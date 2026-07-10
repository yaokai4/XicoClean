import SwiftUI
import AppKit
import Domain
import DesignSystem

/// 简化的二分切割 treemap：面积正比于占用大小，点击目录方块可钻取。
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
            let layout = Self.squarify(node.children, in: rect)
            ZStack(alignment: .topLeading) {
                ForEach(Array(layout.enumerated()), id: \.offset) { _, pair in
                    tile(pair.0, frame: pair.1)
                }
            }
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

    private func tile(_ child: DiskNode, frame: CGRect) -> some View {
        // 聚合瓦片（其他/隐藏空间）用中性灰——与环形图口径一致，数据色相只留给真实条目。
        let color = child.isAggregate ? XColor.idle : Self.color(for: child.name)
        let onTile = Self.readableText(on: color)   // 依瓦片亮度选白/深字，浅色主题下不再白字糊白底（审计 P2）
        let isSelected = selectedID == child.id
        let isHover = hovered == child.id || isSelected
        let showLabel = frame.width > 64 && frame.height > 34
        return Button { onSelect(child) } label: {
            RoundedRectangle(cornerRadius: XRadius.chip, style: .continuous)
                .fill(color.opacity(isHover ? 0.95 : 0.78))
                .overlay(
                    RoundedRectangle(cornerRadius: XRadius.chip, style: .continuous)
                        .strokeBorder(isSelected ? Color.white.opacity(0.9) : onTile.opacity(0.28),
                                      lineWidth: isSelected ? 2 : 1)
                )
                .overlay(alignment: .topLeading) {
                    if showLabel {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(xLoc(child.name)).font(XFont.captionEmphasis).lineLimit(1)
                            Text(child.size.formattedBytes).font(XFont.micro).opacity(0.85)
                        }
                        .foregroundStyle(onTile)
                        .padding(6)
                    }
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(xLoc(child.name))，\(child.size.formattedBytes)")
        .accessibilityAddTraits(.isButton)
        .frame(width: max(2, frame.width - 3), height: max(2, frame.height - 3))
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

    // MARK: 布局

    nonisolated static func squarify(_ items: [DiskNode], in rect: CGRect) -> [(DiskNode, CGRect)] {
        guard !items.isEmpty, rect.width > 0, rect.height > 0 else { return [] }
        if items.count == 1 { return [(items[0], rect)] }

        let total = items.reduce(Int64(0)) { $0 + $1.size }
        guard total > 0 else { return [] }

        var acc: Int64 = 0
        var splitIndex = 0
        while splitIndex < items.count - 1 && acc + items[splitIndex].size < total / 2 {
            acc += items[splitIndex].size
            splitIndex += 1
        }
        // 关键修复：钳制切分点，保证两半都非空，否则会以相同集合无限递归 → 栈溢出崩溃
        splitIndex = min(max(splitIndex, 0), items.count - 2)

        let first = Array(items[0...splitIndex])
        let second = Array(items[(splitIndex + 1)...])
        let firstSum = first.reduce(Int64(0)) { $0 + $1.size }
        let frac = CGFloat(Double(firstSum) / Double(total))

        var r1 = rect, r2 = rect
        if rect.width >= rect.height {
            let w = rect.width * frac
            r1.size.width = w
            r2.origin.x += w
            r2.size.width -= w
        } else {
            let h = rect.height * frac
            r1.size.height = h
            r2.origin.y += h
            r2.size.height -= h
        }
        return squarify(first, in: r1) + squarify(second, in: r2)
    }

    static func color(for name: String) -> Color {
        // 每个文件夹一个稳定色相，取自当前主题的色阶（XColor.ring）——切主题即整体换色、
        // 亮/暗自动适配（不再硬编码固定十六进制）。ring 内部自带取模，负 hash 亦安全。
        XColor.ring(name.hashValue)
    }

    /// 依瓦片底色的相对亮度选可读前景：浅底用近黑字、深底用白字，保证浅色主题下的对比（审计 P2）。
    /// 动态色以当前外观解析；无法转 sRGB 时退回白字（与旧行为一致，绝不更差）。
    static func readableText(on color: Color) -> Color {
        guard let ns = NSColor(color).usingColorSpace(.sRGB) else { return XColor.onAccent }
        let lum = 0.299 * ns.redComponent + 0.587 * ns.greenComponent + 0.114 * ns.blueComponent
        return lum > 0.6 ? XColor.textPrimary : XColor.onAccent
    }
}
