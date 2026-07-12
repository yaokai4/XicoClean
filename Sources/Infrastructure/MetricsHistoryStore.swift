import Foundation

/// 一个历史采样点（1 分钟粒度）。
public struct MetricsHistoryPoint: Codable, Sendable {
    public let t: Double        // Unix 时间戳
    public let cpu: Double      // 0...1
    public let mem: Double
    public let gpu: Double
    public let netDown: Double  // 字节/秒
    public let netUp: Double

    public init(t: Double, cpu: Double, mem: Double, gpu: Double, netDown: Double, netUp: Double) {
        self.t = t; self.cpu = cpu; self.mem = mem; self.gpu = gpu
        self.netDown = netDown; self.netUp = netUp
    }
}

/// 指标历史落盘：1 分钟粒度环形存储，保留 7 天（约 10080 点），供监视页切换时间范围。
/// 写入按分钟去重（同一分钟只记一次，用该分钟的最新值）。
public final class MetricsHistoryStore: @unchecked Sendable {
    public enum Range: String, CaseIterable, Sendable {
        case minute, hour, day, week
        /// 覆盖的秒数。
        public var seconds: Double {
            switch self {
            case .minute: return 60
            case .hour: return 3600
            case .day: return 86400
            case .week: return 604800
            }
        }
        public var title: String {
            switch self {
            case .minute: return "1 分钟"
            case .hour: return "1 小时"
            case .day: return "24 小时"
            case .week: return "7 天"
            }
        }
    }

    private let lock = NSLock()
    private var points: [MetricsHistoryPoint] = []
    private var lastMinute: Int = -1
    private let fileURL: URL
    private let maxPoints = 10_080 + 128   // 7 天 + 余量
    private var dirty = false
    // 落盘在专用串行队列执行，避免主线程被万级 JSON 编码 + 原子写盘阻塞；串行保证两次 flush 不交叉写。
    private let ioQueue = DispatchQueue(label: "app.xico.metrics-history.io", qos: .utility)

    /// fileURL 可注入以便测试隔离；默认写入 Application Support/Xico/metrics-history.json。
    public init(fileURL: URL? = nil) {
        if let url = fileURL {
            self.fileURL = url
        } else {
            let base = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                     appropriateFor: nil, create: true))
                ?? FileManager.default.temporaryDirectory
            let dir = base.appendingPathComponent("Xico", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            self.fileURL = dir.appendingPathComponent("metrics-history.json")
        }
        load()
    }

    /// 记录一个采样（内部按分钟去重）。now 由调用方传入以便测试。
    public func record(_ p: MetricsHistoryPoint, now: Date) {
        let minute = Int(now.timeIntervalSince1970 / 60)
        lock.lock(); defer { lock.unlock() }
        // 防时钟回拨：新点时间早于最后一点则丢弃，避免 points 失序、图表时间倒挂并被持久化。
        if let last = points.last, p.t < last.t { return }
        if minute == lastMinute, !points.isEmpty {
            points[points.count - 1] = p   // 同一分钟：覆盖为最新
        } else {
            points.append(p)
            lastMinute = minute
            if points.count > maxPoints { points.removeFirst(points.count - maxPoints) }
        }
        dirty = true
    }

    /// 取某时间范围内的点（保证按时间升序，供下游按下标画折线）。
    /// `points` 由 record() 维持严格升序（回拨点在 :72 被拒），filter 保序 → 无需再 sort。
    /// 去掉对最多上万点的每帧冗余排序（2026-07 卡死修复：监视页每次 body 求值都会调用本方法）。
    public func points(in range: Range, now: Date) -> [MetricsHistoryPoint] {
        let cutoff = now.timeIntervalSince1970 - range.seconds
        lock.lock(); defer { lock.unlock() }
        return points.filter { $0.t >= cutoff }
    }

    /// 落盘（脏才写）。可在主线程低频调用——编码与写盘派发到后台串行队列，不阻塞调用线程。
    public func flush() {
        lock.lock()
        guard dirty else { lock.unlock(); return }
        let snapshot = points
        dirty = false
        lock.unlock()
        let url = fileURL
        ioQueue.async {
            if let data = try? JSONEncoder().encode(snapshot) {
                try? data.write(to: url, options: .atomic)
            }
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let loaded = try? JSONDecoder().decode([MetricsHistoryPoint].self, from: data) else { return }
        points = loaded
        lastMinute = loaded.last.map { Int($0.t / 60) } ?? -1
    }
}
