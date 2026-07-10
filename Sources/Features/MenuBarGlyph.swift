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

// MARK: - 真 · 合并项（单一状态项内多迷你图并排，iStat Combined 式）

/// 合并项的一个槽位：一种迷你可视化 + 主题染色（单色模板下忽略 tint）。
public struct MenuCombinedSlot: Sendable {
    public enum Viz: Sendable {
        case histogram([Double])                 // CPU
        case pie(Double)                         // 内存 / GPU / 磁盘
        case ring(Double)
        case net(down: String, up: String)       // 网络双行
        case text(String)                        // 温度 / 电池等文本
    }
    public let viz: Viz
    public let tint: [Color]
    /// 可选数值文字（跟在图形右侧，9pt 小字）——由「合并项显示数值」开关控制。
    public let value: String?
    public init(viz: Viz, tint: [Color], value: String? = nil) {
        self.viz = viz
        self.tint = tint
        self.value = value
    }

    /// 缓存签名成分。
    var signature: String {
        switch viz {
        case .histogram(let h): return "h" + MenuBarGlyph.histSignature(h) + (value ?? "")
        case .pie(let f):       return "p\(Int(f * 100))" + (value ?? "")
        case .ring(let f):      return "r\(Int(f * 100))" + (value ?? "")
        case .net(let d, let u): return "n\(d)|\(u)"
        case .text(let t):      return "t\(t)"
        }
    }
}

// MARK: - 菜单栏图形化状态项（CoreGraphics 直绘 · P3 渲染换血）
//
// 菜单栏图标保持克制：单色，渲染为「模板图」(isTemplate)，由系统自动适配——
// 深色菜单栏显示白色、浅色菜单栏显示黑色，永远清晰。彩虹极光留给点开后的详情面板。
//
// 渲染架构（P3）：`NSImage(size:flipped:drawingHandler:)` + CoreGraphics 矢量直绘，
// 取代 SwiftUI ImageRenderer 光栅化——
// 1. 主线程成本从「每 tick 一次 SwiftUI 渲染管线」降到微秒级 CG 路径绘制；
// 2. drawingHandler 由 AppKit 在**每块目标屏幕的 backingScale** 下惰性重绘——1x/2x/3x
//    逐屏像素精确，消灭 scale=2 硬编码；
// 3. 模板图语义完整保留（深浅自适应、按压高亮、macOS 26 透明菜单栏的背景处理）。
// 值不变时经签名缓存直接复用 NSImage（缓存被字形 id 天然限量）。
// SwiftUI 版字形预览仍在 SettingsView.MBStyleTile（与本渲染器解耦）。

@MainActor
public enum MenuBarGlyph {

    // MARK: 公共 API（与旧版签名兼容）

    public static func cpu(fraction: Double, history: [Double], style: MenuBarStyle, colored: Bool = false, border: Bool = true) -> NSImage {
        let value = "\(pct(fraction))%"
        let usesHist = (style == .rich || style == .graph)
        let sig = signature(style: style, colored: colored, border: border, value: value,
                            history: usesHist ? history : nil)
        return cachedImage(id: "cpu", signature: sig) {
            let p = palette(colored: colored, tint: XColor.metricCPU)
            switch style {
            case .rich:  return compose([.histogram(history, chip: border), .gap(3), .value(value)], p)
            case .ring:  return compose([.ring(fraction), .gap(3), .value(value)], p)
            case .graph: return graphOrIcon("cpu", value: value, history: history, border: border, p)
            case .valueOnly: return compose([.value(value)], p)
            case .iconValue: return compose([.symbol("cpu", 12.5, .semibold), .gap(3), .value(value)], p)
            }
        }
    }

    public static func memory(fraction: Double, history: [Double], style: MenuBarStyle, colored: Bool = false, border: Bool = true) -> NSImage {
        let value = "\(pct(fraction))%"
        let sig = signature(style: style, colored: colored, border: border, value: value,
                            history: style == .graph ? history : nil)
        return cachedImage(id: "memory", signature: sig) {
            let p = palette(colored: colored, tint: XColor.metricMemory)
            switch style {
            case .rich:  return compose([.pie(fraction), .gap(3), .value(value)], p)
            case .ring:  return compose([.ring(fraction), .gap(3), .value(value)], p)
            case .graph: return graphOrIcon("memorychip", value: value, history: history, border: border, p)
            case .valueOnly: return compose([.value(value)], p)
            case .iconValue: return compose([.symbol("memorychip", 12.5, .semibold), .gap(3), .value(value)], p)
            }
        }
    }

    public static func network(down: Double, up: Double, history: [Double], style: MenuBarStyle, colored: Bool = false, border: Bool = true) -> NSImage {
        let value = "↓\(down.compactRate)|↑\(up.compactRate)"
        let sig = signature(style: style, colored: colored, border: border, value: value,
                            history: style == .graph ? history : nil)
        return cachedImage(id: "network", signature: sig) {
            let p = palette(colored: colored, tint: XColor.metricNetwork)
            var elems: [Elem] = []
            if style == .graph, history.count >= 2 {
                elems += [.sparkline(history, chip: border), .gap(3)]
            }
            elems.append(.netRows(down: down.compactRate, up: up.compactRate))
            return compose(elems, p)
        }
    }

    /// CPU 温度（如 "44°"）。celsius 为 nil/0 时显示 "—°"，不误导为 0 度。
    /// 彩色模式下按温区着色：冷→绿、温→橙、热→红，一眼判断冷热。
    public static func temperature(celsius: Double?, style: MenuBarStyle, colored: Bool = false, border: Bool = true) -> NSImage {
        let text = (celsius != nil && celsius! > 0) ? "\(Int(celsius!.rounded()))°" : "—°"
        let sig = signature(style: style, colored: colored, border: false, value: text)
        return cachedImage(id: "temp", signature: sig) {
            let p = palette(colored: colored, tint: tempTint(celsius))
            if style == .valueOnly { return compose([.value(text)], p) }
            return compose([.symbol("thermometer.medium", 12.5, .semibold), .gap(3), .value(text)], p)
        }
    }

    private static func tempTint(_ c: Double?) -> [Color] {
        guard let c = c, c > 0 else { return [XColor.textSecondary, XColor.textSecondary] }
        if c >= 80 { return [XColor.danger, XColor.accentPink] }
        if c >= 65 { return [XColor.warning, XColor.accentPink] }
        return [XColor.success, XColor.accentTeal]
    }

    /// 磁盘占用（如 "39%"）。
    public static func disk(fraction: Double, style: MenuBarStyle, colored: Bool = false, border: Bool = true) -> NSImage {
        let value = "\(pct(fraction))%"
        let sig = signature(style: style, colored: colored, border: border, value: value)
        return cachedImage(id: "disk", signature: sig) {
            let p = palette(colored: colored, tint: XColor.metricDisk)
            switch style {
            case .rich:  return compose([.pie(fraction), .gap(3), .value(value)], p)
            case .ring:  return compose([.ring(fraction), .gap(3), .value(value)], p)
            case .valueOnly: return compose([.value(value)], p)
            default:     return compose([.symbol("internaldrive", 12.5, .semibold), .gap(3), .value(value)], p)
            }
        }
    }

    /// GPU 占用（如 "26%"）。
    public static func gpu(fraction: Double, history: [Double], style: MenuBarStyle, colored: Bool = false, border: Bool = true) -> NSImage {
        let value = "\(pct(fraction))%"
        let sig = signature(style: style, colored: colored, border: border, value: value,
                            history: style == .graph ? history : nil)
        return cachedImage(id: "gpu", signature: sig) {
            let p = palette(colored: colored, tint: XColor.metricGPU)
            switch style {
            case .rich:  return compose([.pie(fraction), .gap(3), .value(value)], p)
            case .ring:  return compose([.ring(fraction), .gap(3), .value(value)], p)
            case .graph: return graphOrIcon("cpu.fill", value: value, history: history, border: border, p)
            case .valueOnly: return compose([.value(value)], p)
            case .iconValue: return compose([.symbol("cpu.fill", 12.5, .semibold), .gap(3), .value(value)], p)
            }
        }
    }

    /// 电池（P3·M10）：电量分档 SF 电池形 + 百分比；充电时加闪电。percent 为 nil（台式机）时不显示。
    public static func battery(percent: Int?, charging: Bool, style: MenuBarStyle, colored: Bool = false) -> NSImage {
        let pctText = percent != nil ? "\(percent!)%" : "—"
        let sig = signature(style: style, colored: colored, border: false, value: pctText + (charging ? "c" : ""))
        return cachedImage(id: "battery", signature: sig) {
            let level = percent ?? 100
            let tint: [Color] = charging ? [XColor.success, XColor.accentTeal]
                                         : (level <= 20 ? [XColor.danger, XColor.accentPink] : [XColor.textPrimary, XColor.textPrimary])
            let p = palette(colored: colored, tint: tint)
            let name = batterySymbol(level: level, charging: charging)
            switch style {
            case .valueOnly: return compose([.value(pctText)], p)
            case .ring:      return compose([.ring(Double(level) / 100), .gap(3), .value(pctText)], p)
            default:         return compose([.symbol(name, 13.5, .regular), .gap(3), .value(pctText)], p)
            }
        }
    }

    private static func batterySymbol(level: Int, charging: Bool) -> String {
        if charging { return "battery.100percent.bolt" }
        switch level {
        case ..<13:  return "battery.0percent"
        case ..<38:  return "battery.25percent"
        case ..<63:  return "battery.50percent"
        case ..<88:  return "battery.75percent"
        default:     return "battery.100percent"
        }
    }

    /// 真 · 合并项（P3·M1）：多迷你图并排于单一状态项，6pt 间距 + 极淡分隔线。
    /// 每槽位用其指标自己的样式配置渲染紧凑形态——刘海时代的省空间答案。
    public static func combined(slots: [MenuCombinedSlot], colored: Bool = false) -> NSImage {
        guard !slots.isEmpty else {
            return cachedImage(id: "combined", signature: "empty|\(colored)") {
                let p = palette(colored: colored, tint: [XColor.textPrimary])
                return compose([.symbol("gauge.with.dots.needle.50percent", 14, .semibold)], p)
            }
        }
        let sig = "slots|" + (colored ? "1" : "0") + "|" + slots.map(\.signature).joined(separator: ";")
        return cachedImage(id: "combined", signature: sig) {
            var elems: [Elem] = []
            var tints: [[Color]] = []
            for (i, slot) in slots.enumerated() {
                if i > 0 { elems += [.gap(5), .separator, .gap(5)]; tints += [[], [], []] }   // 占位一一对应
                let vizElem: Elem
                switch slot.viz {
                case .histogram(let h): vizElem = .histogram(h, chip: true)
                case .pie(let f):       vizElem = .pie(f)
                case .ring(let f):      vizElem = .ring(f)
                case .net(let d, let u): vizElem = .netRows(down: d, up: u)
                case .text(let t):      vizElem = .value(t)
                }
                elems.append(vizElem)
                tints.append(slot.tint)
                if let v = slot.value {
                    elems += [.gap(2.5), .smallValue(v)]
                    tints += [[], slot.tint]
                }
            }
            return composeMulti(elems, tints: tints, colored: colored)
        }
    }

    private static func pct(_ f: Double) -> Int { Int((f * 100).rounded()) }

    /// graph 样式：有历史画折线（框=图表坐标系），无历史退化为图标——不画空框。
    private static func graphOrIcon(_ icon: String, value: String, history: [Double], border: Bool, _ p: GlyphPalette) -> NSImage {
        if history.count >= 2 {
            return compose([.sparkline(history, chip: border), .gap(3), .value(value)], p)
        }
        return compose([.symbol(icon, 12.5, .semibold), .gap(3), .value(value)], p)
    }

    // MARK: - 调色（模板黑 / 单一主色）

    struct GlyphPalette {
        let fg: NSColor
        let chipStroke: NSColor
        let chipFill: NSColor
        let template: Bool
    }

    /// colored=false → 模板黑（系统按深浅自动黑白，透明菜单栏下亦由系统兜底）；
    /// colored=true → 单一主色（描边/淡底同源）。
    private static func palette(colored: Bool, tint: [Color]) -> GlyphPalette {
        if colored {
            let c = NSColor(tint.first ?? XColor.textPrimary)
            return GlyphPalette(fg: c,
                                chipStroke: c.withAlphaComponent(0.42),
                                chipFill: c.withAlphaComponent(0.08),
                                template: false)
        }
        return GlyphPalette(fg: .black,
                            chipStroke: NSColor.black.withAlphaComponent(0.36),
                            chipFill: NSColor.black.withAlphaComponent(0.07),
                            template: true)
    }

    // MARK: - 元素模型与排版

    /// 字形 = 一串水平元素。宽度先量后画，全部在 18pt 高度内垂直居中。
    enum Elem {
        case symbol(String, CGFloat, NSFont.Weight)   // SF Symbol：名称 + 磅值 + 字重
        case value(String)                            // 12.5pt 圆润等宽半粗
        case smallValue(String)                       // 9pt 圆润等宽半粗（合并项槽位值）
        case netRows(down: String, up: String)        // ↑/↓ 两行速率
        case sparkline([Double], chip: Bool)          // 40×15 折线（可入框）
        case histogram([Double], chip: Bool)          // 38×15 直方图（可入框）
        case pie(Double)                              // 14pt 饼盘
        case ring(Double)                             // 13pt 圆环
        case separator                                // 合并项分隔发丝线
        case gap(CGFloat)
    }

    static let glyphHeight: CGFloat = 18
    private static let chipRadius: CGFloat = 4       // @2x = 8px（刻意不走 XRadius：整数像素对齐）

    private static func valueFont(_ size: CGFloat, weight: NSFont.Weight = .semibold) -> NSFont {
        let base = NSFont.monospacedDigitSystemFont(ofSize: size, weight: weight)
        if let d = base.fontDescriptor.withDesign(.rounded), let f = NSFont(descriptor: d, size: size) {
            return f
        }
        return base
    }

    private static func textSize(_ s: String, font: NSFont) -> CGSize {
        (s as NSString).size(withAttributes: [.font: font])
    }

    private static func symbolNSImage(_ name: String, size: CGFloat, weight: NSFont.Weight) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: size, weight: weight))
    }

    private static func width(of elem: Elem) -> CGFloat {
        switch elem {
        case .symbol(let name, let size, let weight):
            return symbolNSImage(name, size: size, weight: weight)?.size.width ?? size
        case .value(let s):
            return ceil(textSize(s, font: valueFont(12.5)).width)
        case .smallValue(let s):
            return ceil(textSize(s, font: valueFont(9)).width)
        case .netRows(let down, let up):
            let f = valueFont(9)
            let arrow: CGFloat = 6.5
            let w1 = arrow + 1.5 + textSize(up, font: f).width
            let w2 = arrow + 1.5 + textSize(down, font: f).width
            return ceil(max(w1, w2))
        case .sparkline(_, let chip): return 40 + (chip ? 2 : 0)
        case .histogram(_, let chip): return 38 + (chip ? 2 : 0)
        case .pie:       return 14
        case .ring:      return 15
        case .separator: return 1
        case .gap(let g): return g
        }
    }

    /// 单色调组合。
    private static func compose(_ elems: [Elem], _ p: GlyphPalette) -> NSImage {
        composeMulti(elems, tints: elems.map { _ in [] }, colored: !p.template, fallback: p)
    }

    /// 多色调组合（合并项：每槽位独立 tint；单色模板时全部黑 alpha 分层）。
    private static func composeMulti(_ elems: [Elem], tints: [[Color]], colored: Bool,
                                     fallback: GlyphPalette? = nil) -> NSImage {
        let totalW = ceil(elems.map(width(of:)).reduce(0, +))
        // 逐元素解析调色板（在主线程一次性解析 NSColor，绘制闭包内只用已解析色）。
        // 防御：按 elems 逐索引取 tint（越界视为无 tint），不依赖两数组等长。
        let palettes: [GlyphPalette] = elems.indices.map { i in
            let tint = i < tints.count ? tints[i] : []
            if let fallback, tint.isEmpty { return fallback }
            return palette(colored: colored, tint: tint.isEmpty ? [XColor.textPrimary] : tint)
        }
        let elemsCopy = elems
        let img = NSImage(size: NSSize(width: totalW, height: glyphHeight), flipped: false) { _ in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            var x: CGFloat = 0
            for (i, elem) in elemsCopy.enumerated() {
                draw(elem, at: x, palette: palettes[i], ctx: ctx)
                x += width(of: elem)
            }
            return true
        }
        img.isTemplate = !colored
        return img
    }

    // MARK: - CG 绘制原语（几何与旧 SwiftUI 版逐点对齐）

    private static func draw(_ elem: Elem, at x: CGFloat, palette p: GlyphPalette, ctx: CGContext) {
        switch elem {
        case .gap:
            return
        case .separator:
            // 合并项槽位间的发丝分隔：1pt 宽、10pt 高、0.22 透明度。
            ctx.setFillColor(p.fg.withAlphaComponent(0.22).cgColor)
            ctx.fill(CGRect(x: x, y: 4, width: 1, height: 10))
        case .symbol(let name, let size, let weight):
            guard let img = symbolNSImage(name, size: size, weight: weight) else { return }
            let s = img.size
            let rect = NSRect(x: x, y: (glyphHeight - s.height) / 2, width: s.width, height: s.height)
            drawTinted(img, in: rect, color: p.fg, ctx: ctx)
        case .value(let s):
            drawText(s, font: valueFont(12.5), color: p.fg, x: x, centerY: glyphHeight / 2)
        case .smallValue(let s):
            drawText(s, font: valueFont(9), color: p.fg, x: x, centerY: glyphHeight / 2)
        case .netRows(let down, let up):
            let f = valueFont(9)
            // 两行：上行在上、下行在下（行高 ~8.5pt，整体居中）。
            drawNetRow(symbol: "arrow.up", text: up, font: f, color: p.fg, x: x, rowCenterY: 13.2, ctx: ctx)
            drawNetRow(symbol: "arrow.down", text: down, font: f, color: p.fg, x: x, rowCenterY: 4.8, ctx: ctx)
        case .sparkline(let values, let chip):
            let content = CGRect(x: x + (chip ? 1 : 0), y: 0.75, width: 40, height: 15)
            if chip { drawChip(around: CGRect(x: x, y: 0.75, width: 42, height: 16.5), p: p, ctx: ctx) }
            drawSparkline(values, in: content, color: p.fg, ctx: ctx)
        case .histogram(let values, let chip):
            let content = CGRect(x: x + (chip ? 1 : 0), y: 0.75, width: 38, height: 15)
            if chip { drawChip(around: CGRect(x: x, y: 0.75, width: 40, height: 16.5), p: p, ctx: ctx) }
            drawHistogram(values, in: content, color: p.fg, ctx: ctx)
        case .pie(let f):
            drawPie(f, in: CGRect(x: x, y: 2, width: 14, height: 14), color: p.fg, ctx: ctx)
        case .ring(let f):
            drawRing(f, in: CGRect(x: x + 1, y: 2.5, width: 13, height: 13), color: p.fg, ctx: ctx)
        }
    }

    private static func drawText(_ s: String, font: NSFont, color: NSColor, x: CGFloat, centerY: CGFloat) {
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let size = textSize(s, font: font)
        (s as NSString).draw(at: NSPoint(x: x, y: centerY - size.height / 2), withAttributes: attrs)
    }

    private static func drawNetRow(symbol: String, text: String, font: NSFont, color: NSColor,
                                   x: CGFloat, rowCenterY: CGFloat, ctx: CGContext) {
        var cursor = x
        if let img = symbolNSImage(symbol, size: 7, weight: .bold) {
            let s = img.size
            drawTinted(img, in: NSRect(x: cursor, y: rowCenterY - s.height / 2, width: s.width, height: s.height),
                       color: color, ctx: ctx)
            cursor += 6.5 + 1.5
        }
        drawText(text, font: font, color: color, x: cursor, centerY: rowCenterY)
    }

    /// 「圈图形」软框：淡底 + 1pt 描边、4pt 圆角（@2x 落整数像素）。框即图表坐标系。
    private static func drawChip(around rect: CGRect, p: GlyphPalette, ctx: CGContext) {
        let path = CGPath(roundedRect: rect, cornerWidth: chipRadius, cornerHeight: chipRadius, transform: nil)
        ctx.addPath(path)
        ctx.setFillColor(p.chipFill.cgColor)
        ctx.fillPath()
        // strokeBorder 语义：描边完全在框内 → 内缩半个线宽。
        let inset = rect.insetBy(dx: 0.5, dy: 0.5)
        ctx.addPath(CGPath(roundedRect: inset, cornerWidth: chipRadius - 0.5, cornerHeight: chipRadius - 0.5, transform: nil))
        ctx.setStrokeColor(p.chipStroke.cgColor)
        ctx.setLineWidth(1)
        ctx.strokePath()
    }

    /// 迷你折线（30 样本）：面积填充 0.22 + 1.4pt 圆帽折线。y 轴向上（非翻转坐标）。
    private static func drawSparkline(_ values: [Double], in rect: CGRect, color: NSColor, ctx: CGContext) {
        let v = Array(values.suffix(30))
        guard v.count > 1 else { return }
        let pts: [CGPoint] = v.enumerated().map { i, val in
            CGPoint(x: rect.minX + rect.width * CGFloat(i) / CGFloat(v.count - 1),
                    y: rect.minY + rect.height * CGFloat(min(max(val, 0), 1)) * 0.9 + 0.5)
        }
        // 面积
        ctx.saveGState()
        ctx.beginPath()
        ctx.move(to: CGPoint(x: rect.minX, y: rect.minY))
        ctx.addLine(to: pts[0])
        for pt in pts.dropFirst() { ctx.addLine(to: pt) }
        ctx.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        ctx.closePath()
        ctx.setFillColor(color.withAlphaComponent(0.22).cgColor)
        ctx.fillPath()
        // 折线
        ctx.beginPath()
        ctx.move(to: pts[0])
        for pt in pts.dropFirst() { ctx.addLine(to: pt) }
        ctx.setStrokeColor(color.cgColor)
        ctx.setLineWidth(1.4)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        ctx.strokePath()
        ctx.restoreGState()
    }

    /// 迷你直方图：13 根 2pt 条 + 1pt 间距 = 38pt 整（@2x 整数像素）；低值淡高值实。
    private static func drawHistogram(_ values: [Double], in rect: CGRect, color: NSColor, ctx: CGContext) {
        let v = Array(values.suffix(13))
        guard !v.isEmpty else { return }
        // 右对齐（最新样本贴右缘，与旧版 HStack 尾部对齐一致）。
        var x = rect.maxX - CGFloat(v.count) * 2 - CGFloat(v.count - 1) * 1
        for val in v {
            let f = min(max(val, 0), 1)
            let h = max(2, 15 * CGFloat(f))
            ctx.setFillColor(color.withAlphaComponent(0.4 + 0.6 * f).cgColor)
            ctx.fill(CGRect(x: x, y: rect.minY, width: 2, height: h))
            x += 3
        }
    }

    /// 迷你饼盘：淡底圆盘 0.22 + 实心扇形 + 0.5 外沿。12 点方向顺时针展开。
    private static func drawPie(_ fraction: Double, in rect: CGRect, color: NSColor, ctx: CGContext) {
        let c = CGPoint(x: rect.midX, y: rect.midY)
        let r = rect.width / 2
        ctx.setFillColor(color.withAlphaComponent(0.22).cgColor)
        ctx.fillEllipse(in: rect)
        let f = max(0.02, min(fraction, 1))
        ctx.beginPath()
        ctx.move(to: c)
        // y 轴向上：12 点 = π/2，视觉顺时针 = 角度递减（clockwise: true）。
        ctx.addArc(center: c, radius: r, startAngle: .pi / 2, endAngle: .pi / 2 - 2 * .pi * f, clockwise: true)
        ctx.closePath()
        ctx.setFillColor(color.cgColor)
        ctx.fillPath()
        ctx.setStrokeColor(color.withAlphaComponent(0.5).cgColor)
        ctx.setLineWidth(1)
        ctx.strokeEllipse(in: rect.insetBy(dx: 0.5, dy: 0.5))
    }

    /// 迷你圆环：2pt 底轨 0.38 + 圆帽进度弧。
    private static func drawRing(_ fraction: Double, in rect: CGRect, color: NSColor, ctx: CGContext) {
        let c = CGPoint(x: rect.midX, y: rect.midY)
        let r = (rect.width - 2) / 2
        ctx.setStrokeColor(color.withAlphaComponent(0.38).cgColor)
        ctx.setLineWidth(2)
        ctx.strokeEllipse(in: rect.insetBy(dx: 1, dy: 1))
        let f = max(0.02, min(fraction, 1))
        ctx.beginPath()
        ctx.addArc(center: c, radius: r, startAngle: .pi / 2, endAngle: .pi / 2 - 2 * .pi * f, clockwise: true)
        ctx.setStrokeColor(color.cgColor)
        ctx.setLineWidth(2)
        ctx.setLineCap(.round)
        ctx.strokePath()
        ctx.setLineCap(.butt)
    }

    /// 以 alpha 蒙版方式着色绘制符号（模板色/主色皆可；随目标上下文 scale 光栅化，逐屏精确）。
    private static func drawTinted(_ image: NSImage, in rect: NSRect, color: NSColor, ctx: CGContext) {
        var proposed = rect
        guard let cg = image.cgImage(forProposedRect: &proposed, context: NSGraphicsContext.current, hints: nil) else { return }
        ctx.saveGState()
        ctx.clip(to: rect, mask: cg)
        ctx.setFillColor(color.cgColor)
        ctx.fill(rect)
        ctx.restoreGState()
    }

    // MARK: - 去重缓存（值不变即复用 NSImage；drawingHandler 使重绘本身已极廉价）

    private struct CacheEntry { let signature: String; let image: NSImage }
    private static var renderCache: [String: CacheEntry] = [:]

    private static func cachedImage(id: String, signature: String, _ make: () -> NSImage) -> NSImage {
        if let e = renderCache[id], e.signature == signature { return e.image }
        let img = make()
        renderCache[id] = CacheEntry(signature: signature, image: img)
        return img
    }

    /// 构造去重签名：凡是影响像素的输入都纳入。`history` 仅在真正参与绘制的样式（迷你折线/直方图）
    /// 传入——否则（如饼盘/圆环只吃 fraction，其舍入已体现在 value 里）省略，让值稳定时命中缓存。
    private static func signature(style: MenuBarStyle, colored: Bool, border: Bool,
                                  value: String, history: [Double]? = nil) -> String {
        var s = "\(style.rawValue)|\(colored ? 1 : 0)|\(border ? 1 : 0)|\(value)"
        if let history { s += "|" + histSignature(history) }
        return s
    }

    /// 折线/直方图历史的紧凑签名：量化到整数百分比滤除浮点抖动，只取被绘制的尾部样本。
    /// 纯函数，nonisolated——MenuCombinedSlot.signature（非隔离结构体）也要用。
    nonisolated static func histSignature(_ h: [Double]) -> String {
        h.suffix(30).reduce(into: "") { $0 += String(Int(($1 * 100).rounded())) + "," }
    }
}
