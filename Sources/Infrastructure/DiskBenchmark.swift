import Foundation
import Darwin

// MARK: - 磁盘测速引擎 v2（对标并超越 Blackmagic Disk Speed Test / AmorphousDiskMark）
//
// 方法学（2026-07 实测标定，见 docs/14 附录）：
// - **对齐缓冲**：posix_memalign 16KB 对齐——Swift 数组/malloc 未对齐缓冲在 F_NOCACHE 下慢 31%
//   （M1 实测 1196 → 1567 MB/s），这是自研测速普遍偏低的头号暗坑；
// - **顺序读写 = 64MB 块 × QD2**（两线程 pwrite/pread 不相交区段）：单线程 QD1 无法喂饱
//   Apple NVMe 写入（1567 vs QD2 1958 MB/s），Blackmagic 的成绩正来自多路在途 I/O；
// - **F_NOCACHE** 全程直读介质（绕过统一缓冲缓存）；数据全量不可压缩（arc4random）——
//   零块会被控制器压缩/去重，读写全虚高；
// - **落盘刷新单独计时**：F_FULLFSYNC 不计入吞吐（Blackmagic/CrystalDiskMark 均不含），
//   但如实单列展示——比它们多一层诚实；
// - **RND4K 专业矩阵**：4K 随机 QD1（IOPS + 平均/尾延迟）与 QD32（并发深度饱和 IOPS）——
//   系统响应手感由随机小 I/O 决定，这是 Blackmagic 没有的一层；
// - **瞬时速度**：0.25s 窗口增量（不是累计均值）——仪表指针跟的是「现在」，均值只在收尾定格；
// - 测试文件写在**所选卷**（默认系统卷，支持外置盘），结束（含取消/出错）必删。

public struct DiskBenchmarkResult: Codable, Identifiable, Sendable, Equatable {
    public let id: UUID
    public let date: Date
    public let readMBps: Double
    public let writeMBps: Double
    public let device: String
    // —— v2 扩展（全部可选：旧历史 JSON 无键自动 nil，向后兼容）——
    /// 首个 0.5s 窗口的写入峰值（SLC/控制器缓存爆发观察；≈ 持续值时说明盘很稳）。
    public var burstWriteMBps: Double?
    /// F_FULLFSYNC 全量落盘刷新耗时（秒）——不计入吞吐，单列诚实展示。
    public var flushSeconds: Double?
    /// 实际测试文件大小（字节）。
    public var fileBytes: Int64?
    /// 测试卷路径（nil = 系统卷临时目录，旧记录）。
    public var volumePath: String?
    /// RND4K QD1 随机读：IOPS / 平均延迟 µs / p99 延迟 µs。
    public var rnd4kReadIOPS: Double?
    public var rnd4kReadAvgUS: Double?
    public var rnd4kReadP99US: Double?
    /// RND4K QD1 随机写。
    public var rnd4kWriteIOPS: Double?
    public var rnd4kWriteAvgUS: Double?
    /// RND4K QD32 饱和深度。
    public var rnd4kQD32ReadIOPS: Double?
    public var rnd4kQD32WriteIOPS: Double?

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
    /// RND4K 阶段（stage：本地化 key，如 "随机读 4K"）。
    case random(stage: String, iops: Double)
    case done(DiskBenchmarkResult)
    case failed
}

// MARK: 对齐缓冲（F_NOCACHE 正确性与速度的前提）

/// posix_memalign 分配的 16KB 对齐缓冲；生命周期由持有者保证（deinit 释放）。
final class AlignedBuffer: @unchecked Sendable {
    let pointer: UnsafeMutableRawPointer
    let count: Int
    init?(count: Int, alignment: Int = 16384, randomized: Bool) {
        var ptr: UnsafeMutableRawPointer?
        guard posix_memalign(&ptr, alignment, count) == 0, let p = ptr else { return nil }
        self.pointer = p
        self.count = count
        if randomized { arc4random_buf(p, count) }   // 不可压缩：控制器压缩/去重会让成绩虚高
    }
    deinit { free(pointer) }
}

/// 跨线程字节计数器（进度采样用）。
private final class AtomicBytes: @unchecked Sendable {
    private let lock = NSLock()
    private var v: Int64 = 0
    func add(_ n: Int64) { lock.lock(); v += n; lock.unlock() }
    var value: Int64 { lock.lock(); defer { lock.unlock() }; return v }
}

public final class DiskBenchmarkService: @unchecked Sendable {
    public static let seqChunkBytes = 64 * 1024 * 1024       // 64MB：大块摊薄 NOCACHE 每调用开销（实测优于 8/32MB）
    public static let seqThreads = 2                          // QD2：喂饱 Apple NVMe 写入的最小并发（实测 +25%）
    public static let maxBytes = Int64(10) * 1024 * 1024 * 1024
    public static let maxSeconds: TimeInterval = 15
    public static let rndSeconds: TimeInterval = 2.0          // 每个 RND4K 子测 2s（CrystalDiskMark 同量级）
    public static let rndQDeep = 32
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

    /// 运行完整基准（顺序写 → 顺序读 → RND4K 矩阵）。
    /// `volume`：测试目标卷根（nil = 系统卷临时目录）——外置盘测速的关键入口。
    /// 返回 nil 表示被取消或出错（临时文件已清理）。
    public func run(device: String,
                    volume: URL? = nil,
                    isCancelled: @escaping @Sendable () -> Bool = { false },
                    progress: @escaping @Sendable (DiskBenchmarkPhase) -> Void) -> DiskBenchmarkResult? {
        // 测试文件必须落在被测卷上（temporaryDirectory 永远在系统卷——外置盘测速的经典错误）。
        let dir = volume ?? FileManager.default.temporaryDirectory
        let tmp = dir.appendingPathComponent(".xico-diskbench-\(UUID().uuidString).bin")
        defer { try? FileManager.default.removeItem(at: tmp) }

        // 空间预检：按被测卷可用空间自适应，永不写爆磁盘。
        let freeRaw = (try? dir.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage ?? 0
        guard let budget = Self.targetBytes(freeBytes: Int64(freeRaw)) else {
            progress(.failed); return nil
        }

        // —— 顺序写（QD2 · 64MB 对齐块 · 不可压缩）——
        guard let w = seqWritePhase(to: tmp, budget: budget, isCancelled: isCancelled, progress: progress) else {
            progress(.failed); return nil
        }
        if isCancelled() { return nil }
        // —— 顺序读（QD2 · 单遍：重复读会命中控制器缓存虚高）——
        guard let r = seqReadPhase(from: tmp, isCancelled: isCancelled, progress: progress) else {
            progress(.failed); return nil
        }
        if isCancelled() { return nil }

        var result = DiskBenchmarkResult(date: Date(), readMBps: r.mbps, writeMBps: w.mbps, device: device)
        result.burstWriteMBps = w.burstMBps
        result.flushSeconds = w.flushSeconds
        result.fileBytes = w.bytes
        result.volumePath = volume?.path

        // —— RND4K 矩阵（每子测 2s；取消检查穿插其间）——
        let fileBytes = w.bytes
        if !isCancelled(), let rr = rnd4k(path: tmp.path, fileBytes: fileBytes, write: false, threads: 1,
                                          stage: "随机读 4K", isCancelled: isCancelled, progress: progress) {
            result.rnd4kReadIOPS = rr.iops
            result.rnd4kReadAvgUS = rr.avgUS
            result.rnd4kReadP99US = rr.p99US
        }
        if !isCancelled(), let rw = rnd4k(path: tmp.path, fileBytes: fileBytes, write: true, threads: 1,
                                          stage: "随机写 4K", isCancelled: isCancelled, progress: progress) {
            result.rnd4kWriteIOPS = rw.iops
            result.rnd4kWriteAvgUS = rw.avgUS
        }
        if !isCancelled(), let qr = rnd4k(path: tmp.path, fileBytes: fileBytes, write: false, threads: Self.rndQDeep,
                                          stage: "随机读 4K · 深队列", isCancelled: isCancelled, progress: progress) {
            result.rnd4kQD32ReadIOPS = qr.iops
        }
        if !isCancelled(), let qw = rnd4k(path: tmp.path, fileBytes: fileBytes, write: true, threads: Self.rndQDeep,
                                          stage: "随机写 4K · 深队列", isCancelled: isCancelled, progress: progress) {
            result.rnd4kQD32WriteIOPS = qw.iops
        }
        if isCancelled() { return nil }

        append(result)
        progress(.done(result))
        return result
    }

    // MARK: 顺序阶段（QD2 并发 · 瞬时窗口采样）

    private struct SeqOutcome { let mbps: Double; let bytes: Int64; let flushSeconds: Double?; let burstMBps: Double? }

    private func seqWritePhase(to url: URL, budget: Int64,
                               isCancelled: @escaping @Sendable () -> Bool,
                               progress: @escaping @Sendable (DiskBenchmarkPhase) -> Void) -> SeqOutcome? {
        let fd = open(url.path, O_CREAT | O_TRUNC | O_RDWR, 0o600)
        guard fd >= 0 else { return nil }
        _ = fcntl(fd, F_NOCACHE, 1)
        defer { close(fd) }

        // 连续预分配（fio/DiskTruth 同法）：把 APFS 分配开销踢出计时；失败退回普通分配（不致命）。
        var store = fstore_t(fst_flags: UInt32(F_ALLOCATECONTIG | F_ALLOCATEALL),
                             fst_posmode: F_PEOFPOSMODE, fst_offset: 0,
                             fst_length: off_t(budget), fst_bytesalloc: 0)
        if fcntl(fd, F_PREALLOCATE, &store) == -1 {
            store.fst_flags = UInt32(F_ALLOCATEALL)   // 连续分配不满足 → 允许碎片分配
            _ = fcntl(fd, F_PREALLOCATE, &store)
        }
        _ = ftruncate(fd, off_t(budget))

        guard let outcome = parallelSequential(fd: fd, totalBytes: budget, isWrite: true,
                                               isCancelled: isCancelled,
                                               tick: { mbps in progress(.writing(currentMBps: mbps)) })
        else { return nil }

        // 落盘刷新单独计时：不掺进吞吐（对齐 Blackmagic/CDM 口径），但如实记录展示。
        let f0 = Date()
        _ = fcntl(fd, F_FULLFSYNC)
        let flush = Date().timeIntervalSince(f0)
        return SeqOutcome(mbps: outcome.mbps, bytes: outcome.bytes, flushSeconds: flush, burstMBps: outcome.burstMBps)
    }

    private func seqReadPhase(from url: URL,
                              isCancelled: @escaping @Sendable () -> Bool,
                              progress: @escaping @Sendable (DiskBenchmarkPhase) -> Void) -> SeqOutcome? {
        let fd = open(url.path, O_RDONLY)
        guard fd >= 0 else { return nil }
        _ = fcntl(fd, F_NOCACHE, 1)
        _ = fcntl(fd, F_RDAHEAD, 0)   // 关预读：读测才是纯介质，不掺内核预取
        defer { close(fd) }
        let size = lseek(fd, 0, SEEK_END)
        guard size > 0 else { return nil }
        guard let outcome = parallelSequential(fd: fd, totalBytes: size, isWrite: false,
                                               isCancelled: isCancelled,
                                               tick: { mbps in progress(.reading(currentMBps: mbps)) })
        else { return nil }
        return SeqOutcome(mbps: outcome.mbps, bytes: outcome.bytes, flushSeconds: nil, burstMBps: nil)
    }

    private struct ParallelOutcome { let mbps: Double; let bytes: Int64; let burstMBps: Double? }

    /// QD_N 顺序 I/O：N 线程各负责文件的一个不相交连续区段（pread/pwrite 带显式偏移，无共享游标）。
    /// 主线程做 0.25s 窗口采样：瞬时速度给仪表，首个 0.5s 峰值单独记录（SLC 爆发观察）。
    private func parallelSequential(fd: Int32, totalBytes: Int64, isWrite: Bool,
                                    isCancelled: @escaping @Sendable () -> Bool,
                                    tick: @escaping @Sendable (Double) -> Void) -> ParallelOutcome? {
        let threads = Self.seqThreads
        let chunk = Self.seqChunkBytes
        let per = totalBytes / Int64(threads)
        guard per >= Int64(chunk) else { return nil }

        let counter = AtomicBytes()
        let deadline = Date().addingTimeInterval(Self.maxSeconds)
        let group = DispatchGroup()
        let failed = AtomicBytes()   // >0 = 有 worker 出错

        for i in 0..<threads {
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                defer { group.leave() }
                guard let buf = AlignedBuffer(count: chunk, randomized: isWrite) else {
                    failed.add(1); return
                }
                var off = per * Int64(i)
                let end = off + per
                while off < end, Date() < deadline, !isCancelled() {
                    let want = Int(min(Int64(chunk), end - off))
                    let n = isWrite ? pwrite(fd, buf.pointer, want, off)
                                    : pread(fd, buf.pointer, want, off)
                    if n <= 0 { if isWrite { failed.add(1) }; break }
                    off += Int64(n)
                    counter.add(Int64(n))
                }
            }
        }

        // 采样线程：0.25s 窗口瞬时速度；首 0.5s 峰值 = 爆发观察。
        let start = Date()
        var lastBytes: Int64 = 0
        var lastTime = start
        var burst: Double?
        while group.wait(timeout: .now() + 0.25) == .timedOut {
            let nowBytes = counter.value
            let now = Date()
            let dt = now.timeIntervalSince(lastTime)
            if dt > 0.01 {
                let inst = Double(nowBytes - lastBytes) / dt / 1_048_576
                tick(inst)
                if burst == nil, now.timeIntervalSince(start) >= 0.5 { burst = inst }
            }
            lastBytes = nowBytes
            lastTime = now
        }

        let elapsed = Date().timeIntervalSince(start)
        let total = counter.value
        guard failed.value == 0 || total > 0, elapsed > 0.2, total > 0 else { return nil }
        if isCancelled() { return nil }
        return ParallelOutcome(mbps: Double(total) / elapsed / 1_048_576, bytes: total,
                               burstMBps: isWrite ? burst : nil)
    }

    // MARK: RND4K（QD1 延迟 / QD_N 饱和 IOPS）

    private struct RndOutcome { let iops: Double; let avgUS: Double; let p99US: Double }

    /// 4K 随机读/写 `seconds` 秒。threads=1 时逐次计时（延迟分布）；多线程时只算聚合 IOPS。
    /// 随机写覆写测试文件内部块（不扩文件、不碰用户数据）。
    private func rnd4k(path: String, fileBytes: Int64, write: Bool, threads: Int, stage: String,
                       isCancelled: @escaping @Sendable () -> Bool,
                       progress: @escaping @Sendable (DiskBenchmarkPhase) -> Void) -> RndOutcome? {
        let blockCount = fileBytes / 4096
        guard blockCount > 256 else { return nil }
        let deadline = Date().addingTimeInterval(Self.rndSeconds)
        let opsCounter = AtomicBytes()
        let group = DispatchGroup()
        let latLock = NSLock()
        var latenciesUS: [Double] = []   // 仅 QD1 收集

        for _ in 0..<threads {
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                defer { group.leave() }
                let fd = open(path, write ? O_WRONLY : O_RDONLY)
                guard fd >= 0 else { return }
                _ = fcntl(fd, F_NOCACHE, 1)
                defer { close(fd) }
                guard let buf = AlignedBuffer(count: 4096, alignment: 4096, randomized: write) else { return }
                var local: [Double] = []
                let collectLatency = (threads == 1)
                while Date() < deadline, !isCancelled() {
                    let block = Int64(arc4random_uniform(UInt32(truncatingIfNeeded: min(blockCount, Int64(UInt32.max)))))
                    let off = block * 4096
                    let t0 = collectLatency ? DispatchTime.now().uptimeNanoseconds : 0
                    let n = write ? pwrite(fd, buf.pointer, 4096, off)
                                  : pread(fd, buf.pointer, 4096, off)
                    guard n == 4096 else { break }
                    if collectLatency {
                        local.append(Double(DispatchTime.now().uptimeNanoseconds - t0) / 1000)
                    }
                    opsCounter.add(1)
                }
                if collectLatency {
                    latLock.lock(); latenciesUS = local; latLock.unlock()
                }
            }
        }

        let start = Date()
        while group.wait(timeout: .now() + 0.25) == .timedOut {
            let secs = Date().timeIntervalSince(start)
            if secs > 0.05 { progress(.random(stage: stage, iops: Double(opsCounter.value) / secs)) }
        }
        let elapsed = min(Date().timeIntervalSince(start), Self.rndSeconds)
        let ops = opsCounter.value
        guard ops > 0, elapsed > 0.2, !isCancelled() else { return nil }
        let iops = Double(ops) / elapsed
        var avg = 0.0, p99 = 0.0
        if !latenciesUS.isEmpty {
            avg = latenciesUS.reduce(0, +) / Double(latenciesUS.count)
            let sorted = latenciesUS.sorted()
            p99 = sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.99))]
        }
        return RndOutcome(iops: iops, avgUS: avg, p99US: p99)
    }
}
