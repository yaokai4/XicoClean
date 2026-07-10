import SwiftUI
import Domain
import DesignSystem
import AppKit

// MARK: - 放射环形图（空间透镜）
//
// 原创设计（非照抄 DaisyDisk）：同心环从内到外表示目录层级，扇段角度 = 占用比例。
// 每个「一级文件夹」拥有一个色相，其所有子孙继承该色相（越深越淡）——一眼看清某块空间
// 属于哪个顶层目录。中心显示当前目录/悬停项的名称与大小；右侧图例列出最大的文件夹。
//
// P2（对标 DaisyDisk 的四个胜负手）：
// 1. 「绽放」钻取——RingSector 全参数 Animatable，drill/pop 时弧在层级间连续形变（宿主在
//    withAnimation 中改变 current，同 id 弧插值、进出弧淡入淡出），视觉可追。
// 2. 「其他」聚合弧——<0.5° 碎片不再丢弃，聚合为中性色弧段，环恢复完整 360°；点击弹清单。
// 3. 色相锚定——钻取后整个子树保持其「扫描根下一级祖先」的色相家族（宿主传 familyHue），
//    同级以家族内明度区分，返回时颜色可追。
// 4. 删除红线只有一条——预检走宿主注入的 denyReason（env.safety），不再自建规则实例。

/// 一个扇段（环上的一段弧）。
private struct Arc: Identifiable {
    /// ForEach 稳定键：真实节点用 node.id；「其他」聚合弧用 父id#other——跨层级 diff 的基石。
    let key: String
    let node: DiskNode
    let depth: Int
    let start: Double   // 角度（度）
    let end: Double
    let color: Color
    /// 「其他」聚合弧：把同环上 <0.5° 的碎片归并展示。仅展示与列表，不可钻取/删除/收集。
    let isOther: Bool
    let otherItems: [DiskNode]
    var id: String { key }
    var mid: Double { (start + end) / 2 }
    var sweep: Double { end - start }
}

/// 环形扇段形状（annular sector）——全参数可动画（绽放钻取的几何基础）。
private struct RingSector: Shape {
    var start: Double   // 度
    var end: Double
    var inner: CGFloat
    var outer: CGFloat

    var animatableData: AnimatablePair<AnimatablePair<Double, Double>, AnimatablePair<CGFloat, CGFloat>> {
        get { AnimatablePair(AnimatablePair(start, end), AnimatablePair(inner, outer)) }
        set {
            start = newValue.first.first
            end = newValue.first.second
            inner = newValue.second.first
            outer = newValue.second.second
        }
    }

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
    /// 点击中心返回上一级（DaisyDisk 式手势）；nil 表示已在顶层。
    let onUp: (() -> Void)?
    /// 就地把某项移到废纸篓（可恢复）。nil 表示宿主未提供该能力。
    let onTrash: ((DiskNode) -> Void)?
    /// 加入收集篮（两段式删除的第一段）。nil 表示宿主未提供。
    let onCollect: ((DiskNode) -> Void)?
    /// 删除红线预检（统一走宿主的 env.safety）——返回拒绝原因，nil = 放行。
    /// 不注入时视图不做预检（宿主 onTrash 内部仍会复检，红线永远兜底）。
    let denyReason: ((URL) -> String?)?
    /// 色相锚定：钻取后当前子树的「扫描根下一级祖先」色相；nil = 正在看扫描根（彩虹分配）。
    let familyHue: Color?

    public init(node: DiskNode,
                onDrill: @escaping (DiskNode) -> Void,
                onUp: (() -> Void)? = nil,
                onTrash: ((DiskNode) -> Void)? = nil,
                onCollect: ((DiskNode) -> Void)? = nil,
                denyReason: ((URL) -> String?)? = nil,
                familyHue: Color? = nil) {
        self.node = node
        self.onDrill = onDrill
        self.onUp = onUp
        self.onTrash = onTrash
        self.onCollect = onCollect
        self.denyReason = denyReason
        self.familyHue = familyHue
    }

    @State private var hovered: DiskNode?
    @State private var centerHover = false
    @State private var appeared = false
    @State private var pendingTrash: DiskNode?
    @State private var trashDeny: String?
    @State private var otherPopoverKey: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// 扇段几何缓存：只在当前目录（node.id）+ 家族色相变化时重算一次。悬停仅改变 @State `hovered`
    /// 触发 body 重算，绝不应连带重建整棵弧树——高亮由每段派生态驱动（isHot/dimmed），
    /// 与几何解耦。用引用类型持有，读取即命中、按 node.id 失效，规避每次 hover 的 O(n) 重建。
    private final class ArcCache { var id: UUID?; var themeID: String?; var arcs: [Arc] = [] }
    @State private var arcCache = ArcCache()

    private func cachedArcs() -> [Arc] {
        // 颜色烘进弧数据，故缓存键除 node.id 外还含主题 id——切主题即失效重建
        // （P1 后不再整树重建，缓存必须自己感知主题）。
        let theme = XThemeStore.shared.current.id
        if arcCache.id != node.id || arcCache.themeID != theme {
            arcCache.id = node.id
            arcCache.themeID = theme
            arcCache.arcs = buildArcs()
        }
        return arcCache.arcs
    }

    private let maxDepth = 4

    /// 家族模式下同级的明度阶（烘进 Color，子孙自然继承）——让「同属一族」与「彼此有别」并存。
    /// 动态范围刻意拉大（1.0 → 0.42）：家族色相是「锚」，同级可辨靠明度差，弱对比读起来是一坨。
    private static let familyShades: [Double] = [1.0, 0.55, 0.82, 0.42, 0.70, 0.50]

    /// 顶层调色：扫描根 = 主题色阶彩虹；钻取后 = 家族色相 × 明度阶（色相锚定，返回时颜色可追）。
    private func paletteColor(_ i: Int) -> Color {
        if let familyHue {
            return familyHue.opacity(Self.familyShades[((i % Self.familyShades.count) + Self.familyShades.count) % Self.familyShades.count])
        }
        return XColor.ring(i)
    }

    public var body: some View {
        HStack(alignment: .center, spacing: XSpacing.xl) {
            GeometryReader { geo in
                let side = min(geo.size.width, geo.size.height)
                ring(arcs: cachedArcs(), side: side)
                    .frame(width: geo.size.width, height: geo.size.height)
            }
            .frame(minWidth: 300)

            legend
                .frame(width: 320)
                .frame(maxHeight: .infinity, alignment: .top)   // 撑满高度，让图例列表可滚动展开
        }
        .padding(XSpacing.l)
        .onChange(of: node.id) { hovered = nil; otherPopoverKey = nil }   // 换层后清掉陈旧悬停/浮层
        .confirmationDialog(xLoc("移到废纸篓"),
                            isPresented: Binding(get: { pendingTrash != nil },
                                                 set: { if !$0 { pendingTrash = nil } }),
                            presenting: pendingTrash) { item in
            Button(xLoc("移到废纸篓"), role: .destructive) { onTrash?(item); pendingTrash = nil }
            Button(xLoc("取消"), role: .cancel) { pendingTrash = nil }
        } message: { item in
            Text(xLocF("将把「%@」移到废纸篓，之后可从废纸篓恢复。", item.name))
        }
        .alert(xLoc("无法移到废纸篓"),
               isPresented: Binding(get: { trashDeny != nil }, set: { if !$0 { trashDeny = nil } })) {
            Button(xLoc("好"), role: .cancel) { trashDeny = nil }
        } message: {
            Text(trashDeny ?? "")
        }
    }

    /// 右键「移到废纸篓」入口：先走**全应用统一的删除红线**（宿主注入的 env.safety）自检，
    /// 命中即拒绝并说明原因；放行才弹出二次确认。真正的回收动作由宿主的 onTrash 复检后执行。
    private func requestTrash(_ item: DiskNode) {
        if let reason = denyReason?(item.url) {
            trashDeny = reason
        } else {
            pendingTrash = item
        }
    }

    // MARK: 环形图

    private func ring(arcs: [Arc], side: CGFloat) -> some View {
        let center = side / 2
        let hole = side * 0.20            // 中心圆半径
        let ringW = (center - hole) / CGFloat(maxDepth)
        return ZStack {
            ForEach(arcs) { arc in
                arcButton(arc, hole: hole, ringW: ringW)
            }
            centerLabel(hole: hole)
        }
        .frame(width: side, height: side)
        .scaleEffect(appeared || reduceMotion ? 1 : 0.94)
        .opacity(appeared || reduceMotion ? 1 : 0)
        .onAppear { withAnimation(XMotion.settle) { appeared = true } }
        .frame(maxWidth: .infinity, maxHeight: .infinity)  // 居中
    }

    @ViewBuilder
    private func arcButton(_ arc: Arc, hole: CGFloat, ringW: CGFloat) -> some View {
        let inner = hole + CGFloat(arc.depth - 1) * ringW
        let outer = inner + ringW - 1.5   // 环间留 1.5pt 缝
        let isHot = hovered?.id == arc.node.id && !arc.isOther
        // 同族高亮：悬停某段时，它与它的祖先/子孙（同色相路径）保持满亮，其余变淡——
        // 一眼看清「这块空间从哪来、往哪去」。「其他」聚合弧不参与家族判定。
        let dimmed = hovered != nil && !isHot && (arc.isOther || !isRelated(arc.node, to: hovered))
        let drillable = !arc.isOther && arc.node.isDirectory && !arc.node.children.isEmpty
        // 每段弧封装为 .plain Button：可被 Tab 聚焦、空格/回车触发钻取，并向 VoiceOver
        // 报出「名称·大小·占比」——键盘与读屏用户获得与鼠标悬停/点击等价的操作路径。
        Button {
            if arc.isOther {
                otherPopoverKey = arc.key
            } else if drillable {
                onDrill(arc.node)
            }
        } label: {
            RingSector(start: arc.start + 0.25, end: arc.end - 0.25, inner: inner, outer: outer)
                .fill(arc.color.opacity(isHot ? 1 : depthOpacity(arc.depth) * (dimmed ? 0.35 : 1)))
                .overlay(
                    RingSector(start: arc.start + 0.25, end: arc.end - 0.25, inner: inner, outer: outer)
                        .stroke(Color.white.opacity(isHot ? 0.9 : 0.0), lineWidth: 1.5)
                )
                .shadow(color: isHot ? arc.color.opacity(0.55) : .clear, radius: isHot ? 10 : 0)
        }
        .buttonStyle(.plain)
        .contentShape(RingSector(start: arc.start, end: arc.end, inner: inner, outer: outer))
        .onHover { if $0 { hovered = arc.node } else if hovered?.id == arc.node.id { hovered = nil } }
        .help(arc.isOther ? xLocF("其他 %d 项", arc.otherItems.count) + " · \(arc.node.size.formattedBytes)"
                          : "\(arc.node.name) · \(arc.node.size.formattedBytes)")
        .animation(XMotion.hover, value: hovered?.id)
        .accessibilityLabel(arcLabel(arc))
        .accessibilityAddTraits(.isButton)
        .transition(.opacity)   // 绽放时进出层淡入淡出，几何形变由 RingSector animatableData 插值
        .popover(isPresented: Binding(get: { otherPopoverKey == arc.key },
                                      set: { if !$0 { otherPopoverKey = nil } })) {
            otherList(arc)
        }
        .contextMenu {
            if !arc.isOther {
                Button(xLoc("在 Finder 中显示")) { NSWorkspace.shared.activateFileViewerSelecting([arc.node.url]) }
                if onCollect != nil, !arc.node.isAggregate {
                    Button { onCollect?(arc.node) } label: {
                        Label(xLoc("加入收集篮"), systemImage: "basket")
                    }
                }
                if onTrash != nil, !arc.node.isAggregate {
                    Divider()
                    Button(role: .destructive) { requestTrash(arc.node) } label: {
                        Label(xLoc("移到废纸篓"), systemImage: "trash")
                    }
                }
            }
        }
    }

    /// 「其他」聚合弧的明细浮层：这些是真实的小文件/目录，仅展示与定位，不提供删除
    /// （体量太小不值得、且逐项风险审查成本高——需要删除时钻到对应目录逐项操作）。
    private func otherList(_ arc: Arc) -> some View {
        let shown = Array(arc.otherItems.prefix(50))
        return VStack(alignment: .leading, spacing: XSpacing.s) {
            HStack {
                Text(xLocF("其他 %d 项", arc.otherItems.count)).font(XFont.headline)
                    .foregroundStyle(XColor.textPrimary)
                Spacer()
                Text(arc.node.size.formattedBytes).font(XFont.mono).foregroundStyle(XColor.textSecondary)
            }
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(shown) { item in
                        HStack(spacing: XSpacing.s) {
                            Image(systemName: item.isDirectory ? "folder.fill" : "doc")
                                .font(XFont.nano).foregroundStyle(XColor.textTertiary)
                            Text(item.name).font(XFont.body).foregroundStyle(XColor.textPrimary)
                                .lineLimit(1).truncationMode(.middle)
                            Spacer()
                            Text(item.size.formattedBytes).font(XFont.caption)
                                .foregroundStyle(XColor.textSecondary).monospacedDigit()
                        }
                        .contentShape(Rectangle())
                        .contextMenu {
                            Button(xLoc("在 Finder 中显示")) {
                                NSWorkspace.shared.activateFileViewerSelecting([item.url])
                            }
                        }
                    }
                    if arc.otherItems.count > shown.count {
                        Text(xLocF("+ 另外 %d 项", arc.otherItems.count - shown.count))
                            .font(XFont.caption).foregroundStyle(XColor.textTertiary)
                    }
                }
            }
            .frame(maxHeight: 300)
        }
        .padding(XSpacing.l)
        .frame(width: 340)
    }

    /// VoiceOver 标签：名称 + 大小 + 占当前目录比例。复用既有「%@，%@」文案键，
    /// 占比以中性数字（如 " · 45%"）追加，不新增本地化键。
    private func arcLabel(_ arc: Arc) -> String {
        if arc.isOther {
            return xLocF("其他 %d 项", arc.otherItems.count) + "，\(arc.node.size.formattedBytes)"
        }
        let base = xLocF("%@，%@", arc.node.name, arc.node.size.formattedBytes)
        guard node.size > 0 else { return base }
        let pct = Int((Double(arc.node.size) / Double(node.size) * 100).rounded())
        return "\(base) · \(pct)%"
    }

    /// 判断两个节点是否同一路径族（祖先或子孙关系）——用 URL 前缀近似，无需回溯树。
    private func isRelated(_ a: DiskNode, to b: DiskNode?) -> Bool {
        guard let b else { return false }
        let pa = a.url.path, pb = b.url.path
        return pa.hasPrefix(pb + "/") || pb.hasPrefix(pa + "/") || pa == pb
    }

    private func centerLabel(hole: CGFloat) -> some View {
        let shown = hovered ?? node
        // 悬停子目录时，中心显示其占父目录的比例（图标 + %，无需本地化文案）。
        let sharePct: Int? = {
            guard let h = hovered, h.id != node.id, node.size > 0 else { return nil }
            return Int((Double(h.size) / Double(node.size) * 100).rounded())
        }()
        let canGoUp = onUp != nil && hovered == nil
        // 中心盘也是一个 .plain Button：可被 Tab 聚焦、空格/回车触发「返回上一级」，
        // 与鼠标点击中心等价——键盘/读屏用户不再无路可上。
        return Button {
            onUp?()
        } label: {
        ZStack {
            // 中心盘：给数字一块「表盘」底座，悬停上一级时点亮
            Circle().fill(XColor.surface.opacity(centerHover && canGoUp ? 0.9 : 0.5))
            Circle().stroke(XColor.hairline, lineWidth: 1)
            VStack(spacing: 3) {
                if centerHover && canGoUp {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: max(18, hole * 0.3), weight: .semibold))
                        .foregroundStyle(XColor.brand)
                    Text(xLoc("返回上一级")).font(XFont.captionEmphasis).foregroundStyle(XColor.brand)
                } else {
                    Text(shown.size.formattedBytes)
                        .font(.system(size: max(15, hole * 0.30), weight: .bold, design: .rounded))
                        .foregroundStyle(XColor.textPrimary)
                        .monospacedDigit()
                        .lineLimit(1).minimumScaleFactor(0.55)
                        .contentTransition(.numericText())
                    Text(xLoc(shown.name))
                        .font(XFont.caption).foregroundStyle(XColor.textSecondary)
                        .lineLimit(1).truncationMode(.middle)
                        .frame(maxWidth: hole * 1.6)
                    if let pct = sharePct {
                        HStack(spacing: 3) {
                            Image(systemName: "chart.pie.fill").font(XFont.nano)
                            Text("\(pct)%").font(XFont.captionEmphasis).monospacedDigit()
                        }
                        .foregroundStyle(XColor.brand)
                        .contentTransition(.numericText())
                    }
                }
            }
            .padding(hole * 0.10)
        }
        .frame(width: hole * 2 - 6, height: hole * 2 - 6)
        }
        .buttonStyle(.plain)
        .contentShape(Circle())
        .onHover { centerHover = $0 }
        .animation(XMotion.hover, value: centerHover)
        .accessibilityLabel(canGoUp ? xLoc("返回上一级") : xLoc(shown.name))
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
                        legendRow(child, color: paletteColor(i),
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
                RoundedRectangle(cornerRadius: XRadius.micro).fill(color).frame(width: 11, height: 11)
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Image(systemName: child.isDirectory ? "folder.fill" : "doc")
                            .font(XFont.nano).foregroundStyle(XColor.textTertiary)
                        Text(xLoc(child.name)).font(XFont.bodyEmphasis).foregroundStyle(XColor.textPrimary)
                            .lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Text("\(Int((fraction * 100).rounded()))%")
                            .font(XFont.caption).foregroundStyle(isHot ? color : XColor.textTertiary).monospacedDigit()
                        Text(child.size.formattedBytes).font(XFont.caption).foregroundStyle(XColor.textSecondary).monospacedDigit()
                            .frame(minWidth: 64, alignment: .trailing)
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
        .accessibilityLabel(xLocF("%@，%@", child.name, child.size.formattedBytes))
        .draggable(child.url)   // 拖进收集篮（basket 是 dropDestination）
        .contextMenu {
            Button(xLoc("在 Finder 中显示")) { NSWorkspace.shared.activateFileViewerSelecting([child.url]) }
            // 合成聚合桶（「其他」）不给收集/删除入口——复用父目录 URL，删之即误删整个文件夹（审计 P0）。
            if onCollect != nil, !child.isAggregate {
                Button { onCollect?(child) } label: {
                    Label(xLoc("加入收集篮"), systemImage: "basket")
                }
            }
            if onTrash != nil, !child.isAggregate {
                Divider()
                Button(role: .destructive) { requestTrash(child) } label: {
                    Label(xLoc("移到废纸篓"), systemImage: "trash")
                }
            }
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
            // <0.5° 碎片不再直接丢弃：聚合成一段「其他」中性弧，环恢复完整 360°（P2·D2）。
            // 子项按大小降序，跨过阈值后其余全部低于阈值——碎片天然连续排在尾部。
            var otherSpan: Double = 0
            var otherItems: [DiskNode] = []
            var otherBytes: Int64 = 0
            for (i, child) in n.children.sorted(by: { $0.size > $1.size }).enumerated() {
                let childSpan = span * Double(child.size) / Double(total)
                if childSpan < 0.5 {
                    otherSpan += childSpan
                    otherItems.append(child)
                    otherBytes += child.size
                    continue
                }
                let cStart = a, cEnd = a + childSpan
                let color = hue ?? paletteColor(i)
                out.append(Arc(key: child.id.uuidString, node: child, depth: depth,
                               start: cStart, end: cEnd, color: color,
                               isOther: false, otherItems: []))
                if child.isDirectory && !child.children.isEmpty {
                    recurse(child, depth: depth + 1, start: cStart, end: cEnd, hue: color)
                }
                a = cEnd
            }
            if otherSpan > 0.05, !otherItems.isEmpty {
                // 聚合弧的「载体节点」用一个只承载几何/大小的合成节点视图态——绝不参与删除
                // （isOther 弧在 UI 上无删除/收集入口，点击只弹明细清单）。
                let carrier = DiskNode(url: n.url, name: xLoc("其他"), isDirectory: false,
                                       size: otherBytes, isAggregate: true)
                out.append(Arc(key: n.id.uuidString + "#other", node: carrier, depth: depth,
                               start: a, end: a + otherSpan, color: XColor.idle,
                               isOther: true, otherItems: otherItems))
            }
        }
        // 初始 hue 传 nil：顶层分配一律走 paletteColor——家族模式下它返回「家族色相 × 明度阶」
        // （同级可辨），扫描根下它返回主题色阶彩虹；子孙经 hue 参数继承烘好的颜色。
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
