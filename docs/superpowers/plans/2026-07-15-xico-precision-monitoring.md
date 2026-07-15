# Xico Precision Monitoring Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deliver trustworthy per-application CPU and memory monitoring, Precision Glass CPU/memory menu panels, and a live application inspector whose values can be verified against macOS tools.

**Architecture:** A shared libproc reader produces minimal process records for both the app and privileged helper. Infrastructure enumerates all PIDs, enriches permission-denied records through XPC, resolves child processes to application ownership, computes monotonic CPU deltas, and publishes one application-level snapshot. Features consume that snapshot without performing system calls and render CPU-first or memory-first presentations with both metrics in every application row.

**Tech Stack:** Swift 6, SwiftPM, macOS 14+, Darwin/libproc, Mach VM statistics, ServiceManagement privileged XPC, Swift Concurrency, SwiftUI/AppKit, XCTest.

## Global Constraints

- Preserve unrelated dirty-worktree changes; stage and commit only the files named by the active task.
- Retain the existing safe UTF-8 decoding in `Sources/Infrastructure/ProcessSampler.swift`; do not restore `String(cString:)`.
- CPU panel primary content is CPU-only; memory panel primary content is memory-only.
- Application rows in both panels always display CPU and physical memory.
- Default CPU display is normalized 0–100%; raw 0–N×100% remains selectable.
- Per-application memory uses `ri_phys_footprint`; virtual size and RSS are not substitutes.
- Process identity is PID plus process start time; PID alone is never a CPU-baseline key.
- First process sample publishes memory immediately and marks CPU as warming up.
- Helper failure must fall back to local sampling without blocking the UI or showing fabricated zeros.
- Visible application sampling defaults to 1 Hz and stops when no detail consumer is visible.
- Default panel width is 336 pt; default process row count is 6.
- Precision Glass semantic colors are fixed: CPU blue, memory violet, network mint, system pink, disk amber, temperature coral, healthy green.
- No new third-party dependency is allowed.

---

## File Structure

### Shared process records and helper transport

- Create `Sources/Shared/ProcessResourceRecord.swift`: Codable process record, read failures, helper batch payload, and Darwin libproc reader shared by app/helper.
- Modify `Sources/Shared/HelperProtocol.swift`: add the read-only batch process sampling XPC method.
- Modify `Sources/Shared/HelperSecurity.swift`: bump helper protocol version to `0.4.0`.
- Modify `Sources/XicoHelper/main.swift`: implement bounded batch sampling with the shared reader.

### Infrastructure sampling and memory semantics

- Create `Sources/Infrastructure/ApplicationUsageModels.swift`: application identity, member usage, aggregate usage, snapshot status, coverage, CPU display mode, and trends.
- Create `Sources/Infrastructure/ProcessSnapshotProvider.swift`: PID enumeration, local capture, helper enrichment, capture source.
- Create `Sources/Infrastructure/ApplicationOwnershipResolver.swift`: `.app` root and parent-chain ownership.
- Create `Sources/Infrastructure/ApplicationUsageAggregator.swift`: CPU delta, aggregation, stable ranking, bounded trend cache.
- Modify `Sources/Infrastructure/ProcessSampler.swift`: replace PID-row orchestration with the application-level actor while preserving safe name decoding in the shared reader.
- Create `Sources/Infrastructure/MemoryMetrics.swift`: pure system-memory breakdown and Xico pressure-index calculation.
- Modify `Sources/Infrastructure/LiveMetrics.swift`: consume the pure memory calculation and expose available memory/pressure index.
- Modify `Sources/Infrastructure/HelperProxy.swift`: add short-timeout read-only process sampling.

### Feature state, preferences, and UI

- Modify `Sources/Features/AppModel.swift`: publish `ApplicationUsageSnapshot`, reset stale baselines, and run asynchronous sampling off the main actor.
- Create `Sources/Features/MonitoringPreferences.swift`: exact UserDefaults keys and typed values.
- Create `Sources/Features/ApplicationUsageViews.swift`: dual-metric row, state/coverage banner, icon resolver, and application inspector.
- Create `Sources/DesignSystem/PrecisionMonitoringComponents.swift`: metric section surface, status pill, aligned value column, and semantic gauge.
- Modify `Sources/Features/MenuPanels.swift`: Precision Glass CPU and memory layouts; remove GPU from the CPU panel; add memory history.
- Modify `Sources/Features/MenuBarSettingsView.swift`: CPU scale, grouping, row count, density, units, and 1/2/5-second refresh choices.
- Modify `Sources/Domain/Models.swift`: explicit decimal/binary memory formatting while preserving `formattedMemory` compatibility.

### Tests and QA

- Create `Tests/IntegrationTests/ProcessSnapshotProviderTests.swift`.
- Create `Tests/IntegrationTests/ApplicationUsageAggregatorTests.swift`.
- Create `Tests/IntegrationTests/HelperProcessSamplingTests.swift`.
- Create `Tests/IntegrationTests/MemoryMetricsTests.swift`.
- Create `Tests/IntegrationTests/ProcessAccuracyBenchmarkTests.swift`.
- Create `Tests/FeatureTests/ApplicationUsagePresentationTests.swift`.
- Modify `Tests/FeatureTests/MetricsGatingTests.swift`.
- Modify `Tests/FeatureTests/LocalizationCoverageTests.swift` only if its expected key inventory is explicit rather than discovered dynamically.
- Modify `Sources/XicoApp/LiveShotRenderer.swift` and `Sources/XicoApp/XicoApp.swift`: add focused `--monitoring-shots` QA output.
- Modify all `Sources/DesignSystem/Resources/*.lproj/Localizable.strings`: add the exact new monitoring strings.

---

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

### Task 2: Resolve Application Ownership and Aggregate CPU/Memory

**Files:**
- Create: `Sources/Infrastructure/ApplicationOwnershipResolver.swift`
- Create: `Sources/Infrastructure/ApplicationUsageAggregator.swift`
- Modify: `Sources/Infrastructure/ApplicationUsageModels.swift`
- Modify: `Sources/Infrastructure/ProcessSampler.swift`
- Test: `Tests/IntegrationTests/ApplicationUsageAggregatorTests.swift`

**Interfaces:**
- Consumes: `ProcessCapture` from Task 1.
- Produces: `ApplicationIdentity`, `ApplicationMemberUsage`, `ApplicationUsage`, `ApplicationUsageSnapshot`, `ApplicationOwnershipResolver.resolve(_:)`, `ProcessCPUDeltaCalculator.rates(for:)`, `ApplicationUsageAggregator.aggregate(...)`, `ProcessSampler.sample(limit:combinesProcesses:)`, and `ProcessSampler.resetBaseline()`.

- [ ] **Step 1: Write failing tests for app-root resolution, CPU normalization, aggregation, PID reuse, and long gaps**

```swift
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
        XCTAssertNil(calculator.rates(for: first))
        XCTAssertEqual(calculator.rates(for: second)?.values.first, 100, accuracy: 0.001)
        XCTAssertNil(calculator.rates(for: late))
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
}
```

Add this private fixture under the test target so production code has no fixture API:

```swift
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
```

- [ ] **Step 2: Run the test and verify it fails on missing application types**

Run: `swift test --filter ApplicationUsageAggregatorTests`

Expected: FAIL with missing `ApplicationOwnershipResolver`, `ApplicationUsageAggregator`, and `ProcessCPUDeltaCalculator`.

- [ ] **Step 3: Add the exact application-level models**

```swift
public struct ApplicationIdentity: Hashable, Codable, Sendable, Identifiable {
    public let rawValue: String
    public var id: String { rawValue }
}

public enum CPUDisplayMode: String, CaseIterable, Codable, Sendable {
    case normalized
    case totalCore
}

public struct ApplicationMemberUsage: Identifiable, Sendable {
    public let identity: ProcessIdentity
    public let name: String
    public let cpuRawPercent: Double?
    public let physicalFootprintBytes: Int64
    public var id: ProcessIdentity { identity }
}

public struct ApplicationUsageTrend: Sendable {
    public var cpuRaw: [Double]
    public var memoryBytes: [Int64]
}

public struct ApplicationUsage: Identifiable, Sendable {
    public let id: ApplicationIdentity
    public let displayName: String
    public let bundleIdentifier: String?
    public let bundlePath: String?
    public let representativePID: Int32
    public let members: [ApplicationMemberUsage]
    public let cpuRawPercent: Double?
    public let cpuNormalizedPercent: Double?
    public let physicalFootprintBytes: Int64
    public let peakFootprintBytes: Int64
    public var trend: ApplicationUsageTrend
    public var memberCount: Int { members.count }
    public func cpuPercent(mode: CPUDisplayMode) -> Double? {
        mode == .normalized ? cpuNormalizedPercent : cpuRawPercent
    }
}

public struct ProcessCoverage: Sendable, Equatable {
    public let enumerated: Int
    public let sampled: Int
    public let denied: Int
    public let exited: Int
    public var fraction: Double { enumerated > 0 ? Double(sampled) / Double(enumerated) : 0 }
}

public enum ProcessSamplingStatus: String, Sendable { case warmingUp, live, partial, stale, unavailable }

public struct ApplicationUsageSnapshot: Sendable {
    public let byCPU: [ApplicationUsage]
    public let byMemory: [ApplicationUsage]
    public let status: ProcessSamplingStatus
    public let coverage: ProcessCoverage
    public let sampledAt: Date
    public let source: ProcessCaptureSource
}
```

- [ ] **Step 4: Implement deterministic ownership resolution**

`outermostApplicationPath(in:)` must choose the first path component ending in `.app`, so nested Chrome/Electron helper bundles stay under the outer application. `resolve(_:)` must use this order:

1. Own outermost `.app` path.
2. Nearest parent record with resolved application ownership.
3. Executable path identity `exec:<path>`.
4. Name identity `name:<name>` when no path exists.

Bundle metadata comes from an injectable `ApplicationMetadataProviding` protocol. The production implementation reads `CFBundleIdentifier`, `CFBundleDisplayName`, and `CFBundleName` from `Bundle(url:)`; tests use a dictionary fake.

- [ ] **Step 5: Implement monotonic CPU delta and aggregate members**

`ProcessCPUDeltaCalculator.rates(for:)` must update its baseline on every capture, return `nil` on the first/invalid/overlong interval, and calculate each known identity as:

```swift
let elapsed = Double(current.monotonicNanoseconds - previousTime)
let delta = Double(record.cpuTimeNanoseconds - previous.cpuTimeNanoseconds)
rates[identity] = delta / elapsed * 100
```

`ApplicationUsageAggregator` sums member raw CPU, footprint, and peak footprint. It computes normalized CPU as `min(100, raw / Double(logicalCPUCount))`. Sorting always uses raw CPU; display mode never changes rank order.

Add `UsageRanker.order(_:metric:previousOrder:)`. A value difference larger than 3% of the larger value sorts immediately by the selected metric; values inside that band use the previous visible order, then application identity as the deterministic final tie-breaker.

- [ ] **Step 6: Refactor `ProcessSampler` into an actor that publishes application snapshots**

```swift
public actor ProcessSampler {
    private let provider: any ProcessSnapshotProviding
    private let resolver: ApplicationOwnershipResolver
    private let aggregator: ApplicationUsageAggregator
    private var cpu = ProcessCPUDeltaCalculator()
    private var trends: [ApplicationIdentity: ApplicationUsageTrend] = [:]

    public init(provider: any ProcessSnapshotProviding = LocalProcessSnapshotProvider(),
                logicalCPUCount: Int = ProcessInfo.processInfo.activeProcessorCount) {
        self.provider = provider
        self.resolver = ApplicationOwnershipResolver()
        self.aggregator = ApplicationUsageAggregator(logicalCPUCount: logicalCPUCount)
    }

    public func resetBaseline() { cpu.reset() }
    public func sample(limit: Int = 6, combinesProcesses: Bool = true) async -> ApplicationUsageSnapshot
}
```

Keep trends only for the union of the top 20 CPU and top 20 memory applications, cap both arrays at 60 samples, and remove identities absent for 120 seconds. A warming snapshot contains current memory rows and an empty CPU ranking; it never substitutes `0.0%` for unknown CPU.

- [ ] **Step 7: Run aggregation and full existing monitoring tests**

Run: `swift test --filter ApplicationUsageAggregatorTests && swift test --filter MonitoringTests`

Expected: PASS.

- [ ] **Step 8: Commit application aggregation**

```bash
git add Sources/Infrastructure/ApplicationUsageModels.swift Sources/Infrastructure/ApplicationOwnershipResolver.swift Sources/Infrastructure/ApplicationUsageAggregator.swift Sources/Infrastructure/ProcessSampler.swift Tests/IntegrationTests/ApplicationUsageAggregatorTests.swift
git commit -m "feat: aggregate resource usage by application"
```

---

### Task 3: Enrich Permission-Denied Processes Through the Existing Helper

**Files:**
- Modify: `Sources/Shared/HelperProtocol.swift`
- Modify: `Sources/Shared/HelperSecurity.swift`
- Modify: `Sources/XicoHelper/main.swift`
- Modify: `Sources/Infrastructure/HelperProxy.swift`
- Modify: `Sources/Infrastructure/ProcessSnapshotProvider.swift`
- Test: `Tests/IntegrationTests/HelperProcessSamplingTests.swift`

**Interfaces:**
- Consumes: `ProcessHelperBatchResponse`, `DarwinProcessResourceReader`, and `ProcessCapture`.
- Produces: `XicoHelperProtocol.sampleProcesses(pids:reply:)`, `PrivilegedProcessSampling`, `HelperProxy.sampleProcesses(pids:)`, and `HybridProcessSnapshotProvider`.

- [ ] **Step 1: Write failing helper merge tests**

```swift
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
}
```

Use these exact private fakes in the same test file:

```swift
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
```

- [ ] **Step 2: Run the test and verify the helper sampling interfaces are absent**

Run: `swift test --filter HelperProcessSamplingTests`

Expected: FAIL for missing `HybridProcessSnapshotProvider` and `PrivilegedProcessSampling`.

- [ ] **Step 3: Extend the XPC protocol with a bounded Data response**

Add to `XicoHelperProtocol`:

```swift
func sampleProcesses(pids: [NSNumber], reply: @escaping (Data?) -> Void)
```

Set `XicoHelperInfo.version` to `"0.4.0"`.

Implement the helper method with a hard maximum of 4,096 PIDs, `IdleExit.shared.beginOperation()/endOperation()`, `DarwinProcessResourceReader.read(pid:)`, and `JSONEncoder`. Return `nil` for oversized requests or encoding failure. Return only `ProcessResourceRecord`; never return command-line arguments, environment variables, files, or user content.

- [ ] **Step 4: Add a 1.5-second helper client and hybrid provider**

```swift
public protocol PrivilegedProcessSampling: Sendable {
    var processSamplingAvailable: Bool { get }
    func sampleProcesses(pids: [Int32]) async -> ProcessHelperBatchResponse?
}
```

`HelperProxy.sampleProcesses(pids:)` must reuse signature pinning, use a fresh privileged connection, encode PIDs as `NSNumber`, decode `ProcessHelperBatchResponse`, and call `scheduleTimeout(..., value: nil, timeout: 1.5)`.

`HybridProcessSnapshotProvider` calls the local provider first, sends only `.permissionDenied` PIDs to the helper, merges helper records by `(pid,startTime)`, and removes recovered failures. Helper absence, timeout, decode error, or empty response leaves the local capture unchanged.

- [ ] **Step 5: Run helper, safety, and aggregation tests**

Run: `swift test --filter HelperProcessSamplingTests && swift test --filter HelperFileRemoverTests && swift test --filter ApplicationUsageAggregatorTests`

Expected: PASS.

- [ ] **Step 6: Commit helper enrichment**

```bash
git add Sources/Shared/HelperProtocol.swift Sources/Shared/HelperSecurity.swift Sources/XicoHelper/main.swift Sources/Infrastructure/HelperProxy.swift Sources/Infrastructure/ProcessSnapshotProvider.swift Tests/IntegrationTests/HelperProcessSamplingTests.swift
git commit -m "feat: sample protected processes through helper"
```

---

### Task 4: Publish Honest Sampling State Through AppModel

**Files:**
- Modify: `Sources/Features/AppModel.swift`
- Modify: `Sources/XicoApp/MenuBarController.swift`
- Modify: `Tests/FeatureTests/MetricsGatingTests.swift`

**Interfaces:**
- Consumes: `ProcessSampler.sample(limit:combinesProcesses:)` and `ApplicationUsageSnapshot`.
- Produces: `MetricsFeed.applicationUsage`, `AppModel.topByCPU`, `AppModel.topByMemory`, and `AppModel.prepareApplicationSampling()`.

- [ ] **Step 1: Add failing state-lifecycle tests**

Add `@testable import Infrastructure` beside the existing `@testable import Features`, then add pure state helpers so tests do not instantiate AppKit windows:

```swift
func testOpeningDetailConsumerRequestsFreshProcessBaseline() {
    XCTAssertTrue(AppModel.shouldResetProcessBaseline(wasVisible: false, isVisible: true))
    XCTAssertFalse(AppModel.shouldResetProcessBaseline(wasVisible: true, isVisible: true))
}

func testCoverageBelowNinetyPercentIsPartial() {
    XCTAssertEqual(ProcessSamplingStatus.from(coverage: .init(enumerated: 100, sampled: 89, denied: 11, exited: 0), hasCPU: true), .partial)
    XCTAssertEqual(ProcessSamplingStatus.from(coverage: .init(enumerated: 100, sampled: 95, denied: 5, exited: 0), hasCPU: true), .live)
}

func testSnapshotBecomesStaleAfterTwoRefreshIntervals() {
    let snapshot = ApplicationUsageSnapshot.liveFixture(sampledAt: Date(timeIntervalSince1970: 100))
    XCTAssertEqual(snapshot.effectiveStatus(now: Date(timeIntervalSince1970: 103),
                                            refreshInterval: 1), .stale)
}
```

- [ ] **Step 2: Run the focused test and verify failure**

Run: `swift test --filter MetricsGatingTests`

Expected: FAIL for missing `shouldResetProcessBaseline` and `ProcessSamplingStatus.from`.

- [ ] **Step 3: Replace the two PID lists with one application snapshot**

Add the status and empty-state factories before wiring the feed:

```swift
public extension ProcessSamplingStatus {
    static func from(coverage: ProcessCoverage, hasCPU: Bool) -> Self {
        guard coverage.enumerated > 0 else { return .unavailable }
        guard hasCPU else { return .warmingUp }
        return coverage.fraction < 0.90 ? .partial : .live
    }
}

public extension ApplicationUsageSnapshot {
    static func unavailable(now: Date = Date()) -> Self {
        Self(byCPU: [], byMemory: [], status: .unavailable,
             coverage: .init(enumerated: 0, sampled: 0, denied: 0, exited: 0),
             sampledAt: now, source: .local)
    }
    static func warmingUp(now: Date = Date()) -> Self {
        Self(byCPU: [], byMemory: [], status: .warmingUp,
             coverage: .init(enumerated: 0, sampled: 0, denied: 0, exited: 0),
             sampledAt: now, source: .local)
    }
    func application(id: ApplicationIdentity) -> ApplicationUsage? {
        byCPU.first(where: { $0.id == id }) ?? byMemory.first(where: { $0.id == id })
    }
    func effectiveStatus(now: Date, refreshInterval: TimeInterval) -> ProcessSamplingStatus {
        guard status != .unavailable else { return .unavailable }
        return now.timeIntervalSince(sampledAt) > max(0.1, refreshInterval) * 2 ? .stale : status
    }
}
```

Add this private extension in `MetricsGatingTests.swift`:

```swift
private extension ApplicationUsageSnapshot {
    static func liveFixture(sampledAt: Date) -> Self {
        Self(byCPU: [], byMemory: [], status: .live,
             coverage: .init(enumerated: 1, sampled: 1, denied: 0, exited: 0),
             sampledAt: sampledAt, source: .local)
    }
}
```

In `MetricsFeed`:

```swift
public var applicationUsage = ApplicationUsageSnapshot.unavailable()
public var topByCPU: [ApplicationUsage] { applicationUsage.byCPU }
public var topByMemory: [ApplicationUsage] { applicationUsage.byMemory }
```

Update the AppModel forwarding properties to `[ApplicationUsage]`. Replace `MetricsSample.topByCPU/topByMemory` with:

```swift
let applicationUsage: ApplicationUsageSnapshot?
```

`applyMetrics` assigns the snapshot before `feed.publish(...)` so one `objectWillChange` covers values and state together.

- [ ] **Step 4: Make process sampling asynchronous and clear stale values on visibility transitions**

Replace the direct synchronous `procSampler.sample(top: 4)` call with `await procSampler.sample(limit: MonitoringPreferences.processLimit(), combinesProcesses: MonitoringPreferences.combinesProcesses())` inside a utility-priority detached task. System metrics, process metrics, sensors, and volume data remain in that one single-flight task; the main actor only runs `applyMetrics`.

When a consumer changes hidden → visible:

```swift
public func prepareApplicationSampling() {
    liveMetricsFeed.applicationUsage = .warmingUp()
    liveMetricsFeed.objectWillChange.send()
    Task { await processes.resetBaseline() }
}
```

Call this from `MenuBarController` before setting `metricsDetailConsumerVisible = true`. Keep the no-consumer path free of process enumeration.

- [ ] **Step 5: Run gating and application aggregation tests**

Run: `swift test --filter MetricsGatingTests && swift test --filter ApplicationUsageAggregatorTests`

Expected: PASS, including the existing three visibility cases.

- [ ] **Step 6: Commit state integration**

```bash
git add Sources/Features/AppModel.swift Sources/XicoApp/MenuBarController.swift Tests/FeatureTests/MetricsGatingTests.swift
git commit -m "feat: publish live application sampling state"
```

---

### Task 5: Make System Memory Semantics Explicit and Testable

**Files:**
- Create: `Sources/Infrastructure/MemoryMetrics.swift`
- Modify: `Sources/Infrastructure/LiveMetrics.swift`
- Modify: `Sources/XicoApp/MenuBarController.swift`
- Modify: `Sources/XicoApp/PerformanceProbe.swift`
- Test: `Tests/IntegrationTests/MemoryMetricsTests.swift`

**Interfaces:**
- Produces: `MemoryPageCounts`, `MemoryBreakdown.calculate(...)`, `MemoryPressureIndex.score(...)`, `SystemSnapshot.memoryAvailable`, and `SystemSnapshot.memoryPressureIndex`.
- Consumes: `vm_statistics64`, swap usage, `kern.memorystatus_level`, and `kern.memorystatus_vm_pressure_level`.

- [ ] **Step 1: Write failing tests for memory categories and pressure-index labeling math**

```swift
final class MemoryMetricsTests: XCTestCase {
    func testBreakdownKeepsCacheInsideAvailableMemory() {
        let pages = MemoryPageCounts(internalPages: 500, purgeablePages: 50,
                                     externalPages: 100, wiredPages: 200,
                                     compressorPages: 100)
        let value = MemoryBreakdown.calculate(totalBytes: 1_000 * 4096,
                                              pageSize: 4096, pages: pages)
        XCTAssertEqual(value.applicationBytes, 450 * 4096)
        XCTAssertEqual(value.wiredBytes, 200 * 4096)
        XCTAssertEqual(value.compressedBytes, 100 * 4096)
        XCTAssertEqual(value.cachedBytes, 150 * 4096)
        XCTAssertEqual(value.usedBytes, 750 * 4096)
        XCTAssertEqual(value.availableBytes, 250 * 4096)
    }

    func testPressureIndexUsesKernelPressureAndStateFloor() {
        XCTAssertEqual(MemoryPressureIndex.score(kernelAvailableLevel: 35,
                                                 pressureState: 1,
                                                 availableFraction: 0.3,
                                                 compressedFraction: 0.1,
                                                 swapFraction: 0), 0.65, accuracy: 0.001)
        XCTAssertGreaterThanOrEqual(MemoryPressureIndex.score(kernelAvailableLevel: 90,
                                                              pressureState: 4,
                                                              availableFraction: 0.5,
                                                              compressedFraction: 0,
                                                              swapFraction: 0), 0.85)
    }
}
```

- [ ] **Step 2: Run the test and verify the pure memory types are missing**

Run: `swift test --filter MemoryMetricsTests`

Expected: FAIL for missing `MemoryPageCounts`, `MemoryBreakdown`, and `MemoryPressureIndex`.

- [ ] **Step 3: Implement exact breakdown and bounded pressure formula**

```swift
public enum MemoryPressureIndex {
    public static func score(kernelAvailableLevel: Int?, pressureState: Int,
                             availableFraction: Double, compressedFraction: Double,
                             swapFraction: Double) -> Double {
        let clamp: (Double) -> Double = { min(1, max(0, $0)) }
        let kernel = kernelAvailableLevel.map { 1 - clamp(Double($0) / 100) } ?? 0
        let stateFloor: Double = pressureState == 4 ? 0.85 : (pressureState == 2 ? 0.60 : 0)
        let availability = clamp((0.20 - availableFraction) / 0.20) * 0.55
        let compression = clamp(compressedFraction / 0.35) * 0.25
        let swap = clamp(swapFraction) * 0.20
        return clamp(max(kernel, stateFloor, availability + compression + swap))
    }
}
```

`MemoryBreakdown.calculate` uses:

- application pages = `max(0, internalPages - purgeablePages)`
- wired pages = `wiredPages`
- compressed pages = `compressorPages`
- cached pages = `externalPages + purgeablePages`
- used = application + wired + compressed
- available = `max(0, total - used)`

- [ ] **Step 4: Refactor `LiveMetricsSampler.sampleMemory()` to use the pure calculation**

Add `memoryAvailable` and `memoryPressureIndex` to `SystemSnapshot`. Replace the ambiguous `memoryPressurePercent` property. Keep `memoryPressureFraction` only as the documented three-state fallback. Update the menu bar glyph and performance probe to use `memoryPressureIndex ?? memoryUsedFraction` when the user selects pressure.

- [ ] **Step 5: Run memory, monitoring, and performance-probe compile tests**

Run: `swift test --filter MemoryMetricsTests && swift test --filter MonitoringTests && swift build`

Expected: PASS and build completes without references to `memoryPressurePercent`.

- [ ] **Step 6: Commit memory semantics**

```bash
git add Sources/Infrastructure/MemoryMetrics.swift Sources/Infrastructure/LiveMetrics.swift Sources/XicoApp/MenuBarController.swift Sources/XicoApp/PerformanceProbe.swift Tests/IntegrationTests/MemoryMetricsTests.swift
git commit -m "fix: define trustworthy memory pressure semantics"
```

---

### Task 6: Add Typed Monitoring Preferences and Dual-Metric Row Presentation

**Files:**
- Create: `Sources/Features/MonitoringPreferences.swift`
- Create: `Sources/Features/ApplicationUsageViews.swift`
- Modify: `Sources/Features/MenuBarSettingsView.swift`
- Modify: `Sources/Domain/Models.swift`
- Test: `Tests/FeatureTests/ApplicationUsagePresentationTests.swift`

**Interfaces:**
- Produces: `MonitoringPanelDensity`, `MonitoringPreferences`, `MemoryUnitStyle`, `Int64.formattedMemory(style:)`, `ApplicationUsageFocus`, and `ApplicationUsageRowPresentation.make(...)`.
- Consumes: `ApplicationUsage` and `CPUDisplayMode`.

- [ ] **Step 1: Write failing tests that lock the user's CPU/memory row rule**

```swift
import XCTest
@testable import Features
@testable import Infrastructure
import Domain

final class ApplicationUsagePresentationTests: XCTestCase {
    func testCPURowShowsCPUPrimaryAndMemorySecondary() {
        let row = ApplicationUsageRowPresentation.make(
            usage: .fixture(cpuRaw: 80, cpuNormalized: 10, memory: 1_073_741_824),
            focus: .cpu, cpuMode: .normalized, memoryStyle: .binary)
        XCTAssertEqual(row.primaryText, "10.0%")
        XCTAssertEqual(row.secondaryText, "1.00 GiB")
    }

    func testMemoryRowShowsMemoryPrimaryAndCPUSecondary() {
        let row = ApplicationUsageRowPresentation.make(
            usage: .fixture(cpuRaw: 80, cpuNormalized: 10, memory: 1_073_741_824),
            focus: .memory, cpuMode: .normalized, memoryStyle: .binary)
        XCTAssertEqual(row.primaryText, "1.00 GiB")
        XCTAssertEqual(row.secondaryText, "10.0%")
    }

    func testUnknownCPUIsSamplingNotZero() {
        let row = ApplicationUsageRowPresentation.make(
            usage: .fixture(cpuRaw: nil, cpuNormalized: nil, memory: 1_000_000),
            focus: .memory, cpuMode: .normalized, memoryStyle: .decimal)
        XCTAssertEqual(row.secondaryText, "采样中")
    }
}
```

Add this test-only fixture in the same file:

```swift
private extension ApplicationUsage {
    static func fixture(cpuRaw: Double?, cpuNormalized: Double?, memory: Int64) -> Self {
        let identity = ProcessIdentity(pid: 7, startTimeNanoseconds: 1)
        return ApplicationUsage(
            id: ApplicationIdentity(rawValue: "bundle:com.example.fixture"),
            displayName: "Fixture", bundleIdentifier: "com.example.fixture",
            bundlePath: "/Applications/Fixture.app", representativePID: 7,
            members: [ApplicationMemberUsage(identity: identity, name: "Fixture",
                                             cpuRawPercent: cpuRaw,
                                             physicalFootprintBytes: memory)],
            cpuRawPercent: cpuRaw, cpuNormalizedPercent: cpuNormalized,
            physicalFootprintBytes: memory, peakFootprintBytes: memory,
            trend: ApplicationUsageTrend(cpuRaw: [], memoryBytes: []))
    }
}
```

- [ ] **Step 2: Run the test and verify presentation types are absent**

Run: `swift test --filter ApplicationUsagePresentationTests`

Expected: FAIL for missing `ApplicationUsageRowPresentation` and `MemoryUnitStyle`.

- [ ] **Step 3: Add exact preferences and defaults**

```swift
public enum MonitoringPanelDensity: String, CaseIterable { case compact, balanced, detailed }

public enum MonitoringPreferences {
    public static let cpuModeKey = "xico.monitor.cpuMode"
    public static let combinesProcessesKey = "xico.monitor.combinesProcesses"
    public static let processLimitKey = "xico.monitor.processLimit"
    public static let densityKey = "xico.monitor.density"
    public static let memoryUnitKey = "xico.monitor.memoryUnit"

    public static func cpuMode(_ defaults: UserDefaults = .standard) -> CPUDisplayMode {
        CPUDisplayMode(rawValue: defaults.string(forKey: cpuModeKey) ?? "normalized") ?? .normalized
    }
    public static func combinesProcesses(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: combinesProcessesKey) == nil ? true : defaults.bool(forKey: combinesProcessesKey)
    }
    public static func processLimit(_ defaults: UserDefaults = .standard) -> Int {
        let value = defaults.integer(forKey: processLimitKey)
        return [4, 6, 10, 20].contains(value) ? value : 6
    }
    public static func density(_ defaults: UserDefaults = .standard) -> MonitoringPanelDensity {
        MonitoringPanelDensity(rawValue: defaults.string(forKey: densityKey) ?? "balanced") ?? .balanced
    }
}
```

Add `MemoryUnitStyle.decimal` and `.binary`. `formattedMemory(style:)` uses powers of 1,000 with `GB/MB` for decimal and powers of 1,024 with `GiB/MiB` for binary. Keep the existing `formattedMemory` property delegating to the current Activity Monitor-compatible behavior so unrelated screens do not change.

- [ ] **Step 4: Add pure row presentation**

```swift
public enum ApplicationUsageFocus { case cpu, memory }

public struct ApplicationUsageRowPresentation: Equatable {
    public let primaryText: String
    public let secondaryText: String
    public let fillFraction: Double

    public static func make(usage: ApplicationUsage, focus: ApplicationUsageFocus,
                            cpuMode: CPUDisplayMode, memoryStyle: MemoryUnitStyle,
                            largestMemory: Int64 = 1) -> Self {
        let cpu = usage.cpuPercent(mode: cpuMode)
        let cpuText = cpu.map { String(format: "%.1f%%", $0) } ?? xLoc("采样中")
        let memoryText = usage.physicalFootprintBytes.formattedMemory(style: memoryStyle)
        let fill = focus == .cpu
            ? min(1, (cpu ?? 0) / (cpuMode == .normalized ? 100 : 100 * Double(ProcessInfo.processInfo.activeProcessorCount)))
            : min(1, Double(usage.physicalFootprintBytes) / Double(max(1, largestMemory)))
        return focus == .cpu
            ? Self(primaryText: cpuText, secondaryText: memoryText, fillFraction: fill)
            : Self(primaryText: memoryText, secondaryText: cpuText, fillFraction: fill)
    }
}
```

- [ ] **Step 5: Add settings controls**

Under CPU/memory item details, add shared controls for CPU format, combine processes, row count, density, and memory unit. Global refresh choices become exactly 1, 2, and 5 seconds. Changing presentation preferences updates the next rendered frame; changing grouping calls `model.prepareApplicationSampling()` to rebuild ownership and baseline.

- [ ] **Step 6: Run presentation, localization, and settings compile tests**

Run: `swift test --filter ApplicationUsagePresentationTests && swift test --filter LocalizationCoverageTests && swift build`

Expected: PASS.

- [ ] **Step 7: Commit preferences and presentation**

```bash
git add Sources/Features/MonitoringPreferences.swift Sources/Features/ApplicationUsageViews.swift Sources/Features/MenuBarSettingsView.swift Sources/Domain/Models.swift Tests/FeatureTests/ApplicationUsagePresentationTests.swift
git commit -m "feat: configure application monitoring presentation"
```

---

### Task 7: Build Precision Glass CPU/Memory Panels and Application Inspector

**Files:**
- Create: `Sources/DesignSystem/PrecisionMonitoringComponents.swift`
- Modify: `Sources/Features/ApplicationUsageViews.swift`
- Modify: `Sources/Features/MenuPanels.swift`
- Test: `Tests/FeatureTests/ApplicationUsagePresentationTests.swift`

**Interfaces:**
- Consumes: `ApplicationUsageSnapshot`, row presentation, typed preferences, and `SystemSnapshot` memory fields.
- Produces: `ApplicationUsageList`, `ApplicationUsageInspector`, `XMonitoringSection`, `XSamplingStatusPill`, and finalized CPU/memory panel layouts.

- [ ] **Step 1: Extend presentation tests for headers, column order, and state copy**

```swift
func testCPUColumnOrderIsApplicationCPUMemory() {
    XCTAssertEqual(ApplicationUsageFocus.cpu.columnTitles, ["应用", "CPU", "内存"])
}

func testMemoryColumnOrderIsApplicationMemoryCPU() {
    XCTAssertEqual(ApplicationUsageFocus.memory.columnTitles, ["应用", "内存", "CPU"])
}

func testPartialCoverageCopyIncludesPercentage() {
    XCTAssertEqual(ProcessCoverage(enumerated: 100, sampled: 82, denied: 18, exited: 0).displayText,
                   "数据覆盖 82%")
}
```

- [ ] **Step 2: Run the focused tests and confirm failure on the new presentation APIs**

Run: `swift test --filter ApplicationUsagePresentationTests`

Expected: FAIL for missing `columnTitles` and `displayText`.

- [ ] **Step 3: Add Precision Glass primitives without changing global theme behavior**

Add the tested presentation helpers:

```swift
public extension ApplicationUsageFocus {
    var columnTitles: [String] {
        switch self {
        case .cpu: return [xLoc("应用"), "CPU", xLoc("内存")]
        case .memory: return [xLoc("应用"), xLoc("内存"), "CPU"]
        }
    }
}

public extension ProcessCoverage {
    var displayText: String {
        xLocF("数据覆盖 %d%%", Int((fraction * 100).rounded()))
    }
}
```

`XMonitoringSection` is a rounded 14-pt surface using `XColor.surfaceElevated`, a one-pixel `XColor.border`, and no metric-colored fill. `XSamplingStatusPill` uses healthy green for live, CPU blue for warming, amber for partial/stale, and neutral tertiary for unavailable. `XSemanticGauge` accepts its metric color explicitly; it must not use the existing multicolor `ringColors` for CPU or memory totals.

- [ ] **Step 4: Implement a reusable dual-metric application list**

`ApplicationUsageList` receives `focus`, `snapshot`, `cpuMode`, `memoryStyle`, `totalMemory`, and `onSelect`. Every row renders:

1. 18-pt application icon resolved from `bundlePath`, falling back to a gear.
2. Application name and `N 个进程` secondary label when `memberCount > 1`.
3. Primary value column.
4. Secondary value column.
5. A low-opacity semantic fill bar based on the focus metric.

The header column order comes from `ApplicationUsageFocus.columnTitles`. Warming state shows memory rows with CPU text `采样中`; unavailable state shows a retry/status block instead of empty zeros.

- [ ] **Step 5: Rewrite CPU content around CPU-only primary information**

Keep total/user/system, P/E frequency, per-core visualization, load, CPU temperature, and CPU history. Remove `gpuSegment` from `cpuContent`. Render `ApplicationUsageList(focus: .cpu, snapshot: feed.applicationUsage, ...)` below the history. CPU blue is the gauge/history/fill color; system pink is only the system portion.

- [ ] **Step 6: Rewrite memory content around memory-only primary information**

Show memory state and `Xico 压力指数` as separate labels, physical used/total, application/wired/compressed/cached/available rows, page-in/page-out rates, swap usage, and a history selector for pressure/compression/swap. Render `ApplicationUsageList(focus: .memory, ...)` below memory history. Add cached as a real legend row; available equals `SystemSnapshot.memoryAvailable` and is never recomputed in the view.

- [ ] **Step 7: Add a live application inspector**

Selecting a row stores `ApplicationIdentity`, not a stale `ApplicationUsage` copy. `ApplicationUsageInspector` observes `MetricsFeed`, resolves the latest matching usage from both rankings, and renders:

- current normalized/raw CPU according to preference;
- physical and peak footprint;
- 60-s CPU and memory charts from `trend`;
- child-process rows with PID, name, CPU, and memory;
- sample source, timestamp, and coverage;
- no terminate action in this slice.

Present the inspector as a sheet from `MenuMetricPanel`. If the app exits, keep the last snapshot with an `已退出` state until the sheet closes.

- [ ] **Step 8: Run feature tests and build**

Run: `swift test --filter ApplicationUsagePresentationTests && swift test --filter MetricsGatingTests && swift build`

Expected: PASS.

- [ ] **Step 9: Commit Precision Glass monitoring UI**

```bash
git add Sources/DesignSystem/PrecisionMonitoringComponents.swift Sources/Features/ApplicationUsageViews.swift Sources/Features/MenuPanels.swift Tests/FeatureTests/ApplicationUsagePresentationTests.swift
git commit -m "feat: add precision CPU and memory panels"
```

---

### Task 8: Complete Localization, Accessibility, and Focused Screenshot QA

**Files:**
- Modify: `Sources/DesignSystem/Resources/de.lproj/Localizable.strings`
- Modify: `Sources/DesignSystem/Resources/en.lproj/Localizable.strings`
- Modify: `Sources/DesignSystem/Resources/es.lproj/Localizable.strings`
- Modify: `Sources/DesignSystem/Resources/fr.lproj/Localizable.strings`
- Modify: `Sources/DesignSystem/Resources/it.lproj/Localizable.strings`
- Modify: `Sources/DesignSystem/Resources/ja.lproj/Localizable.strings`
- Modify: `Sources/DesignSystem/Resources/ko.lproj/Localizable.strings`
- Modify: `Sources/DesignSystem/Resources/pt-BR.lproj/Localizable.strings`
- Modify: `Sources/DesignSystem/Resources/ru.lproj/Localizable.strings`
- Modify: `Sources/DesignSystem/Resources/zh-Hans.lproj/Localizable.strings`
- Modify: `Sources/DesignSystem/Resources/zh-Hant.lproj/Localizable.strings`
- Modify: `Sources/XicoApp/LiveShotRenderer.swift`
- Modify: `Sources/XicoApp/XicoApp.swift`
- Test: `Tests/FeatureTests/LocalizationCoverageTests.swift`

**Interfaces:**
- Produces: localized monitoring copy, complete VoiceOver values, and `Xico --monitoring-shots`.

- [ ] **Step 1: Add the exact new key inventory to localization coverage expectations**

The new keys are:

```text
Xico 压力指数
采样中
实时
部分数据
数据已过期
数据不可用
数据覆盖 %d%%
应用检查器
物理内存
峰值内存
应用聚合
独立进程
%d 个进程
采样来源
本地采样
助手增强
已退出
十进制 GB
二进制 GiB
合并子进程
```

Use professional native translations in all 11 localization files; preserve format specifiers exactly (`%d`, `%%`).

- [ ] **Step 2: Run localization tests and verify missing-key failure**

Run: `swift test --filter LocalizationCoverageTests`

Expected: FAIL listing the new keys until every localization file is updated.

- [ ] **Step 3: Add translations and VoiceOver composition**

Every application row accessibility value must read application name, process count, CPU state/value, and memory value in that order. Charts expose a concise label and latest value; decorative fill bars and glows are hidden. Sampling pills expose both state and coverage. Apply `.monospacedDigit()` to every changing numeric column.

- [ ] **Step 4: Add focused monitoring screenshot mode**

Add `renderMonitoringShots()` that renders only:

```text
/tmp/xico-monitoring-shots/cpu-dark.png
/tmp/xico-monitoring-shots/cpu-light.png
/tmp/xico-monitoring-shots/memory-dark.png
/tmp/xico-monitoring-shots/memory-light.png
/tmp/xico-monitoring-shots/cpu-warming-dark.png
/tmp/xico-monitoring-shots/memory-partial-dark.png
```

It must attach the views to an off-screen `NSWindow`, call `model.prepareApplicationSampling()`, allow at least two sampling intervals for live images, and use deterministic injected fixture snapshots for warming/partial images. Add the `--monitoring-shots` dispatch next to `--liveshots`.

- [ ] **Step 5: Run localization tests and render screenshots**

Run: `swift test --filter LocalizationCoverageTests && swift build && .build/debug/Xico --monitoring-shots`

Expected: tests PASS and all six PNG files exist with non-zero size.

- [ ] **Step 6: Inspect all six images**

Verify: no clipped text at 336 pt; CPU panel contains no GPU primary block; memory panel contains no CPU primary block; every application row has both numeric columns; light/dark contrast remains legible; warming/partial states are explicit.

- [ ] **Step 7: Commit localization and screenshot QA**

```bash
git add Sources/DesignSystem/Resources Sources/XicoApp/LiveShotRenderer.swift Sources/XicoApp/XicoApp.swift Tests/FeatureTests/LocalizationCoverageTests.swift
git commit -m "test: cover precision monitoring presentation"
```

---

### Task 9: Prove Accuracy, Coverage, Performance, and Regression Safety

**Files:**
- Create: `Tests/IntegrationTests/ProcessAccuracyBenchmarkTests.swift`
- Modify: `scripts/quality_gate.sh`
- Modify: `docs/superpowers/specs/2026-07-15-xico-precision-monitoring-design.md` only to mark the first implementation slice complete after every acceptance check passes.

**Interfaces:**
- Consumes: the finished local/hybrid provider and application sampler.
- Produces: opt-in real-machine accuracy tests and release-gate regression coverage.

- [ ] **Step 1: Add opt-in real-machine accuracy tests**

Gate the suite with `XICO_RUN_PROCESS_ACCURACY=1`. Add these exact assertions:

1. `PIDEnumerator().allPIDs().count >= Int(proc_listallpids(nil, 0)) - 32` to allow normal churn while rejecting the old quarter-count bug.
2. For the current test process, convert `/usr/bin/top -l 2 -pid <pid> -stats pid,mem` memory to bytes and require relative difference from `ri_phys_footprint` ≤ 5%.
3. Spawn `/usr/bin/yes`, take two samples one second apart, require raw CPU in 70–130%, and require normalized CPU to equal raw divided by active logical CPUs within 0.5 percentage points.
4. Create 1,200 fake records and require aggregation equality for CPU and footprint with no dropped members.
5. Run 20 local captures, sort durations, and require P95 < 15 ms on the current M1 acceptance machine.

Always terminate the `yes` process in `defer`, including assertion failures.

- [ ] **Step 2: Run ordinary tests first**

Run: `swift test`

Expected: all non-hardware-gated suites PASS.

- [ ] **Step 3: Run the real-machine accuracy suite**

Run: `XICO_RUN_PROCESS_ACCURACY=1 swift test --filter ProcessAccuracyBenchmarkTests`

Expected: all five acceptance tests PASS.

- [ ] **Step 4: Measure app-level runtime overhead**

Run the debug app with the CPU or memory panel visible for 60 seconds and use the existing performance probe to compare visible-detail sampling against steady state. Acceptance:

- additional Xico CPU < 1.5 percentage points at 1 Hz;
- trend/ranking cache allocation < 12 MB;
- memory rows appear < 150 ms after opening;
- valid CPU values appear by the next configured sampling interval;
- helper timeout never blocks the main thread.

Record the measured values in the test log emitted by `ProcessAccuracyBenchmarkTests`; do not hard-code machine-specific numbers into UI copy.

- [ ] **Step 5: Add stable suites to the quality gate**

Add the deterministic suites to `scripts/quality_gate.sh`:

```bash
swift test --filter ProcessSnapshotProviderTests
swift test --filter ApplicationUsageAggregatorTests
swift test --filter HelperProcessSamplingTests
swift test --filter MemoryMetricsTests
swift test --filter ApplicationUsagePresentationTests
```

Keep the opt-in real-machine suite outside default CI.

- [ ] **Step 6: Run the full quality gate and final screenshots**

Run: `bash scripts/quality_gate.sh && .build/debug/Xico --monitoring-shots`

Expected: quality gate exits 0; six monitoring screenshots regenerate successfully.

- [ ] **Step 7: Compare live stable processes against Activity Monitor/iStat**

For at least Xico, Chrome/Codex, and one system daemon:

- confirm application grouping contains the expected member count;
- compare physical footprint to the sum of corresponding Activity Monitor child rows;
- compare normalized CPU using iStat 0–100% mode;
- expand the inspector and verify member totals equal the application row after display rounding;
- verify partial coverage is visible if the helper is deliberately disabled.

- [ ] **Step 8: Mark the first spec slice complete and commit acceptance evidence**

Update the spec status from `待用户书面复核` to `首个实施切片完成` only after Steps 2–7 pass.

```bash
git add Tests/IntegrationTests/ProcessAccuracyBenchmarkTests.swift scripts/quality_gate.sh docs/superpowers/specs/2026-07-15-xico-precision-monitoring-design.md
git commit -m "test: verify application monitoring accuracy"
```

---

## Final Acceptance Checklist

- [ ] All PID enumeration uses count semantics and survives buffer saturation.
- [ ] PID reuse and long sample gaps cannot create false CPU spikes.
- [ ] Chrome/Electron/XPC child processes aggregate under the outer application.
- [ ] Helper enrichment is bounded, signed, read-only, and optional.
- [ ] CPU defaults to normalized 0–100%; raw mode is selectable.
- [ ] Per-app memory is summed `ri_phys_footprint` and verified against `top`.
- [ ] CPU panel contains CPU primary information only.
- [ ] Memory panel contains memory primary information only.
- [ ] Every application row in both panels displays CPU and memory.
- [ ] First CPU sample says `采样中`; unavailable data never appears as fabricated zero.
- [ ] Memory pressure state is distinct from the explicitly named Xico pressure index.
- [ ] CPU/memory application rows open the same live application inspector.
- [ ] Dark/light, warming, and partial screenshots pass visual review.
- [ ] Deterministic tests, real-machine accuracy tests, and performance budgets pass.
