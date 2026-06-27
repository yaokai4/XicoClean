import SwiftUI
import Domain
import Infrastructure
import DesignSystem

public struct SettingsView: View {
    @ObservedObject var model: AppModel
    @State private var helperStatus: HelperProxy.Status = .notInstalled
    @State private var history: [CleaningRecord] = []
    @State private var totalReclaimed: Int64 = 0
    @State private var totalCleanups = 0
    @AppStorage("xico.mb.cpu") private var mbCPU = true
    @AppStorage("xico.mb.memory") private var mbMemory = true
    @AppStorage("xico.mb.network") private var mbNetwork = true
    @AppStorage("xico.mb.combined") private var mbCombined = false
    @AppStorage("xico.mb.style") private var mbStyle = MenuBarStyle.iconValue.rawValue

    public init(model: AppModel) { self.model = model }

    private var version: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.2.0"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(v) (\(b))"
    }

    public var body: some View {
        VStack(spacing: 0) {
            XHeaderBar(title: "设置", subtitle: "外观、权限与关于")
            ScrollView {
                VStack(spacing: XSpacing.m) {
                    aboutCard
                    historyCard
                    appearanceCard
                    menuBarCard
                    permissionCard
                    helperCard
                    resetCard
                }
                .padding(XSpacing.xl)
                .frame(maxWidth: 720)
                .frame(maxWidth: .infinity)
            }
        }
        .onAppear {
            helperStatus = model.env.helper.status()
            reloadHistory()
        }
        .onReceive(NotificationCenter.default.publisher(for: .xicoDidClean)) { _ in reloadHistory() }
    }

    private func reloadHistory() {
        history = model.env.history.recent(8)
        totalReclaimed = model.env.history.totalReclaimedAllTime
        totalCleanups = model.env.history.totalCleanups
    }

    private var historyCard: some View {
        XCard {
            VStack(alignment: .leading, spacing: XSpacing.s) {
                HStack(spacing: XSpacing.m) {
                    XIconTile(systemImage: "clock.arrow.circlepath", colors: [XColor.accentTeal, XColor.success], size: 36)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("清理历史").xHeadline().foregroundStyle(XColor.textPrimary)
                        Text(totalCleanups == 0 ? "完成一次清理后会在这里看到记录"
                             : "累计释放 \(totalReclaimed.formattedBytes) · 共 \(totalCleanups) 次清理")
                            .font(XFont.caption).foregroundStyle(XColor.textSecondary)
                    }
                    Spacer()
                    if totalCleanups > 0 {
                        Button("清空记录") { model.env.history.clear(); reloadHistory() }
                            .buttonStyle(.bordered)
                    }
                }
                if !history.isEmpty {
                    Divider().padding(.vertical, 2)
                    ForEach(history) { rec in
                        HStack(spacing: XSpacing.m) {
                            Text(rec.module).font(XFont.bodyEmphasis).foregroundStyle(XColor.textPrimary)
                            Text(rec.date, format: .relative(presentation: .named))
                                .font(XFont.caption).foregroundStyle(XColor.textTertiary)
                            Spacer()
                            Text("\(rec.removedCount) 项").font(XFont.caption).foregroundStyle(XColor.textSecondary)
                            Text(rec.reclaimedBytes.formattedBytes)
                                .font(XFont.mono).foregroundStyle(XColor.success)
                                .frame(minWidth: 72, alignment: .trailing)
                        }
                    }
                }
            }
        }
    }

    private var aboutCard: some View {
        XCard {
            HStack(spacing: XSpacing.l) {
                XBrandMark(size: 56)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Xico").xLargeTitle().foregroundStyle(XColor.textPrimary)
                    Text("macOS 系统清理 · 磁盘管理 · 性能优化").font(XFont.caption).foregroundStyle(XColor.textSecondary)
                    Text("版本 \(version)").font(XFont.caption).foregroundStyle(XColor.textTertiary)
                }
                Spacer()
            }
        }
    }

    private var appearanceCard: some View {
        settingRow(icon: "circle.lefthalf.filled", colors: [XColor.auroraViolet, XColor.auroraBlue],
                   title: "外观", subtitle: "浅色 / 深色 / 跟随系统") {
            AppearanceToggle(appearance: $model.appearance)
        }
    }

    private var menuBarCard: some View {
        XCard {
            VStack(alignment: .leading, spacing: XSpacing.s) {
                HStack(spacing: XSpacing.m) {
                    XIconTile(systemImage: "menubar.rectangle", colors: [XColor.auroraBlue, XColor.auroraViolet], size: 36)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("菜单栏状态项").xHeadline().foregroundStyle(XColor.textPrimary)
                        Text("选择常驻菜单栏显示哪些实时监控（可多选）").font(XFont.caption).foregroundStyle(XColor.textSecondary)
                    }
                    Spacer()
                }
                Divider().padding(.vertical, 2)
                toggleRow("处理器 CPU", $mbCPU)
                toggleRow("内存", $mbMemory)
                toggleRow("网络速度", $mbNetwork)
                toggleRow("合并总览面板", $mbCombined)
                Divider().padding(.vertical, 2)
                HStack {
                    Text("显示样式").font(XFont.bodyEmphasis).foregroundStyle(XColor.textPrimary)
                    Spacer()
                    Picker("", selection: $mbStyle) {
                        ForEach(MenuBarStyle.allCases, id: \.rawValue) { st in
                            Text(st.title).tag(st.rawValue)
                        }
                    }
                    .labelsHidden().pickerStyle(.menu).frame(width: 150)
                }
            }
        }
    }

    private func toggleRow(_ title: String, _ binding: Binding<Bool>) -> some View {
        HStack {
            Text(title).font(XFont.bodyEmphasis).foregroundStyle(XColor.textPrimary)
            Spacer()
            Toggle("", isOn: binding).toggleStyle(.switch).labelsHidden()
        }
    }

    private var permissionCard: some View {
        settingRow(icon: "externaldrive.fill.badge.checkmark",
                   colors: model.hasFullDiskAccess ? [XColor.accentTeal, XColor.success] : [XColor.warning, XColor.accentPink],
                   title: "完全磁盘访问权限",
                   subtitle: model.hasFullDiskAccess ? "已授权 · 可扫描全部位置" : "未授权 · 部分垃圾扫不到") {
            if model.hasFullDiskAccess {
                XBadge("已开启", color: XColor.success)
            } else {
                Button("去开启") { model.openFullDiskAccessSettings() }.buttonStyle(.bordered)
            }
        }
    }

    private var helperCard: some View {
        settingRow(icon: "gearshape.2.fill",
                   colors: helperStatus == .installed ? [XColor.accentTeal, XColor.success] : [XColor.auroraViolet, XColor.auroraRose],
                   title: "特权助手",
                   subtitle: helperSubtitle) {
            switch helperStatus {
            case .installed: XBadge("已就绪", color: XColor.success)
            case .requiresApproval:
                Button("去批准") { model.env.helper.openLoginItemsSettings() }.buttonStyle(.bordered)
            default:
                Button("安装") {
                    try? model.env.helper.install()
                    helperStatus = model.env.helper.status()
                    if helperStatus == .requiresApproval { model.env.helper.openLoginItemsSettings() }
                }.buttonStyle(.bordered)
            }
        }
    }

    private var helperSubtitle: String {
        switch helperStatus {
        case .installed: return "已安装 · 维护中的系统级任务可用"
        case .requiresApproval: return "已注册 · 待在登录项中批准"
        case .unavailable: return "开发签名版本不可用 · 正式签名后可装"
        default: return "用于执行需管理员权限的维护任务"
        }
    }

    private var resetCard: some View {
        settingRow(icon: "arrow.counterclockwise", colors: [XColor.textTertiary, XColor.textSecondary],
                   title: "重新显示引导页", subtitle: "下次启动时再次展示欢迎引导") {
            Button("重置") {
                UserDefaults.standard.set(false, forKey: "xico.onboarded")
                UserDefaults.standard.set(false, forKey: "xico.fdaDismissed")
            }.buttonStyle(.bordered)
        }
    }

    private func settingRow<Trailing: View>(icon: String, colors: [Color], title: String, subtitle: String,
                                            @ViewBuilder trailing: () -> Trailing) -> some View {
        XCard {
            HStack(spacing: XSpacing.m) {
                XIconTile(systemImage: icon, colors: colors, size: 36)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).xHeadline().foregroundStyle(XColor.textPrimary)
                    Text(subtitle).font(XFont.caption).foregroundStyle(XColor.textSecondary)
                }
                Spacer()
                trailing()
            }
        }
    }
}
