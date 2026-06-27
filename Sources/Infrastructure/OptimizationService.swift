import Foundation
import AppKit

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

    /// 启用/停用用户级启动代理（系统级需管理员，UI 已禁用）。返回新文件 URL。
    @MainActor public func setEnabled(_ agent: LaunchAgentItem, enabled: Bool) -> URL? {
        guard !agent.isSystem else { return nil }
        let fm = FileManager.default
        if enabled {
            let target = agent.url.deletingPathExtension() // 去掉 .disabled
            try? fm.moveItem(at: agent.url, to: target)
            runLaunchctl(["load", target.path])
            return target
        } else {
            runLaunchctl(["unload", agent.url.path])
            let target = agent.url.appendingPathExtension("disabled")
            try? fm.moveItem(at: agent.url, to: target)
            return target
        }
    }

    private func runLaunchctl(_ args: [String]) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        proc.arguments = args
        try? proc.run()
        proc.waitUntilExit()
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
