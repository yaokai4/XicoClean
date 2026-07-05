import SwiftUI

// MARK: - 品牌标志形状

/// 四角星「闪耀」标志形状（凹边，优雅）。inner 控制凹陷深度：越小越尖锐、越「宝石」。
/// outerOffset 旋转四个尖角：0 → 上下左右「＋」朝向（经典火花）；45 → 四角朝向（读作「✕/X」）。
public struct SparkleShape: Shape {
    var inner: CGFloat
    var outerOffset: Double
    public init(inner: CGFloat = 0.14, outerOffset: Double = 0) {
        self.inner = inner
        self.outerOffset = outerOffset
    }
    public func path(in rect: CGRect) -> Path {
        let c = CGPoint(x: rect.midX, y: rect.midY)
        let R = min(rect.width, rect.height) / 2
        let r = R * inner
        func pt(_ deg: Double, _ rad: CGFloat) -> CGPoint {
            let a = deg * .pi / 180
            return CGPoint(x: c.x + cos(a) * rad, y: c.y + sin(a) * rad)
        }
        let outer: [Double] = [-90, 0, 90, 180].map { $0 + outerOffset }
        let inner: [Double] = [-45, 45, 135, 225].map { $0 + outerOffset }
        var p = Path()
        p.move(to: pt(outer[0], R))
        for i in 0..<4 {
            p.addQuadCurve(to: pt(outer[(i + 1) % 4], R), control: pt(inner[i], r))
        }
        p.closeSubpath()
        return p
    }
}

/// 「X」标志形状（Xico 的字首）：四片朝四角的锥形刃 + 一枚菱形芯，
/// 兼具「✕ 字母」与「闪耀/焕新」双重意象。waist 控制刃腰宽（越大越粗壮、小尺寸越稳）。
public struct XMarkShape: Shape {
    var waist: CGFloat
    public init(waist: CGFloat = 0.15) { self.waist = waist }
    public func path(in rect: CGRect) -> Path {
        // 四角凹边星，尖角朝四个角落 → 轮廓即「✕」。waist 较大 → 刃腰粗、16px 也立得住。
        SparkleShape(inner: waist, outerOffset: 45).path(in: rect)
    }
}

// MARK: - 品牌配色（唯一事实来源，图标与 App 内品牌位共用）

enum XBrand {
    /// 品牌极光渐变（与 App 内 XColor 同源、已调过的珠宝色相；去掉旧版糖果热品红）：
    /// 极光蓝 → 紫罗兰 → 兰花玫瑰。图标为固定资产，用亮色档以保持外观无关的鲜活。
    static let c1 = Color(nsColor: NSColor(hex: 0x5478F0))   // auroraBlue（左上）
    static let c2 = Color(nsColor: NSColor(hex: 0x8B6FE6))   // auroraViolet（中）
    static let c3 = Color(nsColor: NSColor(hex: 0xCB6FC9))   // 兰花玫瑰（右下，比热品红更沉）
    static let tileGradient = LinearGradient(colors: [c1, c2, c3],
                                             startPoint: .topLeading, endPoint: .bottomTrailing)
    /// 火花的宝石本体：微微带薰衣草色（非纯白），这样纯白高光才能「打」出来、有立体感。
    static let sparkFill = LinearGradient(colors: [Color(nsColor: NSColor(hex: 0xF3F0FE)),
                                                   Color(nsColor: NSColor(hex: 0xCBBBEE))],
                                          startPoint: .topLeading, endPoint: .bottomTrailing)
}

// MARK: - 可复用的「宝石火花」

/// 有切面立体感的宝石标志（可传入任意形状：X 主标志 / 小火花点缀）。
/// 单一光源、右下暗面、左上高光边、柔和白晕。facets=false 时退化为干净单色填充
/// （小尺寸点缀用，避免噪点）。
struct FacetedSpark<S: Shape>: View {
    var shape: S
    var size: CGFloat
    var facets: Bool = true
    var body: some View {
        ZStack {
            // 基础：珠宝白，左上亮右下淡薰衣草
            shape.fill(XBrand.sparkFill)
            if facets {
                // 切面「远面」：干净的两段过渡（清晰切割感，而非灰蒙一片）
                shape.fill(LinearGradient(stops: [
                    .init(color: .clear, location: 0.0),
                    .init(color: .clear, location: 0.52),
                    .init(color: Color(nsColor: NSColor(hex: 0xCBB6F0)).opacity(0.55), location: 1.0),
                ], startPoint: .topLeading, endPoint: .bottomTrailing))
                // 左上镜面高光（纯白亮斑，打在薰衣草宝石体上会清晰「发亮」）
                Ellipse()
                    .fill(RadialGradient(colors: [.white, .white.opacity(0)],
                                         center: .center, startRadius: 0, endRadius: size * 0.13))
                    .frame(width: size * 0.30, height: size * 0.36)
                    .offset(x: -size * 0.11, y: -size * 0.13)
                // 左上高光边
                shape.stroke(LinearGradient(colors: [.white.opacity(0.95), .clear],
                                            startPoint: .topLeading, endPoint: .center),
                             lineWidth: max(0.5, size * 0.012))
            }
        }
        .frame(width: size, height: size)
    }
}

// MARK: - App 内品牌位（侧边栏 / 菜单栏，小尺寸，干净可缩放）

public struct XBrandMark: View {
    let size: CGFloat
    public init(size: CGFloat = 30) { self.size = size }
    public var body: some View {
        let tile = RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
        ZStack {
            tile.fill(XBrand.tileGradient)
            // 左上柔光，给小图标一点体积
            tile.fill(RadialGradient(colors: [.white.opacity(0.28), .clear],
                                     center: UnitPoint(x: 0.28, y: 0.2),
                                     startRadius: 0, endRadius: size * 0.7))
            tile.strokeBorder(.white.opacity(0.16), lineWidth: max(0.5, size * 0.03))
            FacetedSpark(shape: XMarkShape(), size: size * 0.56, facets: size >= 26)
                .shadow(color: XBrand.c2.opacity(0.35), radius: size * 0.04, y: size * 0.02)
        }
        .frame(width: size, height: size)
    }
}

// MARK: - 1024×1024 App 图标（macOS 原生规格：居中圆角砖 + 留白 + 投影）

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
                // 珠宝级极光底色
                shape.fill(XBrand.tileGradient)
                // 左上高光（玻璃质感光源）
                shape.fill(RadialGradient(colors: [.white.opacity(0.40), .clear],
                                          center: UnitPoint(x: 0.27, y: 0.15),
                                          startRadius: 0, endRadius: tile * 0.82))
                // 右上极光冷调余晖（多色相极光，更高级，去单调紫）
                shape.fill(RadialGradient(colors: [Color(nsColor: NSColor(hex: 0x38D6E0)).opacity(0.30), .clear],
                                          center: UnitPoint(x: 0.9, y: 0.08),
                                          startRadius: 0, endRadius: tile * 0.6))
                // 对角光泽扫掠带（极淡，玻璃反光）
                shape.fill(LinearGradient(colors: [.white.opacity(0.14), .clear, .clear],
                                          startPoint: .topLeading, endPoint: .center))
                // 右下暗角，增加体积感
                shape.fill(RadialGradient(colors: [.clear, .black.opacity(0.22)],
                                          center: UnitPoint(x: 0.62, y: 1.05),
                                          startRadius: tile * 0.2, endRadius: tile * 0.95))

                // 主标志：切面「X」宝石（Xico 字首 + 焕新意象），带分离投影 + 白晕
                FacetedSpark(shape: XMarkShape(), size: tile * 0.58)
                    .shadow(color: .black.opacity(0.20), radius: tile * 0.03, x: 0, y: tile * 0.014)
                    .shadow(color: .white.opacity(0.5), radius: tile * 0.055)
                    .shadow(color: XBrand.c1.opacity(0.35), radius: tile * 0.02, y: tile * 0.006)

                // 星座式点缀小火花（竖向经典火花，与对角 X 形成对比 → 「闪耀/干净」）
                FacetedSpark(shape: SparkleShape(), size: tile * 0.135, facets: false)
                    .offset(x: tile * 0.255, y: -tile * 0.235)
                    .shadow(color: .white.opacity(0.7), radius: tile * 0.02)
                FacetedSpark(shape: SparkleShape(), size: tile * 0.06, facets: false)
                    .offset(x: -tile * 0.26, y: tile * 0.205)
                    .opacity(0.9)
                    .shadow(color: .white.opacity(0.6), radius: tile * 0.012)

                // 顶部内描边高光
                shape.strokeBorder(.white.opacity(0.18), lineWidth: 2)
            }
            .frame(width: tile, height: tile)
            .shadow(color: .black.opacity(0.22), radius: 26, x: 0, y: 16)
        }
        .frame(width: s, height: s)
    }
}
