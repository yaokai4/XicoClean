import Foundation

/// 可告警的指标。
public enum AlertMetric: String, Codable, Sendable, CaseIterable {
    case cpu, memory, disk, gpu, battery, cpuTemp

    public var title: String {
        switch self {
        case .cpu: return "处理器占用"
        case .memory: return "内存占用"
        case .disk: return "磁盘占用"
        case .gpu: return "GPU 占用"
        case .battery: return "电池电量"
        case .cpuTemp: return "处理器温度"
        }
    }
    /// 阈值的展示单位。
    public var unit: String { self == .cpuTemp ? "°C" : "%" }
}

public enum AlertComparison: String, Codable, Sendable {
    case above, below
    public var symbol: String { self == .above ? "＞" : "＜" }
}

/// 一条阈值告警规则。threshold：百分比类为 0...1，温度为摄氏度。
public struct AlertRule: Codable, Sendable, Identifiable, Equatable {
    public var id: String
    public var metric: AlertMetric
    public var comparison: AlertComparison
    public var threshold: Double
    public var durationSeconds: Int   // 持续超阈多久才告警
    public var enabled: Bool

    public init(id: String = UUID().uuidString, metric: AlertMetric, comparison: AlertComparison,
                threshold: Double, durationSeconds: Int = 15, enabled: Bool = true) {
        self.id = id
        self.metric = metric
        self.comparison = comparison
        self.threshold = threshold
        self.durationSeconds = durationSeconds
        self.enabled = enabled
    }

    /// 展示用阈值文案，如 "＞ 90%" / "＜ 20%"。
    public var thresholdText: String {
        let v = metric == .cpuTemp ? String(format: "%.0f", threshold) : "\(Int(threshold * 100))"
        return "\(comparison.symbol) \(v)\(metric.unit)"
    }

    /// 默认规则集（用户可开关/增删）。
    public static let defaults: [AlertRule] = [
        AlertRule(metric: .cpu, comparison: .above, threshold: 0.90, durationSeconds: 20, enabled: false),
        AlertRule(metric: .memory, comparison: .above, threshold: 0.90, durationSeconds: 20, enabled: false),
        AlertRule(metric: .disk, comparison: .above, threshold: 0.92, durationSeconds: 0, enabled: false),
        AlertRule(metric: .battery, comparison: .below, threshold: 0.20, durationSeconds: 0, enabled: false),
        AlertRule(metric: .cpuTemp, comparison: .above, threshold: 95, durationSeconds: 10, enabled: false)
    ]
}

/// 告警规则的存储（UserDefaults JSON）。
public final class AlertRuleStore: @unchecked Sendable {
    private let key = "xico.alertRules"
    private let defaults: UserDefaults
    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    public func load() -> [AlertRule] {
        guard let data = defaults.data(forKey: key),
              let rules = try? JSONDecoder().decode([AlertRule].self, from: data), !rules.isEmpty else {
            return AlertRule.defaults
        }
        return rules
    }

    public func save(_ rules: [AlertRule]) {
        if let data = try? JSONEncoder().encode(rules) { defaults.set(data, forKey: key) }
    }
}

/// 告警评估器：每次采样对每条启用规则判定，持续超阈达 duration 且过冷却期即通知。
/// 由 MetricsEngine 在主线程串行调用，无需额外同步。
public final class AlertEvaluator {
    private var breachStart: [String: Date] = [:]   // 规则 id → 首次超阈时刻
    private var lastFired: [String: Date] = [:]      // 规则 id → 上次通知时刻
    private let cooldown: TimeInterval = 300         // 同一规则 5 分钟冷却
    /// 触发动作（默认发系统通知；测试可注入替身）。
    private let notify: (_ title: String, _ body: String, _ identifier: String) -> Void

    public init(notify: @escaping (_ title: String, _ body: String, _ identifier: String) -> Void = Notifier.notifyAlert) {
        self.notify = notify
    }

    /// value 提取器：给定指标返回当前值（百分比 0...1 或温度℃）；nil 表示该指标当前不可用。
    public func evaluate(rules: [AlertRule], now: Date,
                         value: (AlertMetric) -> Double?) {
        for rule in rules where rule.enabled {
            guard let v = value(rule.metric) else { breachStart[rule.id] = nil; continue }
            let breached = rule.comparison == .above ? v >= rule.threshold : v <= rule.threshold
            if !breached { breachStart[rule.id] = nil; continue }

            let start = breachStart[rule.id] ?? now
            if breachStart[rule.id] == nil { breachStart[rule.id] = now }
            guard now.timeIntervalSince(start) >= Double(rule.durationSeconds) else { continue }

            if let last = lastFired[rule.id], now.timeIntervalSince(last) < cooldown { continue }
            lastFired[rule.id] = now
            fire(rule: rule, value: v)
        }
    }

    private func fire(rule: AlertRule, value: Double) {
        let current: String = rule.metric == .cpuTemp
            ? String(format: "%.0f°C", value)
            : "\(Int(value * 100))%"
        notify("Xico 监控告警",
               "\(rule.metric.title) \(current)（阈值 \(rule.thresholdText)）",
               "xico.alert.\(rule.id)")
    }
}
