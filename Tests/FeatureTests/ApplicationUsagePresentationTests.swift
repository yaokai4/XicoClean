import XCTest
import AppKit
@testable import Features
@testable import Infrastructure
import Domain

final class ApplicationUsagePresentationTests: XCTestCase {
    func testCPUColumnOrderIsApplicationCPUMemory() {
        XCTAssertEqual(ApplicationUsageFocus.cpu.columnTitles, ["应用", "CPU", "内存"])
    }

    func testMemoryColumnOrderIsApplicationMemoryCPU() {
        XCTAssertEqual(ApplicationUsageFocus.memory.columnTitles, ["应用", "内存", "CPU"])
    }

    func testPartialCoverageCopyIncludesPercentage() {
        XCTAssertEqual(
            ProcessCoverage(enumerated: 100, sampled: 82, denied: 18, exited: 0).displayText,
            "数据覆盖 82%")
    }

    func testCPURowShowsCPUPrimaryAndMemorySecondary() {
        let row = ApplicationUsageRowPresentation.make(
            usage: .fixture(cpuRaw: 80, cpuNormalized: 10, memory: 1_073_741_824),
            focus: .cpu,
            cpuMode: .normalized,
            memoryStyle: .binary)

        XCTAssertEqual(row.primaryText, "10.0%")
        XCTAssertEqual(row.secondaryText, "1.00 GiB")
        XCTAssertEqual(row.fillFraction, 0.1, accuracy: 0.000_001)
    }

    func testMemoryRowShowsMemoryPrimaryAndCPUSecondary() {
        let row = ApplicationUsageRowPresentation.make(
            usage: .fixture(cpuRaw: 80, cpuNormalized: 10, memory: 1_073_741_824),
            focus: .memory,
            cpuMode: .normalized,
            memoryStyle: .binary,
            largestMemory: 2_147_483_648)

        XCTAssertEqual(row.primaryText, "1.00 GiB")
        XCTAssertEqual(row.secondaryText, "10.0%")
        XCTAssertEqual(row.fillFraction, 0.5, accuracy: 0.000_001)
    }

    func testUnknownCPUIsSamplingNotZero() {
        let row = ApplicationUsageRowPresentation.make(
            usage: .fixture(cpuRaw: nil, cpuNormalized: nil, memory: 1_000_000),
            focus: .memory,
            cpuMode: .normalized,
            memoryStyle: .decimal)

        XCTAssertEqual(row.secondaryText, "采样中")
    }

    func testTotalCoreModeUsesRawCPUAndCoreScaledFill() {
        let coreCount = Double(ProcessInfo.processInfo.activeProcessorCount)
        let row = ApplicationUsageRowPresentation.make(
            usage: .fixture(
                cpuRaw: coreCount * 50,
                cpuNormalized: 50,
                memory: 1_000_000),
            focus: .cpu,
            cpuMode: .totalCore,
            memoryStyle: .decimal)

        XCTAssertEqual(row.primaryText, String(format: "%.1f%%", coreCount * 50))
        XCTAssertEqual(row.fillFraction, 0.5, accuracy: 0.000_001)
    }

    func testFillFractionIsClampedToUnitRange() {
        let overflowing = ApplicationUsageRowPresentation.make(
            usage: .fixture(cpuRaw: 1_000_000, cpuNormalized: 150, memory: 10),
            focus: .cpu,
            cpuMode: .normalized,
            memoryStyle: .decimal)
        let negative = ApplicationUsageRowPresentation.make(
            usage: .fixture(cpuRaw: -10, cpuNormalized: -10, memory: -10),
            focus: .memory,
            cpuMode: .normalized,
            memoryStyle: .decimal,
            largestMemory: 100)

        XCTAssertEqual(overflowing.fillFraction, 1)
        XCTAssertEqual(negative.fillFraction, 0)
    }

    func testExplicitMemoryStylesUseDistinctUnitsAndBases() {
        XCTAssertEqual(Int64(1_000_000_000).formattedMemory(style: .decimal), "1.00 GB")
        XCTAssertEqual(Int64(500_000_000).formattedMemory(style: .decimal), "500.00 MB")
        XCTAssertEqual(Int64(1_073_741_824).formattedMemory(style: .binary), "1.00 GiB")
        XCTAssertEqual(Int64(524_288_000).formattedMemory(style: .binary), "500.00 MiB")
        XCTAssertEqual(Int64(0).formattedMemory(style: .binary), "0 B")
    }

    func testWarmingCPUListFallsBackToMemoryRankingWithoutFabricatingCPU() {
        let usage = ApplicationUsage.fixture(cpuRaw: nil, cpuNormalized: nil, memory: 900_000_000)
        let snapshot = ApplicationUsageSnapshot(
            byCPU: [],
            byMemory: [usage],
            status: .warmingUp,
            coverage: .init(enumerated: 1, sampled: 1, denied: 0, exited: 0),
            sampledAt: Date(),
            source: .local)

        let visible = ApplicationUsageListPresentation.usages(focus: .cpu, snapshot: snapshot)
        XCTAssertEqual(visible.map(\.id), [usage.id])
        let row = ApplicationUsageRowPresentation.make(
            usage: try! XCTUnwrap(visible.first),
            focus: .cpu,
            cpuMode: .normalized,
            memoryStyle: .decimal)
        XCTAssertEqual(row.primaryText, "采样中")
        XCTAssertEqual(row.secondaryText, "900.00 MB")
    }

    func testMemoryHistoryRejectsIncompleteFrameAndRecordsZeroSwapAtomically() {
        var history = MemoryPanelHistoryAccumulator()
        history.record(
            pressureIndex: nil,
            totalBytes: 16_000,
            compressedBytes: 4_000,
            swapUsedBytes: 8_000,
            swapTotalBytes: 10_000)
        XCTAssertTrue(history.pressure.isEmpty)
        XCTAssertTrue(history.compression.isEmpty)
        XCTAssertTrue(history.swap.isEmpty)

        history.record(
            pressureIndex: 0.4,
            totalBytes: 16_000,
            compressedBytes: 4_000,
            swapUsedBytes: 0,
            swapTotalBytes: 0)
        XCTAssertEqual(history.pressure, [0.4])
        XCTAssertEqual(history.compression, [0.25])
        XCTAssertEqual(history.swap, [0])
    }

    func testMemoryHistoryCapsAllSeriesAtSixtyPoints() {
        var history = MemoryPanelHistoryAccumulator()
        for index in 0..<65 {
            history.record(
                pressureIndex: Double(index) / 100,
                totalBytes: 100,
                compressedBytes: Int64(index),
                swapUsedBytes: Int64(index),
                swapTotalBytes: 100)
        }

        XCTAssertEqual(history.pressure.count, 60)
        XCTAssertEqual(history.compression.count, 60)
        XCTAssertEqual(history.swap.count, 60)
        XCTAssertEqual(history.pressure.first, 0.05)
        XCTAssertEqual(history.pressure.last, 0.64)
    }

    @MainActor
    func testApplicationIconCacheLoadsEachPathOnlyOnce() {
        let cache = ApplicationIconCache()
        let expected = NSImage(size: NSSize(width: 18, height: 18))
        var loads = 0
        let loader: (String) -> NSImage? = { _ in loads += 1; return expected }

        let first = cache.image(for: "/Applications/Fixture.app", loader: loader)
        let second = cache.image(for: "/Applications/Fixture.app", loader: loader)

        XCTAssertTrue(first === expected)
        XCTAssertTrue(second === expected)
        XCTAssertEqual(loads, 1)
    }

    func testExitRequiresBundleAbsenceAndEveryMemberPIDToBeGone() {
        let usage = ApplicationUsage.fixture(
            cpuRaw: 10,
            cpuNormalized: 2,
            memory: 100,
            pids: [7, 8])
        let helperStillAlive = ApplicationInspectorLifecycleResolver(
            isBundleRunning: { _ in false },
            processExists: { $0 == 8 })
        let backgroundBundleStillRunning = ApplicationInspectorLifecycleResolver(
            isBundleRunning: { _ in true },
            processExists: { _ in false })
        let fullyExited = ApplicationInspectorLifecycleResolver(
            isBundleRunning: { _ in false },
            processExists: { _ in false })

        XCTAssertEqual(helperStillAlive.state(live: nil, last: usage), .stale)
        XCTAssertEqual(backgroundBundleStillRunning.state(live: nil, last: usage), .stale)
        XCTAssertEqual(fullyExited.state(live: nil, last: usage), .exited)
        XCTAssertEqual(fullyExited.state(live: usage, last: usage), .live)
    }

    func testTwentyRowListUsesBoundedScrollableViewport() {
        XCTAssertEqual(ApplicationUsageListPresentation.rowLimit(configuredLimit: 20), 20)
        let four = ApplicationUsageListPresentation.viewportHeight(
            rowCount: 4, configuredLimit: 4, density: .balanced)
        let twenty = ApplicationUsageListPresentation.viewportHeight(
            rowCount: 20, configuredLimit: 20, density: .balanced)
        XCTAssertGreaterThan(twenty, four)
        XCTAssertLessThan(twenty, 20 * 42)
    }

    func testMissingPressureIndexProducesNeutralEmptyGauge() {
        let missing = XicoPressureGaugePresentation(index: nil)
        let valid = XicoPressureGaugePresentation(index: 0.72)
        XCTAssertFalse(missing.hasValue)
        XCTAssertEqual(missing.fraction, 0)
        XCTAssertTrue(valid.hasValue)
        XCTAssertEqual(valid.fraction, 0.72)
    }
}

@MainActor
final class MonitoringWindowRelationshipTests: XCTestCase {
    func testAttachedSheetCountsAsInsideAndSuppressesParentDismissal() {
        _ = NSApplication.shared
        let card = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 300),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false)
        let sheet = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 200),
            styleMask: [.titled],
            backing: .buffered,
            defer: false)
        card.beginSheet(sheet)

        XCTAssertTrue(card.attachedSheet === sheet)
        XCTAssertTrue(sheet.sheetParent === card)
        XCTAssertTrue(MonitoringCardWindowRelationship.isInside(eventWindow: sheet, card: card))
        XCTAssertFalse(MonitoringCardWindowRelationship.shouldDismissWhenResigning(card: card))
        XCTAssertFalse(MonitoringCardWindowRelationship.shouldCloseForEscape(card: card))
        let unrelated = NSWindow()
        XCTAssertFalse(MonitoringCardWindowRelationship.isInside(eventWindow: unrelated, card: card))

        card.endSheet(sheet)
        XCTAssertTrue(MonitoringCardWindowRelationship.shouldDismissWhenResigning(card: card))
        XCTAssertTrue(MonitoringCardWindowRelationship.shouldCloseForEscape(card: card))
    }

    func testCardGeometryClampsHeightAndOriginToVisibleFrame() {
        let visible = CGRect(x: 100, y: 50, width: 800, height: 600)
        let anchor = CGRect(x: 820, y: 620, width: 24, height: 24)
        let frame = MonitoringCardGeometry.frame(
            fittingSize: CGSize(width: 900, height: 1_200),
            anchorFrame: anchor,
            visibleFrame: visible)

        XCTAssertLessThanOrEqual(frame.height, visible.height - 16)
        XCTAssertLessThanOrEqual(frame.width, visible.width - 16)
        XCTAssertGreaterThanOrEqual(frame.minY, visible.minY + 8)
        XCTAssertLessThanOrEqual(frame.maxY, visible.maxY - 8)
        XCTAssertGreaterThanOrEqual(frame.minX, visible.minX + 8)
        XCTAssertLessThanOrEqual(frame.maxX, visible.maxX - 8)
    }
}

private extension ApplicationUsage {
    static func fixture(
        cpuRaw: Double?,
        cpuNormalized: Double?,
        memory: Int64,
        pids: [Int32] = [7]
    ) -> Self {
        return ApplicationUsage(
            id: ApplicationIdentity(rawValue: "bundle:com.example.fixture"),
            displayName: "Fixture",
            bundleIdentifier: "com.example.fixture",
            bundlePath: "/Applications/Fixture.app",
            representativePID: pids.first ?? 7,
            members: pids.map { pid in
                ApplicationMemberUsage(
                    identity: ProcessIdentity(pid: pid, startTimeNanoseconds: 1),
                    name: pid == pids.first ? "Fixture" : "Fixture Helper",
                    cpuRawPercent: cpuRaw,
                    physicalFootprintBytes: memory)
            },
            cpuRawPercent: cpuRaw,
            cpuNormalizedPercent: cpuNormalized,
            physicalFootprintBytes: memory,
            peakFootprintBytes: memory,
            trend: ApplicationUsageTrend(cpuRaw: [], memoryBytes: []))
    }
}
