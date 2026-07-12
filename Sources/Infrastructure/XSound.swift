import AppKit
import DesignSystem

/// 签名音效（P4）：只有三个——扫描完成、清理完成、收集篮倒计时归零执行。
/// 铁律：克制（短促、-12dB 起步）、全局可关（xico.sound.enabled）、跟随系统「播放用户界面声音效果」、
/// 危险操作（粉碎等）永不配音效、循环/hover 永不配音效。
///
/// 资产（docs/16 P0-2）：定制合成音色（谐波钟声 + 指数衰减包络 + 单极低通，
/// DesignSystem/Resources/xico-*.wav）——scanDone 轻质高频叮 / cleanDone 玻璃水滴 /
/// countdownDone 低频确认。资源缺失时回退系统音，绝不静默失效。
@MainActor
public enum XSound {
    public enum Effect: String {
        case scanDone       // 扫描完成：轻质「叮」
        case cleanDone      // 清理完成：满足感「玻璃」
        case countdownDone  // 收集篮倒计时归零：低调确认
    }

    /// 全局开关（设置页「界面音效」）。
    public static var enabled: Bool {
        UserDefaults.standard.object(forKey: "xico.sound.enabled") == nil
            ? true
            : UserDefaults.standard.bool(forKey: "xico.sound.enabled")
    }

    /// 系统「播放用户界面声音效果」偏好（读不到时视为开）。
    private static var systemUISoundsEnabled: Bool {
        guard let v = CFPreferencesCopyValue("com.apple.sound.uiaudio.enabled" as CFString,
                                             kCFPreferencesAnyApplication,
                                             kCFPreferencesCurrentUser,
                                             kCFPreferencesAnyHost) as? Bool else { return true }
        return v
    }

    /// 播放中的实例持有：NSSound 无人持有会被释放而中途哑掉（局部变量出作用域即停）。
    private static var current: NSSound?

    public static func play(_ effect: Effect) {
        guard enabled, systemUISoundsEnabled else { return }
        // 定制签名音色优先；资源缺失回退系统音（绝不静默失效）。
        let sound: NSSound?
        if let url = XAssets.soundURL("xico-\(effect.rawValue)") {
            sound = NSSound(contentsOf: url, byReference: true)
        } else {
            let fallback: NSSound.Name
            switch effect {
            case .scanDone:      fallback = "Tink"
            case .cleanDone:     fallback = "Glass"
            case .countdownDone: fallback = "Pop"
            }
            sound = NSSound(named: fallback)
        }
        guard let sound else { return }
        sound.volume = 0.25   // ≈ -12dB：存在感来自「有」，不来自「响」
        current = sound
        sound.play()
    }
}
