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
    @Published public var lastReport: CleaningReport?
    /// 失败是否由缺少完全磁盘访问权限导致（用于在失败态给出「开启权限」入口）
    @Published public var permissionIssue = false
    /// 失败是否由试用结束或许可证无效导致
    @Published public var licenseIssue = false
    /// 部分模块失败时的降级提示（非空即在结果页顶部显示横幅）
    @Published public var scanWarning: String?
    /// 扫描完成后计算降级提示（如智能扫描的失败模块清单）
    public var postScanWarning: (@Sendable () -> String?)?
    /// 撤销部分失败时的提示（非空即弹窗）；保留 lastReport 以便重试。
    @Published public var undoFailedItems: [RestorableItem] = []
    public var undoFailedAlert: Bool {
        get { !undoFailedItems.isEmpty }
        set { if !newValue { undoFailedItems = [] } }
    }
    private var isCleaning = false

    public let title: String
    public let intent: DeleteIntent
    private let env: XicoEnvironment
    private let scanProvider: @Sendable (@escaping ProgressHandler) async throws -> [ScanResult]
    private var scanTask: Task<Void, Never>?
    private var cleanTask: Task<Void, Never>?
    private let throttle = ProgressThrottle()
    /// 本次清理写入历史的记录 id（撤销时据此回滚，避免累计释放虚高）
    private var lastHistoryID: UUID?
    /// 清理前的处置钩子（如威胁模块删 plist 前先 bootout 停用已加载 agent）
    public var beforeClean: (@Sendable ([CleanableItem]) async -> Void)?

    /// 清理完成通知观察者：清理后许可闸门可能变化（例如首次清理触发的复验降级），据此重算缓存。
    /// `nonisolated(unsafe)`：仅在 init（@MainActor）赋值一次、在 nonisolated deinit 读取一次移除，
    /// 对象生命周期保证独占访问，Swift 6 下让 deinit 可安全触及此非 Sendable token。
    nonisolated(unsafe) private var didCleanObserver: NSObjectProtocol?
    /// 授权变化观察者（激活/移除/复验后重算购买闸门）——刚激活的用户立刻可清理，无需切页重建会话。
    nonisolated(unsafe) private var licenseChangedObserver: NSObjectProtocol?

    public init(env: XicoEnvironment,
                title: String,
                intent: DeleteIntent,
                scanProvider: @escaping @Sendable (@escaping ProgressHandler) async throws -> [ScanResult]) {
        self.env = env
        self.title = title
        self.intent = intent
        self.scanProvider = scanProvider
        let refresh: @Sendable (Notification) -> Void = { [weak self] _ in
            Task { @MainActor in self?.refreshPurchaseGate() }
        }
        didCleanObserver = NotificationCenter.default.addObserver(
            forName: .xicoDidClean, object: nil, queue: nil, using: refresh)
        licenseChangedObserver = NotificationCenter.default.addObserver(
            forName: .xicoLicenseChanged, object: nil, queue: nil, using: refresh)
    }

    deinit {
        if let didCleanObserver { NotificationCenter.default.removeObserver(didCleanObserver) }
        if let licenseChangedObserver { NotificationCenter.default.removeObserver(licenseChangedObserver) }
    }

    // MARK: 派生数据

    public var selectedItems: [CleanableItem] {
        groups.flatMap { $0.items.filter(\.isSelected) }
    }
    public var selectedRequiresHelper: Bool { selectedItems.contains(where: \.requiresHelper) }
    public var selectedSize: Int64 { selectedItems.reduce(0) { $0 + $1.size } }
    public var selectedCount: Int { selectedItems.count }
    public var totalReclaimable: Int64 { groups.reduce(0) { $0 + $1.reclaimableSize } }   // 剔除「仅提示」字节（终审 P1）
    public var totalItemCount: Int { groups.reduce(0) { $0 + $1.items.count } }

    // MARK: 扫描

    /// 试用结束/许可无效时为 true：结果页仍可扫描与预览，但清理入口应替换为「购买后清理」CTA
    /// （破坏性动作 clean/uninstall/shred 仍由 `ensureLicensed()` 严格拦截，见 clean()）。
    ///
    /// **缓存化（审计 P2）**：改为 @Published 存储属性，只在状态转移点重算（`start()`、扫描落到
    /// `.results`/`.empty`、以及清理完成后的 `.xicoDidClean`），镜像 AppModel 缓存 licenseStatus 的做法。
    /// 绝不再从 body 里读取的计算属性触发 `env.license.status()`（每次重渲染都要磁盘读 + 验签 + 落盘）。
    @Published public private(set) var needsPurchaseToClean = false

    /// 重算购买闸门（一次 status() 磁盘读 + 验签）。只在状态转移点调用，绝不在每帧 body 里调用。
    private func refreshPurchaseGate() {
        needsPurchaseToClean = !env.license.status().state.allowsCommercialUse
    }

    public func start() {
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
        permissionIssue = false
        licenseIssue = false
        scanWarning = nil

        let handler = makeHandler()
        scanTask = Task { [weak self] in
            guard let self else { return }
            do {
                let results = try await self.scanProvider(handler)
                var merged = results.flatMap { $0.groups }.sorted { $0.totalSize > $1.totalSize }
                // 应用用户忽略清单：被排除的项不出现在结果里（对标 CleanMyMac 排除列表）
                let ignore = self.env.ignoreList
                for i in merged.indices { merged[i].items.removeAll { ignore.isIgnored($0.url) } }
                merged.removeAll { $0.items.isEmpty }
                if Task.isCancelled { return }
                self.groups = merged
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
                    self.scanWarning = warnings.isEmpty ? nil : warnings.joined(separator: "\n")
                    self.permissionIssue = !fdaOK
                } else if !fdaOK {
                    // 空结果可能只是没权限——绝不伪装成「很干净」
                    self.permissionIssue = true
                    self.phase = .failed(xLoc("未获完全磁盘访问权限，部分位置无法扫描。授权后可发现更多可清理项。"))
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
        scanTask?.cancel()
        phase = groups.isEmpty ? .idle : .results
    }

    // MARK: 选择

    public func toggleItem(groupID: String, itemID: UUID) {
        guard let gi = groups.firstIndex(where: { $0.id == groupID }),
              let ii = groups[gi].items.firstIndex(where: { $0.id == itemID }) else { return }
        guard !groups[gi].items[ii].isInformational else { return }   // 「仅提示」项不可勾
        groups[gi].items[ii].isSelected.toggle()
    }

    public func setGroup(_ groupID: String, selected: Bool) {
        guard let gi = groups.firstIndex(where: { $0.id == groupID }) else { return }
        // 「仅提示」项不随组全选卷入（三层闸第一层；引擎侧仍会兜底拒删）。
        for i in groups[gi].items.indices where !groups[gi].items[i].isInformational {
            groups[gi].items[i].isSelected = selected
        }
    }

    /// 把某项加入「忽略清单」并从当前结果移除——它今后不再被扫描/清理。
    public func ignore(groupID: String, itemID: UUID) {
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
        guard ensureLicensed() else { return }
        let items = selectedItems
        guard !items.isEmpty, !isCleaning else { return }
        isCleaning = true
        phase = .cleaning
        progress = 0
        statusMessage = xLoc("正在清理…")

        let handler = makeHandler()
        cleanTask = Task { [weak self] in
            guard let self else { return }
            defer { self.isCleaning = false }
            await self.beforeClean?(items)   // 例：威胁模块先 bootout 停用已加载 agent
            let normalItems = items.filter { !$0.requiresHelper }
            let privilegedItems = items.filter(\.requiresHelper)
            var reports: [CleaningReport] = []
            if !normalItems.isEmpty {
                reports.append(await self.env.cleaningEngine.execute(
                    CleaningPlan(items: normalItems, intent: self.intent),
                    progress: handler
                ))
            }
            if !privilegedItems.isEmpty {
                reports.append(await env.cleaningEngine.execute(
                    CleaningPlan(items: privilegedItems, intent: .permanent),
                    progress: handler
                ))
            }
            let report = Self.merge(reports)
            self.lastReport = report
            self.removeCleaned(report)
            // 记入持久化清理历史（可追溯：累计释放 / 最近记录跨会话留存）；
            // 同时持久化 restorable 映射，使「撤销」在离开完成页甚至重启后仍可用。
            self.lastHistoryID = env.history.record(module: self.title,
                                                    reclaimedBytes: report.reclaimedBytes,
                                                    removedCount: report.removedCount,
                                                    restorable: self.intent == .trash ? report.restorable : [])
            self.phase = .finished
            // 签名音效②改在完成页 S-A 幕2 闪光帧齐发（声/触/光同窗，docs/16）——此处不再播避免双响。
            if report.reclaimedBytes > 0 {
                Notifier.notifyCleaningDone(reclaimed: report.reclaimedBytes.formattedBytes,
                                            count: report.removedCount)
            }
            NotificationCenter.default.post(name: .xicoDidClean, object: nil)
        }
    }

    private var isUndoing = false

    public func undo() {
        guard let report = lastReport, !report.restorable.isEmpty, !isUndoing else { return }
        isUndoing = true
        Task {
            defer { self.isUndoing = false }
            let result = await env.cleaningEngine.undo(report)
            if result.allSucceeded {
                // 全部恢复：回滚历史累计、清空报告后重扫
                if let id = lastHistoryID { env.history.remove(id: id); lastHistoryID = nil }
                self.lastReport = nil
                NotificationCenter.default.post(name: .xicoDidClean, object: nil)
                self.start()
            } else {
                // 部分失败：保留报告与历史记录（把已恢复项摘掉，剩下的仍可重试），弹窗告知。
                let remaining = report.restorable.filter { result.failed.contains($0) }
                self.lastReport = CleaningReport(
                    removedCount: report.removedCount, reclaimedBytes: report.reclaimedBytes,
                    failures: report.failures, restorable: remaining)
                // 同步收缩持久化历史的可恢复集，令落盘记录与内存报告一致（审计 P3）——
                // 否则重启后历史仍以为已恢复项可再撤销，累计释放/可撤销状态虚高。
                if let id = lastHistoryID { env.history.updateRestorable(id: id, to: remaining) }
                self.undoFailedItems = result.failed
                NotificationCenter.default.post(name: .xicoDidClean, object: nil)
            }
        }
    }

    /// 在废纸篓中显示未能恢复的项，便于用户手动处理。
    public func revealUndoFailuresInTrash() {
        for item in undoFailedItems { revealInFinder(item.trashedURL) }
    }

    public func reset() {
        phase = .idle
        groups = []
        lastReport = nil
        progress = 0
        progressBytes = 0
    }

    // MARK: 私有

    private func removeCleaned(_ report: CleaningReport) {
        let failedPaths = Set(report.failures.map { $0.url.path })
        for gi in groups.indices {
            groups[gi].items.removeAll { $0.isSelected && !failedPaths.contains($0.url.path) }
        }
        groups.removeAll { $0.items.isEmpty }
    }

    private static func merge(_ reports: [CleaningReport]) -> CleaningReport {
        CleaningReport(
            removedCount: reports.reduce(0) { $0 + $1.removedCount },
            reclaimedBytes: reports.reduce(0) { $0 + $1.reclaimedBytes },
            failures: reports.flatMap(\.failures),
            restorable: reports.flatMap(\.restorable)
        )
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
