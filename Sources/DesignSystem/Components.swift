import SwiftUI

// MARK: - 卡片

public struct XCard<Content: View>: View {
    private let content: Content
    private let padding: CGFloat
    private let elevated: Bool
    /// fill=true：卡面撑满可用高度（网格同排等高用；内容顶对齐，余量由卡面补齐——消灭「一大一小」）。
    private let fill: Bool
    @Environment(\.colorScheme) private var scheme
    public init(padding: CGFloat = XSpacing.l, elevated: Bool = true, fill: Bool = false,
                @ViewBuilder content: () -> Content) {
        self.padding = padding
        self.elevated = elevated
        self.fill = fill
        self.content = content()
    }
    public var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, maxHeight: fill ? .infinity : nil,
                   alignment: fill ? .topLeading : .leading)
            .background(
                // 暗色高程双通道：surface 随 z 轴提亮（黑影在墨底上不可见，提亮才是主信号）；
                // 浅色恒白、层级由阴影承担。
                RoundedRectangle(cornerRadius: XRadius.card, style: .continuous)
                    .fill(XColor.surface(at: elevated ? .raised : .resting))
                    .overlay(
                        // 顶部受光面：暗色用白高光；浅色下白高光是 no-op（白底），
                        // 改用极淡的顶部内衬阴影制造纸面纵深。
                        RoundedRectangle(cornerRadius: XRadius.card, style: .continuous)
                            .fill(LinearGradient(
                                colors: scheme == .dark ? [.white.opacity(XAlpha.hairline), .clear]
                                                        : [.black.opacity(0.02), .clear],
                                startPoint: .top, endPoint: .center))
                    )
            )
            .overlay(
                // 描边：暗色改「内侧 1px 高光」（上亮下暗，受光的实物边缘）；浅色保持暗描边。
                RoundedRectangle(cornerRadius: XRadius.card, style: .continuous)
                    .strokeBorder(
                        scheme == .dark
                            ? AnyShapeStyle(LinearGradient(colors: [.white.opacity(0.09), .white.opacity(0.02)],
                                                           startPoint: .top, endPoint: .bottom))
                            : AnyShapeStyle(XColor.border.opacity(0.6)),
                        lineWidth: 1)
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
                        .contentTransition(.numericText())   // 指标数字滚动到位（docs/16 P1-3）
                    Text(label).font(XFont.caption).foregroundStyle(XColor.textSecondary).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
        }
        // P7 统一卡片悬停物理：与 XStatCard 同走 hoverLift（此前 xGlow+scale 与上浮两派并存）。
        .hoverLift(2)
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
            .padding(.vertical, XSpacing.xs)   // P7：上网格（原 3pt 离网魔数）
            .background(color.opacity(XAlpha.tint), in: Capsule())
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
        PrimaryBody(configuration: configuration, enabled: enabled, large: large, compact: compact)
    }

    /// 内部承载 hover/focus 状态（P7：Mac 指针环境下按钮必须有悬停反馈 + 键盘焦点环）。
    private struct PrimaryBody: View {
        let configuration: Configuration
        let enabled: Bool
        let large: Bool
        let compact: Bool
        @State private var hover = false
        @Environment(\.isFocused) private var focused

        var body: some View {
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
                // 渐变胶囊叠 grain（docs/16 P0-3 收尾）：主按钮常是一屏的渐变主角，微粒把
                // 「渲染图平滑」压成哑光实物感，顺手消灭暗色 banding。裁进胶囊，角外不漏。
                .overlay {
                    if enabled {
                        XGrain().opacity(0.25).clipShape(Capsule())
                    }
                }
                .overlay(
                    // 顶部高光收敛：更哑光、少「塑料光泽」，像原生 macOS 按钮而非糖果
                    Capsule()
                        .fill(LinearGradient(colors: [.white.opacity(enabled ? 0.13 : 0), .clear],
                                             startPoint: .top, endPoint: .center))
                        .allowsHitTesting(false)
                )
                .overlay(Capsule().strokeBorder(.white.opacity(enabled ? 0.14 : 0), lineWidth: 1))
                // 键盘焦点环：2px 品牌描边（与侧栏焦点环同语言）。
                .overlay(Capsule().strokeBorder(focused ? XColor.brand : .clear, lineWidth: 2).padding(-3))
                .brightness(hover && enabled && !configuration.isPressed ? 0.05 : 0)
                .opacity(configuration.isPressed ? 0.85 : 1)
                .scaleEffect(configuration.isPressed ? 0.97 : 1)
                .shadow(color: enabled ? XColor.brand.opacity(hover ? 0.24 : 0.16) : .clear,
                        radius: configuration.isPressed ? 4 : (hover ? 10 : 8), y: 4)
                .animation(XMotion.snappy, value: configuration.isPressed)
                .animation(XMotion.hover, value: hover)
                .onHover { hover = $0 }
        }
    }
}

public struct XSecondaryButtonStyle: ButtonStyle {
    var compact: Bool
    public init(compact: Bool = false) { self.compact = compact }
    public func makeBody(configuration: Configuration) -> some View {
        SecondaryBody(configuration: configuration, compact: compact)
    }

    private struct SecondaryBody: View {
        let configuration: Configuration
        let compact: Bool
        @State private var hover = false
        @Environment(\.isFocused) private var focused

        var body: some View {
            configuration.label
                .font(compact ? XFont.bodyEmphasis : XFont.headline)
                .foregroundStyle(XColor.textPrimary)
                .padding(.horizontal, compact ? XSpacing.m : XSpacing.xl)
                .padding(.vertical, compact ? XSpacing.s : XSpacing.m)
                .background(hover ? XColor.surfaceHover : XColor.surfaceAlt, in: Capsule())
                .overlay(Capsule().strokeBorder(XColor.border, lineWidth: 1))
                .overlay(Capsule().strokeBorder(focused ? XColor.brand : .clear, lineWidth: 2).padding(-3))
                .opacity(configuration.isPressed ? 0.8 : 1)
                .scaleEffect(configuration.isPressed ? 0.97 : 1)
                .animation(XMotion.snappy, value: configuration.isPressed)
                .animation(XMotion.hover, value: hover)
                .onHover { hover = $0 }
        }
    }
}

/// 危险动作专属按钮（删除/粉碎）：danger 渐变实底 + 白字——清理类应用最高危动作的专属语义，
/// 与主/次按钮一眼可辨。约定：标签必须用具体动词（「删除 23 项」而非「确定」）。
public struct XDestructiveButtonStyle: ButtonStyle {
    var compact: Bool
    public init(compact: Bool = false) { self.compact = compact }
    public func makeBody(configuration: Configuration) -> some View {
        DestructiveBody(configuration: configuration, compact: compact)
    }

    private struct DestructiveBody: View {
        let configuration: Configuration
        let compact: Bool
        @State private var hover = false
        @Environment(\.isFocused) private var focused

        var body: some View {
            configuration.label
                .font(compact ? XFont.bodyEmphasis : XFont.headline)
                .foregroundStyle(XColor.onAccent)
                .padding(.horizontal, compact ? XSpacing.m : XSpacing.xl)
                .padding(.vertical, compact ? XSpacing.s : XSpacing.m)
                .background(
                    LinearGradient(colors: [XColor.danger, XColor.accentPink],
                                   startPoint: .topLeading, endPoint: .bottomTrailing),
                    in: Capsule()
                )
                .overlay(Capsule().strokeBorder(focused ? XColor.danger : .clear, lineWidth: 2).padding(-3))
                .brightness(hover && !configuration.isPressed ? 0.05 : 0)
                .opacity(configuration.isPressed ? 0.85 : 1)
                .scaleEffect(configuration.isPressed ? 0.97 : 1)
                .shadow(color: XColor.danger.opacity(hover ? 0.28 : 0.20), radius: configuration.isPressed ? 4 : 8, y: 4)
                .animation(XMotion.snappy, value: configuration.isPressed)
                .animation(XMotion.hover, value: hover)
                .onHover { hover = $0 }
        }
    }
}

// MARK: - 分段控件（自绘胶囊，统一取代系统 .segmented）

/// 自绘胶囊分段控件：物理与 AppearanceToggle 一致（选中段 = 品牌淡染 + 品牌色前景）。
/// 全应用同一种分段语言，替换散落的系统 `.segmented` Picker。
public struct XSegmentedControl<T: Hashable>: View {
    public struct Option {
        public let tag: T
        public let icon: String?
        public let label: String?
        public let a11y: String
        public init(tag: T, icon: String? = nil, label: String? = nil, a11y: String) {
            self.tag = tag
            self.icon = icon
            self.label = label
            self.a11y = a11y
        }
    }
    @Binding var selection: T
    let options: [Option]
    public init(selection: Binding<T>, options: [Option]) {
        _selection = selection
        self.options = options
    }
    public var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(options.enumerated()), id: \.offset) { _, opt in
                let active = selection == opt.tag
                Button {
                    withAnimation(XMotion.snappy) { selection = opt.tag }
                } label: {
                    HStack(spacing: 4) {
                        if let icon = opt.icon { Image(systemName: icon).font(XFont.captionEmphasis) }
                        if let label = opt.label { Text(label).font(XFont.captionEmphasis) }
                    }
                    .frame(minWidth: 30, minHeight: 22)
                    .padding(.horizontal, opt.label == nil ? 0 : XSpacing.s)
                    .foregroundStyle(active ? AnyShapeStyle(XColor.brand) : AnyShapeStyle(XColor.textSecondary))
                    .background(Capsule().fill(active ? AnyShapeStyle(XColor.brand.opacity(XAlpha.tint))
                                                      : AnyShapeStyle(Color.clear)))
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(opt.a11y)
                .accessibilityAddTraits(active ? [.isButton, .isSelected] : .isButton)
            }
        }
        .padding(3)
        .background(XColor.surfaceAlt.opacity(0.6), in: Capsule())
        .overlay(Capsule().strokeBorder(XColor.border.opacity(0.6), lineWidth: 1))
    }
}

// MARK: - 胶囊输入框（docs/16 P0-4：付费转化页零系统灰控件）

/// 自绘胶囊文本框：surfaceAlt 底 + 品牌焦点环——替代系统 `.roundedBorder` 灰框，
/// 与全应用的胶囊/玻璃语言一致。
public struct XCapsuleTextField: View {
    let placeholder: String
    @Binding var text: String
    let onSubmit: () -> Void
    @FocusState private var focused: Bool

    public init(placeholder: String, text: Binding<String>, onSubmit: @escaping () -> Void = {}) {
        self.placeholder = placeholder
        self._text = text
        self.onSubmit = onSubmit
    }

    public var body: some View {
        TextField(placeholder, text: $text)
            .textFieldStyle(.plain)
            .font(XFont.body)
            .focused($focused)
            .onSubmit(onSubmit)
            .padding(.horizontal, XSpacing.m)
            .padding(.vertical, XSpacing.s)
            .background(Capsule().fill(XColor.surfaceAlt.opacity(0.8)))
            .overlay(Capsule().strokeBorder(focused ? XColor.brand : XColor.border,
                                            lineWidth: focused ? 1.5 : 1))
            .animation(XMotion.hover, value: focused)
    }
}

// MARK: - Toast（非模态轻提示）

/// 底部浮动 toast：非模态、自动消失，用于「已拦截 / 已完成」类轻反馈——
/// 取代打断式 alert 的场景（删除类拒收提示等）。
public struct XToastPresenter: ViewModifier {
    @Binding var message: String?
    let icon: String
    let tint: Color
    @State private var dismissTask: Task<Void, Never>?
    public func body(content: Content) -> some View {
        content.overlay(alignment: .bottom) {
            if let message {
                HStack(spacing: XSpacing.s) {
                    Image(systemName: icon).font(XFont.bodyEmphasis).foregroundStyle(tint)
                    Text(message).font(XFont.bodyEmphasis).foregroundStyle(XColor.textPrimary)
                        .lineLimit(2).multilineTextAlignment(.leading)
                }
                .padding(.horizontal, XSpacing.l).padding(.vertical, XSpacing.m)
                .xFloatingGlassCapsule()
                .xElevation(.overlay)
                .padding(.bottom, XSpacing.xxl)
                .frame(maxWidth: 520)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .onAppear {
                    dismissTask?.cancel()
                    dismissTask = Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 3_200_000_000)
                        guard !Task.isCancelled else { return }
                        withAnimation(XMotion.crossfade) { self.message = nil }
                    }
                }
                .accessibilityLabel(message)
            }
        }
        .animation(XMotion.settle, value: message)
    }
}

public extension View {
    /// 挂一个自动消失的 toast（绑定非 nil 即显示，3.2s 后自动清空）。
    func xToast(_ message: Binding<String?>,
                icon: String = "exclamationmark.triangle.fill",
                tint: Color = XColor.warning) -> some View {
        modifier(XToastPresenter(message: message, icon: icon, tint: tint))
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
            VStack(alignment: .leading, spacing: XSpacing.xxs) {
                Text(title).font(XFont.headline).foregroundStyle(XColor.textPrimary)
                Text(subtitle).font(XFont.caption).foregroundStyle(XColor.textSecondary)
            }
            Spacer()
            trailing
        }
        .padding(.horizontal, XSpacing.xl)
        .padding(.vertical, XSpacing.l)
        .xSurface(.thin)   // 浮层材质走令牌（导航层专属；内容卡片仍是不透明 surface）
        // 双色发丝线（docs/16）：暗线 + 下沿极淡高光 = 「刻痕」的实物感，单色发丝在暗底会消失。
        .overlay(alignment: .top) {
            VStack(spacing: 0) {
                Rectangle().fill(XColor.hairline).frame(height: 1)
                Rectangle().fill(Color.white.opacity(0.04)).frame(height: 0.5)
            }
        }
    }
}

// MARK: - 分区卡（uppercase 小标 + 图标 + 内容槽）

/// 统一的「分区卡」容器：扁平染色图标块 + 大写细纹小标 + 任意内容。
/// 收编 HardwareView.HardwareCard 与菜单栏总览 card() 两套私有实现（P5·H5）——
/// 同一种卡头语言，硬件页、菜单栏面板、后续新页面共用。
public struct XSectionCard<Content: View, Trailing: View>: View {
    let icon: String
    let title: String
    let iconColors: [Color]
    let trailing: Trailing
    let content: Content

    var fillHeight: Bool = false

    public init(icon: String, title: String, iconColors: [Color] = XColor.brandGradientColors,
                fillHeight: Bool = false,
                @ViewBuilder trailing: () -> Trailing = { EmptyView() },
                @ViewBuilder content: () -> Content) {
        self.icon = icon
        self.title = title
        self.iconColors = iconColors
        self.fillHeight = fillHeight
        self.trailing = trailing()
        self.content = content()
    }

    public var body: some View {
        XCard(fill: fillHeight) {
            VStack(alignment: .leading, spacing: XSpacing.m) {
                HStack(spacing: XSpacing.s) {
                    XIconTile(systemImage: icon, colors: iconColors, size: 28, flat: true)
                    Text(title).font(XFont.captionEmphasis).foregroundStyle(XColor.textSecondary)
                        .textCase(.uppercase).tracking(0.6)
                    Spacer()
                    trailing
                }
                content
            }
        }
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
                // 染色圆叠 grain（docs/16 P0-3 收尾）：大面积淡染最容易暴露数字平滑感。
                Circle().fill(tint[0].opacity(0.12)).frame(width: 96, height: 96)
                    .overlay(XGrain().opacity(0.4).clipShape(Circle()))
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
