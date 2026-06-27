import Foundation
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
            // 解析符号链接 + 标准化后用统一红线复校（与主应用逐项一致，杜绝软链绕过）
            let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL
            if let reason = safety.denyReason(for: resolved) {
                Self.log.error("拒绝删除受保护路径: \(path, privacy: .public) — \(reason, privacy: .public)")
                failures.append(path); continue
            }
            guard fm.fileExists(atPath: resolved.path) else {
                failures.append(path); continue
            }
            let size = (try? fm.attributesOfItem(atPath: resolved.path)[.size] as? Int64) ?? 0
            do {
                try fm.removeItem(at: resolved)
                freed += size
                Self.log.notice("已删除: \(resolved.path, privacy: .public) (\(size) bytes)")
            } catch {
                Self.log.error("删除失败: \(resolved.path, privacy: .public) — \(error.localizedDescription, privacy: .public)")
                failures.append(path)
            }
        }
        reply(freed, failures)
    }

    // MARK: XPC 连接校验（纵深防御第一道闸门）

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection conn: NSXPCConnection) -> Bool {
        // 仅接受满足代码签名要求的调用方（同 Team ID 的 Xico 主应用）。
        // 由内核在投递消息时强制校验，非匹配方的连接会被立即失效。
        if #available(macOS 13.0, *) {
            conn.setCodeSigningRequirement(XicoHelperSecurity.clientCodeRequirement)
            if !XicoHelperSecurity.isTeamIdentifierConfigured {
                Self.log.fault("Team ID 未配置：所有客户端连接都会被拒绝，请在 Shared/HelperSecurity.swift 设置真实 Team ID")
            }
        } else {
            // 低于 macOS 13 无法用内核级校验，安全起见直接拒绝。
            Self.log.fault("当前系统不支持连接级签名校验，拒绝连接")
            return false
        }
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
