import SwiftUI

// MARK: - 卡片

public struct XCard<Content: View>: View {
    private let content: Content
    private let padding: CGFloat
    private let elevated: Bool
    public init(padding: CGFloat = XSpacing.l, elevated: Bool = true, @ViewBuilder content: () -> Content) {
        self.padding = padding
        self.elevated = elevated
        self.content = content()
    }
    public var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: XRadius.card, style: .continuous)
                    .fill(XColor.surface)
                    .overlay(
                        // 顶部极淡高光，增加立体感
                        RoundedRectangle(cornerRadius: XRadius.card, style: .continuous)
                            .fill(LinearGradient(colors: [.white.opacity(0.06), .clear],
                                                 startPoint: .top, endPoint: .center))
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: XRadius.card, style: .continuous)
                    .strokeBorder(XColor.border.opacity(0.6), lineWidth: 1)
            )
            .modifier(ConditionalCardShadow(enabled: elevated))
    }
}

private struct ConditionalCardShadow: ViewModifier {
    let enabled: Bool
    func body(content: Content) -> some View {
        if enabled { content.xCardShadow() } else { content }
    }
}

// MARK: - 指标卡（迷你环 + 数值，仪表盘用）

public struct XMetricCard: View {
    let value: String
    let label: String
    let fraction: Double
    let colors: [Color]
    @State private var hover = false
    public init(value: String, label: String, fraction: Double, colors: [Color]) {
        self.value = value
        self.label = label
        self.fraction = fraction
        self.colors = colors.isEmpty ? XColor.brandGradientColors : colors
    }
    public var body: some View {
        XCard(padding: XSpacing.l) {
            HStack(spacing: XSpacing.m) {
                XMiniRing(fraction: fraction, colors: colors, size: 46, lineWidth: 5.5)
                VStack(alignment: .leading, spacing: 2) {
                    Text(value).font(XFont.monoLarge).foregroundStyle(XColor.textPrimary).lineLimit(1)
                    Text(label).font(XFont.caption).foregroundStyle(XColor.textSecondary).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
        }
        .shadow(color: hover ? colors[0].opacity(0.28) : .clear, radius: 18, y: 8)
        .scaleEffect(hover ? 1.02 : 1)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: hover)
        .onHover { hover = $0 }
    }
}

// MARK: - 徽标

public struct XBadge: View {
    let text: String
    let color: Color
    public init(_ text: String, color: Color) {
        self.text = text
        self.color = color
    }
    public var body: some View {
        Text(text)
            .font(XFont.captionEmphasis)
            .foregroundStyle(color)
            .padding(.horizontal, XSpacing.s)
            .padding(.vertical, 3)
            .background(color.opacity(0.15), in: Capsule())
    }
}

// MARK: - 按钮样式

public struct XPrimaryButtonStyle: ButtonStyle {
    var enabled: Bool
    var large: Bool
    public init(enabled: Bool = true, large: Bool = false) {
        self.enabled = enabled
        self.large = large
    }
    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(large ? XFont.title : XFont.headline)
            .foregroundStyle(.white)
            .padding(.horizontal, large ? XSpacing.xxl : XSpacing.xl)
            .padding(.vertical, large ? XSpacing.l : XSpacing.m)
            .background(
                enabled ? AnyShapeStyle(XColor.brandGradient) : AnyShapeStyle(XColor.surfaceAlt),
                in: Capsule()
            )
            .overlay(
                // 顶部玻璃高光，增加光泽质感
                Capsule()
                    .fill(LinearGradient(colors: [.white.opacity(enabled ? 0.28 : 0), .clear],
                                         startPoint: .top, endPoint: .center))
                    .blendMode(.plusLighter)
                    .allowsHitTesting(false)
            )
            .overlay(Capsule().strokeBorder(.white.opacity(enabled ? 0.22 : 0), lineWidth: 1))
            .opacity(configuration.isPressed ? 0.85 : 1)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .shadow(color: enabled ? XColor.brand.opacity(0.35) : .clear,
                    radius: configuration.isPressed ? 6 : 14, y: 6)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

public struct XSecondaryButtonStyle: ButtonStyle {
    public init() {}
    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(XFont.headline)
            .foregroundStyle(XColor.textPrimary)
            .padding(.horizontal, XSpacing.xl)
            .padding(.vertical, XSpacing.m)
            .background(XColor.surfaceAlt, in: Capsule())
            .overlay(Capsule().strokeBorder(XColor.border, lineWidth: 1))
            .opacity(configuration.isPressed ? 0.8 : 1)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

// MARK: - 磁盘空间条

public struct XDiskBar: View {
    let usedFraction: Double
    let label: String
    var height: CGFloat
    public init(usedFraction: Double, label: String, height: CGFloat = 10) {
        self.usedFraction = usedFraction
        self.label = label
        self.height = height
    }
    public var body: some View {
        VStack(alignment: .leading, spacing: XSpacing.s) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(XColor.surfaceAlt)
                    Capsule()
                        .fill(LinearGradient(colors: XColor.gauge(usedFraction),
                                             startPoint: .leading, endPoint: .trailing))
                        .frame(width: max(height, geo.size.width * min(max(usedFraction, 0), 1)))
                        .animation(.spring(response: 0.6, dampingFraction: 0.85), value: usedFraction)
                }
            }
            .frame(height: height)
            if !label.isEmpty {
                Text(label).font(XFont.caption).foregroundStyle(XColor.textSecondary)
            }
        }
    }
}

// MARK: - 底部操作条

public struct XActionBar<Trailing: View>: View {
    let title: String
    let subtitle: String
    let trailing: Trailing
    public init(title: String, subtitle: String, @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.subtitle = subtitle
        self.trailing = trailing()
    }
    public var body: some View {
        HStack(spacing: XSpacing.l) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(XFont.headline).foregroundStyle(XColor.textPrimary)
                Text(subtitle).font(XFont.caption).foregroundStyle(XColor.textSecondary)
            }
            Spacer()
            trailing
        }
        .padding(.horizontal, XSpacing.xl)
        .padding(.vertical, XSpacing.l)
        .background(.ultraThinMaterial)
        .overlay(Rectangle().fill(XColor.hairline).frame(height: 1), alignment: .top)
    }
}

// MARK: - 空态

public struct XEmptyState: View {
    let systemImage: String
    let title: String
    let subtitle: String
    public init(systemImage: String, title: String, subtitle: String) {
        self.systemImage = systemImage
        self.title = title
        self.subtitle = subtitle
    }
    public var body: some View {
        VStack(spacing: XSpacing.m) {
            ZStack {
                Circle().fill(XColor.brand.opacity(0.12)).frame(width: 96, height: 96)
                Image(systemName: systemImage)
                    .font(.system(size: 42, weight: .light))
                    .foregroundStyle(XColor.brandGradient)
            }
            Text(title).xTitle().foregroundStyle(XColor.textPrimary)
            Text(subtitle)
                .font(XFont.body).foregroundStyle(XColor.textSecondary)
                .multilineTextAlignment(.center).frame(maxWidth: 420).lineSpacing(2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(XSpacing.xxl)
    }
}
