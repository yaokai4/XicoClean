import AppKit

/// 签名音效（P4）：只有三个——扫描完成、清理完成、收集篮倒计时归零执行。
/// 铁律：克制（短促、-12dB 起步）、全局可关（xico.sound.enabled）、跟随系统「播放用户界面声音效果」、
/// 危险操作（粉碎等）永不配音效、循环/hover 永不配音效。
///
/// 资产：当前用系统内置音色作占位（TODO：替换为专业定制音效资产——真实录音/专业合成，
/// 参考 CleanMyMac 的多感官设计；接入点已就绪，只需替换 Bundle 资源与此处映射）。
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

    public static func play(_ effect: Effect) {
        guard enabled, systemUISoundsEnabled else { return }
        let name: NSSound.Name
        switch effect {
        case .scanDone:      name = "Tink"
        case .cleanDone:     name = "Glass"
        case .countdownDone: name = "Pop"
        }
        guard let sound = NSSound(named: name) else { return }
        sound.volume = 0.25   // ≈ -12dB：存在感来自「有」，不来自「响」
        sound.play()
    }
}
