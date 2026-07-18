import SwiftUI
import AppKit
import Domain
import Infrastructure
import DesignSystem

@MainActor
final class UninstallerModel: ObservableObject {
    @Published var apps: [InstalledApp] = []
    @Published private(set) var selected: InstalledApp?
    @Published private(set) var batch: UninstallBatch?
    @Published var loading = false
    @Published private(set) var scanningTargets = false
    @Published private(set) var working = false
    @Published private(set) var confirmationID: UUID?
    @Published var lastFreed: Int64?
    @Published var lastRemovedCount: Int = 0
    @Published var query = ""

    var filteredApps: [InstalledApp] {
        query.isEmpty ? apps : apps.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    typealias TargetScanner = @Sendable (InstalledApp) async -> UninstallBatch?

    private struct ConfirmationContext {
        let confirmation: UninstallConfirmation
        let generation: UUID
        let app: InstalledApp
        let appName: String
        let selectedCount: Int
        let selectedSize: Int64
    }

    private struct ExecutionContext {
        let confirmation: UninstallConfirmation
        let generation: UUID
        let app: InstalledApp
    }

    private let env: XicoEnvironment
    private let targetScanner: TargetScanner
    private var appListGeneration = UUID()
    private var targetScanGeneration = UUID()
    private var confirmationContext: ConfirmationContext?
    private var executionContext: ExecutionContext?
    private(set) var confirmationGeneration: UUID?
    private(set) var activeExecutionGeneration: UUID?

    init(env: XicoEnvironment, targetScanner: TargetScanner? = nil) {
        self.env = env
        let service = env.uninstaller
        self.targetScanner = targetScanner ?? { app in
            await Task.detached {
                try? service.uninstallTargets(for: app, mode: .uninstallApp)
            }.value
        }
    }

    var isInteractionFrozen: Bool { confirmationContext != nil || working }

    var confirmationAppName: String? { confirmationContext?.appName }
    var confirmationSelectedCount: Int? { confirmationContext?.selectedCount }
    var confirmationSelectedSize: Int64? { confirmationContext?.selectedSize }

    var targets: [UninstallCandidate] { batch?.candidates ?? [] }

    func load() {
        guard !isInteractionFrozen else { return }
        let generation = UUID()
        appListGeneration = generation
        loading = true
        let env = self.env
        Task {
            // 第一阶段：秒级出列表（无体积）
            let apps = await Task.detached { env.uninstaller.listApps() }.value
            guard self.appListGeneration == generation, !self.isInteractionFrozen else { return }
            self.apps = apps
            self.loading = false
            // 第二阶段：后台补齐体积并按大小重排
            let sized = await Task.detached { () -> [InstalledApp] in
                apps.compactMap { env.uninstaller.appByFillingSize($0) }
                    .sorted { $0.size > $1.size }
            }.value
            guard self.appListGeneration == generation, !self.isInteractionFrozen else { return }
            self.apps = sized
        }
    }

    func select(_ app: InstalledApp) {
        guard !isInteractionFrozen else { return }
        startTargetScan(for: app, replacingSelection: true)
    }

    private func startTargetScan(for app: InstalledApp, replacingSelection: Bool) {
        // 立即清空上一应用的列表——避免 A→B 快切时 B 的头部仍绑着 A 的旧文件列表，
        // 用户此刻确认就会误删「另一应用」的文件（P2 数据安全）。
        let generation = UUID()
        targetScanGeneration = generation
        batch = nil
        scanningTargets = true
        if replacingSelection {
            selected = app
            lastFreed = nil
        }
        let targetScanner = self.targetScanner
        Task {
            let scannedBatch = await targetScanner(app)
            // ID/路径相同仍不足够：A1→B→A2→A1 可让第一轮 A1 回来时再次命中。
            // generation、完整 InstalledApp（含 opaque provenance/物理证明）和批次绑定必须全相等。
            guard self.targetScanGeneration == generation,
                  self.selected == app else { return }
            self.scanningTargets = false
            guard let scannedBatch,
                  scannedBatch.mode == .uninstallApp,
                  scannedBatch.app == app else {
                self.batch = nil
                return
            }
            self.batch = scannedBatch
        }
    }

    func toggle(_ id: UUID) {
        guard !isInteractionFrozen else { return }
        guard var batch else { return }
        batch.toggle(id)
        self.batch = batch
    }

    var allTargetsSelected: Bool { batch?.allPolicySelected ?? false }
    func toggleAllTargets(_ on: Bool) {
        guard !isInteractionFrozen else { return }
        guard var batch else { return }
        batch.setAll(on)
        self.batch = batch
    }

    var selectedSize: Int64 { batch?.selectedSize ?? 0 }
    var selectedCount: Int { batch?.selectedCount ?? 0 }

    @Published var licenseBlocked = false

    /// Freezes the exact reviewed batch at the capability boundary. Features retains only the
    /// opaque confirmation and never reconstructs or substitutes its batch snapshot.
    @discardableResult
    func beginConfirmation() -> UUID? {
        guard !working else { return nil }
        if let confirmationContext { return confirmationContext.generation }
        guard let app = selected, let batch,
              batch.mode == .uninstallApp,
              batch.app == app,
              batch.selectedCount > 0 else { return nil }
        let confirmation = env.uninstallCapability.beginConfirmation(for: batch)
        let generation = UUID()
        confirmationContext = ConfirmationContext(confirmation: confirmation,
                                                  generation: generation,
                                                  app: app,
                                                  appName: confirmation.summary.appName,
                                                  selectedCount: confirmation.summary.selectedCount,
                                                  selectedSize: confirmation.summary.selectedSize)
        confirmationGeneration = generation
        confirmationID = confirmation.id
        // A list-size refresh that was already in flight may not mutate UI under the dialog.
        appListGeneration = UUID()
        loading = false
        return generation
    }

    func cancelConfirmation() {
        guard let generation = confirmationContext?.generation else { return }
        cancelConfirmation(generation: generation)
    }

    func cancelConfirmation(generation: UUID) {
        guard confirmationContext?.generation == generation else { return }
        confirmationContext = nil
        confirmationGeneration = nil
        confirmationID = nil
    }

    func uninstallConfirmed() {
        guard !working, let reviewed = confirmationContext else { return }
        // 卸载同样是删除操作，必须过许可证门禁（与扫描/清理一致，堵住"试用到期仍可卸载"）
        guard env.license.status().state.allowsCommercialUse else { licenseBlocked = true; return }
        confirmationContext = nil
        confirmationGeneration = nil
        confirmationID = nil
        let generation = UUID()
        let execution = ExecutionContext(confirmation: reviewed.confirmation,
                                         generation: generation,
                                         app: reviewed.app)
        executionContext = execution
        activeExecutionGeneration = generation
        working = true
        let env = self.env
        Task {
            do {
                let result = try await env.uninstallCapability.execute(
                    confirmation: execution.confirmation)
                self.finishExecution(generation: generation, result: result)
            } catch {
                self.finishExecution(generation: generation, error: error)
            }
        }
    }

    /// One terminal may mutate Feature state only while its execution generation still owns it.
    /// Internal visibility gives deterministic stale-terminal regression coverage.
    func finishExecution(generation: UUID,
                         result: DestructiveExecutionResult<CleaningReport>) {
        guard let execution = executionContext,
              execution.generation == generation,
              activeExecutionGeneration == generation else { return }
        switch result {
        case .failedClosed:
            clearActiveExecution(generation: generation)
            invalidateReviewedBatchAndRefresh(app: execution.app)
        case .executed(let report):
            lastFreed = report.reclaimedBytes
            lastRemovedCount = report.removedCount
            env.history.record(module: "卸载 · \(execution.app.name)",
                               reclaimedBytes: report.reclaimedBytes,
                               removedCount: report.removedCount)
            NotificationCenter.default.post(name: .xicoDidClean, object: nil)
            clearActiveExecution(generation: generation)
            selected = nil
            batch = nil
            targetScanGeneration = UUID()
            scanningTargets = false
            load()
        }
    }

    private func finishExecution(generation: UUID, error: Error) {
        guard let execution = executionContext,
              execution.generation == generation,
              activeExecutionGeneration == generation else { return }
        clearActiveExecution(generation: generation)
        if Self.invalidatesReviewedBatch(error) {
            invalidateReviewedBatchAndRefresh(app: execution.app)
            return
        }
        // Read-only/pre-claim validation errors are retryable without substituting the reviewed
        // payload: restore the same opaque confirmation under a fresh UI generation.
        let retryGeneration = UUID()
        confirmationContext = ConfirmationContext(confirmation: execution.confirmation,
                                                  generation: retryGeneration,
                                                  app: execution.app,
                                                  appName: execution.confirmation.summary.appName,
                                                  selectedCount: execution.confirmation.summary.selectedCount,
                                                  selectedSize: execution.confirmation.summary.selectedSize)
        confirmationGeneration = retryGeneration
        confirmationID = execution.confirmation.id
    }

    private func clearActiveExecution(generation: UUID) {
        guard activeExecutionGeneration == generation else { return }
        executionContext = nil
        activeExecutionGeneration = nil
        working = false
    }

    private func invalidateReviewedBatchAndRefresh(app: InstalledApp) {
        confirmationContext = nil
        confirmationGeneration = nil
        confirmationID = nil
        batch = nil
        guard selected == app else {
            scanningTargets = false
            return
        }
        startTargetScan(for: app, replacingSelection: false)
    }

    private static func invalidatesReviewedBatch(_ error: Error) -> Bool {
        guard let planError = error as? UninstallPlanError else { return false }
        switch planError {
        case .batchExpired, .batchAlreadyConsumed, .authorizationUnavailable:
            return true
        default:
            return false
        }
    }
}

public struct UninstallerView: View {
    @StateObject private var model: UninstallerModel
    public init(env: XicoEnvironment) {
        _model = StateObject(wrappedValue: UninstallerModel(env: env))
    }

    /// 从 AppModel 注入缓存的卸载器模型：跨 tab 保留已加载的应用清单与所选残留项（审计 P2 RootView:249）。
    public init(model appModel: AppModel) {
        _model = StateObject(wrappedValue: appModel.uninstallerModel)
    }

    public var body: some View {
        HStack(spacing: 0) {
            appList
            Divider()
            detail
        }
        .onAppear { if model.apps.isEmpty { model.load() } }
        .confirmationDialog(xLocF("确认卸载 %@？",
                                  model.confirmationAppName ?? xLoc("应用")),
                            isPresented: confirmationPresented, titleVisibility: .visible) {
            Button(xLocF("卸载并移入废纸篓（%d 项）",
                         model.confirmationSelectedCount ?? 0),
                   role: .destructive) {
                model.uninstallConfirmed()
            }
            Button(xLoc("取消"), role: .cancel) { model.cancelConfirmation() }
        } message: {
            Text(xLocF("将把应用本体与已勾选的 %d 项关联文件移入废纸篓（%@），可在访达废纸篓中恢复。请确认勾选项中没有你仍需要的数据。",
                       model.confirmationSelectedCount ?? 0,
                       (model.confirmationSelectedSize ?? 0).formattedBytes))
        }
        .alert(xLoc("需要有效许可证"), isPresented: $model.licenseBlocked) {
            Button(xLoc("升级")) { NotificationCenter.default.post(name: .xicoShowPricing, object: nil) }
            Button(xLoc("好"), role: .cancel) {}
        } message: {
            Text(xLoc("试用已结束或许可证无效。购买后即可继续使用卸载功能。"))
        }
    }

    /// SwiftUI also writes `false` to a dialog binding while invoking one of its buttons.
    /// Defer dismissal ownership by one turn so the destructive action can synchronously consume
    /// the exact opaque confirmation first; a stale dismissal cannot cancel a newer dialog.
    private var confirmationPresented: Binding<Bool> {
        Binding(
            get: { model.confirmationID != nil },
            set: { presented in
                guard !presented,
                      let generation = model.confirmationGeneration else { return }
                Task { @MainActor in
                    await Task.yield()
                    model.cancelConfirmation(generation: generation)
                }
            })
    }

    private var appList: some View {
        VStack(spacing: 0) {
            XHeaderBar(title: xLoc("卸载器"), subtitle: xLocF("%d 个应用", model.apps.count)) {
                if model.loading { XSpinner() }
            }
            searchField
                .disabled(model.isInteractionFrozen)
            if model.loading && model.apps.isEmpty {
                // 首次加载应用清单时，列表主体给出骨架行（而非仅头部小转圈的空白），
                // 与监视器进程/核心列表的骨架处理一致。
                ScrollView {
                    XSkeletonRows(count: 10)
                        .padding(.horizontal, XSpacing.m)
                        .padding(.top, XSpacing.s)
                }
            } else if model.filteredApps.isEmpty && !model.query.isEmpty {
                // 搜索无命中时给出明确的空态，避免用户误以为列表加载失败。
                VStack(spacing: XSpacing.s) {
                    Image(systemName: "magnifyingglass")
                        .font(XFont.title)
                        .foregroundStyle(XColor.textTertiary)
                    Text(xLoc("未找到匹配的应用"))
                        .font(XFont.body)
                        .foregroundStyle(XColor.textSecondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(XSpacing.l)
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(model.filteredApps) { app in
                            AppRow(app: app, selected: model.selected?.id == app.id) { model.select(app) }
                        }
                    }
                    .padding(.horizontal, XSpacing.s)
                    .padding(.bottom, XSpacing.l)
                }
                .disabled(model.isInteractionFrozen)
            }
        }
        .frame(width: 330)
        .background(.ultraThinMaterial)
        .overlay(Rectangle().fill(XColor.hairline).frame(width: 1), alignment: .trailing)
    }

    private var searchField: some View {
        HStack(spacing: XSpacing.s) {
            Image(systemName: "magnifyingglass").font(XFont.callout)
                .foregroundStyle(XColor.textTertiary)
                .accessibilityHidden(true)
            TextField(xLoc("搜索应用"), text: $model.query)
                .textFieldStyle(.plain)
                .font(XFont.body)
        }
        .padding(.horizontal, XSpacing.m)
        .padding(.vertical, 7)
        .background(XColor.surfaceAlt.opacity(0.7), in: Capsule())
        .overlay(Capsule().strokeBorder(XColor.border.opacity(0.6), lineWidth: 1))
        .padding(.horizontal, XSpacing.m)
        .padding(.bottom, XSpacing.s)
    }

    @ViewBuilder private var detail: some View {
        if let app = model.selected {
            VStack(spacing: 0) {
                HStack(spacing: XSpacing.m) {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: app.url.path))
                        .resizable().frame(width: 54, height: 54)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(app.name).font(XFont.title).foregroundStyle(XColor.textPrimary)
                        Text(app.bundleID).font(XFont.caption).foregroundStyle(XColor.textSecondary)
                    }
                    Spacer()
                }
                .padding(XSpacing.xl)

                // 全选/全不选关联文件 + 实时体积——批量卸载更顺手。
                HStack(spacing: XSpacing.s) {
                    XCheckbox(isOn: model.allTargetsSelected) { model.toggleAllTargets(!model.allTargetsSelected) }
                        .accessibilityLabel(xLoc("全选关联文件"))
                        .disabled(model.isInteractionFrozen)
                    Text(xLoc("关联文件")).font(XFont.captionEmphasis).foregroundStyle(XColor.textSecondary)
                    Spacer()
                    Text(xLocF("已选 %d 项 · %@", model.selectedCount, model.selectedSize.formattedBytes))
                        .font(XFont.caption).foregroundStyle(XColor.textTertiary)
                }
                .padding(.horizontal, XSpacing.xl).padding(.top, XSpacing.xs)

                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(model.targets) { candidate in
                            ItemRowView(item: candidate.item) { model.toggle(candidate.id) }
                        }
                    }
                    .padding(XSpacing.l)
                }
                .disabled(model.isInteractionFrozen)

                XActionBar(title: xLocF("已选 %d 项", model.selectedCount),
                           subtitle: xLoc("将移入废纸篓，可在访达中恢复")) {
                    if model.working {
                        XSpinner()
                    } else {
                        Button(xLocF("卸载 · %@", model.selectedSize.formattedBytes)) {
                            _ = model.beginConfirmation()
                        }
                        .buttonStyle(XPrimaryButtonStyle(
                            enabled: model.selectedCount > 0 && !model.isInteractionFrozen))
                        .disabled(model.selectedCount == 0 || model.isInteractionFrozen)
                    }
                }
            }
        } else if let freed = model.lastFreed {
            // 统一计数庆祝：释放字节数从 0 数起 + 卸载项数（文件已入废纸篓，可在访达恢复）。
            TaskCompletionView(
                animateTo: freed,
                metricText: { xLocF("已释放 %@", $0.formattedBytes) },
                detail: xLocF("已卸载 %d 项 · 可在废纸篓恢复", model.lastRemovedCount))
        } else {
            XEmptyState(systemImage: "xmark.bin", title: xLoc("选择要卸载的应用"),
                        subtitle: xLoc("从左侧列表选择一个应用，Xico 会找出它的全部关联文件供你一并清除。"))
        }
    }
}

private struct AppRow: View {
    let app: InstalledApp
    let selected: Bool
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            HStack(spacing: XSpacing.s) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: app.url.path))
                    .resizable().frame(width: 28, height: 28)
                VStack(alignment: .leading, spacing: 1) {
                    Text(app.name).font(XFont.bodyEmphasis)
                        .foregroundStyle(selected ? .white : XColor.textPrimary).lineLimit(1)
                    Text(app.size > 0 ? app.size.formattedBytes : xLoc("计算中…")).font(XFont.caption)
                        .foregroundStyle(selected ? .white.opacity(0.85) : XColor.textSecondary)
                }
                Spacer()
            }
            .padding(.horizontal, XSpacing.s)
            .padding(.vertical, 6)
            .background(
                Group {
                    if selected { RoundedRectangle(cornerRadius: XRadius.tile).fill(XColor.brandGradient) }
                    else if hover { RoundedRectangle(cornerRadius: XRadius.tile).fill(XColor.surfaceHover) }
                }
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .accessibilityLabel(app.name)
        .accessibilityValue(app.size > 0 ? app.size.formattedBytes : "")
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}
