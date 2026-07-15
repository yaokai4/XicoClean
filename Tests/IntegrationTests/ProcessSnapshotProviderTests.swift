import XCTest
@testable import Infrastructure
@testable import Shared

final class ProcessSnapshotProviderTests: XCTestCase {
    private final class FakeListing: PIDListing, @unchecked Sendable {
        let estimate: Int
        let values: [Int32]
        init(estimate: Int, values: [Int32]) {
            self.estimate = estimate
            self.values = values
        }
        func estimatedCount() -> Int { estimate }
        func fill(_ buffer: inout [Int32]) -> Int {
            let count = min(buffer.count, values.count)
            for index in 0..<count { buffer[index] = values[index] }
            return values.count > buffer.count ? buffer.count : values.count
        }
    }

    func testPIDReturnValueIsCountNotBytes() {
        let listing = FakeListing(estimate: 8, values: [11, 12, 13, 14, 15, 16, 17, 18])
        XCTAssertEqual(PIDEnumerator(listing: listing, reserve: 0).allPIDs(),
                       [11, 12, 13, 14, 15, 16, 17, 18])
    }

    func testPIDEnumeratorGrowsWhenBufferFills() {
        let expected = (1...100).map(Int32.init)
        let listing = FakeListing(estimate: 1, values: expected)
        XCTAssertEqual(PIDEnumerator(listing: listing, reserve: 0).allPIDs(), expected)
    }

    func testIdentityIncludesStartTime() {
        XCTAssertNotEqual(ProcessIdentity(pid: 42, startTimeNanoseconds: 1),
                          ProcessIdentity(pid: 42, startTimeNanoseconds: 2))
    }

    func testBatchReaderIncludesCurrentProcessWithStableIdentity() throws {
        let pid = getpid()
        let batch = DarwinProcessResourceReader.readBatch(pids: [pid])
        let batched = try XCTUnwrap(batch.records.first)
        let single = try DarwinProcessResourceReader.read(pid: pid).get()

        XCTAssertTrue(batch.failures.isEmpty)
        XCTAssertEqual(batched.pid, pid)
        XCTAssertEqual(batched.startTimeNanoseconds, single.startTimeNanoseconds)
        XCTAssertEqual(batched.name, single.name)
        XCTAssertEqual(batched.executablePath, single.executablePath)
    }

    func testMachAbsoluteCPUTimeUsesInjectedIntegerTimebase() {
        XCTAssertEqual(
            ProcessCPUTimeConverter.nanoseconds(
                fromMachAbsoluteTime: 24_000_000,
                numerator: 125,
                denominator: 3
            ),
            1_000_000_000
        )
        XCTAssertEqual(
            ProcessCPUTimeConverter.nanoseconds(
                fromMachAbsoluteTime: UInt64.max,
                numerator: 125,
                denominator: 3
            ),
            UInt64.max
        )
    }

    func testRusageStartTimeUsesTimebaseAndZeroFallsBackToBSDStart() {
        XCTAssertEqual(
            ProcessStartTimeConverter.nanoseconds(
                rusageAbsoluteTime: 24_000_000,
                numerator: 125,
                denominator: 3,
                bsdSeconds: 999,
                bsdMicroseconds: 999
            ),
            1_000_000_000
        )
        XCTAssertEqual(
            ProcessStartTimeConverter.nanoseconds(
                rusageAbsoluteTime: 0,
                numerator: 125,
                denominator: 3,
                bsdSeconds: 12,
                bsdMicroseconds: 345_678
            ),
            12_345_678_000
        )
    }

    func testProcessMetadataCacheReusesStableIdentityButNotReusedPID() {
        let cache = ProcessResourceMetadataCache()
        let firstExecutable = ProcessExecutableUUID(high: 1, low: 2)
        let replacedExecutable = ProcessExecutableUUID(high: 3, low: 4)
        var loads = 0
        let first = cache.metadata(
            pid: 42,
            startTimeNanoseconds: 100,
            executableUUID: firstExecutable
        ) {
            loads += 1
            return ProcessResourceMetadata(parentPID: 1, name: "first", executablePath: "/first")
        }
        let cached = cache.metadata(
            pid: 42,
            startTimeNanoseconds: 100,
            executableUUID: firstExecutable
        ) {
            loads += 1
            return ProcessResourceMetadata(parentPID: 99, name: "wrong", executablePath: "/wrong")
        }
        let afterExec = cache.metadata(
            pid: 42,
            startTimeNanoseconds: 100,
            executableUUID: replacedExecutable
        ) {
            loads += 1
            return ProcessResourceMetadata(parentPID: 1, name: "exec", executablePath: "/exec")
        }
        let reusedPID = cache.metadata(
            pid: 42,
            startTimeNanoseconds: 200,
            executableUUID: replacedExecutable
        ) {
            loads += 1
            return ProcessResourceMetadata(parentPID: 2, name: "second", executablePath: "/second")
        }

        XCTAssertEqual(
            first,
            ProcessResourceMetadata(parentPID: 1, name: "first", executablePath: "/first")
        )
        XCTAssertEqual(cached, first)
        XCTAssertEqual(
            afterExec,
            ProcessResourceMetadata(parentPID: 1, name: "exec", executablePath: "/exec")
        )
        XCTAssertEqual(
            reusedPID,
            ProcessResourceMetadata(parentPID: 2, name: "second", executablePath: "/second")
        )
        XCTAssertEqual(loads, 3)
    }
}
