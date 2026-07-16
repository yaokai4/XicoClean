### Task 1: Correct Full-PID Capture and Shared libproc Records

**Files:**
- Create: `Sources/Shared/ProcessResourceRecord.swift`
- Create: `Sources/Infrastructure/ApplicationUsageModels.swift`
- Create: `Sources/Infrastructure/ProcessSnapshotProvider.swift`
- Test: `Tests/IntegrationTests/ProcessSnapshotProviderTests.swift`

**Interfaces:**
- Produces: `ProcessResourceRecord`, `ProcessResourceReadFailure`, `DarwinProcessResourceReader.read(pid:)`, `ProcessIdentity`, `ProcessCapture`, `PIDListing`, `PIDEnumerator`, `ProcessSnapshotProviding`, `LocalProcessSnapshotProvider`.
- Consumes: Darwin `proc_listallpids`, `proc_pidinfo(PROC_PIDTBSDINFO)`, `proc_pid_rusage(RUSAGE_INFO_V4)`, `proc_pidpath`, and `proc_name`.

- [ ] **Step 1: Write failing tests for PID-count semantics, resize, and process identity**

```swift
import XCTest
@testable import Infrastructure
import Shared

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
}
```

- [ ] **Step 2: Run the focused test and confirm the new interfaces do not exist**

Run: `swift test --filter ProcessSnapshotProviderTests`

Expected: FAIL with compiler errors for `PIDListing`, `PIDEnumerator`, and `ProcessIdentity`.

- [ ] **Step 3: Add the shared record and Darwin reader**

Create this public contract in `Sources/Shared/ProcessResourceRecord.swift`:

```swift
import Foundation
import Darwin

public struct ProcessResourceRecord: Codable, Sendable, Hashable {
    public let pid: Int32
    public let parentPID: Int32
    public let startTimeNanoseconds: UInt64
    public let name: String
    public let executablePath: String?
    public let cpuTimeNanoseconds: UInt64
    public let physicalFootprintBytes: Int64
    public let peakFootprintBytes: Int64
    public init(pid: Int32, parentPID: Int32, startTimeNanoseconds: UInt64,
                name: String, executablePath: String?, cpuTimeNanoseconds: UInt64,
                physicalFootprintBytes: Int64, peakFootprintBytes: Int64) {
        self.pid = pid
        self.parentPID = parentPID
        self.startTimeNanoseconds = startTimeNanoseconds
        self.name = name
        self.executablePath = executablePath
        self.cpuTimeNanoseconds = cpuTimeNanoseconds
        self.physicalFootprintBytes = physicalFootprintBytes
        self.peakFootprintBytes = peakFootprintBytes
    }
}

public enum ProcessResourceReadFailure: String, Error, Codable, Sendable {
    case permissionDenied
    case exited
    case unreadable

    static func fromErrno(_ value: Int32) -> Self {
        switch value {
        case EPERM, EACCES: return .permissionDenied
        case ESRCH: return .exited
        default: return .unreadable
        }
    }
}

public struct ProcessHelperBatchResponse: Codable, Sendable {
    public let requestedCount: Int
    public let records: [ProcessResourceRecord]
    public init(requestedCount: Int, records: [ProcessResourceRecord]) {
        self.requestedCount = requestedCount
        self.records = records
    }
}

public enum DarwinProcessResourceReader {
    public static func read(pid: Int32) -> Result<ProcessResourceRecord, ProcessResourceReadFailure> {
        var bsd = proc_bsdinfo()
        let bsdSize = Int32(MemoryLayout<proc_bsdinfo>.stride)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bsd, bsdSize) == bsdSize else {
            return .failure(.fromErrno(errno))
        }

        var usage = rusage_info_v4()
        let usageResult = withUnsafeMutablePointer(to: &usage) { pointer -> Int32 in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V4, $0)
            }
        }
        guard usageResult == 0 else { return .failure(.fromErrno(errno)) }

        var pathBuffer = [CChar](repeating: 0, count: Int(PROC_PIDPATHINFO_MAXSIZE))
        let pathLength = proc_pidpath(pid, &pathBuffer, UInt32(pathBuffer.count))
        let executablePath: String? = pathLength > 0
            ? String(decoding: pathBuffer.prefix(Int(pathLength)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
            : nil

        var nameBuffer = [CChar](repeating: 0, count: 256)
        let nameLength = proc_name(pid, &nameBuffer, UInt32(nameBuffer.count))
        let name = nameLength > 0
            ? String(decoding: nameBuffer.prefix(Int(nameLength)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
            : "PID \(pid)"

        let start = UInt64(bsd.pbi_start_tvsec) * 1_000_000_000
            + UInt64(bsd.pbi_start_tvusec) * 1_000
        return .success(ProcessResourceRecord(
            pid: pid,
            parentPID: Int32(bitPattern: bsd.pbi_ppid),
            startTimeNanoseconds: start,
            name: name,
            executablePath: executablePath,
            cpuTimeNanoseconds: usage.ri_user_time &+ usage.ri_system_time,
            physicalFootprintBytes: Int64(usage.ri_phys_footprint),
            peakFootprintBytes: Int64(usage.ri_lifetime_max_phys_footprint)
        ))
    }
}
```

- [ ] **Step 4: Add exact capture types and a count-correct PID enumerator**

```swift
public struct ProcessIdentity: Hashable, Codable, Sendable {
    public let pid: Int32
    public let startTimeNanoseconds: UInt64
}

public enum ProcessCaptureSource: String, Sendable { case local, helperEnhanced }

public struct ProcessCapture: Sendable {
    public let records: [ProcessResourceRecord]
    public let failures: [Int32: ProcessResourceReadFailure]
    public let wallDate: Date
    public let monotonicNanoseconds: UInt64
    public let source: ProcessCaptureSource
    public let enumeratedCount: Int
}

public protocol PIDListing: Sendable {
    func estimatedCount() -> Int
    func fill(_ buffer: inout [Int32]) -> Int
}

public struct DarwinPIDListing: PIDListing {
    public func estimatedCount() -> Int { max(0, Int(proc_listallpids(nil, 0))) }
    public func fill(_ buffer: inout [Int32]) -> Int {
        Int(proc_listallpids(&buffer, Int32(buffer.count * MemoryLayout<Int32>.size)))
    }
}

public struct PIDEnumerator: Sendable {
    let listing: any PIDListing
    let reserve: Int
    public init(listing: any PIDListing = DarwinPIDListing(), reserve: Int = 64) {
        self.listing = listing
        self.reserve = reserve
    }
    public func allPIDs() -> [Int32] {
        var capacity = max(64, listing.estimatedCount() + reserve)
        for _ in 0..<4 {
            var buffer = [Int32](repeating: 0, count: capacity)
            let count = listing.fill(&buffer)
            guard count > 0 else { return [] }
            if count < capacity {
                return Array(Set(buffer.prefix(count).filter { $0 > 0 })).sorted()
            }
            capacity *= 2
        }
        return []
    }
}

public protocol ProcessSnapshotProviding: Sendable {
    func capture() async -> ProcessCapture
}
```

Implement `LocalProcessSnapshotProvider.capture()` by enumerating once, reading every PID with `DarwinProcessResourceReader`, recording each failure category, and using `DispatchTime.now().uptimeNanoseconds` for the capture clock.

- [ ] **Step 5: Run the focused tests and the existing monitoring tests**

Run: `swift test --filter ProcessSnapshotProviderTests && swift test --filter MonitoringTests`

Expected: both suites PASS.

- [ ] **Step 6: Commit the low-level capture**

```bash
git add Sources/Shared/ProcessResourceRecord.swift Sources/Infrastructure/ApplicationUsageModels.swift Sources/Infrastructure/ProcessSnapshotProvider.swift Tests/IntegrationTests/ProcessSnapshotProviderTests.swift
git commit -m "fix: capture every visible process"
```

---

