import SwiftUI
import Domain
import Infrastructure

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

    public init(env: XicoEnvironment,
                title: String,
                intent: DeleteIntent,
                scanProvider: @escaping @Sendable (@escaping ProgressHandler) async throws -> [ScanResult]) {
        self.env = env
        self.title = title
        self.intent = intent
        self.scanProvider = scanProvider
    }

    // MARK: 派生数据

    public var selectedItems: [CleanableItem] {
        groups.flatMap { $0.items.filter(\.isSelected) }
    }
    public var selectedRequiresHelper: Bool { selectedItems.contains(where: \.requiresHelper) }
    public var selectedSize: Int64 { selectedItems.reduce(0) { $0 + $1.size } }
    public var selectedCount: Int { selectedItems.count }
    public var totalReclaimable: Int64 { groups.reduce(0) { $0 + $1.totalSize } }
    public var totalItemCount: Int { groups.reduce(0) { $0 + $1.items.count } }

    // MARK: 扫描

    public func start() {
        guard ensureLicensed() else { return }
        scanTask?.cancel()
        phase = .scanning
        progress = 0
        progressBytes = 0
        statusMessage = "正在扫描…"
        groups = []
        lastReport = nil
        permissionIssue = false
        licenseIssue = false

        let handler = makeHandler()
        scanTask = Task {
            do {
                let results = try await scanProvider(handler)
                var merged = results.flatMap { $0.groups }.sorted { $0.totalSize > $1.totalSize }
                // 应用用户忽略清单：被排除的项不出现在结果里（对标 CleanMyMac 排除列表）
                let ignore = self.env.ignoreList
                for i in merged.indices { merged[i].items.removeAll { ignore.isIgnored($0.url) } }
                merged.removeAll { $0.items.isEmpty }
                if Task.isCancelled { return }
                self.groups = merged
                if !merged.isEmpty {
                    self.phase = .results
                } else if !self.env.permissions.hasFullDiskAccess() {
                    // 空结果可能只是没权限——绝不伪装成「很干净」
                    self.permissionIssue = true
                    self.phase = .failed("未获完全磁盘访问权限，部分位置无法扫描。授权后可发现更多可清理项。")
                } else {
                    self.phase = .empty
                }
            } catch is CancellationError {
                // 用户取消：保持 cancel() 设定的状态
            } catch {
                if Task.isCancelled { return }
                XicoLog.scan.error("扫描失败 [\(self.title, privacy: .public)]: \(error.localizedDescription, privacy: .public)")
                self.phase = .failed("扫描时出错：\(error.localizedDescription)")
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
        groups[gi].items[ii].isSelected.toggle()
    }

    public func setGroup(_ groupID: String, selected: Bool) {
        guard let gi = groups.firstIndex(where: { $0.id == groupID }) else { return }
        for i in groups[gi].items.indices { groups[gi].items[i].isSelected = selected }
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
        statusMessage = "正在清理…"

        let handler = makeHandler()
        cleanTask = Task {
            defer { self.isCleaning = false }
            let normalItems = items.filter { !$0.requiresHelper }
            let privilegedItems = items.filter(\.requiresHelper)
            var reports: [CleaningReport] = []
            if !normalItems.isEmpty {
                reports.append(await env.cleaningEngine.execute(
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
            phase = .failed("试用已结束或许可证无效。\(status.summary)")
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
