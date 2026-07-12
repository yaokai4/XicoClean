import SwiftUI

/// 主题：一组强调色/渐变 token 覆盖。切换主题即换掉全局的品牌渐变、仪表/图表配色、
/// 菜单栏彩色模式——所有读 `XColor.brandGradientColors / ringColors / brand` 的界面自动跟随。
public struct XTheme: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let gradient: [Color]     // 品牌渐变（按钮、图标块、进度）
    public let ring: [Color]         // 仪表/图表默认配色
    public let accent: Color         // 单一强调色（图标、分段标题）
    public let menuBarColored: Bool  // 菜单栏是否用彩色（否则单色模板，深浅栏都清晰）
    /// 菜单栏 GPU / 磁盘 的专属第 5/6 色相（5 指标挤 4 槽 ring 的补位）。
    /// nil = 回退旧行为（GPU 品红 / 磁盘琥珀），旧六套主题零改动。
    public let menuGPU: Color?
    public let menuDisk: Color?
    /// 空间透镜的高饱和色轮（docs/16 P2）：nil = 默认八色（蓝紫玫青琥绿品靛）。
    /// 暖调主题（warmLuxe/jewel）给暖倾向色轮——切主题时环图与全局气质一致，不再割裂。
    public let lensPalette: [Color]?

    public init(id: String, name: String, gradient: [Color], ring: [Color], accent: Color,
                menuBarColored: Bool, menuGPU: Color? = nil, menuDisk: Color? = nil,
                lensPalette: [Color]? = nil) {
        self.id = id
        self.name = name
        self.gradient = gradient
        self.ring = ring
        self.accent = accent
        self.menuBarColored = menuBarColored
        self.menuGPU = menuGPU
        self.menuDisk = menuDisk
        self.lensPalette = lensPalette
    }

    public static func == (a: XTheme, b: XTheme) -> Bool { a.id == b.id }

    // MARK: 内置主题（全部用动态色，自动适配深浅色）

    // 精修 2026-07（用户拍板）：品牌蓝紫基调不变，整体加深一档饱和去「水洗感」，
    // 第三段从淡兰收成深兰——渐变条更有「极光深空」的纵深。
    public static let aurora = XTheme(
        id: "aurora", name: "极光",
        gradient: [XColor.dyn(0x4A6CF2, 0x7C9AF7),   // 深空蓝
                   XColor.dyn(0x7F5FEA, 0xA88DF5),   // 极光紫
                   XColor.dyn(0xB25FDE, 0xCB98F0)],  // 深兰
        ring: [XColor.dyn(0xD9679C, 0xF0A0C6),        // 玫
               XColor.dyn(0x9678E6, 0xBCA4F5),        // 薰衣草
               XColor.dyn(0x5F82EA, 0x9CB2F5),        // 长春花蓝
               XColor.dyn(0x39B5A9, 0x8FE2D5)],       // 薄荷
        accent: XColor.dyn(0x7F5FEA, 0xA88DF5), menuBarColored: false)

    public static let ocean = XTheme(
        id: "ocean", name: "深海",
        gradient: [XColor.dyn(0x2E7BE6, 0x5AA6F5), XColor.dyn(0x2AA9C4, 0x63D3E6), XColor.dyn(0x1FB89B, 0x6FE6C8)],
        ring: [XColor.dyn(0x2E7BE6, 0x6FB2FF), XColor.dyn(0x2AA9C4, 0x76D8EA), XColor.dyn(0x1FB89B, 0x7FEAD0), XColor.dyn(0x4FD1C5, 0xA6F0E6)],
        accent: XColor.dyn(0x2AA9C4, 0x63D3E6), menuBarColored: true)

    // 精修 2026-07：从「橙粉紫糖果」调成「黄金时刻」——琥珀→珊瑚玫→暮色藕紫，
    // 降饱和提质感，末段紫收深与首段拉开明度（原三段等亮读起来是一坨荧光）。
    public static let sunset = XTheme(
        id: "sunset", name: "暖阳",
        gradient: [XColor.dyn(0xE8853B, 0xF7A85C),   // 落日琥珀
                   XColor.dyn(0xE25B6E, 0xF2879A),   // 珊瑚玫
                   XColor.dyn(0x8E5AB8, 0xB98BE0)],  // 暮色藕紫
        ring: [XColor.dyn(0xE0A23C, 0xF5C878),        // 鎏金
               XColor.dyn(0xDD6B3D, 0xF59A70),        // 焦糖橙
               XColor.dyn(0xDD5580, 0xF08FB2),        // 玫瑰
               XColor.dyn(0x9C68C4, 0xC49DE8)],       // 藕紫
        accent: XColor.dyn(0xE25B6E, 0xF2879A), menuBarColored: true)

    // 精修 2026-07：三段近似绿发平——改「松林深绿→祖母绿→青薄荷」，尾段混入青色
    // 让渐变有明确走向；ring 四阶从深绿到雾灰绿拉开明度阶（磷光屏的高级版）。
    public static let terminal = XTheme(
        id: "terminal", name: "终端",
        gradient: [XColor.dyn(0x0E8F5A, 0x2FD08C),   // 松林
                   XColor.dyn(0x12AC7E, 0x3BE0A8),   // 祖母绿
                   XColor.dyn(0x2FBFAE, 0x7BEBD4)],  // 青薄荷
        ring: [XColor.dyn(0x0E9F62, 0x36D992),        // 翠
               XColor.dyn(0x14AE88, 0x3EE3B0),        // 碧
               XColor.dyn(0x27B4A8, 0x66E4D2),        // 青
               XColor.dyn(0x7CC98B, 0xAAE8B8)],       // 雾绿
        accent: XColor.dyn(0x12AC7E, 0x3BE0A8), menuBarColored: true)

    // 精修 2026-07：紫红→兰紫→靛的三段打磨顺滑——首段压一点荧光、尾段靛蓝收沉，
    // 「洋红霓虹」变「紫水晶到午夜」的过渡。
    public static let magenta = XTheme(
        id: "magenta", name: "品红",
        gradient: [XColor.dyn(0xBE3092, 0xEA74C4),   // 紫红
                   XColor.dyn(0x9247D0, 0xBC8AF2),   // 兰紫
                   XColor.dyn(0x5E54D8, 0x939BF5)],  // 靛
        ring: [XColor.dyn(0xDC66A6, 0xF2A6CC),        // 粉玫
               XColor.dyn(0xBE3092, 0xEA74C4),        // 紫红
               XColor.dyn(0x9247D0, 0xBC8AF2),        // 兰紫
               XColor.dyn(0x5E54D8, 0x939BF5)],       // 靛
        accent: XColor.dyn(0xBE3092, 0xEA74C4), menuBarColored: true)

    // 精修 2026-07：灰阶带一缕钢青偏——「枪灰金属」而非「褪色」；
    // ring0 的点缀蓝从品牌蓝换成更克制的钢蓝（石墨主题里品牌蓝太跳）。
    public static let graphite = XTheme(
        id: "graphite", name: "石墨",
        gradient: [XColor.dyn(0x4E586E, 0x8891A6),   // 枪灰
                   XColor.dyn(0x66718A, 0x9AA4BA),   // 钢青灰
                   XColor.dyn(0x8D97AC, 0xB8C1D4)],  // 银灰
        ring: [XColor.dyn(0x5779C9, 0x8CA6E8),        // 钢蓝（点缀）
               XColor.dyn(0x66718A, 0x9AA4BA),
               XColor.dyn(0x8D97AC, 0xB8C1D4),
               XColor.dyn(0xA9B2C4, 0xCBD2E0)],
        accent: XColor.dyn(0x66718A, 0x9AA4BA), menuBarColored: false)

    // MARK: 温暖高级主题（docs/15 设计语言：暖不塌成一坨——推明度别推饱和、
    // 绕开泥黄绿死区(金压在 36–42°)、暖色配现有中性冷墨底、各借一枚冷宝石破红绿盲）。
    // ring 顺序特意排成 ring2=CPU、ring1=内存、ring3=网络（与 metricCPU/Memory/Network 派生对齐），
    // 三指标无需改代码即命中目标色相；GPU/磁盘走 menuGPU/menuDisk 专属第 5/6 色。

    /// 暖阳高级：暖到底，相邻暖色靠亮度分层兜底（琥珀 L0.24 / 赤陶 L0.17 / 莓玫 L0.15）。
    public static let warmLuxe = XTheme(
        id: "warmLuxe", name: "暖阳高级",
        // gradient 精修 2026-07（ring=WCAG 实测菜单色，保持不动）：原三段在预览条上发闷，
        // 提亮为「焦糖金→珊瑚→柔李紫」——暖而透，不塌成棕。
        gradient: [XColor.dyn(0xD8952E, 0xF2BC5C),   // 焦糖金
                   XColor.dyn(0xE06B58, 0xF2957F),   // 珊瑚
                   XColor.dyn(0x9A63B8, 0xC79AE0)],  // 柔李紫
        ring: [XColor.dyn(0xB43F73, 0xEC8FB6),        // ring0 磁盘·上行·wired 莓玫
               XColor.dyn(0xC24E3A, 0xF08A6E),        // ring1 内存 赤陶珊瑚
               XColor.dyn(0xAE7016, 0xF4B54C),        // ring2 CPU 蜜琥珀
               XColor.dyn(0x1E8F7E, 0x63D6BE)],       // ring3 网络 青碧（冷宝石）
        accent: XColor.dyn(0xC96B34, 0xF2A557),        // 焦糖琥珀
        menuBarColored: true,
        menuGPU:  XColor.dyn(0x9A5BB8, 0xC79AE8),      // 菜单栏 GPU 兰紫
        menuDisk: XColor.dyn(0xB43F73, 0xEC8FB6),      // 菜单栏 磁盘 莓玫
        lensPalette: [                                  // 透镜暖调色轮（明度/色相双拉开）
            Color(red: 0.94, green: 0.63, blue: 0.20),  // 琥珀
            Color(red: 0.88, green: 0.38, blue: 0.24),  // 赤陶
            Color(red: 0.88, green: 0.35, blue: 0.54),  // 莓玫
            Color(red: 0.63, green: 0.36, blue: 0.78),  // 兰紫
            Color(red: 0.08, green: 0.70, blue: 0.60),  // 青碧（冷宝石）
            Color(red: 0.91, green: 0.75, blue: 0.29),  // 金
            Color(red: 0.94, green: 0.50, blue: 0.38),  // 珊瑚
            Color(red: 0.72, green: 0.47, blue: 0.85),  // 薄紫
        ])

    /// 珠宝暖调：暖为主 + 全色域宝石，五指标相邻色相 ≥52°（41/342/274/157/222°）——最强可辨。
    public static let jewel = XTheme(
        id: "jewel", name: "珠宝暖调",
        // gradient 精修 2026-07（ring=WCAG 实测菜单色，保持不动）：三宝石提纯——
        // 石榴红更鲜、紫水晶更透、黄玉更金，「红→紫→金」读作珠宝盒而非混浊过渡。
        gradient: [XColor.dyn(0xB3244E, 0xEE7290),   // 石榴红
                   XColor.dyn(0x8A42C2, 0xC494F2),   // 紫水晶
                   XColor.dyn(0xD79A20, 0xF2C55E)],  // 黄玉金
        ring: [XColor.dyn(0x2A5AC8, 0x7FA6F5),        // ring0 磁盘·上行·wired 蓝宝石（冷宝石）
               XColor.dyn(0xB2214C, 0xF0708E),        // ring1 内存 石榴红
               XColor.dyn(0xA6760F, 0xF2C24E),        // ring2 CPU 黄玉
               XColor.dyn(0x0E9260, 0x5CE0A0)],       // ring3 网络 祖母绿（冷宝石）
        accent: XColor.dyn(0xA8264C, 0xE86A88),        // 石榴红（暖珠宝品牌色）
        menuBarColored: true,
        menuGPU:  XColor.dyn(0x7A3EA8, 0xC79AEE),      // 菜单栏 GPU 紫水晶
        menuDisk: XColor.dyn(0x2A5AC8, 0x7FA6F5),      // 菜单栏 磁盘 蓝宝石
        lensPalette: [                                  // 透镜珠宝色轮
            Color(red: 0.16, green: 0.35, blue: 0.78),  // 蓝宝石
            Color(red: 0.85, green: 0.21, blue: 0.37),  // 石榴红
            Color(red: 0.91, green: 0.66, blue: 0.12),  // 黄玉
            Color(red: 0.06, green: 0.66, blue: 0.41),  // 祖母绿
            Color(red: 0.54, green: 0.30, blue: 0.78),  // 紫水晶
            Color(red: 0.88, green: 0.28, blue: 0.28),  // 红玉
            Color(red: 0.09, green: 0.69, blue: 0.72),  // 碧玺
            Color(red: 0.91, green: 0.47, blue: 0.66),  // 蔷薇石英
        ])

    public static let all: [XTheme] = [aurora, ocean, sunset, warmLuxe, jewel, terminal, magenta, graphite]

    public static func byID(_ id: String) -> XTheme { all.first { $0.id == id } ?? aurora }
}

/// 当前主题的全局持有者（@Observable）。XColor 的品牌色读它——SwiftUI 在 body 求值期间
/// 读到 `shared.current` 即自动登记观察依赖，切主题时**只有真正用到主题色的视图**重渲，
/// 不再需要根视图整树重建 hack。
///
/// 不变式：仅在主线程读写（SwiftUI 视图渲染读、设置页切换写、菜单栏绘制读）——与 SwiftUI
/// 的主线程渲染模型一致，无跨线程竞态，故 @unchecked Sendable 安全。
@Observable
public final class XThemeStore: @unchecked Sendable {
    public static let shared = XThemeStore()
    public var current: XTheme = .aurora
    private init() {}
}
