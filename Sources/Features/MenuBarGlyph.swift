import SwiftUI
import AppKit
import DesignSystem
import Infrastructure

// MARK: - 菜单栏显示样式（可在设置里切换，像 iStat 一样自定义）

public enum MenuBarStyle: String, CaseIterable, Sendable {
    case iconValue   // 图标 + 数值
    case valueOnly   // 仅数值
    case graph       // 迷你折线 + 数值
    case rich        // 指标专属迷你可视化（CPU 直方图 / 内存·GPU·磁盘饼盘 / 网络双行）— iStat 风格
    case ring        // 圆环进度（占比类指标：CPU / 内存 / GPU / 磁盘）

    public var title: String {
        switch self {
        case .iconValue: return xLoc("图标 + 数值")
        case .valueOnly: return xLoc("仅数值")
        case .graph:     return xLoc("迷你图 + 数值")
        case .rich:      return xLoc("可视化 + 数值")
        case .ring:      return xLoc("圆环 + 数值")
        }
    }

    /// 可视化选择器用的短标签（图形本身就是主要提示，标签只作辅助）。
    public var shortTitle: String {
        switch self {
        case .iconValue: return xLoc("图标")
        case .valueOnly: return xLoc("数值")
        case .graph:     return xLoc("迷你图")
        case .rich:      return xLoc("可视化")
        case .ring:      return xLoc("圆环")
        }
    }

    /// 该样式是否需要「单一占比」——网络（双向速率）、温度（非占比）不适用圆环。
    public var needsFraction: Bool { self == .ring }
}

// MARK: - 菜单栏图形化状态项（极简单色，随菜单栏深浅自适应）
//
// 菜单栏图标保持克制：单色，渲染为「模板图」(isTemplate)，由系统自动适配——
// 深色菜单栏显示白色、浅色菜单栏显示黑色，永远清晰。彩虹极光留给点开后的详情面板。

@MainActor
public enum MenuBarGlyph {

    public static func cpu(fraction: Double, history: [Double], style: MenuBarStyle, colored: Bool = false, border: Bool = true) -> NSImage {
        let s = chip(colored: colored, tint: XColor.metricCPU)
        let value = "\(pct(fraction))%"
        if style == .rich {
            return rasterize(RichGlyph(viz: .histogram(history), value: value, chip: s, border: border), colored: colored)
        }
        if style == .ring {
            return rasterize(RichGlyph(viz: .ringViz(fraction), value: value, chip: s, border: border), colored: colored)
        }
        return rasterize(MetricGlyph(glyph: "cpu", value: value, history: history, style: style, chip: s, border: border), colored: colored)
    }

    public static func memory(fraction: Double, history: [Double], style: MenuBarStyle, colored: Bool = false, border: Bool = true) -> NSImage {
        let s = chip(colored: colored, tint: XColor.metricMemory)
        let value = "\(pct(fraction))%"
        if style == .rich {
            return rasterize(RichGlyph(viz: .pie(fraction), value: value, chip: s, border: border), colored: colored)
        }
        if style == .ring {
            return rasterize(RichGlyph(viz: .ringViz(fraction), value: value, chip: s, border: border), colored: colored)
        }
        if style == .ring {
            return rasterize(RichGlyph(viz: .ringViz(fraction), value: value, chip: s, border: border), colored: colored)
        }
        if style == .ring {
            return rasterize(RichGlyph(viz: .ringViz(fraction), value: value, chip: s, border: border), colored: colored)
        }
        return rasterize(MetricGlyph(glyph: "memorychip", value: value, history: history, style: style, chip: s, border: border), colored: colored)
    }

    public static func network(down: Double, up: Double, history: [Double], style: MenuBarStyle, colored: Bool = false, border: Bool = true) -> NSImage {
        // 网络无专属可视化：只有 graph（含迷你折线）时才是「图形」→ 折线本身加框，数值在框外。
        let s = chip(colored: colored, tint: XColor.metricNetwork)
        return rasterize(NetGlyph(up: up.compactRate, down: down.compactRate, history: history, style: style, chip: s, border: border), colored: colored)
    }

    /// CPU 温度（如 "44°"）。celsius 为 nil/0 时显示 "—°"，不误导为 0 度。
    /// 彩色模式下按温区着色：冷→绿、温→橙、热→红，一眼判断冷热。
    public static func temperature(celsius: Double?, style: MenuBarStyle, colored: Bool = false, border: Bool = true) -> NSImage {
        let text = (celsius != nil && celsius! > 0) ? "\(Int(celsius!.rounded()))°" : "—°"
        // 温度无曲线可画：始终「图标 + 数值」或「仅数值」，永不加框（消灭温度旁的空框）。
        let s = chip(colored: colored, tint: tempTint(celsius))
        return rasterize(MetricGlyph(glyph: "thermometer.medium", value: text, history: [],
                                     style: style == .valueOnly ? .valueOnly : .iconValue, chip: s, border: false), colored: colored)
    }

    private static func tempTint(_ c: Double?) -> [Color] {
        guard let c = c, c > 0 else { return [XColor.textSecondary, XColor.textSecondary] }
        if c >= 80 { return [XColor.danger, XColor.accentPink] }
        if c >= 65 { return [XColor.warning, XColor.accentPink] }
        return [XColor.success, XColor.accentTeal]
    }

    /// 磁盘占用（如 "39%"）。
    public static func disk(fraction: Double, style: MenuBarStyle, colored: Bool = false, border: Bool = true) -> NSImage {
        let s = chip(colored: colored, tint: XColor.metricDisk)
        let value = "\(pct(fraction))%"
        if style == .rich {
            return rasterize(RichGlyph(viz: .pie(fraction), value: value, chip: s, border: border), colored: colored)
        }
        return rasterize(MetricGlyph(glyph: "internaldrive", value: value, history: [], style: style, chip: s, border: border), colored: colored)
    }

    /// GPU 占用（如 "26%"）。
    public static func gpu(fraction: Double, history: [Double], style: MenuBarStyle, colored: Bool = false, border: Bool = true) -> NSImage {
        let s = chip(colored: colored, tint: XColor.metricGPU)
        let value = "\(pct(fraction))%"
        if style == .rich {
            return rasterize(RichGlyph(viz: .pie(fraction), value: value, chip: s, border: border), colored: colored)
        }
        return rasterize(MetricGlyph(glyph: "cpu.fill", value: value, history: history, style: style, chip: s, border: border), colored: colored)
    }

    public static func combined(colored: Bool = false) -> NSImage {
        // 合并总览用单色，避免即使其它项克制、这个图标仍是一条彩虹。
        let fg: Color = colored ? XColor.textPrimary : .black
        return rasterize(GlyphOnly(glyph: "gauge.with.dots.needle.50percent", size: 14).foregroundStyle(fg), colored: colored)
    }

    private static func pct(_ f: Double) -> Int { Int((f * 100).rounded()) }

    /// 前景色 + 「圈图形」的描边/底色。colored=false → 模板黑（系统按深浅自动黑白）；
    /// colored=true → 单一主色。描边只用于包住图形本身，数值文字永远在框外。
    static func chip(colored: Bool, tint: [Color]) -> GlyphChip {
        let fg: Color = colored ? (tint.first ?? XColor.textPrimary) : .black
        // 「圈图形」的软框：淡底 + 清晰描边（加深到 0.42/0.36，之前太浅在浅色壁纸上看不清）。
        return GlyphChip(fg: fg,
                         stroke: colored ? fg.opacity(0.42) : Color.black.opacity(0.36),
                         fill: colored ? fg.opacity(0.08) : Color.black.opacity(0.07))
    }

    private static func rasterize<V: View>(_ view: V, colored: Bool) -> NSImage {
        let r = ImageRenderer(content: view)
        r.scale = 2
        let img = r.nsImage ?? NSImage()
        img.isTemplate = !colored   // 单色→系统按深浅自动黑白；彩色→保留
        return img
    }
}

/// 字形的前景色与「圈图形」描边样式（在字形内部只应用到图形本身，数值文字不进框）。
struct GlyphChip {
    let fg: Color
    let stroke: Color
    let fill: Color
}

// MARK: - 只圈图形的描边框
//
// 关键：边框**只圈住图形本身**（迷你折线 / 直方图 / 环 / 进度条），旁边的数值百分比一律在框外并排，
// 绝不进框——进框既丑、也与「边框只圈图形」的设计铁律相悖。深浅自适应：模板模式描边为系统色低透明度。
private extension View {
    /// 「圈图形」软框。`on=false` 时退化为裸图形（框可按项开关）。几何 @2x 落整数设备像素：
    /// 水平内边距 2.5pt=5px、垂直 1pt=2px、圆角 4pt=8px、描边 1pt=2px。
    /// `flush=true` 用于直方图/进度条这类「有地面」的图形：柱子直接坐在边框内底沿，
    /// 两侧只留 1.5pt，超出圆角部分裁切——框是图形的坐标系，而不是漂浮的装饰框。
    @ViewBuilder func menuGraphicChip(_ chip: GlyphChip, on: Bool = true, flush: Bool = false) -> some View {
        if on {
            if flush {
                // 框贴身：左右各 1pt、顶 1.5pt——内容与边框 100% 齐平挤满，框即坐标系。
                self
                    .padding(.horizontal, 1)
                    .padding(.top, 1.5)
                    .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(chip.fill))
                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(chip.stroke, lineWidth: 1))
            } else {
                self
                    .padding(.horizontal, 2.5)
                    .padding(.vertical, 1)
                    .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(chip.fill))
                    .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(chip.stroke, lineWidth: 1))
            }
        } else {
            self
        }
    }
}

// MARK: - 单色迷你折线（graph 样式）

private struct MiniSparkline: View {
    let values: [Double]   // 0…1

    private func points(in size: CGSize) -> [CGPoint] {
        let v = Array(values.suffix(30))   // 30 个采样点：半分钟走势，框内信息密度对齐 iStat
        guard v.count > 1 else { return [] }
        return v.enumerated().map { i, val in
            CGPoint(x: size.width * CGFloat(i) / CGFloat(v.count - 1),
                    y: size.height * (1 - CGFloat(min(max(val, 0), 1)) * 0.9) - 0.5)
        }
    }

    var body: some View {
        GeometryReader { geo in
            let pts = points(in: geo.size)
            let h = geo.size.height, w = geo.size.width
            // 折线下方的面积填充（低透明度）——单色模板下也有层次，像 iStat 的迷你走势
            Path { p in
                guard let first = pts.first else { return }
                p.move(to: CGPoint(x: 0, y: h))
                p.addLine(to: first)
                for pt in pts.dropFirst() { p.addLine(to: pt) }
                p.addLine(to: CGPoint(x: w, y: h))
                p.closeSubpath()
            }
            .fill(.opacity(0.22))
            // 折线本身
            Path { p in
                guard let first = pts.first else { return }
                p.move(to: first)
                for pt in pts.dropFirst() { p.addLine(to: pt) }
            }
            .stroke(style: StrokeStyle(lineWidth: 1.4, lineCap: .round, lineJoin: .round))
        }
        .frame(width: 40, height: 15)
    }
}

// MARK: - 指标字形（CPU / 内存）

private struct MetricGlyph: View {
    let glyph: String
    let value: String
    let history: [Double]
    let style: MenuBarStyle
    let chip: GlyphChip
    var border: Bool = true

    var body: some View {
        // 间距按黄金比收紧（图形→数值 3pt，无外侧余量）——多项并排时节省顶栏空间。
        HStack(spacing: 3) {
            switch style {
            case .iconValue, .rich, .ring:   // ring 对无占比指标回退为图标+数值
                Image(systemName: glyph).font(.system(size: 12.5, weight: .semibold))
            case .valueOnly:
                EmptyView()
            case .graph:
                // 折线迷你图贴边入框（框=图表坐标系，走势线挤满图表区）；数值在框外并排。
                // 无历史数据时不画空框，退化为图标（避免空盒子——温度等无曲线指标的丑框由此消除）。
                if history.count >= 2 {
                    MiniSparkline(values: history).menuGraphicChip(chip, on: border, flush: true)
                } else {
                    Image(systemName: glyph).font(.system(size: 12.5, weight: .semibold))
                }
            }
            Text(value).font(.system(size: 12.5, weight: .semibold, design: .rounded)).monospacedDigit()
        }
        .foregroundStyle(chip.fg)
        .frame(height: 18)
    }
}

// MARK: - 网络字形（↑ / ↓ 两行；graph 样式额外加折线，只圈折线）

private struct NetGlyph: View {
    let up: String
    let down: String
    let history: [Double]
    let style: MenuBarStyle
    let chip: GlyphChip
    var border: Bool = true

    var body: some View {
        HStack(spacing: 3) {
            if style == .graph, history.count >= 2 {
                MiniSparkline(values: history).menuGraphicChip(chip, on: border, flush: true)   // 折线贴边入框
            }
            VStack(alignment: .trailing, spacing: 0) {
                row("arrow.up", up)
                row("arrow.down", down)
            }
        }
        .foregroundStyle(chip.fg)
        .frame(height: 18)
    }
    private func row(_ icon: String, _ value: String) -> some View {
        HStack(spacing: 1.5) {
            Image(systemName: icon).font(.system(size: 7.5, weight: .bold))
            Text(value).font(.system(size: 9, weight: .semibold, design: .rounded)).monospacedDigit()
        }
    }
}

// MARK: - 指标专属迷你可视化（rich 样式，Sensei 风格）
//
// 直方图 / 环 / 进度条这类「自成形状」的图形**一律不加框**（对齐 Sensei 菜单栏：环、电池、条都裸露）。
// 只有折线迷你图（graph）需要一枚淡淡的框把「图表区」圈出来——那个在 MetricGlyph/NetGlyph 里处理。
private struct RichGlyph: View {
    enum Viz {
        case histogram([Double])   // CPU：直方条
        case pie(Double)           // 饼盘：实心扇形，圆盘永远完整无缺口
        case ringViz(Double)       // 圆环：描边进度环（底轨加深，缺口读作轨道而非「被咬」）
        case bar(Double)           // 备用：横向进度条
    }
    let viz: Viz
    let value: String
    let chip: GlyphChip
    var border: Bool = false   // 直方图/环/条默认裸露（对齐 Sensei）；开框则套软框

    var body: some View {
        HStack(spacing: 3) {
            // 直方图/进度条贴边入框（框=坐标系）；环形是自完整图形，永远裸露不套框（用户拍板）
            graphic.menuGraphicChip(chip, on: border && isFlushViz, flush: isFlushViz)
            Text(value).font(.system(size: 12, weight: .semibold, design: .rounded)).monospacedDigit()
        }
        .foregroundStyle(chip.fg)
        .frame(height: 18)
    }

    private var isFlushViz: Bool {
        switch viz {
        case .pie, .ringViz: return false   // 饼盘/圆环是自完整图形，永远裸露不套框
        default: return true
        }
        return true
    }

    @ViewBuilder private var graphic: some View {
        switch viz {
        case .histogram(let h): MiniHistogram(values: h)
        case .pie(let f):       MiniPieGlyph(fraction: f)
        case .ringViz(let f):   MiniRingGlyph(fraction: f)
        case .bar(let f):       MiniBarGlyph(fraction: f)
        }
    }
}

/// 迷你直方图（当前用色渲染，模板/彩色由 render 决定）。
/// 像素对齐：13 根 2pt 实心条 + 1pt 间距（13×2+12×1=38pt），@2x 落在整数设备像素上；
/// 条数与宽度对齐 iStat 的信息密度，柱体贴住 flush 框的内底沿挤满图表区。
private struct MiniHistogram: View {
    let values: [Double]
    var body: some View {
        let v = Array(values.suffix(13))
        HStack(alignment: .bottom, spacing: 1) {
            ForEach(Array(v.enumerated()), id: \.offset) { _, val in
                let f = min(max(val, 0), 1)
                Rectangle()
                    // 单色模板下按值分层不透明度，低值淡高值实，保证直方图不糊成一团。
                    .opacity(0.4 + 0.6 * f)
                    .frame(width: 2, height: max(2, 15 * CGFloat(f)))
            }
        }
        .frame(width: 38, height: 15, alignment: .bottom)
    }
}

/// 迷你饼盘（iStat 式）：淡底圆盘 + 实心扇形填充 + 清晰外沿。
/// 环形在高占比时留下的「缺口」在彩色壁纸上像被咬了一口——饼盘的圆盘永远完整。
private struct MiniPieGlyph: View {
    let fraction: Double
    var body: some View {
        ZStack {
            Circle().opacity(0.22)                                  // 底盘：未用部分
            PieSector(fraction: max(0.02, min(fraction, 1)))        // 实心扇形：已用部分
            Circle().stroke(lineWidth: 1).opacity(0.5)              // 外沿：圆盘轮廓永远闭合
        }
        .frame(width: 14, height: 14)
        .padding(.vertical, 0.5)
    }
}

/// 迷你圆环（描边进度）。底轨 0.38：高占比留下的缺口读作「轨道」而非缺损。
private struct MiniRingGlyph: View {
    let fraction: Double
    var body: some View {
        ZStack {
            Circle().stroke(lineWidth: 2).opacity(0.38)
            Circle().trim(from: 0, to: max(0.02, min(fraction, 1)))
                .stroke(style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: 13, height: 13)
        .padding(1)
    }
}

/// 从 12 点方向顺时针展开的实心扇形。
private struct PieSector: Shape {
    var fraction: Double
    func path(in rect: CGRect) -> Path {
        let c = CGPoint(x: rect.midX, y: rect.midY)
        var p = Path()
        p.move(to: c)
        p.addArc(center: c, radius: min(rect.width, rect.height) / 2,
                 startAngle: .degrees(-90), endAngle: .degrees(-90 + 360 * min(fraction, 1)),
                 clockwise: false)
        p.closeSubpath()
        return p
    }
}

/// 迷你横向填充条（磁盘）。加宽对齐直方图/折线的图表区宽度，framed 后挤满边框。
private struct MiniBarGlyph: View {
    let fraction: Double
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().opacity(0.22)
                Capsule().frame(width: max(2, geo.size.width * min(max(fraction, 0), 1)))
            }
        }
        .frame(width: 38, height: 8)
    }
}

// MARK: - 仅图标（合并总览）

private struct GlyphOnly: View {
    let glyph: String
    let size: CGFloat
    var body: some View {
        Image(systemName: glyph).font(.system(size: size, weight: .semibold)).frame(height: 18)
    }
}
