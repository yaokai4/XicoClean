import SwiftUI
import AppKit
import Domain
import Infrastructure
import DesignSystem
import Features

/// 离屏渲染「侧边栏 + 首页仪表盘」组合，用于在无法点击驱动时验证整体布局与配色。
/// 用法：Xico --layout  → 输出到 /tmp/xico-shots/layout-*.png
@MainActor
func renderLayout() {
    let env = XicoEnvironment.live()
    let model = AppModel(env: env)
    model.refreshMetrics()
    model.refreshMetrics()
    let dir = URL(fileURLWithPath: "/tmp/xico-shots")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

    func write(_ view: some View, _ name: String, scheme: ColorScheme, width: CGFloat, height: CGFloat) {
        let wrapped = view
            .frame(width: width, height: height)
            .environment(\.colorScheme, scheme)
            .environmentObject(model)
        let renderer = ImageRenderer(content: wrapped)
        renderer.scale = 2
        guard let img = renderer.nsImage, let tiff = img.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: dir.appendingPathComponent(name))
    }

    for scheme in [ColorScheme.dark, .light] {
        let s = scheme == .dark ? "dark" : "light"
        // 侧边栏单独渲染（真实宽度；scrolls:false 让离屏能画出导航条目）
        write(SidebarView(scrolls: false), "layout-sidebar-\(s).png", scheme: scheme, width: 248, height: 760)
        // 首页仪表盘（含背景）
        let home = ZStack { AppBackground(); SmartScanView(model: model) }
        write(home, "layout-home-\(s).png", scheme: scheme, width: 900, height: 760)
        // 组合：侧边栏 + 首页并排（近似真实窗口）
        let combined = HStack(spacing: 0) {
            SidebarView(scrolls: false).frame(width: 248)
            ZStack { AppBackground(); SmartScanView(model: model) }
        }
        write(combined, "layout-full-\(s).png", scheme: scheme, width: 1180, height: 760)
    }
    // 组件对比：扁平染色图标砖 vs 渐变砖 + 卡片头样例（验证 flat-first 观感）
    for scheme in [ColorScheme.dark, .light] {
        let s = scheme == .dark ? "dark" : "light"
        let sample = VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 14) {
                XIconTile(systemImage: "cpu", colors: [XColor.auroraBlue, XColor.auroraViolet], size: 28, flat: true)
                XIconTile(systemImage: "memorychip", colors: [XColor.accentTeal, XColor.auroraBlue], size: 28, flat: true)
                XIconTile(systemImage: "thermometer.medium", colors: [XColor.warning, XColor.accentPink], size: 28, flat: true)
                XIconTile(systemImage: "internaldrive", colors: XColor.brandGradientColors, size: 52)
            }
            XCard {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 8) {
                        XIconTile(systemImage: "waveform.path.ecg", colors: XColor.brandGradientColors, size: 28, flat: true)
                        Text("HISTORY").font(XFont.captionEmphasis).foregroundStyle(XColor.textSecondary).tracking(0.6)
                        Spacer()
                    }
                    Text("扁平染色卡片头 · flat icon tile header").font(XFont.caption).foregroundStyle(XColor.textSecondary)
                }
            }
        }
        .padding(28)
        write(ZStack { AppBackground(); sample }, "layout-components-\(s).png", scheme: scheme, width: 520, height: 300)
    }

    FileHandle.standardError.write("layout rendered to \(dir.path)\n".data(using: .utf8)!)
}
