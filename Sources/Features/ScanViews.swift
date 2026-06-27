import SwiftUI
import Combine
import Domain
import Infrastructure
import DesignSystem

/// 扫描会话外壳：idle 由调用方自定义，其余阶段共享。
struct SessionScaffold<Idle: View>: View {
    @ObservedObject var vm: ModuleSessionViewModel
    let cleanButtonTitle: String
    @ViewBuilder var idle: () -> Idle

    var body: some View {
        Group {
            switch vm.phase {
            case .idle:               idle().frame(maxWidth: .infinity, maxHeight: .infinity)
            case .scanning:           scanningView
            case .results, .cleaning: resultsView
            case .empty:              emptyView
            case .finished:           finishedView
            }
        }
        .animation(.easeInOut(duration: 0.35), value: vm.phase)
    }

    private var scanningView: some View {
        VStack(spacing: XSpacing.xl) {
            ScanningIndicator(bytes: vm.progressBytes, message: vm.statusMessage)
            Button("取消") { vm.cancel() }.buttonStyle(XSecondaryButtonStyle())
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var resultsView: some View {
        VStack(spacing: 0) {
            SummaryHeader(total: vm.totalReclaimable, selected: vm.selectedSize,
                          count: vm.selectedCount, itemCount: vm.totalItemCount,
                          onRescan: { vm.start() })
            ScrollView {
                LazyVStack(spacing: XSpacing.m) {
                    ForEach(Array(vm.groups.enumerated()), id: \.element.id) { idx, group in
                        ResultGroupCard(
                            group: group,
                            index: idx,
                            allSelected: vm.groupSelectionState(group),
                            onToggleGroup: { vm.setGroup(group.id, selected: $0) },
                            onToggleItem: { vm.toggleItem(groupID: group.id, itemID: $0) })
                    }
                }
                .padding(XSpacing.xl)
            }
            XActionBar(
                title: "已选 \(vm.selectedCount) 项",
                subtitle: vm.intent == .permanent ? "将彻底删除（不可恢复）" : "将移入废纸篓，可随时撤销"
            ) {
                if vm.phase == .cleaning {
                    HStack(spacing: XSpacing.s) { ProgressView().controlSize(.small); Text("清理中…").font(XFont.caption) }
                } else {
                    Button("\(cleanButtonTitle) · \(vm.selectedSize.formattedBytes)") { vm.clean() }
                        .buttonStyle(XPrimaryButtonStyle(enabled: vm.selectedCount > 0))
                        .disabled(vm.selectedCount == 0)
                }
            }
        }
    }

    private var emptyView: some View {
        VStack(spacing: XSpacing.l) {
            XEmptyState(systemImage: "checkmark.seal.fill",
                        title: "太棒了，这里很干净 ✨",
                        subtitle: "没有发现可清理的项目。")
                .frame(maxHeight: 340)
            Button("重新扫描") { vm.start() }.buttonStyle(XSecondaryButtonStyle())
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
    let total: Int64
    let selected: Int64
    let count: Int
    let itemCount: Int
    let onRescan: () -> Void
    var body: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 3) {
                Text("共发现 \(itemCount) 项 · 可清理").font(XFont.caption).foregroundStyle(XColor.textSecondary).tracking(0.2)
                Text(total.formattedBytes).xLargeTitle().foregroundStyle(XColor.textPrimary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 3) {
                Text("已选 \(count) 项").font(XFont.caption).foregroundStyle(XColor.textSecondary).tracking(0.2)
                Text(selected.formattedBytes).xTitle().foregroundStyle(XColor.brand)
            }
            Button { onRescan() } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.plain).foregroundStyle(XColor.textSecondary)
                .padding(.leading, XSpacing.m)
        }
        .padding(.horizontal, XSpacing.xl)
        .padding(.vertical, XSpacing.l)
    }
}

// MARK: - 模块通用 idle 英雄

struct ModuleIdleHero: View {
    let icon: String
    let colors: [Color]
    let title: String
    let subtitle: String
    let buttonTitle: String
    let action: () -> Void
    var body: some View {
        VStack(spacing: XSpacing.l) {
            XIconTile(systemImage: icon, colors: colors, size: 88)
                .xGlow(colors.first ?? XColor.brand, radius: 30)
            Text(title).xLargeTitle().foregroundStyle(XColor.textPrimary)
            Text(subtitle).font(XFont.body).foregroundStyle(XColor.textSecondary)
                .multilineTextAlignment(.center).frame(maxWidth: 460).lineSpacing(2)
            Button(buttonTitle, action: action)
                .buttonStyle(XPrimaryButtonStyle(large: true))
                .padding(.top, XSpacing.s)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - 智能扫描页（仪表盘式）

public struct SmartScanView: View {
    private let env: XicoEnvironment
    @StateObject private var vm: ModuleSessionViewModel
    @State private var capacity: VolumeCapacity?
    @State private var metrics: SystemMetrics?
    @State private var appeared = false

    public init(env: XicoEnvironment) {
        self.env = env
        _vm = StateObject(wrappedValue: ModuleSessionViewModel(
            env: env, title: "智能扫描", intent: .trash,
            scanProvider: { handler in await env.smartScanCoordinator().scanAll(progress: handler) }))
    }

    public var body: some View {
        SessionScaffold(vm: vm, cleanButtonTitle: "清理") { dashboard }
            .onAppear {
                refresh()
                withAnimation(.spring(response: 0.6, dampingFraction: 0.8)) { appeared = true }
            }
            .onReceive(NotificationCenter.default.publisher(for: .xicoDidClean)) { _ in refresh() }
    }

    private func refresh() {
        capacity = env.fs.volumeCapacity(for: FileManager.default.homeDirectoryForCurrentUser)
        metrics = env.metrics.sample()
    }

    private var dashboard: some View {
        let disk = capacity?.usedFraction ?? 0
        let mem = metrics?.memoryUsedFraction ?? 0
        let health = healthScore(disk: disk, mem: mem)
        return VStack(spacing: XSpacing.l) {
            healthHeader(score: health, disk: disk)

            XRingGauge(progress: disk, colors: XColor.gauge(disk), size: 272) {
                VStack(spacing: XSpacing.xs) {
                    Text((capacity?.available ?? 0).formattedBytes)
                        .font(XFont.hero).foregroundStyle(XColor.textPrimary)
                    Text("可用空间").font(XFont.body).foregroundStyle(XColor.textSecondary)
                    if let cap = capacity {
                        Text("共 \(cap.total.formattedBytes)").font(XFont.caption).foregroundStyle(XColor.textTertiary)
                    }
                }
            }

            HStack(spacing: XSpacing.m) {
                XMetricCard(value: "\(Int(disk * 100))%", label: "磁盘已用",
                            fraction: disk, colors: XColor.gauge(disk))
                XMetricCard(value: "\(Int(mem * 100))%", label: "内存占用",
                            fraction: mem, colors: [XColor.auroraViolet, XColor.auroraRose])
                XMetricCard(value: "\(health)", label: "健康评分",
                            fraction: Double(health) / 100, colors: healthColors(health))
            }
            .frame(maxWidth: 600)

            Button("开始智能扫描") { vm.start() }
                .buttonStyle(XPrimaryButtonStyle(large: true))
                .padding(.top, XSpacing.xs)
        }
        .padding(.horizontal, XSpacing.xl)
        .padding(.vertical, XSpacing.l)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .scaleEffect(appeared ? 1 : 0.94)
        .opacity(appeared ? 1 : 0)
    }

    private func healthHeader(score: Int, disk: Double) -> some View {
        VStack(spacing: 6) {
            HStack(spacing: 7) {
                Circle().fill(healthColors(score)[0]).frame(width: 8, height: 8)
                    .shadow(color: healthColors(score)[0].opacity(0.6), radius: 4)
                Text(healthTitle(score))
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                    .foregroundStyle(XColor.textPrimary)
            }
            Text("磁盘已用 \(Int(disk * 100))% · 一键扫描，安全释放空间")
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
        if s >= 80 { return [XColor.accentTeal, XColor.success] }
        if s >= 60 { return XColor.ringColors }
        return [XColor.warning, XColor.accentPink]
    }

    private func healthTitle(_ s: Int) -> String {
        if s >= 85 { return "你的 Mac 状态很好" }
        if s >= 65 { return "运行顺畅，仍可优化" }
        return "建议清理，释放空间"
    }
}

// MARK: - 单模块页

public struct ModuleScanView: View {
    @StateObject private var vm: ModuleSessionViewModel
    private let meta: ModuleMetadata?
    private let intent: DeleteIntent

    public init(env: XicoEnvironment, moduleID: ModuleID, intent: DeleteIntent) {
        let meta = ModuleCatalog.all.first { $0.id == moduleID }
        self.meta = meta
        self.intent = intent
        _vm = StateObject(wrappedValue: ModuleSessionViewModel(
            env: env, title: meta?.title ?? "", intent: intent,
            scanProvider: { handler in
                guard let scanner = env.scanner(for: moduleID) else { return [] }
                let result = (try? await scanner.scan(progress: handler))
                    ?? ScanResult(moduleID: moduleID, groups: [])
                return [result]
            }))
    }

    public var body: some View {
        SessionScaffold(vm: vm, cleanButtonTitle: intent == .permanent ? "清空" : "清理") {
            ModuleIdleHero(
                icon: meta?.systemImage ?? "magnifyingglass",
                colors: XColor.brandGradientColors,
                title: meta?.title ?? "扫描",
                subtitle: meta?.subtitle ?? "",
                buttonTitle: intent == .permanent ? "扫描废纸篓" : "开始扫描",
                action: { vm.start() })
        }
        .onAppear {
            if CommandLine.arguments.contains("--autoscan"), vm.phase == .idle { vm.start() }
        }
    }
}
