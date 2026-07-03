import SwiftUI

// MARK: - 应用背景（深邃渐变 + 淡彩虹辉光，静态以省电）

public struct AppBackground: View {
    public init() {}
    public var body: some View {
        ZStack {
            LinearGradient(colors: [XColor.canvasTop, XColor.canvasBottom],
                           startPoint: .top, endPoint: .bottom)
            // 背景以中性画布为主，仅留一丝色彩做纵深——克制、高级、真实，
            // 而非四角满屏彩虹「概念稿」水洗感。彩色留给数据本身（环、图、图标）。
            glow(XColor.ringPeri, center: UnitPoint(x: 0.90, y: 0.02), r: 720, o: 0.07)
            glow(XColor.ringRose, center: UnitPoint(x: 0.04, y: 0.98), r: 680, o: 0.06)
        }
        .ignoresSafeArea()
    }

    private func glow(_ color: Color, center: UnitPoint, r: CGFloat, o: Double) -> some View {
        RadialGradient(colors: [color.opacity(o), .clear], center: center, startRadius: 0, endRadius: r)
    }
}

// MARK: - 圆形进度 / 仪表（招牌）

public struct XRingGauge<Center: View>: View {
    let progress: Double
    let spinning: Bool
    let colors: [Color]
    let lineWidth: CGFloat
    let size: CGFloat
    let center: Center
    @State private var spin = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(progress: Double, spinning: Bool = false,
                colors: [Color] = XColor.brandGradientColors,
                lineWidth: CGFloat = 22, size: CGFloat = 280,
                @ViewBuilder center: () -> Center) {
        self.progress = progress
        self.spinning = spinning
        self.colors = colors.isEmpty ? XColor.brandGradientColors : colors
        self.lineWidth = lineWidth
        self.size = size
        self.center = center()
    }

    public var body: some View {
        ZStack {
            Circle()
                .stroke(XColor.surfaceAlt, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))

            // 幽灵渐变环：未填充处也透出一丝品牌色，更通透高级
            Circle()
                .stroke(AngularGradient(colors: colors + [colors.first!], center: .center),
                        style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .opacity(0.12)

            Circle()
                .fill(RadialGradient(colors: [colors.first!.opacity(0.16), .clear],
                                     center: .center, startRadius: 0, endRadius: size / 2))
                .padding(lineWidth)

            // 进度弧：接近 0 时完全不画（否则 0% 也留一颗「浮尘」孤点）。
            if progress > 0.004 {
                Circle()
                    .trim(from: 0, to: min(progress, 1))
                    .stroke(AngularGradient(colors: colors + [colors.first!], center: .center),
                            style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .xGlow(colors.first!, radius: 14)
                    .animation(reduceMotion ? nil : .easeInOut(duration: 0.5), value: progress)
            }

            if spinning {
                Circle()
                    .trim(from: 0, to: 0.16)
                    .stroke(colors.last!.opacity(0.85),
                            style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(spin ? 360 : 0))
                    .blur(radius: 3)
            }

            center.padding(lineWidth + XSpacing.l)
        }
        .frame(width: size, height: size)
        .accessibilityElement(children: .combine)
        .accessibilityValue("\(Int((max(0, min(progress, 1)) * 100).rounded()))%")
        .onAppear { restartSpin() }
        .onChange(of: spinning) { _ in restartSpin() }
    }

    private func restartSpin() {
        spin = false
        guard spinning, !reduceMotion else { return }   // Reduce Motion 下不做无限旋转
        withAnimation(.linear(duration: 1.1).repeatForever(autoreverses: false)) { spin = true }
    }
}

// MARK: - 迷你进度圆环（仪表盘指标卡 / 通用）

public struct XMiniRing<Center: View>: View {
    let fraction: Double
    let colors: [Color]
    let size: CGFloat
    let lineWidth: CGFloat
    let center: Center
    public init(fraction: Double, colors: [Color], size: CGFloat = 46, lineWidth: CGFloat = 5,
                @ViewBuilder center: () -> Center = { EmptyView() }) {
        self.fraction = fraction
        self.colors = colors.isEmpty ? XColor.brandGradientColors : colors
        self.size = size
        self.lineWidth = lineWidth
        self.center = center()
    }
    public var body: some View {
        ZStack {
            Circle().stroke(XColor.surfaceAlt, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
            Circle()
                .trim(from: 0, to: max(0.02, min(fraction, 1)))
                .stroke(AngularGradient(gradient: Gradient(colors: colors + [colors[0]]), center: .center),
                        style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.easeInOut(duration: 0.5), value: fraction)
            center
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)   // 装饰性：信息由相邻文字承载
    }
}

// MARK: - 图标方块

public struct XIconTile: View {
    let systemImage: String
    let colors: [Color]
    let size: CGFloat
    public init(systemImage: String, colors: [Color] = XColor.brandGradientColors, size: CGFloat = 30) {
        self.systemImage = systemImage
        self.colors = colors.isEmpty ? XColor.brandGradientColors : colors
        self.size = size
    }
    public var body: some View {
        RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
            .fill(LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing))
            .frame(width: size, height: size)
            .overlay(
                Image(systemName: systemImage)
                    .font(.system(size: size * 0.5, weight: .medium))
                    .foregroundStyle(.white)
            )
            .shadow(color: colors.first!.opacity(0.35), radius: 6, y: 3)
    }
}

// MARK: - 统计卡

public struct XStatCard: View {
    let icon: String
    let iconColors: [Color]
    let value: String
    let label: String
    public init(icon: String, iconColors: [Color] = XColor.brandGradientColors, value: String, label: String) {
        self.icon = icon
        self.iconColors = iconColors
        self.value = value
        self.label = label
    }
    public var body: some View {
        XCard(padding: XSpacing.l) {
            VStack(alignment: .leading, spacing: XSpacing.m) {
                XIconTile(systemImage: icon, colors: iconColors, size: 36)
                VStack(alignment: .leading, spacing: 3) {
                    Text(value).font(XFont.monoLarge).foregroundStyle(XColor.textPrimary).lineLimit(1)
                    Text(label).font(XFont.caption).foregroundStyle(XColor.textSecondary).lineLimit(1)
                }
            }
        }
        .hoverLift(2)
    }
}

// MARK: - 页面头部

public struct XHeaderBar<Trailing: View>: View {
    let title: String
    let subtitle: String
    let trailing: Trailing
    public init(title: String, subtitle: String, @ViewBuilder trailing: () -> Trailing = { EmptyView() }) {
        self.title = title
        self.subtitle = subtitle
        self.trailing = trailing()
    }
    public var body: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).xTitle().foregroundStyle(XColor.textPrimary)
                if !subtitle.isEmpty {
                    Text(subtitle).font(XFont.callout).foregroundStyle(XColor.textSecondary)
                }
            }
            Spacer()
            trailing
        }
        .padding(.horizontal, XSpacing.xl)
        .padding(.top, XSpacing.l)
        .padding(.bottom, XSpacing.m)
    }
}
