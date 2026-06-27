import Foundation
import Darwin
import os
import Shared

/// 特权助手守护进程（以 root 运行；需正式签名 + SMAppService 注册后才会被系统拉起）。
/// 只暴露白名单化、参数化的高危操作；纵深防御：
///   1. 连接级：仅接受满足代码签名要求（同 Team ID 的 Xico 主应用）的调用方；
///   2. 操作级：删除前用与主应用同一份 SafetyEngine 红线（Shared.XicoSafetyRules）复校，并解析符号链接；
///   3. 审计：每次特权操作与判定结果都落 os_log。
final class HelperService: NSObject, XicoHelperProtocol, NSXPCListenerDelegate {

    private static let log = Logger(subsystem: XicoHelperMachServiceName, category: "helper")

    /// 助手端独立持有的红线（home 无关：保护所有用户的敏感目录）
    private let safety = XicoSafetyRules()

    func version(reply: @escaping (String) -> Void) {
        reply("0.2.0")
    }

    func runMaintenance(_ rawTask: String, reply: @escaping (Bool, String?) -> Void) {
        guard let task = MaintenanceTask(rawValue: rawTask) else {
            Self.log.error("runMaintenance 收到未知任务: \(rawTask, privacy: .public)")
            reply(false, "未知任务"); return
        }
        let (cmd, args): (String, [String])
        switch task {
        case .freeMemory:          (cmd, args) = ("/usr/sbin/purge", [])
        case .flushDNS:            (cmd, args) = ("/usr/bin/dscacheutil", ["-flushcache"])
        case .rebuildSpotlight:    (cmd, args) = ("/usr/bin/mdutil", ["-E", "/"])
        case .runPeriodicScripts:  (cmd, args) = ("/usr/sbin/periodic", ["daily", "weekly", "monthly"])
        case .deleteLocalSnapshots:(cmd, args) = ("/usr/bin/tmutil", ["deletelocalsnapshots", "/"])
        }
        Self.log.notice("执行维护任务: \(task.rawValue, privacy: .public)")
        let (ok, output) = Self.run(cmd, args)
        reply(ok, output)
    }

    func removeProtected(paths: [String], reply: @escaping (Int64, [String]) -> Void) {
        var freed: Int64 = 0
        var failures: [String] = []
        let fm = FileManager.default
        for path in paths {
            // 纵深防御，逐层校验（任一不过即拒绝）：
            // 1) 必须是绝对路径（拒相对/空路径，避免依赖助手 CWD）
            guard path.hasPrefix("/") else {
                Self.log.error("拒绝非绝对路径: \(path, privacy: .public)"); failures.append(path); continue
            }
            // 2) 词法标准化（消解 .. 与多余分隔；不解析符号链接——symlink 另行严控）
            let std = (path as NSString).standardizingPath
            // 3) 白名单：只允许删系统级垃圾根下的内容（白名单优于黑名单）
            guard XicoHelperSecurity.isUnderDeletableRoot(std) else {
                Self.log.error("拒绝白名单外路径: \(std, privacy: .public)"); failures.append(path); continue
            }
            // 4) 统一红线复校（与主应用同一份 XicoSafetyRules）
            if let reason = safety.denyReason(forResolvedComponents: URL(fileURLWithPath: std).pathComponents) {
                Self.log.error("拒绝受保护路径: \(std, privacy: .public) — \(reason, privacy: .public)")
                failures.append(path); continue
            }
            // 5) 防 TOCTOU：用 openat(O_NOFOLLOW) 从白名单根逐级下钻、unlinkat 锚定删除，
            //    内核保证不跟随符号链接，即使白名单根全局可写也无法被换链穿透。
            let size = (try? fm.attributesOfItem(atPath: std)[.size] as? Int64) ?? 0
            if Self.safeRemove(std) {
                freed += size
                Self.log.notice("已删除: \(std, privacy: .public) (\(size) bytes)")
            } else {
                Self.log.error("删除失败/被拒: \(std, privacy: .public)")
                failures.append(path)
            }
        }
        reply(freed, failures)
    }

    /// 从白名单根逐级 openat(O_NOFOLLOW) 下钻到父目录，再 fd 锚定递归删除。
    /// 任一分量是符号链接 → openat 失败 → 整体拒绝；无 TOCTOU 换链窗口。
    static func safeRemove(_ path: String) -> Bool {
        guard let root = XicoHelperSecurity.deletableRoots.first(where: { path == $0 || path.hasPrefix($0 + "/") }),
              path != root else { return false }   // 绝不删白名单根本身
        let rootFD = open(root, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard rootFD >= 0 else { return false }
        defer { close(rootFD) }

        let rel = String(path.dropFirst(root.count + 1))
        let comps = rel.split(separator: "/").map(String.init)
        guard let leaf = comps.last else { return false }

        var parentFD = rootFD
        var opened: [Int32] = []
        defer { opened.forEach { close($0) } }
        for comp in comps.dropLast() {
            let fd = openat(parentFD, comp, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0 else { return false }
            opened.append(fd); parentFD = fd
        }
        return removeEntry(parentFD: parentFD, name: leaf)
    }

    /// fd 相对地递归删除一个条目（不跟随符号链接）
    static func removeEntry(parentFD: Int32, name: String) -> Bool {
        var st = stat()
        guard fstatat(parentFD, name, &st, AT_SYMLINK_NOFOLLOW) == 0 else { return false }
        let type = st.st_mode & S_IFMT
        if type == S_IFLNK { return unlinkat(parentFD, name, 0) == 0 }   // 删软链本身，不跟随
        if type == S_IFDIR {
            let dirFD = openat(parentFD, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard dirFD >= 0, let dir = fdopendir(dirFD) else { if dirFD >= 0 { close(dirFD) }; return false }
            var ok = true
            while let ent = readdir(dir) {
                let n = withUnsafeBytes(of: ent.pointee.d_name) { raw -> String in
                    String(cString: raw.baseAddress!.assumingMemoryBound(to: CChar.self))
                }
                if n == "." || n == ".." { continue }
                if !removeEntry(parentFD: dirFD, name: n) { ok = false }
            }
            closedir(dir)   // 同时关闭 dirFD
            return ok && unlinkat(parentFD, name, AT_REMOVEDIR) == 0
        }
        return unlinkat(parentFD, name, 0) == 0
    }

    // MARK: XPC 连接校验（纵深防御第一道闸门）

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection conn: NSXPCConnection) -> Bool {
        // 仅接受满足代码签名要求的调用方（同 Team ID 的 Xico 主应用）。
        // 由内核在投递消息时强制校验，非匹配方的连接会被立即失效。
        // Team ID 未正确配置时显式拒绝（把「拒绝」写成代码，不依赖占位符恰好不匹配的隐式语义）
        guard XicoHelperSecurity.isTeamIdentifierConfigured else {
            Self.log.fault("Team ID 未配置/非法，拒绝所有连接。请在 Shared/HelperSecurity.swift 设置真实 10 位 Team ID")
            return false
        }
        guard #available(macOS 13.0, *) else {
            // 低于 macOS 13 无法用内核级校验，安全起见直接拒绝。
            Self.log.fault("当前系统不支持连接级签名校验，拒绝连接")
            return false
        }
        conn.setCodeSigningRequirement(XicoHelperSecurity.clientCodeRequirement)
        conn.exportedInterface = NSXPCInterface(with: XicoHelperProtocol.self)
        conn.exportedObject = self
        conn.resume()
        return true
    }

    static func run(_ path: String, _ args: [String]) -> (Bool, String?) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: path)
        proc.arguments = args
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe
        do {
            try proc.run()
            proc.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let out = String(data: data, encoding: .utf8)
            return (proc.terminationStatus == 0, out)
        } catch {
            return (false, error.localizedDescription)
        }
    }
}

let delegate = HelperService()
let listener = NSXPCListener(machServiceName: XicoHelperMachServiceName)
listener.delegate = delegate
listener.resume()
RunLoop.main.run()
