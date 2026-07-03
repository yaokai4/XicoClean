import SwiftUI

// MARK: - 招牌扫描动画（粒子轨道 + 脉冲波 + 旋转渐变环 + 滚动数字）

public struct XScanOrb: View {
    let value: String
    let label: String
    let colors: [Color]
    let size: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(value: String, label: String,
                colors: [Color] = XColor.ringColors, size: CGFloat = 300) {
        self.value = value
        self.label = label
        self.colors = colors.isEmpty ? XColor.ringColors : colors
        self.size = size
    }

    public var body: some View {
        Group {
            if reduceMotion { staticOrb } else { animatedOrb }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("正在扫描")
        .accessibilityValue("\(label) \(value)")
    }

    /// Reduce Motion 下的静态降级：无旋转/粒子，仅静态环 + 数值
    private var staticOrb: some View {
        let lineW = size * 0.03
        return ZStack {
            Circle().stroke(XColor.surfaceAlt.opacity(0.38), lineWidth: lineW)
            Circle()
                .trim(from: 0, to: 0.7)
                .stroke(AngularGradient(colors: colors + [colors[0]], center: .center),
                        style: StrokeStyle(lineWidth: lineW, lineCap: .round))
                .rotationEffect(.degrees(-90))
            VStack(spacing: 6) {
                Text(value).xHeroNumber().foregroundStyle(XColor.textPrimary)
                Text(label).font(XFont.body).foregroundStyle(XColor.textSecondary).tracking(0.3)
            }
        }
        .frame(width: size, height: size)
    }

    @ViewBuilder private var animatedOrb: some View {
        let lineW = size * 0.03
        let r = size / 2 - lineW / 2
        let c0 = colors[0]
        let c1 = colors[min(1, colors.count - 1)]
        let c2 = colors[min(2, colors.count - 1)]

        TimelineView(.animation) { tl in
            let t = tl.date.timeIntervalSinceReferenceDate
            // 非线性旋转：基础速度 + 正弦微调 → 有机、不机械
            let angle = t * 52 + 16 * sin(t * 0.85)
            // 弧长呼吸式伸缩（彗尾时长时短，灵动）
            let arcLen = 0.46 + 0.20 * (0.5 + 0.5 * sin(t * 1.35))
            // 辉光脉动
            let breathe = 0.5 + 0.5 * sin(t * 1.05)
            let headRad = (angle + arcLen * 360) * .pi / 180

            ZStack {
                // 柔光底（脉动呼吸）
                Circle()
                    .fill(RadialGradient(colors: [c1.opacity(0.12 + 0.08 * breathe), .clear],
                                         center: .center, startRadius: 0, endRadius: size * 0.5))
                    .blur(radius: 38)
                    .scaleEffect(0.9 + 0.12 * breathe)

                // 轨道底环
                Circle().stroke(XColor.surfaceAlt.opacity(0.38), lineWidth: lineW)

                // 反向内弧（不同速度，增加层次与流动感）
                Circle()
                    .trim(from: 0, to: 0.22)
                    .stroke(c2.opacity(0.32), style: StrokeStyle(lineWidth: lineW * 0.5, lineCap: .round))
                    .rotationEffect(.degrees(-angle * 0.62))
                    .padding(lineW * 1.8)

                // 主弧（流动的彗星：弧长呼吸 + 有机旋转 + 柔和辉光）
                Circle()
                    .trim(from: 0, to: arcLen)
                    .stroke(AngularGradient(colors: colors + [c0], center: .center),
                            style: StrokeStyle(lineWidth: lineW, lineCap: .round))
                    .rotationEffect(.degrees(angle))
                    .shadow(color: c1.opacity(0.3 + 0.15 * breathe), radius: 14)

                // 弧头高光点（彗星头）
                Circle()
                    .fill(.white)
                    .frame(width: lineW * (0.9 + 0.2 * breathe), height: lineW * (0.9 + 0.2 * breathe))
                    .shadow(color: c2.opacity(0.9), radius: 10)
                    .offset(x: CGFloat(cos(headRad)) * r, y: CGFloat(sin(headRad)) * r)

                // 中心：等宽数字直接刷新（不做逐位滚动）。扫描计数每秒更新多次，
                // 一旦叠加 numericText 滚动动画就会永远处于「过渡中」→ 数字发虚模糊。
                // 等宽字形保证位宽稳定，裸刷新看起来是平滑攀升，干净、高级、不糊。
                VStack(spacing: 6) {
                    Text(value).xHeroNumber().foregroundStyle(XColor.textPrimary)
                    Text(label).font(XFont.body).foregroundStyle(XColor.textSecondary).tracking(0.3)
                }
            }
            .frame(width: size, height: size)
        }
        .frame(width: size, height: size)
    }
}

// MARK: - 精致复选框（动画勾选，替代系统样式）

public struct XCheckbox: View {
    let isOn: Bool
    let colors: [Color]
    let toggle: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(isOn: Bool, colors: [Color] = XColor.brandGradientColors, toggle: @escaping () -> Void) {
        self.isOn = isOn
        self.colors = colors
        self.toggle = toggle
    }

    public var body: some View {
        // 用 Button 实现：自动获得键盘可达（Tab 聚焦 + 空格/回车触发）与无障碍 trait
        Button(action: toggle) {
            ZStack {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(isOn ? Color.clear : XColor.textTertiary.opacity(0.6), lineWidth: 1.5)
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing))
                    .opacity(isOn ? 1 : 0)
                    .scaleEffect(isOn ? 1 : 0.6)
                if isOn {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .heavy))
                        .foregroundStyle(.white)
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .frame(width: 19, height: 19)
            .animation(reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.6), value: isOn)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("勾选")
        .accessibilityValue(isOn ? "已选中" : "未选中")
        .accessibilityAddTraits(.isButton)
    }
}

// MARK: - 完成庆祝粒子爆发

public struct XCelebrationBurst: View {
    let colors: [Color]
    @State private var start = Date()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    public init(colors: [Color] = [XColor.success, XColor.accentTeal, XColor.brand]) {
        self.colors = colors.isEmpty ? [XColor.brand] : colors
    }
    public var body: some View {
        // Reduce Motion 下跳过粒子爆发（完成页另有静态对勾）
        if reduceMotion {
            Color.clear.allowsHitTesting(false)
        } else {
            burst
        }
    }
    private var burst: some View {
        TimelineView(.animation) { tl in
            let e = tl.date.timeIntervalSince(start)
            Canvas { ctx, sz in
                let c = CGPoint(x: sz.width / 2, y: sz.height / 2)
                let n = 30
                for i in 0..<n {
                    let ang = Double(i) / Double(n) * 2 * .pi
                    let speed = 0.6 + 0.5 * abs(sin(Double(i) * 1.3))
                    let dist = CGFloat(min(e, 1.4)) * 150 * CGFloat(speed)
                    let op = max(0, 1 - e / 1.4)
                    let x = c.x + CGFloat(cos(ang)) * dist
                    let y = c.y + CGFloat(sin(ang)) * dist - CGFloat(e * e * 18) // 轻微下落
                    let r: CGFloat = 3.5 * CGFloat(op)
                    let rect = CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2)
                    ctx.fill(Path(ellipseIn: rect), with: .color(colors[i % colors.count].opacity(op)))
                }
            }
        }
        .allowsHitTesting(false)
    }
}

// MARK: - 悬停抬升修饰

public struct HoverLift: ViewModifier {
    @State private var hover = false
    let amount: CGFloat
    public init(amount: CGFloat = 3) { self.amount = amount }
    public func body(content: Content) -> some View {
        content
            .offset(y: hover ? -amount : 0)
            .shadow(color: .black.opacity(hover ? 0.14 : 0), radius: hover ? 16 : 0, y: hover ? 10 : 0)
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: hover)
            .onHover { hover = $0 }
    }
}

public extension View {
    func hoverLift(_ amount: CGFloat = 3) -> some View { modifier(HoverLift(amount: amount)) }
}
