import SwiftUI

// MARK: - 车速表式速度仪（磁盘测速用，270° 弧 + 刻度 + 渐变指针弧）

public struct XSpeedGauge: View {
    let value: Double          // 当前值（MB/s）
    let maxValue: Double       // 满量程
    let label: String          // 读取 / 写入
    let colors: [Color]
    let size: CGFloat
    let active: Bool           // 非当前阶段时整体减淡

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(value: Double, maxValue: Double, label: String,
                colors: [Color] = XColor.brandGradientColors,
                size: CGFloat = 190, active: Bool = true) {
        self.value = value
        self.maxValue = max(maxValue, 1)
        self.label = label
        self.colors = colors
        self.size = size
        self.active = active
    }

    private var fraction: Double { min(1, max(0, value / maxValue)) }
    private let sweep = 0.75    // 270°

    public var body: some View {
        ZStack {
            // 轨道
            Circle()
                .trim(from: 0, to: sweep)
                .stroke(XColor.surfaceAlt, style: StrokeStyle(lineWidth: size * 0.055, lineCap: .round))
                .rotationEffect(.degrees(135))
            // 幽灵渐变（未充部分透一丝色，与 XRingGauge 同语言）
            Circle()
                .trim(from: 0, to: sweep)
                .stroke(AngularGradient(colors: colors + [colors.first!], center: .center,
                                        startAngle: .degrees(135), endAngle: .degrees(405)),
                        style: StrokeStyle(lineWidth: size * 0.055, lineCap: .round))
                .rotationEffect(.degrees(135))
                .opacity(0.14)
            // 值弧：0.15s 线性跟随 0.1s 的采样节奏——指针「贴着」实时速度走，不拖不跳
            if fraction > 0.004 {
                Circle()
                    .trim(from: 0, to: sweep * fraction)
                    .stroke(AngularGradient(colors: colors + [colors.first!], center: .center,
                                            startAngle: .degrees(135), endAngle: .degrees(405)),
                            style: StrokeStyle(lineWidth: size * 0.055, lineCap: .round))
                    .rotationEffect(.degrees(135))
                    .xGlow(colors.first!, radius: active ? 12 : 8)
                    .animation(reduceMotion ? nil : .linear(duration: 0.15), value: fraction)
            }
            // 刻度（9 根主刻度，等分满量程）
            ForEach(0..<9, id: \.self) { i in
                let f = Double(i) / 8.0
                Rectangle()
                    .fill(XColor.textTertiary.opacity(0.55))
                    .frame(width: 1.5, height: size * 0.035)
                    .offset(y: -size * 0.40)
                    .rotationEffect(.degrees(135 + 90 + 270 * f))
            }
            // 中心读数
            VStack(spacing: 2) {
                Text(centerText)
                    .font(.system(size: size * 0.19, weight: .bold, design: .rounded))
                    .foregroundStyle(XColor.textPrimary)
                    .monospacedDigit()
                    .lineLimit(1).minimumScaleFactor(0.6)
                    .contentTransition(.numericText())
                    .frame(maxWidth: size * 0.62)
                Text("MB/s").font(XFont.caption).foregroundStyle(XColor.textTertiary)
                Text(label).font(XFont.captionEmphasis).foregroundStyle(XColor.textSecondary)
                    .padding(.top, 1)
            }
        }
        .frame(width: size, height: size)
        .opacity(active ? 1 : 0.45)
        .animation(.easeOut(duration: 0.2), value: active)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue("\(Int(value.rounded())) MB/s")
    }

    private var centerText: String {
        value >= 1 ? String(format: "%.0f", value) : "0"
    }
}

// MARK: - 品牌彗星旋转器（替代普通转圈，测速/短等待用）

public struct XCometSpinner: View {
    let size: CGFloat
    let colors: [Color]
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(size: CGFloat = 16, colors: [Color] = XColor.brandGradientColors) {
        self.size = size
        self.colors = colors
    }

    private var comet: Gradient {
        let c0 = colors[0]
        let c1 = colors[min(1, colors.count - 1)]
        // 与 XScanOrb 同一套「尾透明→头最亮、尾帽回绕归零」的防孤点做法
        return Gradient(stops: [
            .init(color: c0.opacity(0),   location: 0.00),
            .init(color: c0.opacity(0.4), location: 0.35),
            .init(color: c1,              location: 0.70),
            .init(color: c1,              location: 0.72),
            .init(color: c1.opacity(0),   location: 0.76),
            .init(color: c1.opacity(0),   location: 1.00),
        ])
    }

    public var body: some View {
        Group {
            if reduceMotion {
                Circle().trim(from: 0.01, to: 0.70)
                    .stroke(AngularGradient(gradient: comet, center: .center),
                            style: StrokeStyle(lineWidth: size * 0.14, lineCap: .round))
            } else {
                TimelineView(.animation) { tl in
                    let angle = tl.date.timeIntervalSinceReferenceDate * 220
                    Circle().trim(from: 0.01, to: 0.70)
                        .stroke(AngularGradient(gradient: comet, center: .center),
                                style: StrokeStyle(lineWidth: size * 0.14, lineCap: .round))
                        .rotationEffect(.degrees(angle))
                }
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}
