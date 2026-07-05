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
    // 每项独立的「图形加框」开关（只圈动态图形，数值永远在框外）。
    // 默认按图形类型校准：图表区图形（CPU 直方图 / 网络折线）加框；环/条裸露更干净（对齐 Sensei）。
    @AppStorage("xico.mb.cpu.border")     private var cpuBorder  = true
    @AppStorage("xico.mb.memory.border")  private var memBorder  = false
    @AppStorage("xico.mb.network.border") private var netBorder  = true
    @AppStorage("xico.mb.gpu.border")     private var gpuBorder  = false
    @AppStorage("xico.mb.disk.border")    private var diskBorder = false

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

                    sectionLabel("授权与更新")
                    licenseCard
                    definitionsCard

                    sectionLabel("清理")
                    historyCard
                    ignoreListCard

                    sectionLabel("外观")
                    appearanceCard
                    languageCard
                    ThemePickerCard(selectedID: Binding(
                        get: { model.themeID },
                        set: { model.themeID = $0 }))

                    sectionLabel("监控与告警")
                    menuBarCard
                    alertsCard

                    sectionLabel("权限与系统")
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
                            .buttonStyle(XSecondaryButtonStyle(compact: true))
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
                             : xLocF("%d 项已排除，永不扫描/清理", ignored.count))
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
                        .buttonStyle(XSecondaryButtonStyle(compact: true)).disabled(checkingUpdate)
                    Button(xLoc("升级 Pro")) { model.showPricing = true }
                        .buttonStyle(XPrimaryButtonStyle(compact: true))
                    Button(xLoc("导出诊断日志")) { exportDiagnostics() }
                        .buttonStyle(XSecondaryButtonStyle(compact: true))
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
                updateMessage = xLocF("已是最新版本（%@）。", version)
            case let .available(info):
                updateMessage = xLocF("发现新版本 %@，点击前往下载。", info.version)
                NSWorkspace.shared.open(info.downloadURL)
            case let .failed(reason):
                updateMessage = xLocF("检查更新失败：%@", reason)
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
                    Button(xLoc("导入许可证")) { importLicense() }.buttonStyle(XSecondaryButtonStyle(compact: true))
                    if licenseStatus?.licenseID != nil {
                        Button(xLoc("移除")) {
                            model.env.license.clearLicense()
                            licenseStatus = model.env.license.status()
                            model.refreshLicense()
                            licenseMessage = xLoc("已移除本机许可证。")
                        }
                        .buttonStyle(XSecondaryButtonStyle(compact: true))
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
                        XSpinner()
                    } else {
                        Button(xLoc("检查更新")) { refreshDefinitions() }
                            .buttonStyle(XSecondaryButtonStyle(compact: true))
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
                definitionsMessage = xLocF("已下载并验证规则库 v%@。重新启动 Xico 后生效。", "\(library.version)")
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
                    XIconTile(systemImage: "menubar.rectangle", colors: XColor.metricCPU, size: 36)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(xLoc("菜单栏状态项")).xHeadline().foregroundStyle(XColor.textPrimary)
                        Text(xLoc("选择常驻菜单栏显示哪些实时监控（可多选）")).font(XFont.caption).foregroundStyle(XColor.textSecondary)
                    }
                    Spacer()
                }
                Divider().padding(.vertical, 2)
                Text(xLoc("每项都能单独切换显示方式——直接点选下方图形（图标+数值 / 仅数值 / 迷你折线 / 可视化），像 iStat 一样可视化自定义"))
                    .font(XFont.caption).foregroundStyle(XColor.textSecondary)
                mbMetricRow(xLoc("处理器 CPU"), icon: "cpu", tint: XColor.metricCPU[0], $mbCPU, $cpuStyle, $cpuBorder)
                mbMetricRow(xLoc("内存"), icon: "memorychip", tint: XColor.metricMemory[0], $mbMemory, $memStyle, $memBorder)
                mbMetricRow(xLoc("网络速度"), icon: "antenna.radiowaves.left.and.right", tint: XColor.metricNetwork[0], $mbNetwork, $netStyle, $netBorder)
                mbMetricRow(xLoc("处理器温度"), icon: "thermometer.medium", tint: XColor.warning, $mbTemp, $tempStyle, nil)
                mbMetricRow(xLoc("GPU 占用"), icon: "cpu.fill", tint: XColor.metricGPU[0], $mbGPU, $gpuStyle, $gpuBorder)
                mbMetricRow(xLoc("磁盘占用"), icon: "internaldrive", tint: XColor.metricDisk[0], $mbDisk, $diskStyle, $diskBorder)
                mbMetricRow(xLoc("合并总览面板"), icon: "gauge.with.dots.needle.50percent", tint: XColor.textSecondary, $mbCombined, nil, nil)
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

    /// 单个菜单栏指标行：图标 + 开关 +（开启时）可视化样式选择器（点选图形，非文字下拉）+ 加框开关。
    private func mbMetricRow(_ title: String, icon: String, tint: Color, _ enabled: Binding<Bool>, _ style: Binding<String>?, _ border: Binding<Bool>?) -> some View {
        VStack(spacing: 8) {
            HStack(spacing: XSpacing.s) {
                Image(systemName: icon).font(.system(size: 12, weight: .semibold)).foregroundStyle(tint).frame(width: 18)
                Text(title).font(XFont.bodyEmphasis).foregroundStyle(XColor.textPrimary)
                Spacer()
                Toggle("", isOn: enabled).toggleStyle(.switch).labelsHidden()
            }
            if enabled.wrappedValue, let style = style {
                let framed = border?.wrappedValue ?? false
                HStack(spacing: 6) {
                    ForEach(MenuBarStyle.allCases, id: \.rawValue) { st in
                        MBStyleTile(style: st, tint: tint, icon: icon, framed: framed,
                                    selected: style.wrappedValue == st.rawValue) {
                            withAnimation(XMotion.snappy) { style.wrappedValue = st.rawValue }
                        }
                    }
                }
                .padding(.leading, XSpacing.l + 6)
                // 「图形加框」开关：只在当前样式含动态图形（迷你折线 / 可视化）时才有意义。
                if let border = border, style.wrappedValue == MenuBarStyle.graph.rawValue || style.wrappedValue == MenuBarStyle.rich.rawValue {
                    HStack(spacing: XSpacing.s) {
                        Image(systemName: "square.dashed").font(.system(size: 10, weight: .semibold)).foregroundStyle(XColor.textTertiary)
                        Text(xLoc("图形加框")).font(XFont.caption).foregroundStyle(XColor.textSecondary)
                        Spacer()
                        Toggle("", isOn: border).toggleStyle(.switch).labelsHidden().scaleEffect(0.8)
                    }
                    .padding(.leading, XSpacing.l + 6)
                    .padding(.bottom, 2)
                }
            }
        }
        .padding(.vertical, 1)
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
                Text(xLoc(rule.metric.title)).font(XFont.bodyEmphasis).foregroundStyle(XColor.textPrimary)
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
                Button(xLoc("去开启")) { model.openFullDiskAccessSettings() }.buttonStyle(XSecondaryButtonStyle(compact: true))
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
                Button(xLoc("去批准")) { model.env.helper.openLoginItemsSettings() }.buttonStyle(XSecondaryButtonStyle(compact: true))
            default:
                Button(xLoc("安装")) {
                    do {
                        try model.env.helper.install()
                        helperStatus = model.env.helper.status()
                        if helperStatus == .requiresApproval { model.env.helper.openLoginItemsSettings() }
                    } catch {
                        helperError = xLocF("安装助手失败：%@", error.localizedDescription)
                    }
                }.buttonStyle(XSecondaryButtonStyle(compact: true))
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
            }.buttonStyle(XSecondaryButtonStyle(compact: true))
        }
    }

    /// 设置分区标题：把 14 张卡片按语义分组，扫读更轻松（授权/清理/外观/监控/权限）。
    private func sectionLabel(_ title: String) -> some View {
        Text(xLoc(title))
            .font(.system(size: 11, weight: .semibold)).tracking(0.5).textCase(.uppercase)
            .foregroundStyle(XColor.textTertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, XSpacing.m).padding(.leading, XSpacing.xs)
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

// MARK: - 菜单栏显示样式：可视化选择器磁贴（点图形选样式，像 iStat）

/// 一枚样式磁贴：上方是该样式的真实缩影（图标+数值 / 纯数值 / 迷你折线 / 直方图），
/// 下方短标签。选中态描品牌边、淡底。让用户「看着图形选」，而不是读文字下拉。
private struct MBStyleTile: View {
    let style: MenuBarStyle
    let tint: Color
    let icon: String
    var framed: Bool = false
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 5) {
                preview
                    .foregroundStyle(selected ? tint : XColor.textSecondary)
                    .frame(height: 15)
                Text(style.shortTitle)
                    .font(.system(size: 9, weight: selected ? .semibold : .regular))
                    .foregroundStyle(selected ? XColor.brand : XColor.textTertiary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: XRadius.control, style: .continuous)
                .fill(selected ? XColor.brand.opacity(0.12) : XColor.surfaceAlt.opacity(0.5)))
            .overlay(RoundedRectangle(cornerRadius: XRadius.control, style: .continuous)
                .strokeBorder(selected ? XColor.brand : XColor.border, lineWidth: selected ? 1.5 : 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(style.title)
    }

    /// 图形加软框——与真实字形 1:1（graph/rich 才有动态图形可框；iconValue/valueOnly 无框）。
    @ViewBuilder private func chipped<V: View>(_ content: V) -> some View {
        if framed {
            content
                .padding(.horizontal, 2.5).padding(.vertical, 1)
                .background(RoundedRectangle(cornerRadius: 3.5, style: .continuous).fill((selected ? tint : XColor.textSecondary).opacity(0.09)))
                .overlay(RoundedRectangle(cornerRadius: 3.5, style: .continuous).strokeBorder((selected ? tint : XColor.textSecondary).opacity(0.3), lineWidth: 1))
        } else {
            content
        }
    }

    @ViewBuilder private var preview: some View {
        switch style {
        case .iconValue:
            HStack(spacing: 2) {
                Image(systemName: icon).font(.system(size: 9.5, weight: .semibold))
                Text("42%").font(.system(size: 9.5, weight: .semibold, design: .rounded)).monospacedDigit()
            }
        case .valueOnly:
            Text("42%").font(.system(size: 11, weight: .semibold, design: .rounded)).monospacedDigit()
        case .graph:
            HStack(spacing: 2) {
                chipped(MBSparkPreview())
                Text("42%").font(.system(size: 9, weight: .semibold, design: .rounded)).monospacedDigit()
            }
        case .rich:
            HStack(spacing: 2) {
                chipped(MBHistoPreview())
                Text("42%").font(.system(size: 9, weight: .semibold, design: .rounded)).monospacedDigit()
            }
        }
    }
}

private struct MBSparkPreview: View {
    private let pts: [Double] = [0.30, 0.50, 0.34, 0.62, 0.42, 0.72, 0.5, 0.82]
    var body: some View {
        GeometryReader { g in
            Path { p in
                let w = g.size.width, h = g.size.height
                for (i, v) in pts.enumerated() {
                    let x = w * CGFloat(i) / CGFloat(pts.count - 1)
                    let y = h * (1 - CGFloat(v))
                    if i == 0 { p.move(to: CGPoint(x: x, y: y)) } else { p.addLine(to: CGPoint(x: x, y: y)) }
                }
            }
            .stroke(style: StrokeStyle(lineWidth: 1.3, lineCap: .round, lineJoin: .round))
        }
        .frame(width: 22, height: 12)
    }
}

private struct MBHistoPreview: View {
    private let bars: [Double] = [0.4, 0.7, 0.45, 0.9, 0.55, 0.8, 0.5]
    var body: some View {
        HStack(alignment: .bottom, spacing: 1.5) {
            ForEach(Array(bars.enumerated()), id: \.offset) { _, v in
                RoundedRectangle(cornerRadius: 0.5)
                    .opacity(0.4 + 0.6 * v)
                    .frame(width: 2, height: max(2, 12 * CGFloat(v)))
            }
        }
        .frame(width: 22, height: 12, alignment: .bottom)
    }
}
