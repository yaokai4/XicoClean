import SwiftUI
import AppKit
import Domain
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

/// Precision Monitoring focused QA: exact six-state evidence set at the production 336 pt width.
/// Live panels receive two full one-second sampling intervals after attachment; degraded-state
/// panels use deterministic DEBUG fixtures and settle before the stale threshold.
@MainActor
func renderMonitoringShots() {
    let dir = URL(fileURLWithPath: "/tmp/xico-monitoring-shots")
    try? FileManager.default.removeItem(at: dir)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

    let defaults = UserDefaults.standard
    let controlledKeys = [
        MonitoringPreferences.refreshIntervalKey,
        MonitoringPreferences.processLimitKey,
        MonitoringPreferences.densityKey,
    ]
    let savedDefaults = Dictionary(uniqueKeysWithValues: controlledKeys.map { ($0, defaults.object(forKey: $0)) })
    defer {
        for key in controlledKeys {
            if let value = savedDefaults[key] ?? nil { defaults.set(value, forKey: key) }
            else { defaults.removeObject(forKey: key) }
        }
    }
    MonitoringPreferences.setRefreshInterval(.oneSecond)
    defaults.set(4, forKey: MonitoringPreferences.processLimitKey)
    defaults.set(MonitoringPanelDensity.balanced.rawValue, forKey: MonitoringPreferences.densityKey)

    let env = XicoEnvironment.live()
    // AppModel starts an asynchronous steady-state sample during init. The screenshot command
    // immediately switches to a detail consumer, so that request can be coalesced by the
    // single-flight guard while the CurrentValueSubject is still nil. Seed one real, warmed
    // system frame synchronously so every off-screen panel attaches with renderable content;
    // the normal application sampler continues to populate rankings at 1 Hz below.
    let seedSampler = LiveMetricsSampler()
    _ = seedSampler.sample(consumerVisible: true, scope: .extendedHardware)
    Thread.sleep(forTimeInterval: 0.15)
    let seedSnapshot = seedSampler.sample(consumerVisible: true, scope: .extendedHardware)
    let liveModel = AppModel(env: env)
    liveModel.liveMetricsFeed.publish(snapshot: seedSnapshot, notifyUI: true)
    liveModel.setMetricsDetailConsumerVisible(true)
    liveModel.startMetricsTimer()

    // Capture the same production application pipeline explicitly for the QA artifact. The
    // first frame establishes CPU baselines; the second frame, one configured interval later,
    // contains valid CPU plus current memory rankings.
    let shotProcessSampler = ProcessSampler.production()
    var capturedApplicationUsage: ApplicationUsageSnapshot?
    Task {
        let epoch = await shotProcessSampler.resetBaseline()
        _ = await shotProcessSampler.sample(
            limit: 4,
            combinesProcesses: MonitoringPreferences.combinesProcesses(),
            requiringBaselineEpoch: epoch)
        try? await Task.sleep(nanoseconds: 1_050_000_000)
        capturedApplicationUsage = await shotProcessSampler.sample(
            limit: 4,
            combinesProcesses: MonitoringPreferences.combinesProcesses(),
            requiringBaselineEpoch: epoch)
    }
    let applicationDeadline = Date().addingTimeInterval(4)
    while capturedApplicationUsage == nil, Date() < applicationDeadline {
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
    }

    let liveShots: [(String, MenuMetric, ColorScheme)] = [
        ("cpu-dark", .cpu, .dark),
        ("cpu-light", .cpu, .light),
        ("memory-dark", .memory, .dark),
        ("memory-light", .memory, .light),
    ]
    for (name, metric, scheme) in liveShots {
        if let usage = capturedApplicationUsage {
            liveModel.liveMetricsFeed.applicationUsage = ApplicationUsageSnapshot(
                byCPU: usage.byCPU,
                byMemory: usage.byMemory,
                status: usage.status,
                coverage: usage.coverage,
                sampledAt: Date(),
                source: usage.source)
            liveModel.liveMetricsFeed.objectWillChange.send()
        }
        renderMonitoringPage(
            name: name,
            model: liveModel,
            metric: metric,
            scheme: scheme,
            settle: 0.35,
            directory: dir)
    }

    let fixtureModel = AppModel(env: env)
    fixtureModel.liveMetricsFeed.publish(snapshot: seedSnapshot, notifyUI: true)
    fixtureModel.refreshMetrics()
    let systemDeadline = Date().addingTimeInterval(3)
    while fixtureModel.liveSnapshot == nil, Date() < systemDeadline {
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
    }

    let atlasWarming = ApplicationUsage.monitoringFixture(
        id: "atlas-warming", name: "Atlas Studio", cpuRaw: nil, cpuNormalized: nil,
        memory: 1_820_000_000, memberCount: 3)
    let safariWarming = ApplicationUsage.monitoringFixture(
        id: "safari-warming", name: "Safari", cpuRaw: nil, cpuNormalized: nil,
        memory: 780_000_000, memberCount: 2)
    fixtureModel.liveMetricsFeed.applicationUsage = ApplicationUsageSnapshot(
        byCPU: [],
        byMemory: [atlasWarming, safariWarming],
        status: .warmingUp,
        coverage: ProcessCoverage(enumerated: 96, sampled: 0, denied: 0, exited: 0),
        sampledAt: Date(),
        source: .local)
    fixtureModel.liveMetricsFeed.objectWillChange.send()
    renderMonitoringPage(
        name: "cpu-warming-dark",
        model: fixtureModel,
        metric: .cpu,
        scheme: .dark,
        settle: 0.35,
        directory: dir)

    let xcode = ApplicationUsage.monitoringFixture(
        id: "xcode", name: "Xcode", cpuRaw: 112, cpuNormalized: 14,
        memory: 3_240_000_000, memberCount: 4)
    let atlas = ApplicationUsage.monitoringFixture(
        id: "atlas", name: "Atlas Studio", cpuRaw: 56, cpuNormalized: 7,
        memory: 1_860_000_000, memberCount: 3)
    let safari = ApplicationUsage.monitoringFixture(
        id: "safari", name: "Safari", cpuRaw: 24, cpuNormalized: 3,
        memory: 920_000_000, memberCount: 2)
    let partial = ApplicationUsageSnapshot(
        byCPU: [xcode, atlas, safari],
        byMemory: [xcode, atlas, safari],
        status: .partial,
        coverage: ProcessCoverage(enumerated: 100, sampled: 76, denied: 24, exited: 0),
        sampledAt: Date(),
        source: .helperEnhanced)
    fixtureModel.liveMetricsFeed.applicationUsage = partial
    fixtureModel.liveMetricsFeed.objectWillChange.send()
    renderMonitoringPage(
        name: "memory-partial-dark",
        model: fixtureModel,
        metric: .memory,
        scheme: .dark,
        settle: 0.35,
        directory: dir)

    liveModel.setMetricsDetailConsumerVisible(false)
    FileHandle.standardError.write("rendered monitoring shots to \(dir.path)\n".data(using: .utf8)!)
}

@MainActor
private func renderMonitoringPage(
    name: String,
    model: AppModel,
    metric: MenuMetric,
    scheme: ColorScheme,
    settle: TimeInterval,
    directory: URL
) {
    let height: CGFloat
    if metric == .memory { height = 820 }
    else if name.contains("warming") { height = 520 }
    else { height = 736 }
    let size = CGSize(width: 336, height: height)
    let panel = MenuMetricPanel(model: model, metric: metric)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(XColor.surface))
    let root = ZStack(alignment: .top) {
        AppBackground()
        panel
    }
    .frame(width: size.width, height: size.height, alignment: .top)
    .clipped()
    .environment(\.colorScheme, scheme)
    .environment(\.locale, XLocale.swiftUILocale)
    .tint(XColor.brand)
    .accentColor(XColor.brand)

    let hosting = NSHostingView(rootView: root)
    hosting.frame = NSRect(origin: .zero, size: size)
    let window = NSWindow(
        contentRect: hosting.frame,
        styleMask: [.borderless],
        backing: .buffered,
        defer: false)
    window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
    window.contentView = hosting
    window.setFrameOrigin(NSPoint(x: -4_000, y: -4_000))
    window.orderFront(nil)

    let deadline = Date().addingTimeInterval(settle)
    while Date() < deadline {
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
    }
    hosting.layoutSubtreeIfNeeded()
    if let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) {
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        if let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: directory.appendingPathComponent("\(name).png"))
        }
    }
    window.orderOut(nil)
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
