import SwiftUI
import AppKit
import Infrastructure
import DesignSystem
import Features

// 离屏实时快照/探针工具仅供 QA 与本地调试使用，整体只编进 DEBUG 构建——
// 约 600 行离屏渲染脚手架绝不随发布包出货（调度入口在 XicoApp.swift 同样 #if DEBUG 门控）。
#if DEBUG

/// 渲染需要实时数据的页面（硬件 / 监视）：把视图挂进真实离屏窗口，
/// 让其 onAppear 定时器与异步加载跑起来，等数据填充后再位图快照。
/// 用法：Xico --liveshots
@MainActor
func renderLiveShots() {
    let env = XicoEnvironment.live()
    let dir = URL(fileURLWithPath: "/tmp/xico-shots")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

    let model = AppModel(env: env)
    model.refreshMetrics()
    model.startMetricsTimer()

    let pages: [(String, AnyView, CGSize)] = [
        ("10-hardware", AnyView(HardwareView(env: env)), CGSize(width: 1120, height: 820)),
        ("11-monitor", AnyView(MonitorView(env: env)), CGSize(width: 1120, height: 820)),
        ("12-menu-cpu", AnyView(panelBG { MenuMetricPanel(model: model, metric: .cpu) }), CGSize(width: 320, height: 560)),
        ("13-menu-memory", AnyView(panelBG { MenuMetricPanel(model: model, metric: .memory) }), CGSize(width: 320, height: 560)),
        ("14-menu-network", AnyView(panelBG { MenuMetricPanel(model: model, metric: .network) }), CGSize(width: 320, height: 320)),
        ("22-menu-temp", AnyView(panelBG { MenuMetricPanel(model: model, metric: .temperature) }), CGSize(width: 320, height: 560)),
        ("23-menu-disk", AnyView(panelBG { MenuMetricPanel(model: model, metric: .disk) }), CGSize(width: 320, height: 480)),
        ("24-spacelens-idle", AnyView(SpaceLensView(env: env)), CGSize(width: 1080, height: 720)),
        ("25-diskbench", AnyView(DiskBenchmarkView(device: "APPLE SSD AP0512Q", standalone: true)), CGSize(width: 1080, height: 720)),
        ("26-menu-gpu", AnyView(panelBG { MenuMetricPanel(model: model, metric: .gpu) }), CGSize(width: 320, height: 400)),
        ("15-settings", AnyView(SettingsView(model: model).environmentObject(model)), CGSize(width: 900, height: 1180)),
        ("18-pricing", AnyView(PricingView(model: model)), CGSize(width: 760, height: 720)),
        ("20-dashboard", AnyView(SmartScanView(model: model)), CGSize(width: 900, height: 820))
    ]

    // 网络详情页（对标 iStat 网络面板）
    let netVM = NetworkViewModel(service: env.network)
    netVM.start()
    let netDeadline = Date().addingTimeInterval(3.5)
    while Date() < netDeadline { RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.1)) }
    for scheme in [ColorScheme.dark, ColorScheme.light] {
        renderPage(name: "19-network", view: AnyView(
            ScrollView { NetworkView(vm: netVM, history: []).padding(24) }),
            size: CGSize(width: 1120, height: 900), dir: dir, scheme: scheme)
    }
    netVM.stop()

    // 用 ocean 主题渲染一张监视页，验证主题切换真实生效
    XThemeStore.shared.current = .ocean
    renderPage(name: "16-monitor-ocean", view: AnyView(MonitorView(env: env)),
               size: CGSize(width: 1120, height: 820), dir: dir, scheme: .dark)
    XThemeStore.shared.current = .sunset
    renderPage(name: "17-hardware-sunset", view: AnyView(HardwareView(env: env)),
               size: CGSize(width: 1120, height: 820), dir: dir, scheme: .dark)
    XThemeStore.shared.current = .aurora

    // 监视页 · CPU 标签（每核心历史热力图 + 传感器中心）——验证 R1 / R5。
    UserDefaults.standard.set("heat", forKey: "xico.monitor.coreViz")
    renderPage(name: "21-monitor-cpu-heat", view: AnyView(MonitorView(env: env, initialTab: .cpu)),
               size: CGSize(width: 1120, height: 1100), dir: dir, scheme: .dark)

    for scheme in [ColorScheme.dark, ColorScheme.light] {
        let suffix = scheme == .dark ? "dark" : "light"
        for (name, view, size) in pages {
            let root = ZStack { AppBackground(); view }
                .frame(width: size.width, height: size.height)
                .environment(\.colorScheme, scheme)
                .environment(\.locale, XLocale.swiftUILocale)

            let hosting = NSHostingView(rootView: root)
            hosting.frame = NSRect(x: 0, y: 0, width: size.width, height: size.height)
            let window = NSWindow(contentRect: hosting.frame,
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
            window.contentView = hosting
            window.orderFront(nil)         // 触发 onAppear
            window.setFrameOrigin(NSPoint(x: -3000, y: -3000))  // 挪到屏幕外

            // 让定时器/异步采样跑 ~3 秒填充数据
            let deadline = Date().addingTimeInterval(3.0)
            while Date() < deadline {
                RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.1))
            }

            if let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) {
                hosting.cacheDisplay(in: hosting.bounds, to: rep)
                if let png = rep.representation(using: .png, properties: [:]) {
                    try? png.write(to: dir.appendingPathComponent("\(name)-\(suffix).png"))
                }
            }
            window.orderOut(nil)
        }
    }
    FileHandle.standardError.write("rendered live shots to \(dir.path)\n".data(using: .utf8)!)
}

/// 渲染单页（供主题验证等临时快照复用）。
@MainActor
private func renderPage(name: String, view: AnyView, size: CGSize, dir: URL, scheme: ColorScheme) {
    let root = ZStack { AppBackground(); view }
        .frame(width: size.width, height: size.height)
        .environment(\.colorScheme, scheme)
    let hosting = NSHostingView(rootView: root)
    hosting.frame = NSRect(x: 0, y: 0, width: size.width, height: size.height)
    let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
    window.contentView = hosting
    window.orderFront(nil)
    window.setFrameOrigin(NSPoint(x: -3000, y: -3000))
    let deadline = Date().addingTimeInterval(3.0)
    while Date() < deadline { RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.1)) }
    if let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) {
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        if let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: dir.appendingPathComponent("\(name)-\(scheme == .dark ? "dark" : "light").png"))
        }
    }
    window.orderOut(nil)
}

/// 菜单栏面板的容器背景（模拟弹窗材质）。
@MainActor
private func panelBG<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
    content()
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(XColor.surface))
        .padding(XSpacing.l)
}

#endif
