import Foundation

/// 一条清理历史记录
public struct CleaningRecord: Codable, Identifiable, Sendable, Equatable {
    public let id: UUID
    public let date: Date
    public let module: String
    public let reclaimedBytes: Int64
    public let removedCount: Int

    public init(id: UUID = UUID(), date: Date, module: String, reclaimedBytes: Int64, removedCount: Int) {
        self.id = id
        self.date = date
        self.module = module
        self.reclaimedBytes = reclaimedBytes
        self.removedCount = removedCount
    }
}

/// 清理历史持久化（Codable JSON，写入 Application Support/Xico/history.json）。
/// 线程安全；把「可撤销」升级为「可追溯」：累计释放、最近记录跨会话留存。
public final class HistoryStore: @unchecked Sendable {
    private let lock = NSLock()
    private let url: URL
    private var records: [CleaningRecord]
    private let maxRecords = 500

    public init() {
        let base = (try? FileManager.default.url(for: .applicationSupportDirectory,
                                                 in: .userDomainMask, appropriateFor: nil, create: true))
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        let dir = base.appendingPathComponent("Xico", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir.appendingPathComponent("history.json")
        if let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode([CleaningRecord].self, from: data) {
            records = decoded
        } else {
            records = []
        }
    }

    /// 追加一条记录（reclaimedBytes<=0 时忽略，避免噪音）
    public func record(module: String, reclaimedBytes: Int64, removedCount: Int, date: Date = Date()) {
        guard reclaimedBytes > 0 || removedCount > 0 else { return }
        lock.lock(); defer { lock.unlock() }
        records.insert(CleaningRecord(date: date, module: module,
                                      reclaimedBytes: reclaimedBytes, removedCount: removedCount), at: 0)
        if records.count > maxRecords { records = Array(records.prefix(maxRecords)) }
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
        if let data = try? JSONEncoder().encode(records) {
            try? data.write(to: url, options: .atomic)
        }
    }
}
