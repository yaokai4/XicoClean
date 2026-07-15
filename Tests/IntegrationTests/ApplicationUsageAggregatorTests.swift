import XCTest
@testable import Infrastructure
import Shared

final class ApplicationUsageAggregatorTests: XCTestCase {
    private func record(pid: Int32, parent: Int32 = 1, start: UInt64 = 1,
                        path: String?, cpu: UInt64, memory: Int64) -> ProcessResourceRecord {
        ProcessResourceRecord(pid: pid, parentPID: parent, startTimeNanoseconds: start,
                              name: "p\(pid)", executablePath: path,
                              cpuTimeNanoseconds: cpu, physicalFootprintBytes: memory,
                              peakFootprintBytes: memory)
    }

    func testChromeHelperUsesOutermostApplicationBundle() {
        let path = "/Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Framework.framework/Helpers/Google Chrome Helper.app/Contents/MacOS/Google Chrome Helper"
        XCTAssertEqual(ApplicationOwnershipResolver.outermostApplicationPath(in: path),
                       "/Applications/Google Chrome.app")
    }

    func testBundleMetadataAndParentChainDefineApplicationOwnership() {
        let applicationPath = "/Applications/Demo.app"
        let records = [
            record(pid: 10, path: "\(applicationPath)/Contents/MacOS/Demo",
                   cpu: 2_000_000_000, memory: 400_000_000),
            record(pid: 11, parent: 10, path: "/usr/bin/demo-helper",
                   cpu: 1_000_000_000, memory: 200_000_000)
        ]
        let metadata = ApplicationMetadata(
            bundleIdentifier: "com.example.demo",
            displayName: "Demo Display Name"
        )
        let ownership = ApplicationOwnershipResolver(metadataProvider: DictionaryMetadataProvider(
            metadataByPath: [applicationPath: metadata]
        )).resolve(records)
        let root = ownership[ProcessIdentity(pid: 10, startTimeNanoseconds: 1)]
        let child = ownership[ProcessIdentity(pid: 11, startTimeNanoseconds: 1)]

        XCTAssertEqual(root?.identity.rawValue, "bundle:com.example.demo")
        XCTAssertEqual(root?.displayName, "Demo Display Name")
        XCTAssertEqual(root?.bundlePath, applicationPath)
        XCTAssertEqual(child, root)
    }

    func testApplicationAggregationSumsMembers() {
        let records = [
            record(pid: 10, path: "/Applications/Demo.app/Contents/MacOS/Demo", cpu: 2_000_000_000, memory: 400_000_000),
            record(pid: 11, parent: 10, path: nil, cpu: 1_000_000_000, memory: 200_000_000)
        ]
        let ownership = ApplicationOwnershipResolver().resolve(records)
        let usage = ApplicationUsageAggregator(logicalCPUCount: 8).aggregate(
            records: records, ownership: ownership,
            cpuRawByProcess: [ProcessIdentity(pid: 10, startTimeNanoseconds: 1): 80,
                              ProcessIdentity(pid: 11, startTimeNanoseconds: 1): 40],
            combinesProcesses: true).first!
        XCTAssertEqual(usage.memberCount, 2)
        XCTAssertEqual(usage.physicalFootprintBytes, 600_000_000)
        XCTAssertEqual(usage.cpuRawPercent!, 120, accuracy: 0.001)
        XCTAssertEqual(usage.cpuNormalizedPercent!, 15, accuracy: 0.001)
    }

    func testFirstSampleAndLongGapWarmUpInsteadOfZero() {
        var calculator = ProcessCPUDeltaCalculator(maximumIntervalNanoseconds: 10_000_000_000)
        let first = ProcessCapture.fixture(time: 1_000_000_000, cpu: 1_000_000_000, start: 1)
        let second = ProcessCapture.fixture(time: 2_000_000_000, cpu: 2_000_000_000, start: 1)
        let late = ProcessCapture.fixture(time: 30_000_000_000, cpu: 3_000_000_000, start: 1)
        let afterLate = ProcessCapture.fixture(time: 31_000_000_000, cpu: 4_000_000_000, start: 1)
        XCTAssertNil(calculator.rates(for: first))
        XCTAssertEqual(calculator.rates(for: second)?.values.first ?? -.infinity,
                       100, accuracy: 0.001)
        XCTAssertNil(calculator.rates(for: late))
        XCTAssertEqual(calculator.rates(for: afterLate)?.values.first ?? -.infinity,
                       100, accuracy: 0.001)
    }

    func testReusedPIDDoesNotInheritCPUTime() {
        var calculator = ProcessCPUDeltaCalculator()
        _ = calculator.rates(for: .fixture(time: 1_000_000_000, cpu: 1_000_000_000, start: 1))
        let reused = calculator.rates(for: .fixture(time: 2_000_000_000, cpu: 9_000_000_000, start: 2))
        XCTAssertTrue(reused?.isEmpty == true)
    }

    func testStableRankingKeepsPreviousOrderInsideThreePercentBand() {
        let a = ApplicationUsage.fixture(id: "a", rawCPU: 50, memory: 100)
        let b = ApplicationUsage.fixture(id: "b", rawCPU: 49, memory: 99)
        let ordered = UsageRanker.order([b, a], metric: .cpu, previousOrder: [b.id, a.id])
        XCTAssertEqual(ordered.map(\.id), [b.id, a.id])
    }

    func testCombineProcessesDisabledKeepsMembersSeparate() {
        let records = [
            record(pid: 10, path: "/Applications/Demo.app/Contents/MacOS/Demo",
                   cpu: 2_000_000_000, memory: 400_000_000),
            record(pid: 11, parent: 10, path: nil,
                   cpu: 1_000_000_000, memory: 200_000_000)
        ]
        let ownership = ApplicationOwnershipResolver().resolve(records)
        let usages = ApplicationUsageAggregator(logicalCPUCount: 8).aggregate(
            records: records,
            ownership: ownership,
            cpuRawByProcess: [:],
            combinesProcesses: false
        )

        XCTAssertEqual(usages.count, 2)
        XCTAssertEqual(Set(usages.map(\.memberCount)), [1])
    }

    func testSamplerWarmsUpWithMemoryRowsThenPublishesLiveCPU() async {
        let records = [
            record(pid: 10, path: "/Applications/Demo.app/Contents/MacOS/Demo",
                   cpu: 1_000_000_000, memory: 400_000_000)
        ]
        let nextRecords = [
            record(pid: 10, path: "/Applications/Demo.app/Contents/MacOS/Demo",
                   cpu: 2_000_000_000, memory: 450_000_000)
        ]
        let provider = FixtureProcessSnapshotProvider(captures: [
            .fixture(time: 1_000_000_000, records: records),
            .fixture(time: 2_000_000_000, records: nextRecords)
        ])
        let sampler = ProcessSampler(provider: provider, logicalCPUCount: 8)

        let warming = await sampler.sample()
        XCTAssertEqual(warming.status, .warmingUp)
        XCTAssertTrue(warming.byCPU.isEmpty)
        XCTAssertEqual(warming.byMemory.count, 1)
        XCTAssertNil(warming.byMemory.first?.cpuRawPercent)

        let live = await sampler.sample()
        XCTAssertEqual(live.status, .live)
        XCTAssertEqual(live.byCPU.first?.cpuRawPercent ?? -.infinity,
                       100, accuracy: 0.001)
        XCTAssertEqual(live.byMemory.first?.physicalFootprintBytes, 450_000_000)
    }

    func testSamplerCapsTrendsAtSixtySamples() async {
        var captures: [ProcessCapture] = []
        for index in 0..<62 {
            let time = UInt64(index + 1) * 1_000_000_000
            let sample = record(
                pid: 10,
                path: "/Applications/Demo.app/Contents/MacOS/Demo",
                cpu: time,
                memory: 400_000_000 + Int64(index)
            )
            captures.append(.fixture(time: time, records: [sample]))
        }
        let provider = FixtureProcessSnapshotProvider(captures: captures)
        let sampler = ProcessSampler(provider: provider, logicalCPUCount: 8)

        var latest: ApplicationUsageSnapshot?
        for _ in captures {
            latest = await sampler.sample()
        }

        XCTAssertEqual(latest?.byMemory.first?.trend.cpuRaw.count, 60)
        XCTAssertEqual(latest?.byMemory.first?.trend.memoryBytes.count, 60)
    }

    func testSamplerDropsTrendAfterApplicationIsAbsentForOver120Seconds() async {
        let first = record(pid: 10, path: "/Applications/Demo.app/Contents/MacOS/Demo",
                           cpu: 1_000_000_000, memory: 400_000_000)
        let second = record(pid: 10, path: "/Applications/Demo.app/Contents/MacOS/Demo",
                            cpu: 2_000_000_000, memory: 410_000_000)
        let returned = record(pid: 10, path: "/Applications/Demo.app/Contents/MacOS/Demo",
                              cpu: 3_000_000_000, memory: 420_000_000)
        let provider = FixtureProcessSnapshotProvider(captures: [
            .fixture(time: 1_000_000_000, records: [first]),
            .fixture(time: 2_000_000_000, records: [second]),
            .fixture(time: 123_000_000_000, records: []),
            .fixture(time: 124_000_000_000, records: [returned])
        ])
        let sampler = ProcessSampler(provider: provider, logicalCPUCount: 8)

        _ = await sampler.sample()
        _ = await sampler.sample()
        _ = await sampler.sample()
        let latest = await sampler.sample()

        XCTAssertEqual(latest.byMemory.first?.trend.memoryBytes, [420_000_000])
    }
}

private extension ProcessCapture {
    static func fixture(time: UInt64, cpu: UInt64, start: UInt64) -> Self {
        let record = ProcessResourceRecord(pid: 42, parentPID: 1,
                                           startTimeNanoseconds: start,
                                           name: "fixture", executablePath: "/usr/bin/fixture",
                                           cpuTimeNanoseconds: cpu,
                                           physicalFootprintBytes: 1_000_000,
                                           peakFootprintBytes: 1_000_000)
        return ProcessCapture(records: [record], failures: [:],
                              wallDate: Date(timeIntervalSince1970: Double(time) / 1_000_000_000),
                              monotonicNanoseconds: time, source: .local, enumeratedCount: 1)
    }

    static func fixture(time: UInt64, records: [ProcessResourceRecord]) -> Self {
        ProcessCapture(
            records: records,
            failures: [:],
            wallDate: Date(timeIntervalSince1970: Double(time) / 1_000_000_000),
            monotonicNanoseconds: time,
            source: .local,
            enumeratedCount: records.count
        )
    }
}

private extension ApplicationUsage {
    static func fixture(id: String, rawCPU: Double, memory: Int64) -> Self {
        let process = ProcessIdentity(pid: Int32(id.utf8.first ?? 1), startTimeNanoseconds: 1)
        return ApplicationUsage(
            id: ApplicationIdentity(rawValue: id), displayName: id,
            bundleIdentifier: nil, bundlePath: nil, representativePID: process.pid,
            members: [ApplicationMemberUsage(identity: process, name: id,
                                             cpuRawPercent: rawCPU,
                                             physicalFootprintBytes: memory)],
            cpuRawPercent: rawCPU, cpuNormalizedPercent: rawCPU / 8,
            physicalFootprintBytes: memory, peakFootprintBytes: memory,
            trend: ApplicationUsageTrend(cpuRaw: [], memoryBytes: []))
    }
}

private actor FixtureProcessSnapshotProvider: ProcessSnapshotProviding {
    private let captures: [ProcessCapture]
    private var index = 0

    init(captures: [ProcessCapture]) {
        self.captures = captures
    }

    func capture() async -> ProcessCapture {
        defer { index += 1 }
        return captures[min(index, captures.count - 1)]
    }
}

private struct DictionaryMetadataProvider: ApplicationMetadataProviding {
    let metadataByPath: [String: ApplicationMetadata]

    func metadata(forApplicationAt path: String) -> ApplicationMetadata {
        metadataByPath[path] ?? ApplicationMetadata(bundleIdentifier: nil, displayName: nil)
    }
}
