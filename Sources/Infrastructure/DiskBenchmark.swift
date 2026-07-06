import Foundation
import Darwin

// MARK: - 磁盘测速（顺序读写基准，对标 Sensei 存储器测速）
//
// 方法与 AmorphousDiskMark / Blackmagic 同源：
// - 写：O_CREAT|O_TRUNC|O_WRONLY + F_NOCACHE，8 MB 块顺序写，收尾 fcntl(F_FULLFSYNC) 确保落盘；
// - 读：O_RDONLY + F_NOCACHE，8 MB 块顺序读——绕过统一缓冲缓存，测的是介质而不是内存；
// - 时长自适应：每阶段最多 4 秒或 2 GB，二者先到为准（小盘/慢盘不至于写满、快盘样本充足）；
// - 临时文件写在用户缓存目录（系统卷），结束（含取消/出错）必删。

public struct DiskBenchmarkResult: Codable, Identifiable, Sendable, Equatable {
    public let id: UUID
    public let date: Date
    public let readMBps: Double
    public let writeMBps: Double
    public let device: String

    public init(id: UUID = UUID(), date: Date, readMBps: Double, writeMBps: Double, device: String) {
        self.id = id
        self.date = date
        self.readMBps = readMBps
        self.writeMBps = writeMBps
        self.device = device
    }
}

public enum DiskBenchmarkPhase: Sendable, Equatable {
    case idle
    case writing(currentMBps: Double)
    case reading(currentMBps: Double)
    case done(DiskBenchmarkResult)
    case failed
}

public final class DiskBenchmarkService: @unchecked Sendable {
    public static let chunkBytes = 32 * 1024 * 1024         // 32 MB：摊薄 F_NOCACHE 下的每次调用开销
    public static let maxBytes = Int64(10) * 1024 * 1024 * 1024  // 10 GB：样本大到跨过 SLC/控制器缓存，读写更准
    public static let maxSeconds: TimeInterval = 15          // 每阶段 15s 上限（慢盘兜底）
    /// 需保留的安全余量：可用空间低于「目标 + 余量」时自动缩小测试文件。
    public static let safetyMargin = Int64(4) * 1024 * 1024 * 1024

    /// 按可用空间自适应的实际测试大小（最少 1 GB；不足则返回 nil = 空间太紧不测）。
    public static func targetBytes(freeBytes: Int64) -> Int64? {
        let usable = freeBytes - safetyMargin
        guard usable >= 1024 * 1024 * 1024 else { return nil }
        return min(maxBytes, usable)
    }

    private let historyURL: URL
    private let lock = NSLock()

    public init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Xico", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        historyURL = dir.appendingPathComponent("disk-benchmarks.json")
    }

    // MARK: 历史

    public func history() -> [DiskBenchmarkResult] {
        lock.lock(); defer { lock.unlock() }
        guard let data = try? Data(contentsOf: historyURL),
              let list = try? JSONDecoder().decode([DiskBenchmarkResult].self, from: data) else { return [] }
        return list
    }

    public func append(_ r: DiskBenchmarkResult) {
        lock.lock(); defer { lock.unlock() }
        var list = (try? JSONDecoder().decode([DiskBenchmarkResult].self,
                                              from: (try? Data(contentsOf: historyURL)) ?? Data())) ?? []
        list.insert(r, at: 0)
        if list.count > 24 { list = Array(list.prefix(24)) }   // 只留最近 24 次
        if let data = try? JSONEncoder().encode(list) { try? data.write(to: historyURL, options: .atomic) }
    }

    public func clearHistory() {
        lock.lock(); defer { lock.unlock() }
        try? FileManager.default.removeItem(at: historyURL)
    }

    // MARK: 测速

    /// 运行完整基准（写→读）。`progress` 在采样点回调当前阶段与瞬时速度（主线程外）。
    /// 返回 nil 表示被取消或出错（临时文件已清理）。
    public func run(device: String,
                    isCancelled: @escaping @Sendable () -> Bool = { false },
                    progress: @escaping @Sendable (DiskBenchmarkPhase) -> Void) -> DiskBenchmarkResult? {
        let tmpDir = FileManager.default.temporaryDirectory
        let tmp = tmpDir.appendingPathComponent("xico-diskbench-\(UUID().uuidString).bin")
        defer { try? FileManager.default.removeItem(at: tmp) }

        // 空间预检：按可用空间自适应测试大小，永不写爆磁盘。
        let freeRaw = (try? tmpDir.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage ?? 0
        let free = Int64(freeRaw)
        guard let budget = Self.targetBytes(freeBytes: free) else {
            progress(.failed); return nil
        }

        // —— 写阶段 ——
        guard let writeMBps = writePhase(to: tmp, budget: budget, isCancelled: isCancelled, progress: progress) else {
            progress(.failed); return nil
        }
        if isCancelled() { return nil }
        // —— 读阶段 ——
        guard let readMBps = readPhase(from: tmp, isCancelled: isCancelled, progress: progress) else {
            progress(.failed); return nil
        }
        if isCancelled() { return nil }

        let result = DiskBenchmarkResult(date: Date(), readMBps: readMBps, writeMBps: writeMBps, device: device)
        append(result)
        progress(.done(result))
        return result
    }

    private func writePhase(to url: URL, budget: Int64,
                            isCancelled: @escaping @Sendable () -> Bool,
                            progress: @escaping @Sendable (DiskBenchmarkPhase) -> Void) -> Double? {
        let fd = open(url.path, O_CREAT | O_TRUNC | O_WRONLY, 0o600)
        guard fd >= 0 else { return nil }
        _ = fcntl(fd, F_NOCACHE, 1)
        defer { close(fd) }

        // 缓冲全量随机：零块会被 SSD 固件压缩/去重，读写速度都会虚高（实测读速差 40%+）。
        var buffer = [UInt8](repeating: 0, count: Self.chunkBytes)
        buffer.withUnsafeMutableBytes { ptr in
            arc4random_buf(ptr.baseAddress, ptr.count)
        }

        var total: Int64 = 0
        let start = Date()
        var lastTick = start
        while total < budget, Date().timeIntervalSince(start) < Self.maxSeconds {
            if isCancelled() { return nil }
            let n = buffer.withUnsafeBytes { ptr in write(fd, ptr.baseAddress, ptr.count) }
            guard n > 0 else { return nil }
            total += Int64(n)
            let now = Date()
            if now.timeIntervalSince(lastTick) >= 0.1 {
                let mbps = Double(total) / now.timeIntervalSince(start) / 1_048_576
                progress(.writing(currentMBps: mbps))
                lastTick = now
            }
        }
        _ = fcntl(fd, F_FULLFSYNC)   // 确保真正落盘，速度才诚实
        let elapsed = Date().timeIntervalSince(start)
        guard elapsed > 0.2, total > 0 else { return nil }
        return Double(total) / elapsed / 1_048_576
    }

    private func readPhase(from url: URL,
                           isCancelled: @escaping @Sendable () -> Bool,
                           progress: @escaping @Sendable (DiskBenchmarkPhase) -> Void) -> Double? {
        let fd = open(url.path, O_RDONLY)
        guard fd >= 0 else { return nil }
        _ = fcntl(fd, F_NOCACHE, 1)
        defer { close(fd) }

        var buffer = [UInt8](repeating: 0, count: Self.chunkBytes)
        var total: Int64 = 0
        let start = Date()
        var lastTick = start
        while Date().timeIntervalSince(start) < Self.maxSeconds {
            if isCancelled() { return nil }
            let n = buffer.withUnsafeMutableBytes { ptr in read(fd, ptr.baseAddress, ptr.count) }
            if n == 0 { break }   // 只读一遍：重复读会命中 SSD 控制器缓存，读速虚高
            guard n > 0 else { return nil }
            total += Int64(n)
            let now = Date()
            if now.timeIntervalSince(lastTick) >= 0.1 {
                let mbps = Double(total) / now.timeIntervalSince(start) / 1_048_576
                progress(.reading(currentMBps: mbps))
                lastTick = now
            }
        }
        let elapsed = Date().timeIntervalSince(start)
        guard elapsed > 0.2, total > 0 else { return nil }
        return Double(total) / elapsed / 1_048_576
    }
}
