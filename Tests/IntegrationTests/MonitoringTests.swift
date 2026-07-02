import XCTest
@testable import Infrastructure

// 隔离的临时历史文件，避免读到真机 Application Support 的历史。

/// 监控历史与告警评估的回归测试（覆盖对抗复核修掉的两条 P1）。
final class MonitoringTests: XCTestCase {

    private func point(_ t: Double, cpu: Double = 0.5) -> MetricsHistoryPoint {
        MetricsHistoryPoint(t: t, cpu: cpu, mem: 0.5, gpu: 0.1, netDown: 0, netUp: 0)
    }

    // MARK: MetricsHistoryStore

    func testHistoryDedupesWithinSameMinute() {
        let store = MetricsHistoryStore(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent("xico-test-\(UUID().uuidString).json"))
        let base = Date(timeIntervalSince1970: 1_700_000_000)   // 固定时刻
        store.record(point(base.timeIntervalSince1970, cpu: 0.3), now: base)
        // 同一分钟内再记：应覆盖而非新增
        store.record(point(base.timeIntervalSince1970 + 10, cpu: 0.9), now: base.addingTimeInterval(10))
        let pts = store.points(in: .hour, now: base.addingTimeInterval(20))
        XCTAssertEqual(pts.count, 1, "同一分钟应去重为 1 点")
        XCTAssertEqual(pts.first?.cpu ?? 0, 0.9, accuracy: 0.0001, "应保留该分钟最新值")
    }

    func testHistoryAddsAcrossMinutes() {
        let store = MetricsHistoryStore(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent("xico-test-\(UUID().uuidString).json"))
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        for i in 0..<5 {
            let t = base.addingTimeInterval(Double(i) * 60)
            store.record(point(t.timeIntervalSince1970, cpu: Double(i) / 10), now: t)
        }
        let pts = store.points(in: .day, now: base.addingTimeInterval(300))
        XCTAssertEqual(pts.count, 5, "跨分钟应逐点累加")
    }

    func testHistoryRejectsClockRollback() {
        let store = MetricsHistoryStore(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent("xico-test-\(UUID().uuidString).json"))
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        store.record(point(base.timeIntervalSince1970, cpu: 0.5), now: base)
        store.record(point(base.timeIntervalSince1970 + 120, cpu: 0.6), now: base.addingTimeInterval(120))
        // 时钟回拨：更早的时间点应被丢弃，避免数组失序
        let rolledBack = base.addingTimeInterval(-3600)
        store.record(point(rolledBack.timeIntervalSince1970, cpu: 0.99), now: rolledBack)
        let pts = store.points(in: .week, now: base.addingTimeInterval(200))
        XCTAssertEqual(pts.count, 2, "回拨样本应被丢弃")
        // 保证升序
        for i in 1..<pts.count { XCTAssertLessThanOrEqual(pts[i-1].t, pts[i].t, "必须按时间升序") }
    }

    func testHistoryRangeFilter() {
        let store = MetricsHistoryStore(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent("xico-test-\(UUID().uuidString).json"))
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        // 一点在 30 分钟前，一点在 2 小时前
        store.record(point(now.timeIntervalSince1970 - 7200), now: now.addingTimeInterval(-7200))
        store.record(point(now.timeIntervalSince1970 - 1800), now: now.addingTimeInterval(-1800))
        XCTAssertEqual(store.points(in: .hour, now: now).count, 1, "1 小时范围只含 30 分钟前那点")
        XCTAssertEqual(store.points(in: .day, now: now).count, 2, "24 小时范围含两点")
    }

    // MARK: AlertEvaluator

    /// 计数替身：记录触发次数，避免测试触碰 UNUserNotificationCenter。
    private final class FireCounter {
        var count = 0
        var notify: (String, String, String) -> Void { { _, _, _ in self.count += 1 } }
    }

    func testAlertFiresOnlyAfterDuration() {
        let fc = FireCounter()
        let eval = AlertEvaluator(notify: fc.notify)
        let rule = AlertRule(id: "cpu", metric: .cpu, comparison: .above, threshold: 0.90,
                             durationSeconds: 15, enabled: true)
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        eval.evaluate(rules: [rule], now: t0) { _ in 0.95 }                        // 计时开始
        eval.evaluate(rules: [rule], now: t0.addingTimeInterval(5)) { _ in 0.95 }  // 5s：未到
        XCTAssertEqual(fc.count, 0, "未达持续时长不应触发")
        eval.evaluate(rules: [rule], now: t0.addingTimeInterval(20)) { _ in 0.95 } // 20s：达阈
        XCTAssertEqual(fc.count, 1, "达到持续时长应触发一次")
    }

    func testAlertResetsWhenBelowThreshold() {
        let fc = FireCounter()
        let eval = AlertEvaluator(notify: fc.notify)
        let rule = AlertRule(id: "mem", metric: .memory, comparison: .above, threshold: 0.90,
                             durationSeconds: 10, enabled: true)
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        eval.evaluate(rules: [rule], now: t0) { _ in 0.95 }                        // 超阈
        eval.evaluate(rules: [rule], now: t0.addingTimeInterval(3)) { _ in 0.50 }  // 回落：重置
        eval.evaluate(rules: [rule], now: t0.addingTimeInterval(6)) { _ in 0.95 }  // 再超阈：重新计时
        eval.evaluate(rules: [rule], now: t0.addingTimeInterval(12)) { _ in 0.95 } // 距重新计时仅 6s
        XCTAssertEqual(fc.count, 0, "回落重置计时后不应过早触发")
    }

    func testAlertCooldown() {
        let fc = FireCounter()
        let eval = AlertEvaluator(notify: fc.notify)
        let rule = AlertRule(id: "disk", metric: .disk, comparison: .above, threshold: 0.90,
                             durationSeconds: 0, enabled: true)
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        eval.evaluate(rules: [rule], now: t0) { _ in 0.99 }                         // 立即触发
        eval.evaluate(rules: [rule], now: t0.addingTimeInterval(60)) { _ in 0.99 }  // 1 分钟内：冷却中
        XCTAssertEqual(fc.count, 1, "冷却期内不应重复触发")
        eval.evaluate(rules: [rule], now: t0.addingTimeInterval(400)) { _ in 0.99 } // 超冷却期
        XCTAssertEqual(fc.count, 2, "冷却结束后应可再次触发")
    }

    func testDisabledRuleNeverEvaluatesValue() {
        let eval = AlertEvaluator(notify: { _, _, _ in })
        let rule = AlertRule(id: "off", metric: .cpu, comparison: .above, threshold: 0.1,
                             durationSeconds: 0, enabled: false)
        var asked = false
        eval.evaluate(rules: [rule], now: Date(timeIntervalSince1970: 1_700_000_000)) { _ in
            asked = true; return 0.99
        }
        XCTAssertFalse(asked, "禁用规则不应查询指标值")
    }

    // MARK: AlertRule 展示

    func testAlertThresholdText() {
        XCTAssertEqual(AlertRule(metric: .cpu, comparison: .above, threshold: 0.9).thresholdText, "＞ 90%")
        XCTAssertEqual(AlertRule(metric: .battery, comparison: .below, threshold: 0.2).thresholdText, "＜ 20%")
        XCTAssertEqual(AlertRule(metric: .cpuTemp, comparison: .above, threshold: 95).thresholdText, "＞ 95°C")
    }
}
