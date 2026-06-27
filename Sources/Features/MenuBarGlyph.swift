import SwiftUI
import AppKit
import DesignSystem
import Infrastructure

// MARK: - 菜单栏显示样式（可在设置里切换，像 iStat 一样自定义）

public enum MenuBarStyle: String, CaseIterable, Sendable {
    case iconValue   // 图标 + 数值
    case valueOnly   // 仅数值
    case graph       // 迷你折线 + 数值

    public var title: String {
        switch self {
        case .iconValue: return "图标 + 数值"
        case .valueOnly: return "仅数值"
        case .graph:     return "迷你图 + 数值"
        }
    }
}

// MARK: - 菜单栏图形化状态项（极简单色，随菜单栏深浅自适应）
//
// 菜单栏图标保持克制：单色，渲染为「模板图」(isTemplate)，由系统自动适配——
// 深色菜单栏显示白色、浅色菜单栏显示黑色，永远清晰。彩虹极光留给点开后的详情面板。

@MainActor
public enum MenuBarGlyph {

    public static func cpu(fraction: Double, history: [Double], style: MenuBarStyle) -> NSImage {
        render(MetricGlyph(glyph: "cpu", value: "\(pct(fraction))%", history: history, style: style))
    }

    public static func memory(fraction: Double, history: [Double], style: MenuBarStyle) -> NSImage {
        render(MetricGlyph(glyph: "memorychip", value: "\(pct(fraction))%", history: history, style: style))
    }

    public static func network(down: Double, up: Double, history: [Double], style: MenuBarStyle) -> NSImage {
        render(NetGlyph(up: up.compactRate, down: down.compactRate, history: history, style: style))
    }

    public static func combined() -> NSImage {
        render(GlyphOnly(glyph: "gauge.with.dots.needle.50percent", size: 14))
    }

    private static func pct(_ f: Double) -> Int { Int((f * 100).rounded()) }

    /// 渲染为模板图：系统按菜单栏外观自动着色（深→白 / 浅→黑）
    private static func render<V: View>(_ view: V) -> NSImage {
        let r = ImageRenderer(content: view.foregroundStyle(.black))
        r.scale = 2
        let img = r.nsImage ?? NSImage()
        img.isTemplate = true
        return img
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
            case .iconValue:
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

// MARK: - 仅图标（合并总览）

private struct GlyphOnly: View {
    let glyph: String
    let size: CGFloat
    var body: some View {
        Image(systemName: glyph).font(.system(size: size, weight: .semibold)).frame(height: 18)
    }
}
