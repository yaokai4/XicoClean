import SwiftUI
import AppKit
import Domain
import DesignSystem

// MARK: - Squarified Treemap（空间透镜 · 方块视图）
//
// docs/15 P2-12：布局从朴素二分切割升级为经典 squarified（Bruls, Huizing & van Wijk 2000）——
// 按大小降序逐项放入当前「行」，行内瓦片的最坏纵横比一旦恶化即封行换行，瓦片尽量趋近正方形。
// 两层嵌套渲染：一级瓦片若是目录且足够大，在内边距（3pt + 顶部 14pt 标题带）内用同一算法
// 再铺一层子瓦片（只铺一层，防杂乱）；子瓦片继承父色相、按明度阶区分（与环形图家族策略同款）。
// 预计上屏面积 < 12×8pt 的碎片不单独画，合并为一个中性「其他」桶（非交互、不可删）。

/// 布局槽位：真实子节点，或由过小碎片合并成的展示桶（复用不了任何真实 URL，因此不可交互/不可删）。
enum TreemapSlot {
    case node(DiskNode)
    case merged(count: Int, size: Int64)

    var bytes: Int64 {
        switch self {
        case .node(let n): return n.size
        case .merged(_, let size): return size
        }
    }
}

/// 已定位的槽位（布局输出单元）。id 稳定：真实节点用 node.id，合并桶恒为常量键。
struct PlacedTreemapSlot: Identifiable {
    let slot: TreemapSlot
    let frame: CGRect

    var id: String {
        switch slot {
        case .node(let n): return n.id.uuidString
        case .merged: return "treemap.merged.others"
        }
    }
}

/// Squarified treemap：面积正比于占用大小，点击目录方块可钻取；目录瓦片内嵌套第二层子瓦片。
struct TreemapView: View {
    let node: DiskNode
    /// 当前选中项 id（宿主状态）：瓦片描边高亮，与环形图同一套「单击选中、再击进入」语义。
    let selectedID: UUID?
    let onSelect: (DiskNode) -> Void
    /// 就地把某项移到废纸篓（可恢复）。nil 表示宿主未提供该能力。
    let onTrash: ((DiskNode) -> Void)?
    /// 加入收集篮（两段式删除的第一段）。nil 表示宿主未提供。
    let onCollect: ((DiskNode) -> Void)?
    /// 删除红线预检（统一走宿主的 env.safety）——返回拒绝原因，nil = 放行。
    let denyReason: ((URL) -> String?)?
    @State private var hovered: UUID?
    @State private var pendingTrash: DiskNode?
    @State private var trashDeny: String?

    init(node: DiskNode,
         selectedID: UUID? = nil,
         onTrash: ((DiskNode) -> Void)? = nil,
         onCollect: ((DiskNode) -> Void)? = nil,
         denyReason: ((URL) -> String?)? = nil,
         onSelect: @escaping (DiskNode) -> Void) {
        self.node = node
        self.selectedID = selectedID
        self.onTrash = onTrash
        self.onCollect = onCollect
        self.denyReason = denyReason
        self.onSelect = onSelect
    }

    var body: some View {
        GeometryReader { geo in
            let rect = CGRect(origin: .zero, size: geo.size)
            let slots = Self.layoutSlots(node.children, in: rect)
            let hues = hueIndices()
            ZStack(alignment: .topLeading) {
                ForEach(slots) { placed in
                    switch placed.slot {
                    case .node(let child):
                        tile(child, frame: placed.frame, hueIndex: hues[child.id])
                    case .merged(let count, let size):
                        mergedTile(count: count, size: size, frame: placed.frame)
                    }
                }
            }
            // 动效克制：仅在钻取/返回（当前根变化）时整体安顿一次，不做花哨入场。
            .animation(XMotion.settle, value: node.id)
        }
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

    // MARK: 瓦片

    /// 一级瓦片。目录且足够大时嵌套第二层子瓦片；标题/删除入口/右键菜单等交互全部保留在一级。
    private func tile(_ child: DiskNode, frame: CGRect, hueIndex: Int?) -> some View {
        // 聚合瓦片（其他/隐藏空间）用中性灰——与环形图口径一致，数据色相只留给真实条目。
        // 真实条目沿用环形图的高饱和 vividPalette，按 displayOrder 序号取色，两种视图颜色可互认。
        let base = child.isAggregate
            ? XColor.idle
            : SunburstView.vividPalette[(hueIndex ?? 0) % SunburstView.vividPalette.count]
        let isSelected = selectedID == child.id
        let isHover = hovered == child.id || isSelected
        let w = max(2, frame.width - 3)   // 3pt 瓦片间距（gutter）
        let h = max(2, frame.height - 3)
        // 瓦片太小不画标题（spec：< 48×28pt）。
        let showLabel = frame.width >= 48 && frame.height >= 28
        // 嵌套条件：目录、非聚合、瓦片够大——内边距 3pt + 顶部 14pt 标题带后仍有可读空间。
        let innerRect = CGRect(x: 0, y: 0, width: w - 6, height: h - 6 - 14)
        let nestedSlots: [PlacedTreemapSlot] =
            (child.isDirectory && !child.isAggregate && frame.width >= 72 && frame.height >= 56)
            ? Self.layoutSlots(child.children, in: innerRect)
            : []
        let nested = !nestedSlots.isEmpty
        // 嵌套瓦片底色改淡彩（子瓦片以明度阶铺在上面），标题用主题正文色；
        // 平铺瓦片保持实色，依亮度选黑白字（审计 P2，浅色主题下不再白字糊白底）。
        let onTile = nested ? XColor.textPrimary : Self.readableText(on: base)
        return Button { onSelect(child) } label: {
            RoundedRectangle(cornerRadius: XRadius.chip, style: .continuous)
                .fill(base.opacity(nested ? (isHover ? 0.34 : 0.24) : (isHover ? 0.95 : 0.78)))
                .overlay(
                    RoundedRectangle(cornerRadius: XRadius.chip, style: .continuous)
                        .strokeBorder(isSelected ? Color.white.opacity(0.9) : onTile.opacity(0.28),
                                      lineWidth: isSelected ? 2 : 1)
                )
                .overlay(alignment: .topLeading) {
                    if nested {
                        // 顶部 14pt 标题带：名称 + 大小单行排布，给子瓦片让出最大面积。
                        HStack(spacing: XSpacing.xs) {
                            Text(xLoc(child.name)).font(XFont.micro)
                            Text(child.size.formattedBytes).font(XFont.nano).opacity(0.8)
                        }
                        .lineLimit(1)
                        .foregroundStyle(onTile)
                        .frame(height: 14)
                        .padding(.leading, 6)
                        .padding(.top, XSpacing.xxs)
                    } else if showLabel {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(xLoc(child.name)).font(XFont.captionEmphasis).lineLimit(1)
                            Text(child.size.formattedBytes).font(XFont.micro).opacity(0.85)
                        }
                        .foregroundStyle(onTile)
                        .padding(6)
                    }
                }
                .overlay(alignment: .topLeading) {
                    if nested {
                        subTiles(nestedSlots, base: base, size: innerRect.size)
                    }
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(xLoc(child.name))，\(child.size.formattedBytes)")
        .accessibilityAddTraits(.isButton)
        .frame(width: w, height: h)
        // 可见的「移到废纸篓」入口：不再只藏在右键菜单里。常显但克制（悬停/聚焦时加亮），
        // 作为独立 Button 可被 Tab 聚焦、空格触发——键盘用户与不知右键的用户都能发现并执行删除。
        .overlay(alignment: .topTrailing) {
            // 合成聚合桶（「其他」）不给删除入口——它复用父目录 URL，删之即误删整个文件夹（审计 P0）。
            if showLabel, onTrash != nil, !child.isAggregate {
                Button(role: .destructive) { requestTrash(child) } label: {
                    Image(systemName: "trash.fill")
                        .font(XFont.micro).foregroundStyle(.white)
                        .padding(5)
                        .background(Circle().fill(.black.opacity(0.42)))
                }
                .buttonStyle(.plain)
                .padding(5)
                .opacity(isHover ? 1 : 0.5)
                .animation(XMotion.hover, value: isHover)
                .help(xLoc("移到废纸篓"))
                .accessibilityLabel(xLoc("移到废纸篓"))
            }
        }
        .offset(x: frame.minX, y: frame.minY)
        .onHover { hovered = $0 ? child.id : nil }
        .help("\(xLoc(child.name)) — \(child.size.formattedBytes)")
        .draggableUnlessAggregate(child)   // 拖进收集篮（basket 是 dropDestination）；聚合节点不可拖
        .contextMenu {
            Button(xLoc("在 Finder 中显示")) { NSWorkspace.shared.activateFileViewerSelecting([child.url]) }
            Button(xLoc("快速查看")) { quickLook(child.url) }
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

    /// 第二层子瓦片：纯视觉景深（不拦截点击，交互仍归一级瓦片）。
    /// 继承父色相、按明度阶区分——与环形图家族策略同款，明度数组本文件自持（childShades）。
    private func subTiles(_ slots: [PlacedTreemapSlot], base: Color, size: CGSize) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(Array(slots.enumerated()), id: \.element.id) { i, placed in
                let fill: Color = {
                    switch placed.slot {
                    case .merged:
                        return XColor.idle.opacity(0.4)
                    case .node(let sub):
                        return sub.isAggregate
                            ? XColor.idle.opacity(0.4)
                            : base.opacity(Self.childShades[i % Self.childShades.count])
                    }
                }()
                RoundedRectangle(cornerRadius: XRadius.micro, style: .continuous)
                    .fill(fill)
                    .frame(width: max(1, placed.frame.width - 1),
                           height: max(1, placed.frame.height - 1))
                    .offset(x: placed.frame.minX, y: placed.frame.minY)
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .offset(x: 3, y: 17)          // 内边距 3pt + 顶部 14pt 标题带
        .allowsHitTesting(false)      // 只铺一层、只作景深；点击/右键仍落在一级瓦片
    }

    /// 碎片合并桶：过小的项（预计 < 12×8pt）不单独画，合并为中性灰展示桶。
    /// 它不对应任何真实 URL——不可点选、不可拖、不给删除入口（与 isAggregate 守卫同一口径）。
    private func mergedTile(count: Int, size: Int64, frame: CGRect) -> some View {
        let showLabel = frame.width >= 48 && frame.height >= 28
        return RoundedRectangle(cornerRadius: XRadius.chip, style: .continuous)
            .fill(XColor.idle.opacity(0.35))
            .overlay(
                RoundedRectangle(cornerRadius: XRadius.chip, style: .continuous)
                    .strokeBorder(XColor.hairline, lineWidth: 1)
            )
            .overlay(alignment: .topLeading) {
                if showLabel {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(xLocF("其他 %d 项", count)).font(XFont.captionEmphasis).lineLimit(1)
                        Text(size.formattedBytes).font(XFont.micro).opacity(0.85)
                    }
                    .foregroundStyle(XColor.textSecondary)
                    .padding(6)
                }
            }
            .frame(width: max(2, frame.width - 3), height: max(2, frame.height - 3))
            .offset(x: frame.minX, y: frame.minY)
            .help(xLocF("%d 个过小的项合并展示，合计 %@。放大窗口或钻取后可见明细。", count, size.formattedBytes))
            .accessibilityLabel(xLocF("其他 %d 项，合计 %@", count, size.formattedBytes))
    }

    // MARK: 布局

    /// 与环形图同一套色相分配：displayOrder 中真实条目按序取 vividPalette，聚合桶不占色相。
    /// 两种视图切换时同一目录颜色可互认。
    private func hueIndices() -> [UUID: Int] {
        var map: [UUID: Int] = [:]
        var i = 0
        for child in SunburstView.displayOrder(node.children) where !child.isAggregate {
            map[child.id] = i
            i += 1
        }
        return map
    }

    /// 子瓦片明度阶（同环形图 familyShades 的策略，本文件自持一份）：
    /// 动态范围刻意拉大——父色相是「锚」，相邻子瓦片靠明度差可辨，弱对比读起来是一坨。
    private static let childShades: [Double] = [1.0, 0.55, 0.82, 0.42, 0.70, 0.50]

    /// 兼容包装（回归测试沿用此入口）：降序排序后走 squarified 核心，返回 (节点, 矩形) 对。
    /// 空集 / 空矩形 / 全零大小返回空数组（与旧二分实现口径一致）。
    nonisolated static func squarify(_ items: [DiskNode], in rect: CGRect) -> [(DiskNode, CGRect)] {
        guard !items.isEmpty, rect.width > 0, rect.height > 0,
              items.contains(where: { $0.size > 0 }) else { return [] }
        let sorted = items.sorted { $0.size > $1.size }
        let rects = squarifiedRects(values: sorted.map { Double(max(0, $0.size)) }, in: rect)
        return Array(zip(sorted, rects))
    }

    /// 视图用布局入口：降序 + squarified，另把「预计上屏面积 < minCell（12×8pt）」的碎片
    /// 合并成一个尾部展示桶（桶按合计大小插回降序位）——碎片不单独画（spec 4）。
    nonisolated static func layoutSlots(_ children: [DiskNode], in rect: CGRect,
                                        minCell: CGSize = CGSize(width: 12, height: 8)) -> [PlacedTreemapSlot] {
        let live = children.filter { $0.size > 0 }
        guard !live.isEmpty, rect.width > 0, rect.height > 0 else { return [] }
        let sorted = live.sorted { $0.size > $1.size }
        let total = sorted.reduce(0.0) { $0 + Double($1.size) }
        let scale = Double(rect.width * rect.height) / total
        let minArea = Double(minCell.width * minCell.height)

        var kept: [TreemapSlot] = []
        var tinyCount = 0
        var tinySize: Int64 = 0
        for child in sorted {
            if Double(child.size) * scale < minArea {
                tinyCount += 1
                tinySize += child.size
            } else {
                kept.append(.node(child))
            }
        }
        if tinyCount > 0 {
            // 桶按合计大小插回降序序列——squarified 假设降序输入才能保证纵横比质量。
            let idx = kept.firstIndex { $0.bytes < tinySize } ?? kept.endIndex
            kept.insert(.merged(count: tinyCount, size: tinySize), at: idx)
        }
        let rects = squarifiedRects(values: kept.map { Double($0.bytes) }, in: rect)
        return zip(kept, rects).map { PlacedTreemapSlot(slot: $0, frame: $1) }
    }

    /// 经典 squarified treemap（Bruls, Huizing & van Wijk 2000）的纯函数核心：
    /// 输入矩形与（建议降序的）值数组，输出与之**一一对应**的子矩形数组。
    ///
    /// 算法：维护「当前行」（沿剩余矩形短边铺设的一条条带）。逐项试加入当前行——
    /// 若加入后行内最坏纵横比不恶化则收下，否则封行（条带定厚、行内按面积分长），
    /// 从切剩的矩形另起新行。降序输入下该贪心可证行内纵横比单调不减，瓦片趋近正方形。
    ///
    /// 边界口径：零/负值项得到零矩形；空间耗尽（浮点残差）后的余项亦为零矩形——
    /// 返回数组长度恒等于 `values.count`，便于调用方 zip 回原序。
    nonisolated static func squarifiedRects(values: [Double], in rect: CGRect) -> [CGRect] {
        var result = [CGRect](repeating: CGRect(origin: rect.origin, size: .zero), count: values.count)
        let total = values.reduce(0) { $0 + max(0, $1) }
        guard !values.isEmpty, rect.width > 0, rect.height > 0, total > 0 else { return result }

        let scale = Double(rect.width * rect.height) / total
        var remaining = rect
        var row: [(index: Int, area: Double)] = []
        var rowSum = 0.0
        var rowMax = 0.0
        var rowMin = Double.greatestFiniteMagnitude

        /// 行的最坏纵横比（≥1，1 = 全正方形；越大越差）。
        func worst(sum: Double, maxArea: Double, minArea: Double, side: Double) -> Double {
            guard sum > 0, minArea > 0, side > 0 else { return .greatestFiniteMagnitude }
            let s2 = sum * sum
            let w2 = side * side
            return max(w2 * maxArea / s2, s2 / (w2 * minArea))
        }

        /// 封行：沿剩余矩形的短边铺满当前行（条带厚度 = 行面积 / 短边长），切掉该条带。
        func flushRow() {
            guard !row.isEmpty else { return }
            defer {
                row.removeAll(keepingCapacity: true)
                rowSum = 0
                rowMax = 0
                rowMin = .greatestFiniteMagnitude
            }
            let wide = remaining.width >= remaining.height   // 宽矩形→竖条贴左；高矩形→横条贴顶
            let side = Double(wide ? remaining.height : remaining.width)
            guard side > 0 else { return }
            let thickness = CGFloat(rowSum / side)
            var offset: CGFloat = 0
            for (i, area) in row {
                let length = CGFloat(area / rowSum) * CGFloat(side)
                result[i] = wide
                    ? CGRect(x: remaining.minX, y: remaining.minY + offset, width: thickness, height: length)
                    : CGRect(x: remaining.minX + offset, y: remaining.minY, width: length, height: thickness)
                offset += length
            }
            if wide {
                remaining.origin.x += thickness
                remaining.size.width = max(0, remaining.size.width - thickness)
            } else {
                remaining.origin.y += thickness
                remaining.size.height = max(0, remaining.size.height - thickness)
            }
        }

        for (i, raw) in values.enumerated() {
            let area = max(0, raw) * scale
            guard area > 0 else { continue }                                 // 零值项保留零矩形
            let side = Double(min(remaining.width, remaining.height))
            guard side > 0 else { continue }                                 // 空间耗尽（浮点残差）
            if row.isEmpty
                || worst(sum: rowSum + area, maxArea: max(rowMax, area),
                         minArea: min(rowMin, area), side: side)
                   <= worst(sum: rowSum, maxArea: rowMax, minArea: rowMin, side: side) {
                row.append((i, area))
                rowSum += area
                rowMax = max(rowMax, area)
                rowMin = min(rowMin, area)
            } else {
                flushRow()
                row.append((i, area))
                rowSum = area
                rowMax = area
                rowMin = area
            }
        }
        flushRow()
        return result
    }

    /// 依瓦片底色的相对亮度选可读前景：浅底用近黑字、深底用白字，保证浅色主题下的对比（审计 P2）。
    /// 动态色以当前外观解析；无法转 sRGB 时退回白字（与旧行为一致，绝不更差）。
    static func readableText(on color: Color) -> Color {
        guard let ns = NSColor(color).usingColorSpace(.sRGB) else { return XColor.onAccent }
        let lum = 0.299 * ns.redComponent + 0.587 * ns.greenComponent + 0.114 * ns.blueComponent
        return lum > 0.6 ? XColor.textPrimary : XColor.onAccent
    }
}
