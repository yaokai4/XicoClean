import XCTest
@testable import Infrastructure

/// 分层历史环形缓冲（P3·M4）：桶封口、容量上限、进行中桶的实时尾部。
final class HistoryRingsTests: XCTestCase {

    func testBasePushAndCap() {
        var r = HistoryRings()
        for i in 0..<(HistoryRings.baseCap + 30) {
            r.push(Double(i), at: Double(i))
        }
        XCTAssertEqual(r.base.count, HistoryRings.baseCap)
        XCTAssertEqual(r.base.last, Double(HistoryRings.baseCap + 29))
        XCTAssertEqual(r.base.first, Double(30))   // 先进先出
    }

    func testMidBucketSealsOnBoundary() {
        var r = HistoryRings()
        // 10s 桶：t=0..9 全部 0.2，t=10 进新桶 → 上一桶封口，均值 0.2。
        for t in 0..<10 { r.push(0.2, at: Double(t)) }
        XCTAssertTrue(r.mid.isEmpty)               // 桶未封口
        XCTAssertEqual(r.midLive.count, 1)         // 进行中桶实时可见
        XCTAssertEqual(r.midLive[0], 0.2, accuracy: 1e-9)
        r.push(0.8, at: 10)                        // 跨桶 → 封口
        XCTAssertEqual(r.mid.count, 1)
        XCTAssertEqual(r.mid[0], 0.2, accuracy: 1e-9)
        XCTAssertEqual(r.midLive.count, 2)         // 封口桶 + 新进行中桶
        XCTAssertEqual(r.midLive[1], 0.8, accuracy: 1e-9)
    }

    func testLongBucketAverages() {
        var r = HistoryRings()
        // 60s 桶：前 60 秒交替 0/1（均值 0.5），第 61 秒进新桶。
        for t in 0..<60 { r.push(t % 2 == 0 ? 0 : 1, at: Double(t)) }
        r.push(0.3, at: 60)
        XCTAssertEqual(r.long.count, 1)
        XCTAssertEqual(r.long[0], 0.5, accuracy: 1e-9)
    }

    func testMidCap() {
        var r = HistoryRings()
        // 灌满超过 midCap 个 10s 桶。
        let buckets = HistoryRings.midCap + 10
        for b in 0..<buckets {
            r.push(Double(b), at: Double(b * 10))
            r.push(Double(b), at: Double(b * 10 + 5))
        }
        r.push(0, at: Double(buckets * 10))   // 封掉最后一桶
        XCTAssertEqual(r.mid.count, HistoryRings.midCap)
        XCTAssertEqual(r.mid.last ?? -1, Double(buckets - 1), accuracy: 1e-9)
    }

    func testWindowSeries() {
        var r = HistoryRings()
        for t in 0..<25 { r.push(Double(t) / 25, at: Double(t)) }
        XCTAssertEqual(HistoryWindow.live.series(from: r).count, 25)
        XCTAssertEqual(HistoryWindow.mid.series(from: r).count, r.midLive.count)
        XCTAssertEqual(HistoryWindow.long.series(from: r).count, r.longLive.count)
    }

    func testMetricRingsPushAll() {
        var m = MetricRings()
        m.push(cpu: 0.5, memory: 0.6, gpu: 0.2, netDown: 100, netUp: 50, at: 0)
        XCTAssertEqual(m.cpu.base, [0.5])
        XCTAssertEqual(m.memory.base, [0.6])
        XCTAssertEqual(m.gpu.base, [0.2])
        XCTAssertEqual(m.netDown.base, [100])
        XCTAssertEqual(m.netUp.base, [50])
    }
}
