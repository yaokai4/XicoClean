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
    let period: String
    let devices: String
    let features: [String]
    let highlighted: Bool
}

/// 会员 / 升级页（以 sheet 呈现）。展示试用状态、买断分层、功能对照，
/// 「立即购买」打开可配置的结账地址（Info.plist 的 XicoPurchaseURL，附 plan 参数），
/// 「导入许可证」用于购买后激活。买断制 + 本地隐私是与 CleanMyMac 订阅制的差异化卖点。
public struct PricingView: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var importError: String?
    @State private var importedOK = false
    @State private var activationKey = ""

    public init(model: AppModel) { self.model = model }

    private var plans: [PricingPlan] {
        [
            PricingPlan(id: "personal", name: xLoc("个人版"), price: "¥ 128", period: xLoc("一次买断"),
                        devices: xLoc("1 台 Mac"),
                        features: [xLoc("全部清理与优化功能"), xLoc("iStat 级实时监控"),
                                   xLoc("Sensei 级硬件健康"), xLoc("清理历史与一键撤销"),
                                   xLoc("规则库与安全更新"), xLoc("大版本内免费升级")],
                        highlighted: false),
            PricingPlan(id: "family", name: xLoc("家庭版"), price: "¥ 218", period: xLoc("一次买断"),
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
        case .invalid: return xLoc("许可证无效 · 请重新导入")
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
                Text(plan.price).font(.system(size: 30, weight: .bold, design: .rounded)).foregroundStyle(XColor.textPrimary)
                Text(plan.period).font(XFont.caption).foregroundStyle(XColor.textSecondary)
            }
            XBadge(plan.devices, color: XColor.accentTeal)
            Divider().overlay(XColor.hairline)
            VStack(alignment: .leading, spacing: XSpacing.s) {
                ForEach(plan.features, id: \.self) { f in
                    HStack(alignment: .top, spacing: XSpacing.s) {
                        Image(systemName: "checkmark.circle.fill").font(.system(size: 13)).foregroundStyle(XColor.success)
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
            Button(xLoc("或导入许可证文件")) { importLicense() }
                .buttonStyle(.link).font(XFont.caption)
            if importedOK {
                Text(xLoc("激活成功，感谢支持！")).font(XFont.caption).foregroundStyle(XColor.success)
            }
            if let e = importError {
                Text(e).font(XFont.caption).foregroundStyle(XColor.danger).multilineTextAlignment(.center)
            }
        }
    }

    private func activateKey() {
        let key = activationKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, !model.activating else { return }
        importError = nil
        Task {
            let result = await model.activateLicense(key: key)
            switch result {
            case .success:
                withAnimation { importedOK = true }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { dismiss() }
            case let .failure(err):
                importError = err.localizedDescription
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
            Image(systemName: icon).font(.system(size: 11)).foregroundStyle(XColor.textTertiary)
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

    private func importLicense() {
        importError = nil
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = []
        panel.prompt = xLoc("导入")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try Data(contentsOf: url)
            _ = try model.env.license.installLicense(fromEnvelopeData: data)
            model.refreshLicense()
            withAnimation { importedOK = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { dismiss() }
        } catch {
            importError = error.localizedDescription
        }
    }
}
