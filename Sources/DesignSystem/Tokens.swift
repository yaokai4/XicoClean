import SwiftUI
import AppKit

// MARK: - 颜色（语义化 Design Tokens，自动深浅色）

public enum XColor {
    // 品牌渐变（淡彩虹：蓝 → 紫 → 兰，中等明度配白字清晰）
    public static let auroraBlue   = dynamic(light: 0x5478F0, dark: 0x7C97F2)
    public static let auroraViolet = dynamic(light: 0x8B6FE6, dark: 0xA790F0)
    public static let auroraOrchid = dynamic(light: 0xB873D8, dark: 0xC79AE8)
    public static let auroraRose   = dynamic(light: 0xD874B0, dark: 0xE6A6CE)
    /// 品牌强调色——随当前主题变化（图标、高亮、选中态）
    public static var brand: Color { XThemeStore.current.accent }
    public static let brandEnd     = auroraRose
    public static let accentTeal   = dynamic(light: 0x3AC9C2, dark: 0x86E6DC)
    public static let accentPink   = dynamic(light: 0xE070AC, dark: 0xF0A8CE)
    public static let accentViolet = auroraViolet

    // 光环/光晕：Apple 智能式淡彩虹，但用更沉的珠宝色相（去「糖果塑料感」，
    // 保留彩色识别度的同时更高级）。暗底略提亮以保通透。
    public static let ringRose   = dynamic(light: 0xD772A2, dark: 0xEC9EC2)
    public static let ringLav    = dynamic(light: 0x9A78D8, dark: 0xBBA2ED)
    public static let ringPeri   = dynamic(light: 0x6E86E0, dark: 0x9DB0EE)
    public static let ringMint   = dynamic(light: 0x46B3AC, dark: 0x92DDD2)
    // 仪表/图表默认配色——随当前主题变化
    public static var ringColors: [Color] { XThemeStore.current.ring }

    public static let success      = dynamic(light: 0x1FB87A, dark: 0x35DEA0)
    public static let warning      = dynamic(light: 0xF59E0B, dark: 0xFFC53D)
    public static let danger       = dynamic(light: 0xF24B5E, dark: 0xFF6F80)

    // 背景与表面（冷调墨黑，独立于 CleanMyMac 的紫调）
    public static let canvasTop    = dynamic(light: 0xF6F7FC, dark: 0x10121E)
    public static let canvasBottom = dynamic(light: 0xEDEFF7, dark: 0x07080F)
    public static let sidebar      = dynamic(light: 0xFBFBFE, dark: 0x0D0F19)
    public static let surface      = dynamic(light: 0xFFFFFF, dark: 0x181B2A)
    public static let surfaceAlt   = dynamic(light: 0xEFF1F8, dark: 0x232739)
    public static let surfaceHover = dynamic(light: 0xF5F6FC, dark: 0x2B3047)

    public static let textPrimary   = dynamic(light: 0x171A28, dark: 0xF4F6FC)
    public static let textSecondary = dynamic(light: 0x666C80, dark: 0xA4ABC2)
    public static let textTertiary  = dynamic(light: 0x9AA0B4, dark: 0x666D84)
    public static let border        = dynamic(light: 0xE5E8F1, dark: 0x2A2F44)
    public static let hairline      = dynamic(light: 0xEDEFF6, dark: 0x1D2131)

    // 渐变（三段，配白字清晰）——随当前主题变化
    public static var brandGradientColors: [Color] { XThemeStore.current.gradient }
    public static var brandGradient: LinearGradient {
        LinearGradient(colors: XThemeStore.current.gradient, startPoint: .topLeading, endPoint: .bottomTrailing)
    }
    public static var successGradient: LinearGradient {
        LinearGradient(colors: [accentTeal, success], startPoint: .topLeading, endPoint: .bottomTrailing)
    }
    /// 主题强调色（图标、分段标题）。
    public static var themeAccent: Color { XThemeStore.current.accent }

    /// 健康分 / 占用率 → 颜色（三段语义：让仪表说真话）。
    /// <78% 健康：品牌通透色；78–90% 偏高：暖橙；≥90% 危险：红粉。
    /// 这样「88% 满盘」读作偏高提示而非满屏假告警，纯红只留给真正贴顶。
    public static func gauge(_ fraction: Double) -> [Color] {
        if fraction >= 0.90 { return [danger, accentPink] }
        if fraction >= 0.78 { return [warning, accentPink] }
        return ringColors
    }

    /// GPU 专用光环：高占用是「在干活」而非告警，永不转红，用清凉的紫罗兰渐变。
    public static func gpuGauge(_ fraction: Double) -> [Color] {
        [auroraViolet, auroraOrchid]
    }

    /// 便捷构造动态色（供主题定义用）。
    public static func dyn(_ light: Int, _ dark: Int) -> Color { dynamic(light: light, dark: dark) }

    static func dynamic(light: Int, dark: Int) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return NSColor(hex: isDark ? dark : light)
        })
    }
}

public extension NSColor {
    convenience init(hex: Int, alpha: CGFloat = 1) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha)
    }
}

// MARK: - 间距（4pt 基准网格）

public enum XSpacing {
    public static let xxs: CGFloat = 2   // 组内极紧（title↔subtitle、图标↔文字）
    public static let xs: CGFloat = 4
    public static let s: CGFloat = 8
    public static let m: CGFloat = 12
    public static let l: CGFloat = 16
    public static let xl: CGFloat = 24
    public static let xxl: CGFloat = 32
    public static let xxxl: CGFloat = 48
}

// MARK: - 圆角

public enum XRadius {
    public static let control: CGFloat = 8
    public static let button: CGFloat = 11
    public static let tile: CGFloat = 12
    public static let card: CGFloat = 18
    public static let large: CGFloat = 26
}

// MARK: - 字体

// 严格阶梯（约 1.25 模数），相邻两级一眼可分；大数字/标识符各有专属 token，
// 消灭散落的 size:46/34/23/22/10 一次性字号。
public enum XFont {
    public static let hero = Font.system(size: 54, weight: .bold, design: .rounded).monospacedDigit()
    public static let heroCompact = Font.system(size: 46, weight: .bold, design: .rounded).monospacedDigit()  // 仪表盘/详情大数字
    public static let largeTitle = Font.system(size: 28, weight: .bold, design: .rounded)                     // 页面主标题
    public static let title = Font.system(size: 22, weight: .semibold)                                        // 补 largeTitle↔headline 断层
    public static let title2 = Font.system(size: 17, weight: .semibold)                                       // 卡片/区块标题
    public static let headline = Font.system(size: 15, weight: .semibold)                                     // 行标题
    public static let body = Font.system(size: 13, weight: .regular)
    public static let bodyEmphasis = Font.system(size: 13, weight: .medium)
    public static let callout = Font.system(size: 12, weight: .regular)
    public static let caption = Font.system(size: 11, weight: .regular)
    public static let captionEmphasis = Font.system(size: 11, weight: .semibold)
    public static let micro = Font.system(size: 10, weight: .medium)                                          // 唯一合法 10pt（收编所有魔法数字）
    public static let mono = Font.system(size: 13, weight: .semibold, design: .rounded).monospacedDigit()
    public static let monoLarge = Font.system(size: 19, weight: .bold, design: .rounded).monospacedDigit()
    public static let monoHero = Font.system(size: 34, weight: .bold, design: .rounded).monospacedDigit()     // 价格/详情锚点数字
    public static let captionMono = Font.system(size: 11, weight: .regular, design: .monospaced)              // bundleID/IPv6/MAC 等标识符
}

// MARK: - 排版样式（字体 + 字距）

public extension View {
    func xHeroNumber() -> some View { font(XFont.hero).tracking(-0.5) }
    func xLargeTitle() -> some View { font(XFont.largeTitle).tracking(-0.4) }
    func xTitle() -> some View { font(XFont.title).tracking(-0.2) }
    func xHeadline() -> some View { font(XFont.headline).tracking(-0.1) }
    func xSubtitle() -> some View { font(XFont.headline).fontWeight(.regular).tracking(0.2) }   // hero 副标题（15pt regular）
    func xHeroCompactNumber() -> some View { font(XFont.heroCompact).tracking(-0.5) }
    func xSectionLabel() -> some View { font(.system(size: 10, weight: .bold)).tracking(1.0).textCase(.uppercase) }
    func xNumber() -> some View { font(XFont.mono).tracking(-0.2) }
}

// MARK: - 阴影

public struct XShadow: ViewModifier {
    let radius: CGFloat
    let y: CGFloat
    let opacity: Double
    public func body(content: Content) -> some View {
        content
            // 双层投影：大范围环境光柔影 + 近距离接触实影 —— 真实物体的层次感，
            // 而非单层「塑料贴纸」阴影。这是去「塑料感」的关键之一。
            .shadow(color: .black.opacity(opacity), radius: radius, x: 0, y: y)
            .shadow(color: .black.opacity(opacity * 0.55), radius: radius * 0.28, x: 0, y: max(1, y * 0.3))
    }
}

public extension View {
    func xCardShadow() -> some View { modifier(XShadow(radius: 18, y: 8, opacity: 0.10)) }
    func xSoftShadow() -> some View { modifier(XShadow(radius: 8, y: 3, opacity: 0.08)) }
    /// 辉光收敛：贴边一圈、几乎察觉不到——去掉「半屏紫雾/概念稿」感。
    func xGlow(_ color: Color, radius: CGFloat = 16, opacity: Double = 0.28) -> some View {
        shadow(color: color.opacity(opacity), radius: radius, x: 0, y: 0)
    }
}
