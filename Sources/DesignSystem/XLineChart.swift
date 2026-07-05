import SwiftUI

/// 可动画的向量：让折线在数据流入时**平滑滑动**（而非每秒硬切一帧）。
/// 长度变化（历史填充到上限前）时按较短长度插值，达上限后长度恒定即完全平滑。
struct AnimatableVector: VectorArithmetic {
    var values: [Double]
    init(_ values: [Double] = []) { self.values = values }
    static var zero: AnimatableVector { AnimatableVector([]) }
    static func + (l: AnimatableVector, r: AnimatableVector) -> AnimatableVector { op(l, r, +) }
    static func - (l: AnimatableVector, r: AnimatableVector) -> AnimatableVector { op(l, r, -) }
    private static func op(_ l: AnimatableVector, _ r: AnimatableVector, _ f: (Double, Double) -> Double) -> AnimatableVector {
        let n = max(l.values.count, r.values.count)
        return AnimatableVector((0..<n).map { i in
            f(i < l.values.count ? l.values[i] : 0, i < r.values.count ? r.values[i] : 0)
        })
    }
    mutating func scale(by rhs: Double) { values = values.map { $0 * rhs } }
    var magnitudeSquared: Double { values.reduce(0) { $0 + $1 * $1 } }
}

/// 高级平滑折线图：Catmull-Rom 平滑曲线 + 渐变区域填充 + 辉光描边 + 端点光点。
/// values 需归一化到 0...1。可选网格基线（tall 图开）与悬停读数（对标 iStat 的可擦洗图表）。
public struct XLineChart: View {
    let values: [Double]
    let colors: [Color]
    let showFill: Bool
    let showDot: Bool
    let showGrid: Bool
    let lineWidth: CGFloat
    /// 悬停时把索引映射为读数文字（如 "62% · 12:04"）。为 nil 则不显示悬停读数。
    let hoverLabel: ((Int) -> String)?
    @State private var hoverFraction: CGFloat? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(values: [Double], colors: [Color] = XColor.brandGradientColors,
                showFill: Bool = true, showDot: Bool = true, showGrid: Bool = false,
                lineWidth: CGFloat = 2, hoverLabel: ((Int) -> String)? = nil) {
        self.values = values
        self.colors = colors.isEmpty ? XColor.brandGradientColors : colors
        self.showFill = showFill
        self.showDot = showDot
        self.showGrid = showGrid
        self.lineWidth = lineWidth
        self.hoverLabel = hoverLabel
    }

    public var body: some View {
        GeometryReader { geo in
            let vec = AnimatableVector(values)
            ZStack {
                if showGrid { grid(geo.size) }

                if showFill {
                    StreamLine(vector: vec, closed: true)
                        .fill(LinearGradient(colors: [(colors.last ?? XColor.brand).opacity(0.30),
                                                      (colors.last ?? XColor.brand).opacity(0.02)],
                                             startPoint: .top, endPoint: .bottom))
                }
                StreamLine(vector: vec, closed: false)
                    .stroke(LinearGradient(colors: colors, startPoint: .leading, endPoint: .trailing),
                            style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
                    .shadow(color: (colors.last ?? XColor.brand).opacity(0.5), radius: 4, y: 1)

                if showDot, let last = points(geo.size).last {
                    Circle().fill(.white).frame(width: lineWidth * 3, height: lineWidth * 3)
                        .shadow(color: (colors.last ?? XColor.brand).opacity(0.9), radius: 4)
                        .position(last)
                        .animation(reduceMotion ? nil : .linear(duration: 0.95), value: values)
                }

                if let hf = hoverFraction { hoverOverlay(geo.size, fraction: hf) }
            }
            // 数据流入时整条线平滑滑动（对标 iStat 的实时流动感），而非每帧硬跳。
            .animation(reduceMotion ? nil : .linear(duration: 0.95), value: values)
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                guard hoverLabel != nil, geo.size.width > 0 else { hoverFraction = nil; return }
                switch phase {
                case .active(let p): hoverFraction = min(max(p.x / geo.size.width, 0), 1)
                case .ended:         hoverFraction = nil
                }
            }
        }
    }

    // MARK: 网格基线（3 条 25/50/75% 参考线 + 底线），让「20% 还是 60%」一眼可判。
    private func grid(_ size: CGSize) -> some View {
        ZStack {
            ForEach([0.25, 0.5, 0.75], id: \.self) { f in
                Rectangle().fill(XColor.hairline.opacity(0.6))
                    .frame(height: 1)
                    .position(x: size.width / 2, y: size.height * (1 - f))
            }
            Rectangle().fill(XColor.border)
                .frame(height: 1)
                .position(x: size.width / 2, y: size.height - 0.5)
        }
    }

    // MARK: 悬停读数（竖直准星 + 就近采样点高亮 + 浮动数值胶囊）
    @ViewBuilder private func hoverOverlay(_ size: CGSize, fraction: CGFloat) -> some View {
        let pts = points(size)
        if pts.count > 1 {
            let idx = min(max(Int((fraction * CGFloat(pts.count - 1)).rounded()), 0), pts.count - 1)
            let p = pts[idx]
            ZStack {
                Rectangle().fill(XColor.textTertiary.opacity(0.5))
                    .frame(width: 1).frame(maxHeight: .infinity)
                    .position(x: p.x, y: size.height / 2)
                Circle().fill(colors.last ?? XColor.brand)
                    .frame(width: lineWidth * 3.4, height: lineWidth * 3.4)
                    .overlay(Circle().strokeBorder(.white, lineWidth: 1.5))
                    .position(p)
                if let label = hoverLabel?(idx) {
                    Text(label)
                        .font(XFont.captionMono).foregroundStyle(XColor.textPrimary)
                        .padding(.horizontal, XSpacing.s).padding(.vertical, 3)
                        .background(.ultraThinMaterial, in: Capsule())
                        .overlay(Capsule().strokeBorder(XColor.border, lineWidth: 1))
                        .fixedSize()
                        .position(x: min(max(p.x, 42), size.width - 42), y: max(12, p.y - 20))
                }
            }
        }
    }

    private func points(_ size: CGSize) -> [CGPoint] {
        StreamLine.points(values, size: size)
    }
}

/// 可动画的平滑折线 Shape：animatableData 为归一化数值向量，随数据流入平滑插值。
private struct StreamLine: Shape {
    var vector: AnimatableVector
    var closed: Bool
    var animatableData: AnimatableVector {
        get { vector }
        set { vector = newValue }
    }
    func path(in rect: CGRect) -> Path {
        let pts = StreamLine.points(vector.values, size: rect.size)
        var path = Path()
        guard pts.count > 1 else { return path }
        if closed {
            path.move(to: CGPoint(x: pts[0].x, y: rect.height)); path.addLine(to: pts[0])
        } else {
            path.move(to: pts[0])
        }
        for i in 0..<pts.count - 1 {
            let p0 = pts[max(i - 1, 0)], p1 = pts[i], p2 = pts[i + 1], p3 = pts[min(i + 2, pts.count - 1)]
            let c1 = CGPoint(x: p1.x + (p2.x - p0.x) / 6, y: p1.y + (p2.y - p0.y) / 6)
            let c2 = CGPoint(x: p2.x - (p3.x - p1.x) / 6, y: p2.y - (p3.y - p1.y) / 6)
            path.addCurve(to: p2, control1: c1, control2: c2)
        }
        if closed, let last = pts.last {
            path.addLine(to: CGPoint(x: last.x, y: rect.height)); path.closeSubpath()
        }
        return path
    }
    static func points(_ values: [Double], size: CGSize) -> [CGPoint] {
        guard values.count > 1, size.width > 0 else { return [] }
        let n = values.count
        return values.enumerated().map { i, v in
            let x = size.width * CGFloat(i) / CGFloat(n - 1)
            let clamped = min(max(v, 0), 1)
            let y = size.height * (1 - CGFloat(clamped)) * 0.92 + size.height * 0.04
            return CGPoint(x: x, y: y)
        }
    }
}
