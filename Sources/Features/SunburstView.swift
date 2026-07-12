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

extension View {
    /// 拖拽守卫：合成聚合节点（「其他」/「其他文件」/「隐藏空间」）复用父目录/卷根 URL，
    /// 拖进收集篮会被 findNode 解析成**真实的父目录乃至扫描根**——等于把整个文件夹装进删除篮
    /// （审计 P0 wrong-target deletion 的拖拽变体）。聚合节点一律不可拖。
    @ViewBuilder
    func draggableUnlessAggregate(_ node: DiskNode) -> some View {
        if node.isAggregate {
            self
        } else {
            self.draggable(node.url)
        }
    }
}

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
    /// 当前选中项（宿主状态）：环段与图例行高亮、中心显示其详情、图例顶部出详情卡。
    let selected: DiskNode?
    /// 单击激活（宿主决定语义：未选中 → 选中；已选中的目录 → 进入）。文件与目录一视同仁。
    let onActivate: (DiskNode) -> Void
    /// 点击中心返回上一级（DaisyDisk 式手势）；nil 表示已在顶层。
    let onUp: (() -> Void)?
    /// 取消选中（点中心/按 ESC）。nil = 宿主无选中状态。
    let onDeselect: (() -> Void)?
    /// 就地把某项移到废纸篓（可恢复）。nil 表示宿主未提供该能力。
    let onTrash: ((DiskNode) -> Void)?
    /// 加入收集篮（两段式删除的第一段）。nil 表示宿主未提供。
    let onCollect: ((DiskNode) -> Void)?
    /// 删除红线预检（统一走宿主的 env.safety）——返回拒绝原因，nil = 放行。
    /// 不注入时视图不做预检（宿主 onTrash 内部仍会复检，红线永远兜底）。
    let denyReason: ((URL) -> String?)?
    /// 色相锚定：钻取后当前子树的「扫描根下一级祖先」色相；nil = 正在看扫描根（彩虹分配）。
    let familyHue: Color?
    /// 卷可用字节（P1-7 可用空间楔形）：仅在「看整卷根」时传入，环追加一段低饱和可用楔形，
    /// 中心与图例同步显示可用容量——「还剩多少」与「谁占掉了」同屏（DaisyDisk 口径）。
    let freeBytes: Int64?
    /// 跨树搜索（P2-11）：非空时命中名保持满亮、其余变暗，图例只列命中项。
    let searchQuery: String
    /// 树结构版本号（宿主在嫁接/剪枝/回接后自增）：DiskNode 是引用类型、就地改 children 时
    /// node.id 不变——没有它 ArcCache 会拿陈旧几何当缓存命中，环上显示过期子树（多层下极显眼）。
    let revision: Int
    /// 账本节点动作（P0-d）：管理本地快照（tmutil 独立通道）/ 引导开启完全磁盘访问。
    let onManageSnapshots: (() -> Void)?
    let onOpenFDA: (() -> Void)?

    public init(node: DiskNode,
                selected: DiskNode? = nil,
                onActivate: @escaping (DiskNode) -> Void,
                onUp: (() -> Void)? = nil,
                onDeselect: (() -> Void)? = nil,
                onTrash: ((DiskNode) -> Void)? = nil,
                onCollect: ((DiskNode) -> Void)? = nil,
                denyReason: ((URL) -> String?)? = nil,
                familyHue: Color? = nil,
                freeBytes: Int64? = nil,
                searchQuery: String = "",
                revision: Int = 0,
                onManageSnapshots: (() -> Void)? = nil,
                onOpenFDA: (() -> Void)? = nil) {
        self.node = node
        self.selected = selected
        self.onActivate = onActivate
        self.onUp = onUp
        self.onDeselect = onDeselect
        self.onTrash = onTrash
        self.onCollect = onCollect
        self.denyReason = denyReason
        self.familyHue = familyHue
        self.freeBytes = freeBytes
        self.searchQuery = searchQuery
        self.revision = revision
        self.onManageSnapshots = onManageSnapshots
        self.onOpenFDA = onOpenFDA
    }

    @State private var hovered: DiskNode?
    @State private var centerHover = false
    @State private var appeared = false
    @State private var pendingTrash: DiskNode?
    @State private var trashDeny: String?
    @State private var otherPopoverKey: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// 扇段几何缓存：只在当前目录（node.id）+ 家族色相/可用楔形变化时重算一次。悬停仅改变 @State
    /// `hovered` 触发 body 重算，绝不应连带重建整棵弧树——高亮由每段派生态驱动（isHot/dimmed），
    /// 与几何解耦。用引用类型持有，读取即命中、按 node.id 失效，规避每次 hover 的 O(n) 重建。
    private final class ArcCache {
        var id: UUID?; var themeID: String?; var free: Int64?; var rev: Int?; var arcs: [Arc] = []
    }
    @State private var arcCache = ArcCache()

    private func cachedArcs() -> [Arc] {
        // 颜色烘进弧数据，故缓存键除 node.id 外还含主题 id——切主题即失效重建
        // （P1 后不再整树重建，缓存必须自己感知主题）。可用楔形改变几何，同为缓存键。
        // revision：宿主细化嫁接/删除剪枝/撤销回接都是就地改 children（node.id 不变），
        // 必须凭版本号失效，否则环形图停在过期子树上。
        let theme = XThemeStore.shared.current.id
        if arcCache.id != node.id || arcCache.themeID != theme || arcCache.free != freeBytes
            || arcCache.rev != revision {
            arcCache.id = node.id
            arcCache.themeID = theme
            arcCache.free = freeBytes
            arcCache.rev = revision
            arcCache.arcs = buildArcs()
        }
        return arcCache.arcs
    }

    /// 显示深度 = 5（2026-07 二次拍板：恢复 DaisyDisk 式多层放射）：内环 = 当前目录的
    /// 直接子项（与右侧图例 1:1），子孙沿外环逐层放射、环带越外越薄——「当前目录里
    /// 每一块空间从哪来」一眼可追。上一版单层甜甜圈被用户否决（“怎么变成圆圈了”）。
    /// 可读性三道闸（吸收此前五层嵌套「嫌乱嫌丑」的教训）：
    ///   1. 环段内嵌文字只画第 1 层——外环绝不出现挤在一起的小字；
    ///   2. 深层 <0.5° 碎片直接留白（DaisyDisk 亦然），外圈不会连成灰盘；
    ///   3. 「其他」聚合弧只在第 1 层出现，与图例口径一致。
    /// 注意：这只是**显示**深度；扫描仍是全深度精确统计（DiskTreeScanner 不变）。
    private let maxDepth = 5

    /// 各环带权重（内 → 外递减，DaisyDisk 式「内厚外薄」）：第 1 层是主角承载文字，
    /// 外层只负责形状轮廓——放射的「尖刺」感来自薄外环。
    private static let ringWeights: [CGFloat] = [1.30, 1.0, 0.78, 0.60, 0.46]

    /// 依权重预算各环的（内径，外径）。
    private static func ringRadii(hole: CGFloat, center: CGFloat) -> [(inner: CGFloat, outer: CGFloat)] {
        let unit = (center - hole) / ringWeights.reduce(0, +)
        var radii: [(CGFloat, CGFloat)] = []
        var inner = hole
        for w in ringWeights {
            let outer = inner + unit * w
            radii.append((inner, outer))
            inner = outer
        }
        return radii
    }

    /// 环形图专用高饱和调色板（深浅色同值）：DaisyDisk 式鲜明色轮——
    /// 主题 ring 色阶是为「背景上的点缀」调的淡彩，铺满整环会发灰发水；数据图要的是果敢的色相。
    /// docs/16 P2：**随主题走**——暖调主题（warmLuxe/jewel）给暖倾向色轮，
    /// 切主题时透镜与全局气质一致（arcCache 以 themeID 为键，切换即失效重建）。
    static var vividPalette: [Color] {
        XThemeStore.shared.current.lensPalette ?? defaultVividPalette
    }

    private static let defaultVividPalette: [Color] = [
        Color(red: 0.24, green: 0.48, blue: 0.95),   // 蓝
        Color(red: 0.55, green: 0.36, blue: 0.96),   // 紫
        Color(red: 0.91, green: 0.32, blue: 0.49),   // 玫红
        Color(red: 0.09, green: 0.72, blue: 0.65),   // 青
        Color(red: 0.96, green: 0.62, blue: 0.04),   // 琥珀
        Color(red: 0.13, green: 0.73, blue: 0.27),   // 绿
        Color(red: 0.85, green: 0.27, blue: 0.94),   // 品红
        Color(red: 0.40, green: 0.40, blue: 0.95),   // 靛
    ]

    /// 家族模式下同级的明度阶（烘进 Color，子孙自然继承）——让「同属一族」与「彼此有别」并存。
    /// 动态范围刻意拉大（1.0 → 0.42）：家族色相是「锚」，同级可辨靠明度差，弱对比读起来是一坨。
    private static let familyShades: [Double] = [1.0, 0.55, 0.82, 0.42, 0.70, 0.50]

    /// 顶层调色：扫描根 = 主题色阶彩虹；钻取后 = 家族色相 × 明度阶（色相锚定，返回时颜色可追）。
    private func paletteColor(_ i: Int) -> Color {
        if let familyHue {
            return familyHue.opacity(Self.familyShades[((i % Self.familyShades.count) + Self.familyShades.count) % Self.familyShades.count])
        }
        return Self.vividPalette[((i % Self.vividPalette.count) + Self.vividPalette.count) % Self.vividPalette.count]
    }

    /// DaisyDisk 式展示序：真实条目按大小降序在前，聚合段（其他/隐藏空间）钉在尾部——
    /// 环与图例共用同一口径，色相按「真实条目的序号」分配（聚合段恒为中性灰，不占色相）。
    static func displayOrder(_ children: [DiskNode]) -> [DiskNode] {
        children.sorted { a, b in
            if a.isAggregate != b.isAggregate { return !a.isAggregate }
            return a.size > b.size
        }
    }

    /// 聚合段的中性灰（与「其他」碎片弧同款）——数据色相只留给真实目录/文件。
    private static var aggregateColor: Color { XColor.idle.opacity(0.45) }

    /// 聚合段的解释文案（图例悬停提示）：隐藏空间 ≠ 其他小项。
    private static func aggregateHelp(_ node: DiskNode) -> String {
        node.name == "隐藏空间"
            ? xLoc("系统快照、可清除空间与无权限读取的部分——卷已用量与可见明细之差")
            : xLoc("多个小项的合计视图")
    }

    /// 账本节点的详情解释（P0-d 三本账，逐段说人话——诚实账本的展示面）。
    private func ledgerExplanation(_ node: DiskNode) -> String {
        switch node.ledgerKind {
        case .purgeable:
            return xLoc("macOS 自管的「可清除」空间（缓存/休眠镜像等）。系统在需要时自动腾出，第三方工具无法可靠释放——Xico 只解释、不代删、不计入可回收。")
        case .snapshots:
            return xLoc("Time Machine 本地快照。体积为差额估算（无特权拿不到精确值）；可逐个删除释放空间，删除走系统 tmutil、需二次确认。")
        case .unreadable:
            return xLoc("因缺少完全磁盘访问权限而未能读取的目录。开启权限后重新扫描即可看到明细。")
        default:
            return Self.aggregateHelp(node)
        }
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
        .onExitCommand { onDeselect?() }   // ESC 取消选中
        // ⌘⌫ 删除选中项（P1-9，DaisyDisk 高频直觉快捷键）：走同一条红线预检 + 二次确认。
        .onDeleteCommand {
            if let sel = selected, !sel.isAggregate, onTrash != nil { requestTrash(sel) }
        }
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
        let hole = side * 0.22            // 中心圆半径：多层放射下环带区加厚到 ~0.28×side
        let radii = Self.ringRadii(hole: hole, center: center)
        return ZStack {
            ForEach(arcs) { arc in
                arcButton(arc, radii: radii)
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
    private func arcButton(_ arc: Arc, radii: [(inner: CGFloat, outer: CGFloat)]) -> some View {
        let band = radii[min(max(arc.depth - 1, 0), radii.count - 1)]
        let inner = band.inner
        let outer = band.outer - 1.5   // 环间留 1.5pt 缝
        let isSelected = selected?.id == arc.node.id && !arc.isOther
        let isHot = (hovered?.id == arc.node.id && !arc.isOther) || isSelected
        // 同族高亮：悬停某段时，它与它的祖先/子孙（同色相路径）保持满亮，其余**轻微后退**
        // （0.68，仍保有本色）——一眼看清「这块空间从哪来、往哪去」，但绝不把全场压成灰
        // （2026-07 用户实测：0.35 灰化被否决，「选中应是单段突出，不是其余变灰」）。
        // 跨树搜索（P2-11）例外：找东西时非命中就该强力退场，保留 0.25 深压。
        let searchDim = !searchQuery.isEmpty && !arc.node.name.localizedCaseInsensitiveContains(searchQuery)
        // 关键排除：悬停的就是**当前选中项**时不触发家族压暗——点选后鼠标仍停在该段上，
        // 若不排除，全场立即因 hover 变暗，用户感知成「一选中全变灰」（2026-07 实测投诉根因）。
        let familyDim = hovered != nil && hovered?.id != selected?.id && !isHot
            && (arc.isOther || !isRelated(arc.node, to: hovered))
        let fade: Double = searchDim ? 0.25 : (familyDim ? 0.68 : 1)
        // DaisyDisk 式「单段突出」：**选中段**沿弧中线向外弹出 5pt + 白描边 + 同色光晕——
        // 强调来自「它抬起来了」，而非「别人都暗下去」。悬停只给描边光晕不弹出（鼠标扫过
        // 几百段时满盘弹跳会晕）。zIndex 抬到最上层，弹出时不被外环遮挡。
        let theta = (arc.mid - 90) * .pi / 180
        let pop: CGFloat = isSelected ? 5 : 0
        // 每段弧封装为 .plain Button：可被 Tab 聚焦、空格/回车触发，并向 VoiceOver
        // 报出「名称·大小·占比」。单击激活（选中/进入由宿主决断）——文件与目录一视同仁，
        // 每一段都点得动（DaisyDisk 口径）。
        Button {
            if arc.isOther {
                if !arc.otherItems.isEmpty { otherPopoverKey = arc.key }   // 可用楔形无明细，点击无操作
            } else {
                onActivate(arc.node)
            }
        } label: {
            RingSector(start: arc.start + 0.25, end: arc.end - 0.25, inner: inner, outer: outer)
                .fill(arc.color.opacity(isHot ? 1 : depthOpacity(arc.depth) * fade))
                .overlay(
                    RingSector(start: arc.start + 0.25, end: arc.end - 0.25, inner: inner, outer: outer)
                        .stroke(Color.white.opacity(isHot ? 0.95 : 0.0), lineWidth: isSelected ? 2.5 : 1.5)
                )
                .shadow(color: isHot ? arc.color.opacity(0.6) : .clear, radius: isSelected ? 12 : (isHot ? 10 : 0))
        }
        .buttonStyle(.plain)
        .contentShape(RingSector(start: arc.start, end: arc.end, inner: inner, outer: band.outer))
        .overlay {
            // 环段内嵌标签（P1-7 信息密度追平 DaisyDisk）：**只画第 1 层**且弧够宽（≥14°）——
            // 外环薄带绝不塞字（此前五层嵌套小字被实测否决）。纯装饰，a11y 已有完整标签。
            if arc.depth == 1, arc.sweep >= 14, !arc.isOther || arc.node.name == xLoc("可用空间") {
                arcInlineLabel(arc, inner: inner, outer: outer, dimmed: searchDim || familyDim)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .offset(x: pop * CGFloat(cos(theta)), y: pop * CGFloat(sin(theta)))
        .zIndex(isHot ? 2 : 0)
        .onHover { if $0 { hovered = arc.node } else if hovered?.id == arc.node.id { hovered = nil } }
        .help(arc.isOther ? "\(xLoc(arc.node.name)) · \(arc.node.size.formattedBytes)"
                          : "\(xLoc(arc.node.name)) · \(arc.node.size.formattedBytes)")
        .animation(XMotion.hover, value: hovered?.id)
        .animation(XMotion.hover, value: selected?.id)
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

    /// 环段内嵌标签（2026-07 重做）：**水平**「名称 + 百分比」两行置于弧中线径向中点——
    /// 单层厚环带下水平字清晰体面；此前的切向旋转小字在多层窄环上被用户实测嫌丑。
    private func arcInlineLabel(_ arc: Arc, inner: CGFloat, outer: CGFloat, dimmed: Bool) -> some View {
        GeometryReader { geo in
            let c = CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)
            let r = (inner + outer) / 2
            let theta = (arc.mid - 90) * .pi / 180
            let pos = CGPoint(x: c.x + r * cos(theta), y: c.y + r * sin(theta))
            // 弦长近似可用宽度（弧越窄可写越少），留 8pt 余量、封顶 110pt。
            let maxW = min(max(0, 2 * r * sin(arc.sweep * .pi / 360) - 8), 110)
            VStack(spacing: 1) {
                Text(xLoc(arc.node.name))
                    .font(XFont.nano)
                    .lineLimit(1).truncationMode(.middle)
                Text("\(Int((arc.sweep / 360 * 100).rounded()))%")
                    .font(XFont.microMono)
                    .opacity(0.8)
            }
            .foregroundStyle(Self.readableText(on: arc.color).opacity(dimmed ? 0.4 : 0.94))
            .frame(maxWidth: maxW)
            .position(pos)
        }
    }

    /// 该文件是否「已完整下载在本机的 iCloud 项」——可驱逐本地副本（保留云端）。
    static func isEvictableUbiquitous(_ url: URL) -> Bool {
        guard let v = try? url.resourceValues(forKeys: [.isUbiquitousItemKey,
                                                        .ubiquitousItemDownloadingStatusKey]) else { return false }
        return v.isUbiquitousItem == true && v.ubiquitousItemDownloadingStatus == .current
    }

    /// 驱逐本地副本（文件仍在云端；树上就地剪除本地占用）。
    private func evictLocal(_ node: DiskNode) {
        do {
            try FileManager.default.evictUbiquitousItem(at: node.url)
            onDeselect?()
            // 驱逐后本地占用归零——按「移除成功」语义就地剪枝由宿主 onTrash 的 prune 承担不了
            //（未走废纸篓），此处提示用户重扫该层即可；体量小，代价可接受。
            trashDeny = xLoc("已从本地移除（云端保留）。重新扫描该文件夹可刷新占用。")
        } catch {
            trashDeny = error.localizedDescription
        }
    }

    /// 段色上可读的文字色：按 sRGB 相对亮度选黑/白（与 TreemapView 同法，就地实现避免跨文件私有依赖）。
    static func readableText(on color: Color) -> Color {
        let ns = NSColor(color).usingColorSpace(.sRGB) ?? .black
        let l = 0.2126 * ns.redComponent + 0.7152 * ns.greenComponent + 0.0722 * ns.blueComponent
        return l > 0.62 ? Color.black : Color.white
    }

    /// VoiceOver 标签：名称 + 大小 + 占当前目录比例。复用既有「%@，%@」文案键，
    /// 占比以中性数字（如 " · 45%"）追加，不新增本地化键。
    private func arcLabel(_ arc: Arc) -> String {
        if arc.isOther {
            return xLocF("其他 %d 项", arc.otherItems.count) + "，\(arc.node.size.formattedBytes)"
        }
        let base = xLocF("%@，%@", xLoc(arc.node.name), arc.node.size.formattedBytes)
        let total = node.size + max(freeBytes ?? 0, 0)   // 与中心盘/详情卡同口径（终审 P1）
        guard total > 0 else { return base }
        let pct = Int((Double(arc.node.size) / Double(total) * 100).rounded())
        return "\(base) · \(pct)%"
    }

    /// 判断两个节点是否同一路径族（祖先或子孙关系）——用 URL 前缀近似，无需回溯树。
    private func isRelated(_ a: DiskNode, to b: DiskNode?) -> Bool {
        guard let b else { return false }
        let pa = a.url.path, pb = b.url.path
        return pa.hasPrefix(pb + "/") || pb.hasPrefix(pa + "/") || pa == pb
    }

    private func centerLabel(hole: CGFloat) -> some View {
        // 中心优先级：悬停 > 选中 > 当前目录——选中后移开鼠标，中心仍锚着选中项（DaisyDisk 口径）。
        let shown = hovered ?? selected ?? node
        let sharePct: Int? = {
            guard shown.id != node.id else { return nil }
            // 分母 = 整环所代表的总量：看整卷根时含可用楔形（node.size 只是已用量，漏加 free
            // 会让「可用空间」悬停显示 >100%、普通段占比虚高——2026-07 终审 P1）。
            // 与环段内嵌标签的 sweep/360 口径完全一致。
            let total = node.size + max(freeBytes ?? 0, 0)
            guard total > 0 else { return nil }
            return Int((Double(shown.size) / Double(total) * 100).rounded())
        }()
        let canGoUp = onUp != nil && hovered == nil && selected == nil
        // 中心盘也是一个 .plain Button：可被 Tab 聚焦、空格/回车触发「返回上一级」，
        // 与鼠标点击中心等价——键盘/读屏用户不再无路可上。
        return Button {
            // 有选中时，点中心 = 取消选中（DaisyDisk 惯例）；无选中才是返回上一级。
            if selected != nil {
                onDeselect?()
            } else {
                onUp?()
            }
        } label: {
        ZStack {
            // 中心盘（P2-13 玻璃质感）：系统材质底 + 表面色罩 + 极细内高光——
            // 「悬浮表盘」景深，深色模式尤其立体（DaisyDisk 深色是弱项）。
            Circle().fill(.ultraThinMaterial)
            Circle().fill(XColor.surface.opacity(centerHover && canGoUp ? 0.72 : 0.35))
            Circle().stroke(XColor.hairline, lineWidth: 1)
            Circle().stroke(Color.white.opacity(0.08), lineWidth: 1).padding(1.5)
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
        let sorted = Self.displayOrder(node.children)
        let total = max(node.size + max(freeBytes ?? 0, 0), 1)   // 与环段/中心盘同口径（终审 P1）
        // 跨树搜索（P2-11）：查询非空时图例只列命中项（弧同步压暗非命中）。
        let visible = searchQuery.isEmpty
            ? Array(sorted.enumerated())
            : Array(sorted.enumerated()).filter { $0.element.name.localizedCaseInsensitiveContains(searchQuery) }
        return VStack(alignment: .leading, spacing: XSpacing.s) {
            HStack {
                Text(xLoc(node.name)).font(XFont.headline).foregroundStyle(XColor.textPrimary)
                    .lineLimit(1).truncationMode(.middle)
                Spacer()
                Text(node.size.formattedBytes).font(XFont.mono).foregroundStyle(XColor.textSecondary)
            }
            if let free = freeBytes, free > 0 {
                HStack(spacing: 5) {
                    Circle().fill(XColor.success.opacity(0.5)).frame(width: 7, height: 7)
                    Text(xLocF("可用 %@", free.formattedBytes))
                        .font(XFont.captionEmphasis).foregroundStyle(XColor.success)
                    Spacer()
                }
            }
            Text(searchQuery.isEmpty
                 ? xLocF("%d 个项目 · 点文件夹进入 · 点文件选中", node.children.count)
                 : xLocF("命中 %d 项", visible.count))
                .font(XFont.caption).foregroundStyle(XColor.textTertiary)
            Divider().padding(.vertical, 2)
            // 全部条目可滚动（不再截断到 14 项）——大目录也能逐项审阅。
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(visible, id: \.element.id) { i, child in
                        legendRow(child, color: child.isAggregate ? Self.aggregateColor : paletteColor(i),
                                  fraction: Double(child.size) / Double(total))
                    }
                }
            }
            if let sel = selected {
                selectionCard(sel)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .animation(XMotion.hover, value: selected?.id)
    }

    /// 已知可安全清理的路径族（P2-15 徽标）：与 SafetyEngine 的可重建垃圾白名单同口径
    ///（缓存/日志/窗口状态/开发者派生数据/废纸篓）。命中即在图例给 success 徽标 + 一键入篮。
    static func isKnownCleanable(_ url: URL) -> Bool {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let p = url.path
        let roots = ["\(home)/Library/Caches", "\(home)/Library/Logs",
                     "\(home)/Library/Saved Application State",
                     "\(home)/Library/Developer/Xcode/DerivedData",
                     "\(home)/.cache", "\(home)/.Trash"]
        return roots.contains { p == $0 || p.hasPrefix($0 + "/") }
    }

    // MARK: 选中详情卡（DaisyDisk 式：选中任意环段/行——含文件——即出详情与操作）

    @ViewBuilder
    private func selectionCard(_ sel: DiskNode) -> some View {
        // 分母与中心盘/环段标签同口径：看整卷根时含可用楔形（终审 P1 分母修正）。
        let cardTotal = node.size + max(freeBytes ?? 0, 0)
        let pct = cardTotal > 0 ? Int((Double(sel.size) / Double(cardTotal) * 100).rounded()) : 0
        let drillable = sel.isDirectory && !sel.isAggregate
        VStack(alignment: .leading, spacing: XSpacing.s) {
            HStack(spacing: XSpacing.s) {
                Image(systemName: sel.isAggregate ? "square.stack.3d.up"
                                                  : (sel.isDirectory ? "folder.fill" : "doc.fill"))
                    .font(XFont.caption).foregroundStyle(XColor.brand)
                Text(xLoc(sel.name)).font(XFont.bodyEmphasis).foregroundStyle(XColor.textPrimary)
                    .lineLimit(1).truncationMode(.middle)
                Spacer()
                Text(sel.size.formattedBytes).font(XFont.mono).foregroundStyle(XColor.textSecondary)
                Text("\(pct)%").font(XFont.captionEmphasis).foregroundStyle(XColor.brand).monospacedDigit()
            }
            if sel.isAggregate {
                // 聚合段（其他/隐藏空间/账本）：只解释，不给文件级操作（URL 是父目录，动它即误伤）。
                Text(ledgerExplanation(sel))
                    .font(XFont.caption).foregroundStyle(XColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                // 账本子段在环上是很薄的外环弧、不好点——详情卡里逐行列出并携带
                // 各自动作，三本账的可达性不依赖环上命中率。
                if sel.ledgerKind == nil {
                    ForEach(sel.children.filter { $0.ledgerKind != nil }) { child in
                        HStack(spacing: XSpacing.s) {
                            Circle().fill(Self.aggregateColor).frame(width: 7, height: 7)
                            Text(xLoc(child.name)).font(XFont.caption)
                                .foregroundStyle(XColor.textPrimary)
                                .lineLimit(1)
                            Spacer()
                            Text(child.size.formattedBytes).font(XFont.microMono)
                                .foregroundStyle(XColor.textSecondary)
                            switch child.ledgerKind {
                            case .snapshots:
                                if let onManageSnapshots {
                                    Button(xLoc("管理…")) { onManageSnapshots() }
                                        .buttonStyle(XSecondaryButtonStyle(compact: true))
                                }
                            case .unreadable:
                                if let onOpenFDA {
                                    Button(xLoc("开启权限")) { onOpenFDA() }
                                        .buttonStyle(XSecondaryButtonStyle(compact: true))
                                }
                            default:
                                EmptyView()
                            }
                        }
                        .help(ledgerExplanation(child))
                    }
                }
                // 账本节点的专属动作（P0-d）：快照走 tmutil 独立通道、无权限区引导 FDA。
                switch sel.ledgerKind {
                case .snapshots:
                    if let onManageSnapshots {
                        Button { onManageSnapshots() } label: {
                            Label(xLoc("管理本地快照…"), systemImage: "clock.arrow.circlepath")
                        }
                        .buttonStyle(XPrimaryButtonStyle(compact: true))
                    }
                case .unreadable:
                    if let onOpenFDA {
                        Button { onOpenFDA() } label: {
                            Label(xLoc("开启完全磁盘访问"), systemImage: "lock.shield")
                        }
                        .buttonStyle(XPrimaryButtonStyle(compact: true))
                    }
                default:
                    EmptyView()
                }
            } else {
                Text(sel.url.path)
                    .font(XFont.captionMono).foregroundStyle(XColor.textTertiary)
                    .lineLimit(1).truncationMode(.middle)
                HStack(spacing: XSpacing.s) {
                    if drillable {
                        Button {
                            onActivate(sel)   // 已选中 → 宿主语义 = 进入
                        } label: {
                            Label(xLoc("进入"), systemImage: "arrow.down.forward.circle")
                        }
                        .buttonStyle(XPrimaryButtonStyle(compact: true))
                    }
                    Button { NSWorkspace.shared.activateFileViewerSelecting([sel.url]) } label: {
                        Image(systemName: "magnifyingglass")
                    }
                    .buttonStyle(XSecondaryButtonStyle(compact: true))
                    .help(xLoc("在 Finder 中显示"))
                    Button { quickLook(sel.url) } label: {
                        Image(systemName: "eye")
                    }
                    .buttonStyle(XSecondaryButtonStyle(compact: true))
                    .help(xLoc("快速查看"))
                    if onCollect != nil {
                        Button { onCollect?(sel) } label: {
                            Image(systemName: "basket")
                        }
                        .buttonStyle(XSecondaryButtonStyle(compact: true))
                        .help(xLoc("加入收集篮"))
                    }
                    // iCloud 就地驱逐（P1-8）：已下载的 iCloud 文件「从本地移除、云端保留」——
                    // 比移废纸篓更轻更安全，是 DaisyDisk 付费墙后才有的能力。
                    if !sel.isDirectory, Self.isEvictableUbiquitous(sel.url) {
                        Button { evictLocal(sel) } label: {
                            Image(systemName: "icloud.and.arrow.up")
                        }
                        .buttonStyle(XSecondaryButtonStyle(compact: true))
                        .help(xLoc("从本地移除（保留云端）"))
                    }
                    Spacer()
                    if onTrash != nil {
                        Button(role: .destructive) { requestTrash(sel) } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(XSecondaryButtonStyle(compact: true))
                        .help(xLoc("移到废纸篓"))
                    }
                }
            }
        }
        .padding(XSpacing.m)
        .background(RoundedRectangle(cornerRadius: XRadius.control, style: .continuous)
            .fill(XColor.surface.opacity(0.85)))
        .overlay(RoundedRectangle(cornerRadius: XRadius.control, style: .continuous)
            .stroke(XColor.hairline, lineWidth: 1))
    }

    private func legendRow(_ child: DiskNode, color: Color, fraction: Double) -> some View {
        let isSelected = selected?.id == child.id
        let isHot = hovered?.id == child.id || isSelected
        return Button {
            onActivate(child)
        } label: {
            HStack(spacing: XSpacing.s) {
                RoundedRectangle(cornerRadius: XRadius.micro).fill(color).frame(width: 11, height: 11)
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Image(systemName: child.isDirectory ? "folder.fill" : "doc")
                            .font(XFont.nano).foregroundStyle(XColor.textTertiary)
                        Text(xLoc(child.name)).font(XFont.bodyEmphasis).foregroundStyle(XColor.textPrimary)
                            .lineLimit(1).truncationMode(.middle)
                        // 可安全清理徽标（P2-15）：缓存/日志/DerivedData 等已知可重建垃圾——
                        // 空间可视化与清理安全库在同一屏产生化学反应（三合一独占）。
                        if !child.isAggregate, Self.isKnownCleanable(child.url) {
                            Image(systemName: "sparkles")
                                .font(XFont.nano).foregroundStyle(XColor.success)
                                .help(xLoc("已知可安全清理类型（缓存/日志/派生数据），删除后可自动重建"))
                        }
                        Spacer()
                        Text("\(Int((fraction * 100).rounded()))%")
                            .font(XFont.caption).foregroundStyle(isHot ? color : XColor.textTertiary).monospacedDigit()
                        Text(child.size.formattedBytes).font(XFont.caption).foregroundStyle(XColor.textSecondary).monospacedDigit()
                            .frame(minWidth: 64, alignment: .trailing)
                        // 「可进入」余量提示：文件夹行尾常驻小箭头（悬停加亮）——点击即进的视觉承诺。
                        if child.isDirectory && !child.isAggregate {
                            Image(systemName: "chevron.right")
                                .font(XFont.nano)
                                .foregroundStyle(isHot ? XColor.textSecondary : XColor.textTertiary.opacity(0.6))
                        }
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
                .fill(isSelected ? XColor.brand.opacity(0.10) : (isHot ? XColor.surfaceHover : Color.clear)))
            .overlay(RoundedRectangle(cornerRadius: XRadius.control, style: .continuous)
                .stroke(isSelected ? XColor.brand.opacity(0.35) : Color.clear, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { if $0 { hovered = child } else if hovered?.id == child.id { hovered = nil } }
        .help(child.isAggregate ? Self.aggregateHelp(child) : "")
        .accessibilityLabel(xLocF("%@，%@", xLoc(child.name), child.size.formattedBytes))
        .draggableUnlessAggregate(child)   // 拖进收集篮（basket 是 dropDestination）；聚合节点不可拖
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
            for (i, child) in Self.displayOrder(n.children).enumerated() {
                let childSpan = span * Double(child.size) / Double(total)
                if childSpan < 0.5 {
                    // 深层碎片直接留白（DaisyDisk 亦然）——只有第 1 层才聚合成「其他」段，
                    // 否则每个目录都吐一段灰弧，外圈会连成一整个灰盘（实测事故，已修正）。
                    if depth == 1 {
                        otherSpan += childSpan
                        otherItems.append(child)
                        otherBytes += child.size
                    }
                    continue
                }
                let cStart = a, cEnd = a + childSpan
                let base = child.isAggregate ? Self.aggregateColor : (hue ?? paletteColor(i))
                // 深层同胞交替明度（DaisyDisk 同法）：继承同一家族色相时，相邻段以 ~14% 差
                // 彼此区分，否则整个扇区糊成一块实色。注意向下传的是未交替的 base——
                // 交替只作用于本段展示，不随深度复利叠加。
                let color = (depth >= 2 && !child.isAggregate && i % 2 == 1) ? base.opacity(0.86) : base
                out.append(Arc(key: child.id.uuidString, node: child, depth: depth,
                               start: cStart, end: cEnd, color: color,
                               isOther: false, otherItems: []))
                if child.isDirectory && !child.children.isEmpty {
                    recurse(child, depth: depth + 1, start: cStart, end: cEnd, hue: base)
                }
                a = cEnd
            }
            if depth == 1, otherSpan > 0.05, !otherItems.isEmpty {
                // 聚合弧的「载体节点」用一个只承载几何/大小的合成节点视图态——绝不参与删除
                // （isOther 弧在 UI 上无删除/收集入口，点击只弹明细清单）。
                let carrier = DiskNode(url: n.url, name: xLoc("其他"), isDirectory: false,
                                       size: otherBytes, isAggregate: true)
                out.append(Arc(key: n.id.uuidString + "#other", node: carrier, depth: depth,
                               start: a, end: a + otherSpan, color: XColor.idle.opacity(0.45),
                               isOther: true, otherItems: otherItems))
            }
        }
        // 初始 hue 传 nil：顶层分配一律走 paletteColor——家族模式下它返回「家族色相 × 明度阶」
        // （同级可辨），扫描根下它返回主题色阶彩虹；子孙经 hue 参数继承烘好的颜色。
        // 可用空间楔形（P1-7）：看整卷根时，已用部分按占比压缩、尾部追加低饱和「可用」段——
        // 整环 = 卷总量，一眼同时读出「还剩多少」与「谁占掉了」。
        if let free = freeBytes, free > 0, node.size > 0 {
            let usedSpan = 360 * Double(node.size) / Double(node.size + free)
            recurse(node, depth: 1, start: 0, end: usedSpan, hue: nil)
            let carrier = DiskNode(url: node.url, name: xLoc("可用空间"), isDirectory: false,
                                   size: free, isAggregate: true)
            out.append(Arc(key: node.id.uuidString + "#free", node: carrier, depth: 1,
                           start: usedSpan, end: 360, color: XColor.success.opacity(0.22),
                           isOther: true, otherItems: []))
        } else {
            recurse(node, depth: 1, start: 0, end: 360, hue: nil)
        }
        return out
    }

    private func depthOpacity(_ depth: Int) -> Double {
        switch depth {
        case 1: return 1.0
        case 2: return 0.90
        case 3: return 0.80
        case 4: return 0.70
        default: return 0.62
        }
    }
}
