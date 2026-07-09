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
    /// 私有串行队列：encode + 原子落盘在此串行执行（不占 `lock`），读者绝不被磁盘 I/O 阻塞。
    private let ioQueue = DispatchQueue(label: "com.xico.history.persist", qos: .utility)
    /// 单调写序号（`lock` 保护）：每次在锁内领取的快照都带一个更大的序号，用于并发写者定序。
    private var writeSeq: UInt64 = 0
    /// 已落盘的最新快照序号（仅在 `ioQueue` 内访问）：较旧序号的快照绝不覆盖较新的（防写盘乱序回退）。
    private var lastWrittenSeq: UInt64 = 0

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
        lock.lock()
        let rec = CleaningRecord(date: date, module: module,
                                 reclaimedBytes: reclaimedBytes, removedCount: removedCount,
                                 restorable: restorable)
        records.insert(rec, at: 0)
        if records.count > maxRecords { records = Array(records.prefix(maxRecords)) }
        let snap = snapshotForPersist()
        lock.unlock()
        persist(snap)
        return rec.id
    }

    /// 撤销后清除某记录的 restorable 映射（保留统计，但标记为已恢复不可再撤销）。
    public func clearRestorable(id: UUID) {
        updateRestorable(id: id, to: [])
    }

    /// 把某记录的 restorable 映射更新为指定子集。撤销部分失败时用来仅保留仍未恢复的项，
    /// 使这些项可重试（而非一次失败就丢掉全部重试能力）。
    public func updateRestorable(id: UUID, to items: [RestorableItem]) {
        lock.lock()
        guard let i = records.firstIndex(where: { $0.id == id }) else { lock.unlock(); return }
        let r = records[i]
        records[i] = CleaningRecord(id: r.id, date: r.date, module: r.module,
                                    reclaimedBytes: r.reclaimedBytes, removedCount: r.removedCount,
                                    restorable: items)
        let snap = snapshotForPersist()
        lock.unlock()
        persist(snap)
    }

    /// 移除一条记录（撤销清理时回滚历史，避免「累计释放」虚高）
    public func remove(id: UUID) {
        lock.lock()
        records.removeAll { $0.id == id }
        let snap = snapshotForPersist()
        lock.unlock()
        persist(snap)
    }

    public func recent(_ limit: Int = 20) -> [CleaningRecord] {
        lock.lock(); defer { lock.unlock() }
        return Array(records.prefix(limit))
    }

    /// 最近**仍可真正撤销**的记录：其废纸篓映射至少有一项仍存在于磁盘。
    ///
    /// 关键修复：`canUndo` 只看 restorable 是否为空，不看废纸篓里文件是否还在——
    /// 用户清空废纸篓（或手动删除）后，撤销卡片仍空许「可一键放回原位」，点了必然全失败。
    /// 这里在读取时按文件系统现实**自愈**：把已消失的映射剪除并落盘，
    /// 使 UI 只在真正可恢复时才展示撤销入口。`existsInTrash` 可注入用于测试。
    public func firstUndoable(within limit: Int = 3,
                              existsInTrash: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }) -> CleaningRecord? {
        lock.lock()
        var mutated = false
        var result: CleaningRecord?
        for i in records.indices.prefix(limit) {
            let r = records[i]
            guard !r.restorable.isEmpty else { continue }
            let alive = r.restorable.filter { existsInTrash($0.trashedURL) }
            if alive.count != r.restorable.count {
                records[i] = CleaningRecord(id: r.id, date: r.date, module: r.module,
                                            reclaimedBytes: r.reclaimedBytes, removedCount: r.removedCount,
                                            restorable: alive)
                mutated = true
            }
            if !alive.isEmpty { result = records[i]; break }
        }
        let snap = mutated ? snapshotForPersist() : nil
        lock.unlock()
        // 自愈剪除后**同步**落盘：保住「firstUndoable 返回即已把剪除结果持久化」的既定契约
        // （否则进程随后退出会丢掉剪除，已消失的项下次又被当作可撤销）。仅在真的发生剪除时才写，
        // 频率低、体量小；序号守卫仍保证不被更旧快照回退覆盖，磁盘最终态恒为最新快照。
        if let snap { persist(snap) }
        return result
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
        lock.lock()
        records = []
        let snap = snapshotForPersist()
        lock.unlock()
        persist(snap)
    }

    /// 调用方**已持有 `lock`**：在临界区内仅做一次廉价的数组快照并领取单调序号后即可释放锁。
    /// 真正的 encode + 原子写盘交由 `persist(_:)` 在释放锁之后进行，读者绝不被磁盘 I/O 阻塞。
    private func snapshotForPersist() -> (records: [CleaningRecord], seq: UInt64) {
        writeSeq &+= 1
        return (records, writeSeq)
    }

    /// **释放锁之后**调用：在私有串行队列上**同步**完成 encode + 原子写盘——
    /// 「同步」保住「record/remove 返回即已落盘」的持久化语义（撤销映射不能丢），
    /// 「串行队列 + 不占 `lock`」保住读者不被磁盘 I/O 阻塞。序号守卫使并发写者中较旧的快照
    /// 绝不覆盖较新的（无论二者到达 ioQueue 的先后），磁盘最终态恒为最新快照。
    /// `sync=true`（record/remove/updateRestorable/clear 等写路径）：**同步**落盘，保住
    /// 「返回即已落盘」的持久化语义（撤销映射不能丢）。`sync=false`（firstUndoable 的读时自愈）：
    /// **异步**落盘，读者不被磁盘 I/O 阻塞。两者都在同一私有串行队列上执行，序号守卫使较旧快照
    /// 绝不覆盖较新的（无论到达先后），磁盘最终态恒为最新快照。
    private func persist(_ snapshot: (records: [CleaningRecord], seq: UInt64), sync: Bool = true) {
        let work = { [self] in
            guard snapshot.seq > lastWrittenSeq else { return }   // 已有更新的快照落过盘：跳过陈旧写
            do {
                let data = try JSONEncoder().encode(snapshot.records)
                try data.write(to: url, options: .atomic)
                lastWrittenSeq = snapshot.seq
            } catch {
                XicoLog.history.error("清理历史写盘失败：\(error.localizedDescription, privacy: .public)")
            }
        }
        if sync { ioQueue.sync(execute: work) } else { ioQueue.async(execute: work) }
    }
}
