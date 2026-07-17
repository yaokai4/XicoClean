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
    @State private var showingLicenses = false
    // 菜单栏设置已迁出为独立「状态栏」页（MenuBarSettingsView，P0 IA 重组 docs/14）。

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
                    definitionsCard

                    sectionLabel("清理")
                    ignoreListCard
                    sentinelCard

                    sectionLabel("外观")
                    appearanceCard
                    soundCard
                    hapticsCard
                    languageCard
                    ThemePickerCard(selectedID: Binding(
                        get: { model.themeID },
                        set: { model.themeID = $0 }))

                    sectionLabel("监控与告警")
                    menuBarPointerRow
                    alertsCard

                    sectionLabel("权限与系统")
                    permissionCard
                    helperCard
                    diagnosticsCard
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
        .onReceive(NotificationCenter.default.publisher(for: .xicoOutcomeInvalidated)) { notification in
            guard let event = notification.object as? OutcomeInvalidationEvent,
                  event.domains.contains(.cleaningHistory) else { return }
            reloadHistory()
        }
        .onReceive(NotificationCenter.default.publisher(for: .xicoDidClean)) { _ in reloadHistory() }
        .sheet(isPresented: $showingLicenses) { OpenSourceLicensesView { showingLicenses = false } }
        .alert(xLoc("操作未完成"), isPresented: Binding(get: { helperError != nil }, set: { if !$0 { helperError = nil } })) {
            Button(xLoc("好"), role: .cancel) {}
        } message: {
            Text(helperError ?? "")
        }
        .alert(
            xLoc("历史记录未同步"),
            isPresented: Binding(
                get: { historyUndoWarning != nil },
                set: { if !$0 { historyUndoWarning = nil } })
        ) {
            Button(xLoc("好"), role: .cancel) { historyUndoWarning = nil }
        } message: {
            Text(historyUndoWarning ?? "")
        }
        .confirmationDialog(xLoc("清空清理历史？"), isPresented: $confirmClearHistory, titleVisibility: .visible) {
            Button(xLoc("清空记录（不可恢复）"), role: .destructive) {
                model.env.history.clear()
                reloadHistory()
            }
            Button(xLoc("取消"), role: .cancel) {}
        } message: {
            Text(xLoc("将清空全部清理历史，之后无法再从这里撤销这些清理。此操作不可恢复。"))
        }
        .confirmationDialog(xLoc("重新显示引导页？"), isPresented: $confirmReset, titleVisibility: .visible) {
            Button(xLoc("重置"), role: .destructive) {
                UserDefaults.standard.set(false, forKey: "xico.onboarded")
                UserDefaults.standard.set(false, forKey: "xico.fdaDismissed")
            }
            Button(xLoc("取消"), role: .cancel) {}
        } message: {
            Text(xLoc("下次启动 Xico 时会再次展示欢迎引导页。"))
        }
    }

    @State private var undoingID: UUID?
    @State private var historyUndoWarning: String?
    @State private var confirmClearHistory = false
    @State private var confirmReset = false

    private func reloadHistory() {
        history = model.env.history.recent(8)
        totalReclaimed = model.env.history.totalReclaimedAllTime
        totalCleanups = model.env.history.totalCleanups
    }

    /// 从历史记录跨会话撤销：把该次清理的废纸篓项放回原位。
    private func undoRecord(_ rec: CleaningRecord) {
        guard rec.canUndo, undoingID == nil else { return }
        undoingID = rec.id
        Task {
            let result = await model.env.cleaningEngine.undo(
                rec.restorable,
                parentID: rec.operationID)
            // 全成功：移除记录并回滚累计释放。部分失败：仅保留仍未恢复的项为可撤销，可重试。
            let historyResult: HistoryUpdateResult
            if result.payload.remaining.isEmpty, !rec.hasIrreversibleChanges {
                historyResult = model.env.historySink.remove(id: rec.id)
            } else {
                historyResult = model.env.historySink.updateRestorable(
                    id: rec.id,
                    to: result.payload.remaining)
            }
            switch historyResult {
            case .committed:
                historyUndoWarning = nil
            case .notFound:
                historyUndoWarning = xLoc("撤销结果已生效，但对应的历史记录已不存在。")
            case .rejected:
                historyUndoWarning = xLoc("撤销结果已生效，但清理历史未能同步更新。")
            }
            if let invalidation = ValidatedOutcomeInvalidation(
                outcome: result.outcome,
                domains: [.diskCapacity, .scanIndex, .cleaningHistory]) {
                _ = model.env.invalidationSink.publish(invalidation)
            }
            reloadHistory()
            undoingID = nil
        }
    }

    // MARK: 安全承诺（P4·C7：把最强的一层「说」出来——信任叙事产品化，对标 CleanMyMac Safety Database）

    private var safetyPromiseCard: some View {
        XCard {
            VStack(alignment: .leading, spacing: XSpacing.s) {
                HStack(spacing: XSpacing.m) {
                    XIconTile(systemImage: "checkmark.shield.fill", colors: [XColor.success, XColor.accentTeal], size: 36)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(xLoc("安全承诺")).xHeadline().foregroundStyle(XColor.textPrimary)
                        Text(xLoc("每一次删除都要过三道闸，这是 Xico 的底线")).font(XFont.caption).foregroundStyle(XColor.textSecondary)
                    }
                    Spacer()
                }
                Divider().padding(.vertical, XSpacing.xxs)
                promiseLine("nosign", XColor.danger,
                            xLoc("永不触碰红线"),
                            xLoc("系统关键路径、凭证与密钥（如 ~/.ssh、~/.aws）、云盘配置——规则库直接拒绝，无一例外"))
                promiseLine("checkmark.seal", XColor.brand,
                            xLoc("三道独立校验"),
                            xLoc("界面预检 → 安全引擎复检 → 特权助手删除前再复校，三处共用同一套规则库"))
                promiseLine("arrow.uturn.backward.circle", XColor.success,
                            xLoc("默认可撤销"),
                            xLoc("清理默认移入废纸篓、一键放回原位；彻底删除永远单独确认"))
                promiseLine("icloud.slash", XColor.textSecondary,
                            xLoc("数据不出本机"),
                            xLoc("扫描结果、清理历史、统计数据全部本地存储，绝不上传"))
            }
        }
    }

    private func promiseLine(_ icon: String, _ tint: Color, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: XSpacing.s) {
            Image(systemName: icon).font(XFont.callout).foregroundStyle(tint).frame(width: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(XFont.bodyEmphasis).foregroundStyle(XColor.textPrimary)
                Text(detail).font(XFont.caption).foregroundStyle(XColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
    }

    // MARK: 废纸篓哨兵（P4：删 App 入废纸篓 → 通知提示残留，点按直达卸载器）

    @AppStorage("xico.sentinel.enabled") private var sentinelEnabled = true

    private var sentinelCard: some View {
        settingRow(icon: "bell.badge", colors: [XColor.accentTeal, XColor.auroraBlue],
                   title: xLoc("删除 App 时提示残留"),
                   subtitle: xLoc("把 App 拖入废纸篓后自动检测其残留文件并发送通知，点按直达卸载器。只提示，绝不自动删除。")) {
            Toggle("", isOn: $sentinelEnabled).toggleStyle(XThemeSwitchStyle()).labelsHidden()
                .accessibilityLabel(xLoc("删除 App 时提示残留"))
                .onChange(of: sentinelEnabled) { model.setTrashSentinel(enabled: sentinelEnabled) }
        }
    }

    // MARK: 界面音效（三个签名音效的总开关）

    @AppStorage("xico.sound.enabled") private var soundEnabled = true

    private var soundCard: some View {
        settingRow(icon: "speaker.wave.2", colors: [XColor.ringMint, XColor.accentTeal],
                   title: xLoc("界面音效"), subtitle: xLoc("扫描完成 / 清理完成 / 删除执行的轻量提示音；跟随系统「界面声音」偏好")) {
            Toggle("", isOn: $soundEnabled).toggleStyle(XThemeSwitchStyle()).labelsHidden()
                .accessibilityLabel(xLoc("界面音效"))
        }
    }

    // MARK: 触感反馈（XHaptic 总开关，docs/16 P0-1 收尾）

    @AppStorage("xico.haptics.enabled") private var hapticsEnabled = true

    private var hapticsCard: some View {
        settingRow(icon: "hand.tap", colors: [XColor.ringLav, XColor.brand],
                   title: xLoc("触感反馈"), subtitle: xLoc("清理完成 / 拖拽吸附 / 阈值跨越时触控板轻震；无支持硬件时自动无效")) {
            Toggle("", isOn: $hapticsEnabled).toggleStyle(XThemeSwitchStyle()).labelsHidden()
                .accessibilityLabel(xLoc("触感反馈"))
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
                        Button(xLoc("清空记录")) { confirmClearHistory = true }
                            .buttonStyle(XSecondaryButtonStyle(compact: true))
                    }
                }
                // 价值账本（P6·2）：近 6 个月释放空间的月度条——「Xico 为你做了什么」一眼可见。
                // 数据源 = 既有清理历史（唯一事实源，无新增持久化）；纯本地，绝不上传。
                if totalCleanups > 0 {
                    ledgerBars
                    if let fun = spaceFunLine(totalReclaimed) {
                        Text(fun).font(XFont.caption).foregroundStyle(XColor.brand)
                    }
                    Text(xLoc("这些数据从不离开你的 Mac。"))
                        .font(XFont.micro).foregroundStyle(XColor.textTertiary)
                }
                if !history.isEmpty {
                    Divider().padding(.vertical, XSpacing.xxs)
                    ForEach(history) { rec in
                        HStack(spacing: XSpacing.m) {
                            Text(moduleLabel(rec.module)).font(XFont.bodyEmphasis).foregroundStyle(XColor.textPrimary)
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

    /// 近 6 个月的月度释放条形（按清理记录聚合；空月画基线点，诚实呈现「没清理」）。
    private var ledgerBars: some View {
        let cal = Calendar.current
        let now = Date()
        // 月锚点：本月起往前 6 个月。
        let months: [Date] = (0..<6).reversed().compactMap {
            cal.date(byAdding: .month, value: -$0, to: cal.dateInterval(of: .month, for: now)?.start ?? now)
        }
        let all = model.env.history.recent(10_000)
        let byMonth: [Date: Int64] = months.reduce(into: [:]) { acc, m in
            let next = cal.date(byAdding: .month, value: 1, to: m) ?? m
            acc[m] = all.filter { $0.date >= m && $0.date < next }.reduce(0) { $0 + $1.reclaimedBytes }
        }
        let maxV = max(byMonth.values.max() ?? 1, 1)
        let fmt: DateFormatter = {
            let f = DateFormatter()
            f.locale = XLocale.swiftUILocale
            f.setLocalizedDateFormatFromTemplate("MMM")
            return f
        }()
        return HStack(alignment: .bottom, spacing: XSpacing.m) {
            ForEach(months, id: \.self) { m in
                let v = byMonth[m] ?? 0
                VStack(spacing: 3) {
                    Text(v > 0 ? v.formattedBytes : "—")
                        .font(XFont.nano).foregroundStyle(v > 0 ? XColor.textSecondary : XColor.textTertiary)
                        .lineLimit(1).minimumScaleFactor(0.7)
                    Capsule()
                        .fill(v > 0 ? AnyShapeStyle(LinearGradient(colors: [XColor.accentTeal, XColor.success],
                                                                   startPoint: .bottom, endPoint: .top))
                                    : AnyShapeStyle(XColor.idle.opacity(0.4)))
                        .frame(height: v > 0 ? max(6, 44 * CGFloat(Double(v) / Double(maxV))) : 3)
                        .frame(maxWidth: .infinity)
                    Text(fmt.string(from: m)).font(XFont.nano).foregroundStyle(XColor.textTertiary)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(fmt.string(from: m)) · \(v.formattedBytes)")
            }
        }
        .padding(.top, XSpacing.xs)
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
                    Divider().padding(.vertical, XSpacing.xxs)
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

    /// 历史「模块」列显示时本地化——绝大多数记录以中文字面量为稳定键，直接 xLoc 即可。
    /// 卸载记录带动态应用名，存储为规范中文键「卸载 · <名>」，此处按显示语言重排前缀，
    /// 使切换语言后该行随之翻译（不再冻结在记录时的语言）。
    private func moduleLabel(_ module: String) -> String {
        let uninstallPrefix = "卸载 · "
        if module.hasPrefix(uninstallPrefix) {
            return xLocF("卸载 · %@", String(module.dropFirst(uninstallPrefix.count)))
        }
        return xLoc(module)
    }

    /// 关于卡：产品信息在左，主行动（检查更新 + 升级 Pro / 管理授权）紧贴其右——
    /// 不再有分隔横线，也不再把「导出诊断日志」挤在产品信息旁（用户反馈：横线多余、诊断日志应另放）。
    /// 诊断日志已下沉到「权限与系统 · 诊断日志」卡。Pro 入口常显：未激活 =「升级 Pro」主按钮；
    /// 已激活 =「管理授权」次按钮（这里是授权状态/换机释放的唯一入口，绝不能只在未激活时出现）。
    private var aboutCard: some View {
        XCard {
            VStack(spacing: XSpacing.m) {
                HStack(alignment: .top, spacing: XSpacing.l) {
                    XBrandMark(size: 56)
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: XSpacing.s) {
                            Text(xLoc("希可 Mac 清理")).xLargeTitle().foregroundStyle(XColor.textPrimary)
                            if licenseAllowsUse, case .licensed = (licenseStatus ?? model.env.license.status()).state {
                                XBadge("Pro", color: XColor.brand)
                            }
                        }
                        Text(xLoc("macOS 系统清理 · 磁盘管理 · 性能优化")).font(XFont.caption).foregroundStyle(XColor.textSecondary)
                        Text(xLocF("版本 %@", version)).font(XFont.caption).foregroundStyle(XColor.textTertiary)
                        HStack(spacing: XSpacing.s) {
                            Button(xLoc("隐私政策")) { NSWorkspace.shared.open(URL(string: "https://mac.xicoai.com/security")!) }
                                .buttonStyle(.link).font(XFont.caption)
                            Text("·").foregroundStyle(XColor.textTertiary)
                            Button(xLoc("许可协议")) { NSWorkspace.shared.open(URL(string: "https://xicoai.com/terms")!) }
                                .buttonStyle(.link).font(XFont.caption)
                            Text("·").foregroundStyle(XColor.textTertiary)
                            Button(xLoc("开源许可")) { showingLicenses = true }
                                .buttonStyle(.link).font(XFont.caption)
                        }
                    }
                    Spacer()
                    // 主行动紧贴产品信息右侧：付费主行动在上、检查更新在下。
                    VStack(alignment: .trailing, spacing: XSpacing.s) {
                        if licenseAllowsUse {
                            Button(xLoc("管理授权")) { model.showPricing = true }
                                .buttonStyle(XSecondaryButtonStyle(compact: true))
                        } else {
                            Button(xLoc("升级 Pro")) { model.showPricing = true }
                                .buttonStyle(XPrimaryButtonStyle(compact: true))
                        }
                        Button(checkingUpdate ? xLoc("检查中…") : xLoc("检查更新")) { checkForUpdate() }
                            .buttonStyle(XSecondaryButtonStyle(compact: true)).disabled(checkingUpdate)
                    }
                }
                if let msg = updateMessage {
                    Text(msg).font(XFont.caption).foregroundStyle(XColor.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    /// 诊断日志卡（从关于卡下沉至「权限与系统」）：导出最近运行日志便于反馈，绝无自动上报。
    private var diagnosticsCard: some View {
        settingRow(icon: "doc.text.magnifyingglass", colors: [XColor.textTertiary, XColor.textSecondary],
                   title: xLoc("诊断日志"), subtitle: xLoc("导出最近运行日志，便于反馈问题（不含任何自动上报）")) {
            Button(xLoc("导出")) { exportDiagnostics() }
                .buttonStyle(XSecondaryButtonStyle(compact: true))
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
                // DMG 字节完整性由 Gatekeeper/公证在安装时校验（App 不做应用内下载+sha256 逐字节比对）；
                // appcast 里的 sha256 仅用于加固已签名的 appcast 载荷，不作为下载物的独立校验（审计 SettingsView:302）。
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
        panel.nameFieldStringValue = xLoc("Xico-诊断日志.txt")
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if !XicoDiagnostics.export(to: url) {
            helperError = xLoc("导出诊断日志失败，请重试。")
        }
    }

    private var licenseAllowsUse: Bool {
        (licenseStatus ?? model.env.license.status()).state.allowsCommercialUse
    }

    private var definitionsCard: some View {
        XCard {
            VStack(alignment: .leading, spacing: XSpacing.s) {
                HStack(spacing: XSpacing.m) {
                    XIconTile(systemImage: "checkmark.shield.fill",
                              colors: definitionsTrusted ? [XColor.accentTeal, XColor.success] : [XColor.warning, XColor.accentPink],
                              size: 36)
                    VStack(alignment: .leading, spacing: 2) {
                        // 品牌化（P5）：规则库是数据资产也是信任资产——对标 MacPaw Safety Database 的叙事。
                        Text(xLoc("Xico 安全库")).xHeadline().foregroundStyle(XColor.textPrimary)
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
                    Divider().padding(.vertical, XSpacing.xxs)
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
        let lib = model.env.definitionsUpdater.currentLibrary()
        var parts = [xLocF("当前 v%@", "\(status.activeVersion)")]
        parts.append(xLocF("%d 条清理规则 · %d 条威胁特征", lib.definitions.count, lib.threatSignatures.count))
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
                // 规则库为实时热加载：更新后无需重启，下次扫描即采用新规则（审计 SettingsView:519 P3）。
                definitionsMessage = xLocF("已下载并验证规则库 v%@。下次扫描即生效，无需重启。", "\(library.version)")
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
                .accessibilityLabel(xLoc("外观"))
        }
    }

    private var languageCard: some View {
        settingRow(icon: "globe", colors: [XColor.accentTeal, XColor.auroraBlue],
                   title: xLoc("语言"), subtitle: xLoc("简体中文 / English / 日本語 · 即时切换")) {
            Picker("", selection: $model.language) {
                ForEach(XLang.allCases) { lang in Text(lang.nativeName).tag(lang) }
            }
            .labelsHidden().pickerStyle(.menu).frame(width: 160)
            .accessibilityLabel(xLoc("语言"))
        }
    }

    // MARK: 状态栏指引（菜单栏设置已迁出为独立页——侧边栏「性能与安全 · 状态栏」）

    private var menuBarPointerRow: some View {
        XCard {
            HStack(spacing: XSpacing.m) {
                XIconTile(systemImage: "menubar.rectangle", colors: XColor.metricCPU, size: 36)
                VStack(alignment: .leading, spacing: 2) {
                    Text(xLoc("菜单栏状态项")).xHeadline().foregroundStyle(XColor.textPrimary)
                    Text(xLoc("样式、排序与刷新频率已移至「状态栏」页")).font(XFont.caption).foregroundStyle(XColor.textSecondary)
                }
                Spacer()
                Button(xLoc("打开状态栏设置")) {
                    withAnimation(XMotion.snappy) { model.selection = .menuBar }
                }
                .buttonStyle(XSecondaryButtonStyle())
            }
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
                    // 新增规则：选指标即建一条该指标的合理默认规则（可再调阈值/开关/删除）。
                    Menu {
                        ForEach(AlertMetric.allCases, id: \.self) { metric in
                            Button(xLoc(metric.title)) { addAlertRule(metric: metric) }
                        }
                    } label: {
                        Label(xLoc("新增规则"), systemImage: "plus")
                            .font(XFont.captionEmphasis)
                    }
                    .fixedSize()
                    .accessibilityLabel(xLoc("新增规则"))
                }
                Divider().padding(.vertical, XSpacing.xxs)
                if model.alertRules.isEmpty {
                    Text(xLoc("暂无告警规则")).font(XFont.caption).foregroundStyle(XColor.textTertiary)
                        .padding(.vertical, XSpacing.xs)
                }
                ForEach(model.alertRules) { rule in
                    alertRuleRow(rule: rule)
                }
            }
        }
    }

    /// 新建某指标的规则：阈值/方向/持续时长取该指标的合理默认，落库即生效。
    private func addAlertRule(metric: AlertMetric) {
        let rule: AlertRule
        switch metric {
        case .battery: rule = AlertRule(metric: .battery, comparison: .below, threshold: 0.20, durationSeconds: 0)
        case .cpuTemp: rule = AlertRule(metric: .cpuTemp, comparison: .above, threshold: 95, durationSeconds: 10)
        case .disk:    rule = AlertRule(metric: .disk, comparison: .above, threshold: 0.92, durationSeconds: 0)
        default:       rule = AlertRule(metric: metric, comparison: .above, threshold: 0.90, durationSeconds: 20)
        }
        withAnimation(XMotion.snappy) { model.alertRules.append(rule) }
        model.saveAlertRules()
    }

    /// 规则行：指标 + 阈值文案 / 阈值下拉 / 启用开关 / 删除。
    /// 绑定按 id 反查而非缓存下标——支持增删后下标漂移不越界。
    private func alertRuleRow(rule: AlertRule) -> some View {
        HStack(spacing: XSpacing.m) {
            VStack(alignment: .leading, spacing: 1) {
                Text(xLoc(rule.metric.title)).font(XFont.bodyEmphasis).foregroundStyle(XColor.textPrimary)
                Text(rule.durationSeconds > 0
                     ? xLocF("%@ 持续 %d 秒", rule.thresholdText, rule.durationSeconds)
                     : rule.thresholdText)
                    .font(XFont.caption).monospacedDigit().foregroundStyle(XColor.textSecondary)
            }
            Spacer()
            Picker("", selection: Binding(
                get: { rule.threshold },
                set: { newVal in
                    guard let i = model.alertRules.firstIndex(where: { $0.id == rule.id }) else { return }
                    model.alertRules[i].threshold = newVal
                    model.saveAlertRules()
                })) {
                ForEach(thresholdOptions(for: rule.metric), id: \.self) { v in
                    Text(rule.metric == .cpuTemp ? "\(Int(v))°C" : "\(Int(v * 100))%").tag(v)
                }
            }
            .labelsHidden().pickerStyle(.menu).frame(width: 92)
            .accessibilityLabel(xLocF("%@ 告警阈值", xLoc(rule.metric.title)))
            Toggle("", isOn: Binding(
                get: { rule.enabled },
                set: { on in
                    guard let i = model.alertRules.firstIndex(where: { $0.id == rule.id }) else { return }
                    model.alertRules[i].enabled = on
                    model.saveAlertRules()
                })).toggleStyle(XThemeSwitchStyle()).labelsHidden()
                .accessibilityLabel(xLocF("%@ 告警开关", xLoc(rule.metric.title)))
            Button {
                withAnimation(XMotion.snappy) { model.alertRules.removeAll { $0.id == rule.id } }
                model.saveAlertRules()
            } label: {
                Image(systemName: "trash").font(XFont.caption).foregroundStyle(XColor.textTertiary)
            }
            .buttonStyle(.plain)
            .help(xLoc("删除规则"))
            .accessibilityLabel(xLocF("删除 %@ 规则", xLoc(rule.metric.title)))
        }
        .padding(.vertical, XSpacing.xxs)
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
            Button(xLoc("重置")) { confirmReset = true }
                .buttonStyle(XSecondaryButtonStyle(compact: true))
        }
    }

    /// 设置分区标题：把 14 张卡片按语义分组，扫读更轻松（授权/清理/外观/监控/权限）。
    private func sectionLabel(_ title: String) -> some View {
        Text(xLoc(title))
            .font(XFont.captionEmphasis).tracking(0.5).textCase(.uppercase)
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
