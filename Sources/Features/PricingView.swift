import SwiftUI
import AppKit
import Domain
import Infrastructure
import DesignSystem

/// 一个定价方案。
struct PricingPlan: Identifiable {
    let id: String
    let name: String
    let price: String
    /// 划线原价（有折扣时），与官网购买页同步展示。
    let compareAt: String?
    /// 折扣百分比（如 71 = -71%）。
    let discount: Int?
    let period: String
    let devices: String
    let features: [String]
    let highlighted: Bool
}

/// 会员 / 升级页（以 sheet 呈现）。展示试用状态、买断分层、功能对照。
/// 价格与官网实时同步（ProPricingClient：官网定价 API → geo 币种+价目表 → 缓存回退），
/// 「立即购买」打开官网购买页（Info.plist 的 XicoPurchaseURL，附 plan 参数），
/// 购买后用 18 位激活码解锁。买断制 + 本地隐私是与 CleanMyMac 订阅制的差异化卖点。
public struct PricingView: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var importError: String?
    @State private var importedOK = false
    @State private var activationKey = ""
    /// 当前选中的买断方案（可点卡选择，驱动底部「立即购买」）。默认个人版。
    @State private var selectedPlanID = "personal"
    /// 与官网同步的实时价格：先渲染缓存/兜底值，onAppear 拉取后无感刷新。
    @State private var pricing: ProPricing = ProPricingClient.cachedOrDefault()
    /// 席位已满：激活返回 seat_limit 时置真，展开「在旧设备释放授权」的自助恢复引导（审计 CONTRACT (d)）。
    @State private var seatLimitHit = false
    /// 正在停用本机席位。
    @State private var deactivating = false
    /// 停用成功后的提示文案。
    @State private var deactivateNote: String?
    /// 应用内浏览器目标（购买 / 隐私政策）——签名时刻 S3：零离开购买（docs/14 P2）。
    @State private var browserTarget: BrowserTarget?

    public init(model: AppModel) { self.model = model }

    private var plans: [PricingPlan] {
        [
            PricingPlan(id: "personal", name: xLoc("个人版"),
                        price: pricing.label(pricing.personal),
                        compareAt: pricing.compareAtLabel(pricing.personal),
                        discount: pricing.discountPercent(pricing.personal),
                        period: xLoc("一次买断"),
                        devices: xLoc("1 台 Mac"),
                        features: [xLoc("全部清理与优化功能"), xLoc("iStat 级实时监控"),
                                   xLoc("Sensei 级硬件健康"), xLoc("清理历史与一键撤销"),
                                   xLoc("规则库与安全更新"), xLoc("大版本内免费升级")],
                        highlighted: false),
            PricingPlan(id: "family", name: xLoc("家庭版"),
                        price: pricing.label(pricing.family),
                        compareAt: pricing.compareAtLabel(pricing.family),
                        discount: pricing.discountPercent(pricing.family),
                        period: xLoc("一次买断"),
                        devices: xLoc("最多 5 台 Mac"),
                        features: [xLoc("个人版全部功能"), xLoc("家庭 5 台共享授权"),
                                   xLoc("优先邮件支持"), xLoc("抢先体验新功能")],
                        highlighted: true)
        ]
    }

    public var body: some View {
        ZStack {
            AppBackground()
            VStack(spacing: 0) {
                header
                ScrollView {
                    VStack(spacing: XSpacing.l) {
                        if isCurrentlyLicensed {
                            // 已激活：只显示「已激活的样子」——授权状态 + 本机设备 + 换机释放，
                            // 不再出现方案卡与「立即购买」付款入口（用户反馈）。
                            activatedView
                        } else {
                            trialPill
                            HStack(alignment: .top, spacing: XSpacing.l) {
                                ForEach(plans) { plan in planCard(plan) }
                            }
                            purchaseCTA
                            trialEscape
                            importRow
                        }
                        trustLine
                    }
                    .padding(XSpacing.xl)
                    .frame(maxWidth: 720)
                }
            }
        }
        .frame(width: 760, height: 720)
        .task {
            // 与官网同步实时价格（同一套按 IP 定币种的口径）；失败静默保持缓存/兜底值。
            pricing = await ProPricingClient.fetch()
        }
        // 应用内浏览器：购买/隐私政策不再跳系统浏览器；支付成功页回跳 xico://activate?key=
        // 被浏览器拦截 → 自动回填激活（S3 闭环）。
        .sheet(item: $browserTarget) { target in
            InAppBrowserView(target: target) { key in
                activationKey = key
                activateKey()
            }
        }
    }

    private var header: some View {
        HStack(spacing: XSpacing.m) {
            XIconTile(systemImage: "sparkles", colors: XColor.brandGradientColors, size: 42, flat: false)
            VStack(alignment: .leading, spacing: 2) {
                Text("Xico Pro").xTitle().foregroundStyle(XColor.textPrimary)
                Text(xLoc("一次买断，永久使用 · 数据全程本地")).font(XFont.callout).foregroundStyle(XColor.textSecondary)
            }
            Spacer()
            Button { dismiss() } label: {
                Image(systemName: "xmark").font(.system(size: 12, weight: .bold)).foregroundStyle(XColor.textTertiary)
                    .frame(width: 28, height: 28).background(XColor.surfaceAlt, in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(xLoc("关闭"))
        }
        .padding(.horizontal, XSpacing.xl).padding(.top, XSpacing.l).padding(.bottom, XSpacing.m)
    }

    private var trialPill: some View {
        Group {
            if let st = model.licenseStatus {
                HStack(spacing: XSpacing.s) {
                    Image(systemName: st.state.allowsCommercialUse ? "clock.badge.checkmark" : "clock.badge.exclamationmark")
                        .foregroundStyle(st.state.allowsCommercialUse ? XColor.success : XColor.warning)
                    Text(statusText(st)).font(XFont.bodyEmphasis).foregroundStyle(XColor.textPrimary)
                    Spacer()
                }
                .padding(XSpacing.m)
                .background(XColor.surface, in: RoundedRectangle(cornerRadius: XRadius.tile, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: XRadius.tile, style: .continuous).strokeBorder(XColor.border, lineWidth: 1))
            }
        }
    }

    private func statusText(_ st: LicenseStatus) -> String {
        switch st.state {
        case let .licensed(name, _): return xLocF("已激活 · %@", name)
        case let .trial(days): return xLocF("试用中 · 剩余 %d 天", days)
        case .expired: return xLoc("试用已结束 · 升级后继续使用清理与优化")
        case .invalid: return xLoc("许可证无效 · 请重新激活")
        }
    }

    /// 可选择的方案卡：整卡可点，选中态描品牌边 + 左上单选圆点填充。
    /// 购买行动收敛到卡片下方的单个「立即购买」CTA（作用于选中方案），比每卡各自一个按钮更清晰。
    private func planCard(_ plan: PricingPlan) -> some View {
        let selected = selectedPlanID == plan.id
        return Button {
            withAnimation(XMotion.snappy) { selectedPlanID = plan.id }
        } label: {
            VStack(alignment: .leading, spacing: XSpacing.m) {
                HStack(spacing: XSpacing.s) {
                    // 单选指示：选中填充品牌色，未选空心。
                    Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                        .font(XFont.body).foregroundStyle(selected ? XColor.brand : XColor.textTertiary)
                        .accessibilityHidden(true)
                    Text(plan.name).xHeadline().foregroundStyle(XColor.textPrimary)
                    Spacer()
                    if plan.highlighted { XBadge(xLoc("推荐"), color: XColor.brand) }
                }
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(plan.price).font(XFont.monoHero).foregroundStyle(XColor.textPrimary)
                        .contentTransition(.numericText())
                    // 划线原价 + 折扣徽章：与官网购买页同步展示（有折扣时才出现）。
                    if let compareAt = plan.compareAt {
                        Text(compareAt).font(XFont.callout).foregroundStyle(XColor.textTertiary)
                            .strikethrough(true, color: XColor.textTertiary)
                    }
                    Text(plan.period).font(XFont.caption).foregroundStyle(XColor.textSecondary)
                }
                HStack(spacing: XSpacing.s) {
                    XBadge(plan.devices, color: XColor.accentTeal)
                    if let discount = plan.discount {
                        XBadge("-\(discount)%", color: XColor.accentPink)
                    }
                }
                Divider().overlay(XColor.hairline)
                VStack(alignment: .leading, spacing: XSpacing.s) {
                    ForEach(plan.features, id: \.self) { f in
                        HStack(alignment: .top, spacing: XSpacing.s) {
                            Image(systemName: "checkmark.circle.fill").font(XFont.body).foregroundStyle(XColor.success)
                            Text(f).font(XFont.caption).foregroundStyle(XColor.textSecondary)
                            Spacer(minLength: 0)
                        }
                    }
                }
            }
            .padding(XSpacing.l)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: XRadius.card, style: .continuous)
                    .fill(selected ? XColor.brand.opacity(0.06) : XColor.surface)
                    .overlay(RoundedRectangle(cornerRadius: XRadius.card, style: .continuous)
                        .strokeBorder(
                            selected ? AnyShapeStyle(XColor.brand)
                                     : (plan.highlighted ? AnyShapeStyle(XColor.brandGradient)
                                                         : AnyShapeStyle(XColor.border)),
                            lineWidth: (selected || plan.highlighted) ? 2 : 1))
            )
            // 推荐档卖相（docs/16 P2）：渐变描边发光 + 顶部 ribbon + 1.02 微缩放——
            // 与 Setapp/Bear 的推荐档同段位，此前只多一枚小徽章拉不开。
            .overlay(alignment: .top) {
                if plan.highlighted {
                    Text(xLoc("最超值"))
                        .font(XFont.captionEmphasis).foregroundStyle(XColor.onAccent)
                        .padding(.horizontal, XSpacing.m).padding(.vertical, 3)
                        .background(XColor.brandGradient, in: Capsule())
                        .xGrain(0.3)
                        .offset(y: -11)
                }
            }
            .scaleEffect(plan.highlighted ? 1.02 : 1)
            .shadow(color: plan.highlighted ? XColor.brand.opacity(0.22) : .clear, radius: 18, y: 6)
            .xCardShadow()
            .contentShape(RoundedRectangle(cornerRadius: XRadius.card, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityLabel(xLocF("%@ · %@", plan.name, plan.price))
    }

    /// 底部主 CTA：购买当前选中的方案。名称随选择实时变化，让「选中→购买」一目了然。
    private var purchaseCTA: some View {
        let plan = plans.first { $0.id == selectedPlanID } ?? plans[0]
        return Button {
            openCheckout(plan: plan.id)
        } label: {
            Text(xLocF("立即购买 · %@", plan.name)).frame(maxWidth: .infinity)
        }
        .buttonStyle(XPrimaryButtonStyle())
        .accessibilityLabel(xLocF("立即购买 %@", plan.name))
    }

    /// 付费墙逃逸出口（docs/14 P2）：试用可用时永远给出「先试用」按钮——
    /// 首启弹出的定价页不做订阅压迫（CleanMyMac 被骂点反着做），信任本身是转化率。
    @ViewBuilder private var trialEscape: some View {
        if case let .trial(days) = model.licenseStatus?.state, days > 0 {
            Button {
                dismiss()
            } label: {
                Text(days >= LicenseService.defaultTrialDays
                     ? xLoc("先试用 15 天 · 全功能免费体验")
                     : xLocF("继续试用 · 剩余 %d 天", days))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(XSecondaryButtonStyle())
            .accessibilityLabel(xLoc("先试用，稍后购买"))
        }
    }

    /// 已激活视图：授权状态 + 本机设备 + 换机释放。取代付款方案卡，让「已激活」一眼可辨。
    private var activatedView: some View {
        VStack(spacing: XSpacing.l) {
            VStack(alignment: .leading, spacing: XSpacing.m) {
                HStack(spacing: XSpacing.m) {
                    XIconTile(systemImage: "checkmark.seal.fill", colors: [XColor.success, XColor.accentTeal], size: 44, flat: false)
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: XSpacing.s) {
                            Text(xLoc("已激活")).xHeadline().foregroundStyle(XColor.textPrimary)
                            XBadge("Pro", color: XColor.brand)
                        }
                        if let st = model.licenseStatus {
                            Text(st.summary).font(XFont.caption).foregroundStyle(XColor.textSecondary)
                        }
                    }
                    Spacer()
                }
                Divider().overlay(XColor.hairline)
                HStack(spacing: XSpacing.m) {
                    Image(systemName: "laptopcomputer").font(XFont.body).foregroundStyle(XColor.brand).frame(width: 22)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(xLoc("本机设备")).font(XFont.caption).foregroundStyle(XColor.textSecondary)
                        Text(AppModel.neutralDeviceLabel()).font(XFont.body).foregroundStyle(XColor.textPrimary)
                    }
                    Spacer()
                    XBadge(xLoc("已授权"), color: XColor.success)
                }
                Text(xLoc("已激活的设备可在官网后台查询与管理。"))
                    .font(XFont.nano).foregroundStyle(XColor.textTertiary)
            }
            .padding(XSpacing.l)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: XRadius.card, style: .continuous)
                    .fill(XColor.surface)
                    .overlay(RoundedRectangle(cornerRadius: XRadius.card, style: .continuous)
                        .strokeBorder(XColor.success.opacity(0.4), lineWidth: 1))
            )
            .xCardShadow()

            VStack(spacing: XSpacing.s) {
                Button(deactivating ? xLoc("释放中…") : xLoc("换机？释放本机授权")) { deactivateThisDevice() }
                    .buttonStyle(XSecondaryButtonStyle(compact: true))
                    .disabled(deactivating)
                Text(xLoc("释放后本机立即退出 Pro 并回到试用/受限，服务器席位随之腾出供新设备激活；请仅在本机不再使用本应用时释放。"))
                    .font(XFont.nano).foregroundStyle(XColor.textTertiary).multilineTextAlignment(.center)
                if let note = deactivateNote {
                    Text(note).font(XFont.caption).foregroundStyle(XColor.success).multilineTextAlignment(.center)
                }
                if let e = importError {
                    Text(e).font(XFont.caption).foregroundStyle(XColor.danger).multilineTextAlignment(.center)
                }
            }
            privacyDisclosure
        }
    }

    private var importRow: some View {
        VStack(spacing: XSpacing.s) {
            Text(xLoc("已购买？输入激活码解锁")).font(XFont.caption).foregroundStyle(XColor.textSecondary)
            HStack(spacing: XSpacing.s) {
                XCapsuleTextField(placeholder: xLoc("18 位激活码"), text: $activationKey) { activateKey() }
                    .frame(maxWidth: 260)
                    .disabled(model.activating)
                Button(model.activating ? xLoc("激活中…") : xLoc("激活")) { activateKey() }
                    .buttonStyle(XPrimaryButtonStyle(compact: true))
                    .disabled(model.activating || activationKey.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if importedOK {
                Text(xLoc("激活成功，感谢支持！")).font(XFont.caption).foregroundStyle(XColor.success)
            }
            if let e = importError {
                Text(e).font(XFont.caption).foregroundStyle(XColor.danger).multilineTextAlignment(.center)
            }
            if seatLimitHit {
                Text(xLoc("授权台数已满。换了新机器？请在旧设备上点『释放本机授权』腾出名额后重试，或联系我们协助。"))
                    .font(XFont.caption).foregroundStyle(XColor.warning).multilineTextAlignment(.center)
            }
            privacyDisclosure
        }
    }

    private var isCurrentlyLicensed: Bool {
        if case .licensed = model.licenseStatus?.state { return true }
        return false
    }

    /// 设备标识采集的如实披露（审计 DeviceIdentity P3）：激活/复验会上送本机设备标识以绑定授权台数。
    private var privacyDisclosure: some View {
        VStack(spacing: XSpacing.xxs) {
            Text(xLoc("激活与复验会上送本机设备标识以绑定授权台数，不含姓名/邮箱。"))
                .font(XFont.nano).foregroundStyle(XColor.textTertiary).multilineTextAlignment(.center)
            Button(xLoc("隐私政策")) {
                browserTarget = BrowserTarget(url: Self.privacyURL(), title: xLoc("隐私政策"))
            }
            .buttonStyle(.link).font(XFont.nano)
        }
        .padding(.top, XSpacing.xs)
    }

    private static func privacyURL() -> URL {
        if let s = Bundle.main.object(forInfoDictionaryKey: "XicoPrivacyURL") as? String,
           let u = URL(string: s) { return u }
        return URL(string: "https://mac.xicoai.com/privacy")!
    }

    private func activateKey() {
        let key = activationKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, !model.activating else { return }
        importError = nil
        seatLimitHit = false
        Task {
            let result = await model.activateLicense(key: key)
            switch result {
            case .success:
                withAnimation { importedOK = true }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { dismiss() }
            case let .failure(err):
                importError = err.localizedDescription
                // 席位已满：展开自助恢复引导（换机用户可在旧机释放授权名额后重试）。
                if case LicenseActivationError.seatLimit = err { withAnimation { seatLimitHit = true } }
            }
        }
    }

    /// 停用本机席位：换机/换主板前在旧机主动释放一个授权名额，避免迁移后撞上「授权台数已达上限」。
    /// 成功即清除本地许可并刷新状态。审计 CONTRACT (d)。
    private func deactivateThisDevice() {
        guard let licenseID = model.licenseStatus?.licenseID, !deactivating else { return }
        deactivating = true
        importError = nil
        deactivateNote = nil
        Task {
            defer { deactivating = false }
            do {
                try await LicenseActivationClient().deactivate(
                    licenseId: licenseID,
                    deviceId: DeviceIdentity.current(),
                )
                // 落「本机已释放此席位」标记（审计 P2）：仅删许可文件不足以真正释放——
                // 用户可保存旧信封在停用后手动重导入把席位吹回来。此标记令后续手动重导入被拒，
                // 直到一次成功的在线激活（服务端重新盖章席位）清除它。
                model.env.license.recordReleased(licenseID: licenseID, deviceId: DeviceIdentity.current())
                model.env.license.clearLicense()
                model.refreshLicense()
                withAnimation { deactivateNote = xLoc("已释放本机授权，可在新设备重新激活。") }
            } catch {
                importError = error.localizedDescription
            }
        }
    }

    private var trustLine: some View {
        HStack(spacing: XSpacing.l) {
            trustItem("lock.shield", xLoc("数据本地"))
            trustItem("infinity", xLoc("永久买断"))
            trustItem("arrow.uturn.backward", xLoc("30 天退款"))
        }
        .padding(.top, XSpacing.s)
    }
    private func trustItem(_ icon: String, _ text: String) -> some View {
        HStack(spacing: XSpacing.xs) {
            Image(systemName: icon).font(XFont.caption).foregroundStyle(XColor.textTertiary)
            Text(text).font(XFont.caption).foregroundStyle(XColor.textTertiary)
        }
    }

    /// 打开购买页——应用内浏览器呈现（docs/14 P2 S3），不再 NSWorkspace 跳系统浏览器。
    /// 附 embedded=1 供官网隐藏页头页脚（渐进增强：官网未适配时也只是多个无害参数）。
    private func openCheckout(plan: String) {
        var url = LicenseService.purchaseURL()
        if var comps = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            var items = comps.queryItems ?? []
            items.append(URLQueryItem(name: "plan", value: plan))
            items.append(URLQueryItem(name: "embedded", value: "1"))
            comps.queryItems = items
            if let u = comps.url { url = u }
        }
        browserTarget = BrowserTarget(url: url, title: xLoc("购买 Xico Pro"))
    }

}
