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
    /// 删除后会怎样——给用户「删这个安全吗」的判断依据（智能解释）。
    var explanation: String {
        switch self {
        case .safe: return xLoc("删除安全：这些是可再生的缓存/临时文件，应用会在需要时自动重建。默认已勾选。")
        case .caution: return xLoc("请留意：删除本身可恢复（移入废纸篓），但重建或再获取需要时间/流量。默认不勾选，确认后再删。")
        case .risky: return xLoc("高风险：可能涉及重要或不可逆的数据。请逐项确认，默认不勾选。")
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
    var onIgnore: (() -> Void)? = nil
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
                Text(xLoc(item.detail))
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
            Button(xLoc("快速查看")) { quickLook(item.url) }
            Button(xLoc("在 Finder 中显示")) { revealInFinder(item.url) }
            if let onIgnore {
                Divider()
                Button(xLoc("永不清理此项")) { onIgnore() }
            }
        }
    }
}

func revealInFinder(_ url: URL) {
    NSWorkspace.shared.activateFileViewerSelecting([url])
}

/// 用系统 Quick Look 预览（qlmanage -p 弹出标准预览面板，稳健且无需接管 responder 链）。
func quickLook(_ url: URL) {
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/usr/bin/qlmanage")
    proc.arguments = ["-p", url.path]
    proc.standardOutput = FileHandle.nullDevice
    proc.standardError = FileHandle.nullDevice
    try? proc.run()
}

// MARK: - 结果分组卡片（含交错入场动画）

struct ResultGroupCard: View {
    let group: ScanResultGroup
    let index: Int
    let allSelected: Bool
    let onToggleGroup: (Bool) -> Void
    let onToggleItem: (UUID) -> Void
    var onIgnoreItem: ((UUID) -> Void)? = nil
    @State private var expanded = false
    @State private var appeared = false
    @State private var showAll = false
    @State private var showInfo = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// 结果项按大小降序，最能省空间的排在最前，信息层级更清晰。
    private var sortedItems: [CleanableItem] {
        group.items.sorted { $0.size > $1.size }
    }
    private static let previewCap = 80

    var body: some View {
        XCard {
            VStack(alignment: .leading, spacing: XSpacing.s) {
                HStack(spacing: XSpacing.m) {
                    XCheckbox(isOn: allSelected) { onToggleGroup(!allSelected) }
                    XIconTile(systemImage: group.systemImage, colors: group.safety.gradient, size: 36)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(xLoc(group.title)).xHeadline().foregroundStyle(XColor.textPrimary)
                        if !group.description.isEmpty {
                            Text(xLoc(group.description)).font(XFont.caption)
                                .foregroundStyle(XColor.textSecondary).lineLimit(2)
                        }
                    }
                    Spacer()
                    // 智能解释：这是什么 / 删了会怎样
                    Button { showInfo.toggle() } label: {
                        Image(systemName: "info.circle")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(XColor.textTertiary)
                    }
                    .buttonStyle(.plain)
                    .help(xLoc("这是什么 / 删除后会怎样"))
                    .popover(isPresented: $showInfo, arrowEdge: .bottom) {
                        VStack(alignment: .leading, spacing: XSpacing.s) {
                            Text(xLoc(group.title)).xHeadline().foregroundStyle(XColor.textPrimary)
                            if !group.description.isEmpty {
                                Text(xLoc(group.description)).font(XFont.caption).foregroundStyle(XColor.textSecondary)
                            }
                            Divider()
                            HStack(spacing: 6) {
                                Image(systemName: "checkmark.shield").foregroundStyle(group.safety.tint)
                                Text(xLoc(group.safety.label)).font(XFont.caption).foregroundStyle(group.safety.tint)
                            }
                            Text(xLoc(group.safety.explanation)).font(XFont.caption).foregroundStyle(XColor.textSecondary)
                        }
                        .padding(XSpacing.m).frame(width: 320)
                    }
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
                        let items = sortedItems
                        let shown = showAll ? items : Array(items.prefix(Self.previewCap))
                        ForEach(shown) { item in
                            ItemRowView(item: item, onToggle: { onToggleItem(item.id) },
                                        onIgnore: onIgnoreItem.map { cb in { cb(item.id) } })
                        }
                        if items.count > Self.previewCap && !showAll {
                            // 关键：隐藏项仍会被清理。给出可点击入口让用户能审阅全部，
                            // 并明确说明"未展示项也在清理范围内"（审计 C2）。
                            Button {
                                withAnimation(.easeOut(duration: reduceMotion ? 0 : 0.2)) { showAll = true }
                            } label: {
                                Text(xLocF("显示全部 %d 项（其余 %d 项已勾选，将一并清理）", items.count, items.count - Self.previewCap))
                                    .font(XFont.caption).foregroundStyle(XColor.brand)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.top, XSpacing.xs)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
        }
        .hoverLift(2)
        .opacity(appeared ? 1 : 0)
        .offset(y: (appeared || reduceMotion) ? 0 : 16)
        .onAppear {
            if reduceMotion {
                appeared = true   // 降低动态效果：不做交错入场位移
            } else {
                withAnimation(.spring(response: 0.5, dampingFraction: 0.82).delay(Double(index) * 0.05)) {
                    appeared = true
                }
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
            XScanOrb(value: bytes.formattedBytes, label: xLoc("已发现"), size: 300)
            Text(message.isEmpty ? xLoc("正在扫描…") : message)
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
    @State private var shownBytes: Int64 = 0   // 从 0 数到释放量的动画值
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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

                Text(xLocF("已释放 %@", shownBytes.formattedBytes))
                    .xLargeTitle().foregroundStyle(XColor.textPrimary)
                    .monospacedDigit()
                    .contentTransition(.numericText())
                Text(xLocF("清理了 %d 项", report.removedCount) +
                     (report.failures.isEmpty ? "" : xLocF(" · %d 项被跳过", report.failures.count)))
                    .font(XFont.body).foregroundStyle(XColor.textSecondary)
                HStack(spacing: XSpacing.m) {
                    if intent == .trash && !report.restorable.isEmpty {
                        Button(xLoc("撤销")) { onUndo() }.buttonStyle(XSecondaryButtonStyle())
                    }
                    Button(xLoc("完成")) { onDone() }.buttonStyle(XPrimaryButtonStyle())
                }
                .padding(.top, XSpacing.s)
                .opacity(pop ? 1 : 0)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            withAnimation(.spring(response: 0.5, dampingFraction: 0.55)) { pop = true }
            countUp()
        }
    }

    /// 释放量从 0 数到目标（ease-out），命中 CleanMyMac 式满足感的关键动效。
    private func countUp() {
        let target = report.reclaimedBytes
        guard target > 0, !reduceMotion else { shownBytes = target; return }
        Task { @MainActor in
            let start = Date()
            let duration = 0.9
            while true {
                let t = min(1, Date().timeIntervalSince(start) / duration)
                let eased = 1 - pow(1 - t, 3)   // ease-out cubic
                shownBytes = Int64(Double(target) * eased)
                if t >= 1 { break }
                try? await Task.sleep(nanoseconds: 16_000_000)   // ~60fps
            }
            shownBytes = target
        }
    }
}
