import Foundation
import Shared

/// 默认安全引擎：清理器的命门。
/// 任何删除前都必须经过 verify；保护清单内的路径一律拒绝。
///
/// 实现已下沉到 `Shared.XicoSafetyRules`（唯一事实来源），
/// 主应用与特权助手共用同一份红线，杜绝两侧口径分裂。
public struct DefaultSafetyEngine: SafetyEngine {
    private let rules: XicoSafetyRules

    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        rules = XicoSafetyRules(home: home)
    }

    public func verify(_ url: URL, intent: DeleteIntent) -> SafetyVerdict {
        if let reason = rules.denyReason(for: url) {
            return .deny(reason: reason)
        }
        return .allow
    }
}
