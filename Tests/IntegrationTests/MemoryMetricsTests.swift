import XCTest
@testable import Infrastructure

final class MemoryMetricsTests: XCTestCase {
    func testCPUAndMemoryScopesRequestOnlyTheirOwnDetailMetrics() {
        XCTAssertTrue(LiveMetricsSamplingScope.cpuDetail.needsPerCore)
        XCTAssertTrue(LiveMetricsSamplingScope.cpuDetail.needsLoad)
        XCTAssertFalse(LiveMetricsSamplingScope.cpuDetail.needsSwap)
        XCTAssertTrue(LiveMetricsSamplingScope.cpuDetail.needsTemperature)
        XCTAssertFalse(LiveMetricsSamplingScope.cpuDetail.needsExtendedHardware)

        XCTAssertFalse(LiveMetricsSamplingScope.memoryDetail.needsPerCore)
        XCTAssertFalse(LiveMetricsSamplingScope.memoryDetail.needsLoad)
        XCTAssertTrue(LiveMetricsSamplingScope.memoryDetail.needsSwap)
        XCTAssertFalse(LiveMetricsSamplingScope.memoryDetail.needsTemperature)
        XCTAssertFalse(LiveMetricsSamplingScope.memoryDetail.needsExtendedHardware)

        XCTAssertTrue(LiveMetricsSamplingScope.extendedHardware.needsPerCore)
        XCTAssertTrue(LiveMetricsSamplingScope.extendedHardware.needsLoad)
        XCTAssertTrue(LiveMetricsSamplingScope.extendedHardware.needsSwap)
        XCTAssertTrue(LiveMetricsSamplingScope.extendedHardware.needsTemperature)
        XCTAssertTrue(LiveMetricsSamplingScope.extendedHardware.needsExtendedHardware)
    }

    func testCPUFrequencyCacheReadsImmediatelyHitsBeforeSixtySecondsAndRefreshesAfterExpiry() {
        XCTAssertEqual(CPUFrequencySamplingPolicy.timeToLive, 60)
        let cache = CPUFrequencyCache(timeToLive: 60)
        let started = Date(timeIntervalSince1970: 1_000)
        var loads = 0

        let first = cache.value(now: started) {
            loads += 1
            return (performance: 3_200, efficiency: 2_000)
        }
        let cached = cache.value(now: started.addingTimeInterval(59.9)) {
            loads += 1
            return (performance: 1, efficiency: 1)
        }
        let refreshed = cache.value(now: started.addingTimeInterval(60.1)) {
            loads += 1
            return (performance: 3_100, efficiency: 1_900)
        }

        XCTAssertEqual(first?.performance, 3_200)
        XCTAssertEqual(cached?.performance, 3_200)
        XCTAssertEqual(refreshed?.performance, 3_100)
        XCTAssertEqual(loads, 2)
    }

    func testTemperatureCacheReadsImmediatelyHitsBeforeSixtySecondsAndRefreshesAfterExpiry() {
        let cache = TemperatureReadingCache(timeToLive: 60)
        let started = Date(timeIntervalSince1970: 2_000)
        var loads = 0
        func load(_ celsius: Double) -> [TempReading] {
            loads += 1
            return [TempReading(id: "cpu", name: "CPU", celsius: celsius, category: .cpu)]
        }

        let first = cache.value(now: started) { load(50) }
        let cached = cache.value(now: started.addingTimeInterval(59.9)) { load(99) }
        let refreshed = cache.value(now: started.addingTimeInterval(60.1)) { load(55) }

        XCTAssertEqual(first.first?.celsius, 50)
        XCTAssertEqual(cached.first?.celsius, 50)
        XCTAssertEqual(refreshed.first?.celsius, 55)
        XCTAssertEqual(loads, 2)
    }

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

    func testBreakdownSaturatesAtInt64MaxWithoutOverflowing() {
        let pages = MemoryPageCounts(
            internalPages: .max,
            purgeablePages: .max,
            externalPages: .max,
            wiredPages: .max,
            compressorPages: .max
        )

        let value = MemoryBreakdown.calculate(
            totalBytes: .max,
            pageSize: .max,
            pages: pages
        )

        XCTAssertEqual(value.applicationBytes, 0)
        XCTAssertEqual(value.wiredBytes, .max)
        XCTAssertEqual(value.compressedBytes, .max)
        XCTAssertEqual(value.cachedBytes, .max)
        XCTAssertEqual(value.usedBytes, .max)
        XCTAssertEqual(value.availableBytes, 0)
    }

    func testBreakdownTreatsNegativeCountsAndPageSizeAsZero() {
        let pages = MemoryPageCounts(
            internalPages: .min,
            purgeablePages: -1,
            externalPages: -2,
            wiredPages: -3,
            compressorPages: -4
        )

        let value = MemoryBreakdown.calculate(
            totalBytes: 1_000,
            pageSize: .min,
            pages: pages
        )

        XCTAssertEqual(value.applicationBytes, 0)
        XCTAssertEqual(value.wiredBytes, 0)
        XCTAssertEqual(value.compressedBytes, 0)
        XCTAssertEqual(value.cachedBytes, 0)
        XCTAssertEqual(value.usedBytes, 0)
        XCTAssertEqual(value.availableBytes, 1_000)
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

    func testPressureIndexRequiresMemoryAndSwapFromTheSameCompleteSample() {
        let skippedSwapIsComplete = LiveMetricsSampler.hasCompleteSwapSample(
            wasRequested: false,
            sampleIsValid: false
        )
        let failedSwapIsComplete = LiveMetricsSampler.hasCompleteSwapSample(
            wasRequested: true,
            sampleIsValid: false
        )
        let successfulSwapIsComplete = LiveMetricsSampler.hasCompleteSwapSample(
            wasRequested: true,
            sampleIsValid: true
        )
        let withoutSwap = LiveMetricsSampler.pressureIndexForSample(
            memoryIsValid: true,
            memoryTotal: 1_000,
            memoryAvailable: 300,
            memoryCompressed: 100,
            swapWasSampled: skippedSwapIsComplete,
            swapUsed: 0,
            swapTotal: 0,
            kernelAvailableLevel: 35,
            pressureState: 1
        )
        let withFailedSwap = LiveMetricsSampler.pressureIndexForSample(
            memoryIsValid: true,
            memoryTotal: 1_000,
            memoryAvailable: 300,
            memoryCompressed: 100,
            swapWasSampled: failedSwapIsComplete,
            swapUsed: 0,
            swapTotal: 0,
            kernelAvailableLevel: 35,
            pressureState: 1
        )
        let withSwap = LiveMetricsSampler.pressureIndexForSample(
            memoryIsValid: true,
            memoryTotal: 1_000,
            memoryAvailable: 300,
            memoryCompressed: 100,
            swapWasSampled: successfulSwapIsComplete,
            swapUsed: 0,
            swapTotal: 0,
            kernelAvailableLevel: 35,
            pressureState: 1
        )

        XCTAssertNil(withoutSwap)
        XCTAssertNil(withFailedSwap)
        XCTAssertNotNil(withSwap)
    }
}
