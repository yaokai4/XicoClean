import SwiftUI

// MARK: - 招牌扫描动画（粒子轨道 + 脉冲波 + 旋转渐变环 + 滚动数字）

public struct XScanOrb: View {
    let value: String
    let label: String
    let colors: [Color]
    let size: CGFloat
    /// 确定性进度（0…1）。非 nil 时在彗星后画一圈「诚实填充」的进度弧——
    /// 让长扫描有真实完成感，而不是纯装饰的循环（对标 CleanMyMac 的填充环）。
    let progress: Double?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(value: String, label: String,
                colors: [Color] = XColor.ringColors, size: CGFloat = 300, progress: Double? = nil) {
        self.value = value
        self.label = label
        self.colors = colors.isEmpty ? XColor.ringColors : colors
        self.size = size
        self.progress = progress
    }

    /// 进度填充弧（彗星后方的「诚实」环）。
    @ViewBuilder private func progressArc(lineWidth: CGFloat) -> some View {
        if let p = progress, p > 0.004 {
            Circle()
                .trim(from: 0, to: min(p, 1))
                .stroke(AngularGradient(colors: colors + [colors[0]], center: .center),
                        style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .opacity(0.9)
                .animation(reduceMotion ? nil : XMotion.gauge, value: p)
        }
    }

    public var body: some View {
        Group {
            if reduceMotion { staticOrb } else { animatedOrb }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(xLoc("正在扫描"))
        .accessibilityValue("\(label) \(value)")
    }

    /// 彗星渐变：尾部透明 → 头部最亮（location 0.72 即弧头）。
    /// 头部本身就是渐变的最亮端 + 柔光，取代旧版「浮在弧末的分离白点」（用户点名的塑料感来源）。
    /// 注意 0.78 之后归零：圆头笔帽会越过 trim 端点少许继续采样角度渐变，
    /// 尾帽越过 0 时回绕到 location≈1.0——若那里仍是亮色，就会在尾部憋出一颗「孤点」。
    private var cometGradient: Gradient {
        let c0 = colors[0]
        let c1 = colors[min(1, colors.count - 1)]
        let c2 = colors[min(2, colors.count - 1)]
        return Gradient(stops: [
            .init(color: c0.opacity(0),    location: 0.00),
            .init(color: c0.opacity(0.22), location: 0.26),
            .init(color: c1,               location: 0.54),
            .init(color: c2,               location: 0.72),
            .init(color: c2,               location: 0.745),
            .init(color: c2.opacity(0),    location: 0.78),
            .init(color: c2.opacity(0),    location: 1.00),
        ])
    }

    private var centerLabel: some View {
        // 等宽数字裸刷新（不做逐位滚动，避免「永远过渡中」发虚），平滑攀升、清晰不糊。
        VStack(spacing: 6) {
            Text(value).xHeroNumber().foregroundStyle(XColor.textPrimary)
            Text(label).font(XFont.body).foregroundStyle(XColor.textSecondary).tracking(0.3)
        }
    }

    /// Reduce Motion 下的静态降级：无旋转，单条渐变弧 + 数值（同样无分离白点）。
    /// 确定性进度用实色渐变（彗星渐变 0.78 后归零，进度 >78% 会「断头」）。
    private var staticOrb: some View {
        let lineW = size * 0.028
        let c2 = colors[min(2, colors.count - 1)]
        return ZStack {
            Circle().stroke(XColor.surfaceAlt.opacity(0.30), lineWidth: lineW)
            if let p = progress {
                Circle()
                    .trim(from: 0, to: min(max(p, 0.02), 1))
                    .stroke(AngularGradient(colors: colors + [colors[0]], center: .center),
                            style: StrokeStyle(lineWidth: lineW, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .shadow(color: c2.opacity(0.35), radius: lineW * 1.3)
            } else {
                Circle()
                    .trim(from: 0.01, to: 0.72)
                    .stroke(AngularGradient(gradient: cometGradient, center: .center),
                            style: StrokeStyle(lineWidth: lineW, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .shadow(color: c2.opacity(0.35), radius: lineW * 1.3)
            }
            centerLabel
        }
        .frame(width: size, height: size)
    }

    @ViewBuilder private var animatedOrb: some View {
        let lineW = size * 0.028
        let c1 = colors[min(1, colors.count - 1)]
        let c2 = colors[min(2, colors.count - 1)]

        TimelineView(.animation) { tl in
            let t = tl.date.timeIntervalSinceReferenceDate
            let angle = t * 58                        // 恒定转速——沉稳精确，不再忽快忽慢
            let breathe = 0.5 + 0.5 * sin(t * 0.85)   // 仅驱动柔光呼吸；彗尾弧长恒定，不再「变长变端」

            ZStack {
                // 呼吸柔光底（低幅、克制，纵深而不喧哗）
                Circle()
                    .fill(RadialGradient(colors: [c1.opacity(0.10 + 0.05 * breathe), .clear],
                                         center: .center, startRadius: size * 0.08, endRadius: size * 0.50))
                    .blur(radius: 30)
                    .scaleEffect(0.95 + 0.05 * breathe)

                // 轨道底环
                Circle().stroke(XColor.surfaceAlt.opacity(0.30), lineWidth: lineW)

                // 幽灵满环：整圈透出一丝品牌色，环「活着」但极克制
                Circle().stroke(c1.opacity(0.09), lineWidth: lineW)

                // 诚实进度弧（有确定性 progress 时才画）
                progressArc(lineWidth: lineW)

                // 内圈反向细弧：极淡的第二层运动，给环纵深感（精致但不喧哗）
                Circle()
                    .trim(from: 0.01, to: 0.30)
                    .stroke(c1.opacity(0.16), style: StrokeStyle(lineWidth: lineW * 0.5, lineCap: .round))
                    .padding(lineW * 2.6)
                    .rotationEffect(.degrees(-angle * 0.6 - 90))

                // 主彗星：恒定弧长 0.72，尾透明 → 头最亮，柔和同色辉光；
                // 头即渐变最亮端，与弧体连为一体——无分离白点、无塑料感。
                // trim 从 0.01 起：配合渐变尾端归零，双保险杜绝尾帽回绕亮点。
                Circle()
                    .trim(from: 0.01, to: 0.72)
                    .stroke(AngularGradient(gradient: cometGradient, center: .center),
                            style: StrokeStyle(lineWidth: lineW, lineCap: .round))
                    .rotationEffect(.degrees(angle - 90))
                    .shadow(color: c2.opacity(0.40 + 0.12 * breathe), radius: lineW * 1.6)

                centerLabel
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
    /// 可选的上下文标签（如文件名/分组名）——让 VoiceOver 念出「<该项> · 已选中」而非泛泛的「勾选」。
    let a11yLabel: String?
    let toggle: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(isOn: Bool, colors: [Color] = XColor.brandGradientColors,
                accessibilityLabel: String? = nil, toggle: @escaping () -> Void) {
        self.isOn = isOn
        self.colors = colors
        self.a11yLabel = accessibilityLabel
        self.toggle = toggle
    }

    /// 部分选中（树形父目录下只勾了部分子项）——渲染横线而非对勾（P7：文件树刚需三态）。
    public var mixed: Bool = false

    public var body: some View {
        // 用 Button 实现：自动获得键盘可达（Tab 聚焦 + 空格/回车触发）与无障碍 trait
        Button(action: toggle) {
            ZStack {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder((isOn || mixed) ? Color.clear : XColor.textTertiary.opacity(0.6), lineWidth: 1.5)
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing))
                    .opacity((isOn || mixed) ? 1 : 0)
                    .scaleEffect((isOn || mixed) ? 1 : 0.6)
                if isOn {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .heavy))
                        .foregroundStyle(.white)
                        .transition(.scale.combined(with: .opacity))
                } else if mixed {
                    Image(systemName: "minus")
                        .font(.system(size: 10, weight: .heavy))
                        .foregroundStyle(.white)
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .frame(width: 19, height: 19)
            .animation(reduceMotion ? nil : XMotion.snappy, value: isOn)
            .animation(reduceMotion ? nil : XMotion.snappy, value: mixed)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(a11yLabel ?? xLoc("勾选"))
        .accessibilityValue(isOn ? xLoc("已选中") : (mixed ? xLoc("部分选中") : xLoc("未选中")))
        .accessibilityAddTraits(isOn ? [.isButton, .isSelected] : .isButton)
    }
}

public extension XCheckbox {
    /// 三态便捷构造：isOn=nil 表示「部分选中」。
    init(triState: Bool?, colors: [Color] = XColor.brandGradientColors,
         accessibilityLabel: String? = nil, toggle: @escaping () -> Void) {
        self.init(isOn: triState == true, colors: colors, accessibilityLabel: accessibilityLabel, toggle: toggle)
        self.mixed = (triState == nil)
    }
}

// MARK: - 完成庆祝粒子爆发

public struct XCelebrationBurst: View {
    let colors: [Color]
    @State private var start = Date()
    /// 粒子 1.4s 后透明度已归零——到点即停 TimelineView 驱动（能耗铁律：动画必须停表，
    /// 此前完成页常驻时 .animation 时间线仍满帧率空转，稳态 GPU 白耗）。
    @State private var finished = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    public init(colors: [Color] = [XColor.success, XColor.accentTeal, XColor.brand]) {
        self.colors = colors.isEmpty ? [XColor.brand] : colors
    }
    public var body: some View {
        // Reduce Motion 下跳过粒子爆发（完成页另有静态对勾）；播完自停 → 稳态零帧。
        if reduceMotion || finished {
            Color.clear.allowsHitTesting(false)
        } else {
            burst
                .task {
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    finished = true
                }
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

// MARK: - 实时脉冲点（LIVE 指示）

/// 会呼吸的「实时」小圆点：实心点 + 向外扩散淡出的圆环。用在监视器/硬件页头部，
/// 让「LIVE」不再是一颗死气沉沉的静态圆点。Reduce Motion 下退化为静态点。
public struct XLiveDot: View {
    var color: Color
    var size: CGFloat
    @State private var pulse = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    public init(color: Color = XColor.success, size: CGFloat = 7) {
        self.color = color
        self.size = size
    }
    public var body: some View {
        ZStack {
            if !reduceMotion {
                Circle().stroke(color, lineWidth: 1.5)
                    .frame(width: size, height: size)
                    .scaleEffect(pulse ? 2.6 : 1)
                    .opacity(pulse ? 0 : 0.55)
            }
            Circle().fill(color).frame(width: size, height: size)
                .shadow(color: color.opacity(0.7), radius: 3)
        }
        .frame(width: size, height: size)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeOut(duration: 1.6).repeatForever(autoreverses: false)) { pulse = true }
        }
        .accessibilityHidden(true)
    }
}

// MARK: - 悬停抬升修饰

/// 全应用**唯一**的卡片悬停物理（P7 收编）：上浮 + 阴影升至 XElevation.raised 档
/// （radius 20 / y 10 / 0.12——与静置卡片的 z 轴阶梯同一套参数，不再自带私有影）。
public struct HoverLift: ViewModifier {
    @State private var hover = false
    let amount: CGFloat
    public init(amount: CGFloat = 3) { self.amount = amount }
    public func body(content: Content) -> some View {
        content
            .offset(y: hover ? -amount : 0)
            .shadow(color: .black.opacity(hover ? 0.12 : 0), radius: hover ? 20 : 0, y: hover ? 10 : 0)
            .animation(XMotion.snappy, value: hover)
            .onHover { hover = $0 }
    }
}

public extension View {
    func hoverLift(_ amount: CGFloat = 3) -> some View { modifier(HoverLift(amount: amount)) }
}
