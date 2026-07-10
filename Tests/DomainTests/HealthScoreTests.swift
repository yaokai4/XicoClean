import XCTest
@testable import Domain

/// 可解释健康分（P6·1）：纯打分函数逐项验证 + 缺数据降权归一。
final class HealthScoreTests: XCTestCase {

    func testDiskScoreBands() {
        XCTAssertEqual(HealthScore.diskScore(freeFraction: 0.30), 100)
        XCTAssertEqual(HealthScore.diskScore(freeFraction: 0.25), 100)
        XCTAssertEqual(HealthScore.diskScore(freeFraction: 0.15), 60)   // 5%–25% 线性 20→100
        XCTAssertEqual(HealthScore.diskScore(freeFraction: 0.05), 20)
        XCTAssertEqual(HealthScore.diskScore(freeFraction: 0.025), 10)
        XCTAssertEqual(HealthScore.diskScore(freeFraction: 0), 0)
    }

    func testMemoryScoreBands() {
        XCTAssertEqual(HealthScore.memoryScore(usedFraction: 0.5), 100)
        XCTAssertEqual(HealthScore.memoryScore(usedFraction: 0.60), 100)
        XCTAssertEqual(HealthScore.memoryScore(usedFraction: 0.775), 65)   // 中点
        XCTAssertEqual(HealthScore.memoryScore(usedFraction: 0.98), 20)
    }

    func testTempScoreBands() {
        XCTAssertEqual(HealthScore.tempScore(celsius: 40), 100)
        XCTAssertEqual(HealthScore.tempScore(celsius: 55), 100)
        XCTAssertEqual(HealthScore.tempScore(celsius: 72.5), 65)
        XCTAssertEqual(HealthScore.tempScore(celsius: 100), 10)
        XCTAssertEqual(HealthScore.tempScore(celsius: 120), 10)
    }

    func testThermalAndSmart() {
        XCTAssertEqual(HealthScore.thermalScore(level: 0), 100)
        XCTAssertEqual(HealthScore.thermalScore(level: 1), 70)
        XCTAssertEqual(HealthScore.thermalScore(level: 2), 40)
        XCTAssertEqual(HealthScore.thermalScore(level: 3), 10)
        XCTAssertEqual(HealthScore.smartScore(allHealthy: true), 100)
        XCTAssertEqual(HealthScore.smartScore(allHealthy: false), 10)
    }

    func testComputeFullWeights() {
        let s = HealthScore.compute(diskFreeFraction: 0.30, diskFreeText: "x",
                                    memoryUsedFraction: 0.5, memoryText: "x",
                                    cpuTempCelsius: 40, thermalLevel: 0, thermalText: "x",
                                    smartAllHealthy: true, smartText: "x")
        XCTAssertEqual(s.total, 100)
        XCTAssertEqual(s.components.count, 5)
        XCTAssertTrue(s.components.allSatisfy { $0.score == 100 })
    }

    func testComputeRedistributesMissingWeights() {
        // 温度/SMART 缺数据：总分 = 磁盘/内存/热压力 的加权归一，不被缺项拖为 0。
        let s = HealthScore.compute(diskFreeFraction: 0.30, diskFreeText: "x",
                                    memoryUsedFraction: 0.5, memoryText: "x",
                                    cpuTempCelsius: nil, thermalLevel: 0, thermalText: "x",
                                    smartAllHealthy: nil, smartText: "x")
        XCTAssertEqual(s.total, 100)
        XCTAssertNil(s.components.first { $0.id == "temp" }?.score)
        XCTAssertNil(s.components.first { $0.id == "smart" }?.score)
    }

    func testComputeAllMissing() {
        let s = HealthScore.compute(diskFreeFraction: nil, diskFreeText: "-",
                                    memoryUsedFraction: nil, memoryText: "-",
                                    cpuTempCelsius: nil, thermalLevel: nil, thermalText: "-",
                                    smartAllHealthy: nil, smartText: "-")
        XCTAssertEqual(s.total, 0)
    }

    func testWeightedMix() {
        // 磁盘 20 分（低）+ 内存 100 + 热压力 100，权重 25/20/20 → (20*25+100*20+100*20)/65 ≈ 69
        let s = HealthScore.compute(diskFreeFraction: 0.05, diskFreeText: "x",
                                    memoryUsedFraction: 0.5, memoryText: "x",
                                    cpuTempCelsius: nil, thermalLevel: 0, thermalText: "x",
                                    smartAllHealthy: nil, smartText: "x")
        XCTAssertEqual(s.total, 69)
    }
}
