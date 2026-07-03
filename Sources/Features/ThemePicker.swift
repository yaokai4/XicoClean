import SwiftUI
import DesignSystem

/// 主题选择器：横向卡片轮播，每张卡是主题的真实迷你预览（仪表 + 图表 + 渐变按钮）。
/// 选中即时应用到全局配色。
struct ThemePickerCard: View {
    @Binding var selectedID: String

    var body: some View {
        XCard {
            VStack(alignment: .leading, spacing: XSpacing.m) {
                HStack(spacing: XSpacing.m) {
                    XIconTile(systemImage: "paintpalette.fill", colors: XColor.brandGradientColors, size: 36)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(xLoc("主题")).xHeadline().foregroundStyle(XColor.textPrimary)
                        Text(xLoc("换一套配色，全局即时生效")).font(XFont.caption).foregroundStyle(XColor.textSecondary)
                    }
                    Spacer()
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: XSpacing.m) {
                        ForEach(XTheme.all) { theme in
                            let isSel = theme.id == selectedID
                            ThemeSwatch(theme: theme, selected: isSel)
                                // 选中项前推放大并高亮，未选中项略缩淡出——稳定的深度层次
                                .scaleEffect(isSel ? 1.06 : 0.95)
                                .opacity(isSel ? 1 : 0.8)
                                .zIndex(isSel ? 1 : 0)
                                .onTapGesture {
                                    withAnimation(.spring(response: 0.4, dampingFraction: 0.75)) {
                                        selectedID = theme.id
                                    }
                                }
                        }
                    }
                    .padding(.vertical, 10)
                    .padding(.horizontal, XSpacing.s)
                }
            }
        }
    }
}

/// 单个主题预览卡片：迷你环形仪表 + 迷你折线 + 主题名。
private struct ThemeSwatch: View {
    let theme: XTheme
    let selected: Bool
    @State private var hover = false

    var body: some View {
        VStack(spacing: XSpacing.s) {
            ZStack {
                RoundedRectangle(cornerRadius: XRadius.tile, style: .continuous)
                    .fill(XColor.surfaceAlt)
                VStack(spacing: 8) {
                    // 迷你环形（用主题 ring 色）
                    ZStack {
                        Circle().stroke(XColor.surface, lineWidth: 6).frame(width: 46, height: 46)
                        Circle().trim(from: 0, to: 0.68)
                            .stroke(AngularGradient(colors: theme.ring + [theme.ring[0]], center: .center),
                                    style: StrokeStyle(lineWidth: 6, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                            .frame(width: 46, height: 46)
                    }
                    // 迷你渐变条（主题 gradient）
                    Capsule()
                        .fill(LinearGradient(colors: theme.gradient, startPoint: .leading, endPoint: .trailing))
                        .frame(width: 64, height: 8)
                }
            }
            .frame(width: 108, height: 96)
            .overlay(
                RoundedRectangle(cornerRadius: XRadius.tile, style: .continuous)
                    .strokeBorder(selected ? theme.accent : XColor.border,
                                  lineWidth: selected ? 2.5 : 1)
            )
            .overlay(alignment: .topTrailing) {
                if selected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(theme.accent)
                        .background(Circle().fill(XColor.surface).frame(width: 14, height: 14))
                        .padding(6)
                }
            }
            .scaleEffect(hover ? 1.04 : 1)
            .shadow(color: hover ? theme.accent.opacity(0.3) : .clear, radius: 12, y: 4)
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: hover)
            .onHover { hover = $0 }

            Text(xLoc(theme.name))
                .font(selected ? XFont.captionEmphasis : XFont.caption)
                .foregroundStyle(selected ? XColor.textPrimary : XColor.textSecondary)
        }
    }
}
