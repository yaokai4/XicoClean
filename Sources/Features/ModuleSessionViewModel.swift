import SwiftUI
import Domain
import Infrastructure
import DesignSystem

/// 进度节流：限制 UI 更新频率，避免海量文件时主线程被刷爆。
final class ProgressThrottle: @unchecked Sendable {
    private let lock = NSLock()
    private var last = DispatchTime.now().uptimeNanoseconds
    func shouldFire(minInterval: Double = 0.08) -> Bool {
        lock.lock(); defer { lock.unlock() }
        let now = DispatchTime.now().uptimeNanoseconds
        if Double(now - last) > minInterval * 1_000_000_000 {
            last = now
            return true
        }
        return false
    }
}

/// 一次「扫描 → 预览 → 清理 → 撤销」会话的状态机，被智能扫描与各模块页复用。
@MainActor
public final class ModuleSessionViewModel: ObservableObject {
    public enum Phase: Equatable {
        case idle, scanning, results, empty, cleaning, finished
        case failed(String)
    }

    @Published public var phase: Phase = .idle
    @Published public var progress: Double = 0
    @Published public var progressBytes: Int64 = 0
    @Published public var statusMessage: String = ""
    @Published public var groups: [ScanResultGroup] = []
    @Published public private(set) var lastReport: CleaningReport?
    /// 已经通过唯一 typed consumer 冻结 side effects 与展示授权的实时终态。
    @Published var outcomeConsumption: CleaningOutcomeConsumption?
    /// 失败是否由缺少完全磁盘访问权限导致（用于在失败态给出「开启权限」入口）
    @Published public var permissionIssue = false
    /// 失败是否由试用结束或许可证无效导致
    @Published public var licenseIssue = false
    /// 部分模块失败时的降级提示（非空即在结果页顶部显示横幅）
    @Published public var scanWarning: String?
    @Published public private(set) var coverage: ScanCoverage?
    /// 扫描完成后计算降级提示（如智能扫描的失败模块清单）
    public var postScanWarning: (@Sendable () -> String?)?
    /// 撤销部分失败时的提示（非空即弹窗）；保留 lastReport 以便重试。
    @Published public var undoFailedItems: [RestorableItem] = []
    @Published public var persistenceWarning: String?
    public var undoFailedAlert: Bool {
        get { !undoFailedItems.isEmpty }
        set { if !newValue { undoFailedItems = [] } }
    }
    private var isCleaning = false

    public let title: String
    public let intent: DeleteIntent
    public let prerequisite: CleaningPrerequisite
    private let env: XicoEnvironment
    private let scanProvider: @Sendable (@escaping ProgressHandler) async throws -> [ScanResult]
    private var scanTask: Task<Void, Never>?
    private var cleanTask: Task<Void, Never>?
    private let throttle = ProgressThrottle()
    /// 仅保存 reducer 确认且由实际 Trash payload 支撑的回执；部分撤销不会伪造新清理报告。
    private var undoReceipts: [RestorableItem] = []
    private struct OwnedUndoReceipt: Sendable {
        let ownerOperationID: UUID
        let item: RestorableItem
    }
    private var receiptLedger: [OwnedUndoReceipt] = []
    private var historyRecordIDsByOperation: [UUID: UUID] = [:]
    private var operationHasIrreversibleChanges: [UUID: Bool] = [:]
    private var reportOccurrenceSelectionMapping: [Int: Int] = [:]
    private var retrySelectionInventory: [CleanableItem] = []
    /// 撤销会改变 Domain 报告所代表的 receipt ledger；撤销后旧报告不得再作为 retry authority。
    private var retryChainInvalidatedByUndo = false
    private let outcomeGate: OutcomeFeedbackGate
    private let cleaningOutcomeConsumer: CleaningOutcomeConsumer

    /// 类型化结果失效观察者：清理后许可闸门可能变化（例如首次清理触发的复验降级），据此重算缓存。
    /// `nonisolated(unsafe)`：仅在 init（@MainActor）赋值一次、在 nonisolated deinit 读取一次移除，
    /// 对象生命周期保证独占访问，Swift 6 下让 deinit 可安全触及此非 Sendable token。
    nonisolated(unsafe) private var outcomeInvalidationObserver: NSObjectProtocol?
    /// 授权变化观察者（激活/移除/复验后重算购买闸门）——刚激活的用户立刻可清理，无需切页重建会话。
    nonisolated(unsafe) private var licenseChangedObserver: NSObjectProtocol?

    public init(env: XicoEnvironment,
                title: String,
                intent: DeleteIntent,
                prerequisite: CleaningPrerequisite = .none,
                scanProvider: @escaping @Sendable (@escaping ProgressHandler) async throws -> [ScanResult]) {
        let outcomeGate = OutcomeFeedbackGate()
        self.env = env
        self.title = title
        self.intent = intent
        self.prerequisite = prerequisite
        self.scanProvider = scanProvider
        self.outcomeGate = outcomeGate
        self.cleaningOutcomeConsumer = CleaningOutcomeConsumer(
            history: env.historySink,
            notifier: env.cleaningNotifier,
            invalidation: env.invalidationSink,
            gate: outcomeGate)
        let refresh: @Sendable (Notification) -> Void = { [weak self] notification in
            guard let event = notification.object as? OutcomeInvalidationEvent,
                  event.kind == .cleaningExecute else { return }
            Task { @MainActor in self?.refreshPurchaseGate() }
        }
        outcomeInvalidationObserver = NotificationCenter.default.addObserver(
            forName: .xicoOutcomeInvalidated, object: nil, queue: nil, using: refresh)
        licenseChangedObserver = NotificationCenter.default.addObserver(
            forName: .xicoLicenseChanged, object: nil, queue: nil, using: refresh)
    }

    deinit {
        if let outcomeInvalidationObserver {
            NotificationCenter.default.removeObserver(outcomeInvalidationObserver)
        }
        if let licenseChangedObserver { NotificationCenter.default.removeObserver(licenseChangedObserver) }
    }

    // MARK: 派生数据

    public var selectedItems: [CleanableItem] {
        groups.flatMap { $0.items.filter(\.isSelected) }
    }
    public var selectedRequiresHelper: Bool { selectedItems.contains(where: \.requiresHelper) }
    public var selectedSize: Int64 { selectedItems.reduce(0) { $0 + $1.estimatedReclaimableBytes } }
    public var selectedCount: Int { selectedItems.count }
    var hasUndoReceipts: Bool { !undoReceipts.isEmpty }
    var hasRetryableCleaningRemainder: Bool {
        !retryChainInvalidatedByUndo
            && outcomeConsumption?.retryableRemainder.isEmpty == false
    }
    public var totalReclaimable: Int64 { groups.reduce(0) { $0 + $1.reclaimableSize } }   // 剔除「仅提示」字节（终审 P1）
    public var totalItemCount: Int { groups.reduce(0) { $0 + $1.items.count } }

    // MARK: 扫描

    /// 试用结束/许可无效时为 true：结果页仍可扫描与预览，但清理入口应替换为「购买后清理」CTA
    /// （破坏性动作 clean/uninstall/shred 仍由 `ensureLicensed()` 严格拦截，见 clean()）。
    ///
    /// **缓存化（审计 P2）**：改为 @Published 存储属性，只在状态转移点重算（`start()`、扫描落到
    /// `.results`/`.empty`、以及清理完成后的类型化失效事件），镜像 AppModel 缓存 licenseStatus 的做法。
    /// 绝不再从 body 里读取的计算属性触发 `env.license.status()`（每次重渲染都要磁盘读 + 验签 + 落盘）。
    @Published public private(set) var needsPurchaseToClean = false

    /// 重算购买闸门（一次 status() 磁盘读 + 验签）。只在状态转移点调用，绝不在每帧 body 里调用。
    private func refreshPurchaseGate() {
        needsPurchaseToClean = !env.license.status().state.allowsCommercialUse
    }

    public func start() {
        start(preservingHistoryOwnership: false)
    }

    /// 撤销已落盘但历史同步失败时仍需重扫 UI；此内部入口保留尚未同步的历史所有权，
    /// 让持久化降级不会被一次自动重扫静默抹掉。普通用户发起的新扫描始终清空旧会话。
    private func start(preservingHistoryOwnership: Bool) {
        guard !isCleaning,
              !isUndoing || preservingHistoryOwnership else { return }
        refreshPurchaseGate()
        // 扫描与结果预览对试用到期用户开放（只读、无破坏性）——不再在此拦截，
        // 许可校验只把守破坏性动作（见 clean()）。这样过期用户仍能看见「能清多少」，
        // 结果页据 needsPurchaseToClean 给出「购买后清理」CTA。
        scanTask?.cancel()
        phase = .scanning
        progress = 0
        progressBytes = 0
        statusMessage = xLoc("正在扫描…")
        groups = []
        lastReport = nil
        outcomeConsumption = nil
        undoReceipts = []
        receiptLedger = []
        reportOccurrenceSelectionMapping = [:]
        retrySelectionInventory = []
        retryChainInvalidatedByUndo = false
        if !preservingHistoryOwnership {
            historyRecordIDsByOperation = [:]
            operationHasIrreversibleChanges = [:]
        }
        undoFailedItems = []
        permissionIssue = false
        licenseIssue = false
        scanWarning = nil
        coverage = nil

        let handler = makeHandler()
        scanTask = Task { [weak self] in
            guard let self else { return }
            do {
                let results = try await self.scanProvider(handler)
                let coverage = ScanCoverage.merged(results.compactMap(\.coverage))
                var merged = results.flatMap { $0.groups }.sorted { $0.totalSize > $1.totalSize }
                // 应用用户忽略清单：被排除的项不出现在结果里（对标 CleanMyMac 排除列表）
                let ignore = self.env.ignoreList
                for i in merged.indices { merged[i].items.removeAll { ignore.isIgnored($0.url) } }
                merged.removeAll { $0.items.isEmpty }
                if Task.isCancelled { return }
                self.groups = merged
                self.coverage = coverage
                self.refreshPurchaseGate()   // 落到 .results/.empty 前刷新缓存的购买闸门（审计 P2）
                let fdaOK = self.env.permissions.hasFullDiskAccess()
                if !merged.isEmpty {
                    self.phase = .results
                    XSound.play(.scanDone)   // 签名音效①：扫描完成（P4）
                    // 有结果也要如实告知是否「已扫全」：未授 FDA 时，多数受保护位置根本没被扫到，
                    // 用户看到的只是冰山一角——用横幅明说，避免误以为「扫完就这么点」。
                    var warnings: [String] = []
                    if let w = self.postScanWarning?() { warnings.append(w) }
                    if !fdaOK {
                        warnings.append(xLoc("未获完全磁盘访问权限，部分位置无法扫描。授权后可发现更多可清理项。"))
                    }
                    if let coverage, coverage.deniedDirectories > 0 {
                        warnings.append(xLocF("有 %d 个目录因权限不足未读取。", coverage.deniedDirectories))
                    }
                    if let coverage, coverage.cloudPlaceholdersSkipped > 0 {
                        warnings.append(xLocF("跳过 %d 个仅在云端的占位目录，未触发下载。",
                                              coverage.cloudPlaceholdersSkipped))
                    }
                    self.scanWarning = warnings.isEmpty ? nil : warnings.joined(separator: "\n")
                    self.permissionIssue = !fdaOK
                } else if !fdaOK || coverage?.isComplete == false {
                    // 空结果可能只是没权限——绝不伪装成「很干净」
                    self.permissionIssue = true
                    if !fdaOK {
                        self.phase = .failed(xLoc("未获完全磁盘访问权限，部分位置无法扫描。授权后可发现更多可清理项。"))
                    } else {
                        self.phase = .failed(xLoc("扫描覆盖不完整，不能据此判断为很干净。请检查权限后重试。"))
                    }
                } else {
                    self.scanWarning = self.postScanWarning?()
                    self.phase = .empty
                    XSound.play(.scanDone)
                }
            } catch is CancellationError {
                // 用户取消：保持 cancel() 设定的状态
            } catch {
                if Task.isCancelled { return }
                XicoLog.scan.error("扫描失败 [\(self.title, privacy: .public)]: \(error.localizedDescription, privacy: .public)")
                self.phase = .failed(xLocF("扫描时出错：%@", error.localizedDescription))
            }
        }
    }

    /// 打开「完全磁盘访问」系统设置（失败态的权限入口）
    public func openPermissionSettings() {
        env.permissions.openFullDiskAccessSettings()
    }

    public func cancel() {
        guard !isUndoing else { return }
        if isCleaning {
            cancelCleaning()
            return
        }
        scanTask?.cancel()
        env.scanIndex.invalidate()
        phase = groups.isEmpty ? .idle : .results
    }

    // MARK: 选择

    public func toggleItem(groupID: String, itemID: UUID) {
        guard phase == .results, !isCleaning else { return }
        guard let gi = groups.firstIndex(where: { $0.id == groupID }),
              let ii = groups[gi].items.firstIndex(where: { $0.id == itemID }) else { return }
        guard !groups[gi].items[ii].isInformational else { return }   // 「仅提示」项不可勾
        groups[gi].items[ii].isSelected.toggle()
    }

    public func setGroup(_ groupID: String, selected: Bool) {
        guard phase == .results, !isCleaning else { return }
        guard let gi = groups.firstIndex(where: { $0.id == groupID }) else { return }
        // 「仅提示」项不随组全选卷入（三层闸第一层；引擎侧仍会兜底拒删）。
        for i in groups[gi].items.indices where !groups[gi].items[i].isInformational {
            groups[gi].items[i].isSelected = selected
        }
    }

    /// 把某项加入「忽略清单」并从当前结果移除——它今后不再被扫描/清理。
    public func ignore(groupID: String, itemID: UUID) {
        guard phase == .results, !isCleaning else { return }
        guard let gi = groups.firstIndex(where: { $0.id == groupID }),
              let item = groups[gi].items.first(where: { $0.id == itemID }) else { return }
        env.ignoreList.add(item.url)
        groups[gi].items.removeAll { $0.id == itemID }
        if groups[gi].items.isEmpty { groups.remove(at: gi) }
    }

    public func groupSelectionState(_ group: ScanResultGroup) -> Bool {
        !group.items.isEmpty && group.items.allSatisfy(\.isSelected)
    }

    // MARK: 清理

    public func clean() {
        guard phase == .results else { return }
        guard ensureLicensed() else { return }
        let occurrences = selectedOccurrences()
        guard !occurrences.isEmpty, !isCleaning else { return }
        let plans = occurrences.map { occurrence in
            CleaningPlan(
                items: [occurrence.item],
                intent: occurrence.item.requiresHelper ? .permanent : intent,
                prerequisite: prerequisite)
        }
        isCleaning = true
        retryChainInvalidatedByUndo = false
        phase = .cleaning
        progress = 0
        statusMessage = xLoc("正在清理…")
        outcomeConsumption = nil
        persistenceWarning = nil

        let handler = makeHandler()
        cleanTask = Task { [weak self] in
            guard let self else { return }
            defer {
                self.isCleaning = false
                self.cleanTask = nil
            }
            let report = await self.env.cleaningEngine.execute(
                plans,
                parentID: nil,
                progress: handler)
            let consumption = await self.cleaningOutcomeConsumer.consume(
                module: self.title,
                report: report,
                selectionOccurrenceCount: occurrences.count,
                detailKey: "已释放空间")

            // consumer 完成历史、通知、失效和展示授权后，才一次性公开终态。
            self.rememberHistory(
                report: consumption.report,
                result: consumption.historyResult)
            self.applySelectionMutation(
                consumption.selectionMutation,
                to: occurrences)
            self.reportOccurrenceSelectionMapping =
                consumption.selectionMutation.retainedOccurrenceMapping
            self.retrySelectionInventory = self.selectedOccurrences().map(\.item)
            self.receiptLedger = consumption.undoReceipts.map {
                OwnedUndoReceipt(
                    ownerOperationID: consumption.report.operation.id,
                    item: $0)
            }
            self.undoReceipts = consumption.undoReceipts
            self.outcomeConsumption = consumption
            self.lastReport = consumption.report
            self.phase = .finished
        }
    }

    /// 取消只向正在运行的任务发出协作式取消；终态必须由引擎 reducer 生成并经 consumer 展示。
    public func cancelCleaning() {
        cleanTask?.cancel()
    }

    /// 只重试 Domain 在上一终态中签发的剩余事实。Feature 不重建计划、不按路径推断身份；
    /// 已成功的删除只作为 D 上下文出现，绝不会再次执行。
    public func retryCleaning() {
        guard phase == .finished,
              let prior = lastReport,
              hasRetryableCleaningRemainder,
              !isCleaning,
              !isUndoing else { return }
        guard ensureLicensed() else { return }
        let occurrences = selectedOccurrences()
        guard occurrences.map(\.item) == retrySelectionInventory else {
            retryChainInvalidatedByUndo = true
            persistenceWarning = xLoc("当前结果已发生变化，已停止使用旧重试授权。请重新扫描后再试。")
            return
        }
        let priorMapping = reportOccurrenceSelectionMapping
        isCleaning = true
        phase = .cleaning
        progress = 0
        statusMessage = xLoc("正在重试未完成项目…")

        let handler = makeHandler()
        cleanTask = Task { [weak self] in
            guard let self else { return }
            defer {
                self.isCleaning = false
                self.cleanTask = nil
            }
            let execution = await self.env.cleaningEngine.retry(
                prior,
                progress: handler)
            let consumption = await self.cleaningOutcomeConsumer.consumeRetry(
                module: self.title,
                execution: execution,
                selectionOccurrenceCount: execution.report.items.count,
                detailKey: "重试结果")
            let transition = CleaningRetrySelectionTransition.make(
                execution: execution,
                priorReportOccurrenceMapping: priorMapping,
                currentSelectionOccurrenceCount: occurrences.count)

            self.applySelectionMutation(transition.mutation, to: occurrences)
            self.reportOccurrenceSelectionMapping = transition.nextReportOccurrenceMapping
            self.retrySelectionInventory = self.selectedOccurrences().map(\.item)
            self.receiptLedger = execution.retainedReceipts.map {
                OwnedUndoReceipt(ownerOperationID: $0.ownerOperationID, item: $0.item)
            }
            self.undoReceipts = consumption.undoReceipts
            self.rememberHistory(
                report: consumption.report,
                result: consumption.historyResult)
            self.outcomeConsumption = consumption
            self.lastReport = consumption.report
            self.phase = .finished
        }
    }

    private var isUndoing = false

    public func undo() {
        guard !receiptLedger.isEmpty, !isUndoing, !isCleaning else { return }
        let requestedLedger = receiptLedger
        let receipts = requestedLedger.map(\.item)
        let parentID = lastReport?.operation.id
        isUndoing = true
        Task {
            defer { self.isUndoing = false }
            let result = await env.cleaningEngine.undo(
                receipts,
                parentID: parentID)
            let remaining = result.payload.remaining
            self.retryChainInvalidatedByUndo = true
            await self.publishUndoInvalidation(result.outcome)

            guard let remainingLedger = self.ownedReceiptSubset(
                remaining,
                from: requestedLedger) else {
                // Domain 返回了并非本次请求子集的回执时 fail closed：不丢所有权，也不改历史。
                self.persistenceWarning = xLoc("撤销结果无法与原始回执核对，已保留原记录以避免错误更新。")
                self.undoFailedItems = receipts
                return
            }
            self.receiptLedger = remainingLedger
            self.undoReceipts = remainingLedger.map(\.item)
            let historyRejected = self.synchronizeHistoryAfterUndo(
                requestedLedger: requestedLedger,
                remainingLedger: remainingLedger)

            if remainingLedger.isEmpty {
                self.lastReport = nil
                self.outcomeConsumption = nil
                self.undoFailedItems = []
                self.start(preservingHistoryOwnership: historyRejected)
            } else {
                // 部分失败：保留原始 reducer 报告，只缩减 payload-backed 回执，绝不伪造替代报告。
                self.undoFailedItems = remaining
            }
        }
    }

    /// 在废纸篓中显示未能恢复的项，便于用户手动处理。
    public func revealUndoFailuresInTrash() {
        for item in undoFailedItems { revealInFinder(item.trashedURL) }
    }

    public func reset() {
        guard !isUndoing else { return }
        if isCleaning {
            cancelCleaning()
            return
        }
        scanTask?.cancel()
        phase = .idle
        groups = []
        lastReport = nil
        outcomeConsumption = nil
        undoReceipts = []
        receiptLedger = []
        historyRecordIDsByOperation = [:]
        operationHasIrreversibleChanges = [:]
        reportOccurrenceSelectionMapping = [:]
        retrySelectionInventory = []
        retryChainInvalidatedByUndo = false
        undoFailedItems = []
        persistenceWarning = nil
        progress = 0
        progressBytes = 0
    }

    // MARK: 私有

    private struct SelectedOccurrence {
        let groupIndex: Int
        let itemIndex: Int
        let item: CleanableItem
    }

    /// 按 groups/items 的原始顺序建立 occurrence inventory；调用方 ID 与路径都不是删除身份。
    private func selectedOccurrences() -> [SelectedOccurrence] {
        groups.enumerated().flatMap { groupIndex, group in
            group.items.enumerated().compactMap { itemIndex, item in
                guard item.isSelected else { return nil }
                return SelectedOccurrence(
                    groupIndex: groupIndex,
                    itemIndex: itemIndex,
                    item: item)
            }
        }
    }

    private func applySelectionMutation(
        _ selectionMutation: CleaningSelectionMutation,
        to occurrences: [SelectedOccurrence]
    ) {
        guard selectionMutation.originalOccurrenceCount == occurrences.count else { return }
        let indices = selectionMutation.removableOccurrenceIndices
        guard Set(indices).count == indices.count,
              indices.allSatisfy(occurrences.indices.contains) else { return }
        let locations = indices.map { occurrences[$0] }
        // 先完整验证快照仍对应当前 position，再执行任何删除；不匹配时 fail closed 全部保留。
        guard locations.allSatisfy({ location in
            groups.indices.contains(location.groupIndex)
                && groups[location.groupIndex].items.indices.contains(location.itemIndex)
                && groups[location.groupIndex].items[location.itemIndex] == location.item
                && groups[location.groupIndex].items[location.itemIndex].isSelected
        }) else { return }

        let byGroup = Dictionary(grouping: locations, by: \.groupIndex)
        for groupIndex in byGroup.keys.sorted(by: >) {
            let itemIndices = byGroup[groupIndex, default: []]
                .map(\.itemIndex)
                .sorted(by: >)
            for itemIndex in itemIndices {
                groups[groupIndex].items.remove(at: itemIndex)
            }
        }
        groups.removeAll { $0.items.isEmpty }
    }

    private func rememberHistory(
        report: CleaningReport,
        result: HistoryRecordResult?
    ) {
        let operationID = report.operation.id
        operationHasIrreversibleChanges[operationID] = report.facts.contains { fact in
            guard fact.mutation != .none else { return false }
            switch fact {
            case let .deletion(item):
                return !(item.disposition == .succeeded
                    && item.mutation == .changed
                    && item.intent == .trash)
            case .auxiliary:
                return true
            }
        }
        switch result {
        case let .inserted(recordID)?:
            historyRecordIDsByOperation[operationID] = recordID
        case let .alreadyRecorded(recordID)?:
            historyRecordIDsByOperation[operationID] = recordID
        case .notRecordedNoChanges?:
            historyRecordIDsByOperation.removeValue(forKey: operationID)
        case let .rejected(code)?:
            historyRecordIDsByOperation.removeValue(forKey: operationID)
            persistenceWarning = xLoc("文件操作结果已保留，但清理历史未能写入。")
            XicoLog.history.error("cleaning history record rejected code=\(code, privacy: .public)")
        case nil:
            historyRecordIDsByOperation.removeValue(forKey: operationID)
        }
    }

    /// 把 Domain 的 remaining payload 重新绑定到原回执所有者；不是严格子集就拒绝更新。
    private func ownedReceiptSubset(
        _ remaining: [RestorableItem],
        from requested: [OwnedUndoReceipt]
    ) -> [OwnedUndoReceipt]? {
        var unmatched = remaining
        var subset: [OwnedUndoReceipt] = []
        for entry in requested {
            guard let index = unmatched.firstIndex(of: entry.item) else { continue }
            subset.append(entry)
            unmatched.remove(at: index)
        }
        return unmatched.isEmpty ? subset : nil
    }

    /// 每个回执只更新创建它的历史记录。含永久删除或已执行辅助事实的记录即使回执归零也保留，
    /// 只把 restorable payload 更新为空，避免把不可逆事实从历史中抹掉。
    @discardableResult
    private func synchronizeHistoryAfterUndo(
        requestedLedger: [OwnedUndoReceipt],
        remainingLedger: [OwnedUndoReceipt]
    ) -> Bool {
        let ownerIDs = Set(requestedLedger.map(\.ownerOperationID))
            .sorted { $0.uuidString < $1.uuidString }
        var hadRejectedUpdate = false

        for ownerID in ownerIDs {
            guard let recordID = historyRecordIDsByOperation[ownerID] else { continue }
            let remaining = remainingLedger
                .filter { $0.ownerOperationID == ownerID }
                .map(\.item)
            let removesWholeRecord = remaining.isEmpty
                && operationHasIrreversibleChanges[ownerID] != true
            let result = removesWholeRecord
                ? env.historySink.remove(id: recordID)
                : env.historySink.updateRestorable(id: recordID, to: remaining)

            switch result {
            case .committed:
                if removesWholeRecord {
                    historyRecordIDsByOperation.removeValue(forKey: ownerID)
                    operationHasIrreversibleChanges.removeValue(forKey: ownerID)
                }
            case .notFound:
                historyRecordIDsByOperation.removeValue(forKey: ownerID)
                operationHasIrreversibleChanges.removeValue(forKey: ownerID)
                persistenceWarning = xLoc("撤销结果已生效，但对应的历史记录已不存在。")
            case let .rejected(code):
                // 保留 recordID 所有权，不能把失败的持久化同步伪装为已提交。
                hadRejectedUpdate = true
                persistenceWarning = xLoc("撤销结果已生效，但清理历史未能同步更新。")
                XicoLog.history.error("cleaning history undo sync rejected code=\(code, privacy: .public)")
            }
        }
        return hadRejectedUpdate
    }

    private func publishUndoInvalidation(_ outcome: OperationOutcome) async {
        await outcomeGate.registerTerminal(outcome.id)
        guard await outcomeGate.consume(.internalInvalidation, for: outcome.id),
              let domains = OutcomeOperationRegistry.semantics(
                for: outcome.kind)?.invalidationDomains,
              let request = ValidatedOutcomeInvalidation(
                outcome: outcome,
                domains: domains) else {
            XicoLog.clean.error("cleaning undo invalidation validation rejected")
            return
        }
        switch env.invalidationSink.publish(request) {
        case .published:
            break
        case let .rejected(code):
            XicoLog.clean.error("cleaning undo invalidation rejected code=\(code, privacy: .public)")
        }
    }

    private func ensureLicensed() -> Bool {
        let status = env.license.status()
        guard status.state.allowsCommercialUse else {
            scanTask?.cancel()
            permissionIssue = false
            licenseIssue = true
            // 不再自动跳转设置页（会让失败提示一闪而过看不到）。停在失败态，
            // 由失败态视图提供「购买 / 导入许可证」入口（见 ScanViews 许可证失败态）。
            phase = .failed(xLocF("试用已结束或许可证无效。%@", status.summary))
            return false
        }
        licenseIssue = false
        return true
    }

    private func makeHandler() -> ProgressHandler {
        let throttle = self.throttle
        return { [weak self] p in
            guard throttle.shouldFire() else { return }
            Task { @MainActor in
                guard let self else { return }
                if let f = p.fraction { self.progress = f }
                self.progressBytes = p.bytesFound
                if !p.message.isEmpty { self.statusMessage = p.message }
            }
        }
    }
}
