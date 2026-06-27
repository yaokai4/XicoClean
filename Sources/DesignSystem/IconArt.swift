import SwiftUI

/// 四角星「闪耀」标志形状（凹边，优雅）
public struct SparkleShape: Shape {
    public init() {}
    public func path(in rect: CGRect) -> Path {
        let c = CGPoint(x: rect.midX, y: rect.midY)
        let R = min(rect.width, rect.height) / 2
        let r = R * 0.16
        func pt(_ deg: Double, _ rad: CGFloat) -> CGPoint {
            let a = deg * .pi / 180
            return CGPoint(x: c.x + cos(a) * rad, y: c.y + sin(a) * rad)
        }
        let outer: [Double] = [-90, 0, 90, 180]
        let inner: [Double] = [-45, 45, 135, 225]
        var p = Path()
        p.move(to: pt(outer[0], R))
        for i in 0..<4 {
            p.addQuadCurve(to: pt(outer[(i + 1) % 4], R), control: pt(inner[i], r))
        }
        p.closeSubpath()
        return p
    }
}

/// 品牌标志（用于 App 内品牌位 + 生成 App 图标）
public struct XBrandMark: View {
    let size: CGFloat
    public init(size: CGFloat = 30) { self.size = size }
    public var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
                .fill(LinearGradient(colors: [Color(nsColor: NSColor(hex: 0x3D8BFF)),
                                              Color(nsColor: NSColor(hex: 0x8E6CFF)),
                                              Color(nsColor: NSColor(hex: 0xE83C8C))],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
            SparkleShape().fill(.white)
                .frame(width: size * 0.5, height: size * 0.5)
        }
        .frame(width: size, height: size)
    }
}

/// 1024×1024 App 图标（macOS 原生规格：居中圆角砖 + 留白 + 投影）
public struct XAppIcon: View {
    public init() {}
    public var body: some View {
        let s: CGFloat = 1024
        let inset: CGFloat = 100               // macOS 标准留白
        let tile = s - inset * 2               // 824 圆角砖
        let radius = tile * 0.2237             // 连续圆角
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)

        return ZStack {
            ZStack {
                // 富有层次的极光底色
                shape.fill(LinearGradient(
                    colors: [Color(nsColor: NSColor(hex: 0x5A86F5)),
                             Color(nsColor: NSColor(hex: 0x8E62F0)),
                             Color(nsColor: NSColor(hex: 0xE85FA8))],
                    startPoint: .topLeading, endPoint: .bottomTrailing))
                // 左上高光（玻璃质感光源）
                shape.fill(RadialGradient(colors: [.white.opacity(0.38), .clear],
                                          center: UnitPoint(x: 0.28, y: 0.16),
                                          startRadius: 0, endRadius: tile * 0.78))
                // 底部暗角，增加体积感
                shape.fill(RadialGradient(colors: [.clear, .black.opacity(0.18)],
                                          center: UnitPoint(x: 0.5, y: 1.05),
                                          startRadius: tile * 0.2, endRadius: tile * 0.9))

                // 优雅光弧（取代旧的细轨道环，作为「焕新」意象）
                Circle()
                    .trim(from: 0.07, to: 0.45)
                    .stroke(LinearGradient(colors: [.white.opacity(0.0), .white.opacity(0.55)],
                                           startPoint: .leading, endPoint: .trailing),
                            style: StrokeStyle(lineWidth: tile * 0.018, lineCap: .round))
                    .frame(width: tile * 0.82, height: tile * 0.82)
                    .rotationEffect(.degrees(8))

                // 主星：高对比、清晰，带分离投影 + 柔光
                SparkleShape()
                    .fill(LinearGradient(colors: [.white, Color(nsColor: NSColor(hex: 0xF0ECFF))],
                                         startPoint: .top, endPoint: .bottom))
                    .frame(width: tile * 0.5, height: tile * 0.5)
                    .shadow(color: .black.opacity(0.16), radius: tile * 0.035, x: 0, y: tile * 0.012)
                    .shadow(color: .white.opacity(0.55), radius: tile * 0.05)

                // 副星
                SparkleShape().fill(.white)
                    .frame(width: tile * 0.155, height: tile * 0.155)
                    .offset(x: tile * 0.215, y: -tile * 0.2)
                    .shadow(color: .white.opacity(0.6), radius: tile * 0.02)

                // 顶部内描边高光
                shape.strokeBorder(.white.opacity(0.18), lineWidth: 2)
            }
            .frame(width: tile, height: tile)
            .shadow(color: .black.opacity(0.22), radius: 26, x: 0, y: 16)
        }
        .frame(width: s, height: s)
    }
}
