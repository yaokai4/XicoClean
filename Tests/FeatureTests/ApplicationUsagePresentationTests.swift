import XCTest
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
}

private extension ApplicationUsage {
    static func fixture(cpuRaw: Double?, cpuNormalized: Double?, memory: Int64) -> Self {
        let identity = ProcessIdentity(pid: 7, startTimeNanoseconds: 1)
        return ApplicationUsage(
            id: ApplicationIdentity(rawValue: "bundle:com.example.fixture"),
            displayName: "Fixture",
            bundleIdentifier: "com.example.fixture",
            bundlePath: "/Applications/Fixture.app",
            representativePID: 7,
            members: [
                ApplicationMemberUsage(
                    identity: identity,
                    name: "Fixture",
                    cpuRawPercent: cpuRaw,
                    physicalFootprintBytes: memory)
            ],
            cpuRawPercent: cpuRaw,
            cpuNormalizedPercent: cpuNormalized,
            physicalFootprintBytes: memory,
            peakFootprintBytes: memory,
            trend: ApplicationUsageTrend(cpuRaw: [], memoryBytes: []))
    }
}
