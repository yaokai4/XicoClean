import Foundation

/// 分层历史环形缓冲（P3·M4）：一条指标同时维护三档时间窗——
/// base = 每 tick 原始样本（实时窗，容量 120）；
/// mid  = 10 秒桶均值（≈15 分钟窗，容量 90）；
/// long = 60 秒桶均值（≈1 小时窗，容量 60）。
/// 菜单栏面板折线据此提供「实时 / 15 分 / 1 时」三挡切换（iStat 级时间尺度）。
/// 桶按墙钟时间对齐（timeIntervalSince1970 / 桶宽取整）——采样间隔漂移不影响归桶。
public struct HistoryRings: Sendable, Equatable {
    public private(set) var base: [Double] = []
    public private(set) var mid: [Double] = []
    public private(set) var long: [Double] = []

    public static let baseCap = 120
    public static let midCap = 90
    public static let longCap = 60

    private var midAcc = BucketAcc(width: 10)
    private var longAcc = BucketAcc(width: 60)

    public init() {}

    public mutating func push(_ value: Double, at time: TimeInterval = Date().timeIntervalSince1970) {
        base.append(value)
        if base.count > Self.baseCap { base.removeFirst(base.count - Self.baseCap) }
        if let sealed = midAcc.push(value, at: time) {
            mid.append(sealed)
            if mid.count > Self.midCap { mid.removeFirst(mid.count - Self.midCap) }
        }
        if let sealed = longAcc.push(value, at: time) {
            long.append(sealed)
            if long.count > Self.longCap { long.removeFirst(long.count - Self.longCap) }
        }
    }

    /// 含「进行中桶」的中窗序列（尾部实时跟手，不用等桶封口）。
    public var midLive: [Double] { midAcc.current.map { mid + [$0] } ?? mid }
    public var longLive: [Double] { longAcc.current.map { long + [$0] } ?? long }

    /// 时间桶累加器：桶号变化即封口，返回上一桶均值。
    private struct BucketAcc: Sendable, Equatable {
        let width: Double
        var sum: Double = 0
        var n: Int = 0
        var bucket: Int = -1

        init(width: Double) { self.width = width }

        var current: Double? { n > 0 ? sum / Double(n) : nil }

        mutating func push(_ value: Double, at time: TimeInterval) -> Double? {
            let b = Int(time / width)
            var sealed: Double?
            if b != bucket, n > 0 {
                sealed = sum / Double(n)
                sum = 0
                n = 0
            }
            bucket = b
            sum += value
            n += 1
            return sealed
        }
    }
}

/// 菜单栏面板会用到的全部指标的分层历史。
public struct MetricRings: Sendable, Equatable {
    public var cpu = HistoryRings()
    public var memory = HistoryRings()
    public var gpu = HistoryRings()
    public var netDown = HistoryRings()
    public var netUp = HistoryRings()
    public init() {}

    public mutating func push(cpu c: Double, memory m: Double, gpu g: Double,
                              netDown d: Double, netUp u: Double,
                              at time: TimeInterval = Date().timeIntervalSince1970) {
        cpu.push(c, at: time)
        memory.push(m, at: time)
        gpu.push(g, at: time)
        netDown.push(d, at: time)
        netUp.push(u, at: time)
    }
}

/// 面板折线的时间窗挡位。
public enum HistoryWindow: String, CaseIterable, Sendable {
    case live, mid, long

    public var title: String {
        switch self {
        case .live: return "实时"
        case .mid:  return "15 分"
        case .long: return "1 时"
        }
    }

    public func series(from rings: HistoryRings) -> [Double] {
        switch self {
        case .live: return rings.base
        case .mid:  return rings.midLive
        case .long: return rings.longLive
        }
    }
}
