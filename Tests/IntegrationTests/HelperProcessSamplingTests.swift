import XCTest
@testable import Infrastructure
import Shared

final class HelperProcessSamplingTests: XCTestCase {
    func testHelperRecordReplacesPermissionDeniedFailure() async {
        let local = FakeProvider(capture: .fixture(records: [.pid(1)], failures: [2: .permissionDenied]))
        let helper = DelayedPrivilegedSampler(
            delayNanoseconds: 20_000_000,
            response: ProcessHelperBatchResponse(requestedCount: 1, records: [.pid(2)]))
        let provider = HybridProcessSnapshotProvider(local: local, helper: helper)

        let initial = await provider.capture()
        try? await Task.sleep(nanoseconds: 50_000_000)
        let capture = await provider.capture()

        XCTAssertEqual(initial.source, .local)
        XCTAssertEqual(Set(capture.records.map(\.pid)), [1, 2])
        XCTAssertNil(capture.failures[2])
        XCTAssertEqual(capture.source, .helperEnhanced)
    }

    func testDelayedHelperNeverBlocksLocalFirstCaptureAndEnhancesNextCapture() async {
        let local = FakeProvider(capture: .fixture(records: [.pid(1)], failures: [2: .permissionDenied]))
        let helper = DelayedPrivilegedSampler(
            delayNanoseconds: 250_000_000,
            response: ProcessHelperBatchResponse(requestedCount: 1, records: [.pid(2)]))
        let provider = HybridProcessSnapshotProvider(local: local, helper: helper)

        let started = DispatchTime.now().uptimeNanoseconds
        let initial = await provider.capture()
        let elapsedMilliseconds = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000

        XCTAssertEqual(initial.source, .local)
        XCTAssertEqual(initial.failures[2], .permissionDenied)
        XCTAssertLessThan(elapsedMilliseconds, 150)

        try? await Task.sleep(nanoseconds: 300_000_000)
        let enhanced = await provider.capture()
        XCTAssertEqual(enhanced.source, .helperEnhanced)
        XCTAssertEqual(Set(enhanced.records.map(\.pid)), [1, 2])
        XCTAssertNil(enhanced.failures[2])
    }

    func testHelperTimeoutKeepsHonestLocalCoverage() async {
        let local = FakeProvider(capture: .fixture(records: [.pid(1)], failures: [2: .permissionDenied]))
        let helper = FakePrivilegedSampler(response: nil)
        let provider = HybridProcessSnapshotProvider(local: local, helper: helper)
        let capture = await provider.capture()
        try? await Task.sleep(nanoseconds: 10_000_000)
        let duringBackoff = await provider.capture()
        XCTAssertEqual(capture.records.map(\.pid), [1])
        XCTAssertEqual(capture.failures[2], .permissionDenied)
        XCTAssertEqual(capture.source, .local)
        XCTAssertEqual(duringBackoff.source, .local)
    }

    func testProductionSamplerPublishesHelperEnhancedSource() async {
        let local = FakeProvider(
            capture: .fixture(records: [.pid(1)], failures: [2: .permissionDenied]))
        let helper = DelayedPrivilegedSampler(
            delayNanoseconds: 20_000_000,
            response: ProcessHelperBatchResponse(requestedCount: 1, records: [.pid(2)]))
        let sampler = ProcessSampler.production(
            local: local,
            helper: helper,
            logicalCPUCount: 8)

        let initial = await sampler.sample()
        try? await Task.sleep(nanoseconds: 50_000_000)
        let snapshot = await sampler.sample()

        XCTAssertEqual(initial.source, .local)
        XCTAssertEqual(snapshot.source, .helperEnhanced)
        XCTAssertEqual(snapshot.coverage.sampled, 2)
    }

    func testUnavailableHelperBacksOffWhilePreservingLocalCoverage() async {
        let local = FakeProvider(
            capture: .fixture(records: [.pid(1)], failures: [2: .permissionDenied])
        )
        let helper = CountingUnavailablePrivilegedSampler()
        let clock = MutableTestDate(Date(timeIntervalSince1970: 1_000))
        let provider = HybridProcessSnapshotProvider(
            local: local,
            helper: helper,
            now: { clock.value },
            helperRetryDelay: 10
        )

        let first = await provider.capture()
        try? await Task.sleep(nanoseconds: 10_000_000)
        let duringBackoff = await provider.capture()
        clock.advance(by: 10.1)
        let afterBackoff = await provider.capture()
        try? await Task.sleep(nanoseconds: 10_000_000)

        XCTAssertEqual(helper.invocationCount, 2)
        XCTAssertEqual(first.source, .local)
        XCTAssertEqual(duringBackoff.failures[2], .permissionDenied)
        XCTAssertEqual(afterBackoff.source, .local)
    }

    func testEmptyHelperResponseUsesTheSameFailureBackoff() async {
        let local = FakeProvider(
            capture: .fixture(records: [.pid(1)], failures: [2: .permissionDenied])
        )
        let helper = CountingUnavailablePrivilegedSampler(
            response: ProcessHelperBatchResponse(requestedCount: 1, records: [])
        )
        let clock = MutableTestDate(Date(timeIntervalSince1970: 1_000))
        let provider = HybridProcessSnapshotProvider(
            local: local,
            helper: helper,
            now: { clock.value },
            helperRetryDelay: 10
        )

        _ = await provider.capture()
        try? await Task.sleep(nanoseconds: 10_000_000)
        _ = await provider.capture()
        XCTAssertEqual(helper.invocationCount, 1)

        clock.advance(by: 10.1)
        _ = await provider.capture()
        try? await Task.sleep(nanoseconds: 10_000_000)
        XCTAssertEqual(helper.invocationCount, 2)
    }

    func testExpiredHelperRecordCannotSurviveLongGapOrPossiblePIDReuse() async {
        let deniedPID: Int32 = 2
        let oldIdentity = ProcessResourceRecord(
            pid: deniedPID,
            parentPID: 1,
            startTimeNanoseconds: 111,
            name: "old-p2",
            executablePath: "/usr/bin/old-p2",
            cpuTimeNanoseconds: 10,
            physicalFootprintBytes: 1_000_000,
            peakFootprintBytes: 1_000_000
        )
        let local = FakeProvider(
            capture: .fixture(records: [.pid(1)], failures: [deniedPID: .permissionDenied])
        )
        let helper = DelayedPrivilegedSampler(
            delayNanoseconds: 0,
            response: ProcessHelperBatchResponse(requestedCount: 1, records: [oldIdentity])
        )
        let clock = MutableTestDate(Date(timeIntervalSince1970: 1_000))
        let provider = HybridProcessSnapshotProvider(
            local: local,
            helper: helper,
            now: { clock.value },
            helperRetryDelay: 60,
            helperResultFreshness: {
                ProcessHelperEnhancementPolicy.resultTimeToLive(refreshInterval: 1)
            }
        )

        _ = await provider.capture()
        try? await Task.sleep(nanoseconds: 10_000_000)
        clock.advance(by: ProcessHelperEnhancementPolicy.resultTimeToLive(refreshInterval: 1) + 0.1)
        let afterLongGap = await provider.capture()

        XCTAssertEqual(afterLongGap.source, .local)
        XCTAssertEqual(afterLongGap.records.map(\.pid), [1])
        XCTAssertEqual(afterLongGap.failures[deniedPID], .permissionDenied)
        XCTAssertFalse(afterLongGap.records.contains { $0.startTimeNanoseconds == 111 })
    }

    func testDefaultHelperFreshnessCoversFiveSecondRefreshInterval() async {
        let local = FakeProvider(
            capture: .fixture(records: [.pid(1)], failures: [2: .permissionDenied])
        )
        let helper = DelayedPrivilegedSampler(
            delayNanoseconds: 0,
            response: ProcessHelperBatchResponse(requestedCount: 1, records: [.pid(2)])
        )
        let clock = MutableTestDate(Date(timeIntervalSince1970: 1_000))
        let configuredRefresh = MutableTestInterval(5)
        let provider = HybridProcessSnapshotProvider(
            local: local,
            helper: helper,
            now: { clock.value },
            helperResultFreshness: {
                ProcessHelperEnhancementPolicy.resultTimeToLive(
                    refreshInterval: configuredRefresh.value
                )
            }
        )

        _ = await provider.capture()
        try? await Task.sleep(nanoseconds: 10_000_000)
        clock.advance(by: MonitoringRefreshInterval.fiveSeconds.rawValue + 0.5)
        let nextConfiguredTick = await provider.capture()

        XCTAssertEqual(nextConfiguredTick.source, .helperEnhanced)
        XCTAssertEqual(Set(nextConfiguredTick.records.map(\.pid)), [1, 2])
        XCTAssertNil(nextConfiguredTick.failures[2])

        try? await Task.sleep(nanoseconds: 10_000_000)
        configuredRefresh.value = 1
        clock.advance(by: 2.1)
        let afterChangingToOneSecond = await provider.capture()
        XCTAssertEqual(afterChangingToOneSecond.source, .local)
        XCTAssertEqual(afterChangingToOneSecond.failures[2], .permissionDenied)
    }
}

private struct FakeProvider: ProcessSnapshotProviding {
    let value: ProcessCapture
    init(capture: ProcessCapture) { value = capture }
    func capture() async -> ProcessCapture { value }
}

private struct FakePrivilegedSampler: PrivilegedProcessSampling {
    let response: ProcessHelperBatchResponse?
    var processSamplingAvailable: Bool { true }
    func sampleProcesses(pids: [Int32]) async -> ProcessHelperBatchResponse? { response }
}

private final class DelayedPrivilegedSampler: PrivilegedProcessSampling, @unchecked Sendable {
    let delayNanoseconds: UInt64
    let response: ProcessHelperBatchResponse?

    init(delayNanoseconds: UInt64, response: ProcessHelperBatchResponse?) {
        self.delayNanoseconds = delayNanoseconds
        self.response = response
    }

    var processSamplingAvailable: Bool { true }

    func sampleProcesses(pids: [Int32]) async -> ProcessHelperBatchResponse? {
        try? await Task.sleep(nanoseconds: delayNanoseconds)
        return response
    }
}

private final class CountingUnavailablePrivilegedSampler: PrivilegedProcessSampling, @unchecked Sendable {
    private let lock = NSLock()
    private let response: ProcessHelperBatchResponse?
    private var count = 0

    init(response: ProcessHelperBatchResponse? = nil) {
        self.response = response
    }

    var processSamplingAvailable: Bool { true }
    var invocationCount: Int { lock.withLock { count } }

    func sampleProcesses(pids: [Int32]) async -> ProcessHelperBatchResponse? {
        lock.withLock { count += 1 }
        return response
    }
}

private final class MutableTestDate: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Date

    init(_ value: Date) { storage = value }
    var value: Date { lock.withLock { storage } }
    func advance(by interval: TimeInterval) {
        lock.withLock { storage = storage.addingTimeInterval(interval) }
    }
}

private final class MutableTestInterval: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: TimeInterval

    init(_ value: TimeInterval) { storage = value }
    var value: TimeInterval {
        get { lock.withLock { storage } }
        set { lock.withLock { storage = newValue } }
    }
}

private extension ProcessResourceRecord {
    static func pid(_ pid: Int32) -> Self {
        ProcessResourceRecord(pid: pid, parentPID: 1,
                              startTimeNanoseconds: UInt64(pid),
                              name: "p\(pid)", executablePath: "/usr/bin/p\(pid)",
                              cpuTimeNanoseconds: 0, physicalFootprintBytes: 1_000_000,
                              peakFootprintBytes: 1_000_000)
    }
}

private extension ProcessCapture {
    static func fixture(records: [ProcessResourceRecord],
                        failures: [Int32: ProcessResourceReadFailure]) -> Self {
        ProcessCapture(records: records, failures: failures,
                       wallDate: Date(timeIntervalSince1970: 1),
                       monotonicNanoseconds: 1_000_000_000,
                       source: .local,
                       enumeratedCount: records.count + failures.count)
    }
}
