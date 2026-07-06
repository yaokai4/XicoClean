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
            // 值弧
            if fraction > 0.004 {
                Circle()
                    .trim(from: 0, to: sweep * fraction)
                    .stroke(AngularGradient(colors: colors + [colors.first!], center: .center,
                                            startAngle: .degrees(135), endAngle: .degrees(405)),
                            style: StrokeStyle(lineWidth: size * 0.055, lineCap: .round))
                    .rotationEffect(.degrees(135))
                    .xGlow(colors.first!, radius: 9)
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.25), value: fraction)
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
