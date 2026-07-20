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
    @Published private(set) var undoing = false
    @Published private(set) var confirmationID: UUID?
    @Published var lastFreed: Int64?
    @Published var lastRemovedCount: Int = 0
    @Published private(set) var uninstallCompletion: UninstallCompletion?
    @Published private(set) var lastUninstallReport: CleaningReport?
    @Published private(set) var requiresFreshScanBeforeRetry = false
    @Published private(set) var remainingUndoReceipts: [RestorableItem] = []
    @Published private(set) var hasUnresolvedPossiblyChangedFacts = false
    @Published private(set) var unresolvedUninstallOccurrences: [UninstallOccurrenceFact] = []
    @Published private(set) var unresolvedOccurrenceLedgerOverflow = false
    @Published private(set) var unresolvedOccurrenceGlobalOverflow = false
    @Published var query = ""

    var filteredApps: [InstalledApp] {
        query.isEmpty ? apps : apps.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    typealias TargetScanner = @Sendable (InstalledApp, UninstallMode) async -> UninstallBatch?

    private struct ConfirmationContext {
        let confirmation: UninstallConfirmation
        let generation: UUID
        let app: InstalledApp
        let mode: UninstallMode
        let appName: String
        let selectedCount: Int
        let selectedSize: Int64
    }

    private struct ExecutionContext {
        let confirmation: UninstallConfirmation
        let generation: UUID
        let app: InstalledApp
        let mode: UninstallMode
    }

    private struct RetainedWorkflowState {
        let completion: UninstallCompletion?
        let report: CleaningReport?
        let batch: UninstallBatch?
        let requiresFreshScan: Bool
        let retryDirective: UninstallRetryDirective?
        let undoReceiptLedger: [UUID: [RestorableItem]]
        let appBodyReceiptAwaitingUndo: RestorableItem?
    }

    private let env: XicoEnvironment
    private let targetScanner: TargetScanner
    private var appListGeneration = UUID()
    private var targetScanGeneration = UUID()
    private var confirmationContext: ConfirmationContext?
    private var executionContext: ExecutionContext?
    private var undoGeneration: UUID?
    private var undoReceiptLedger: [UUID: [RestorableItem]] = [:]
    private var retainedWorkflowStates: [UninstallAppWorkflowIdentity: RetainedWorkflowState] = [:]
    private var unresolvedOccurrenceLedger:
        [UninstallAppWorkflowIdentity: [UninstallOccurrenceFact]] = [:]
    private var unresolvedOccurrenceOverflowAppIDs = Set<UninstallAppWorkflowIdentity>()
    private var unsafeUndoEndpointCollisionAppIDs = Set<UninstallAppWorkflowIdentity>()
    private var retryDirective: UninstallRetryDirective?
    private var appBodyReceiptAwaitingUndo: RestorableItem?
    private static let maximumUnresolvedOccurrencesPerApp = 1_024
    private static let maximumUnresolvedOccurrencesTotal = 8_192
    private static let maximumTrackedWorkflowApps = 64
    private(set) var confirmationGeneration: UUID?
    private(set) var activeExecutionGeneration: UUID?

    init(env: XicoEnvironment, targetScanner: TargetScanner? = nil) {
        self.env = env
        let service = env.uninstaller
        self.targetScanner = targetScanner ?? { app, mode in
            await Task.detached {
                try? service.uninstallTargets(for: app, mode: mode)
            }.value
        }
    }

    var isInteractionFrozen: Bool { confirmationContext != nil || working || undoing }

    var confirmationAppName: String? { confirmationContext?.appName }
    var confirmationSelectedCount: Int? { confirmationContext?.selectedCount }
    var confirmationSelectedSize: Int64? { confirmationContext?.selectedSize }
    var confirmationMode: UninstallMode? { confirmationContext?.mode }

    var targets: [UninstallCandidate] { batch?.candidates ?? [] }
    var undoReceiptOwnerOperationIDs: Set<UUID> { Set(undoReceiptLedger.keys) }
    var canUndoPartialUninstall: Bool {
        guard let appID = selected?.uninstallWorkflowIdentity else { return false }
        return !undoReceiptLedger.isEmpty
            && !unsafeUndoEndpointCollisionAppIDs.contains(appID)
    }

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
        if let currentApp = selected,
           !persistWorkflowStateIfNeeded(for: currentApp.uninstallWorkflowIdentity) {
            return
        }
        if restoreRetainedWorkflow(for: app) { return }
        startTargetScan(for: app, mode: .uninstallApp, replacingSelection: true)
    }

    private func startTargetScan(
        for app: InstalledApp,
        mode: UninstallMode,
        replacingSelection: Bool
    ) {
        // 立即清空上一应用的列表——避免 A→B 快切时 B 的头部仍绑着 A 的旧文件列表，
        // 用户此刻确认就会误删「另一应用」的文件（P2 数据安全）。
        let generation = UUID()
        let resolvingRetry = !replacingSelection && requiresFreshScanBeforeRetry
        targetScanGeneration = generation
        batch = nil
        scanningTargets = true
        if replacingSelection {
            selected = app
            lastFreed = nil
            lastRemovedCount = 0
            uninstallCompletion = nil
            lastUninstallReport = nil
            requiresFreshScanBeforeRetry = false
            retryDirective = nil
            undoReceiptLedger = [:]
            remainingUndoReceipts = []
            appBodyReceiptAwaitingUndo = nil
            refreshUnresolvedOccurrenceProjection(for: app.uninstallWorkflowIdentity)
        }
        let targetScanner = self.targetScanner
        Task {
            let scannedBatch = await targetScanner(app, mode)
            // ID/路径相同仍不足够：A1→B→A2→A1 可让第一轮 A1 回来时再次命中。
            // generation、完整 InstalledApp（含 opaque provenance/物理证明）和批次绑定必须全相等。
            guard self.targetScanGeneration == generation,
                  self.selected == app else { return }
            self.scanningTargets = false
            guard let scannedBatch,
                  scannedBatch.mode == mode,
                  scannedBatch.app == app else {
                self.batch = nil
                return
            }
            if resolvingRetry,
               mode == .cleanLeftovers,
               scannedBatch.candidates.isEmpty {
                self.resolveFreshEmptyLeftoversScan(for: app)
                return
            }
            self.batch = scannedBatch
            self.requiresFreshScanBeforeRetry = false
            self.retryDirective = nil
            _ = self.persistWorkflowStateIfNeeded(for: app.uninstallWorkflowIdentity)
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
    var canRescanForRetry: Bool {
        requiresFreshScanBeforeRetry && retryDirective != .restoreAppThenRescan
    }

    @Published var licenseBlocked = false

    /// Freezes the exact reviewed batch at the capability boundary. Features retains only the
    /// opaque confirmation and never reconstructs or substitutes its batch snapshot.
    @discardableResult
    func beginConfirmation() -> UUID? {
        guard !working, !undoing, !requiresFreshScanBeforeRetry else { return nil }
        if let confirmationContext { return confirmationContext.generation }
        guard let app = selected, let batch,
              batch.app == app,
              batch.selectedCount > 0 else { return nil }
        let confirmation = env.uninstallCapability.beginConfirmation(for: batch)
        let generation = UUID()
        confirmationContext = ConfirmationContext(confirmation: confirmation,
                                                  generation: generation,
                                                  app: app,
                                                  mode: batch.mode,
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
                                         app: reviewed.app,
                                         mode: reviewed.mode)
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
                         result: DestructiveExecutionResult<UninstallExecution>) {
        guard let execution = executionContext,
              execution.generation == generation,
              activeExecutionGeneration == generation else { return }
        switch result {
        case .failedClosed:
            clearActiveExecution(generation: generation)
            invalidateReviewedBatchAndRefresh(app: execution.app, mode: execution.mode)
        case .executed(let terminal):
            clearActiveExecution(generation: generation)
            let appIdentity = execution.app.uninstallWorkflowIdentity
            guard !terminal.occurrenceFacts.isEmpty,
                  terminal.occurrenceFacts.allSatisfy({
                      $0.subject.appIdentity == appIdentity
                  }) else {
                // A terminal for another app cannot mutate this workflow. Record a sticky,
                // fail-closed uncertainty for the expected app and require a fresh scan.
                markOccurrenceOverflow(for: appIdentity, global: false)
                refreshUnresolvedOccurrenceProjection(for: appIdentity)
                uninstallCompletion = .uncertain
                lastUninstallReport = nil
                lastFreed = nil
                lastRemovedCount = 0
                retryDirective = .determineFromFreshScan
                requiresFreshScanBeforeRetry = true
                selected = execution.app
                batch = nil
                targetScanGeneration = UUID()
                scanningTargets = false
                _ = persistWorkflowStateIfNeeded(for: appIdentity)
                return
            }
            reconcileUnresolvedOccurrences(for: appIdentity, with: terminal)
            uninstallCompletion = terminal.completion
            lastUninstallReport = terminal.report
            retryDirective = terminal.retryDirective
            if let bodyReceipt = terminal.appBodyRestorable {
                appBodyReceiptAwaitingUndo = bodyReceipt
            }
            mergeUndoReceipts(
                terminal.restorable,
                ownerID: terminal.report.operation.id,
                appID: appIdentity)
            refreshUndoReceiptProjection()
            refreshUnresolvedOccurrenceProjection(for: appIdentity)

            let hasAnyUnresolvedOccurrences = !unresolvedUninstallOccurrences.isEmpty
                || unresolvedOccurrenceLedgerOverflow
            if unsafeUndoEndpointCollisionAppIDs.contains(appIdentity)
                || (terminal.fullSuccess && hasAnyUnresolvedOccurrences) {
                // A later clean pass cannot retroactively prove what happened to an earlier
                // possibly-changed target or an ambiguous recovery receipt. Preserve an explicit
                // non-celebratory state and require fresh reconciliation instead of clearing it.
                uninstallCompletion = .uncertain
                retryDirective = .determineFromFreshScan
            }

            if terminal.fullSuccess && !hasAnyUnresolvedOccurrences {
                lastFreed = terminal.report.reclaimedBytes
                lastRemovedCount = terminal.report.removedCount
                requiresFreshScanBeforeRetry = false
                selected = nil
                batch = nil
                unresolvedUninstallOccurrences = []
                unresolvedOccurrenceLedgerOverflow = false
                hasUnresolvedPossiblyChangedFacts = false
                unresolvedOccurrenceLedger.removeValue(forKey: appIdentity)
                unresolvedOccurrenceOverflowAppIDs.remove(appIdentity)
                retainedWorkflowStates.removeValue(forKey: appIdentity)
                unsafeUndoEndpointCollisionAppIDs.remove(appIdentity)
                undoReceiptLedger = [:]
                remainingUndoReceipts = []
                appBodyReceiptAwaitingUndo = nil
                targetScanGeneration = UUID()
                scanningTargets = false
                load()
            } else {
                lastFreed = nil
                lastRemovedCount = 0
                selected = execution.app
                batch = terminal.remainingBatch
                requiresFreshScanBeforeRetry = true
                targetScanGeneration = UUID()
                scanningTargets = false
                _ = persistWorkflowStateIfNeeded(for: appIdentity)
            }
        }
    }

    func rescanForRetry() {
        guard !isInteractionFrozen, requiresFreshScanBeforeRetry,
              let app = selected, let directive = retryDirective else { return }
        switch directive {
        case .uninstallApp:
            startTargetScan(for: app, mode: .uninstallApp, replacingSelection: false)
        case .cleanLeftovers:
            startTargetScan(for: app, mode: .cleanLeftovers, replacingSelection: false)
        case .determineFromFreshScan:
            let mode: UninstallMode = env.fs.exists(app.url)
                ? .uninstallApp : .cleanLeftovers
            startTargetScan(for: app, mode: mode, replacingSelection: false)
        case .restoreAppThenRescan:
            // Rich signed/LaunchAgent evidence cannot be freshly issued after its App source was
            // moved. The exact App receipt must be restored first; undo completion switches this
            // directive to a fresh mode determination.
            return
        }
    }

    func undoPartialUninstall() {
        guard !isInteractionFrozen, canUndoPartialUninstall else { return }
        let generation = UUID()
        undoGeneration = generation
        undoing = true
        let ledger = undoReceiptLedger
        let engine = env.cleaningEngine
        Task {
            var remaining: [UUID: [RestorableItem]] = [:]
            for (ownerID, receipts) in ledger {
                let result = await engine.undo(receipts, parentID: ownerID)
                if !result.payload.remaining.isEmpty {
                    remaining[ownerID] = result.payload.remaining
                }
            }
            guard self.undoGeneration == generation else { return }
            self.undoGeneration = nil
            self.undoing = false
            self.undoReceiptLedger = remaining
            self.refreshUndoReceiptProjection()
            self.requiresFreshScanBeforeRetry = true
            if let bodyReceipt = self.appBodyReceiptAwaitingUndo,
               self.remainingUndoReceipts.contains(bodyReceipt) {
                self.retryDirective = .restoreAppThenRescan
            } else {
                self.appBodyReceiptAwaitingUndo = nil
                self.retryDirective = .determineFromFreshScan
            }
            if let appID = self.selected?.uninstallWorkflowIdentity {
                _ = self.persistWorkflowStateIfNeeded(for: appID)
            }
        }
    }

    private func finishExecution(generation: UUID, error: Error) {
        guard let execution = executionContext,
              execution.generation == generation,
              activeExecutionGeneration == generation else { return }
        clearActiveExecution(generation: generation)
        if Self.invalidatesReviewedBatch(error) {
            invalidateReviewedBatchAndRefresh(app: execution.app, mode: execution.mode)
            return
        }
        // Read-only/pre-claim validation errors are retryable without substituting the reviewed
        // payload: restore the same opaque confirmation under a fresh UI generation.
        let retryGeneration = UUID()
        confirmationContext = ConfirmationContext(confirmation: execution.confirmation,
                                                  generation: retryGeneration,
                                                  app: execution.app,
                                                  mode: execution.mode,
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

    private func invalidateReviewedBatchAndRefresh(
        app: InstalledApp,
        mode: UninstallMode
    ) {
        confirmationContext = nil
        confirmationGeneration = nil
        confirmationID = nil
        batch = nil
        guard selected == app else {
            scanningTargets = false
            return
        }
        startTargetScan(for: app, mode: mode, replacingSelection: false)
    }

    private static func invalidatesReviewedBatch(_ error: Error) -> Bool {
        error is UninstallPlanError
    }

    private func refreshUndoReceiptProjection() {
        remainingUndoReceipts = undoReceiptLedger.keys
            .sorted { $0.uuidString < $1.uuidString }
            .flatMap { undoReceiptLedger[$0] ?? [] }
    }

    private struct ReceiptEndpointPair: Hashable {
        let original: String
        let trashed: String

        init(_ item: RestorableItem) {
            original = item.originalURL.standardizedFileURL.path
            trashed = item.trashedURL.standardizedFileURL.path
        }
    }

    /// Adds exact receipts without ever letting two distinct recovery facts claim the same path.
    /// The check spans every retained operation owner because `CleaningEngine.undo` only sees one
    /// owner batch at a time. Exact duplicate pairs are coalesced; any other original/original,
    /// Trash/Trash or original/Trash overlap disables automatic undo for the whole app workflow.
    private func mergeUndoReceipts(
        _ incoming: [RestorableItem],
        ownerID: UUID,
        appID: UninstallAppWorkflowIdentity
    ) {
        guard !incoming.isEmpty else { return }
        var exactPairs = Set(undoReceiptLedger.values.flatMap { $0 }.map {
            ReceiptEndpointPair($0)
        })
        let fresh = incoming.filter { receipt in
            exactPairs.insert(ReceiptEndpointPair(receipt)).inserted
        }
        if !fresh.isEmpty {
            undoReceiptLedger[ownerID, default: []].append(contentsOf: fresh)
        }

        let allPairs = Set(undoReceiptLedger.values.flatMap { $0 }.map {
            ReceiptEndpointPair($0)
        })
        var ownersByEndpoint: [String: Set<ReceiptEndpointPair>] = [:]
        var collision = false
        for pair in allPairs {
            if pair.original == pair.trashed { collision = true }
            ownersByEndpoint[pair.original, default: []].insert(pair)
            ownersByEndpoint[pair.trashed, default: []].insert(pair)
        }
        collision = collision || ownersByEndpoint.values.contains { $0.count > 1 }
        guard collision else { return }
        unsafeUndoEndpointCollisionAppIDs.insert(appID)
        markOccurrenceOverflow(for: appID, global: false)
    }

    private var hasPendingWorkflowState: Bool {
        (uninstallCompletion != nil && uninstallCompletion != .fullSuccess)
            || requiresFreshScanBeforeRetry
            || !undoReceiptLedger.isEmpty
            || !unresolvedUninstallOccurrences.isEmpty
            || unresolvedOccurrenceLedgerOverflow
    }

    @discardableResult
    private func persistWorkflowStateIfNeeded(
        for appID: UninstallAppWorkflowIdentity
    ) -> Bool {
        guard hasPendingWorkflowState else {
            retainedWorkflowStates.removeValue(forKey: appID)
            return true
        }
        guard retainedWorkflowStates[appID] != nil
                || retainedWorkflowStates.count < Self.maximumTrackedWorkflowApps else {
            markOccurrenceOverflow(for: appID, global: true)
            return false
        }
        retainedWorkflowStates[appID] = RetainedWorkflowState(
            completion: uninstallCompletion,
            report: lastUninstallReport,
            batch: batch,
            requiresFreshScan: requiresFreshScanBeforeRetry,
            retryDirective: retryDirective,
            undoReceiptLedger: undoReceiptLedger,
            appBodyReceiptAwaitingUndo: appBodyReceiptAwaitingUndo)
        return true
    }

    private func restoreRetainedWorkflow(for app: InstalledApp) -> Bool {
        let appID = app.uninstallWorkflowIdentity
        guard let state = retainedWorkflowStates[appID] else { return false }
        targetScanGeneration = UUID()
        selected = app
        batch = state.batch
        scanningTargets = false
        lastFreed = nil
        lastRemovedCount = 0
        uninstallCompletion = state.completion
        lastUninstallReport = state.report
        requiresFreshScanBeforeRetry = state.requiresFreshScan
        retryDirective = state.retryDirective
        undoReceiptLedger = state.undoReceiptLedger
        appBodyReceiptAwaitingUndo = state.appBodyReceiptAwaitingUndo
        refreshUndoReceiptProjection()
        refreshUnresolvedOccurrenceProjection(for: appID)
        return true
    }

    private func resolveFreshEmptyLeftoversScan(for app: InstalledApp) {
        let appID = app.uninstallWorkflowIdentity
        var unresolved = unresolvedOccurrenceLedger[appID] ?? []
        unresolved.removeAll { $0.mutation == .none }
        if unresolved.isEmpty {
            unresolvedOccurrenceLedger.removeValue(forKey: appID)
        } else {
            unresolvedOccurrenceLedger[appID] = unresolved
        }
        refreshUnresolvedOccurrenceProjection(for: appID)
        let stillUnresolved = !unresolvedUninstallOccurrences.isEmpty
            || unresolvedOccurrenceLedgerOverflow
        if stillUnresolved {
            batch = nil
            uninstallCompletion = .uncertain
            lastFreed = nil
            lastRemovedCount = 0
            requiresFreshScanBeforeRetry = true
            retryDirective = .cleanLeftovers
            _ = persistWorkflowStateIfNeeded(for: appID)
            return
        }

        uninstallCompletion = .fullSuccess
        lastFreed = lastUninstallReport?.reclaimedBytes ?? 0
        lastRemovedCount = lastUninstallReport?.removedCount ?? 0
        requiresFreshScanBeforeRetry = false
        retryDirective = nil
        batch = nil
        selected = nil
        retainedWorkflowStates.removeValue(forKey: appID)
        unsafeUndoEndpointCollisionAppIDs.remove(appID)
        undoReceiptLedger = [:]
        remainingUndoReceipts = []
        appBodyReceiptAwaitingUndo = nil
        targetScanGeneration = UUID()
        load()
    }

    /// A later trusted success proves only that the same exact subject now completed. It may
    /// reconcile earlier `.none` failures for that subject, but can never retroactively settle an
    /// occurrence whose mutation was `.possiblyChanged`.
    private func reconcileUnresolvedOccurrences(
        for appID: UninstallAppWorkflowIdentity,
        with terminal: UninstallExecution
    ) {
        var unresolved = unresolvedOccurrenceLedger[appID] ?? []
        let successfulSubjects = terminal.occurrenceFacts.compactMap { fact in
            fact.disposition == .succeeded && fact.mutation == .changed
                ? fact.subject : nil
        }
        if !successfulSubjects.isEmpty {
            unresolved.removeAll { prior in
                prior.mutation == .none
                    && successfulSubjects.contains(prior.subject)
            }
        }

        let newUnresolved = terminal.occurrenceFacts.filter {
            $0.disposition != .succeeded
        }
        if !newUnresolved.isEmpty {
            let trackedAppIDs = Set(unresolvedOccurrenceLedger.keys)
                .union(unresolvedOccurrenceOverflowAppIDs)
            guard trackedAppIDs.contains(appID)
                    || trackedAppIDs.count < Self.maximumTrackedWorkflowApps else {
                markOccurrenceOverflow(for: appID, global: true)
                unresolvedUninstallOccurrences = Array(newUnresolved.prefix(
                    Self.maximumUnresolvedOccurrencesPerApp))
                unresolvedOccurrenceLedgerOverflow = true
                hasUnresolvedPossiblyChangedFacts = true
                return
            }
            let otherFactCount = unresolvedOccurrenceLedger.reduce(0) {
                partial, entry in
                entry.key == appID ? partial : partial + entry.value.count
            }
            let remainingCapacity = max(0, min(
                Self.maximumUnresolvedOccurrencesPerApp - unresolved.count,
                Self.maximumUnresolvedOccurrencesTotal
                    - otherFactCount - unresolved.count))
            unresolved.append(contentsOf: newUnresolved.prefix(remainingCapacity))
            if newUnresolved.count > remainingCapacity {
                let exhaustedGlobalCapacity = otherFactCount + unresolved.count
                    >= Self.maximumUnresolvedOccurrencesTotal
                markOccurrenceOverflow(
                    for: appID, global: exhaustedGlobalCapacity)
            }
        }
        if unresolved.isEmpty,
           !unresolvedOccurrenceOverflowAppIDs.contains(appID) {
            unresolvedOccurrenceLedger.removeValue(forKey: appID)
        } else {
            unresolvedOccurrenceLedger[appID] = unresolved
        }
        refreshUnresolvedOccurrenceProjection(for: appID)
    }

    private func markOccurrenceOverflow(
        for appID: UninstallAppWorkflowIdentity,
        global: Bool
    ) {
        if global {
            unresolvedOccurrenceGlobalOverflow = true
        } else if unresolvedOccurrenceOverflowAppIDs.contains(appID)
                    || unresolvedOccurrenceOverflowAppIDs.count
                        < Self.maximumTrackedWorkflowApps {
            unresolvedOccurrenceOverflowAppIDs.insert(appID)
        } else {
            unresolvedOccurrenceGlobalOverflow = true
        }
    }

    private func refreshUnresolvedOccurrenceProjection(
        for appID: UninstallAppWorkflowIdentity
    ) {
        unresolvedUninstallOccurrences = unresolvedOccurrenceLedger[appID] ?? []
        unresolvedOccurrenceLedgerOverflow = unresolvedOccurrenceGlobalOverflow
            || unresolvedOccurrenceOverflowAppIDs.contains(appID)
        hasUnresolvedPossiblyChangedFacts = unresolvedOccurrenceLedgerOverflow
            || unresolvedUninstallOccurrences.contains {
                $0.mutation == .possiblyChanged
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
            Button(model.confirmationMode == .cleanLeftovers
                    ? xLocF("清理残留并移入废纸篓（%d 项）",
                            model.confirmationSelectedCount ?? 0)
                    : xLocF("卸载并移入废纸篓（%d 项）",
                            model.confirmationSelectedCount ?? 0),
                   role: .destructive) {
                model.uninstallConfirmed()
            }
            Button(xLoc("取消"), role: .cancel) { model.cancelConfirmation() }
        } message: {
            Text(model.confirmationMode == .cleanLeftovers
                 ? xLocF("将把已勾选的 %d 项卸载残留移入废纸篓（%@），可在访达废纸篓中恢复。请确认其中没有你仍需要的数据。",
                         model.confirmationSelectedCount ?? 0,
                         (model.confirmationSelectedSize ?? 0).formattedBytes)
                 : xLocF("将把应用本体与已勾选的 %d 项关联文件移入废纸篓（%@），可在访达废纸篓中恢复。请确认勾选项中没有你仍需要的数据。",
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

                if let completion = model.uninstallCompletion,
                   completion != .fullSuccess {
                    VStack(alignment: .leading, spacing: XSpacing.s) {
                        Label(partialTitle(completion), systemImage: "exclamationmark.triangle.fill")
                            .font(XFont.bodyEmphasis)
                            .foregroundStyle(XColor.warning)
                        Text(partialDetail(completion))
                            .font(XFont.caption)
                            .foregroundStyle(XColor.textSecondary)
                        if !model.unresolvedUninstallOccurrences.isEmpty {
                            VStack(alignment: .leading, spacing: 3) {
                                ForEach(model.unresolvedUninstallOccurrences.prefix(3)) {
                                    occurrence in
                                    Text(occurrence.subject.canonicalPath)
                                        .font(.system(.caption2, design: .monospaced))
                                        .foregroundStyle(XColor.textTertiary)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                }
                            }
                            .accessibilityElement(children: .combine)
                        }
                        if model.unresolvedOccurrenceLedgerOverflow {
                            Text(xLoc("部分未解决详情因安全容量上限未显示，完成状态仍被锁定。"))
                                .font(XFont.caption)
                                .foregroundStyle(XColor.warning)
                                .accessibilityAddTraits(.isStaticText)
                        }
                        HStack(spacing: XSpacing.s) {
                            if !model.remainingUndoReceipts.isEmpty {
                                Button(model.undoing ? xLoc("正在撤销…") : xLoc("撤销已移入废纸篓的项目")) {
                                    model.undoPartialUninstall()
                                }
                                .disabled(model.undoing || model.working
                                          || !model.canUndoPartialUninstall)
                            }
                            if model.canRescanForRetry {
                                Button(xLoc("重新扫描并重试")) { model.rescanForRetry() }
                                    .disabled(model.isInteractionFrozen)
                            }
                        }
                    }
                    .padding(XSpacing.m)
                    .background(XColor.warning.opacity(0.09), in: RoundedRectangle(cornerRadius: XRadius.tile))
                    .overlay(RoundedRectangle(cornerRadius: XRadius.tile)
                        .strokeBorder(XColor.warning.opacity(0.28), lineWidth: 1))
                    .padding(.horizontal, XSpacing.xl)
                    .padding(.bottom, XSpacing.s)
                }

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
                            enabled: model.selectedCount > 0 && !model.isInteractionFrozen
                                && !model.requiresFreshScanBeforeRetry))
                        .disabled(model.selectedCount == 0 || model.isInteractionFrozen
                                  || model.requiresFreshScanBeforeRetry)
                    }
                }
            }
        } else if let freed = model.lastFreed {
            // Trash preserves recoverability and does not free physical capacity. Animate the
            // exact moved size, but never label it as reclaimed disk space.
            TaskCompletionView(
                animateTo: freed,
                metricText: { xLocF("已移入废纸篓 %@", $0.formattedBytes) },
                detail: xLocF("已卸载 %d 项 · 可在废纸篓恢复", model.lastRemovedCount))
        } else {
            XEmptyState(systemImage: "xmark.bin", title: xLoc("选择要卸载的应用"),
                        subtitle: xLoc("从左侧列表选择一个应用，Xico 会找出它的全部关联文件供你一并清除。"))
        }
    }

    private func partialTitle(_ completion: UninstallCompletion) -> String {
        switch completion {
        case .dataMovedButAppNotUninstalled:
            return xLoc("部分数据已移入废纸篓，但 App 尚未卸载")
        case .appMovedButSomeDataRetained:
            return xLoc("App 已移入废纸篓，但仍有部分关联数据")
        case .cancelled:
            return xLoc("卸载已取消")
        case .failure:
            return xLoc("卸载未完成")
        case .partial:
            return xLoc("卸载仅完成了一部分")
        case .uncertain:
            return xLoc("仍有项目状态需要确认")
        case .fullSuccess:
            return xLoc("卸载完成")
        }
    }

    private func partialDetail(_ completion: UninstallCompletion) -> String {
        switch completion {
        case .dataMovedButAppNotUninstalled:
            return xLoc("已成功移动的数据仍可撤销；App 本体和失败项目会保留，重试前必须重新扫描并确认。")
        case .appMovedButSomeDataRetained:
            return xLoc("失败项目不会被假报为成功。若其归属依赖 App 签名，请先撤销 App 后再重新扫描。")
        case .partial, .failure, .cancelled:
            return xLoc("失败或未处理的项目已保留；旧授权不会重放，重试将创建新的扫描与确认。")
        case .uncertain:
            return xLoc("此前操作包含状态不确定的项目，后续成功不能覆盖该事实；请重新扫描并核对结果。")
        case .fullSuccess:
            return ""
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
