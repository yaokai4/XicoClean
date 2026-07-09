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

    /// 主题色阶索引取色（环绕）。所有数据可视化的「第 n 号强调色」都走它——
    /// 切主题即整体换色。i 可为任意整数（自动取模），永不越界。
    public static func ring(_ i: Int) -> Color {
        let r = XThemeStore.current.ring
        guard !r.isEmpty else { return brand }
        return r[((i % r.count) + r.count) % r.count]
    }

    // MARK: 各指标的语义色阶（全部从当前主题色阶派生）
    //
    // 单一事实源：CPU/内存/网络/GPU/磁盘的环·条·直方图·折线·卡片强调统一从这里取色，
    // 切主题时全体同步换色（G1）。各指标取不同的色阶位以在合并总览里互相可辨。
    public static var metricCPU: [Color]     { [ring(2), ring(1)] }   // 冷蓝→紫
    public static var metricMemory: [Color]  { [ring(1), ring(0)] }   // 紫→玫
    public static var metricGPU: [Color]     { [ring(1), ring(2)] }   // 紫→蓝（「在干活」非告警）
    public static var metricNetwork: [Color] { [ring(3), ring(2)] }   // 薄荷→蓝
    public static var metricDisk: [Color]    { [ring(2), ring(3)] }   // 蓝→薄荷
    /// 网络上下行两色（下行 / 上行），随主题走且互相可辨。
    public static var netDown: Color { ring(3) }
    public static var netUp: Color   { ring(0) }

    // 内存明细分类色：3 档主题色阶 + 语义暖橙（压缩=有压力）+ 中性（可用），互相可辨且随主题走。
    public static var memApp: Color        { ring(2) }
    public static var memWired: Color      { ring(0) }
    public static var memCompressed: Color { warning }
    public static var memCached: Color     { ring(3) }
    public static var memFree: Color       { idle }

    public static let success      = dynamic(light: 0x1FB87A, dark: 0x35DEA0)
    public static let warning      = dynamic(light: 0xF59E0B, dark: 0xFFC53D)
    public static let danger       = dynamic(light: 0xF24B5E, dark: 0xFF6F80)
    /// 信息/中性提示（区别于告警橙）——用于非告警型引导横幅等。
    public static let info         = dynamic(light: 0x2E74E6, dark: 0x6BA6FF)
    /// 强调色之上的前景（按钮/图标块白字）。品牌渐变足够深，白字达标。
    public static let onAccent     = Color.white
    /// 非活动/占位中性色（分段控件未选段、骨架屏等），比 textTertiary 更淡。
    public static let idle         = dynamic(light: 0xB4B9C8, dark: 0x4A5066)

    // 背景与表面（冷调墨黑，独立于 CleanMyMac 的紫调）
    public static let canvasTop    = dynamic(light: 0xF6F7FC, dark: 0x10121E)
    public static let canvasBottom = dynamic(light: 0xEDEFF7, dark: 0x07080F)
    public static let sidebar      = dynamic(light: 0xFBFBFE, dark: 0x0D0F19)
    public static let surface      = dynamic(light: 0xFFFFFF, dark: 0x181B2A)
    public static let surfaceAlt   = dynamic(light: 0xEFF1F8, dark: 0x232739)
    public static let surfaceHover = dynamic(light: 0xF5F6FC, dark: 0x2B3047)

    public static let textPrimary   = dynamic(light: 0x171A28, dark: 0xF4F6FC)
    public static let textSecondary = dynamic(light: 0x666C80, dark: 0xA4ABC2)
    // 三级文字：旧值在白底/深底上均未达 WCAG AA（对比 <4.5:1）。再加深浅色档到白底对比 ≥4.5:1
    // （0x6C7286 ≈ 4.8:1），深色档 0x8A91A8 在墨底/表面上均 ≥5.4:1 已达标，保持不变。
    public static let textTertiary  = dynamic(light: 0x6C7286, dark: 0x8A91A8)
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

    /// GPU 专用光环：高占用是「在干活」而非告警，永不转红——用主题色阶的冷调段。
    public static func gpuGauge(_ fraction: Double) -> [Color] {
        metricGPU
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
    public static let micro: CGFloat = 3     // 图表条 / 图例小方块
    public static let chip: CGFloat = 6      // 徽标 / 小胶囊 / 复选框
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
    public static let largeTitle = Font.system(size: 28, weight: .bold, design: .rounded)                     // 页面主标题（无对应文本样式，经 xLargeTitle() 缩放）
    // 标题/区块档位改挂相对文本样式：默认档尺寸与旧固定值一一对齐（title=22、title2=17、title3=15），
    // 默认观感不变，放大辅助字号时随之缩放。token 名/API 全部保持稳定。
    public static let title = Font.system(.title, design: .default).weight(.semibold)                         // 22pt · 补 largeTitle↔headline 断层
    public static let title2 = Font.system(.title2, design: .default).weight(.semibold)                       // 17pt · 卡片/区块标题
    public static let headline = Font.system(.title3, design: .default).weight(.semibold)                     // 15pt · 行标题
    // 正文档位挂到相对文本样式，让文字随系统「首选正文大小」(Dynamic Type) 缩放。
    // 选用默认磅值与旧固定值一致的样式（body=13、callout=12、subheadline=11），
    // 默认设置下观感不变，放大辅助尺寸时整体跟随——token 名/API 全部保持稳定。
    public static let body = Font.system(.body, design: .default)
    public static let bodyEmphasis = Font.system(.body, design: .default).weight(.medium)
    public static let callout = Font.system(.callout, design: .default)
    public static let caption = Font.system(.subheadline, design: .default)
    public static let captionEmphasis = Font.system(.subheadline, design: .default).weight(.semibold)
    public static let micro = Font.system(size: 10, weight: .medium)                                          // 唯一合法 10pt（收编所有魔法数字）
    public static let nano = Font.system(size: 9, weight: .semibold)                                           // 图例/角标最小字（收编 size:8/9）
    public static let microMono = Font.system(size: 9, weight: .semibold, design: .rounded).monospacedDigit()  // 迷你数字（菜单栏副行等）
    public static let wordmark = Font.system(size: 21, weight: .bold, design: .rounded)                        // 品牌字标「Xico」
    // 行内等宽数字挂 .body（默认 13pt）相对样式——随 Dynamic Type 缩放，默认档观感与旧固定值一致。
    public static let mono = Font.system(.body, design: .rounded).weight(.semibold).monospacedDigit()
    public static let monoLarge = Font.system(size: 19, weight: .bold, design: .rounded).monospacedDigit()
    public static let monoHero = Font.system(size: 34, weight: .bold, design: .rounded).monospacedDigit()     // 价格/详情锚点数字
    public static let captionMono = Font.system(.subheadline, design: .monospaced)                            // 11pt · bundleID/IPv6/MAC 等标识符
    // 环心数字：固定磅值以稳妥贴合小环内径（不随 Dynamic Type 放大溢出）——收编散落的 size:10/11/15 圆润数字。
    public static let monoMini = Font.system(size: 11, weight: .bold, design: .rounded).monospacedDigit()     // 迷你环中心数字（每核心/GPU 小环）
    public static let monoMid  = Font.system(size: 15, weight: .bold, design: .rounded).monospacedDigit()     // 详情主环中心百分数（60pt 环）
    public static let heroUnit = Font.system(size: 23, weight: .semibold, design: .rounded)                   // 环心大数字旁的单位（配 heroCompact，收编 size:23）
    // 圆润粗体大标题（健康分标题等）——挂相对 .title 样式，默认 22pt 观感不变且随 Dynamic Type 缩放（收编 size:22）。
    public static let titleRounded = Font.system(.title, design: .rounded).weight(.bold)
}

// MARK: - 排版样式（字体 + 字距）

/// 让固定磅值的标题/大数字随「首选文本大小」(Dynamic Type) 等比缩放，同时 100% 保留默认磅值观感
/// （@ScaledMetric 的 wrappedValue 即默认档尺寸）。用于 hero/heroCompact/largeTitle/区块标签等
/// 没有对应文本样式、但仍应随辅助功能字号放大的字号——纯 Font.system(size:) 不随缩放。
struct XScaledFont: ViewModifier {
    @ScaledMetric private var size: CGFloat
    private let weight: Font.Weight
    private let design: Font.Design
    private let monospacedDigit: Bool
    private let tracking: CGFloat

    init(size: CGFloat, relativeTo textStyle: Font.TextStyle, weight: Font.Weight,
         design: Font.Design = .default, monospacedDigit: Bool = false, tracking: CGFloat = 0) {
        _size = ScaledMetric(wrappedValue: size, relativeTo: textStyle)
        self.weight = weight
        self.design = design
        self.monospacedDigit = monospacedDigit
        self.tracking = tracking
    }

    func body(content: Content) -> some View {
        let base = Font.system(size: size, weight: weight, design: design)
        return content
            .font(monospacedDigit ? base.monospacedDigit() : base)
            .tracking(tracking)
    }
}

public extension View {
    // hero / heroCompact / largeTitle：单行大数字与页面主标题——随 Dynamic Type 缩放，
    // 但对单行数字版式设无障碍上限，避免放大到换行/溢出。
    func xHeroNumber() -> some View {
        modifier(XScaledFont(size: 54, relativeTo: .largeTitle, weight: .bold, design: .rounded,
                             monospacedDigit: true, tracking: -0.5))
            .dynamicTypeSize(...DynamicTypeSize.accessibility1)
    }
    func xLargeTitle() -> some View {
        modifier(XScaledFont(size: 28, relativeTo: .largeTitle, weight: .bold, design: .rounded, tracking: -0.4))
            .dynamicTypeSize(...DynamicTypeSize.accessibility2)
    }
    func xTitle() -> some View { font(XFont.title).tracking(-0.2) }
    func xHeadline() -> some View { font(XFont.headline).tracking(-0.1) }
    func xSubtitle() -> some View { font(XFont.headline).fontWeight(.regular).tracking(0.2) }   // hero 副标题（15pt regular）
    func xHeroCompactNumber() -> some View {
        modifier(XScaledFont(size: 46, relativeTo: .largeTitle, weight: .bold, design: .rounded,
                             monospacedDigit: true, tracking: -0.5))
            .dynamicTypeSize(...DynamicTypeSize.accessibility1)
    }
    func xSectionLabel() -> some View {
        modifier(XScaledFont(size: 10, relativeTo: .caption, weight: .bold, tracking: 1.0))
            .textCase(.uppercase)
    }
    func xNumber() -> some View { font(XFont.mono).tracking(-0.2) }
    // 侧栏主导航标签：13.5pt 随 Dynamic Type 缩放；字重随选中变化但字号恒定，避免选中时行高跳动重排。
    // 收编 RootView SidebarTile 里的 size:13.5 字面量（审计 RootView:199 P2）。
    func xNavLabel(selected: Bool) -> some View {
        modifier(XScaledFont(size: 13.5, relativeTo: .body, weight: selected ? .semibold : .medium))
    }
    // 侧栏主导航图标：固定 14pt（与标签同步字重），字号恒定避免选中重排。收编 size:14 字面量。
    func xNavIcon(selected: Bool) -> some View {
        font(.system(size: 14, weight: selected ? .semibold : .regular))
    }
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
    /// 统一层次阶梯（见 XElevation）。
    func xElevation(_ level: XElevation) -> some View { modifier(level.modifier) }
}

// MARK: - 层次阶梯（真实 z 轴：贴面 → 静置 → 抬起 → 浮层）

/// 三级（+贴面）立体阶梯，取代散落的单层阴影。卡片默认 resting，悬停升 raised，
/// 菜单栏弹窗/定价 sheet 用 overlay。让界面像「叠在桌面之上的分层实物」，而非平面贴纸。
public enum XElevation {
    case flush, resting, raised, overlay
    var modifier: XShadow {
        switch self {
        case .flush:   return XShadow(radius: 0,  y: 0,  opacity: 0)
        case .resting: return XShadow(radius: 10, y: 3,  opacity: 0.06)
        case .raised:  return XShadow(radius: 20, y: 10, opacity: 0.12)
        case .overlay: return XShadow(radius: 36, y: 18, opacity: 0.20)
        }
    }
}

// MARK: - 动效令牌（统一 spring/曲线语言，收编散落的 spring()/easeInOut()）

/// 一套连贯的动效语言：所有状态变化都从这里取曲线，避免各处随手写不同参数导致
/// 动作「各说各话」。snappy 用于点按/选中，settle 用于入场/布局，celebrate 用于完成庆祝，
/// gauge 用于仪表/进度，crossfade 用于淡入淡出，hover 用于悬停。
public enum XMotion {
    public static let snappy    = Animation.spring(response: 0.30, dampingFraction: 0.72)
    public static let settle    = Animation.spring(response: 0.50, dampingFraction: 0.82)
    public static let celebrate = Animation.spring(response: 0.55, dampingFraction: 0.60)
    public static let gauge     = Animation.easeInOut(duration: 0.50)
    public static let crossfade = Animation.easeInOut(duration: 0.30)
    public static let hover     = Animation.easeOut(duration: 0.12)
}
