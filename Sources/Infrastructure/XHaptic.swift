import AppKit

/// 签名触感（docs/16 P0 · CleanMyMac 的结构性盲区）：Force Touch 触控板的物理反馈。
/// 与 `XSound` 完全同构：克制、全局可关（`xico.haptics.enabled`，默认开）、系统自动降级
/// （无支持硬件时 perform 无副作用）。
///
/// 铁律（比声音还克制）：
/// - 只在「有确定后果」的时刻震——完成 / 跨过阈值 / 拖拽吸附；
/// - 危险操作（粉碎 / 删除确认）**永不**配触感——不给误触做「愉悦」强化；
/// - hover / 滚动 / 循环 **永不**配触感——触感疲劳是廉价感来源。
///
/// 为什么这是超越点：清理完成时指尖那一下轻震，是把「软件跑完了」变成
/// 「我做完了一件事」的身体记忆——截图传不出去，但用过就回不去。
@MainActor
public enum XHaptic {
    public enum Kind {
        /// 跨台阶（最重的一次）：清理完成、健康分跨过优秀阈值。
        case levelChange
        /// 对齐吸附（Apple 为拖拽对齐设计）：文件拖入收集篮、面级动效收束点。
        case alignment
        /// 通用轻反馈。
        case generic
    }

    /// 全局开关（设置页「触感反馈」）。
    public static var enabled: Bool {
        UserDefaults.standard.object(forKey: "xico.haptics.enabled") == nil
            ? true
            : UserDefaults.standard.bool(forKey: "xico.haptics.enabled")
    }

    public static func perform(_ kind: Kind) {
        guard enabled else { return }
        let pattern: NSHapticFeedbackManager.FeedbackPattern
        switch kind {
        case .levelChange: pattern = .levelChange
        case .alignment:   pattern = .alignment
        case .generic:     pattern = .generic
        }
        NSHapticFeedbackManager.defaultPerformer.perform(pattern, performanceTime: .now)
    }
}
