import SwiftUI
import DesignSystem

public struct OnboardingView: View {
    @ObservedObject var model: AppModel
    @State private var appeared = false

    public init(model: AppModel) { self.model = model }

    public var body: some View {
        ZStack {
            AppBackground()
            // 包一层 ScrollView：大号 Dynamic Type / 窄矮窗口下内容可能超出可视高度，
            // 若不可滚动会把唯一出口「开始使用」按钮裁到屏外（审计 P2）。用 GeometryReader 撑起
            // 至少一屏高度并居中；内容超高时自然可滚动，CTA 永远可达。
            GeometryReader { geo in
                ScrollView {
                    onboardingContent
                        .padding(XSpacing.xxxl)
                        .frame(maxWidth: .infinity, minHeight: geo.size.height)
                        .opacity(appeared ? 1 : 0)
                        .offset(y: appeared ? 0 : 24)
                }
            }
        }
        .onAppear { withAnimation(.spring(response: 0.6, dampingFraction: 0.8)) { appeared = true } }
    }

    private var onboardingContent: some View {
        VStack(spacing: XSpacing.xl) {
                XBrandMark(size: 76)
                    .xGlow(XColor.brand, radius: 36)
                    .scaleEffect(appeared ? 1 : 0.6)

                VStack(spacing: XSpacing.s) {
                    Text(xLoc("欢迎使用 Xico")).xLargeTitle().foregroundStyle(XColor.textPrimary)
                    Text(xLoc("让你的 Mac 重新变快、变干净、腾出空间"))
                        .font(XFont.body).foregroundStyle(XColor.textSecondary)
                }

                VStack(spacing: XSpacing.m) {
                    feature("sparkles", [XColor.ringPeri, XColor.ringLav], xLoc("智能清理"), xLoc("一键扫描系统垃圾、缓存与应用残留"))
                    feature("circle.hexagongrid.fill", [XColor.ringLav, XColor.ringRose], xLoc("空间透镜"), xLoc("可视化磁盘占用，快速定位大文件"))
                    feature("checkmark.shield.fill", [XColor.ringPeri, XColor.ringMint], xLoc("绝对安全"), xLoc("全部移入废纸篓，随时一键撤销"))
                }
                .frame(maxWidth: 460)

                XCard {
                    HStack(spacing: XSpacing.m) {
                        XIconTile(systemImage: "externaldrive.fill.badge.checkmark",
                                  colors: [XColor.brand, XColor.brandEnd], size: 36)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(xLoc("开启完全磁盘访问权限")).font(XFont.bodyEmphasis).foregroundStyle(XColor.textPrimary)
                            Text(xLoc("扫描全部垃圾需要此权限，一次授权长期有效。"))
                                .font(XFont.caption).foregroundStyle(XColor.textSecondary)
                        }
                        Spacer()
                        Button(xLoc("去开启")) { model.openFullDiskAccessSettings() }.buttonStyle(XSecondaryButtonStyle(compact: true))
                    }
                }
                .frame(maxWidth: 460)

                Button(xLoc("开始使用")) { model.completeOnboarding() }
                    .buttonStyle(XPrimaryButtonStyle(large: true))
                    .padding(.top, XSpacing.s)
        }
    }

    private func feature(_ icon: String, _ colors: [Color], _ title: String, _ sub: String) -> some View {
        HStack(spacing: XSpacing.m) {
            XIconTile(systemImage: icon, colors: colors, size: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).xHeadline().foregroundStyle(XColor.textPrimary)
                Text(sub).font(XFont.caption).foregroundStyle(XColor.textSecondary)
            }
            Spacer()
        }
    }
}
