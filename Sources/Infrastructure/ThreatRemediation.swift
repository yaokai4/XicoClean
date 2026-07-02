import Foundation

/// 威胁清理的运行期处置：删除 plist 前先 launchctl bootout，停用已加载的用户级恶意 agent，
/// 使其不必等到注销/重启就停止（此前只删文件，活体进程照常运行）。
public enum ThreatRemediation {
    /// 对一批待清理项中的用户级 LaunchAgent plist 执行 bootout（best-effort，逐项）。
    public static func bootoutUserAgents(_ urls: [URL]) async {
        let uid = getuid()
        for url in urls {
            guard url.pathExtension == "plist",
                  url.path.contains("/LaunchAgents/") else { continue }
            // 优先读 plist 的 Label；缺失则回退到文件名（去 .plist）
            let label = (NSDictionary(contentsOf: url)?["Label"] as? String)
                ?? url.deletingPathExtension().lastPathComponent
            _ = await runLaunchctl(["bootout", "gui/\(uid)/\(label)"])
        }
    }

    private static func runLaunchctl(_ args: [String]) async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let proc = Process()
                proc.executableURL = URL(fileURLWithPath: "/bin/launchctl")
                proc.arguments = args
                proc.standardOutput = FileHandle.nullDevice
                proc.standardError = FileHandle.nullDevice
                do {
                    try proc.run(); proc.waitUntilExit()
                    continuation.resume(returning: proc.terminationStatus == 0)
                } catch {
                    XicoLog.helper.debug("bootout 失败 \(args.joined(separator: " "), privacy: .public): \(error.localizedDescription, privacy: .public)")
                    continuation.resume(returning: false)
                }
            }
        }
    }
}
