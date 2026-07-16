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

