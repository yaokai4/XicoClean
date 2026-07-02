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

    public init(id: String, name: String, gradient: [Color], ring: [Color], accent: Color, menuBarColored: Bool) {
        self.id = id
        self.name = name
        self.gradient = gradient
        self.ring = ring
        self.accent = accent
        self.menuBarColored = menuBarColored
    }

    public static func == (a: XTheme, b: XTheme) -> Bool { a.id == b.id }

    // MARK: 内置主题（全部用动态色，自动适配深浅色）

    public static let aurora = XTheme(
        id: "aurora", name: "极光",
        gradient: [XColor.auroraBlue, XColor.auroraViolet, XColor.auroraOrchid],
        ring: [XColor.ringRose, XColor.ringLav, XColor.ringPeri, XColor.ringMint],
        accent: XColor.auroraViolet, menuBarColored: false)

    public static let ocean = XTheme(
        id: "ocean", name: "深海",
        gradient: [XColor.dyn(0x2E7BE6, 0x5AA6F5), XColor.dyn(0x2AA9C4, 0x63D3E6), XColor.dyn(0x1FB89B, 0x6FE6C8)],
        ring: [XColor.dyn(0x2E7BE6, 0x6FB2FF), XColor.dyn(0x2AA9C4, 0x76D8EA), XColor.dyn(0x1FB89B, 0x7FEAD0), XColor.dyn(0x4FD1C5, 0xA6F0E6)],
        accent: XColor.dyn(0x2AA9C4, 0x63D3E6), menuBarColored: true)

    public static let sunset = XTheme(
        id: "sunset", name: "暖阳",
        gradient: [XColor.dyn(0xF2762E, 0xFF9B57), XColor.dyn(0xE8578A, 0xFF89B4), XColor.dyn(0xC85CD8, 0xDC9AEC)],
        ring: [XColor.dyn(0xF2A03E, 0xFFC46B), XColor.dyn(0xF2762E, 0xFF9B57), XColor.dyn(0xE8578A, 0xFF89B4), XColor.dyn(0xC85CD8, 0xDC9AEC)],
        accent: XColor.dyn(0xE8578A, 0xFF89B4), menuBarColored: true)

    public static let terminal = XTheme(
        id: "terminal", name: "终端",
        gradient: [XColor.dyn(0x1FA35A, 0x37D989), XColor.dyn(0x1FB87A, 0x35DEA0), XColor.dyn(0x4FD1B5, 0x7FEAD0)],
        ring: [XColor.dyn(0x1FA35A, 0x37D989), XColor.dyn(0x1FB87A, 0x35DEA0), XColor.dyn(0x4FD1B5, 0x7FEAD0), XColor.dyn(0x9BE8A8, 0xB8F0C2)],
        accent: XColor.dyn(0x1FB87A, 0x35DEA0), menuBarColored: true)

    public static let magenta = XTheme(
        id: "magenta", name: "品红",
        gradient: [XColor.dyn(0xC2379E, 0xE86FC0), XColor.dyn(0x9B4BD8, 0xB884F0), XColor.dyn(0x6C5CE0, 0x9A8FF0)],
        ring: [XColor.dyn(0xE070AC, 0xF0A8CE), XColor.dyn(0xC2379E, 0xE86FC0), XColor.dyn(0x9B4BD8, 0xB884F0), XColor.dyn(0x6C5CE0, 0x9A8FF0)],
        accent: XColor.dyn(0xC2379E, 0xE86FC0), menuBarColored: true)

    public static let graphite = XTheme(
        id: "graphite", name: "石墨",
        gradient: [XColor.dyn(0x596274, 0x8A93A8), XColor.dyn(0x6E7688, 0x9AA3B8), XColor.dyn(0x8A93A8, 0xB4BCCE)],
        ring: [XColor.dyn(0x5478F0, 0x7C97F2), XColor.dyn(0x6E7688, 0x9AA3B8), XColor.dyn(0x8A93A8, 0xB4BCCE), XColor.dyn(0xA6AEC0, 0xC8CFDC)],
        accent: XColor.dyn(0x6E7688, 0x9AA3B8), menuBarColored: false)

    public static let all: [XTheme] = [aurora, ocean, sunset, terminal, magenta, graphite]

    public static func byID(_ id: String) -> XTheme { all.first { $0.id == id } ?? aurora }
}

/// 当前主题的全局持有者。XColor 的品牌色读它；切换时更新此值并触发根视图重渲。
///
/// 不变式：仅在主线程读写（SwiftUI 视图渲染读、设置页切换写），故用 nonisolated(unsafe)
/// 免除 actor 隔离——与 SwiftUI 的主线程渲染模型一致，无跨线程竞态。
public enum XThemeStore {
    nonisolated(unsafe) public static var current: XTheme = .aurora
}
