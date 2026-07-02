import SwiftUI
import AppKit
import Combine
import Domain
import Infrastructure
import DesignSystem

/// 扫描会话外壳：idle 由调用方自定义，其余阶段共享。
struct SessionScaffold<Idle: View>: View {
    @ObservedObject var vm: ModuleSessionViewModel
    let cleanButtonTitle: String
    @ViewBuilder var idle: () -> Idle
    @State private var confirmPermanent = false

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
        .animation(.easeInOut(duration: 0.35), value: vm.phase)
        .alert("部分项目未能恢复", isPresented: $vm.undoFailedAlert) {
            Button("在废纸篓中显示") { vm.revealUndoFailuresInTrash() }
            Button("好", role: .cancel) {}
        } message: {
            Text("有 \(vm.undoFailedItems.count) 项无法自动放回原位（可能废纸篓已被清空、文件被移动或所在卷已卸载）。这些项仍可在废纸篓中手动找回。")
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
                    Button("开启完全磁盘访问") { vm.openPermissionSettings() }
                        .buttonStyle(XPrimaryButtonStyle())
                }
                if vm.licenseIssue {
                    Button("购买 Xico") { NSWorkspace.shared.open(LicenseService.purchaseURL()) }
                        .buttonStyle(XPrimaryButtonStyle())
                    Button("导入许可证 / 设置") {
                        NotificationCenter.default.post(name: .xicoOpenSettings, object: nil)
                    }
                    .buttonStyle(XSecondaryButtonStyle())
                }
                Button("重试") { vm.start() }.buttonStyle(XSecondaryButtonStyle())
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
        if vm.permissionIssue { return "需要完全磁盘访问权限" }
        if vm.licenseIssue { return "需要有效许可证" }
        return "扫描未完成"
    }

    private var scanningView: some View {
        VStack(spacing: XSpacing.xl) {
            ScanningIndicator(bytes: vm.progressBytes, message: vm.statusMessage)
            Button("取消") { vm.cancel() }.buttonStyle(XSecondaryButtonStyle())
                .keyboardShortcut(.cancelAction)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var resultsView: some View {
        VStack(spacing: 0) {
            SummaryHeader(total: vm.totalReclaimable, selected: vm.selectedSize,
                          count: vm.selectedCount, itemCount: vm.totalItemCount,
                          onRescan: { vm.start() })
            if let warning = vm.scanWarning {
                HStack(spacing: XSpacing.s) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(XColor.warning)
                    Text(warning).font(XFont.caption).foregroundStyle(XColor.textSecondary)
                    Spacer()
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
                            allSelected: vm.groupSelectionState(group),
                            onToggleGroup: { vm.setGroup(group.id, selected: $0) },
                            onToggleItem: { vm.toggleItem(groupID: group.id, itemID: $0) },
                            onIgnoreItem: { vm.ignore(groupID: group.id, itemID: $0) })
                    }
                }
                .padding(XSpacing.xl)
            }
            XActionBar(
                title: "已选 \(vm.selectedCount) 项",
                subtitle: actionSubtitle
            ) {
                if vm.phase == .cleaning {
                    HStack(spacing: XSpacing.s) { ProgressView().controlSize(.small); Text("清理中…").font(XFont.caption) }
                } else {
                    Button("\(cleanButtonTitle) · \(vm.selectedSize.formattedBytes)") {
                        if vm.intent == .permanent || vm.selectedRequiresHelper { confirmPermanent = true } else { vm.clean() }
                    }
                        .buttonStyle(XPrimaryButtonStyle(enabled: vm.selectedCount > 0))
                        .disabled(vm.selectedCount == 0)
                }
            }
        }
        .confirmationDialog(confirmTitle, isPresented: $confirmPermanent, titleVisibility: .visible) {
            Button(confirmButtonTitle, role: .destructive) { vm.clean() }
            Button("取消", role: .cancel) {}
        } message: {
            Text(confirmMessage)
        }
    }

    private var actionSubtitle: String {
        if vm.intent == .permanent { return "将彻底删除（不可恢复）" }
        if vm.selectedRequiresHelper { return "普通项目移入废纸篓；管理员项目将彻底删除" }
        return "将移入废纸篓，可随时撤销"
    }

    private var confirmTitle: String {
        vm.selectedRequiresHelper ? "确认清理管理员项目？" : "确认彻底删除？"
    }

    private var confirmButtonTitle: String {
        if vm.selectedRequiresHelper { return "确认清理 \(vm.selectedCount) 项" }
        return "彻底删除 \(vm.selectedCount) 项（不可恢复）"
    }

    private var confirmMessage: String {
        if vm.selectedRequiresHelper {
            return "管理员权限项目会经特权助手永久删除，无法从废纸篓恢复；普通项目仍会移入废纸篓。"
        }
        return "这些项目将被永久删除，无法从废纸篓恢复。"
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
                .keyboardShortcut(.defaultAction)
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
        let failures = FailureBox()
        let model = ModuleSessionViewModel(
            env: env, title: "智能扫描", intent: .trash,
            scanProvider: { handler in
                failures.reset()
                return try await env.smartScanCoordinator().scanAll(
                    progress: handler, onModuleFailure: { failures.add($0) })
            })
        model.postScanWarning = { failures.summary() }
        _vm = StateObject(wrappedValue: model)
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
                .keyboardShortcut(.defaultAction)
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

/// 线程安全地收集失败模块名（并发扫描期写、主线程读）。
final class FailureBox: @unchecked Sendable {
    private let lock = NSLock()
    private var names: [String] = []
    func reset() { lock.lock(); names = []; lock.unlock() }
    func add(_ name: String) { lock.lock(); names.append(name); lock.unlock() }
    func summary() -> String? {
        lock.lock(); defer { lock.unlock() }
        guard !names.isEmpty else { return nil }
        return "部分模块扫描失败：\(names.joined(separator: "、"))。结果可能不完整。"
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
        let model = ModuleSessionViewModel(
            env: env, title: meta?.title ?? "", intent: intent,
            scanProvider: { handler in
                guard let scanner = env.scanner(for: moduleID) else { return [] }
                // 不再吞掉错误：失败会上抛到 ViewModel 呈现为失败态，而非伪装成「很干净」
                return [try await scanner.scan(progress: handler)]
            })
        // 威胁模块：删除 plist 前先 bootout，停用已加载的恶意 agent
        if moduleID == .malware {
            model.beforeClean = { items in
                await ThreatRemediation.bootoutUserAgents(items.map(\.url))
            }
        }
        _vm = StateObject(wrappedValue: model)
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
