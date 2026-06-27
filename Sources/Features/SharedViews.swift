import SwiftUI
import Domain
import DesignSystem

// MARK: - 安全级别 → 视觉

extension SafetyLevel {
    var tint: Color {
        switch self {
        case .safe: return XColor.success
        case .caution: return XColor.warning
        case .risky: return XColor.danger
        }
    }
    var gradient: [Color] {
        switch self {
        case .safe: return [XColor.accentTeal, XColor.success]
        case .caution: return [XColor.warning, XColor.accentPink]
        case .risky: return [XColor.danger, XColor.accentPink]
        }
    }
}

// MARK: - 单行可清理项

struct ItemRowView: View {
    let item: CleanableItem
    let onToggle: () -> Void
    @State private var hover = false

    var body: some View {
        HStack(spacing: XSpacing.m) {
            XCheckbox(isOn: item.isSelected, toggle: onToggle)

            Image(systemName: item.url.hasDirectoryPath ? "folder.fill" : "doc.fill")
                .foregroundStyle(XColor.textTertiary)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(item.displayName)
                        .font(XFont.bodyEmphasis).foregroundStyle(XColor.textPrimary).lineLimit(1)
                    if let note = item.note {
                        Text(note)
                            .font(.system(size: 9.5, weight: .semibold))
                            .foregroundStyle(XColor.warning)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(XColor.warning.opacity(0.15), in: Capsule())
                            .lineLimit(1).fixedSize()
                    }
                }
                Text(item.detail)
                    .font(XFont.caption).foregroundStyle(XColor.textTertiary)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            if item.safety != .safe {
                XBadge(item.safety.label, color: item.safety.tint)
            }
            Text(item.size.formattedBytes)
                .font(XFont.mono).foregroundStyle(XColor.textSecondary)
                .frame(minWidth: 76, alignment: .trailing)
        }
        .padding(.horizontal, XSpacing.s)
        .padding(.vertical, 6)
        .background(hover ? XColor.surfaceHover : .clear, in: RoundedRectangle(cornerRadius: 8))
        .animation(.easeOut(duration: 0.15), value: hover)
        .onHover { hover = $0 }
        .contextMenu {
            Button("在 Finder 中显示") { revealInFinder(item.url) }
        }
    }
}

func revealInFinder(_ url: URL) {
    NSWorkspace.shared.activateFileViewerSelecting([url])
}

// MARK: - 结果分组卡片（含交错入场动画）

struct ResultGroupCard: View {
    let group: ScanResultGroup
    let index: Int
    let allSelected: Bool
    let onToggleGroup: (Bool) -> Void
    let onToggleItem: (UUID) -> Void
    @State private var expanded = false
    @State private var appeared = false

    var body: some View {
        XCard {
            VStack(alignment: .leading, spacing: XSpacing.s) {
                HStack(spacing: XSpacing.m) {
                    XCheckbox(isOn: allSelected) { onToggleGroup(!allSelected) }
                    XIconTile(systemImage: group.systemImage, colors: group.safety.gradient, size: 36)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(group.title).xHeadline().foregroundStyle(XColor.textPrimary)
                        if !group.description.isEmpty {
                            Text(group.description).font(XFont.caption)
                                .foregroundStyle(XColor.textSecondary).lineLimit(2)
                        }
                    }
                    Spacer()
                    Text(group.totalSize.formattedBytes).xNumber().foregroundStyle(XColor.textPrimary)
                    Button {
                        withAnimation(.spring(response: 0.32, dampingFraction: 0.8)) { expanded.toggle() }
                    } label: {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 12, weight: .semibold))
                            .rotationEffect(.degrees(expanded ? 180 : 0))
                            .foregroundStyle(XColor.textSecondary)
                            .frame(width: 22, height: 22)
                            .background(XColor.surfaceAlt, in: Circle())
                    }
                    .buttonStyle(.plain)
                }

                if expanded {
                    Divider().padding(.vertical, 2)
                    VStack(spacing: 0) {
                        ForEach(group.items.prefix(80)) { item in
                            ItemRowView(item: item) { onToggleItem(item.id) }
                        }
                        if group.items.count > 80 {
                            Text("还有 \(group.items.count - 80) 项…")
                                .font(XFont.caption).foregroundStyle(XColor.textTertiary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.top, XSpacing.xs)
                        }
                    }
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
        }
        .hoverLift(2)
        .opacity(appeared ? 1 : 0)
        .offset(y: appeared ? 0 : 16)
        .onAppear {
            withAnimation(.spring(response: 0.5, dampingFraction: 0.82).delay(Double(index) * 0.05)) {
                appeared = true
            }
        }
    }
}

// MARK: - 扫描中（招牌动画）

struct ScanningIndicator: View {
    let bytes: Int64
    let message: String
    var body: some View {
        VStack(spacing: XSpacing.xl) {
            XScanOrb(value: bytes.formattedBytes, label: "已发现", size: 300)
            Text(message.isEmpty ? "正在扫描…" : message)
                .font(XFont.body).foregroundStyle(XColor.textSecondary)
                .lineLimit(1).truncationMode(.middle).frame(maxWidth: 380)
                .transition(.opacity)
                .id(message)
        }
    }
}

// MARK: - 完成页（庆祝动画）

struct CompletionView: View {
    let report: CleaningReport
    let intent: DeleteIntent
    let onUndo: () -> Void
    let onDone: () -> Void
    @State private var pop = false

    var body: some View {
        ZStack {
            XCelebrationBurst().frame(width: 360, height: 360)
            VStack(spacing: XSpacing.l) {
                ZStack {
                    Circle().fill(XColor.success.opacity(0.15)).frame(width: 124, height: 124)
                    Image(systemName: "checkmark")
                        .font(.system(size: 54, weight: .bold))
                        .foregroundStyle(XColor.successGradient)
                }
                .scaleEffect(pop ? 1 : 0.3)
                .opacity(pop ? 1 : 0)

                Text("已释放 \(report.reclaimedBytes.formattedBytes)")
                    .xLargeTitle().foregroundStyle(XColor.textPrimary)
                    .contentTransition(.numericText())
                Text("清理了 \(report.removedCount) 项" +
                     (report.failures.isEmpty ? "" : " · \(report.failures.count) 项被跳过"))
                    .font(XFont.body).foregroundStyle(XColor.textSecondary)
                HStack(spacing: XSpacing.m) {
                    if intent == .trash && !report.restorable.isEmpty {
                        Button("撤销") { onUndo() }.buttonStyle(XSecondaryButtonStyle())
                    }
                    Button("完成") { onDone() }.buttonStyle(XPrimaryButtonStyle())
                }
                .padding(.top, XSpacing.s)
                .opacity(pop ? 1 : 0)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            withAnimation(.spring(response: 0.5, dampingFraction: 0.55)) { pop = true }
        }
    }
}
