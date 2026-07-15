import XCTest
@testable import Infrastructure

final class MemoryMetricsTests: XCTestCase {
    func testBreakdownKeepsCacheInsideAvailableMemory() {
        let pages = MemoryPageCounts(
            internalPages: 500,
            purgeablePages: 50,
            externalPages: 100,
            wiredPages: 200,
            compressorPages: 100
        )

        let value = MemoryBreakdown.calculate(
            totalBytes: 1_000 * 4096,
            pageSize: 4096,
            pages: pages
        )

        XCTAssertEqual(value.applicationBytes, 450 * 4096)
        XCTAssertEqual(value.wiredBytes, 200 * 4096)
        XCTAssertEqual(value.compressedBytes, 100 * 4096)
        XCTAssertEqual(value.cachedBytes, 150 * 4096)
        XCTAssertEqual(value.usedBytes, 750 * 4096)
        XCTAssertEqual(value.availableBytes, 250 * 4096)
    }

    func testPressureIndexUsesKernelPressureAndStateFloor() {
        XCTAssertEqual(
            MemoryPressureIndex.score(
                kernelAvailableLevel: 35,
                pressureState: 1,
                availableFraction: 0.3,
                compressedFraction: 0.1,
                swapFraction: 0
            ),
            0.65,
            accuracy: 0.001
        )
        XCTAssertGreaterThanOrEqual(
            MemoryPressureIndex.score(
                kernelAvailableLevel: 90,
                pressureState: 4,
                availableFraction: 0.5,
                compressedFraction: 0,
                swapFraction: 0
            ),
            0.85
        )
    }

    func testPressureIndexIsBoundedForOutOfRangeInputs() {
        XCTAssertEqual(
            MemoryPressureIndex.score(
                kernelAvailableLevel: -50,
                pressureState: 1,
                availableFraction: -1,
                compressedFraction: 2,
                swapFraction: 2
            ),
            1
        )
        XCTAssertEqual(
            MemoryPressureIndex.score(
                kernelAvailableLevel: 200,
                pressureState: 1,
                availableFraction: 1,
                compressedFraction: -1,
                swapFraction: -1
            ),
            0
        )
    }

    func testSwapSamplingIsGatedByVisibleOrPressureConsumer() {
        XCTAssertTrue(
            LiveMetricsSampler.shouldSampleSwap(
                consumerVisible: true,
                memoryGlyphEnabled: false,
                memoryMetric: "used"
            )
        )
        XCTAssertTrue(
            LiveMetricsSampler.shouldSampleSwap(
                consumerVisible: false,
                memoryGlyphEnabled: true,
                memoryMetric: nil
            )
        )
        XCTAssertFalse(
            LiveMetricsSampler.shouldSampleSwap(
                consumerVisible: false,
                memoryGlyphEnabled: true,
                memoryMetric: "used"
            )
        )
        XCTAssertFalse(
            LiveMetricsSampler.shouldSampleSwap(
                consumerVisible: false,
                memoryGlyphEnabled: false,
                memoryMetric: nil
            )
        )
    }
}
