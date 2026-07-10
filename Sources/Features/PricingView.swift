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
    /// 与官网同步的实时价格：先渲染缓存/兜底值，onAppear 拉取后无感刷新。
    @State private var pricing: ProPricing = ProPricingClient.cachedOrDefault()
    /// 席位已满：激活返回 seat_limit 时置真，展开「在旧设备释放授权」的自助恢复引导（审计 CONTRACT (d)）。
    @State private var seatLimitHit = false
    /// 正在停用本机席位。
    @State private var deactivating = false
    /// 停用成功后的提示文案。
    @State private var deactivateNote: String?

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
                        trialPill
                        HStack(alignment: .top, spacing: XSpacing.l) {
                            ForEach(plans) { plan in planCard(plan) }
                        }
                        importRow
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
    }

    private var header: some View {
        HStack(spacing: XSpacing.m) {
            XIconTile(systemImage: "sparkles", colors: XColor.brandGradientColors, size: 42)
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

    private func planCard(_ plan: PricingPlan) -> some View {
        VStack(alignment: .leading, spacing: XSpacing.m) {
            HStack {
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
            Spacer(minLength: XSpacing.s)
            Button {
                openCheckout(plan: plan.id)
            } label: {
                Text(xLoc("立即购买")).frame(maxWidth: .infinity)
            }
            .buttonStyle(XPrimaryButtonStyle())
        }
        .padding(XSpacing.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: XRadius.card, style: .continuous)
                .fill(XColor.surface)
                .overlay(RoundedRectangle(cornerRadius: XRadius.card, style: .continuous)
                    .strokeBorder(plan.highlighted ? XColor.brand.opacity(0.6) : XColor.border,
                                  lineWidth: plan.highlighted ? 2 : 1))
        )
        .xCardShadow()
    }

    private var importRow: some View {
        VStack(spacing: XSpacing.s) {
            Text(xLoc("已购买？输入激活码解锁")).font(XFont.caption).foregroundStyle(XColor.textSecondary)
            HStack(spacing: XSpacing.s) {
                TextField(xLoc("18 位激活码"), text: $activationKey)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 260)
                    .disabled(model.activating)
                    .onSubmit { activateKey() }
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
            if isCurrentlyLicensed {
                Button(deactivating ? xLoc("释放中…") : xLoc("换机？释放本机授权")) { deactivateThisDevice() }
                    .buttonStyle(.link).font(XFont.caption)
                    .disabled(deactivating)
                // 如实说明「释放」的后果与边界（审计 PricingView P2）：释放只腾出服务器席位并清除本机许可，
                // 不能撤销已下载到本机的签名许可副本本身；下次联网复验时服务器据设备席位状态给出（已签名的）结论。
                Text(xLoc("释放后本机立即退出 Pro 并回到试用/受限，服务器席位随之腾出供新设备激活；请仅在本机不再使用本应用时释放。"))
                    .font(XFont.nano).foregroundStyle(XColor.textTertiary).multilineTextAlignment(.center)
            }
            if let note = deactivateNote {
                Text(note).font(XFont.caption).foregroundStyle(XColor.success).multilineTextAlignment(.center)
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
            Button(xLoc("隐私政策")) { NSWorkspace.shared.open(Self.privacyURL()) }
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

    private func openCheckout(plan: String) {
        var url = LicenseService.purchaseURL()
        if var comps = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            var items = comps.queryItems ?? []
            items.append(URLQueryItem(name: "plan", value: plan))
            comps.queryItems = items
            if let u = comps.url { url = u }
        }
        NSWorkspace.shared.open(url)
    }

}
