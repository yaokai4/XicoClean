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

    public let title: String
    public let intent: DeleteIntent
    private let env: XicoEnvironment
    private let scanProvider: @Sendable (@escaping ProgressHandler) async throws -> [ScanResult]
    private var scanTask: Task<Void, Never>?
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
                let merged = results.flatMap { $0.groups }.sorted { $0.totalSize > $1.totalSize }
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

    public func groupSelectionState(_ group: ScanResultGroup) -> Bool {
        !group.items.isEmpty && group.items.allSatisfy(\.isSelected)
    }

    // MARK: 清理

    public func clean() {
        guard ensureLicensed() else { return }
        let items = selectedItems
        guard !items.isEmpty else { return }
        phase = .cleaning
        progress = 0
        statusMessage = "正在清理…"

        let handler = makeHandler()
        Task {
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
            // 记入持久化清理历史（可追溯：累计释放 / 最近记录跨会话留存）
            self.lastHistoryID = env.history.record(module: self.title,
                                                    reclaimedBytes: report.reclaimedBytes,
                                                    removedCount: report.removedCount)
            self.phase = .finished
            NotificationCenter.default.post(name: .xicoDidClean, object: nil)
        }
    }

    public func undo() {
        guard let report = lastReport, !report.restorable.isEmpty else { return }
        // 回滚历史，避免撤销后「累计释放」仍计入这次清理
        if let id = lastHistoryID { env.history.remove(id: id); lastHistoryID = nil }
        Task {
            _ = await env.cleaningEngine.undo(report)
            self.lastReport = nil
            NotificationCenter.default.post(name: .xicoDidClean, object: nil)
            self.start()
        }
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
            phase = .failed("试用已结束或许可证无效。请在设置中导入有效许可证后继续。\(status.summary)")
            NotificationCenter.default.post(name: .xicoOpenSettings, object: nil)
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
