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
        // 走统一层次阶梯（raised ≈ 原 xCardShadow，视感一致但纳入 z 轴体系）。
        if enabled { content.xElevation(.raised) } else { content }
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
        .xGlow(colors[0], radius: 18, opacity: hover ? 0.28 : 0)
        .scaleEffect(hover ? 1.02 : 1)
        .animation(XMotion.snappy, value: hover)
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
    var compact: Bool
    public init(enabled: Bool = true, large: Bool = false, compact: Bool = false) {
        self.enabled = enabled
        self.large = large
        self.compact = compact
    }
    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(large ? XFont.title : (compact ? XFont.bodyEmphasis : XFont.headline))
            // 禁用态背景是浅色 surfaceAlt，白字会消失——改用次要文字色保证浅色模式可读。
            // 用 textSecondary（而非更淡的 textTertiary）：禁用标签仍是「载重文字」，
            // 需在 surfaceAlt 上稳过 WCAG AA（≥4.5:1）；textTertiary 贴近下限，留给纯装饰性说明。
            .foregroundStyle(enabled ? AnyShapeStyle(XColor.onAccent) : AnyShapeStyle(XColor.textSecondary))
            .padding(.horizontal, large ? XSpacing.xxl : (compact ? XSpacing.m : XSpacing.xl))
            .padding(.vertical, large ? XSpacing.l : (compact ? XSpacing.s : XSpacing.m))
            .background(
                enabled ? AnyShapeStyle(XColor.brandGradient) : AnyShapeStyle(XColor.surfaceAlt),
                in: Capsule()
            )
            .overlay(
                // 顶部高光收敛：更哑光、少「塑料光泽」，像原生 macOS 按钮而非糖果
                Capsule()
                    .fill(LinearGradient(colors: [.white.opacity(enabled ? 0.13 : 0), .clear],
                                         startPoint: .top, endPoint: .center))
                    .allowsHitTesting(false)
            )
            .overlay(Capsule().strokeBorder(.white.opacity(enabled ? 0.14 : 0), lineWidth: 1))
            .opacity(configuration.isPressed ? 0.85 : 1)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .shadow(color: enabled ? XColor.brand.opacity(0.16) : .clear,
                    radius: configuration.isPressed ? 4 : 8, y: 4)
            .animation(XMotion.snappy, value: configuration.isPressed)
    }
}

public struct XSecondaryButtonStyle: ButtonStyle {
    var compact: Bool
    public init(compact: Bool = false) { self.compact = compact }
    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(compact ? XFont.bodyEmphasis : XFont.headline)
            .foregroundStyle(XColor.textPrimary)
            .padding(.horizontal, compact ? XSpacing.m : XSpacing.xl)
            .padding(.vertical, compact ? XSpacing.s : XSpacing.m)
            .background(XColor.surfaceAlt, in: Capsule())
            .overlay(Capsule().strokeBorder(XColor.border, lineWidth: 1))
            .opacity(configuration.isPressed ? 0.8 : 1)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(XMotion.snappy, value: configuration.isPressed)
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
                        .animation(XMotion.gauge, value: usedFraction)
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

// MARK: - 骨架屏（首帧未采样占位）

/// 首帧数据未就绪时的占位骨架：surfaceAlt 底 + 一道柔和微光扫过（Reduce Motion 下静止）。
/// 取代生硬的「正在读取…」文字，让指标卡/环/列表在数据到达前也有「结构感」而非空白。
public struct XSkeleton: View {
    let width: CGFloat?
    let height: CGFloat
    let cornerRadius: CGFloat
    @State private var shimmer = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    public init(width: CGFloat? = nil, height: CGFloat = 12, cornerRadius: CGFloat = XRadius.chip) {
        self.width = width
        self.height = height
        self.cornerRadius = cornerRadius
    }
    public var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(XColor.surfaceAlt)
            .frame(width: width, height: height)
            .frame(maxWidth: width == nil ? .infinity : nil, alignment: .leading)
            .overlay {
                if !reduceMotion {
                    GeometryReader { geo in
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .fill(LinearGradient(colors: [.clear, .white.opacity(0.10), .clear],
                                                 startPoint: .leading, endPoint: .trailing))
                            .frame(width: geo.size.width * 0.6)
                            .offset(x: shimmer ? geo.size.width : -geo.size.width * 0.6)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                }
            }
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.linear(duration: 1.3).repeatForever(autoreverses: false)) { shimmer = true }
            }
            .accessibilityHidden(true)
    }
}

/// 若干行骨架（列表/明细占位）。行宽做轻微递减，更像真实文本块而非等长积木。
public struct XSkeletonRows: View {
    let count: Int
    public init(count: Int = 3) { self.count = count }
    public var body: some View {
        VStack(alignment: .leading, spacing: XSpacing.s) {
            ForEach(0..<count, id: \.self) { i in
                XSkeleton(width: nil, height: 11)
                    .frame(maxWidth: i == count - 1 ? 160 : .infinity, alignment: .leading)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(xLoc("加载中"))
    }
}

// MARK: - 空态

public struct XEmptyState: View {
    public enum Kind { case neutral, success, error, loading }
    let systemImage: String
    let title: String
    let subtitle: String
    let kind: Kind
    @State private var appeared = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    public init(systemImage: String, title: String, subtitle: String, kind: Kind = .neutral) {
        self.systemImage = systemImage
        self.title = title
        self.subtitle = subtitle
        self.kind = kind
    }
    private var tint: [Color] {
        switch kind {
        case .neutral, .loading: return XColor.brandGradientColors
        case .success: return [XColor.accentTeal, XColor.success]
        case .error:   return [XColor.warning, XColor.accentPink]
        }
    }
    public var body: some View {
        VStack(spacing: XSpacing.m) {
            ZStack {
                Circle().fill(tint[0].opacity(0.12)).frame(width: 96, height: 96)
                if kind == .success { Circle().stroke(tint[0].opacity(0.35), lineWidth: 1).frame(width: 96, height: 96) }
                Image(systemName: systemImage)
                    .font(.system(size: 42, weight: .light))
                    .foregroundStyle(LinearGradient(colors: tint, startPoint: .topLeading, endPoint: .bottomTrailing))
                    .xGlow(kind == .success ? tint[0] : .clear, radius: 18, opacity: 0.5)
            }
            .scaleEffect(appeared || reduceMotion ? 1 : 0.7)
            .opacity(appeared || reduceMotion ? 1 : 0)
            Text(title).xTitle().foregroundStyle(XColor.textPrimary)
            Text(subtitle)
                .font(XFont.body).foregroundStyle(XColor.textSecondary)
                .multilineTextAlignment(.center).frame(maxWidth: 420).lineSpacing(2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(XSpacing.xxl)
        .onAppear { if !reduceMotion { withAnimation(XMotion.settle) { appeared = true } } }
    }
}
