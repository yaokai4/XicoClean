import Foundation
import Domain

/// 一条清理历史记录
public struct CleaningRecord: Codable, Identifiable, Sendable, Equatable {
    public let id: UUID
    public let date: Date
    public let module: String
    public let reclaimedBytes: Int64
    public let removedCount: Int
    /// 移入废纸篓的项（原路径 → 废纸篓路径）。非空即可从历史页跨会话「撤销」。
    /// 彻底删除（permanent）的记录此处为空，不可撤销。
    public let restorable: [RestorableItem]

    public init(id: UUID = UUID(), date: Date, module: String,
                reclaimedBytes: Int64, removedCount: Int, restorable: [RestorableItem] = []) {
        self.id = id
        self.date = date
        self.module = module
        self.reclaimedBytes = reclaimedBytes
        self.removedCount = removedCount
        self.restorable = restorable
    }

    // 旧版 history.json 无 restorable 字段——解码时容错默认空数组。
    private enum CodingKeys: String, CodingKey { case id, date, module, reclaimedBytes, removedCount, restorable }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        date = try c.decode(Date.self, forKey: .date)
        module = try c.decode(String.self, forKey: .module)
        reclaimedBytes = try c.decode(Int64.self, forKey: .reclaimedBytes)
        removedCount = try c.decode(Int.self, forKey: .removedCount)
        restorable = try c.decodeIfPresent([RestorableItem].self, forKey: .restorable) ?? []
    }

    public var canUndo: Bool { !restorable.isEmpty }
}

/// 清理历史持久化（Codable JSON，写入 Application Support/Xico/history.json）。
/// 线程安全；把「可撤销」升级为「可追溯」：累计释放、最近记录跨会话留存。
public final class HistoryStore: @unchecked Sendable {
    private let lock = NSLock()
    private let url: URL
    private var records: [CleaningRecord]
    private let maxRecords = 500

    /// directory 可注入（测试用临时目录，避免污染真实清理历史）；默认 Application Support/Xico。
    public init(directory: URL? = nil) {
        let dir: URL
        if let directory {
            dir = directory
        } else {
            let base = (try? FileManager.default.url(for: .applicationSupportDirectory,
                                                     in: .userDomainMask, appropriateFor: nil, create: true))
                ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
            dir = base.appendingPathComponent("Xico", isDirectory: true)
        }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir.appendingPathComponent("history.json")
        if let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode([CleaningRecord].self, from: data) {
            records = decoded
        } else {
            records = []
        }
    }

    /// 追加一条记录（reclaimedBytes<=0 且 removedCount<=0 时忽略）。返回记录 id，便于撤销时回滚。
    @discardableResult
    public func record(module: String, reclaimedBytes: Int64, removedCount: Int,
                       restorable: [RestorableItem] = [], date: Date = Date()) -> UUID? {
        guard reclaimedBytes > 0 || removedCount > 0 else { return nil }
        lock.lock(); defer { lock.unlock() }
        let rec = CleaningRecord(date: date, module: module,
                                 reclaimedBytes: reclaimedBytes, removedCount: removedCount,
                                 restorable: restorable)
        records.insert(rec, at: 0)
        if records.count > maxRecords { records = Array(records.prefix(maxRecords)) }
        persist()
        return rec.id
    }

    /// 撤销后清除某记录的 restorable 映射（保留统计，但标记为已恢复不可再撤销）。
    public func clearRestorable(id: UUID) {
        updateRestorable(id: id, to: [])
    }

    /// 把某记录的 restorable 映射更新为指定子集。撤销部分失败时用来仅保留仍未恢复的项，
    /// 使这些项可重试（而非一次失败就丢掉全部重试能力）。
    public func updateRestorable(id: UUID, to items: [RestorableItem]) {
        lock.lock(); defer { lock.unlock() }
        guard let i = records.firstIndex(where: { $0.id == id }) else { return }
        let r = records[i]
        records[i] = CleaningRecord(id: r.id, date: r.date, module: r.module,
                                    reclaimedBytes: r.reclaimedBytes, removedCount: r.removedCount,
                                    restorable: items)
        persist()
    }

    /// 移除一条记录（撤销清理时回滚历史，避免「累计释放」虚高）
    public func remove(id: UUID) {
        lock.lock(); defer { lock.unlock() }
        records.removeAll { $0.id == id }
        persist()
    }

    public func recent(_ limit: Int = 20) -> [CleaningRecord] {
        lock.lock(); defer { lock.unlock() }
        return Array(records.prefix(limit))
    }

    public var totalReclaimedAllTime: Int64 {
        lock.lock(); defer { lock.unlock() }
        return records.reduce(0) { $0 + $1.reclaimedBytes }
    }

    public var totalCleanups: Int {
        lock.lock(); defer { lock.unlock() }
        return records.count
    }

    public func clear() {
        lock.lock(); defer { lock.unlock() }
        records = []
        persist()
    }

    private func persist() {
        do {
            let data = try JSONEncoder().encode(records)
            try data.write(to: url, options: .atomic)
        } catch {
            XicoLog.history.error("清理历史写盘失败：\(error.localizedDescription, privacy: .public)")
        }
    }
}
