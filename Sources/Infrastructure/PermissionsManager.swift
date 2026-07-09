import Foundation
import AppKit

/// 检测与引导「完全磁盘访问权限」（FDA）。
public struct PermissionsManager: Sendable {
    public init() {}

    /// 检测是否已获得完全磁盘访问权限（FDA）。
    ///
    /// 先做**强阳性探针**：直接读取只有 FDA 才能打开的具体文件（Safari 书签 / 用户 TCC.db）。
    /// 能读到 → 明确已授权；文件存在却读不动（EPERM 等）→ 明确未授权（比只「列目录」更不易假阴性，
    /// 因为某些位置在未授权时目录列举会「看似成功」但拿不到受保护内容）。
    /// 两个文件都不存在时，退回目录列举启发式；仍无定论则保守判「未授权」。
    public func hasFullDiskAccess() -> Bool {
        let home = FileManager.default.homeDirectoryForCurrentUser
        // 强阳性探针：这些文件在未授 FDA 时打开会被内核以权限错误拒绝。
        let fileProbes = [
            home.appendingPathComponent("Library/Safari/Bookmarks.plist"),
            home.appendingPathComponent("Library/Application Support/com.apple.TCC/TCC.db")
        ]
        for probe in fileProbes where FileManager.default.fileExists(atPath: probe.path) {
            do {
                let handle = try FileHandle(forReadingFrom: probe)
                defer { try? handle.close() }
                _ = try handle.read(upToCount: 1)   // 真正触达内容，权限不足会在此抛错
                return true
            } catch {
                // 文件存在却打不开/读不动 → 权限被拒，判为「未授权」（definitive）
                return false
            }
        }
        // 退回启发式：列出仅 FDA 才能读取的目录。
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
        // 探针都不存在时，保守地判为「未授权」：宁可显示授权入口，也不把没权限伪装成可用
        return false
    }

    /// 打开系统设置的「完全磁盘访问权限」面板
    @MainActor public func openFullDiskAccessSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }
}
