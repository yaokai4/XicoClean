import SwiftUI
import AppKit
import DesignSystem
import Infrastructure

// MARK: - 菜单栏显示样式（可在设置里切换，像 iStat 一样自定义）

public enum MenuBarStyle: String, CaseIterable, Sendable {
    case iconValue   // 图标 + 数值
    case valueOnly   // 仅数值
    case graph       // 迷你折线 + 数值
    case rich        // 指标专属迷你可视化（CPU 直方图 / 内存·磁盘环 / 网络双行）— iStat 风格

    public var title: String {
        switch self {
        case .iconValue: return "图标 + 数值"
        case .valueOnly: return "仅数值"
        case .graph:     return "迷你图 + 数值"
        case .rich:      return "可视化 + 数值"
        }
    }
}

// MARK: - 菜单栏图形化状态项（极简单色，随菜单栏深浅自适应）
//
// 菜单栏图标保持克制：单色，渲染为「模板图」(isTemplate)，由系统自动适配——
// 深色菜单栏显示白色、浅色菜单栏显示黑色，永远清晰。彩虹极光留给点开后的详情面板。

@MainActor
public enum MenuBarGlyph {

    public static func cpu(fraction: Double, history: [Double], style: MenuBarStyle, colored: Bool = false) -> NSImage {
        if style == .rich {
            return render(RichGlyph(viz: .histogram(history), value: "\(pct(fraction))%"),
                          colored: colored, tint: [XColor.auroraBlue, XColor.auroraViolet])
        }
        return render(MetricGlyph(glyph: "cpu", value: "\(pct(fraction))%", history: history, style: style),
               colored: colored, tint: [XColor.auroraBlue, XColor.auroraViolet])
    }

    public static func memory(fraction: Double, history: [Double], style: MenuBarStyle, colored: Bool = false) -> NSImage {
        if style == .rich {
            return render(RichGlyph(viz: .ring(fraction), value: "\(pct(fraction))%"),
                          colored: colored, tint: [XColor.auroraViolet, XColor.auroraRose])
        }
        return render(MetricGlyph(glyph: "memorychip", value: "\(pct(fraction))%", history: history, style: style),
               colored: colored, tint: [XColor.auroraViolet, XColor.auroraRose])
    }

    public static func network(down: Double, up: Double, history: [Double], style: MenuBarStyle, colored: Bool = false) -> NSImage {
        render(NetGlyph(up: up.compactRate, down: down.compactRate, history: history, style: style),
               colored: colored, tint: [XColor.accentTeal, XColor.auroraBlue])
    }

    /// CPU 温度（如 "44°"）。celsius 为 nil/0 时显示 "—°"，不误导为 0 度。
    /// 彩色模式下按温区着色：冷→绿、温→橙、热→红，一眼判断冷热。
    public static func temperature(celsius: Double?, style: MenuBarStyle, colored: Bool = false) -> NSImage {
        let text = (celsius != nil && celsius! > 0) ? "\(Int(celsius!.rounded()))°" : "—°"
        return render(MetricGlyph(glyph: "thermometer.medium", value: text, history: [], style: style == .rich ? .iconValue : style),
                      colored: colored, tint: tempTint(celsius))
    }

    private static func tempTint(_ c: Double?) -> [Color] {
        guard let c = c, c > 0 else { return [XColor.textSecondary, XColor.textSecondary] }
        if c >= 80 { return [XColor.danger, XColor.accentPink] }
        if c >= 65 { return [XColor.warning, XColor.accentPink] }
        return [XColor.success, XColor.accentTeal]
    }

    /// 磁盘占用（如 "39%"）。
    public static func disk(fraction: Double, style: MenuBarStyle, colored: Bool = false) -> NSImage {
        if style == .rich {
            return render(RichGlyph(viz: .bar(fraction), value: "\(pct(fraction))%"),
                          colored: colored, tint: [XColor.accentTeal, XColor.success])
        }
        return render(MetricGlyph(glyph: "internaldrive", value: "\(pct(fraction))%", history: [], style: style),
               colored: colored, tint: [XColor.accentTeal, XColor.success])
    }

    /// GPU 占用（如 "26%"）。
    public static func gpu(fraction: Double, history: [Double], style: MenuBarStyle, colored: Bool = false) -> NSImage {
        if style == .rich {
            return render(RichGlyph(viz: .ring(fraction), value: "\(pct(fraction))%"),
                          colored: colored, tint: [XColor.auroraViolet, XColor.auroraOrchid])
        }
        return render(MetricGlyph(glyph: "cpu.fill", value: "\(pct(fraction))%", history: history, style: style),
               colored: colored, tint: [XColor.auroraViolet, XColor.auroraOrchid])
    }

    public static func combined(colored: Bool = false) -> NSImage {
        // 合并总览用单色，避免即使其它项克制、这个图标仍是一条彩虹。
        render(GlyphOnly(glyph: "gauge.with.dots.needle.50percent", size: 14),
               colored: colored, tint: [XColor.textPrimary])
    }

    private static func pct(_ f: Double) -> Int { Int((f * 100).rounded()) }

    /// 渲染菜单栏图标。colored=false → 模板图（系统按深浅自动黑/白，永远清晰，默认）；
    /// colored=true → 单一色相着色（每指标一色，克制不刺眼，像 iStat 的彩色模式，
    /// 而非之前的双色极光渐变）。真正的彩虹极光留给点开后的详情面板。
    private static func render<V: View>(_ view: V, colored: Bool, tint: [Color]) -> NSImage {
        if colored {
            // 只取该指标的主色做单色填充——避免菜单栏里出现刺眼的多色渐变。
            let solid = tint.first ?? XColor.textPrimary
            let r = ImageRenderer(content: view.foregroundStyle(solid))
            r.scale = 2
            let img = r.nsImage ?? NSImage()
            img.isTemplate = false   // 保留彩色
            return img
        } else {
            let r = ImageRenderer(content: view.foregroundStyle(.black))
            r.scale = 2
            let img = r.nsImage ?? NSImage()
            img.isTemplate = true    // 系统自动着色
            return img
        }
    }
}

// MARK: - 单色迷你折线（graph 样式）

private struct MiniSparkline: View {
    let values: [Double]   // 0…1
    var body: some View {
        GeometryReader { geo in
            let v = Array(values.suffix(16))
            Path { p in
                guard v.count > 1 else { return }
                let w = geo.size.width, h = geo.size.height
                for (i, val) in v.enumerated() {
                    let x = w * CGFloat(i) / CGFloat(v.count - 1)
                    let y = h * (1 - CGFloat(min(max(val, 0), 1)))
                    if i == 0 { p.move(to: CGPoint(x: x, y: y)) } else { p.addLine(to: CGPoint(x: x, y: y)) }
                }
            }
            .stroke(style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
        }
        .frame(width: 22, height: 12)
    }
}

// MARK: - 指标字形（CPU / 内存）

private struct MetricGlyph: View {
    let glyph: String
    let value: String
    let history: [Double]
    let style: MenuBarStyle

    var body: some View {
        HStack(spacing: 3) {
            switch style {
            case .iconValue, .rich:
                Image(systemName: glyph).font(.system(size: 12.5, weight: .semibold))
            case .valueOnly:
                EmptyView()
            case .graph:
                MiniSparkline(values: history)
            }
            Text(value).font(.system(size: 12.5, weight: .semibold, design: .rounded)).monospacedDigit()
        }
        .frame(height: 18)
        .padding(.horizontal, 1)
    }
}

// MARK: - 网络字形（↑ / ↓ 两行；graph 样式额外加折线）

private struct NetGlyph: View {
    let up: String
    let down: String
    let history: [Double]
    let style: MenuBarStyle

    var body: some View {
        HStack(spacing: 3) {
            if style == .graph { MiniSparkline(values: history) }
            VStack(alignment: .trailing, spacing: 0) {
                row("arrow.up", up)
                row("arrow.down", down)
            }
        }
        .frame(height: 18)
        .padding(.horizontal, 1)
    }
    private func row(_ icon: String, _ value: String) -> some View {
        HStack(spacing: 1.5) {
            Image(systemName: icon).font(.system(size: 7.5, weight: .bold))
            Text(value).font(.system(size: 9, weight: .semibold, design: .rounded)).monospacedDigit()
        }
    }
}

// MARK: - 指标专属迷你可视化（rich 样式，iStat 风格）

private struct RichGlyph: View {
    enum Viz {
        case histogram([Double])   // CPU/GPU：彩色直方条
        case ring(Double)          // 内存/GPU：迷你环
        case bar(Double)           // 磁盘：横向填充条
    }
    let viz: Viz
    let value: String

    var body: some View {
        HStack(spacing: 3) {
            switch viz {
            case .histogram(let h): MiniHistogram(values: h)
            case .ring(let f):      MiniRingGlyph(fraction: f)
            case .bar(let f):       MiniBarGlyph(fraction: f)
            }
            Text(value).font(.system(size: 12, weight: .semibold, design: .rounded)).monospacedDigit()
        }
        .frame(height: 18)
        .padding(.horizontal, 1)
    }
}

/// 迷你直方图（当前用色渲染，模板/彩色由 render 决定）。
private struct MiniHistogram: View {
    let values: [Double]
    var body: some View {
        let v = Array(values.suffix(12))
        HStack(alignment: .bottom, spacing: 1) {
            ForEach(Array(v.enumerated()), id: \.offset) { _, val in
                let f = min(max(val, 0), 1)
                RoundedRectangle(cornerRadius: 0.5)
                    // 单色模板下按值分层不透明度，低值淡高值实，保证直方图不糊成一团。
                    .opacity(0.4 + 0.6 * f)
                    .frame(width: 1.6, height: max(1.5, 13 * CGFloat(f)))
            }
        }
        .frame(width: 24, height: 13, alignment: .bottom)
    }
}

/// 迷你环（用 trim 画部分弧）。
private struct MiniRingGlyph: View {
    let fraction: Double
    var body: some View {
        ZStack {
            Circle().stroke(lineWidth: 2).opacity(0.25)
            Circle().trim(from: 0, to: max(0.02, min(fraction, 1)))
                .stroke(style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: 13, height: 13)
    }
}

/// 迷你横向填充条（磁盘）。
private struct MiniBarGlyph: View {
    let fraction: Double
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().opacity(0.22)
                Capsule().frame(width: max(2, geo.size.width * min(max(fraction, 0), 1)))
            }
        }
        .frame(width: 20, height: 8)
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
