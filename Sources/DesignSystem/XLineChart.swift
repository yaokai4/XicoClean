import SwiftUI

/// 高级平滑折线图：Catmull-Rom 平滑曲线 + 渐变区域填充 + 辉光描边 + 端点光点。
/// values 需归一化到 0...1。
public struct XLineChart: View {
    let values: [Double]
    let colors: [Color]
    let showFill: Bool
    let showDot: Bool
    let lineWidth: CGFloat

    public init(values: [Double], colors: [Color] = XColor.brandGradientColors,
                showFill: Bool = true, showDot: Bool = true, lineWidth: CGFloat = 2) {
        self.values = values
        self.colors = colors.isEmpty ? XColor.brandGradientColors : colors
        self.showFill = showFill
        self.showDot = showDot
        self.lineWidth = lineWidth
    }

    public var body: some View {
        GeometryReader { geo in
            let pts = points(geo.size)
            ZStack {
                if showFill, pts.count > 1 {
                    smoothPath(pts, closed: true, height: geo.size.height)
                        .fill(LinearGradient(colors: [(colors.last ?? XColor.brand).opacity(0.30),
                                                      (colors.last ?? XColor.brand).opacity(0.02)],
                                             startPoint: .top, endPoint: .bottom))
                }
                if pts.count > 1 {
                    smoothPath(pts, closed: false, height: geo.size.height)
                        .stroke(LinearGradient(colors: colors, startPoint: .leading, endPoint: .trailing),
                                style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
                        .shadow(color: (colors.last ?? XColor.brand).opacity(0.5), radius: 4, y: 1)
                }
                if showDot, let last = pts.last {
                    Circle().fill(.white).frame(width: lineWidth * 3, height: lineWidth * 3)
                        .shadow(color: (colors.last ?? XColor.brand).opacity(0.9), radius: 4)
                        .position(last)
                }
            }
        }
    }

    private func points(_ size: CGSize) -> [CGPoint] {
        guard values.count > 1, size.width > 0 else { return [] }
        let n = values.count
        return values.enumerated().map { i, v in
            let x = size.width * CGFloat(i) / CGFloat(n - 1)
            let clamped = min(max(v, 0), 1)
            let y = size.height * (1 - CGFloat(clamped)) * 0.92 + size.height * 0.04 // 上下留一点边距
            return CGPoint(x: x, y: y)
        }
    }

    private func smoothPath(_ pts: [CGPoint], closed: Bool, height: CGFloat) -> Path {
        var path = Path()
        guard pts.count > 1 else { return path }
        if closed {
            path.move(to: CGPoint(x: pts[0].x, y: height))
            path.addLine(to: pts[0])
        } else {
            path.move(to: pts[0])
        }
        for i in 0..<pts.count - 1 {
            let p0 = pts[max(i - 1, 0)]
            let p1 = pts[i]
            let p2 = pts[i + 1]
            let p3 = pts[min(i + 2, pts.count - 1)]
            let c1 = CGPoint(x: p1.x + (p2.x - p0.x) / 6, y: p1.y + (p2.y - p0.y) / 6)
            let c2 = CGPoint(x: p2.x - (p3.x - p1.x) / 6, y: p2.y - (p3.y - p1.y) / 6)
            path.addCurve(to: p2, control1: c1, control2: c2)
        }
        if closed, let last = pts.last {
            path.addLine(to: CGPoint(x: last.x, y: height))
            path.closeSubpath()
        }
        return path
    }
}
