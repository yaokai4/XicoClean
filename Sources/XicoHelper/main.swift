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
            // 5) 防 TOCTOU：整条路径（含叶）必须真实存在且无任一分量是符号链接，
            //    否则攻击者可在校验后把中间分量换成软链让 removeItem 删穿。
            guard Self.isSymlinkFreeAndExtant(std) else {
                Self.log.error("拒绝含符号链接/不存在的路径: \(std, privacy: .public)")
                failures.append(path); continue
            }
            let url = URL(fileURLWithPath: std)
            let size = (try? fm.attributesOfItem(atPath: std)[.size] as? Int64) ?? 0
            do {
                try fm.removeItem(at: url)
                freed += size
                Self.log.notice("已删除: \(std, privacy: .public) (\(size) bytes)")
            } catch {
                Self.log.error("删除失败: \(std, privacy: .public) — \(error.localizedDescription, privacy: .public)")
                failures.append(path)
            }
        }
        reply(freed, failures)
    }

    /// 从根逐分量 lstat：要求每一段都存在且都不是符号链接。
    /// 配合「目标根目录为 root 所有、非特权进程不可写入」即可消除 TOCTOU 换链竞态。
    static func isSymlinkFreeAndExtant(_ path: String) -> Bool {
        var current = "/"
        for comp in (path as NSString).pathComponents where comp != "/" {
            current = (current as NSString).appendingPathComponent(comp)
            var st = stat()
            guard lstat(current, &st) == 0 else { return false }
            if (st.st_mode & S_IFMT) == S_IFLNK { return false }
        }
        return current != "/"
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
