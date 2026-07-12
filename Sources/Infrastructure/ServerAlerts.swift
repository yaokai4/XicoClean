import Foundation
import Domain

/// 服务器阈值告警——ServerCat 完全没有的能力（它零告警、零推送，用户必须开 App 才知道出事）。
/// 规则为全局（应用到所有已连接主机），在监控引擎每帧评估，持续超阈 N 次采样后触发系统推送，
/// 恢复后自动清除（并可选发恢复通知）。外加「主机掉线」通知。

public enum ServerAlertMetric: String, Codable, Sendable, CaseIterable, Identifiable {
    case cpu, memory, disk, load1
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .cpu: return "处理器"
        case .memory: return "内存"
        case .disk: return "磁盘"
        case .load1: return "负载(1m)"
        }
    }
    public var isFraction: Bool { self != .load1 }
    public func value(from s: RemoteSnapshot) -> Double {
        switch self {
        case .cpu: return s.cpuUsage
        case .memory: return s.memUsedFraction
        case .disk: return s.rootDiskFraction
        case .load1: return s.load1
        }
    }
}

public enum ServerAlertComparison: String, Codable, Sendable {
    case above, below
    public var symbol: String { self == .above ? "＞" : "＜" }
    public func breached(_ value: Double, _ threshold: Double) -> Bool {
        self == .above ? value > threshold : value < threshold
    }
}

public struct ServerAlertRule: Codable, Sendable, Identifiable, Equatable {
    public var id: String
    public var metric: ServerAlertMetric
    public var comparison: ServerAlertComparison
    /// 分数类为 0...1；load 为绝对值。
    public var threshold: Double
    /// 持续多少次采样超阈才告警（去抖）。
    public var sustainedSamples: Int
    public var enabled: Bool

    public init(id: String = UUID().uuidString, metric: ServerAlertMetric, comparison: ServerAlertComparison,
                threshold: Double, sustainedSamples: Int = 3, enabled: Bool = true) {
        self.id = id; self.metric = metric; self.comparison = comparison
        self.threshold = threshold; self.sustainedSamples = sustainedSamples; self.enabled = enabled
    }

    public var thresholdText: String {
        metric.isFraction ? "\(comparison.symbol) \(Int(threshold * 100))%"
                          : "\(comparison.symbol) \(String(format: "%.1f", threshold))"
    }

    public static let defaults: [ServerAlertRule] = [
        ServerAlertRule(metric: .cpu, comparison: .above, threshold: 0.90, sustainedSamples: 3),
        ServerAlertRule(metric: .memory, comparison: .above, threshold: 0.90, sustainedSamples: 3),
        ServerAlertRule(metric: .disk, comparison: .above, threshold: 0.92, sustainedSamples: 1),
        ServerAlertRule(metric: .load1, comparison: .above, threshold: 8, sustainedSamples: 3, enabled: false)
    ]
}

/// 告警配置持久化（UserDefaults）。
public final class ServerAlertRuleStore: @unchecked Sendable {
    private let defaults: UserDefaults
    private let rulesKey = "xico.server.alertRules.v1"
    private let hostDownKey = "xico.server.alertHostDown.v1"
    private let hostDownSet = "xico.server.alertHostDownConfigured.v1"

    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    public func load() -> [ServerAlertRule] {
        guard let data = defaults.data(forKey: rulesKey),
              let rules = try? JSONDecoder().decode([ServerAlertRule].self, from: data), !rules.isEmpty else {
            return ServerAlertRule.defaults
        }
        return rules
    }

    public func save(_ rules: [ServerAlertRule]) {
        if let data = try? JSONEncoder().encode(rules) { defaults.set(data, forKey: rulesKey) }
    }

    public var hostDownEnabled: Bool {
        get { defaults.bool(forKey: hostDownSet) ? defaults.bool(forKey: hostDownKey) : true }
        set { defaults.set(true, forKey: hostDownSet); defaults.set(newValue, forKey: hostDownKey) }
    }
}

/// 告警评估器：持有每个 (主机, 规则) 的连续超阈计数与「正在告警」集合，保证一次越界只推一次、
/// 恢复后可再次触发。纯逻辑，可单测。触发经注入的 `emit` 回调（默认接 Notifier）。
public final class ServerAlertEvaluator: @unchecked Sendable {
    private let lock = NSLock()
    private var breachCount: [String: Int] = [:]
    private var firing: Set<String> = []

    public var rules: [ServerAlertRule]
    public var hostDownEnabled: Bool

    public init(rules: [ServerAlertRule], hostDownEnabled: Bool) {
        self.rules = rules
        self.hostDownEnabled = hostDownEnabled
    }

    private func key(_ hostID: UUID, _ ruleID: String) -> String { "\(hostID.uuidString)#\(ruleID)" }

    public struct Firing: Sendable { public let title: String; public let body: String; public let identifier: String }

    /// 评估一帧，返回需要发出的通知（可能多条）。UI 层负责实际推送（Notifier）。
    public func evaluate(hostID: UUID, hostName: String, snapshot: RemoteSnapshot) -> [Firing] {
        lock.lock(); defer { lock.unlock() }
        var out: [Firing] = []
        for rule in rules where rule.enabled {
            let k = key(hostID, rule.id)
            let v = rule.metric.value(from: snapshot)
            if rule.comparison.breached(v, rule.threshold) {
                let c = (breachCount[k] ?? 0) + 1
                breachCount[k] = c
                if c >= max(1, rule.sustainedSamples) && !firing.contains(k) {
                    firing.insert(k)
                    let valueText = rule.metric.isFraction ? "\(Int(v * 100))%" : String(format: "%.2f", v)
                    out.append(Firing(
                        title: "\(hostName) · \(rule.metric.title)告警",
                        body: "\(rule.metric.title) \(valueText)（阈值 \(rule.thresholdText)）",
                        identifier: "xico.server.alert.\(k)"))
                }
            } else {
                breachCount[k] = 0
                firing.remove(k)
            }
        }
        return out
    }

    /// 主机掉线：从「在线」跌到「失败」时触发一次。
    public func hostDown(hostID: UUID, hostName: String, reason: String) -> Firing? {
        guard hostDownEnabled else { return nil }
        let k = "down#\(hostID.uuidString)"
        lock.lock(); defer { lock.unlock() }
        guard !firing.contains(k) else { return nil }
        firing.insert(k)
        return Firing(title: "\(hostName) · 主机掉线", body: reason, identifier: "xico.server.down.\(hostID.uuidString)")
    }

    public func clearHostDown(hostID: UUID) {
        lock.lock(); defer { lock.unlock() }
        firing.remove("down#\(hostID.uuidString)")
    }
}
