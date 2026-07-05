import SwiftUI
import Domain
import DesignSystem
import AppKit

// MARK: - 放射环形图（空间透镜）
//
// 原创设计（非照抄 DaisyDisk）：同心环从内到外表示目录层级，扇段角度 = 占用比例。
// 每个「一级文件夹」拥有一个色相，其所有子孙继承该色相（越深越淡）——一眼看清某块空间
// 属于哪个顶层目录。中心显示当前目录/悬停项的名称与大小；右侧图例列出最大的文件夹。

/// 一个扇段（环上的一段弧）。
private struct Arc: Identifiable {
    let id: UUID
    let node: DiskNode
    let depth: Int
    let start: Double   // 角度（度）
    let end: Double
    let color: Color
    var mid: Double { (start + end) / 2 }
    var sweep: Double { end - start }
}

/// 环形扇段形状（annular sector）。
private struct RingSector: Shape {
    var start: Double   // 度
    var end: Double
    var inner: CGFloat
    var outer: CGFloat
    func path(in rect: CGRect) -> Path {
        let c = CGPoint(x: rect.midX, y: rect.midY)
        let a0 = Angle(degrees: start - 90)   // -90：12 点方向起始
        let a1 = Angle(degrees: end - 90)
        var p = Path()
        p.addArc(center: c, radius: outer, startAngle: a0, endAngle: a1, clockwise: false)
        p.addArc(center: c, radius: inner, startAngle: a1, endAngle: a0, clockwise: true)
        p.closeSubpath()
        return p
    }
}

public struct SunburstView: View {
    let node: DiskNode
    let onDrill: (DiskNode) -> Void

    public init(node: DiskNode, onDrill: @escaping (DiskNode) -> Void) {
        self.node = node
        self.onDrill = onDrill
    }

    @State private var hovered: DiskNode?

    // 珠宝色相盘：每个一级文件夹分一个色相，子孙继承。
    private static let palette: [Color] = [
        Color(nsColor: NSColor(hex: 0x6E86E0)),  // 长春花蓝
        Color(nsColor: NSColor(hex: 0x9A78D8)),  // 薰衣草紫
        Color(nsColor: NSColor(hex: 0xC06BB8)),  // 兰
        Color(nsColor: NSColor(hex: 0xD772A2)),  // 玫
        Color(nsColor: NSColor(hex: 0x46B3AC)),  // 薄荷
        Color(nsColor: NSColor(hex: 0x5B9BD8)),  // 天青
        Color(nsColor: NSColor(hex: 0xE0965A)),  // 暖橙
        Color(nsColor: NSColor(hex: 0x7FB86B)),  // 苔绿
    ]

    private let maxDepth = 4

    public var body: some View {
        HStack(alignment: .center, spacing: XSpacing.xl) {
            GeometryReader { geo in
                let side = min(geo.size.width, geo.size.height)
                ring(arcs: buildArcs(), side: side)
                    .frame(width: geo.size.width, height: geo.size.height)
            }
            .frame(minWidth: 300)

            legend
                .frame(width: 320)
                .frame(maxHeight: .infinity, alignment: .top)   // 撑满高度，让图例列表可滚动展开
        }
        .padding(XSpacing.l)
    }

    // MARK: 环形图

    private func ring(arcs: [Arc], side: CGFloat) -> some View {
        let center = side / 2
        let hole = side * 0.20            // 中心圆半径
        let ringW = (center - hole) / CGFloat(maxDepth)
        return ZStack {
            ForEach(arcs) { arc in
                let inner = hole + CGFloat(arc.depth - 1) * ringW
                let outer = inner + ringW - 1.5   // 环间留 1.5pt 缝
                let isHot = hovered?.id == arc.node.id
                RingSector(start: arc.start + 0.25, end: arc.end - 0.25, inner: inner, outer: outer)
                    .fill(arc.color.opacity(isHot ? 1 : depthOpacity(arc.depth)))
                    .overlay(
                        RingSector(start: arc.start + 0.25, end: arc.end - 0.25, inner: inner, outer: outer)
                            .stroke(Color.white.opacity(isHot ? 0.9 : 0.0), lineWidth: 1.5)
                    )
                    .contentShape(RingSector(start: arc.start, end: arc.end, inner: inner, outer: outer))
                    .onHover { if $0 { hovered = arc.node } else if hovered?.id == arc.node.id { hovered = nil } }
                    .onTapGesture { if arc.node.isDirectory, !arc.node.children.isEmpty { onDrill(arc.node) } }
                    .help("\(arc.node.name) · \(arc.node.size.formattedBytes)")
            }
            centerLabel(hole: hole)
        }
        .frame(width: side, height: side)
        .frame(maxWidth: .infinity, maxHeight: .infinity)  // 居中
    }

    private func centerLabel(hole: CGFloat) -> some View {
        let shown = hovered ?? node
        // 悬停子目录时，中心显示其占父目录的比例（图标 + %，无需本地化文案）。
        let sharePct: Int? = {
            guard let h = hovered, h.id != node.id, node.size > 0 else { return nil }
            return Int((Double(h.size) / Double(node.size) * 100).rounded())
        }()
        return VStack(spacing: 3) {
            Text(shown.size.formattedBytes)
                .font(.system(size: max(15, hole * 0.34), weight: .bold, design: .rounded))
                .foregroundStyle(XColor.textPrimary)
                .monospacedDigit()
            Text(xLoc(shown.name))
                .font(XFont.caption).foregroundStyle(XColor.textSecondary)
                .lineLimit(1).truncationMode(.middle)
                .frame(maxWidth: hole * 1.7)
            if let pct = sharePct {
                HStack(spacing: 3) {
                    Image(systemName: "chart.pie.fill").font(.system(size: 9))
                    Text("\(pct)%").font(XFont.captionEmphasis).monospacedDigit()
                }
                .foregroundStyle(XColor.brand)
                .contentTransition(.numericText())
            }
        }
    }

    // MARK: 图例（最大的文件夹）

    private var legend: some View {
        let sorted = node.children.sorted { $0.size > $1.size }
        let total = max(node.size, 1)
        return VStack(alignment: .leading, spacing: XSpacing.s) {
            HStack {
                Text(xLoc(node.name)).font(XFont.headline).foregroundStyle(XColor.textPrimary)
                    .lineLimit(1).truncationMode(.middle)
                Spacer()
                Text(node.size.formattedBytes).font(XFont.mono).foregroundStyle(XColor.textSecondary)
            }
            Text(xLocF("%d 个项目 · 点击色块或环钻取", node.children.count))
                .font(XFont.caption).foregroundStyle(XColor.textTertiary)
            Divider().padding(.vertical, 2)
            // 全部条目可滚动（不再截断到 14 项）——大目录也能逐项审阅。
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(sorted.enumerated()), id: \.element.id) { i, child in
                        legendRow(child, color: Self.palette[i % Self.palette.count],
                                  fraction: Double(child.size) / Double(total))
                    }
                }
            }
        }
    }

    private func legendRow(_ child: DiskNode, color: Color, fraction: Double) -> some View {
        let isHot = hovered?.id == child.id
        let drillable = child.isDirectory && !child.children.isEmpty
        return Button {
            if drillable { onDrill(child) }
        } label: {
            HStack(spacing: XSpacing.s) {
                RoundedRectangle(cornerRadius: 3).fill(color).frame(width: 11, height: 11)
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Image(systemName: child.isDirectory ? "folder.fill" : "doc")
                            .font(.system(size: 9)).foregroundStyle(XColor.textTertiary)
                        Text(xLoc(child.name)).font(XFont.bodyEmphasis).foregroundStyle(XColor.textPrimary)
                            .lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Text(child.size.formattedBytes).font(XFont.caption).foregroundStyle(XColor.textSecondary).monospacedDigit()
                    }
                    // 占比条
                    GeometryReader { g in
                        ZStack(alignment: .leading) {
                            Capsule().fill(XColor.surfaceAlt)
                            Capsule().fill(color).frame(width: max(3, g.size.width * CGFloat(min(fraction, 1))))
                        }
                    }
                    .frame(height: 4)
                }
            }
            .padding(.vertical, 5).padding(.horizontal, XSpacing.s)
            .background(RoundedRectangle(cornerRadius: XRadius.control, style: .continuous)
                .fill(isHot ? XColor.surfaceHover : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { if $0 { hovered = child } else if hovered?.id == child.id { hovered = nil } }
        .contextMenu {
            Button(xLoc("在 Finder 中显示")) { NSWorkspace.shared.activateFileViewerSelecting([child.url]) }
        }
    }

    // MARK: 构建扇段

    private func buildArcs() -> [Arc] {
        var out: [Arc] = []
        func recurse(_ n: DiskNode, depth: Int, start: Double, end: Double, hue: Color?) {
            guard depth <= maxDepth else { return }
            let total = max(n.size, 1)
            let span = end - start
            var a = start
            for (i, child) in n.children.sorted(by: { $0.size > $1.size }).enumerated() {
                let childSpan = span * Double(child.size) / Double(total)
                if childSpan < 0.5 { continue }              // 跳过 <0.5° 的碎片
                let cStart = a, cEnd = a + childSpan
                let color = hue ?? Self.palette[i % Self.palette.count]
                out.append(Arc(id: child.id, node: child, depth: depth, start: cStart, end: cEnd, color: color))
                if child.isDirectory && !child.children.isEmpty {
                    recurse(child, depth: depth + 1, start: cStart, end: cEnd, hue: color)
                }
                a = cEnd
            }
        }
        recurse(node, depth: 1, start: 0, end: 360, hue: nil)
        return out
    }

    private func depthOpacity(_ depth: Int) -> Double {
        switch depth {
        case 1: return 0.95
        case 2: return 0.82
        case 3: return 0.70
        default: return 0.58
        }
    }
}
