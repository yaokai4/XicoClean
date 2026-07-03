import SwiftUI
import AppKit
import Domain
import DesignSystem

/// 简化的二分切割 treemap：面积正比于占用大小，点击目录方块可钻取。
struct TreemapView: View {
    let node: DiskNode
    let onSelect: (DiskNode) -> Void
    @State private var hovered: UUID?

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
    }

    private func tile(_ child: DiskNode, frame: CGRect) -> some View {
        let color = Self.color(for: child.name)
        let isHover = hovered == child.id
        let showLabel = frame.width > 64 && frame.height > 34
        return Button { onSelect(child) } label: {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(color.opacity(isHover ? 0.95 : 0.78))
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.25), lineWidth: 1)
                )
                .overlay(alignment: .topLeading) {
                    if showLabel {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(child.name).font(.system(size: 11, weight: .semibold)).lineLimit(1)
                            Text(child.size.formattedBytes).font(.system(size: 10)).opacity(0.85)
                        }
                        .foregroundStyle(.white)
                        .padding(6)
                    }
                }
        }
        .buttonStyle(.plain)
        .frame(width: max(2, frame.width - 3), height: max(2, frame.height - 3))
        .offset(x: frame.minX, y: frame.minY)
        .onHover { hovered = $0 ? child.id : nil }
        .help("\(child.name) — \(child.size.formattedBytes)")
        .contextMenu {
            Button(xLoc("在 Finder 中显示")) { NSWorkspace.shared.activateFileViewerSelecting([child.url]) }
            Button(xLoc("快速查看")) { quickLook(child.url) }
        }
        .accessibilityLabel("\(child.name)，\(child.size.formattedBytes)")
        .accessibilityAddTraits(.isButton)
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
        // 淡彩虹色板，与全局配色一致
        let palette: [Int] = [0x7C97F2, 0xA790F0, 0xC79AE8, 0xE6A6CE, 0x86E6DC, 0x8FB0FF, 0xCBB0FF, 0xAEC2FF]
        let hash = abs(name.hashValue)
        return Color(nsColor: NSColor(hex: palette[hash % palette.count]))
    }
}
