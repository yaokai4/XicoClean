import Foundation

/// 威胁清理的运行期处置：删除 plist 前先 launchctl bootout，停用已加载的用户级恶意 agent，
/// 使其不必等到注销/重启就停止（此前只删文件，活体进程照常运行）。
public enum ThreatRemediation {
    /// 对一批待清理项中的用户级 LaunchAgent plist 执行 bootout（best-effort，逐项）。
    ///
    /// 安全约束（调用方须传入 ThreatScanner 实际标记的可疑项，而非未过滤的任意批次）：本函数
    /// 额外自证——① 只处理**本用户家目录** `~/Library/LaunchAgents/` 下的 plist（gui/<uid> 域即用户域，
    /// 系统级 LaunchDaemons/其它卷一律不碰）；② Label 取自**不可信**的待清理 plist，故先做
    /// 白名单字符校验（仅 `[A-Za-z0-9._-]`，拒绝空格/路径分隔符/其它元字符），杜绝被构造成
    /// 另一个服务标签或参数注入 launchctl。任一不满足即跳过该项。
    public static func bootoutUserAgents(_ urls: [URL]) async {
        let uid = getuid()
        let userAgentsDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents").standardizedFileURL.path
        for url in urls {
            guard url.pathExtension == "plist" else { continue }
            // 仅限用户域 LaunchAgents（gui/<uid> 对应的就是这里）；系统级/外置卷不处理。
            let std = url.standardizedFileURL.path
            guard std == userAgentsDir || std.hasPrefix(userAgentsDir + "/") else { continue }
            // 优先读 plist 的 Label；缺失则回退到文件名（去 .plist）
            let label = (NSDictionary(contentsOf: url)?["Label"] as? String)
                ?? url.deletingPathExtension().lastPathComponent
            // Label 来自不可信 plist：形状不合法（含空格/分隔符/元字符）即拒绝，绝不传给 launchctl。
            guard isValidLaunchdLabel(label) else { continue }
            _ = await runLaunchctl(["bootout", "gui/\(uid)/\(label)"])
        }
    }

    /// launchd Label 合法性：非空、长度受限、仅 `[A-Za-z0-9._-]`（反向域名风格）。
    /// 拒绝空格、`/`、`;`、`$` 等——即便 Process 以参数数组传参无 shell 注入，也防其被当作
    /// 其它服务目标或选项误解析。
    static func isValidLaunchdLabel(_ label: String) -> Bool {
        guard !label.isEmpty, label.count <= 512 else { return false }
        return label.allSatisfy { c in
            c.isASCII && (c.isLetter || c.isNumber || c == "." || c == "_" || c == "-")
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
