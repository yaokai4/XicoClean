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
    @State private var activationKey = ""
    // 菜单栏（P3 IA 重组：预设 → 项目列表（排序+开关）→ 逐项详情 → 全局）。
    // 僵尸键清理：全局 xico.mb.style 与逐项 .border 键已废除（控制器早已不读，
    // 「看起来能调、实际半瘫」比不能调更伤信任——P3·M8）。
    @AppStorage("xico.mb.interval") private var mbInterval = 2.0
    // 默认单色（模板图，随菜单栏深浅自动黑/白）——克制、像 Sensei/iStat 默认那样不刺眼。
    // 彩虹极光留给点开后的详情面板与 App 内部。想要彩色菜单栏的用户可自行打开。
    @AppStorage("xico.mb.colored") private var mbColored = false
    @AppStorage("xico.mb.order") private var mbOrderCSV = ""
    @AppStorage("xico.mb.combined.values") private var mbCombinedValues = false
    /// 展开逐项详情的条目（同一时间只展开一个——渐进披露，防设置迷宫）。
    @State private var mbExpanded: String?

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
                    safetyPromiseCard
                    historyCard
                    ignoreListCard

                    sectionLabel("外观")
                    appearanceCard
                    soundCard
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
        .confirmationDialog(xLoc("清空清理历史？"), isPresented: $confirmClearHistory, titleVisibility: .visible) {
            Button(xLoc("清空记录（不可恢复）"), role: .destructive) {
                model.env.history.clear()
                reloadHistory()
            }
            Button(xLoc("取消"), role: .cancel) {}
        } message: {
            Text(xLoc("将清空全部清理历史，之后无法再从这里撤销这些清理。此操作不可恢复。"))
        }
        .confirmationDialog(xLoc("移除本机许可证？"), isPresented: $confirmRemoveLicense, titleVisibility: .visible) {
            Button(xLoc("移除许可证"), role: .destructive) { removeLicense() }
            Button(xLoc("取消"), role: .cancel) {}
        } message: {
            Text(xLoc("将从本机删除已安装的许可证与激活状态，需重新导入或激活才能继续使用 Pro 功能。"))
        }
        .confirmationDialog(xLoc("释放本机授权？"), isPresented: $confirmReleaseDevice, titleVisibility: .visible) {
            Button(xLoc("释放此设备"), role: .destructive) { releaseThisDevice() }
            Button(xLoc("取消"), role: .cancel) {}
        } message: {
            Text(xLoc("将向服务器释放本机占用的授权名额并移除本机许可证，之后需重新激活才能继续使用 Pro 功能。适合换机/换主板前腾出名额。"))
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
    @State private var confirmClearHistory = false
    @State private var confirmRemoveLicense = false
    @State private var confirmReleaseDevice = false
    @State private var releasingDevice = false
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

    // MARK: 界面音效（三个签名音效的总开关）

    @AppStorage("xico.sound.enabled") private var soundEnabled = true

    private var soundCard: some View {
        settingRow(icon: "speaker.wave.2", colors: [XColor.ringMint, XColor.accentTeal],
                   title: xLoc("界面音效"), subtitle: xLoc("扫描完成 / 清理完成 / 删除执行的轻量提示音；跟随系统「界面声音」偏好")) {
            Toggle("", isOn: $soundEnabled).toggleStyle(.switch).labelsHidden()
                .accessibilityLabel(xLoc("界面音效"))
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

    private var aboutCard: some View {
        XCard {
            HStack(spacing: XSpacing.l) {
                XBrandMark(size: 56)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Xico").xLargeTitle().foregroundStyle(XColor.textPrimary)
                    Text(xLoc("macOS 系统清理 · 磁盘管理 · 性能优化")).font(XFont.caption).foregroundStyle(XColor.textSecondary)
                    Text(xLocF("版本 %@", version)).font(XFont.caption).foregroundStyle(XColor.textTertiary)
                    HStack(spacing: XSpacing.s) {
                        Button(xLoc("隐私政策")) { NSWorkspace.shared.open(URL(string: "https://mac.xicoai.com/security")!) }
                            .buttonStyle(.link).font(XFont.caption)
                        Text("·").foregroundStyle(XColor.textTertiary)
                        Button(xLoc("许可协议")) { NSWorkspace.shared.open(URL(string: "https://xicoai.com/terms")!) }
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
                        Button(xLoc("移除")) { confirmRemoveLicense = true }
                            .buttonStyle(XSecondaryButtonStyle(compact: true))
                    }
                }
                HStack(spacing: XSpacing.s) {
                    TextField(xLoc("输入 18 位激活码"), text: $activationKey)
                        .textFieldStyle(.roundedBorder)
                        .disabled(model.activating)
                        .onSubmit { activateKey() }
                    Button(model.activating ? xLoc("激活中…") : xLoc("激活")) { activateKey() }
                        .buttonStyle(XPrimaryButtonStyle(compact: true))
                        .disabled(model.activating || activationKey.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                if let licenseMessage {
                    Divider().padding(.vertical, XSpacing.xxs)
                    Text(licenseMessage)
                        .font(XFont.caption)
                        .foregroundStyle(XColor.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                // 换机自助：在旧机主动向服务器释放本机席位，腾出授权名额（避免新机撞「授权台数已达上限」）。
                if (licenseStatus ?? model.env.license.status()).licenseID != nil {
                    Button(releasingDevice ? xLoc("释放中…") : xLoc("换机？释放此设备授权")) {
                        confirmReleaseDevice = true
                    }
                    .buttonStyle(.link)
                    .font(XFont.caption)
                    .disabled(releasingDevice)
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

    private func activateKey() {
        let key = activationKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, !model.activating else { return }
        Task {
            let result = await model.activateLicense(key: key)
            switch result {
            case .success:
                licenseStatus = model.env.license.status()
                licenseMessage = xLoc("激活成功，感谢支持！")
            case let .failure(err):
                // 席位已满：除了服务器文案，再补一句自助恢复引导（换机用户可在旧机释放名额后重试）。
                if case LicenseActivationError.seatLimit = err {
                    licenseMessage = err.localizedDescription + "\n"
                        + xLoc("换了新机器？请在旧设备的设置里点『释放此设备』腾出名额后重试，或联系我们协助。")
                } else {
                    licenseMessage = err.localizedDescription
                }
            }
        }
    }

    /// 移除本机许可证：删除已安装的许可证文件并刷新状态。
    /// clearLicense() 只删许可证文件，不清激活锚点——见 cross_file_note（WS license）。
    private func removeLicense() {
        model.env.license.clearLicense()
        licenseStatus = model.env.license.status()
        model.refreshLicense()
        licenseMessage = xLoc("已移除本机许可证。")
    }

    /// 释放本机席位：换机/换主板前在旧机主动向服务器释放一个授权名额，避免迁移后撞上「授权台数已达上限」。
    /// 成功后清除本地许可并刷新状态（与 PricingView.deactivateThisDevice 同一契约，审计 CONTRACT (d)）。
    private func releaseThisDevice() {
        guard let licenseID = (licenseStatus ?? model.env.license.status()).licenseID,
              !releasingDevice else { return }
        releasingDevice = true
        Task {
            defer { releasingDevice = false }
            do {
                try await LicenseActivationClient().deactivate(
                    licenseId: licenseID,
                    deviceId: DeviceIdentity.current(),
                )
                // 记录本机已释放：与 PricingView.deactivateThisDevice 同一契约——
                // 否则把旧信封重新导入即可复活席位，绕过座席上限（审计 P2 SettingsView:423）。
                model.env.license.recordReleased(licenseID: licenseID, deviceId: DeviceIdentity.current())
                model.env.license.clearLicense()
                licenseStatus = model.env.license.status()
                model.refreshLicense()
                licenseMessage = xLoc("已释放本机授权，可在新设备重新激活。")
            } catch {
                licenseMessage = error.localizedDescription
            }
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
            // 手动导入须启用「已释放席位」拦截，与 PricingView.importLicense 一致：
            // 换机点了「释放本机授权」后，把旧信封重新导入不能再复活席位（须重新在线激活腾额）。
            licenseStatus = try model.env.license.installLicense(fromEnvelopeData: data, enforceReleased: true)
            model.refreshLicense()
            // 导入即强制在线复验，与 PricingView 导入路径一致：服务端已吊销/退款但尚未进入
            // 本地名单的副本在导入当刻即被拦截，而非拖到下一次节流复验（审计 SettingsView:442 P3）。
            model.revalidateLicenseOnline(force: true)
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

    // MARK: 菜单栏（P3 IA：预设 → 项目列表（排序+开关）→ 逐项详情 → 全局；四层渐进披露防设置迷宫）

    /// 菜单栏项元数据（顺序 = 默认显示顺序左→右，与 MenuBarController.config 对齐）。
    private struct MBItem: Identifiable {
        let id: String
        let title: String
        let icon: String
        let tint: Color
        let defOn: Bool
        let defStyle: MenuBarStyle
        /// 该项可选的样式集合（网络/温度无占比 → 无圆环；电池/温度无图表 → 无迷你图/可视化；合并项无样式）。
        let styles: [MenuBarStyle]
    }

    private var mbItems: [MBItem] {
        [
            MBItem(id: "network", title: xLoc("网络速度"), icon: "antenna.radiowaves.left.and.right",
                   tint: XColor.metricNetwork[0], defOn: true, defStyle: .graph,
                   styles: [.iconValue, .valueOnly, .graph, .rich]),
            MBItem(id: "disk", title: xLoc("磁盘占用"), icon: "internaldrive",
                   tint: XColor.metricDisk[0], defOn: false, defStyle: .iconValue,
                   styles: [.iconValue, .valueOnly, .rich, .ring]),
            MBItem(id: "temp", title: xLoc("处理器温度"), icon: "thermometer.medium",
                   tint: XColor.warning, defOn: false, defStyle: .iconValue,
                   styles: [.iconValue, .valueOnly]),
            MBItem(id: "battery", title: xLoc("电池"), icon: "battery.100percent",
                   tint: XColor.success, defOn: false, defStyle: .iconValue,
                   styles: [.iconValue, .valueOnly, .ring]),
            MBItem(id: "gpu", title: xLoc("GPU 占用"), icon: "cpu.fill",
                   tint: XColor.metricGPU[0], defOn: false, defStyle: .rich,
                   styles: [.iconValue, .valueOnly, .graph, .rich, .ring]),
            MBItem(id: "memory", title: xLoc("内存"), icon: "memorychip",
                   tint: XColor.metricMemory[0], defOn: true, defStyle: .rich,
                   styles: [.iconValue, .valueOnly, .graph, .rich, .ring]),
            MBItem(id: "cpu", title: xLoc("处理器 CPU"), icon: "cpu",
                   tint: XColor.metricCPU[0], defOn: true, defStyle: .rich,
                   styles: [.iconValue, .valueOnly, .graph, .rich, .ring]),
            MBItem(id: "combined", title: xLoc("合并项（多迷你图并排）"), icon: "gauge.with.dots.needle.50percent",
                   tint: XColor.textSecondary, defOn: false, defStyle: .rich, styles: []),
        ]
    }

    /// 用户顺序（左→右）；新增项自动补到末尾。
    private var mbOrder: [String] {
        let all = mbItems.map(\.id)
        let saved = mbOrderCSV.split(separator: ",").map(String.init).filter { all.contains($0) }
        guard !saved.isEmpty else { return all }
        return saved + all.filter { !saved.contains($0) }
    }

    private func moveMB(_ id: String, up: Bool) {
        var order = mbOrder
        guard let i = order.firstIndex(of: id) else { return }
        let j = up ? i - 1 : i + 1
        guard j >= 0, j < order.count else { return }
        order.swapAt(i, j)
        withAnimation(XMotion.snappy) { mbOrderCSV = order.joined(separator: ",") }
    }

    // UserDefaults 直连绑定（@AppStorage 无法表达「每项动态键」与三态）。
    private func mbBool(_ key: String, default def: Bool) -> Binding<Bool> {
        Binding(get: { UserDefaults.standard.object(forKey: key) == nil ? def : UserDefaults.standard.bool(forKey: key) },
                set: { UserDefaults.standard.set($0, forKey: key) })
    }
    private func mbStyleBinding(_ item: MBItem) -> Binding<String> {
        Binding(get: { UserDefaults.standard.string(forKey: "xico.mb.\(item.id).style") ?? item.defStyle.rawValue },
                set: { UserDefaults.standard.set($0, forKey: "xico.mb.\(item.id).style") })
    }
    /// 三态彩色：global（跟随全局开关）/ mono / colored。
    private func mbColorBinding(_ id: String) -> Binding<String> {
        let key = "xico.mb.\(id).colored"
        return Binding(get: {
            guard UserDefaults.standard.object(forKey: key) != nil else { return "global" }
            return UserDefaults.standard.bool(forKey: key) ? "colored" : "mono"
        }, set: { v in
            switch v {
            case "colored": UserDefaults.standard.set(true, forKey: key)
            case "mono":    UserDefaults.standard.set(false, forKey: key)
            default:        UserDefaults.standard.removeObject(forKey: key)
            }
        })
    }
    /// 每项独立刷新率：0 = 跟随全局节拍。
    private func mbIntervalBinding(_ id: String) -> Binding<Double> {
        let key = "xico.mb.\(id).interval"
        return Binding(get: { UserDefaults.standard.double(forKey: key) },
                       set: { v in
                           if v <= 0 { UserDefaults.standard.removeObject(forKey: key) }
                           else { UserDefaults.standard.set(v, forKey: key) }
                       })
    }

    private var menuBarCard: some View {
        XCard {
            VStack(alignment: .leading, spacing: XSpacing.s) {
                HStack(spacing: XSpacing.m) {
                    XIconTile(systemImage: "menubar.rectangle", colors: XColor.metricCPU, size: 36)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(xLoc("菜单栏状态项")).xHeadline().foregroundStyle(XColor.textPrimary)
                        Text(xLoc("一键预设开箱即好看；想细调再逐项展开")).font(XFont.caption).foregroundStyle(XColor.textSecondary)
                    }
                    Spacer()
                }
                Divider().padding(.vertical, XSpacing.xxs)

                // 第一层：一键预设（真实字形缩影预览）。
                HStack(spacing: XSpacing.s) {
                    mbPresetCard(xLoc("极简"), desc: xLoc("单一合并项 · 单色"), preview: presetPreviewMinimal) { applyPreset("minimal") }
                    mbPresetCard(xLoc("性能"), desc: xLoc("CPU + 内存 + GPU"), preview: presetPreviewPerformance) { applyPreset("performance") }
                    mbPresetCard(xLoc("全景"), desc: xLoc("五项常驻 · 彩色"), preview: presetPreviewPanorama) { applyPreset("panorama") }
                }

                Divider().padding(.vertical, XSpacing.xxs)

                // 第二层：项目列表（排序 + 开关）；第三层：点行展开逐项详情。
                ForEach(Array(mbOrder.enumerated()), id: \.element) { idx, id in
                    if let item = mbItems.first(where: { $0.id == id }) {
                        mbItemRow(item, index: idx, count: mbOrder.count)
                    }
                }

                Divider().padding(.vertical, XSpacing.xxs)

                // 第四层：全局。
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
                    .accessibilityLabel(xLoc("更新频率"))
                    .onChange(of: mbInterval) { model.applyRefreshInterval(mbInterval) }
                }
            }
        }
    }

    // MARK: 预设卡（真实字形渲染的缩影，点击一键应用；应用后仍可逐项微调）

    private static let mbDemoHist: [Double] = [0.3, 0.5, 0.4, 0.7, 0.6, 0.8, 0.5, 0.9, 0.7, 0.6, 0.8, 0.7, 0.62]

    private var presetPreviewMinimal: NSImage {
        MenuBarGlyph.combined(slots: [
            MenuCombinedSlot(viz: .histogram(Self.mbDemoHist), tint: XColor.metricCPU),
            MenuCombinedSlot(viz: .pie(0.71), tint: XColor.metricMemory),
            MenuCombinedSlot(viz: .net(down: "1.2M", up: "386K"), tint: XColor.metricNetwork),
        ])
    }
    private var presetPreviewPerformance: NSImage {
        MenuBarGlyph.combined(slots: [
            MenuCombinedSlot(viz: .histogram(Self.mbDemoHist), tint: XColor.metricCPU, value: "62%"),
            MenuCombinedSlot(viz: .pie(0.71), tint: XColor.metricMemory, value: "71%"),
            MenuCombinedSlot(viz: .pie(0.26), tint: XColor.metricGPU, value: "26%"),
        ])
    }
    private var presetPreviewPanorama: NSImage {
        MenuBarGlyph.combined(slots: [
            MenuCombinedSlot(viz: .histogram(Self.mbDemoHist), tint: XColor.metricCPU),
            MenuCombinedSlot(viz: .pie(0.71), tint: XColor.metricMemory),
            MenuCombinedSlot(viz: .net(down: "1.2M", up: "386K"), tint: XColor.metricNetwork),
            MenuCombinedSlot(viz: .text("44°"), tint: [XColor.warning]),
            MenuCombinedSlot(viz: .pie(0.39), tint: XColor.metricDisk),
        ])
    }

    private func mbPresetCard(_ title: String, desc: String, preview: NSImage, apply: @escaping () -> Void) -> some View {
        Button(action: apply) {
            VStack(spacing: 5) {
                Image(nsImage: preview)
                    .renderingMode(.template)
                    .foregroundStyle(XColor.textPrimary)
                    .frame(height: 18)
                    .scaleEffect(0.9)
                Text(title).font(XFont.captionEmphasis).foregroundStyle(XColor.textPrimary)
                Text(desc).font(XFont.nano).foregroundStyle(XColor.textTertiary).lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, XSpacing.s)
            .background(RoundedRectangle(cornerRadius: XRadius.control, style: .continuous)
                .fill(XColor.surfaceAlt.opacity(0.5)))
            .overlay(RoundedRectangle(cornerRadius: XRadius.control, style: .continuous)
                .strokeBorder(XColor.border, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title + " · " + desc)
    }

    /// 一键预设：写一组 xico.mb.* 键，MenuBarController 经 defaults 快照比对自动重建。
    private func applyPreset(_ name: String) {
        let d = UserDefaults.standard
        let allIDs = mbItems.map(\.id)
        func enable(_ ids: [String]) {
            for id in allIDs { d.set(ids.contains(id), forKey: "xico.mb.\(id)") }
        }
        switch name {
        case "minimal":
            enable(["combined"])
            for id in allIDs { d.removeObject(forKey: "xico.mb.combined.\(id)") }   // 恢复默认 cpu+mem+net
            mbColored = false
        case "performance":
            enable(["cpu", "memory", "gpu"])
            d.set(MenuBarStyle.rich.rawValue, forKey: "xico.mb.cpu.style")
            d.set(MenuBarStyle.rich.rawValue, forKey: "xico.mb.memory.style")
            d.set(MenuBarStyle.rich.rawValue, forKey: "xico.mb.gpu.style")
            mbColored = false
        default:   // panorama
            enable(["cpu", "memory", "network", "temp", "disk"])
            d.set(MenuBarStyle.rich.rawValue, forKey: "xico.mb.cpu.style")
            d.set(MenuBarStyle.rich.rawValue, forKey: "xico.mb.memory.style")
            d.set(MenuBarStyle.graph.rawValue, forKey: "xico.mb.network.style")
            mbColored = true
        }
        withAnimation(XMotion.snappy) { mbExpanded = nil }
    }

    // MARK: 项目行（开关 + 上下排序 + 展开逐项详情）

    private func mbItemRow(_ item: MBItem, index: Int, count: Int) -> some View {
        let enabled = mbBool("xico.mb.\(item.id)", default: item.defOn)
        let expanded = mbExpanded == item.id
        return VStack(spacing: 8) {
            HStack(spacing: XSpacing.s) {
                // 排序（上/下移，键盘可达——比裸拖拽更可靠、可无障碍）。
                VStack(spacing: 0) {
                    Button { moveMB(item.id, up: true) } label: {
                        Image(systemName: "chevron.up").font(XFont.nano)
                    }.buttonStyle(.plain).disabled(index == 0)
                        .accessibilityLabel(xLocF("上移 %@", item.title))
                    Button { moveMB(item.id, up: false) } label: {
                        Image(systemName: "chevron.down").font(XFont.nano)
                    }.buttonStyle(.plain).disabled(index == count - 1)
                        .accessibilityLabel(xLocF("下移 %@", item.title))
                }
                .foregroundStyle(XColor.textTertiary)
                Image(systemName: item.icon).font(XFont.callout).foregroundStyle(item.tint).frame(width: 18)
                Text(item.title).font(XFont.bodyEmphasis).foregroundStyle(XColor.textPrimary)
                if enabled.wrappedValue {
                    Button {
                        withAnimation(XMotion.snappy) { mbExpanded = expanded ? nil : item.id }
                    } label: {
                        Image(systemName: "chevron.right")
                            .font(XFont.nano).foregroundStyle(XColor.textTertiary)
                            .rotationEffect(.degrees(expanded ? 90 : 0))
                            .frame(width: 16, height: 16)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(xLocF("展开 %@ 详情", item.title))
                }
                Spacer()
                Toggle("", isOn: enabled).toggleStyle(.switch).labelsHidden()
                    .accessibilityLabel(item.title)
            }
            if enabled.wrappedValue, expanded {
                mbItemDetail(item)
                    .padding(.leading, XSpacing.xl + 2)
                    .transition(.opacity)
            }
        }
        .padding(.vertical, 1)
    }

    /// 第三层：逐项详情（样式磁贴 + 彩色三态 + 独立刷新率；合并项 = 子项勾选 + 显示数值）。
    @ViewBuilder private func mbItemDetail(_ item: MBItem) -> some View {
        VStack(alignment: .leading, spacing: XSpacing.s) {
            if item.id == "combined" {
                Text(xLoc("包含哪些指标（用各指标自己的紧凑图形）"))
                    .font(XFont.caption).foregroundStyle(XColor.textSecondary)
                ForEach(mbItems.filter { $0.id != "combined" }) { sub in
                    HStack {
                        Image(systemName: sub.icon).font(XFont.caption).foregroundStyle(sub.tint).frame(width: 16)
                        Text(sub.title).font(XFont.body).foregroundStyle(XColor.textPrimary)
                        Spacer()
                        Toggle("", isOn: mbBool("xico.mb.combined.\(sub.id)",
                                                default: ["cpu", "memory", "network"].contains(sub.id)))
                            .toggleStyle(.switch).labelsHidden().controlSize(.mini)
                            .accessibilityLabel(sub.title)
                    }
                }
                toggleRow(xLoc("图形旁显示数值"), $mbCombinedValues)
            } else if !item.styles.isEmpty {
                let styleBinding = mbStyleBinding(item)
                HStack(spacing: 6) {
                    ForEach(item.styles, id: \.rawValue) { st in
                        MBStyleTile(style: st, tint: item.tint, icon: item.icon, framed: true,
                                    selected: styleBinding.wrappedValue == st.rawValue) {
                            withAnimation(XMotion.snappy) { styleBinding.wrappedValue = st.rawValue }
                        }
                    }
                }
            }
            if item.id != "combined" {
                HStack(spacing: XSpacing.l) {
                    HStack(spacing: XSpacing.xs) {
                        Text(xLoc("颜色")).font(XFont.caption).foregroundStyle(XColor.textSecondary)
                        Picker("", selection: mbColorBinding(item.id)) {
                            Text(xLoc("跟随全局")).tag("global")
                            Text(xLoc("单色")).tag("mono")
                            Text(xLoc("彩色")).tag("colored")
                        }
                        .labelsHidden().pickerStyle(.menu).fixedSize()
                        .accessibilityLabel(xLoc("颜色"))
                    }
                    HStack(spacing: XSpacing.xs) {
                        Text(xLoc("刷新")).font(XFont.caption).foregroundStyle(XColor.textSecondary)
                        Picker("", selection: mbIntervalBinding(item.id)) {
                            Text(xLoc("跟随全局")).tag(0.0)
                            Text("1s").tag(1.0)
                            Text("2s").tag(2.0)
                            Text("3s").tag(3.0)
                            Text("5s").tag(5.0)
                        }
                        .labelsHidden().pickerStyle(.menu).fixedSize()
                        .accessibilityLabel(xLoc("刷新"))
                    }
                    Spacer()
                }
            }
        }
    }

    private func toggleRow(_ title: String, _ binding: Binding<Bool>) -> some View {
        HStack {
            Text(title).font(XFont.bodyEmphasis).foregroundStyle(XColor.textPrimary)
            Spacer()
            Toggle("", isOn: binding).toggleStyle(.switch).labelsHidden()
                .accessibilityLabel(title)
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
                Divider().padding(.vertical, XSpacing.xxs)
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
            .accessibilityLabel(xLocF("%@ 告警阈值", xLoc(rule.metric.title)))
            Toggle("", isOn: Binding(
                get: { rule.enabled },
                set: { on in
                    model.alertRules[idx].enabled = on
                    model.saveAlertRules()
                })).toggleStyle(.switch).labelsHidden()
                .accessibilityLabel(xLocF("%@ 告警开关", xLoc(rule.metric.title)))
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
                    .font(XFont.nano).fontWeight(selected ? .semibold : .regular)
                    .foregroundStyle(selected ? XColor.brand : XColor.textTertiary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, XSpacing.s)
            .background(RoundedRectangle(cornerRadius: XRadius.control, style: .continuous)
                .fill(selected ? XColor.brand.opacity(0.12) : XColor.surfaceAlt.opacity(0.5)))
            .overlay(RoundedRectangle(cornerRadius: XRadius.control, style: .continuous)
                .strokeBorder(selected ? XColor.brand : XColor.border, lineWidth: selected ? 1.5 : 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(style.title)
        .accessibilityLabel(style.title)
    }

    /// 图形加软框——与真实字形 1:1（graph/rich 才有动态图形可框；iconValue/valueOnly 无框）。
    @ViewBuilder private func chipped<V: View>(_ content: V) -> some View {
        if framed {
            content
                .padding(.horizontal, XSpacing.xxs).padding(.vertical, 1)
                .background(RoundedRectangle(cornerRadius: XRadius.micro, style: .continuous).fill((selected ? tint : XColor.textSecondary).opacity(0.09)))
                .overlay(RoundedRectangle(cornerRadius: XRadius.micro, style: .continuous).strokeBorder((selected ? tint : XColor.textSecondary).opacity(0.3), lineWidth: 1))
        } else {
            content
        }
    }

    @ViewBuilder private var preview: some View {
        switch style {
        case .iconValue:
            HStack(spacing: 2) {
                Image(systemName: icon).font(XFont.nano)
                Text("42%").font(XFont.microMono)
            }
        case .valueOnly:
            Text("42%").font(XFont.microMono)
        case .graph:
            HStack(spacing: 2) {
                chipped(MBSparkPreview())
                Text("42%").font(XFont.microMono)
            }
        case .rich:
            HStack(spacing: 2) {
                // 与真实字形一致:CPU=直方图入框,内存/GPU/磁盘=裸露饼盘
                if icon == "cpu" {
                    chipped(MBHistoPreview())
                } else {
                    MBPiePreview()
                }
                Text("42%").font(XFont.microMono)
            }
        case .ring:
            HStack(spacing: 2) {
                MBRingPreview()
                Text("42%").font(XFont.microMono)
            }
        }
    }
}

private struct MBPiePreview: View {
    var body: some View {
        ZStack {
            Circle().opacity(0.22)
            MBPieSector(fraction: 0.42)
            Circle().stroke(lineWidth: 1).opacity(0.5)
        }
        .frame(width: 12, height: 12)
    }
}

private struct MBPieSector: Shape {
    var fraction: Double
    func path(in rect: CGRect) -> Path {
        let c = CGPoint(x: rect.midX, y: rect.midY)
        var p = Path()
        p.move(to: c)
        p.addArc(center: c, radius: min(rect.width, rect.height) / 2,
                 startAngle: .degrees(-90), endAngle: .degrees(-90 + 360 * fraction), clockwise: false)
        p.closeSubpath()
        return p
    }
}

private struct MBRingPreview: View {
    var body: some View {
        ZStack {
            Circle().stroke(lineWidth: 1.8).opacity(0.38)
            Circle().trim(from: 0, to: 0.42)
                .stroke(style: StrokeStyle(lineWidth: 1.8, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: 12, height: 12)
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
