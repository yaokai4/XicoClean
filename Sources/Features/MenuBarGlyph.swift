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
            case .rich:  return compose([.histogram(history, chip: border), .gap(3.5), .value(value)], p)
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
                elems += [.sparkline(history, chip: border), .gap(3.5)]
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
            // 彩色模式独立色相（评审修正）：极光首色与 CPU 同为蓝 227° → 改琥珀。
            let p = palette(colored: colored, tint: [XColor.warning])
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
            // 彩色模式独立色相（评审修正）：面板极光渐变首色与内存同为紫 261°——
            // 菜单栏一眼认指标是彩色模式唯一意义，GPU 改品红拉开 ≥35°。
            let p = palette(colored: colored, tint: [XColor.accentPink])
            switch style {
            case .rich:  return compose([.pie(fraction), .gap(3), .value(value)], p)
            case .ring:  return compose([.ring(fraction), .gap(3), .value(value)], p)
            case .graph: return graphOrIcon("display", value: value, history: history, border: border, p)
            case .valueOnly: return compose([.value(value)], p)
            case .iconValue: return compose([.symbol("display", 12.5, .semibold), .gap(3), .value(value)], p)
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
            switch style {
            case .valueOnly: return compose([.value(pctText)], p)
            case .ring:      return compose([.ring(Double(level) / 100), .gap(3), .value(pctText)], p)
            default:         return compose([.battery(level: level, charging: charging), .gap(3.5), .value(pctText)], p)
            }
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
            return compose([.sparkline(history, chip: border), .gap(3.5), .value(value)], p)
        }
        return compose([.symbol(icon, 12.5, .semibold), .gap(3), .value(value)], p)
    }

    // MARK: - 调色（模板黑 / 单一主色）

    struct GlyphPalette {
        let fg: NSColor
        let template: Bool
    }

    /// colored=false → 模板黑（系统按深浅自动黑白，透明菜单栏下亦由系统兜底）；
    /// colored=true → 单一主色。淡层（轨道/基线/面积）一律由 fg 派生 alpha，天然同源。
    private static func palette(colored: Bool, tint: [Color]) -> GlyphPalette {
        if colored {
            return GlyphPalette(fg: NSColor(tint.first ?? XColor.textPrimary), template: false)
        }
        return GlyphPalette(fg: .black, template: true)
    }

    // MARK: - 元素模型与排版

    /// 字形 = 一串水平元素。宽度先量后画，全部在 18pt 高度内垂直居中。
    /// P10R2 语言（用户钦点方向）：图表回归「软框」——圆角边框即坐标系，但描边与内容
    /// 都要浓而脆（上一版 0.36 描边 + 低透明条被实测嫌「太淡」）；条形用圆角胶囊、
    /// 数字大单位小、电池自绘——这些保留。
    enum Elem {
        case symbol(String, CGFloat, NSFont.Weight)   // SF Symbol：名称 + 磅值 + 字重
        case value(String)                            // 12.5pt 数字 + 9pt 小单位（%/°）共基线
        case smallValue(String)                       // 9pt 圆润等宽半粗（合并项槽位值）
        case netRows(down: String, up: String)        // ▲/▼ 两行速率，数字右对齐齐平
        case sparkline([Double], chip: Bool)          // 渐变面积折线（chip=入软框）
        case histogram([Double], chip: Bool)          // 圆角条直方图（chip=入软框）
        case pie(Double)                              // 14pt 饼盘
        case ring(Double)                             // 13pt 圆环
        case battery(level: Int, charging: Bool)      // 自绘电池壳+电芯（+镂空闪电）
        case separator                                // 合并项分隔发丝线
        case gap(CGFloat)
    }

    static let glyphHeight: CGFloat = 18

    // 直方图排版常量：10 根 2.5pt 圆角条 + 1pt 间距 = 34pt 内容宽（@2x 落整数像素）。
    private static let histBars = 10
    private static let histBarW: CGFloat = 2.5
    private static let histGap: CGFloat = 1
    private static let histWidth: CGFloat = 34
    private static let sparkWidth: CGFloat = 36
    private static let batteryWidth: CGFloat = 22.5   // 20 壳 + 0.75 隙 + 1.75 电极帽
    // 软框：内容左右各 2pt 内边距；16.5pt 高、4.5pt 圆角、1pt 描边。
    private static let chipPad: CGFloat = 2
    private static let chipRadius: CGFloat = 4.5
    private static let chipRect = CGRect(x: 0, y: 0.75, width: 0, height: 16.5)

    /// 数值与单位分离："52%"→("52","%")、"44°"→("44","°")。单位画小一号才精致。
    private static func unitSplit(_ s: String) -> (num: String, unit: String?) {
        if s.count > 1, s.hasSuffix("%") || s.hasSuffix("°") {
            return (String(s.dropLast()), String(s.suffix(1)))
        }
        return (s, nil)
    }

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
            let (num, unit) = unitSplit(s)
            var w = textSize(num, font: valueFont(12.5, weight: .medium)).width
            if let unit { w += textSize(unit, font: valueFont(9, weight: .medium)).width }
            return ceil(w)
        case .smallValue(let s):
            return ceil(textSize(s, font: valueFont(9)).width)
        case .netRows(let down, let up):
            let f = valueFont(9)
            let arrow: CGFloat = 5 + 2   // 实心三角 + 间距
            return ceil(arrow + max(textSize(up, font: f).width, textSize(down, font: f).width))
        case .sparkline(_, let chip): return sparkWidth + (chip ? chipPad * 2 : 0)
        case .histogram(_, let chip): return histWidth + (chip ? chipPad * 2 : 0)
        case .pie:        return 14
        case .ring:       return 15
        case .battery:    return batteryWidth
        case .separator:  return 1
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
            // 合并项槽位间的发丝分隔：1pt 宽、9pt 高、0.18 透明度——存在感刚好到「能分组」。
            ctx.setFillColor(p.fg.withAlphaComponent(0.18).cgColor)
            ctx.fill(CGRect(x: x, y: 4.5, width: 1, height: 9))
        case .symbol(let name, let size, let weight):
            guard let img = symbolNSImage(name, size: size, weight: weight) else { return }
            let s = img.size
            let rect = NSRect(x: x, y: (glyphHeight - s.height) / 2, width: s.width, height: s.height)
            drawTinted(img, in: rect, color: p.fg, ctx: ctx)
        case .value(let s):
            drawValue(s, x: x, centerY: glyphHeight / 2, color: p.fg)
        case .smallValue(let s):
            drawText(s, font: valueFont(9), color: p.fg, x: x, centerY: glyphHeight / 2)
        case .netRows(let down, let up):
            let f = valueFont(9)
            let w = width(of: elem)
            // 两行：上行在上、下行在下；数字右对齐使两行尾缘齐平（表格式的整齐）。
            drawNetRow(text: up, up: true, x: x, elemWidth: w, rowCenterY: 13.1, font: f, color: p.fg, ctx: ctx)
            drawNetRow(text: down, up: false, x: x, elemWidth: w, rowCenterY: 4.9, font: f, color: p.fg, ctx: ctx)
        case .sparkline(let values, let chip):
            if chip {
                // 满高适配（用户钦点）：内容裁剪进内圆角框，面积贴住内壁底、
                // 100% 峰值顶到内壁顶（留 0.75pt 给 1.4pt 线帽不压描边）。
                let box = CGRect(x: x, y: chipRect.minY, width: sparkWidth + chipPad * 2, height: chipRect.height)
                drawChip(box, color: p.fg, ctx: ctx)
                let inner = box.insetBy(dx: 1, dy: 1)
                ctx.saveGState()
                ctx.addPath(CGPath(roundedRect: inner, cornerWidth: chipRadius - 1, cornerHeight: chipRadius - 1, transform: nil))
                ctx.clip()
                drawSparkline(values, in: CGRect(x: box.minX + chipPad, y: inner.minY,
                                                 width: sparkWidth, height: inner.height - 0.75),
                              color: p.fg, baseline: false, ctx: ctx)
                ctx.restoreGState()
            } else {
                drawSparkline(values, in: CGRect(x: x, y: 1.5, width: sparkWidth, height: 14),
                              color: p.fg, baseline: true, ctx: ctx)
            }
        case .histogram(let values, let chip):
            if chip {
                // 满高适配（用户钦点）：柱子基线与边框内壁底齐平（方底）、100% 顶到内壁顶。
                // 与系统电池同法：内容裁剪进内圆角框，角上的端柱由圆角弧自然裁形。
                let box = CGRect(x: x, y: chipRect.minY, width: histWidth + chipPad * 2, height: chipRect.height)
                drawChip(box, color: p.fg, ctx: ctx)
                let inner = box.insetBy(dx: 1, dy: 1)
                ctx.saveGState()
                ctx.addPath(CGPath(roundedRect: inner, cornerWidth: chipRadius - 1, cornerHeight: chipRadius - 1, transform: nil))
                ctx.clip()
                drawHistogram(values, in: CGRect(x: box.minX + chipPad, y: inner.minY,
                                                 width: histWidth, height: inner.height),
                              color: p.fg, track: false, flushBottom: true, ctx: ctx)
                ctx.restoreGState()
            } else {
                drawHistogram(values, in: CGRect(x: x, y: 1.5, width: histWidth, height: 15),
                              color: p.fg, track: true, ctx: ctx)
            }
        case .pie(let f):
            drawPie(f, in: CGRect(x: x + 0.25, y: 2.25, width: 13.5, height: 13.5), color: p.fg, ctx: ctx)
        case .ring(let f):
            drawRing(f, in: CGRect(x: x + 1, y: 2.5, width: 13, height: 13), color: p.fg, ctx: ctx)
        case .battery(let level, let charging):
            drawBattery(level: level, charging: charging, at: x, color: p.fg, ctx: ctx)
        }
    }

    private static func drawText(_ s: String, font: NSFont, color: NSColor, x: CGFloat, centerY: CGFloat) {
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let size = textSize(s, font: font)
        (s as NSString).draw(at: NSPoint(x: x, y: centerY - size.height / 2), withAttributes: attrs)
    }

    /// 数值排版：数字 12.5pt 圆润等宽中黑；%/° 单位 9pt、0.55 透明度、与数字共基线。
    /// 「大数字 + 小单位」是 iStat / 系统状态项的既定语言——等大单位显得笨。
    private static func drawValue(_ s: String, x: CGFloat, centerY: CGFloat, color: NSColor) {
        let (num, unit) = unitSplit(s)
        let nf = valueFont(12.5, weight: .medium)
        let ns = textSize(num, font: nf)
        drawText(num, font: nf, color: color, x: x, centerY: centerY)
        guard let unit else { return }
        let uf = valueFont(9, weight: .medium)
        let us = textSize(unit, font: uf)
        let numBottom = centerY - ns.height / 2
        let uy: CGFloat
        if unit == "°" {
            // 度数符号顶对齐（上标感）——基线对齐会让小圆圈掉到中部。
            uy = numBottom + ns.height - us.height
        } else {
            // % 与数字共基线：非翻转坐标下 draw(at:) 的 y 是行框底 = 基线 + descender（负值）。
            uy = (numBottom - nf.descender) + uf.descender
        }
        (unit as NSString).draw(at: NSPoint(x: x + ns.width, y: uy),
                                withAttributes: [.font: uf, .foregroundColor: color.withAlphaComponent(0.55)])
    }

    /// 网络单行：实心小三角（▲上行 / ▼下行）+ 右对齐数字。
    private static func drawNetRow(text: String, up: Bool, x: CGFloat, elemWidth: CGFloat,
                                   rowCenterY: CGFloat, font: NSFont, color: NSColor, ctx: CGContext) {
        let tw: CGFloat = 5, th: CGFloat = 3.5
        let ty = rowCenterY - th / 2
        ctx.beginPath()
        if up {
            ctx.move(to: CGPoint(x: x, y: ty))
            ctx.addLine(to: CGPoint(x: x + tw, y: ty))
            ctx.addLine(to: CGPoint(x: x + tw / 2, y: ty + th))
        } else {
            ctx.move(to: CGPoint(x: x, y: ty + th))
            ctx.addLine(to: CGPoint(x: x + tw, y: ty + th))
            ctx.addLine(to: CGPoint(x: x + tw / 2, y: ty))
        }
        ctx.closePath()
        ctx.setFillColor(color.withAlphaComponent(0.7).cgColor)
        ctx.fillPath()
        let s = textSize(text, font: font)
        drawText(text, font: font, color: color, x: x + elemWidth - s.width, centerY: rowCenterY)
    }

    /// 软框：圆角边框即图表坐标系。描边 0.55 + 淡底 0.07——比旧版（0.36）浓一档，
    /// 在浅/深菜单栏下都清晰立体（用户实测嫌旧框「太淡」）。
    private static func drawChip(_ rect: CGRect, color: NSColor, ctx: CGContext) {
        ctx.addPath(CGPath(roundedRect: rect, cornerWidth: chipRadius, cornerHeight: chipRadius, transform: nil))
        ctx.setFillColor(color.withAlphaComponent(0.07).cgColor)
        ctx.fillPath()
        // strokeBorder 语义：描边完全在框内 → 内缩半线宽。
        let inset = rect.insetBy(dx: 0.5, dy: 0.5)
        ctx.addPath(CGPath(roundedRect: inset, cornerWidth: chipRadius - 0.5, cornerHeight: chipRadius - 0.5, transform: nil))
        ctx.setStrokeColor(color.withAlphaComponent(0.55).cgColor)
        ctx.setLineWidth(1)
        ctx.strokePath()
    }

    /// 迷你折线（30 样本）：渐变面积（顶浓底透）+ 1.5pt 圆帽折线；裸绘时带基线发丝
    ///（入框时框底即地平线）。
    private static func drawSparkline(_ values: [Double], in rect: CGRect, color: NSColor,
                                      baseline: Bool, ctx: CGContext) {
        let v = Array(values.suffix(30))
        guard v.count > 1 else { return }
        if baseline {
            ctx.setFillColor(color.withAlphaComponent(0.28).cgColor)
            ctx.fill(CGRect(x: rect.minX, y: rect.minY - 1, width: rect.width, height: 1))
        }
        // 首末点向内缩 0.75pt：圆帽端不与软框描边融接（评审修正）。
        let plotX = rect.minX + 0.75, plotW = rect.width - 1.5
        // 满量程映射：100% 就该到 rect 顶（头部余量由调用方的 rect 控制，不再打 9 折）。
        let pts: [CGPoint] = v.enumerated().map { i, val in
            CGPoint(x: plotX + plotW * CGFloat(i) / CGFloat(v.count - 1),
                    y: rect.minY + rect.height * CGFloat(min(max(val, 0), 1)))
        }
        // 渐变面积：单色多一层纵深，模板模式下 alpha 渐变照常生效。
        ctx.saveGState()
        ctx.beginPath()
        ctx.move(to: CGPoint(x: rect.minX, y: rect.minY))
        ctx.addLine(to: pts[0])
        for pt in pts.dropFirst() { ctx.addLine(to: pt) }
        ctx.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        ctx.closePath()
        ctx.clip()
        if let grad = CGGradient(colorsSpace: nil,
                                 colors: [color.withAlphaComponent(0.38).cgColor,
                                          color.withAlphaComponent(0.10).cgColor] as CFArray,
                                 locations: [0, 1]) {
            ctx.drawLinearGradient(grad,
                                   start: CGPoint(x: rect.midX, y: rect.maxY),
                                   end: CGPoint(x: rect.midX, y: rect.minY), options: [])
        }
        ctx.restoreGState()
        // 折线
        ctx.saveGState()
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

    /// 迷你直方图（iStat 语法）：10 根 2.5pt 圆角条右对齐。
    /// flushBottom（入框满高模式）：柱体向下多画一个圆角半径、由外层圆角裁剪压平——
    /// 柱底与边框内壁严丝合缝（方底）、柱顶保留圆角，100% 顶到内壁顶。
    private static func drawHistogram(_ values: [Double], in rect: CGRect, color: NSColor,
                                      track: Bool, flushBottom: Bool = false, ctx: CGContext) {
        let v = Array(values.suffix(histBars))
        guard !v.isEmpty else { return }
        let r = histBarW / 2
        if track {
            var tx = rect.minX
            for _ in 0..<histBars {
                ctx.addPath(CGPath(roundedRect: CGRect(x: tx, y: rect.minY, width: histBarW, height: rect.height),
                                   cornerWidth: r, cornerHeight: r, transform: nil))
                tx += histBarW + histGap
            }
            ctx.setFillColor(color.withAlphaComponent(0.13).cgColor)
            ctx.fillPath()
        }
        // 右对齐（最新样本贴右缘）。条形近实色（0.82 起跳）——低透明条实测「太淡」。
        var x = rect.maxX - CGFloat(v.count) * histBarW - CGFloat(v.count - 1) * histGap
        for val in v {
            let f = min(max(val, 0), 1)
            let h = max(4, rect.height * CGFloat(f))   // 最低 4pt：短刻度而非圆点（评审修正）
            let barY = flushBottom ? rect.minY - r : rect.minY
            let barH = flushBottom ? h + r : h
            ctx.addPath(CGPath(roundedRect: CGRect(x: x, y: barY, width: histBarW, height: barH),
                               cornerWidth: r, cornerHeight: r, transform: nil))
            ctx.setFillColor(color.withAlphaComponent(0.82 + 0.18 * f).cgColor)
            ctx.fillPath()
            x += histBarW + histGap
        }
    }

    /// 迷你饼盘：淡底圆盘 0.18 + 实心扇形 + 0.4 发丝外沿。12 点方向顺时针展开。
    private static func drawPie(_ fraction: Double, in rect: CGRect, color: NSColor, ctx: CGContext) {
        let c = CGPoint(x: rect.midX, y: rect.midY)
        let r = rect.width / 2
        ctx.setFillColor(color.withAlphaComponent(0.24).cgColor)
        ctx.fillEllipse(in: rect)
        let f = max(0.02, min(fraction, 1))
        ctx.beginPath()
        ctx.move(to: c)
        // y 轴向上：12 点 = π/2，视觉顺时针 = 角度递减（clockwise: true）。
        ctx.addArc(center: c, radius: r, startAngle: .pi / 2, endAngle: .pi / 2 - 2 * .pi * f, clockwise: true)
        ctx.closePath()
        ctx.setFillColor(color.cgColor)
        ctx.fillPath()
        ctx.setStrokeColor(color.withAlphaComponent(0.45).cgColor)
        ctx.setLineWidth(1)
        ctx.strokeEllipse(in: rect.insetBy(dx: 0.5, dy: 0.5))
    }

    /// 迷你圆环：2pt 淡轨 0.32 + 圆帽进度弧。
    private static func drawRing(_ fraction: Double, in rect: CGRect, color: NSColor, ctx: CGContext) {
        let c = CGPoint(x: rect.midX, y: rect.midY)
        let r = (rect.width - 2) / 2
        ctx.setStrokeColor(color.withAlphaComponent(0.32).cgColor)
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

    /// 自绘电池（替代 SF Symbol 的粗胖电池形）：20×10 圆角壳 + 电极帽 + 按电量比例的
    /// 圆角电芯；充电时先镂空一圈再实画闪电——芯满时闪电依旧清晰。
    private static func drawBattery(level: Int, charging: Bool, at x: CGFloat, color: NSColor, ctx: CGContext) {
        let body = CGRect(x: x, y: (glyphHeight - 10) / 2, width: 20, height: 10)
        // 壳：1pt 描边完全在框内（内缩半线宽），2.75pt 圆角。
        ctx.addPath(CGPath(roundedRect: body.insetBy(dx: 0.5, dy: 0.5),
                           cornerWidth: 2.75, cornerHeight: 2.75, transform: nil))
        ctx.setStrokeColor(color.withAlphaComponent(0.55).cgColor)
        ctx.setLineWidth(1)
        ctx.strokePath()
        // 电极帽
        ctx.addPath(CGPath(roundedRect: CGRect(x: body.maxX + 0.5, y: body.midY - 2.25, width: 1.75, height: 4.5),
                           cornerWidth: 0.85, cornerHeight: 0.85, transform: nil))
        ctx.setFillColor(color.withAlphaComponent(0.55).cgColor)
        ctx.fillPath()
        // 电芯
        let inset = body.insetBy(dx: 2, dy: 2)
        let w = max(2.5, inset.width * CGFloat(min(max(level, 0), 100)) / 100)
        ctx.addPath(CGPath(roundedRect: CGRect(x: inset.minX, y: inset.minY, width: w, height: inset.height),
                           cornerWidth: 1.1, cornerHeight: 1.1, transform: nil))
        ctx.setFillColor(color.cgColor)
        ctx.fillPath()
        // 充电闪电：镂空 halo + 实画。
        if charging, let bolt = symbolNSImage("bolt.fill", size: 8, weight: .bold) {
            let s = bolt.size
            let r = NSRect(x: body.midX - s.width / 2, y: body.midY - s.height / 2, width: s.width, height: s.height)
            var proposed = r
            if let cg = bolt.cgImage(forProposedRect: &proposed, context: NSGraphicsContext.current, hints: nil) {
                let halo = r.insetBy(dx: -1.4, dy: -1.4)
                ctx.saveGState()
                ctx.clip(to: halo, mask: cg)
                ctx.setBlendMode(.destinationOut)
                ctx.setFillColor(NSColor.black.cgColor)
                ctx.fill(halo)
                ctx.fill(halo)   // 蒙版边缘半透明，双擦逼近全透明缝（评审修正）
                ctx.restoreGState()
                drawTinted(bolt, in: r, color: color, ctx: ctx)
            }
        }
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
