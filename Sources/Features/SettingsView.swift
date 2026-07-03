import SwiftUI
import AppKit
import Domain
import Infrastructure
import DesignSystem

public struct SettingsView: View {
    @ObservedObject var model: AppModel
    @State private var helperStatus: HelperProxy.Status = .notInstalled
    @State private var helperError: String?
    @State private var history: [CleaningRecord] = []
    @State private var totalReclaimed: Int64 = 0
    @State private var totalCleanups = 0
    @State private var definitionsStatus: DefinitionsUpdateStatus?
    @State private var definitionsMessage: String?
    @State private var definitionsUpdating = false
    @State private var licenseStatus: LicenseStatus?
    @State private var licenseMessage: String?
    @AppStorage("xico.mb.cpu") private var mbCPU = true
    @AppStorage("xico.mb.memory") private var mbMemory = true
    @AppStorage("xico.mb.network") private var mbNetwork = true
    @AppStorage("xico.mb.combined") private var mbCombined = false
    @AppStorage("xico.mb.style") private var mbStyle = MenuBarStyle.iconValue.rawValue
    @AppStorage("xico.mb.interval") private var mbInterval = 2.0
    @AppStorage("xico.mb.temp") private var mbTemp = false
    @AppStorage("xico.mb.disk") private var mbDisk = false
    @AppStorage("xico.mb.gpu") private var mbGPU = false
    // 默认单色（模板图，随菜单栏深浅自动黑/白）——克制、像 Sensei/iStat 默认那样不刺眼。
    // 彩虹极光留给点开后的详情面板与 App 内部。想要彩色菜单栏的用户可自行打开。
    @AppStorage("xico.mb.colored") private var mbColored = false
    // 每项独立的显示样式（像 iStat：各指标可各自切换 图标+数值 / 仅数值 / 迷你图 / 可视化）。
    // 默认给一套克制但有信息量的组合：CPU/GPU 用可视化、网络用迷你折线、其余用图标+数值。
    @AppStorage("xico.mb.cpu.style")     private var cpuStyle    = MenuBarStyle.rich.rawValue
    @AppStorage("xico.mb.memory.style")  private var memStyle    = MenuBarStyle.rich.rawValue
    @AppStorage("xico.mb.network.style") private var netStyle    = MenuBarStyle.graph.rawValue
    @AppStorage("xico.mb.temp.style")    private var tempStyle   = MenuBarStyle.iconValue.rawValue
    @AppStorage("xico.mb.gpu.style")     private var gpuStyle    = MenuBarStyle.rich.rawValue
    @AppStorage("xico.mb.disk.style")    private var diskStyle   = MenuBarStyle.iconValue.rawValue

    public init(model: AppModel) { self.model = model }

    private var version: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.2.0"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(v) (\(b))"
    }

    public var body: some View {
        VStack(spacing: 0) {
            XHeaderBar(title: xLoc("设置"), subtitle: xLoc("外观、权限与关于"))
            ScrollView {
                VStack(spacing: XSpacing.m) {
                    aboutCard
                    licenseCard
                    definitionsCard
                    ignoreListCard
                    historyCard
                    appearanceCard
                    languageCard
                    ThemePickerCard(selectedID: Binding(
                        get: { model.themeID },
                        set: { model.themeID = $0 }))
                    menuBarCard
                    alertsCard
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
            definitionsStatus = model.env.definitionsUpdater.status()
            licenseStatus = model.env.license.status()
            reloadHistory()
            reloadIgnored()
        }
        .onReceive(NotificationCenter.default.publisher(for: .xicoDidClean)) { _ in reloadHistory() }
        .alert(xLoc("操作未完成"), isPresented: Binding(get: { helperError != nil }, set: { if !$0 { helperError = nil } })) {
            Button(xLoc("好"), role: .cancel) {}
        } message: {
            Text(helperError ?? "")
        }
    }

    @State private var undoingID: UUID?

    private func reloadHistory() {
        history = model.env.history.recent(8)
        totalReclaimed = model.env.history.totalReclaimedAllTime
        totalCleanups = model.env.history.totalCleanups
    }

    /// 从历史记录跨会话撤销：把该次清理的废纸篓项放回原位。
    private func undoRecord(_ rec: CleaningRecord) {
        guard rec.canUndo, undoingID == nil else { return }
        undoingID = rec.id
        let report = CleaningReport(removedCount: rec.removedCount, reclaimedBytes: rec.reclaimedBytes,
                                    failures: [], restorable: rec.restorable)
        Task {
            let result = await model.env.cleaningEngine.undo(report)
            // 全成功：移除记录并回滚累计释放。部分失败：仅保留仍未恢复的项为可撤销，可重试。
            if result.allSucceeded {
                model.env.history.remove(id: rec.id)
            } else {
                model.env.history.updateRestorable(id: rec.id, to: result.failed)
            }
            reloadHistory()
            undoingID = nil
            NotificationCenter.default.post(name: .xicoDidClean, object: nil)
        }
    }

    private var historyCard: some View {
        XCard {
            VStack(alignment: .leading, spacing: XSpacing.s) {
                HStack(spacing: XSpacing.m) {
                    XIconTile(systemImage: "clock.arrow.circlepath", colors: [XColor.accentTeal, XColor.success], size: 36)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(xLoc("清理历史")).xHeadline().foregroundStyle(XColor.textPrimary)
                        Text(totalCleanups == 0 ? xLoc("完成一次清理后会在这里看到记录")
                             : xLocF("累计释放 %@ · 共 %d 次清理", totalReclaimed.formattedBytes, totalCleanups))
                            .font(XFont.caption).foregroundStyle(XColor.textSecondary)
                    }
                    Spacer()
                    if totalCleanups > 0 {
                        Button(xLoc("清空记录")) { model.env.history.clear(); reloadHistory() }
                            .buttonStyle(.bordered)
                    }
                }
                if !history.isEmpty {
                    Divider().padding(.vertical, 2)
                    ForEach(history) { rec in
                        HStack(spacing: XSpacing.m) {
                            Text(xLoc(rec.module)).font(XFont.bodyEmphasis).foregroundStyle(XColor.textPrimary)
                            Text(rec.date, format: .relative(presentation: .named))
                                .font(XFont.caption).foregroundStyle(XColor.textTertiary)
                            Spacer()
                            if rec.canUndo {
                                Button(xLoc("撤销")) { undoRecord(rec) }
                                    .buttonStyle(.link).font(XFont.caption)
                                    .disabled(undoingID == rec.id)
                            }
                            Text(xLocF("%d 项", rec.removedCount)).font(XFont.caption).foregroundStyle(XColor.textSecondary)
                            Text(rec.reclaimedBytes.formattedBytes)
                                .font(XFont.mono).foregroundStyle(XColor.success)
                                .frame(minWidth: 72, alignment: .trailing)
                        }
                    }
                }
            }
        }
    }

    @State private var ignored: [String] = []

    private var ignoreListCard: some View {
        XCard {
            VStack(alignment: .leading, spacing: XSpacing.s) {
                HStack(spacing: XSpacing.m) {
                    XIconTile(systemImage: "hand.raised.slash", colors: [XColor.auroraViolet, XColor.auroraBlue], size: 36)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(xLoc("忽略清单")).xHeadline().foregroundStyle(XColor.textPrimary)
                        Text(ignored.isEmpty ? xLoc("在扫描结果中右键「永不清理此项」可加入这里")
                             : "\(ignored.count) 项已排除，永不扫描/清理")
                            .font(XFont.caption).foregroundStyle(XColor.textSecondary)
                    }
                    Spacer()
                }
                if !ignored.isEmpty {
                    Divider().padding(.vertical, 2)
                    ForEach(ignored, id: \.self) { path in
                        HStack(spacing: XSpacing.s) {
                            Text(path).font(XFont.caption).foregroundStyle(XColor.textSecondary)
                                .lineLimit(1).truncationMode(.middle)
                            Spacer()
                            Button(xLoc("移除")) { model.env.ignoreList.remove(path); reloadIgnored() }
                                .buttonStyle(.link).font(XFont.caption)
                        }
                    }
                }
            }
        }
    }

    private func reloadIgnored() { ignored = model.env.ignoreList.all() }

    private var aboutCard: some View {
        XCard {
            HStack(spacing: XSpacing.l) {
                XBrandMark(size: 56)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Xico").xLargeTitle().foregroundStyle(XColor.textPrimary)
                    Text(xLoc("macOS 系统清理 · 磁盘管理 · 性能优化")).font(XFont.caption).foregroundStyle(XColor.textSecondary)
                    Text(xLocF("版本 %@", version)).font(XFont.caption).foregroundStyle(XColor.textTertiary)
                    HStack(spacing: XSpacing.s) {
                        Button(xLoc("隐私政策")) { NSWorkspace.shared.open(URL(string: "https://xico.app/privacy")!) }
                            .buttonStyle(.link).font(XFont.caption)
                        Text("·").foregroundStyle(XColor.textTertiary)
                        Button(xLoc("许可协议")) { NSWorkspace.shared.open(URL(string: "https://xico.app/eula")!) }
                            .buttonStyle(.link).font(XFont.caption)
                    }
                }
                Spacer()
                VStack(spacing: XSpacing.xs) {
                    Button(checkingUpdate ? xLoc("检查中…") : xLoc("检查更新")) { checkForUpdate() }
                        .buttonStyle(.bordered).disabled(checkingUpdate)
                    Button(xLoc("升级 Pro")) { model.showPricing = true }
                        .buttonStyle(.bordered)
                    Button(xLoc("导出诊断日志")) { exportDiagnostics() }
                        .buttonStyle(.bordered)
                }
            }
            if let msg = updateMessage {
                Text(msg).font(XFont.caption).foregroundStyle(XColor.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    @State private var checkingUpdate = false
    @State private var updateMessage: String?

    private func checkForUpdate() {
        checkingUpdate = true
        updateMessage = nil
        Task {
            let result = await UpdateChecker().check()
            checkingUpdate = false
            switch result {
            case .upToDate:
                updateMessage = "已是最新版本（\(version)）。"
            case let .available(info):
                updateMessage = "发现新版本 \(info.version)，点击前往下载。"
                NSWorkspace.shared.open(info.downloadURL)
            case let .failed(reason):
                updateMessage = "检查更新失败：\(reason)"
            }
        }
    }

    /// 导出最近日志到用户选择的位置，便于反馈问题（不含任何自动上报）。
    private func exportDiagnostics() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Xico-诊断日志.txt"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if !XicoDiagnostics.export(to: url) {
            helperError = xLoc("导出诊断日志失败，请重试。")
        }
    }

    private var licenseCard: some View {
        XCard {
            VStack(alignment: .leading, spacing: XSpacing.s) {
                HStack(spacing: XSpacing.m) {
                    XIconTile(systemImage: licenseIcon,
                              colors: licenseAllowsUse ? [XColor.accentTeal, XColor.success] : [XColor.warning, XColor.accentPink],
                              size: 36)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(xLoc("商业授权")).xHeadline().foregroundStyle(XColor.textPrimary)
                        Text(licenseSubtitle).font(XFont.caption).foregroundStyle(XColor.textSecondary)
                    }
                    Spacer()
                    Button(xLoc("导入许可证")) { importLicense() }.buttonStyle(.bordered)
                    if licenseStatus?.licenseID != nil {
                        Button(xLoc("移除")) {
                            model.env.license.clearLicense()
                            licenseStatus = model.env.license.status()
                            model.refreshLicense()
                            licenseMessage = xLoc("已移除本机许可证。")
                        }
                        .buttonStyle(.bordered)
                    }
                }
                if let licenseMessage {
                    Divider().padding(.vertical, 2)
                    Text(licenseMessage)
                        .font(XFont.caption)
                        .foregroundStyle(XColor.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private var licenseAllowsUse: Bool {
        (licenseStatus ?? model.env.license.status()).state.allowsCommercialUse
    }

    private var licenseIcon: String {
        switch (licenseStatus ?? model.env.license.status()).state {
        case .licensed: return "checkmark.seal.fill"
        case .trial: return "timer"
        case .expired, .invalid: return "exclamationmark.triangle.fill"
        }
    }

    private var licenseSubtitle: String {
        switch (licenseStatus ?? model.env.license.status()).state {
        case let .licensed(name, _): return xLocF("已激活 · %@", name)
        case let .trial(days):       return xLocF("试用中 · 剩余 %d 天", days)
        case .expired:               return xLoc("试用已结束 · 升级后继续使用清理与优化")
        case .invalid:               return xLoc("许可证无效 · 请重新导入")
        }
    }

    private func importLicense() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.json, .data]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try Data(contentsOf: url)
            licenseStatus = try model.env.license.installLicense(fromEnvelopeData: data)
            model.refreshLicense()
            licenseMessage = xLoc("许可证已验证并安装。")
        } catch {
            licenseStatus = model.env.license.status()
            model.refreshLicense()
            licenseMessage = error.localizedDescription
        }
    }

    private var definitionsCard: some View {
        XCard {
            VStack(alignment: .leading, spacing: XSpacing.s) {
                HStack(spacing: XSpacing.m) {
                    XIconTile(systemImage: "checkmark.shield.fill",
                              colors: definitionsTrusted ? [XColor.accentTeal, XColor.success] : [XColor.warning, XColor.accentPink],
                              size: 36)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(xLoc("清理规则库")).xHeadline().foregroundStyle(XColor.textPrimary)
                        Text(definitionsSubtitle).font(XFont.caption).foregroundStyle(XColor.textSecondary)
                    }
                    Spacer()
                    if definitionsUpdating {
                        ProgressView().controlSize(.small)
                    } else {
                        Button(xLoc("检查更新")) { refreshDefinitions() }
                            .buttonStyle(.bordered)
                            .disabled(!(definitionsStatus?.endpointConfigured ?? false) || !(definitionsStatus?.trustConfigured ?? false))
                    }
                }
                if let definitionsMessage {
                    Divider().padding(.vertical, 2)
                    Text(definitionsMessage)
                        .font(XFont.caption)
                        .foregroundStyle(XColor.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private var definitionsTrusted: Bool {
        definitionsStatus?.trustConfigured == true
    }

    private var definitionsSubtitle: String {
        let status = definitionsStatus ?? model.env.definitionsUpdater.status()
        let config: String
        if status.endpointConfigured && status.trustConfigured {
            config = xLoc("在线更新已启用")
        } else if !status.endpointConfigured {
            config = xLoc("使用内置离线规则")
        } else {
            config = xLoc("缺少可信公钥配置")
        }
        var parts = [xLocF("当前 v%@", "\(status.activeVersion)")]
        if let c = status.cachedVersion { parts.append(xLocF("已缓存 v%@", "\(c)")) }
        parts.append(config)
        return parts.joined(separator: " · ")
    }

    private func refreshDefinitions() {
        definitionsUpdating = true
        definitionsMessage = nil
        Task {
            do {
                let library = try await model.env.definitionsUpdater.refresh()
                definitionsStatus = model.env.definitionsUpdater.status()
                definitionsMessage = "已下载并验证规则库 v\(library.version)。重新启动 Xico 后生效。"
            } catch {
                definitionsStatus = model.env.definitionsUpdater.status()
                definitionsMessage = error.localizedDescription
            }
            definitionsUpdating = false
        }
    }

    private var appearanceCard: some View {
        settingRow(icon: "circle.lefthalf.filled", colors: [XColor.auroraViolet, XColor.auroraBlue],
                   title: xLoc("外观"), subtitle: xLoc("浅色 / 深色 / 跟随系统")) {
            AppearanceToggle(appearance: $model.appearance)
        }
    }

    private var languageCard: some View {
        settingRow(icon: "globe", colors: [XColor.accentTeal, XColor.auroraBlue],
                   title: xLoc("语言"), subtitle: xLoc("简体中文 / English / 日本語 · 即时切换")) {
            Picker("", selection: $model.language) {
                ForEach(XLang.allCases) { lang in Text(lang.nativeName).tag(lang) }
            }
            .labelsHidden().pickerStyle(.menu).frame(width: 160)
        }
    }

    private var menuBarCard: some View {
        XCard {
            VStack(alignment: .leading, spacing: XSpacing.s) {
                HStack(spacing: XSpacing.m) {
                    XIconTile(systemImage: "menubar.rectangle", colors: [XColor.auroraBlue, XColor.auroraViolet], size: 36)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(xLoc("菜单栏状态项")).xHeadline().foregroundStyle(XColor.textPrimary)
                        Text(xLoc("选择常驻菜单栏显示哪些实时监控（可多选）")).font(XFont.caption).foregroundStyle(XColor.textSecondary)
                    }
                    Spacer()
                }
                Divider().padding(.vertical, 2)
                Text(xLoc("每项都能单独切换显示方式（图标+数值 / 仅数值 / 迷你折线 / 可视化），像 iStat 一样自定义"))
                    .font(XFont.caption).foregroundStyle(XColor.textSecondary)
                mbMetricRow(xLoc("处理器 CPU"), $mbCPU, $cpuStyle)
                mbMetricRow(xLoc("内存"), $mbMemory, $memStyle)
                mbMetricRow(xLoc("网络速度"), $mbNetwork, $netStyle)
                mbMetricRow(xLoc("处理器温度"), $mbTemp, $tempStyle)
                mbMetricRow(xLoc("GPU 占用"), $mbGPU, $gpuStyle)
                mbMetricRow(xLoc("磁盘占用"), $mbDisk, $diskStyle)
                mbMetricRow(xLoc("合并总览面板"), $mbCombined, nil)
                Divider().padding(.vertical, 2)
                VStack(alignment: .leading, spacing: 3) {
                    toggleRow(xLoc("彩色图标"), $mbColored)
                    Text(xLoc("关：随菜单栏深浅自动黑白（推荐，克制）；开：每指标按代表色着色"))
                        .font(XFont.caption).foregroundStyle(XColor.textTertiary)
                }
                HStack {
                    Text(xLoc("更新频率")).font(XFont.bodyEmphasis).foregroundStyle(XColor.textPrimary)
                    Spacer()
                    Picker("", selection: $mbInterval) {
                        Text(xLoc("快速（1 秒）")).tag(1.0)
                        Text(xLoc("标准（2 秒）")).tag(2.0)
                        Text(xLoc("省电（3 秒）")).tag(3.0)
                    }
                    .labelsHidden().pickerStyle(.menu).frame(width: 150)
                    .onChange(of: mbInterval) { model.applyRefreshInterval($0) }
                }
            }
        }
    }

    /// 单个菜单栏指标行：开关 +（开启时）该项独立的显示样式选择器。
    private func mbMetricRow(_ title: String, _ enabled: Binding<Bool>, _ style: Binding<String>?) -> some View {
        VStack(spacing: 6) {
            HStack {
                Text(title).font(XFont.bodyEmphasis).foregroundStyle(XColor.textPrimary)
                Spacer()
                Toggle("", isOn: enabled).toggleStyle(.switch).labelsHidden()
            }
            if enabled.wrappedValue, let style = style {
                HStack(spacing: XSpacing.s) {
                    Image(systemName: "slider.horizontal.3").font(.system(size: 10)).foregroundStyle(XColor.textTertiary)
                    Picker("", selection: style) {
                        ForEach(MenuBarStyle.allCases, id: \.rawValue) { st in
                            Text(st.title).tag(st.rawValue)
                        }
                    }
                    .labelsHidden().pickerStyle(.menu).frame(width: 160)
                    Spacer()
                }
                .padding(.leading, XSpacing.l)
                .padding(.bottom, 2)
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

    // MARK: 阈值告警

    private var alertsCard: some View {
        XCard {
            VStack(alignment: .leading, spacing: XSpacing.s) {
                HStack(spacing: XSpacing.m) {
                    XIconTile(systemImage: "bell.badge", colors: [XColor.warning, XColor.accentPink], size: 36)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(xLoc("阈值告警")).xHeadline().foregroundStyle(XColor.textPrimary)
                        Text(xLoc("指标持续越过阈值时发系统通知")).font(XFont.caption).foregroundStyle(XColor.textSecondary)
                    }
                    Spacer()
                }
                Divider().padding(.vertical, 2)
                ForEach(Array(model.alertRules.enumerated()), id: \.element.id) { idx, rule in
                    alertRuleRow(idx: idx, rule: rule)
                }
            }
        }
    }

    private func alertRuleRow(idx: Int, rule: AlertRule) -> some View {
        HStack(spacing: XSpacing.m) {
            VStack(alignment: .leading, spacing: 1) {
                Text(rule.metric.title).font(XFont.bodyEmphasis).foregroundStyle(XColor.textPrimary)
                Text(rule.durationSeconds > 0
                     ? xLocF("%@ 持续 %d 秒", rule.thresholdText, rule.durationSeconds)
                     : rule.thresholdText)
                    .font(XFont.caption).foregroundStyle(XColor.textSecondary)
            }
            Spacer()
            Picker("", selection: Binding(
                get: { rule.threshold },
                set: { newVal in
                    model.alertRules[idx].threshold = newVal
                    model.saveAlertRules()
                })) {
                ForEach(thresholdOptions(for: rule.metric), id: \.self) { v in
                    Text(rule.metric == .cpuTemp ? "\(Int(v))°C" : "\(Int(v * 100))%").tag(v)
                }
            }
            .labelsHidden().pickerStyle(.menu).frame(width: 92)
            Toggle("", isOn: Binding(
                get: { rule.enabled },
                set: { on in
                    model.alertRules[idx].enabled = on
                    model.saveAlertRules()
                })).toggleStyle(.switch).labelsHidden()
        }
        .padding(.vertical, 2)
    }

    private func thresholdOptions(for metric: AlertMetric) -> [Double] {
        switch metric {
        case .cpuTemp: return [80, 85, 90, 95, 100]
        case .battery: return [0.10, 0.15, 0.20, 0.30]
        default: return [0.70, 0.80, 0.85, 0.90, 0.95]
        }
    }

    private var permissionCard: some View {
        settingRow(icon: "externaldrive.fill.badge.checkmark",
                   colors: model.hasFullDiskAccess ? [XColor.accentTeal, XColor.success] : [XColor.warning, XColor.accentPink],
                   title: xLoc("完全磁盘访问权限"),
                   subtitle: model.hasFullDiskAccess ? xLoc("已授权 · 可扫描全部位置") : xLoc("未授权 · 部分垃圾扫不到")) {
            if model.hasFullDiskAccess {
                XBadge(xLoc("已开启"), color: XColor.success)
            } else {
                Button(xLoc("去开启")) { model.openFullDiskAccessSettings() }.buttonStyle(.bordered)
            }
        }
    }

    private var helperCard: some View {
        settingRow(icon: "gearshape.2.fill",
                   colors: helperStatus == .installed ? [XColor.accentTeal, XColor.success] : [XColor.auroraViolet, XColor.auroraRose],
                   title: xLoc("特权助手"),
                   subtitle: helperSubtitle) {
            switch helperStatus {
            case .installed: XBadge(xLoc("已就绪"), color: XColor.success)
            case .requiresApproval:
                Button(xLoc("去批准")) { model.env.helper.openLoginItemsSettings() }.buttonStyle(.bordered)
            default:
                Button(xLoc("安装")) {
                    do {
                        try model.env.helper.install()
                        helperStatus = model.env.helper.status()
                        if helperStatus == .requiresApproval { model.env.helper.openLoginItemsSettings() }
                    } catch {
                        helperError = "安装助手失败：\(error.localizedDescription)"
                    }
                }.buttonStyle(.bordered)
            }
        }
    }

    private var helperSubtitle: String {
        switch helperStatus {
        case .installed: return xLoc("已安装 · 维护中的系统级任务可用")
        case .requiresApproval: return xLoc("已注册 · 待在登录项中批准")
        case .unavailable: return xLoc("开发签名版本不可用 · 正式签名后可装")
        default: return xLoc("用于执行需管理员权限的维护任务")
        }
    }

    private var resetCard: some View {
        settingRow(icon: "arrow.counterclockwise", colors: [XColor.textTertiary, XColor.textSecondary],
                   title: xLoc("重新显示引导页"), subtitle: xLoc("下次启动时再次展示欢迎引导")) {
            Button(xLoc("重置")) {
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
