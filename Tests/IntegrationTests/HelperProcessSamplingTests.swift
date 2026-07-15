import XCTest
@testable import Infrastructure
import Shared

final class HelperProcessSamplingTests: XCTestCase {
    func testHelperRecordReplacesPermissionDeniedFailure() async {
        let local = FakeProvider(capture: .fixture(records: [.pid(1)], failures: [2: .permissionDenied]))
        let helper = FakePrivilegedSampler(response: ProcessHelperBatchResponse(
            requestedCount: 1, records: [.pid(2)]))
        let capture = await HybridProcessSnapshotProvider(local: local, helper: helper).capture()
        XCTAssertEqual(Set(capture.records.map(\.pid)), [1, 2])
        XCTAssertNil(capture.failures[2])
        XCTAssertEqual(capture.source, .helperEnhanced)
    }

    func testHelperTimeoutKeepsHonestLocalCoverage() async {
        let local = FakeProvider(capture: .fixture(records: [.pid(1)], failures: [2: .permissionDenied]))
        let helper = FakePrivilegedSampler(response: nil)
        let capture = await HybridProcessSnapshotProvider(local: local, helper: helper).capture()
        XCTAssertEqual(capture.records.map(\.pid), [1])
        XCTAssertEqual(capture.failures[2], .permissionDenied)
        XCTAssertEqual(capture.source, .local)
    }

    func testProductionSamplerPublishesHelperEnhancedSource() async {
        let local = FakeProvider(
            capture: .fixture(records: [.pid(1)], failures: [2: .permissionDenied]))
        let helper = FakePrivilegedSampler(response: ProcessHelperBatchResponse(
            requestedCount: 1, records: [.pid(2)]))
        let sampler = ProcessSampler.production(
            local: local,
            helper: helper,
            logicalCPUCount: 8)

        let snapshot = await sampler.sample()

        XCTAssertEqual(snapshot.source, .helperEnhanced)
        XCTAssertEqual(snapshot.coverage.sampled, 2)
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
