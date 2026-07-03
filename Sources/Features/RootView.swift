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
            // 主题/语言切换时，色值与文案都来自静态查表（XThemeStore / XLocale），SwiftUI 无法追踪。
            // 用 .id 绑定 themeID+语言，切换时重建整棵内容树 → 全局即时换色、换语言。
            .id("\(model.themeID)-\(model.language.rawValue)")
            .environment(\.locale, XLocale.swiftUILocale)   // .relative 日期/数字等跟随 App 语言
            .transition(.opacity)

            if model.showOnboarding {
                OnboardingView(model: model)
                    .transition(.opacity)
                    .zIndex(1)
            }
        }
        .frame(minWidth: 1080, minHeight: 720)
        .animation(.easeInOut(duration: 0.3), value: model.themeID)   // 换主题时整树平滑淡入
        .preferredColorScheme(model.appearance.colorScheme)
        .sheet(isPresented: $model.showPricing) { PricingView(model: model) }
        .onAppear { model.startMetricsTimer() }
        .onReceive(NotificationCenter.default.publisher(for: .xicoOpenSettings)) { _ in
            withAnimation(.spring(response: 0.35, dampingFraction: 0.78)) {
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
                    withAnimation(.easeOut(duration: 0.2)) { appearance = a }
                } label: {
                    Image(systemName: a.icon)
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 30, height: 22)
                        .foregroundStyle(appearance == a ? .white : XColor.textSecondary)
                        .background(
                            Capsule().fill(appearance == a ? AnyShapeStyle(XColor.brandGradient)
                                                           : AnyShapeStyle(Color.clear))
                        )
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(XColor.surfaceAlt.opacity(0.6), in: Capsule())
        .overlay(Capsule().strokeBorder(XColor.border.opacity(0.6), lineWidth: 1))
    }
}

// MARK: - 侧边栏（自定义高级样式）

struct SidebarView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            brandHeader
            ScrollView {
                VStack(alignment: .leading, spacing: XSpacing.l) {
                    ForEach(ModuleCatalog.grouped(), id: \.0) { category, modules in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(xLoc(category.title))
                                .xSectionLabel()
                                .foregroundStyle(XColor.textTertiary)
                                .padding(.leading, XSpacing.m)
                                .padding(.bottom, 3)
                            ForEach(modules) { meta in
                                SidebarTile(meta: meta, selected: model.selection == meta.id) {
                                    withAnimation(.spring(response: 0.35, dampingFraction: 0.78)) {
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
            diskFooter
        }
        .background(
            ZStack {
                LinearGradient(colors: [XColor.sidebar, XColor.canvasBottom],
                               startPoint: .top, endPoint: .bottom)
                RadialGradient(colors: [XColor.auroraViolet.opacity(0.12), .clear],
                               center: .top, startRadius: 0, endRadius: 300)
                RadialGradient(colors: [XColor.auroraRose.opacity(0.08), .clear],
                               center: .bottom, startRadius: 0, endRadius: 220)
            }
            .overlay(Rectangle().fill(XColor.hairline).frame(width: 1), alignment: .trailing)
            .ignoresSafeArea()
        )
    }

    private var brandHeader: some View {
        HStack(spacing: XSpacing.s) {
            XBrandMark(size: 30)
            Text("Xico").font(.system(size: 21, weight: .bold, design: .rounded))
                .foregroundStyle(XColor.textPrimary)
            Spacer()
        }
        .padding(.horizontal, XSpacing.m)
        .padding(.top, 38)
        .padding(.bottom, XSpacing.m)
    }

    private var diskFooter: some View {
        VStack(alignment: .leading, spacing: XSpacing.s) {
            if let cap = model.capacity {
                HStack {
                    Text(xLoc("磁盘")).font(XFont.captionEmphasis).foregroundStyle(XColor.textSecondary)
                    Spacer()
                    Text(xLocF("%@ 可用", cap.available.formattedBytes)).font(XFont.caption).foregroundStyle(XColor.textSecondary)
                }
                XDiskBar(usedFraction: cap.usedFraction, label: "", height: 8)
            }
            HStack {
                AppearanceToggle(appearance: $model.appearance)
                Spacer()
                Button { model.selection = .settings } label: {
                    Image(systemName: "gearshape.fill")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(model.selection == .settings ? XColor.brand : XColor.textSecondary)
                        .frame(width: 28, height: 28)
                        .background(model.selection == .settings ? XColor.surfaceHover : .clear, in: Circle())
                }
                .buttonStyle(.plain)
            }
            .padding(.top, 2)
        }
        .padding(XSpacing.m)
        .overlay(Rectangle().fill(XColor.hairline).frame(height: 1), alignment: .top)
    }
}

struct SidebarTile: View {
    let meta: ModuleMetadata
    let selected: Bool
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: XSpacing.s + 2) {
                Image(systemName: meta.systemImage)
                    // 图标字号/字重恒定，仅颜色随选中变化——避免选中时行高跳动。
                    .font(.system(size: 14, weight: selected ? .semibold : .regular))
                    .foregroundStyle(selected ? .white : XColor.textSecondary)
                    .frame(width: 20, height: 20)
                Text(xLoc(meta.title))
                    // 字号恒定 13.5pt，仅字重随选中变化（medium→semibold），杜绝选中放大导致的重排。
                    .font(.system(size: 13.5, weight: selected ? .semibold : .medium))
                    .foregroundStyle(selected ? .white : XColor.textPrimary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, XSpacing.s + 2)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: XRadius.tile, style: .continuous)
                    .fill(selected ? AnyShapeStyle(XColor.brandGradient)
                                   : AnyShapeStyle(hover ? XColor.surfaceHover : Color.clear))
                    // 更柔、更扩散的投影，收敛"发光块"的刺眼感。
                    .shadow(color: selected ? XColor.brand.opacity(0.22) : .clear, radius: 9, y: 3)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .accessibilityLabel(meta.title)
        .accessibilityHint(meta.subtitle)
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
            .animation(.easeInOut(duration: 0.28), value: model.selection)
        }
    }

    @ViewBuilder private var page: some View {
        switch model.selection ?? .smartScan {
        case .smartScan:    SmartScanView(model: model)
        case .systemJunk:   ModuleScanView(model: model, moduleID: .systemJunk, intent: .trash)
        case .largeFiles:   ModuleScanView(model: model, moduleID: .largeFiles, intent: .trash)
        case .trash:        ModuleScanView(model: model, moduleID: .trash, intent: .permanent)
        case .spaceLens:    SpaceLensView(env: model.env)
        case .duplicates:   DuplicatesView(env: model.env)
        case .similarImages: SimilarImagesView(env: model.env)
        case .shredder:     ShredderView(env: model.env)
        case .uninstaller:  UninstallerView(env: model.env)
        case .appUpdater:   AppUpdaterView(env: model.env)
        case .privacy:      ModuleScanView(model: model, moduleID: .privacy, intent: .trash)
        case .optimization: OptimizationView(env: model.env)
        case .maintenance:  MaintenanceView(env: model.env)
        case .malware:      ModuleScanView(model: model, moduleID: .malware, intent: .trash)
        case .hardware:     HardwareView(env: model.env)
        case .monitor:      MonitorView(env: model.env)
        case .settings:     SettingsView(model: model)
        // 未知模块 ID（例如开发用 --open=<拼写错误>）回落到仪表盘，而非过时的「即将推出」占位页。
        default:            SmartScanView(model: model)
        }
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
            Button { withAnimation(.spring(response: 0.3)) { model.licenseBannerDismissed = true } } label: {
                Image(systemName: "xmark").font(.system(size: 11, weight: .bold))
                    .foregroundStyle(XColor.textTertiary)
                    .frame(width: 24, height: 24)
                    .background(XColor.surfaceAlt.opacity(hover ? 1 : 0), in: Circle())
            }
            .buttonStyle(.plain).onHover { hover = $0 }
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
            XIconTile(systemImage: "lock.shield.fill", colors: [XColor.warning, XColor.accentPink], size: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(xLoc("开启完全磁盘访问以扫描全部垃圾"))
                    .font(XFont.bodyEmphasis).foregroundStyle(XColor.textPrimary)
                Text(xLoc("一次授权后长期有效。系统设置 › 隐私与安全性 › 完全磁盘访问权限。"))
                    .font(XFont.caption).foregroundStyle(XColor.textSecondary)
            }
            Spacer()
            Button(xLoc("开启")) { model.openFullDiskAccessSettings() }
                .buttonStyle(XPrimaryButtonStyle())
            Button { withAnimation(.spring(response: 0.3)) { model.permissionBannerDismissed = true } } label: {
                Image(systemName: "xmark").font(.system(size: 11, weight: .bold))
                    .foregroundStyle(XColor.textTertiary)
                    .frame(width: 24, height: 24)
                    .background(XColor.surfaceAlt.opacity(hover ? 1 : 0), in: Circle())
            }
            .buttonStyle(.plain).onHover { hover = $0 }
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

// MARK: - 菜单栏内容

/// 菜单栏常驻状态面板：实时 CPU / 内存 / 存储 / 网络 / 风扇 / 温度
public struct MenuBarView: View {
    @ObservedObject var model: AppModel
    public init(model: AppModel) { self.model = model }

    public var body: some View {
        VStack(alignment: .leading, spacing: XSpacing.m) {
            HStack(spacing: XSpacing.s) {
                XBrandMark(size: 22)
                Text(xLoc("系统状态")).font(XFont.headline).foregroundStyle(XColor.textPrimary)
                Spacer()
                if let chip = model.macInfo?.chip {
                    Text(chip).font(XFont.caption).foregroundStyle(XColor.textTertiary)
                }
            }

            if let s = model.liveSnapshot {
                HStack(spacing: XSpacing.s) {
                    ringStat(xLoc("处理器"), s.cpuUsage)
                    ringStat(xLoc("内存"), s.memoryUsedFraction)
                    ringStat(xLoc("存储"), s.diskUsedFraction)
                }
                .padding(.vertical, XSpacing.xs)

                Divider().padding(.vertical, 2)

                row("antenna.radiowaves.left.and.right", xLoc("网络"),
                    "↓ \(s.netDownBytesPerSec.formattedRate)   ↑ \(s.netUpBytesPerSec.formattedRate)")
                if let rpm = s.fanRPM {
                    row("fanblades", xLoc("风扇"), "\(rpm) RPM")
                }
                HStack {
                    Image(systemName: "thermometer.medium").font(.system(size: 12)).foregroundStyle(XColor.brand)
                        .frame(width: 18)
                    Text(xLoc("热状态")).font(XFont.caption).foregroundStyle(XColor.textSecondary)
                    Spacer()
                    XBadge(s.thermal.rawValue, color: thermalColor(s.thermal))
                }
            } else {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity)
            }

            Divider().padding(.vertical, 2)
            HStack(spacing: XSpacing.s) {
                Button {
                    NSApp.activate(ignoringOtherApps: true)
                    model.selection = .monitor
                    for w in NSApp.windows where w.canBecomeMain { w.makeKeyAndOrderFront(nil) }
                } label: { Text(xLoc("打开监视器")).frame(maxWidth: .infinity) }
                    .buttonStyle(.borderedProminent)
                Button { NSApp.terminate(nil) } label: { Image(systemName: "power") }
                    .buttonStyle(.bordered)
            }
        }
        .padding(XSpacing.m)
        .frame(width: 300)
    }

    /// 彩虹极光环 + 中心百分数 + 标题（合并总览的三个指标）
    private func ringStat(_ title: String, _ fraction: Double) -> some View {
        VStack(spacing: 6) {
            XMiniRing(fraction: fraction, colors: XColor.ringColors, size: 58, lineWidth: 6.5) {
                Text("\(Int((fraction * 100).rounded()))%")
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundStyle(XColor.textPrimary)
            }
            Text(title).font(XFont.caption).foregroundStyle(XColor.textSecondary)
        }
        .frame(maxWidth: .infinity)
    }

    private func row(_ icon: String, _ title: String, _ detail: String) -> some View {
        HStack {
            Image(systemName: icon).font(.system(size: 12)).foregroundStyle(XColor.brand).frame(width: 18)
            Text(title).font(XFont.caption).foregroundStyle(XColor.textSecondary)
            Spacer()
            Text(detail).font(XFont.mono).foregroundStyle(XColor.textPrimary)
        }
    }

    private func thermalColor(_ t: ThermalLevel) -> Color {
        switch t {
        case .nominal: return XColor.success
        case .fair: return XColor.accentTeal
        case .serious: return XColor.warning
        case .critical: return XColor.danger
        }
    }
}
