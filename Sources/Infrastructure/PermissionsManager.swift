import Foundation
import AppKit

/// 检测与引导「完全磁盘访问权限」（FDA）。
public struct PermissionsManager: Sendable {
    public init() {}

    /// 启发式检测是否已获得完全磁盘访问权限：
    /// 尝试列出仅 FDA 才能读取的目录。
    public func hasFullDiskAccess() -> Bool {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let probes = [
            home.appendingPathComponent("Library/Application Support/com.apple.TCC"),
            home.appendingPathComponent("Library/Safari")
        ]
        for probe in probes where FileManager.default.fileExists(atPath: probe.path) {
            if (try? FileManager.default.contentsOfDirectory(atPath: probe.path)) != nil {
                return true
            } else {
                return false
            }
        }
        // 探针目录都不存在时，保守地认为可用（不阻断功能）
        return true
    }

    /// 打开系统设置的「完全磁盘访问权限」面板
    @MainActor public func openFullDiskAccessSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }
}
