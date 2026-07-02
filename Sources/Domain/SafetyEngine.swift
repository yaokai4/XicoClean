import Foundation
import Shared

/// 默认安全引擎：清理器的命门。
/// 任何删除前都必须经过 verify；保护清单内的路径一律拒绝。
///
/// 实现已下沉到 `Shared.XicoSafetyRules`（唯一事实来源），
/// 主应用与特权助手共用同一份红线，杜绝两侧口径分裂。
public struct DefaultSafetyEngine: SafetyEngine {
    private let rules: XicoSafetyRules
    /// 用户内容目录（其中的文件只允许移入废纸篓，绝不允许彻底删除）。小写、已解析。
    private let contentRootsLower: [[String]]

    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        rules = XicoSafetyRules(home: home)
        let h = home.standardizedFileURL.resolvingSymlinksInPath()
        contentRootsLower = ["Documents", "Desktop", "Pictures", "Movies", "Music", "Downloads"].map {
            XicoSafetyRules.canonicalLower(h.appendingPathComponent($0).pathComponents)
        }
    }

    public func verify(_ url: URL, intent: DeleteIntent) -> SafetyVerdict {
        if let reason = rules.denyReason(for: url) {
            return .deny(reason: reason)
        }
        // DeleteIntent 差异化：内容目录（文稿/桌面/图片/影片/音乐/下载）内的文件对
        // .trash 放行（可恢复），但 .permanent 一律拒——彻底删除用户内容永不可逆，
        // 任何模块误用 permanent intent 都会在此被红线兜底拦下。
        if intent == .permanent {
            let t = XicoSafetyRules.canonicalLower(url.standardizedFileURL.resolvingSymlinksInPath().pathComponents)
            for root in contentRootsLower where XicoSafetyRules.isInsideOrEqual(t, root) {
                return .deny(reason: "内容目录中的文件仅支持移入废纸篓（可恢复），不支持彻底删除")
            }
        }
        return .allow
    }
}
