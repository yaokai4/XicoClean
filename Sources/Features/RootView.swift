import SwiftUI
import AppKit
import Domain
import Infrastructure
import DesignSystem

public struct RootView: View {
    @ObservedObject var model: AppModel

    public init(model: AppModel) { self.model = model }

    public var body: some View {
        ZStack {
            NavigationSplitView {
                SidebarView()
                    .environmentObject(model)
                    .navigationSplitViewColumnWidth(min: 232, ideal: 248, max: 300)
            } detail: {
                DetailView()
                    .environmentObject(model)
            }
            // 语言切换时文案来自静态查表（XLocale），SwiftUI 无法追踪——仍需 .id 重建。
            // 主题已走 @Observable XThemeStore：body 里读到主题色的视图自动登记依赖、
            // 精准重渲，不再整树重建（P1 主题架构现代化）。
            .id(model.language.rawValue)
            .environment(\.locale, XLocale.swiftUILocale)   // .relative 日期/数字等跟随 App 语言
            .transition(.opacity)

            if model.showOnboarding {
                OnboardingView(model: model)
                    .transition(.opacity)
                    .zIndex(1)
            }
        }
        // 最小高度降到 640：小尺寸/低分屏（如 1280×800 扣掉菜单栏+程序坞）也能完整容纳窗口；
        // 各繁忙页（设置 / 结果操作条）内部本就带 ScrollView，可在此下限内正常滚动（审计 RootView:34 P3）。
        .frame(minWidth: 1080, minHeight: 640)
        .animation(XMotion.crossfade, value: model.themeID)   // 换主题时整树平滑淡入（XMotion.crossfade）
        .preferredColorScheme(model.appearance.colorScheme)
        .sheet(isPresented: $model.showPricing) { PricingView(model: model) }
        .onAppear { model.startMetricsTimer() }
        .onReceive(NotificationCenter.default.publisher(for: .xicoOpenSettings)) { _ in
            withAnimation(XMotion.snappy) {
                model.selection = .settings
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .xicoShowPricing)) { _ in
            model.showPricing = true
        }
    }
}

// MARK: - 外观切换器（浅 / 深 / 自动）

struct AppearanceToggle: View {
    @Binding var appearance: AppAppearance
    var body: some View {
        HStack(spacing: 2) {
            ForEach(AppAppearance.allCases) { a in
                Button {
                    withAnimation(XMotion.snappy) { appearance = a }
                } label: {
                    Image(systemName: a.icon)
                        .font(XFont.captionEmphasis)
                        .frame(width: 30, height: 22)
                        // 选中段用扁平品牌染色 + 品牌色图标（呼应侧栏选中态），不再是白字彩色渐变小胶囊。
                        .foregroundStyle(appearance == a ? AnyShapeStyle(XColor.brand)
                                                         : AnyShapeStyle(XColor.textSecondary))
                        .background(
                            Capsule().fill(appearance == a ? AnyShapeStyle(XColor.brand.opacity(XAlpha.tint))
                                                           : AnyShapeStyle(Color.clear))
                        )
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(xLoc(a.label))
                .accessibilityAddTraits(appearance == a ? [.isButton, .isSelected] : .isButton)
            }
        }
        .padding(3)
        .background(XColor.surfaceAlt.opacity(0.6), in: Capsule())
        .overlay(Capsule().strokeBorder(XColor.border.opacity(0.6), lineWidth: 1))
    }
}

// MARK: - 侧边栏（自定义高级样式）

public struct SidebarView: View {
    @EnvironmentObject var model: AppModel
    /// 离屏截图时置 false 跳过 ScrollView（ImageRenderer 不渲染滚动内容）；正常运行恒为 true。
    var scrolls: Bool
    public init(scrolls: Bool = true) { self.scrolls = scrolls }

    public var body: some View {
        VStack(spacing: 0) {
            brandHeader
            if scrolls {
                ScrollView { navList }
            } else {
                navList
            }
            diskFooter
        }
        .background(
            // 真 vibrancy 侧栏（P1 材质层）：behindWindow 透出桌面壁纸，与 Finder/系统设置同质感；
            // 上面压一层极淡 sidebar 色统一品牌冷调。右缘发丝线保留。
            // Reduce Transparency 时 NSVisualEffectView 自动退化为实底，无需分支。
            VisualEffectBackground(material: .sidebar, blending: .behindWindow)
                .overlay(XColor.sidebar.opacity(0.35))
                .overlay(Rectangle().fill(XColor.hairline).frame(width: 1), alignment: .trailing)
                .ignoresSafeArea()
        )
    }

    private var navList: some View {
        VStack(alignment: .leading, spacing: XSpacing.l) {
            ForEach(Array(ModuleCatalog.grouped().enumerated()), id: \.element.0) { catIndex, pair in
                let (category, modules) = pair
                VStack(alignment: .leading, spacing: 2) {
                    Text(xLoc(category.title))
                        .xSectionLabel()
                        .foregroundStyle(XColor.textTertiary)
                        .padding(.leading, XSpacing.m)
                        .padding(.bottom, 3)
                    ForEach(modules) { meta in
                        SidebarTile(meta: meta, tint: Self.categoryTint(catIndex),
                                    selected: model.selection == meta.id) {
                            withAnimation(XMotion.snappy) {
                                model.selection = meta.id
                            }
                        }
                    }
                }
            }
        }
        .padding(.horizontal, XSpacing.s)
        .padding(.top, XSpacing.s)
        .padding(.bottom, XSpacing.l)
    }

    /// 每个分类一族色（CleanMyMac 式彩色侧栏图标——图标即导航地标，一眼定位分区）。
    static func categoryTint(_ index: Int) -> Color {
        let palette: [Color] = [
            Color(red: 0.09, green: 0.72, blue: 0.65),   // 清理 · 青
            Color(red: 0.24, green: 0.48, blue: 0.95),   // 应用 · 蓝
            Color(red: 0.55, green: 0.36, blue: 0.96),   // 文件与空间 · 紫
            Color(red: 0.96, green: 0.55, blue: 0.11),   // 性能与安全 · 橙
            Color(red: 0.91, green: 0.32, blue: 0.49),   // 硬件/监控 · 玫红
            Color(red: 0.13, green: 0.73, blue: 0.27),   // 其余 · 绿
        ]
        return palette[index % palette.count]
    }

    private var brandHeader: some View {
        // 品牌抬头：更大的极光 X 徽 + 柔光，整体上移贴近红绿灯区（用户拍板）。
        HStack(spacing: XSpacing.s + 2) {
            XBrandMark(size: 34)
                .xGlow(XColor.brand, radius: 12)
            Text("Xico").font(XFont.wordmark)   // 品牌字标专用令牌（此前散落 22pt/28pt 三种写法，审计 P2）
                .foregroundStyle(XColor.textPrimary)
                .tracking(0.2)
            Spacer()
        }
        .padding(.horizontal, XSpacing.m)
        .padding(.top, 24)
        .padding(.bottom, XSpacing.s)
    }

    private var diskFooter: some View {
        VStack(alignment: .leading, spacing: XSpacing.s) {
            // 容量来自高频采样的 MetricsFeed（AppModel 不随 tick 重发布），故这里直接观察 feed，
            // 否则侧栏只观察 AppModel 会读到「转发但不刷新」的陈旧容量（审计 RootView:152 P3）。
            SidebarDiskGauge(feed: model.liveMetricsFeed)
            HStack {
                AppearanceToggle(appearance: $model.appearance)
                Spacer()
                Button { model.selection = .settings } label: {
                    Image(systemName: "gearshape.fill")
                        .font(XFont.bodyEmphasis)
                        .foregroundStyle(model.selection == .settings ? XColor.brand : XColor.textSecondary)
                        .frame(width: 28, height: 28)
                        .background(model.selection == .settings ? XColor.surfaceHover : .clear, in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(xLoc("设置"))
            }
            .padding(.top, 2)
        }
        .padding(XSpacing.m)
        .overlay(Rectangle().fill(XColor.hairline).frame(height: 1), alignment: .top)
    }
}

/// 侧栏底部磁盘容量条——单独观察 MetricsFeed，让容量随高频采样实时更新，
/// 而不必让整个 SidebarView 订阅 feed（避免侧栏每 tick 重排）。数据未就绪时不渲染。
private struct SidebarDiskGauge: View {
    @ObservedObject var feed: MetricsFeed
    var body: some View {
        if let cap = feed.capacity {
            HStack {
                Text(xLoc("磁盘")).font(XFont.captionEmphasis).foregroundStyle(XColor.textSecondary)
                Spacer()
                Text(xLocF("%@ 可用", cap.available.formattedBytes)).font(XFont.caption).foregroundStyle(XColor.textSecondary)
            }
            XDiskBar(usedFraction: cap.usedFraction, label: "", height: 8)
        }
    }
}

struct SidebarTile: View {
    let meta: ModuleMetadata
    var tint: Color = XColor.brand
    let selected: Bool
    let action: () -> Void
    @State private var hover = false
    @FocusState private var focused: Bool

    var body: some View {
        Button(action: action) {
            HStack(spacing: XSpacing.s + 2) {
                // 彩色迷你瓦片（CleanMyMac/系统设置式）：分类色小方块 + 白字形——
                // 侧栏不再是一列灰图标，图标本身成为导航地标。选中时微亮。
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(LinearGradient(colors: [tint, tint.opacity(0.82)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 22, height: 22)
                    .overlay(
                        Image(systemName: meta.systemImage)
                            .font(XFont.captionEmphasis)
                            .foregroundStyle(.white)
                    )
                    .opacity(selected || hover ? 1 : 0.88)
                    .shadow(color: tint.opacity(selected ? 0.35 : 0), radius: 4, y: 1)
                Text(xLoc(meta.title))
                    // 字号恒定 13.5pt（随 Dynamic Type 缩放），仅字重随选中变化，杜绝选中放大导致的重排。
                    .xNavLabel(selected: selected)
                    .foregroundStyle(selected ? XColor.textPrimary : XColor.textSecondary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, XSpacing.s + 2)
            .padding(.vertical, 8)
            .background(
                // 选中：极淡品牌染色底 + 左侧品牌指示条（原生高级做法），
                // 取代原「饱和渐变发光块」的 web-app 廉价感。
                RoundedRectangle(cornerRadius: XRadius.tile, style: .continuous)
                    .fill(selected ? AnyShapeStyle(XColor.brand.opacity(XAlpha.tint))
                                   : AnyShapeStyle(hover ? XColor.surfaceHover : Color.clear))
            )
            .overlay(alignment: .leading) {
                if selected {
                    Capsule(style: .continuous)
                        .fill(XColor.brandGradient)
                        .frame(width: 3, height: 16)
                        .padding(.leading, 3)
                }
            }
            // 键盘焦点环（Tab 导航时可见），达成全键盘可达。
            .overlay(
                RoundedRectangle(cornerRadius: XRadius.tile, style: .continuous)
                    .strokeBorder(focused ? XColor.brand : .clear, lineWidth: 2)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focused($focused)
        .onHover { hover = $0 }
        .accessibilityLabel(xLoc(meta.title))
        .accessibilityHint(xLoc(meta.subtitle))
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}

// MARK: - 详情区

struct DetailView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        ZStack {
            AppBackground()
            VStack(spacing: 0) {
                if model.showPermissionBanner {
                    PermissionBanner().environmentObject(model)
                }
                if model.showLicenseBanner {
                    LicenseBanner().environmentObject(model)
                }
                page
                    .id(model.selection)
                    .transition(.opacity.combined(with: .offset(y: 8)))
            }
            .animation(XMotion.crossfade, value: model.selection)
        }
        // macOS 26：数据密集工具类用 .hard 分割线式滚动边缘（低版本 no-op，见 XSurface）。
        .xHardScrollEdges()
    }

    @ViewBuilder private var page: some View {
        switch model.selection ?? .smartScan {
        case .smartScan:    SmartScanView(model: model)
        case .systemJunk:   ModuleScanView(model: model, moduleID: .systemJunk, intent: .trash)
        case .largeFiles:   ModuleScanView(model: model, moduleID: .largeFiles, intent: .trash)
        case .trash:        ModuleScanView(model: model, moduleID: .trash, intent: .permanent)
        // 空间透镜 / 重复文件 / 卸载器改由 AppModel 缓存会话注入，切换侧栏再回来不丢结果（审计 P2）。
        case .spaceLens:    SpaceLensView(model: model)
        case .duplicates:   DuplicatesView(model: model)
        case .similarImages: SimilarImagesView(model: model)
        case .shredder:     ShredderView(env: model.env)
        case .uninstaller:  UninstallerView(model: model)
        case .appUpdater:   AppUpdaterView(env: model.env)
        // 隐私已并入智能扫描；老用户持久化的选中项仍可正常打开
        case .privacy:      ModuleScanView(model: model, moduleID: .privacy, intent: .trash)
        case .optimization: OptimizationView(env: model.env, feed: model.liveMetricsFeed)
        case .maintenance:  MaintenanceView(env: model.env)
        case .malware:      ModuleScanView(model: model, moduleID: .malware, intent: .trash)
        case .diskSpeed:    DiskBenchmarkView(device: internalDiskModel, standalone: true)
        case .hardware:     HardwareView(env: model.env)
        case .monitor:      MonitorView(env: model.env)
        case .settings:     SettingsView(model: model)
        // 未知模块 ID（例如开发用 --open=<拼写错误>）回落到仪表盘，而非过时的「即将推出」占位页。
        default:            SmartScanView(model: model)
        }
    }

    /// 内置盘型号（磁盘测速页抬头）；后台采样未就绪时回落系统卷名。
    private var internalDiskModel: String {
        model.storageVolumes.first(where: { $0.isInternal })
            .map { $0.model.isEmpty ? $0.name : $0.model } ?? "Macintosh HD"
    }
}

struct LicenseBanner: View {
    @EnvironmentObject var model: AppModel
    @State private var hover = false

    var body: some View {
        HStack(spacing: XSpacing.m) {
            XIconTile(systemImage: "checkmark.seal.fill", colors: [XColor.warning, XColor.accentPink], size: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(xLoc("需要有效许可证"))
                    .font(XFont.bodyEmphasis).foregroundStyle(XColor.textPrimary)
                Text(model.licenseStatus?.summary ?? xLoc("请在设置中导入有效许可证后继续。"))
                    .font(XFont.caption).foregroundStyle(XColor.textSecondary)
            }
            Spacer()
            Button(xLoc("升级")) { model.showPricing = true }
                .buttonStyle(XPrimaryButtonStyle())
            Button(xLoc("导入许可证")) { model.selection = .settings }
                .buttonStyle(XSecondaryButtonStyle())
            Button { withAnimation(XMotion.snappy) { model.licenseBannerDismissed = true } } label: {
                Image(systemName: "xmark").font(XFont.captionEmphasis)
                    .foregroundStyle(XColor.textTertiary)
                    .frame(width: 24, height: 24)
                    .background(XColor.surfaceAlt.opacity(hover ? 1 : 0), in: Circle())
            }
            .buttonStyle(.plain).onHover { hover = $0 }
            .accessibilityLabel(xLoc("忽略"))
        }
        .padding(XSpacing.m)
        .background(
            RoundedRectangle(cornerRadius: XRadius.card, style: .continuous)
                .fill(XColor.surface)
                .overlay(RoundedRectangle(cornerRadius: XRadius.card, style: .continuous)
                    .strokeBorder(XColor.warning.opacity(0.35), lineWidth: 1))
        )
        .xSoftShadow()
        .padding(.horizontal, XSpacing.xl)
        .padding(.top, XSpacing.m)
        .transition(.move(edge: .top).combined(with: .opacity))
    }
}

// MARK: - 权限提示横幅

struct PermissionBanner: View {
    @EnvironmentObject var model: AppModel
    @State private var hover = false
    var body: some View {
        HStack(spacing: XSpacing.m) {
            // 引导型提示（非告警）：用品牌/信息色，不用告警橙——橙色只留给真正的许可证失效。
            XIconTile(systemImage: "lock.shield.fill", colors: [XColor.info, XColor.auroraBlue], size: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(xLoc("开启完全磁盘访问以扫描全部垃圾"))
                    .font(XFont.bodyEmphasis).foregroundStyle(XColor.textPrimary)
                Text(xLoc("一次授权后长期有效。系统设置 › 隐私与安全性 › 完全磁盘访问权限。"))
                    .font(XFont.caption).foregroundStyle(XColor.textSecondary)
            }
            Spacer()
            Button(xLoc("开启")) { model.openFullDiskAccessSettings() }
                .buttonStyle(XPrimaryButtonStyle(compact: true))
            Button { withAnimation(XMotion.snappy) { model.permissionBannerDismissed = true } } label: {
                Image(systemName: "xmark").font(XFont.captionEmphasis)
                    .foregroundStyle(XColor.textTertiary)
                    .frame(width: 24, height: 24)
                    .background(XColor.surfaceAlt.opacity(hover ? 1 : 0), in: Circle())
            }
            .buttonStyle(.plain).onHover { hover = $0 }
            .accessibilityLabel(xLoc("忽略"))
        }
        .padding(XSpacing.m)
        .background(
            RoundedRectangle(cornerRadius: XRadius.card, style: .continuous)
                .fill(XColor.surface)
                .overlay(RoundedRectangle(cornerRadius: XRadius.card, style: .continuous)
                    .strokeBorder(XColor.info.opacity(0.30), lineWidth: 1))
        )
        .xSoftShadow()
        .padding(.horizontal, XSpacing.xl)
        .padding(.top, XSpacing.m)
        .transition(.move(edge: .top).combined(with: .opacity))
    }
}

// MARK: - 菜单栏内容

/// 菜单栏「合并总览」面板——对标 Sensei 图3 的 Combined：一叠卡片，每张卡片内用
/// 「标签 · 横向进度条 · 数值」的条形行，一屏读懂整机 CPU / 内存 / GPU / 存储 / 网络 / 散热 / 电池。
public struct MenuBarView: View {
    @ObservedObject var model: AppModel
    /// 高频快照现归 MetricsFeed（AppModel 不再每 tick 重发布，审计 P2）——菜单栏总览须观察本 feed 才能实时更新。
    @ObservedObject var feed: MetricsFeed
    public init(model: AppModel) {
        self.model = model
        self._feed = ObservedObject(wrappedValue: model.liveMetricsFeed)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: XSpacing.s) {
            HStack(spacing: XSpacing.s) {
                XBrandMark(size: 20)
                Text(xLoc("系统状态")).font(XFont.headline).foregroundStyle(XColor.textPrimary)
                Spacer()
                if let chip = model.macInfo?.chip {
                    Text(chip).font(XFont.caption).foregroundStyle(XColor.textTertiary)
                }
            }

            if let s = model.liveSnapshot {
                cpuCard(s)
                memoryCard(s)
                if let g = s.gpuUsage { gpuCard(s, g) }
                storageCard(s)
                networkCard(s)
                sensorsCard(s)
                if let pct = s.batteryPercent { batteryCard(s, pct) }
            } else {
                XSpinner().frame(maxWidth: .infinity).padding(.vertical, XSpacing.l)
            }

            HStack(spacing: XSpacing.s) {
                Button {
                    NSApp.activate(ignoringOtherApps: true)
                    model.selection = .monitor
                    for w in NSApp.windows where w.canBecomeMain { w.makeKeyAndOrderFront(nil) }
                } label: { Text(xLoc("打开监视器")).frame(maxWidth: .infinity) }
                    .buttonStyle(XPrimaryButtonStyle(compact: true))
                Button { NSApp.terminate(nil) } label: { Image(systemName: "power") }
                    .buttonStyle(XSecondaryButtonStyle(compact: true))
                    .accessibilityLabel(xLoc("退出"))
            }
            .padding(.top, 2)
        }
        .padding(XSpacing.m)
        .frame(width: 300)
    }

    // MARK: - 卡片

    private func cpuCard(_ s: SystemSnapshot) -> some View {
        card("cpu", xLoc("处理器"), "\(Int(s.cpuUsage * 100))%", XColor.metricCPU[0]) {
            barRow(xLoc("用户"), "\(Int(s.cpuUser * 100))%", s.cpuUser, XColor.metricCPU[0])
            barRow(xLoc("系统"), "\(Int(s.cpuSystem * 100))%", s.cpuSystem, XColor.metricCPU[1])
        }
    }
    private func memoryCard(_ s: SystemSnapshot) -> some View {
        card("memorychip", xLoc("内存"), "\(Int(s.memoryUsedFraction * 100))%", XColor.metricMemory[0]) {
            barRow(xLoc("占用"), s.memoryUsed.formattedMemory, s.memoryUsedFraction, XColor.metricMemory[0])
            barRow(xLoc("压力"), "", s.memoryPressureFraction, pressureColor(s.memoryPressure))
            infoRowBadge(xLoc("内存压力"), xLoc(s.memoryPressureLabel), pressureColor(s.memoryPressure))
        }
    }
    private func gpuCard(_ s: SystemSnapshot, _ g: Double) -> some View {
        card("cpu.fill", "GPU", "\(Int(g * 100))%", XColor.metricGPU[0]) {
            barRow(xLoc("占用"), "\(Int(g * 100))%", g, XColor.metricGPU[0])
            if let t = s.gpuTemp, t > 0 { infoRow(xLoc("温度"), String(format: "%.0f°C", t)) }
        }
    }
    private func storageCard(_ s: SystemSnapshot) -> some View {
        card("internaldrive", xLoc("存储"), "\(Int(s.diskUsedFraction * 100))%", XColor.metricDisk[0]) {
            barRow(xLoc("已用"), s.diskFree.formattedBytes, s.diskUsedFraction, XColor.metricDisk[0])
        }
    }
    private func networkCard(_ s: SystemSnapshot) -> some View {
        card("antenna.radiowaves.left.and.right", xLoc("网络"), "", XColor.metricNetwork[0]) {
            infoRow("↓ " + xLoc("下载"), s.netDownBytesPerSec.formattedRate)
            infoRow("↑ " + xLoc("上传"), s.netUpBytesPerSec.formattedRate)
        }
    }
    private func sensorsCard(_ s: SystemSnapshot) -> some View {
        card("thermometer.medium", xLoc("散热"), "", XColor.warning) {
            if let t = s.cpuTemp, t > 0 { infoRow(xLoc("处理器温度"), String(format: "%.0f°C", t)) }
            if let g = s.gpuTemp, g > 0 { infoRow(xLoc("GPU 温度"), String(format: "%.0f°C", g)) }
            if let rpm = s.fanRPM { infoRow(xLoc("风扇"), "\(rpm) RPM") }
            infoRowBadge(xLoc("热状态"), xLoc(s.thermal.rawValue), thermalColor(s.thermal))
        }
    }
    private func batteryCard(_ s: SystemSnapshot, _ pct: Int) -> some View {
        card(batteryIcon(pct, charging: s.batteryCharging), xLoc("电池"), "\(pct)%", batteryColor(pct)) {
            barRow(xLoc("电量"), "\(pct)%", Double(pct) / 100, batteryColor(pct))
            infoRowBadge(xLoc("状态"),
                         s.batteryCharging ? xLoc("充电中") : xLoc("使用电池"),
                         s.batteryCharging ? XColor.success : XColor.textSecondary)
        }
    }

    // MARK: - 组件

    /// 菜单栏总览的**紧凑密度**分区卡（14pt 图标 + nano 小标，为 300pt 弹窗设计）。
    /// 页面级分区卡请用 DesignSystem.XSectionCard（28pt 图标 + caption 小标）——两档密度、同一语言。
    private func card<C: View>(_ icon: String, _ title: String, _ headerValue: String, _ tint: Color,
                               @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: XSpacing.xs) {
                Image(systemName: icon).font(XFont.micro).foregroundStyle(tint).frame(width: 14)
                Text(title).font(XFont.nano).tracking(0.6).textCase(.uppercase)
                    .foregroundStyle(XColor.textTertiary)
                Spacer()
                if !headerValue.isEmpty {
                    Text(headerValue).font(XFont.microMono).foregroundStyle(XColor.textSecondary)
                }
            }
            content()
        }
        .padding(.horizontal, XSpacing.s).padding(.vertical, XSpacing.s)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: XRadius.tile, style: .continuous)
                .fill(XColor.surfaceAlt.opacity(0.55))
                // 极淡主题色底（贴左上一丝 tint 辉光，像 Sensei 每卡不同色调）——用该卡指标色，克制不刺眼。
                .overlay(
                    RoundedRectangle(cornerRadius: XRadius.tile, style: .continuous)
                        .fill(LinearGradient(colors: [tint.opacity(0.10), .clear],
                                             startPoint: .topLeading, endPoint: .center))
                )
        )
        .overlay(RoundedRectangle(cornerRadius: XRadius.tile, style: .continuous).strokeBorder(tint.opacity(0.18), lineWidth: 1))
    }

    /// 「标签 · 横向进度条 · 数值」——Sensei 式条形行。进度条用定宽（ImageRenderer 与真机弹窗都稳定）。
    /// 标签/数值单行、长语言自动缩放不换行。
    private func barRow(_ label: String, _ value: String, _ fraction: Double, _ color: Color) -> some View {
        let barW: CGFloat = 108
        return HStack(spacing: XSpacing.s) {
            Text(label).font(XFont.caption).foregroundStyle(XColor.textSecondary)
                .lineLimit(1).minimumScaleFactor(0.6)
                .frame(width: 58, alignment: .leading)
            ZStack(alignment: .leading) {
                Capsule().fill(XColor.textTertiary.opacity(0.16)).frame(width: barW, height: 5)
                Capsule()
                    .fill(LinearGradient(colors: [color.opacity(0.8), color], startPoint: .leading, endPoint: .trailing))
                    .frame(width: max(3, barW * min(max(fraction, 0), 1)), height: 5)
                    .animation(XMotion.gauge, value: fraction)
            }
            Spacer(minLength: XSpacing.xs)
            Text(value).font(XFont.microMono).foregroundStyle(XColor.textPrimary)
                .lineLimit(1).minimumScaleFactor(0.6)
                .frame(minWidth: 44, alignment: .trailing)
        }
    }

    private func infoRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).font(XFont.caption).foregroundStyle(XColor.textSecondary)
            Spacer()
            Text(value).font(XFont.microMono).foregroundStyle(XColor.textPrimary)
        }
    }
    private func infoRowBadge(_ label: String, _ badge: String, _ color: Color) -> some View {
        HStack {
            Text(label).font(XFont.caption).foregroundStyle(XColor.textSecondary)
            Spacer()
            XBadge(badge, color: color)
        }
    }

    private func pressureColor(_ level: Int) -> Color {
        switch level { case 4: return XColor.danger; case 2: return XColor.warning; default: return XColor.success }
    }
    private func thermalColor(_ t: ThermalLevel) -> Color {
        switch t {
        case .nominal: return XColor.success
        case .fair: return XColor.accentTeal
        case .serious: return XColor.warning
        case .critical: return XColor.danger
        }
    }
    private func batteryIcon(_ pct: Int, charging: Bool) -> String {
        if charging { return "battery.100.bolt" }
        switch pct {
        case ..<13:  return "battery.0"
        case ..<38:  return "battery.25"
        case ..<63:  return "battery.50"
        case ..<88:  return "battery.75"
        default:     return "battery.100"
        }
    }
    private func batteryColor(_ pct: Int) -> Color {
        if pct <= 15 { return XColor.danger }
        if pct <= 30 { return XColor.warning }
        return XColor.success
    }
}
