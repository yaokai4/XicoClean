import SwiftUI
import AppKit

// MARK: - 微粒纹理（docs/16 P0：塑料感的本质是「过于干净的数字平滑」——1–3% 微粒把渲染图变实物）

/// 全应用统一的胶片微粒层。
///
/// 工艺（比方案的 Canvas 随机点更稳）：噪点**只生成一次**——静态种子瓦片（256px 图元 @2x），
/// `Image(resizingMode: .tile)` 平铺。Canvas 逐帧随机会在每次 body 重算时「换一张噪点」造成
/// 肉眼可见的闪烁蠕动；静态瓦片零重算、零闪烁、滚动零成本。
/// `.overlay` 混合只扰动明度不改色相；顺手消灭暗色渐变 banding。
public struct XGrain: View {
    /// 每像素低幅白噪声瓦片（一次生成，进程内缓存）。128pt 逻辑尺寸 @2x 像素密度，视网膜屏下细腻。
    private static let tile: NSImage = {
        let pixels = 256
        let image = NSImage(size: NSSize(width: 128, height: 128))
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                         bitsPerSample: 8, samplesPerPixel: 2, hasAlpha: true,
                                         isPlanar: false, colorSpaceName: .deviceWhite,
                                         bytesPerRow: 0, bitsPerPixel: 0),
              let data = rep.bitmapData else { return image }
        var seed: UInt64 = 0x9E3779B97F4A7C15   // 固定种子：每次启动同一张纹理，观感稳定
        for i in 0..<(pixels * pixels) {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407   // LCG，无需引 GameplayKit
            data[i * 2] = 255                                            // 白
            data[i * 2 + 1] = UInt8(seed >> 58)                          // alpha 0–63（≈0–25%，容器再降）
        }
        image.addRepresentation(rep)
        return image
    }()

    public init() {}
    public var body: some View {
        Image(nsImage: Self.tile)
            .resizable(resizingMode: .tile)
            .blendMode(.overlay)        // 只扰明度不改色相
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

public extension View {
    /// 给大面积实色/渐变叠一层微粒（图标块、按钮胶囊、染色圆等）。
    func xGrain(_ opacity: Double = 0.35) -> some View {
        overlay(XGrain().opacity(opacity))
    }
}

// MARK: - 应用背景（Mesh 极光 + 微粒；macOS 14 降级径向辉光；默认静态省电）

public struct AppBackground: View {
    /// true = 活极光（hero 屏专用：Onboarding / 扫描完成页）——中心控制点极慢微漂。
    /// 默认 false：全 app 常规背景保持静态（能耗铁律：稳态零重绘）。
    private let animated: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    public init(animated: Bool = false) { self.animated = animated }

    public var body: some View {
        ZStack {
            LinearGradient(colors: [XColor.canvasTop, XColor.canvasBottom],
                           startPoint: .top, endPoint: .bottom)
            // 降低透明度（docs/16 红线）：用户明确要实底时，mesh 极光整层退场，
            // 只留纯色画布 + 微粒（grain 不涉透明语义，保留哑光质感）。
            if !reduceTransparency {
                // 背景以中性画布为主，仅留一丝色彩做纵深——克制、高级、真实，
                // 而非四角满屏彩虹「概念稿」水洗感。彩色留给数据本身（环、图、图标）。
                // 色相取当前主题色阶（切主题→背景一起换色，G1 渐变背景统一）。
                aurora
            }
            // 微粒收尾（docs/16 P0）：把「渲染图般干净」推到「实物般哑光」，顺手消 banding。
            XGrain().opacity(0.5)
        }
        .ignoresSafeArea()
    }

    /// 品牌氤氲：macOS 15+ 用 MeshGradient（3×3 网格、感知空间插值、大模糊）——
    /// 从「两颗可辨识的光斑」升级为「整屏若有若无的场」，且天然比径向渐变少 banding；
    /// macOS 14 降级为原双径向辉光。
    @ViewBuilder private var aurora: some View {
        if #available(macOS 15.0, *) {
            if animated && !reduceMotion {
                TimelineView(.animation(minimumInterval: 1.0 / 20)) { tl in
                    mesh(at: tl.date.timeIntervalSinceReferenceDate)
                }
            } else {
                mesh(at: 0)
            }
        } else {
            glow(XColor.ring(2), center: UnitPoint(x: 0.90, y: 0.02), r: 720, o: 0.07)
            glow(XColor.ring(0), center: UnitPoint(x: 0.04, y: 0.98), r: 680, o: 0.06)
        }
    }

    /// 四角锁死、只微漂中心控制点（±0.06）——缓慢有机才高级，整片乱涌是廉价屏保。
    @available(macOS 15.0, *)
    private func mesh(at t: TimeInterval) -> some View {
        let dx = Float(0.06 * sin(t * 0.30))
        let dy = Float(0.06 * cos(t * 0.23))
        return MeshGradient(
            width: 3, height: 3,
            points: [
                [0, 0], [0.5, 0], [1, 0],
                [0, 0.5], [0.5 + dx, 0.5 + dy], [1, 0.5],
                [0, 1], [0.5, 1], [1, 1],
            ],
            colors: [
                .clear, XColor.ring(2).opacity(0.10), .clear,
                .clear, XColor.ring(1).opacity(0.07), .clear,
                XColor.ring(0).opacity(0.08), .clear, .clear,
            ],
            colorSpace: .perceptual)   // 感知插值：暗色中段不发灰不发脏
        .blur(radius: 40)              // mesh 硬边必须糊掉
        .allowsHitTesting(false)
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
    let a11yLabel: String?
    let center: Center
    @State private var spin = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme

    public init(progress: Double, spinning: Bool = false,
                colors: [Color] = XColor.brandGradientColors,
                lineWidth: CGFloat = 22, size: CGFloat = 280, a11yLabel: String? = nil,
                @ViewBuilder center: () -> Center) {
        self.progress = progress
        self.spinning = spinning
        self.colors = colors.isEmpty ? XColor.brandGradientColors : colors
        self.lineWidth = lineWidth
        self.size = size
        self.a11yLabel = a11yLabel
        self.center = center()
    }

    public var body: some View {
        ZStack {
            Circle()
                .stroke(XColor.surfaceAlt, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))

            // 幽灵渐变环：未填充处也透出一丝品牌色，更通透高级。
            // 浅色底上 ghost 档几乎不可见，按配色方案给到 dim 档保住轨道轮廓。
            Circle()
                .stroke(AngularGradient(colors: colors + [colors.first!], center: .center),
                        style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .opacity(colorScheme == .light ? XAlpha.dim : XAlpha.ghost)

            Circle()
                .fill(RadialGradient(colors: [colors.first!.opacity(XAlpha.tint), .clear],
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
                    .animation(reduceMotion ? nil : XMotion.gauge, value: progress)
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
        .accessibilityLabel(a11yLabel ?? "")
        .accessibilityValue("\(Int((max(0, min(progress, 1)) * 100).rounded()))%")
        .onAppear { restartSpin() }
        .onChange(of: spinning) { restartSpin() }
    }

    private func restartSpin() {
        // 显式事务复位：repeatForever 不会被普通赋值可靠取消，反复开关会叠加动画（P4 复核）。
        // 先在禁动画事务里归零，再于下一个 runloop 重新起转，确保复位与新动画不合并。
        var t = Transaction()
        t.disablesAnimations = true
        withTransaction(t) { spin = false }
        guard spinning, !reduceMotion else { return }   // Reduce Motion 下不做无限旋转
        DispatchQueue.main.async {
            guard spinning else { return }
            withAnimation(.linear(duration: 1.1).repeatForever(autoreverses: false)) { spin = true }
        }
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
                .animation(XMotion.gauge, value: fraction)
            center
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)   // 装饰性：信息由相邻文字承载
    }
}

// MARK: - 品牌加载转圈（统一「加载中」语言）

/// 替代散落各处的系统 `ProgressView()` 灰色菊花——小号品牌渐变环，边扫描边旋转。
/// Reduce Motion 由底层 XRingGauge 处理（不做无限旋转）。让每一处「检查中/加载中/处理中」
/// 都说同一种话，去掉「系统原生控件嵌在高级卡片里」的拼接感。
public struct XSpinner: View {
    let size: CGFloat
    let lineWidth: CGFloat
    public init(size: CGFloat = 16, lineWidth: CGFloat = 2.5) {
        self.size = size
        self.lineWidth = lineWidth
    }
    public var body: some View {
        XRingGauge(progress: 0, spinning: true, colors: XColor.brandGradientColors,
                   lineWidth: lineWidth, size: size) { EmptyView() }
            .accessibilityLabel(xLoc("加载中"))
    }
}

// MARK: - 分段容量条（内存明细等）

/// 连续分段的容量胶囊（活动监视器式内存条）：各段依次自左排布，余量为轨道底色（= 空闲）。
/// 宽度随数据平滑过渡。用于内存明细（应用/联动/压缩/缓存）等需要「一条读懂构成」的场景。
public struct XSegmentBar: View {
    public struct Segment: Identifiable {
        /// 稳定身份（如组 id）——**绝不能用排名当 id**：数据重排时同一段会「变成另一个组」，
        /// 宽度/颜色瞬移，动画把跳变演成「到处飞」（2026-07 用户实测）。
        public let id: String
        public let fraction: Double
        public let color: Color
        public init(id: String, fraction: Double, color: Color) {
            self.id = id; self.fraction = fraction; self.color = color
        }
    }
    let segments: [Segment]
    let height: CGFloat
    let updateCadence: XMonitoringUpdateCadence
    public init(
        segments: [Segment],
        height: CGFloat = 10,
        updateCadence: XMonitoringUpdateCadence = .ambient
    ) {
        self.segments = segments
        self.height = height
        self.updateCadence = updateCadence
    }
    public var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            Capsule()
                .fill(XColor.surfaceAlt)
                .overlay(alignment: .leading) {
                    HStack(spacing: 0) {
                        ForEach(segments) { seg in
                            Rectangle().fill(seg.color)
                                .frame(width: max(0, w * min(max(seg.fraction, 0), 1)))
                        }
                    }
                    .animation(
                        updateCadence.animatesUpdates ? XMotion.settle : nil,
                        value: segments.map(\.fraction)
                    )
                }
                .clipShape(Capsule())
        }
        .frame(height: height)
    }
}

// MARK: - 图标方块

public struct XIconTile: View {
    let systemImage: String
    let colors: [Color]
    let size: CGFloat
    /// flat=true：扁平染色底 + 同色实心字形（克制，用于卡片头/列表——「渐变只留给主角」）。
    /// flat=false：品牌渐变底 + 白字 + 投影（用于 hero / 主操作）。
    /// 渐变预算铁律（docs/16 P0-6）：默认 flat——每屏渐变只留给唯一主角，
    /// hero 级调用点**显式**传 flat:false。克制才是奢侈。
    let flat: Bool
    public init(systemImage: String, colors: [Color] = XColor.brandGradientColors,
                size: CGFloat = 30, flat: Bool = true) {
        self.systemImage = systemImage
        self.colors = colors.isEmpty ? XColor.brandGradientColors : colors
        self.size = size
        self.flat = flat
    }
    public var body: some View {
        let shape = RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
        return Group {
            if flat {
                shape.fill((colors.first ?? XColor.brand).opacity(XAlpha.tint))
                    .frame(width: size, height: size)
                    .overlay(
                        Image(systemName: systemImage)
                            .font(.system(size: size * 0.5, weight: .semibold))
                            .foregroundStyle(colors.first ?? XColor.brand)
                    )
            } else {
                shape.fill(LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing))
                    .overlay(XGrain().opacity(0.35).clipShape(shape))   // 大面积渐变的微粒收尾（去塑料）
                    .frame(width: size, height: size)
                    .overlay(
                        Image(systemName: systemImage)
                            .font(.system(size: size * 0.5, weight: .medium))
                            .foregroundStyle(.white)
                    )
                    .shadow(color: colors.first!.opacity(0.35), radius: 6, y: 3)
            }
        }
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
            VStack(alignment: .leading, spacing: XSpacing.xs) {
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
