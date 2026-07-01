import SwiftUI
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

            if model.showOnboarding {
                OnboardingView(model: model)
                    .transition(.opacity)
                    .zIndex(1)
            }
        }
        .frame(minWidth: 1080, minHeight: 720)
        .preferredColorScheme(model.appearance.colorScheme)
        .onAppear { model.startMetricsTimer() }
        .onReceive(NotificationCenter.default.publisher(for: .xicoOpenSettings)) { _ in
            withAnimation(.spring(response: 0.35, dampingFraction: 0.78)) {
                model.selection = .settings
            }
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
                            Text(category.title)
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
                    Text("磁盘").font(XFont.captionEmphasis).foregroundStyle(XColor.textSecondary)
                    Spacer()
                    Text("\(cap.available.formattedBytes) 可用").font(XFont.caption).foregroundStyle(XColor.textSecondary)
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
            HStack(spacing: XSpacing.s) {
                Image(systemName: meta.systemImage)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(selected ? .white : XColor.textSecondary)
                    .frame(width: 22, height: 22)
                Text(meta.title)
                    .font(selected ? XFont.headline : XFont.bodyEmphasis)
                    .foregroundStyle(selected ? .white : XColor.textPrimary)
                Spacer()
            }
            .padding(.horizontal, XSpacing.s)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: XRadius.tile, style: .continuous)
                    .fill(selected ? AnyShapeStyle(XColor.brandGradient)
                                   : AnyShapeStyle(hover ? XColor.surfaceHover : Color.clear))
                    .shadow(color: selected ? XColor.brand.opacity(0.3) : .clear, radius: 7, y: 3)
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
        case .smartScan:    SmartScanView(env: model.env)
        case .systemJunk:   ModuleScanView(env: model.env, moduleID: .systemJunk, intent: .trash)
        case .largeFiles:   ModuleScanView(env: model.env, moduleID: .largeFiles, intent: .trash)
        case .trash:        ModuleScanView(env: model.env, moduleID: .trash, intent: .permanent)
        case .spaceLens:    SpaceLensView(env: model.env)
        case .duplicates:   DuplicatesView(env: model.env)
        case .uninstaller:  UninstallerView(env: model.env)
        case .privacy:      ModuleScanView(env: model.env, moduleID: .privacy, intent: .trash)
        case .optimization: OptimizationView(env: model.env)
        case .maintenance:  MaintenanceView(env: model.env)
        case .malware:      ModuleScanView(env: model.env, moduleID: .malware, intent: .trash)
        case .monitor:      MonitorView(env: model.env)
        case .settings:     SettingsView(model: model)
        // 未知模块 ID（例如开发用 --open=<拼写错误>）回落到仪表盘，而非过时的「即将推出」占位页。
        default:            SmartScanView(env: model.env)
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
                Text("需要有效许可证")
                    .font(XFont.bodyEmphasis).foregroundStyle(XColor.textPrimary)
                Text(model.licenseStatus?.summary ?? "请在设置中导入有效许可证后继续。")
                    .font(XFont.caption).foregroundStyle(XColor.textSecondary)
            }
            Spacer()
            Button("打开设置") { model.selection = .settings }
                .buttonStyle(XPrimaryButtonStyle())
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
                Text("开启完全磁盘访问以扫描全部垃圾")
                    .font(XFont.bodyEmphasis).foregroundStyle(XColor.textPrimary)
                Text("一次授权后长期有效。系统设置 › 隐私与安全性 › 完全磁盘访问权限。")
                    .font(XFont.caption).foregroundStyle(XColor.textSecondary)
            }
            Spacer()
            Button("开启") { model.openFullDiskAccessSettings() }
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
                Text("系统状态").font(XFont.headline).foregroundStyle(XColor.textPrimary)
                Spacer()
                if let chip = model.macInfo?.chip {
                    Text(chip).font(XFont.caption).foregroundStyle(XColor.textTertiary)
                }
            }

            if let s = model.liveSnapshot {
                HStack(spacing: XSpacing.s) {
                    ringStat("处理器", s.cpuUsage)
                    ringStat("内存", s.memoryUsedFraction)
                    ringStat("存储", s.diskUsedFraction)
                }
                .padding(.vertical, XSpacing.xs)

                Divider().padding(.vertical, 2)

                row("antenna.radiowaves.left.and.right", "网络",
                    "↓ \(s.netDownBytesPerSec.formattedRate)   ↑ \(s.netUpBytesPerSec.formattedRate)")
                if let rpm = s.fanRPM {
                    row("fanblades", "风扇", "\(rpm) RPM")
                }
                HStack {
                    Image(systemName: "thermometer.medium").font(.system(size: 12)).foregroundStyle(XColor.brand)
                        .frame(width: 18)
                    Text("热状态").font(XFont.caption).foregroundStyle(XColor.textSecondary)
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
                } label: { Text("打开监视器").frame(maxWidth: .infinity) }
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
