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

