import SwiftUI
import AppKit
import Combine
import Domain
import Infrastructure
import DesignSystem

/// 扫描会话外壳：idle 由调用方自定义，其余阶段共享。
/// P4：扫描/结果态带模块身份（图标+名称，深层流程不迷路）；scanning→results 用
/// matchedGeometryEffect 让「扫描 orb 收拢为结果页汇总环」（签名时刻 S3），替代纯 crossfade 硬切。
struct SessionScaffold<Idle: View>: View {
    @ObservedObject var vm: ModuleSessionViewModel
    let cleanButtonTitle: String
    /// 模块图标（扫描态章头 + 结果页汇总环中心）。
    var moduleIcon: String = "sparkles"
    @ViewBuilder var idle: () -> Idle
    @State private var confirmPermanent = false
    @Namespace private var scanNS
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            switch vm.phase {
            case .idle:               idle().frame(maxWidth: .infinity, maxHeight: .infinity)
            case .scanning:           scanningView
            case .results, .cleaning: resultsView
            case .empty:              emptyView
            case .finished:           finishedView
            case let .failed(message): failedView(message)
            }
        }
        // S3：settle 弹簧驱动相位切换——orb 帧连续收拢到汇总环（Reduce Motion 退回 crossfade）。
        .animation(reduceMotion ? XMotion.crossfade : XMotion.settle, value: vm.phase)
        .alert(xLoc("部分项目未能恢复"), isPresented: $vm.undoFailedAlert) {
            Button(xLoc("在废纸篓中显示")) { vm.revealUndoFailuresInTrash() }
            Button(xLoc("好"), role: .cancel) {}
        } message: {
            Text(xLocF("有 %d 项无法自动放回原位（可能废纸篓已被清空、文件被移动或所在卷已卸载）。这些项仍可在废纸篓中手动找回。", vm.undoFailedItems.count))
        }
    }

    private func failedView(_ message: String) -> some View {
        VStack(spacing: XSpacing.l) {
            XEmptyState(systemImage: failedIcon,
                        title: failedTitle,
                        subtitle: message)
                .frame(maxHeight: 320)
            HStack(spacing: XSpacing.m) {
                if vm.permissionIssue {
                    Button(xLoc("开启完全磁盘访问")) { vm.openPermissionSettings() }
                        .buttonStyle(XPrimaryButtonStyle())
                }
                if vm.licenseIssue {
                    Button(xLoc("升级 Xico Pro")) {
                        NotificationCenter.default.post(name: .xicoShowPricing, object: nil)
                    }
                    .buttonStyle(XPrimaryButtonStyle())
                    Button(xLoc("导入许可证 / 设置")) {
                        NotificationCenter.default.post(name: .xicoOpenSettings, object: nil)
                    }
                    .buttonStyle(XSecondaryButtonStyle())
                }
                Button(xLoc("重试")) { vm.start() }.buttonStyle(XSecondaryButtonStyle())
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var failedIcon: String {
        if vm.permissionIssue { return "lock.shield" }
        if vm.licenseIssue { return "checkmark.seal" }
        return "exclamationmark.triangle"
    }

    private var failedTitle: String {
        if vm.permissionIssue { return xLoc("需要完全磁盘访问权限") }
        if vm.licenseIssue { return xLoc("需要有效许可证") }
        return xLoc("扫描未完成")
    }

    private var scanningView: some View {
        VStack(spacing: XSpacing.xl) {
            // 模块身份章头：深层流程不再「不知道自己在哪个模块」（P4·C3）。
            HStack(spacing: XSpacing.s) {
                Image(systemName: moduleIcon).font(XFont.captionEmphasis).foregroundStyle(XColor.brand)
                Text(xLoc(vm.title)).font(XFont.captionEmphasis).foregroundStyle(XColor.textSecondary)
            }
            .padding(.horizontal, XSpacing.m).padding(.vertical, 5)
            .background(Capsule().fill(XColor.brand.opacity(XAlpha.ghost)))
            .overlay(Capsule().stroke(XColor.hairline, lineWidth: 1))
            ScanningIndicator(bytes: vm.progressBytes, message: vm.statusMessage, progress: vm.progress > 0 ? vm.progress : nil)
                .matchedGeometryEffect(id: "scanOrb", in: scanNS)   // S3 的「源」：扫描 orb
            Button(xLoc("取消")) { vm.cancel() }.buttonStyle(XSecondaryButtonStyle())
                .keyboardShortcut(.cancelAction)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var resultsView: some View {
        ScrollViewReader { proxy in
        VStack(spacing: 0) {
            SummaryHeader(moduleIcon: moduleIcon, moduleTitle: vm.title,
                          total: vm.totalReclaimable, selected: vm.selectedSize,
                          count: vm.selectedCount, itemCount: vm.totalItemCount,
                          groups: vm.groups.map { ($0.id, $0.title, $0.totalSize) },
                          morphNS: reduceMotion ? nil : scanNS,
                          onRescan: { vm.start() },
                          onTapGroup: { id in
                              withAnimation(XMotion.settle) { proxy.scrollTo(id, anchor: .top) }
                          })
            if let warning = vm.scanWarning {
                HStack(spacing: XSpacing.s) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(XColor.warning)
                    Text(warning).font(XFont.caption).foregroundStyle(XColor.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: XSpacing.s)
                    // 未授 FDA → 就地给一枚授权按钮，让用户一键去开启后重扫，真正扫全。
                    if vm.permissionIssue {
                        Button(xLoc("开启完全磁盘访问")) { vm.openPermissionSettings() }
                            .buttonStyle(XSecondaryButtonStyle(compact: true))
                    }
                }
                .padding(.horizontal, XSpacing.xl).padding(.vertical, XSpacing.s)
                .background(XColor.warning.opacity(0.12))
            }
            ScrollView {
                LazyVStack(spacing: XSpacing.m) {
                    ForEach(Array(vm.groups.enumerated()), id: \.element.id) { idx, group in
                        ResultGroupCard(
                            group: group,
                            index: idx,
                            count: vm.groups.count,
                            allSelected: vm.groupSelectionState(group),
                            onToggleGroup: { vm.setGroup(group.id, selected: $0) },
                            onToggleItem: { vm.toggleItem(groupID: group.id, itemID: $0) },
                            onIgnoreItem: { vm.ignore(groupID: group.id, itemID: $0) })
                            .id(group.id)   // 构成条点击滚动锚点
                    }
                }
                .padding(XSpacing.xl)
            }
            XActionBar(
                title: xLocF("已选 %d 项", vm.selectedCount),
                subtitle: actionSubtitle
            ) {
                if vm.phase == .cleaning {
                    HStack(spacing: XSpacing.s) {
                        XRingGauge(progress: 0, spinning: true, colors: XColor.brandGradientColors, lineWidth: 2.5, size: 16) { EmptyView() }
                        Text(xLoc("清理中…")).font(XFont.caption).foregroundStyle(XColor.textSecondary)
                    }
                } else if vm.needsPurchaseToClean {
                    // 试用到期后扫描仍可用（看见价值），但清理需购买——直接给出「购买后清理」CTA，
                    // 而非让用户点清理再撞授权失败态。破坏性动作的授权红线仍在 vm.clean() 内保持不变。
                    Button(xLoc("购买后清理") + " · " + vm.selectedSize.formattedBytes) {
                        NotificationCenter.default.post(name: .xicoShowPricing, object: nil)
                    }
                        .buttonStyle(XPrimaryButtonStyle())
                        .accessibilityLabel(xLoc("购买后清理"))
                } else {
                    Button("\(cleanButtonTitle) · \(vm.selectedSize.formattedBytes)") {
                        if vm.intent == .permanent || vm.selectedRequiresHelper { confirmPermanent = true } else { vm.clean() }
                    }
                        .buttonStyle(XPrimaryButtonStyle(enabled: vm.selectedCount > 0))
                        .disabled(vm.selectedCount == 0)
                }
            }
        }
        }   // ScrollViewReader
        .confirmationDialog(confirmTitle, isPresented: $confirmPermanent, titleVisibility: .visible) {
            Button(confirmButtonTitle, role: .destructive) { vm.clean() }
            Button(xLoc("取消"), role: .cancel) {}
        } message: {
            Text(confirmMessage)
        }
    }

    private var actionSubtitle: String {
        if vm.intent == .permanent { return xLoc("将彻底删除（不可恢复）") }
        if vm.selectedRequiresHelper { return xLoc("普通项目移入废纸篓；管理员项目将彻底删除") }
        return xLoc("将移入废纸篓，可随时撤销")
    }

    private var confirmTitle: String {
        vm.selectedRequiresHelper ? xLoc("确认清理管理员项目？") : xLoc("确认彻底删除？")
    }

    private var confirmButtonTitle: String {
        if vm.selectedRequiresHelper { return xLocF("确认清理 %d 项", vm.selectedCount) }
        return xLocF("彻底删除 %d 项（不可恢复）", vm.selectedCount)
    }

    private var confirmMessage: String {
        if vm.selectedRequiresHelper {
            return xLoc("管理员权限项目会经特权助手永久删除，无法从废纸篓恢复；普通项目仍会移入废纸篓。")
        }
        return xLoc("这些项目将被永久删除，无法从废纸篓恢复。")
    }

    private var emptyView: some View {
        VStack(spacing: XSpacing.l) {
            XEmptyState(systemImage: "checkmark.seal.fill",
                        title: xLoc("太棒了，这里很干净 ✨"),
                        subtitle: xLoc("没有发现可清理的项目。"), kind: .success)
                .frame(maxHeight: 340)
            Button(xLoc("重新扫描")) { vm.start() }.buttonStyle(XSecondaryButtonStyle())
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder private var finishedView: some View {
        if let report = vm.lastReport {
            CompletionView(report: report, intent: vm.intent,
                           onUndo: { vm.undo() }, onDone: { vm.reset() })
        } else {
            emptyView
        }
    }
}

struct SummaryHeader: View {
    /// P4·C3/C4：模块身份（汇总环中心图标 + 名称）+ 按组构成条（点击段落滚动到对应组）。
    var moduleIcon: String = "sparkles"
    var moduleTitle: String = ""
    let total: Int64
    let selected: Int64
    let count: Int
    let itemCount: Int
    /// 构成条数据：(组 id, 组名, 字节)。空则不画构成条（兼容旧调用方）。
    var groups: [(id: String, title: String, bytes: Int64)] = []
    /// S3 收拢动画的命名空间（扫描 orb → 本汇总环）；nil = 不参与形变。
    var morphNS: Namespace.ID?
    let onRescan: () -> Void
    var onTapGroup: ((String) -> Void)?

    var body: some View {
        VStack(spacing: XSpacing.s) {
            HStack(alignment: .center, spacing: XSpacing.l) {
                // S3 的「宿」：扫描 orb 收拢为这枚汇总环（中心 = 模块图标）。
                summaryRing
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: XSpacing.xs) {
                        if !moduleTitle.isEmpty {
                            Text(xLoc(moduleTitle)).font(XFont.captionEmphasis).foregroundStyle(XColor.brand).tracking(0.2)
                            Text("·").font(XFont.caption).foregroundStyle(XColor.textTertiary)
                        }
                        Text(xLocF("共发现 %d 项 · 可清理", itemCount)).font(XFont.caption).foregroundStyle(XColor.textSecondary).tracking(0.2)
                    }
                    Text(total.formattedBytes).xLargeTitle().foregroundStyle(XColor.textPrimary)
                        .contentTransition(.numericText())
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 3) {
                    Text(xLocF("已选 %d 项", count)).font(XFont.caption).foregroundStyle(XColor.textSecondary).tracking(0.2)
                    Text(selected.formattedBytes).xTitle().foregroundStyle(XColor.brand)
                        .contentTransition(.numericText())
                }
                Button { onRescan() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.plain).foregroundStyle(XColor.textSecondary)
                    .padding(.leading, XSpacing.m)
                    .accessibilityLabel(xLoc("重新扫描"))
            }
            if groups.count > 1 { compositionBar }
        }
        .padding(.horizontal, XSpacing.xl)
        .padding(.vertical, XSpacing.l)
    }

    @ViewBuilder private var summaryRing: some View {
        let ring = XMiniRing(fraction: total > 0 ? Double(selected) / Double(total) : 0,
                             colors: XColor.brandGradientColors, size: 52, lineWidth: 5) {
            Image(systemName: moduleIcon)
                .font(XFont.bodyEmphasis)
                .foregroundStyle(XColor.brandGradient)
        }
        if let morphNS {
            ring.matchedGeometryEffect(id: "scanOrb", in: morphNS)
        } else {
            ring
        }
    }

    /// 按组构成条：一条读懂「可清理的都是什么」；点击段落/图例滚动到对应组（P4·C4）。
    private var compositionBar: some View {
        let top = groups.sorted { $0.bytes > $1.bytes }
        let denom = max(total, 1)
        return VStack(alignment: .leading, spacing: XSpacing.xs) {
            // 身份 = 组 id（稳定）：扫描中/收尾时按大小重排，同一段平滑滑动而非瞬移到别组的值上
            //（此前 id=排名 + 颜色跟排名，重排即「到处飞」——2026-07 用户实测修复）。
            XSegmentBar(segments: Array(top.prefix(6)).enumerated().map { i, g in
                .init(id: g.id, fraction: Double(g.bytes) / Double(denom), color: XColor.ring(i))
            }, height: 6)
            // 图例胶囊：点击滚动到组。超过 6 组只列前 6（余量并入轨道底色，诚实不假聚合）。
            HStack(spacing: XSpacing.s) {
                ForEach(Array(top.prefix(6).enumerated()), id: \.element.id) { i, g in
                    Button {
                        onTapGroup?(g.id)
                    } label: {
                        HStack(spacing: 3) {
                            Circle().fill(XColor.ring(i)).frame(width: 6, height: 6)
                            Text(xLoc(g.title)).font(XFont.micro).foregroundStyle(XColor.textSecondary)
                                .lineLimit(1)
                            Text("\(Int((Double(g.bytes) / Double(denom) * 100).rounded()))%")
                                .font(XFont.micro).foregroundStyle(XColor.textTertiary).monospacedDigit()
                        }
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(xLocF("%@，%@", g.title, g.bytes.formattedBytes))
                }
                Spacer(minLength: 0)
            }
        }
    }
}

// MARK: - 模块通用 idle 英雄

struct ModuleIdleHero: View {
    /// 英雄区下方的小事实胶囊（安全承诺 / 上次清理），给空旷的 idle 页一层「可信赖」的质感。
    struct Fact: Identifiable {
        let id = UUID()
        let icon: String
        let text: String
        var tint: Color = XColor.textSecondary
    }

    let icon: String
    let colors: [Color]
    let title: String
    let subtitle: String
    let buttonTitle: String
    var facts: [Fact] = []
    /// 可选的次要动作（如空间透镜的「选择文件夹…」），与主 CTA 并排。
    var secondaryTitle: String?
    var secondaryAction: (() -> Void)?
    let action: () -> Void
    var body: some View {
        VStack(spacing: XSpacing.l) {
            XIconTile(systemImage: icon, colors: colors, size: 88, flat: false)
                .xGlow(colors.first ?? XColor.brand, radius: 30)
            Text(xLoc(title)).xLargeTitle().foregroundStyle(XColor.textPrimary)
            Text(xLoc(subtitle)).font(XFont.body).foregroundStyle(XColor.textSecondary)
                .multilineTextAlignment(.center).frame(maxWidth: 460).lineSpacing(2)
            HStack(spacing: XSpacing.m) {
                Button(buttonTitle, action: action)
                    .buttonStyle(XPrimaryButtonStyle(large: true))
                    .keyboardShortcut(.defaultAction)
                if let t = secondaryTitle, let act = secondaryAction {
                    Button(t, action: act).buttonStyle(XSecondaryButtonStyle())
                }
            }
            .padding(.top, XSpacing.s)
            if !facts.isEmpty {
                HStack(spacing: XSpacing.s) {
                    ForEach(facts) { fact in
                        HStack(spacing: 5) {
                            Image(systemName: fact.icon).font(XFont.micro)
                                .foregroundStyle(fact.tint)
                            Text(fact.text).font(XFont.caption).foregroundStyle(XColor.textSecondary)
                        }
                        .padding(.horizontal, XSpacing.m)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(XColor.surface.opacity(0.6)))
                        .overlay(Capsule().stroke(XColor.hairline, lineWidth: 1))
                    }
                }
                .padding(.top, XSpacing.m)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - 智能扫描页（idle 仪表盘 + 六类目并行中枢，docs/14 P1）

public struct SmartScanView: View {
    private let model: AppModel
    private let env: XicoEnvironment
    /// 六类目并行中枢（缓存于 AppModel，切换侧栏不丢结果与下钻位置）。
    @ObservedObject private var hub: SmartScanHubViewModel
    /// 高频数据源（温度/SMART 子项取自这里；读不到即「暂无数据」，诚实降权）。
    @ObservedObject private var feed: MetricsFeed
    @State private var capacity: VolumeCapacity?
    @State private var metrics: SystemMetrics?
    @State private var appeared = false
    @State private var showHealthDetail = false
    /// S-B 阈值跃迁的一次性辉光脉冲。
    @State private var healthGlow = false
    /// 健康分跨阈值的一次性缩放。显式回到 1，避免 PhaseAnimator 在隐藏窗口仍维持显示周期。
    @State private var healthScale: CGFloat = 1
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(model: AppModel) {
        self.model = model
        self.env = model.env
        self.hub = model.smartScanHub
        self._feed = ObservedObject(wrappedValue: model.liveMetricsFeed)
    }

    public var body: some View {
        Group {
            switch hub.phase {
            case .idle:
                dashboard.frame(maxWidth: .infinity, maxHeight: .infinity)
            case .active:
                SmartScanHubActiveView(hub: hub)
            case .finished:
                if let report = hub.lastReport {
                    CompletionView(report: report, intent: .trash, note: hub.spaceNote,
                                   onUndo: { hub.undo() }, onDone: { hub.reset() })
                } else {
                    dashboard.frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .animation(reduceMotion ? XMotion.crossfade : XMotion.settle, value: hub.phase)
        .alert(xLoc("部分项目未能恢复"), isPresented: $hub.undoFailedAlert) {
            Button(xLoc("在废纸篓中显示")) { hub.revealUndoFailuresInTrash() }
            Button(xLoc("好"), role: .cancel) {}
        } message: {
            Text(xLocF("有 %d 项无法自动放回原位（可能废纸篓已被清空、文件被移动或所在卷已卸载）。这些项仍可在废纸篓中手动找回。", hub.undoFailedItems.count))
        }
        .onAppear {
            refresh()
            withAnimation(XMotion.settle) { appeared = true }
        }
        .onReceive(NotificationCenter.default.publisher(for: .xicoDidClean)) { _ in refresh() }
    }

    @State private var lastUndoable: CleaningRecord?
    @State private var undoing = false

    private func refresh() {
        capacity = env.fs.volumeCapacity(for: FileManager.default.homeDirectoryForCurrentUser)
        metrics = env.metrics.sample()
        // 只在废纸篓里文件确实还在时才展示撤销入口——清空废纸篓后不再空许「可放回原位」。
        lastUndoable = env.history.firstUndoable()
    }

    /// 撤销最近一次清理（把废纸篓项放回原位）——把独家卖点「可撤销」放到主页可发现处。
    private func undoLast() {
        guard let rec = lastUndoable, !undoing else { return }
        undoing = true
        let report = CleaningReport(removedCount: rec.removedCount, reclaimedBytes: rec.reclaimedBytes,
                                    failures: [], restorable: rec.restorable)
        Task {
            let result = await env.cleaningEngine.undo(report)
            if result.allSucceeded { env.history.remove(id: rec.id) }
            // 部分失败：只保留仍未恢复的项为可撤销，用户可重试（而非丢掉全部重试能力）
            else { env.history.updateRestorable(id: rec.id, to: result.failed) }
            refresh()
            undoing = false
        }
    }

    @ViewBuilder private var recentCleanupCard: some View {
        if let rec = lastUndoable {
            HStack(spacing: XSpacing.m) {
                XIconTile(systemImage: "clock.arrow.circlepath", colors: [XColor.accentTeal, XColor.success], size: 30)
                VStack(alignment: .leading, spacing: 1) {
                    Text(xLocF("上次清理释放 %@", rec.reclaimedBytes.formattedBytes))
                        .font(XFont.bodyEmphasis).foregroundStyle(XColor.textPrimary)
                    Text(xLoc("移入废纸篓 · 可一键放回原位")).font(XFont.caption).foregroundStyle(XColor.textSecondary)
                }
                Spacer()
                Button(undoing ? xLoc("撤销中…") : xLoc("撤销")) { undoLast() }
                    .buttonStyle(XSecondaryButtonStyle())
                    .disabled(undoing)
            }
            .padding(XSpacing.m)
            .frame(maxWidth: 600)
            .background(XColor.surface, in: RoundedRectangle(cornerRadius: XRadius.card, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: XRadius.card, style: .continuous).strokeBorder(XColor.border, lineWidth: 1))
        }
    }

    /// 可解释健康分（P6·1）：五子项加权，全部可点开溯源；不可用子项如实标注并降权。
    private var healthDetail: HealthScore {
        let thermalState = ProcessInfo.processInfo.thermalState
        let thermalLevel: Int = {
            switch thermalState {
            case .nominal: return 0
            case .fair: return 1
            case .serious: return 2
            default: return 3
            }
        }()
        let thermalText: String = {
            switch thermalState {
            case .nominal: return xLoc("正常")
            case .fair: return xLoc("偏高")
            case .serious: return xLoc("严重")
            default: return xLoc("临界")
            }
        }()
        // SMART：只统计内置卷；详情采样未跑过（列表为空）时如实 nil。
        let internals = feed.storageVolumes.filter(\.isInternal)
        let smartHealthy: Bool? = internals.isEmpty ? nil
            : internals.allSatisfy { $0.smartStatus == "Verified" || $0.smartStatus == "已验证" }
        return HealthScore.compute(
            diskFreeFraction: capacity.map { max(0, 1 - $0.usedFraction) },
            diskFreeText: capacity.map { xLocF("%@ 可用", $0.available.formattedBytes) } ?? "—",
            memoryUsedFraction: metrics?.memoryUsedFraction,
            memoryText: metrics.map { "\(Int($0.memoryUsedFraction * 100))%" } ?? "—",
            cpuTempCelsius: feed.liveSnapshot?.cpuTemp,
            thermalLevel: thermalLevel,
            thermalText: thermalText,
            smartAllHealthy: smartHealthy,
            smartText: internals.isEmpty ? xLoc("打开硬件页后计入") : (smartHealthy == true ? xLoc("全部正常") : xLoc("有告警")))
    }

    /// 首帧未采样占位（docs/16 P0-5）：世界级首帧从不显示假 0——「0%→88%」硬跳是廉价感第一来源。
    /// 结构感 skeleton + 旋转环，真值到达即 crossfade 到 dashboardLoaded。
    @ViewBuilder private var dashboard: some View {
        Group {
            if capacity == nil && metrics == nil {
                dashboardSkeleton
            } else {
                dashboardLoaded
            }
        }
        .animation(XMotion.crossfade, value: capacity == nil && metrics == nil)
    }

    private var dashboardSkeleton: some View {
        VStack(spacing: XSpacing.xl) {
            XSkeleton(width: 240, height: 22)
            XRingGauge(progress: 0, spinning: true, colors: XColor.ringColors,
                       lineWidth: 16, size: 296, a11yLabel: xLoc("加载中")) {
                VStack(spacing: XSpacing.s) {
                    XSkeleton(width: 150, height: 36)
                    XSkeleton(width: 96, height: 12)
                }
            }
            HStack(spacing: XSpacing.m) {
                ForEach(0..<3, id: \.self) { _ in
                    XCard(padding: XSpacing.l) {
                        HStack(spacing: XSpacing.m) {
                            Circle().fill(XColor.surfaceAlt).frame(width: 46, height: 46)
                            VStack(alignment: .leading, spacing: 6) {
                                XSkeleton(width: 64, height: 16)
                                XSkeleton(width: 88, height: 10)
                            }
                            Spacer(minLength: 0)
                        }
                    }
                }
            }
        }
    }

    private var dashboardLoaded: some View {
        let disk = capacity?.usedFraction ?? 0
        let free = max(0, 1 - disk)
        let mem = metrics?.memoryUsedFraction ?? 0
        let detail = healthDetail
        let health = detail.total
        return VStack(spacing: XSpacing.xl) {
            healthHeader(score: health)

            // 环填「可用率」，配色跟随当前主题（ringColors）——首屏中心元件与卡片/按钮同主题，
            // 换 暖阳/品红 等主题时不再是一枝独秀的青蓝。环越满 = 越空 = 越好。
            XRingGauge(progress: free, colors: XColor.ringColors, lineWidth: 16, size: 296,
                       a11yLabel: xLoc("可用空间")) {
                VStack(spacing: XSpacing.xxs) {
                    heroBytes(capacity?.available ?? 0)
                    Text(xLoc("可用空间")).font(XFont.body).foregroundStyle(XColor.textSecondary)
                    if let cap = capacity {
                        Text(xLocF("共 %@ · 已用 %d%%", cap.total.formattedBytes, Int(disk * 100)))
                            .font(XFont.caption).foregroundStyle(XColor.textTertiary)
                    }
                }
            }

            // 三卡配色统一走语义 gauge（内存不再恒定紫红，与磁盘一致按占用着色）。
            HStack(spacing: XSpacing.m) {
                XMetricCard(value: "\(Int(disk * 100))%", label: xLoc("磁盘已用"),
                            fraction: disk, colors: XColor.gauge(disk))
                XMetricCard(value: "\(Int(mem * 100))%", label: xLoc("内存占用"),
                            fraction: mem, colors: XColor.gauge(mem))
                // 健康评分可点开溯源（P6·1）：每一分都能看到来自哪个子项、原始值是什么。
                Button {
                    showHealthDetail = true
                } label: {
                    XMetricCard(value: "\(health)", label: xLoc("健康评分"),
                                fraction: Double(health) / 100, colors: healthColors(health))
                }
                .buttonStyle(.plain)
                // S-B「健康分登场」（docs/16）：跨过优秀阈值（≥85）那一刻——
                // 一次 .levelChange 触感 + 品牌辉光脉冲 + 三阶段登场
                // （seed 0.96 → overshoot 1.06 → settle 1.0），把「跨过一道坎」物理化。
                // 环色同帧从中性阶跃迁为品牌极光（healthColors 的 ≥85 分支），声触光色同刻发生。
                .xGlow(XColor.brand, radius: healthGlow ? 22 : 0, opacity: healthGlow ? 0.5 : 0)
                .scaleEffect(reduceMotion ? 1 : healthScale)
                .onChange(of: health >= 85) { _, excellent in
                    guard excellent else { return }
                    XHaptic.perform(.levelChange)
                    var transaction = Transaction()
                    transaction.disablesAnimations = true
                    withTransaction(transaction) { healthScale = 0.96 }
                    withAnimation(XMotion.celebrateSoft) { healthScale = 1.06 }
                    withAnimation(XMotion.celebrateSoft) { healthGlow = true }
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 220_000_000)
                        withAnimation(XMotion.settle) { healthScale = 1 }
                        try? await Task.sleep(nanoseconds: 680_000_000)
                        withAnimation(XMotion.crossfade) { healthGlow = false }
                    }
                }
                .accessibilityLabel(xLocF("健康评分 %d，点按查看构成", health))
                .popover(isPresented: $showHealthDetail, arrowEdge: .bottom) {
                    HealthBreakdownView(score: detail)
                }
            }
            .frame(maxWidth: 600)

            VStack(spacing: XSpacing.s) {
                Button(xLoc("开始智能扫描")) { hub.start() }
                    .buttonStyle(XPrimaryButtonStyle(large: true))
                    .keyboardShortcut(.defaultAction)
                // 一句话讲清扫描面（六类并行 + 逐类到达是中枢的签名能力，值得在 CTA 下亮明）。
                Text(xLoc("六类并行：系统垃圾 · 废纸篓 · 威胁 · 重复 · 相似图片 · 大文件"))
                    .font(XFont.caption).foregroundStyle(XColor.textTertiary)
            }
            .padding(.top, XSpacing.s)

            recentCleanupCard

            // 工具入口：文件粉碎不是扫描类目（无扫描相、不可撤销），以工具行形式从中枢直达。
            Button {
                withAnimation(XMotion.snappy) { model.selection = .shredder }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "flame").font(XFont.micro)
                    Text(xLoc("需要彻底粉碎文件？打开文件粉碎")).font(XFont.caption)
                }
                .foregroundStyle(XColor.textTertiary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(xLoc("文件粉碎"))

        }
        .padding(.horizontal, XSpacing.xl)
        .padding(.vertical, XSpacing.l)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .scaleEffect(appeared ? 1 : 0.94)
        .opacity(appeared ? 1 : 0)
    }

    /// 环心大数字：数值与单位分开排印（值大、单位小），保证单行不换行、居中不断版。
    private func heroBytes(_ bytes: Int64) -> some View {
        let s = bytes.formattedBytes
        let parts = s.split(separator: " ", maxSplits: 1)
        let value = parts.first.map(String.init) ?? s
        let unit = parts.count > 1 ? String(parts[1]) : ""
        return HStack(alignment: .firstTextBaseline, spacing: 5) {
            Text(value)
                .font(XFont.heroCompact)
            Text(unit)
                .font(XFont.heroUnit)
                .foregroundStyle(XColor.textSecondary)
        }
        .foregroundStyle(XColor.textPrimary)
        .lineLimit(1)
        .minimumScaleFactor(0.6)   // 极端超长（999.99 GB）整体等比缩小而非断行
        .layoutPriority(1)
    }

    private func healthHeader(score: Int) -> some View {
        VStack(spacing: 6) {
            HStack(spacing: 7) {
                Circle().fill(healthColors(score)[0]).frame(width: 8, height: 8)
                    .shadow(color: healthColors(score)[0].opacity(0.6), radius: 4)
                Text(healthTitle(score))
                    .font(XFont.titleRounded)
                    .foregroundStyle(XColor.textPrimary)
            }
            // 磁盘占用只在环副标题出现一次；此处不再重复 %（原首屏三处重复占用率）。
            Text(xLoc("一键扫描，安全释放空间"))
                .font(XFont.callout).foregroundStyle(XColor.textSecondary)
        }
        .padding(.bottom, XSpacing.xs)
    }

    private func healthScore(disk: Double, mem: Double) -> Int {
        let d = max(0, disk - 0.60) / 0.40   // 0 当 ≤60%，1 当 100%
        let m = max(0, mem - 0.70) / 0.30    // 0 当 ≤70%，1 当 100%
        let penalty = (d * 0.62 + m * 0.38) * 58
        return max(20, min(100, Int((100 - penalty).rounded())))
    }

    private func healthColors(_ s: Int) -> [Color] {
        // S-B 色彩跃迁（docs/16）：品牌极光只留给「优秀」——从中性阶跃迁到品牌色本身就是
        // 奖励语义；一般状态用中性 graphite（不发糖），差状态保留警示色（诚实指标）。
        if s >= 85 { return XColor.brandGradientColors }
        if s >= 60 { return [XColor.textTertiary, XColor.textSecondary] }
        return [XColor.warning, XColor.accentPink]
    }

    private func healthTitle(_ s: Int) -> String {
        if s >= 85 { return xLoc("你的 Mac 状态很好") }
        if s >= 65 { return xLoc("运行顺畅，仍可优化") }
        return xLoc("建议清理，释放空间")
    }
}

/// 健康分构成浮层（P6·1）：逐子项列出 当前值 / 得分 / 打分口径 / 改善建议——
/// 每一分都可溯源，「诚实指标」铁律的展示面。
private struct HealthBreakdownView: View {
    let score: HealthScore

    var body: some View {
        VStack(alignment: .leading, spacing: XSpacing.s) {
            HStack {
                Text(xLoc("健康评分构成")).font(XFont.headline).foregroundStyle(XColor.textPrimary)
                Spacer()
                Text("\(score.total)").font(XFont.monoLarge).foregroundStyle(XColor.brand)
            }
            Divider()
            ForEach(score.components) { comp in
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(xLoc(comp.titleKey)).font(XFont.bodyEmphasis).foregroundStyle(XColor.textPrimary)
                        Text("\(Int(comp.weight * 100))%").font(XFont.nano).foregroundStyle(XColor.textTertiary)
                        Spacer()
                        Text(comp.valueText).font(XFont.caption).foregroundStyle(XColor.textSecondary)
                        if let s = comp.score {
                            Text("\(s)").font(XFont.mono)
                                .foregroundStyle(s >= 80 ? XColor.success : (s >= 50 ? XColor.warning : XColor.danger))
                                .frame(minWidth: 30, alignment: .trailing)
                        } else {
                            Text(xLoc("暂无数据")).font(XFont.caption).foregroundStyle(XColor.textTertiary)
                        }
                    }
                    if let s = comp.score {
                        GeometryReader { g in
                            ZStack(alignment: .leading) {
                                Capsule().fill(XColor.surfaceAlt)
                                Capsule().fill(s >= 80 ? XColor.success : (s >= 50 ? XColor.warning : XColor.danger))
                                    .frame(width: max(3, g.size.width * CGFloat(s) / 100))
                            }
                        }
                        .frame(height: 4)
                    }
                    Text(xLoc(comp.basisKey) + " · " + xLoc(comp.adviceKey))
                        .font(XFont.micro).foregroundStyle(XColor.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, 2)
            }
            Divider()
            Text(xLoc("分数只反映机器当前状态，与是否运行过扫描无关。数据不可用的子项不计分。"))
                .font(XFont.micro).foregroundStyle(XColor.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(XSpacing.l)
        .frame(width: 380)
    }
}

/// 线程安全地收集失败模块名（并发扫描期写、主线程读）。
final class FailureBox: @unchecked Sendable {
    private let lock = NSLock()
    private var names: [String] = []
    func reset() { lock.lock(); names = []; lock.unlock() }
    func add(_ name: String) { lock.lock(); names.append(name); lock.unlock() }
    func summary() -> String? {
        lock.lock(); defer { lock.unlock() }
        guard !names.isEmpty else { return nil }
        return xLocF("部分模块扫描失败：%@。结果可能不完整。", names.joined(separator: "、"))
    }
}

// MARK: - 单模块页

public struct ModuleScanView: View {
    // 会话由 AppModel 缓存并持有：切换侧栏再回来复用同一实例，扫描进度/结果不丢（审计 P1）。
    @ObservedObject private var vm: ModuleSessionViewModel
    private let meta: ModuleMetadata?
    private let intent: DeleteIntent
    private let history: HistoryStore
    /// idle 英雄区的信任胶囊——在 .onAppear / .xicoDidClean 时算一次并缓存，
    /// 而非每次 body 求值都读历史库 + 造格式化器（审计 ScanViews:492 P3）。
    @State private var facts: [ModuleIdleHero.Fact] = []

    /// 相对时间格式化器只造一次（与 DiskBenchmarkView.dateFmt 同法）；locale 在算 facts 时按需刷新，
    /// 以跟随运行时语言切换。
    private static let relativeFmt: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f
    }()

    public init(model: AppModel, moduleID: ModuleID, intent: DeleteIntent) {
        let meta = ModuleCatalog.all.first { $0.id == moduleID }
        self.meta = meta
        self.intent = intent
        self.history = model.env.history
        self.vm = model.moduleSession(moduleID: moduleID, intent: intent, title: meta?.title ?? "")
    }

    /// idle 英雄区的信任胶囊：安全承诺 + 该模块最近一次清理成果。只在出现/清理后算一次，写入 @State。
    private func computeFacts() {
        var result: [ModuleIdleHero.Fact] = []
        if intent == .permanent {
            result.append(.init(icon: "exclamationmark.shield", text: xLoc("彻底删除 · 执行前二次确认"),
                                tint: XColor.warning))
        } else {
            result.append(.init(icon: "arrow.uturn.backward.circle", text: xLoc("仅移入废纸篓 · 一键可撤销"),
                                tint: XColor.success))
        }
        if let title = meta?.title,
           let rec = history.recent(30).first(where: { $0.module == title && $0.reclaimedBytes > 0 }) {
            let fmt = Self.relativeFmt
            fmt.locale = XLocale.swiftUILocale
            let when = fmt.localizedString(for: rec.date, relativeTo: Date())
            result.append(.init(icon: "clock.arrow.circlepath",
                                text: xLocF("上次清理 %@ · 释放 %@", when, rec.reclaimedBytes.formattedBytes)))
        }
        facts = result
    }

    public var body: some View {
        SessionScaffold(vm: vm, cleanButtonTitle: intent == .permanent ? xLoc("清空") : xLoc("清理"),
                        moduleIcon: meta?.systemImage ?? "magnifyingglass") {
            ModuleIdleHero(
                icon: meta?.systemImage ?? "magnifyingglass",
                colors: XColor.brandGradientColors,
                title: meta?.title ?? xLoc("扫描"),
                subtitle: meta?.subtitle ?? "",
                buttonTitle: intent == .permanent ? xLoc("扫描废纸篓") : xLoc("开始扫描"),
                facts: facts,
                action: { vm.start() })
        }
        .onAppear {
            computeFacts()
            if CommandLine.arguments.contains("--autoscan"), vm.phase == .idle { vm.start() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .xicoDidClean)) { _ in computeFacts() }
    }
}
