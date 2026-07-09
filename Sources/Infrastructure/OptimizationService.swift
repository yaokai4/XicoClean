import Foundation
import DesignSystem
import AppKit
import os

public struct LaunchAgentItem: Identifiable, Sendable, Hashable {
    public let id: String
    public let label: String
    public let url: URL
    public let isSystem: Bool
    public let isEnabled: Bool
}

public struct RunningAppItem: Identifiable, Sendable, Hashable {
    public let id: Int32
    public let name: String
    public let bundleID: String
    public let pid: Int32
    public let iconPath: String?
}

/// 优化：登录项 / 启动代理 与 运行中应用。
public struct OptimizationService: Sendable {
    private let home: URL
    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.home = home
    }

    public func launchAgents() -> [LaunchAgentItem] {
        var items: [LaunchAgentItem] = []
        let locations: [(URL, Bool)] = [
            (home.appendingPathComponent("Library/LaunchAgents"), false),
            (URL(fileURLWithPath: "/Library/LaunchAgents"), true),
            (URL(fileURLWithPath: "/Library/LaunchDaemons"), true)
        ]
        for (dir, isSystem) in locations {
            let urls = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
            for url in urls {
                let name = url.lastPathComponent
                let enabled = url.pathExtension == "plist"
                let disabled = name.hasSuffix(".plist.disabled")
                guard enabled || disabled else { continue }
                let label = enabled
                    ? url.deletingPathExtension().lastPathComponent
                    : url.deletingPathExtension().deletingPathExtension().lastPathComponent
                items.append(LaunchAgentItem(id: url.path, label: label, url: url,
                                             isSystem: isSystem, isEnabled: enabled))
            }
        }
        return items.sorted { $0.label.lowercased() < $1.label.lowercased() }
    }

    /// 启停结果：新文件 URL + 可选警告（launchctl 未能立即生效时告知用户，但持久开关已改）。
    public struct ToggleResult: Sendable {
        public let url: URL?
        public let warning: String?
    }

    private static let log = Logger(subsystem: "com.xico.app", category: "app")

    /// 启用/停用用户级启动代理（系统级需管理员，UI 已禁用）。
    /// 用现代 `launchctl bootstrap/bootout gui/$UID`（旧 load/unload 在新系统上常静默失败）；
    /// 在后台执行、检查退出码；文件改名失败会回滚，launchctl 失败作为软警告如实上报。
    public func setEnabled(_ agent: LaunchAgentItem, enabled: Bool) async -> ToggleResult {
        guard !agent.isSystem else { return ToggleResult(url: nil, warning: "系统级项目需要管理员权限") }
        let fm = FileManager.default
        let uid = getuid()
        let domain = "gui/\(uid)"

        if enabled {
            let target = agent.url.deletingPathExtension()   // 去掉 .disabled
            do {
                try fm.moveItem(at: agent.url, to: target)
            } catch {
                Self.log.error("启用启动项改名失败 \(agent.label, privacy: .public): \(error.localizedDescription, privacy: .public)")
                return ToggleResult(url: nil, warning: xLocF("启用失败：%@", error.localizedDescription))
            }
            let (ok, out) = await Self.runLaunchctl(["bootstrap", domain, target.path])
            // bootstrap 失败通常是"已加载"或需登录会话——文件已启用，将于下次登录生效，作软警告
            let warn = ok ? nil : xLocF("已启用（将在下次登录完全生效）。launchctl：%@", out)
            return ToggleResult(url: target, warning: warn)
        } else {
            // 先尝试停用已加载服务，再改名为 .disabled（持久停用）。
            // service target 需用 plist 内的 Label（与文件名只是约定相等）。plist Label **不可信**：
            // 先做与 ThreatRemediation 同源的白名单校验（仅 [A-Za-z0-9._-]），非法则回退到文件系统
            // 派生的 Label（我方可控），仍非法即跳过 bootout（仅改名做持久停用），绝不把畸形串
            // 传给 launchctl（防被构造成其它服务目标或参数注入，审计 P3 安全）。
            let declared = (NSDictionary(contentsOf: agent.url)?["Label"] as? String) ?? agent.label
            let label = ThreatRemediation.isValidLaunchdLabel(declared) ? declared : agent.label
            var ok = true
            var out = ""
            if ThreatRemediation.isValidLaunchdLabel(label) {
                (ok, out) = await Self.runLaunchctl(["bootout", "\(domain)/\(label)"])
            }
            let target = agent.url.appendingPathExtension("disabled")
            do {
                try fm.moveItem(at: agent.url, to: target)
            } catch {
                Self.log.error("停用启动项改名失败 \(agent.label, privacy: .public): \(error.localizedDescription, privacy: .public)")
                return ToggleResult(url: nil, warning: xLocF("停用失败：%@", error.localizedDescription))
            }
            let warn = ok ? nil : xLocF("已停用（下次登录不再启动）。当前会话可能仍在运行：%@", out)
            return ToggleResult(url: target, warning: warn)
        }
    }

    /// 后台执行 launchctl，返回 (成功, 输出)。不阻塞主线程。
    private static func runLaunchctl(_ args: [String]) async -> (Bool, String) {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let proc = Process()
                proc.executableURL = URL(fileURLWithPath: "/bin/launchctl")
                proc.arguments = args
                let pipe = Pipe()
                proc.standardOutput = pipe
                proc.standardError = pipe
                do {
                    try proc.run()
                    // 先排空管道再 waitUntilExit：若子进程输出填满管道缓冲区而父进程先阻塞在
                    // waitUntilExit，会互相死锁。与 MaintenanceRunner / runSystemProfiler 同序（审计 P3）。
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    proc.waitUntilExit()
                    let out = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    continuation.resume(returning: (proc.terminationStatus == 0, out.isEmpty ? xLocF("退出码 %d", Int(proc.terminationStatus)) : out))
                } catch {
                    continuation.resume(returning: (false, error.localizedDescription))
                }
            }
        }
    }

    @MainActor public func runningApps() -> [RunningAppItem] {
        let selfPID = ProcessInfo.processInfo.processIdentifier
        return NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.processIdentifier != selfPID }
            .map { app in
                RunningAppItem(
                    id: app.processIdentifier,
                    name: app.localizedName ?? app.bundleIdentifier ?? "未知",
                    bundleID: app.bundleIdentifier ?? "",
                    pid: app.processIdentifier,
                    iconPath: app.bundleURL?.path)
            }
            .sorted { $0.name.lowercased() < $1.name.lowercased() }
    }

    @MainActor public func quit(pid: Int32) {
        NSRunningApplication(processIdentifier: pid_t(pid))?.terminate()
    }

    @MainActor public func reveal(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}
