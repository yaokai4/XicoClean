import Foundation
import Darwin
import os
import Shared

/// 特权助手守护进程（以 root 运行；需正式签名 + SMAppService 注册后才会被系统拉起）。
/// 只暴露白名单化、参数化的高危操作；纵深防御：
///   1. 连接级：仅接受满足代码签名要求（同 Team ID 的 Xico 主应用）的调用方；
///   2. 操作级：删除前用与主应用同一份 SafetyEngine 红线（Shared.XicoSafetyRules）复校，并解析符号链接；
///   3. 审计：每次特权操作与判定结果都落 os_log。
/// 空闲计时器：无新连接超过 timeout 秒即 exit(0)，由 launchd 按需重新拉起。
final class IdleExit: @unchecked Sendable {
    static let shared = IdleExit()
    private let timeout: TimeInterval = 90
    private var timer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "com.xico.app.helper.idle")
    /// 正在执行的特权操作数；>0 期间绝不空闲退出——大批特权删除或维护任务可能超过 timeout 秒，
    /// 若此时计时器触发 exit(0)，操作会被拦腰截断（残留半删目录）。这是数据损坏级 bug。
    private var inFlight = 0

    func arm() { touch() }

    func touch() {
        queue.async { self.rearm() }
    }

    /// 标记一次特权操作开始：挂起空闲退出（取消计时器）。须与 endOperation 成对使用。
    /// HelperFileRemover 位于 Shared 模块、无法反向引用本执行档里的 IdleExit（模块/层级边界：
    /// XicoHelper import Shared，反之会造成循环依赖），因此改由助手在每个耗时 XPC 方法进出时
    /// 挂起/重装计时器——无论操作跑多久都不会被空闲退出打断，完成后才重新计时。
    func beginOperation() {
        queue.async {
            self.inFlight += 1
            self.timer?.cancel()
            self.timer = nil
        }
    }

    /// 标记一次特权操作结束：所有在飞行的操作都完成后，才重新武装空闲计时。
    func endOperation() {
        queue.async {
            self.inFlight = max(0, self.inFlight - 1)
            if self.inFlight == 0 { self.rearm() }
        }
    }

    /// 重装空闲计时器（仅当无操作在飞行时才真正计时；须在 queue 上调用）。
    private func rearm() {
        guard inFlight == 0 else { return }
        timer?.cancel()
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + timeout)
        t.setEventHandler { exit(0) }
        t.resume()
        timer = t
    }
}

final class HelperService: NSObject, XicoHelperProtocol, NSXPCListenerDelegate {

    private static let log = Logger(subsystem: XicoHelperMachServiceName, category: "helper")

    /// 助手端独立持有的红线（home 无关：保护所有用户的敏感目录）
    private let safety = XicoSafetyRules()
    /// root 递归删除核心（白名单注入化，逻辑与单测共用同一实现）
    private let remover = HelperFileRemover(deletableRoots: XicoHelperSecurity.deletableRoots)

    func version(reply: @escaping (String) -> Void) {
        reply(XicoHelperInfo.version)
    }

    func runMaintenance(_ rawTask: String, reply: @escaping (Bool, String?) -> Void) {
        // 维护任务（如 mdutil -E 重建 Spotlight、tmutil 删本地快照）可能长于空闲 timeout——
        // 挂起空闲退出直至任务返回，避免跑到一半被 exit(0) 截断。
        IdleExit.shared.beginOperation()
        defer { IdleExit.shared.endOperation() }
        guard let task = MaintenanceTask(rawValue: rawTask) else {
            Self.log.error("runMaintenance 收到未知任务: \(rawTask, privacy: .public)")
            reply(false, "未知任务"); return
        }
        let (cmd, args): (String, [String])
        switch task {
        case .freeMemory:          (cmd, args) = ("/usr/sbin/purge", [])
        case .flushDNS:            (cmd, args) = ("/usr/bin/dscacheutil", ["-flushcache"])
        case .rebuildSpotlight:    (cmd, args) = ("/usr/bin/mdutil", ["-E", "/"])
        case .deleteLocalSnapshots:(cmd, args) = ("/usr/bin/tmutil", ["deletelocalsnapshots", "/"])
        }
        Self.log.notice("执行维护任务: \(task.rawValue, privacy: .public)")
        let (ok, output) = Self.run(cmd, args)
        reply(ok, output)
    }

    func removeProtected(paths: [String], reply: @escaping (Int64, [String]) -> Void) {
        // 大批特权删除可能长于空闲 timeout——挂起空闲退出直至整批删完，
        // 避免删到一半被 exit(0) 截断（残留半删目录）。
        IdleExit.shared.beginOperation()
        defer { IdleExit.shared.endOperation() }
        var freed: Int64 = 0
        var failures: [String] = []
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
            let size = Self.allocatedSize(atPath: std)
            if remover.safeRemove(std) {
                freed += size
                Self.log.notice("已删除: \(std, privacy: .public) (\(size) bytes)")
            } else {
                Self.log.error("删除失败/被拒: \(std, privacy: .public)")
                failures.append(path)
            }
        }
        reply(freed, failures)
    }

    static func allocatedSize(atPath path: String) -> Int64 {
        let url = URL(fileURLWithPath: path)
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .totalFileAllocatedSizeKey, .fileSizeKey]
        guard let rv = try? url.resourceValues(forKeys: keys) else { return 0 }
        if rv.isDirectory != true {
            return Int64(rv.totalFileAllocatedSize ?? rv.fileSize ?? 0)
        }
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: Array(keys),
            options: [],
            errorHandler: { _, _ in true }
        ) else { return 0 }
        var total: Int64 = Int64(rv.totalFileAllocatedSize ?? 0)
        for case let child as URL in enumerator {
            guard let values = try? child.resourceValues(forKeys: keys), values.isDirectory != true else { continue }
            total += Int64(values.totalFileAllocatedSize ?? values.fileSize ?? 0)
        }
        return total
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
        IdleExit.shared.touch()   // 有活干，推迟空闲退出
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

// 空闲自动退出：root 守护进程不必长驻，缩短攻击面暴露窗口。
// launchd 会在下次有连接时按需重新拉起（MachService on-demand）。
// 每次接受连接时刷新计时；90 秒无新连接即退出。
IdleExit.shared.arm()

RunLoop.main.run()
