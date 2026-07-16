### Task 4: Publish Honest Sampling State Through AppModel

**Files:**
- Modify: `Sources/Features/AppModel.swift`
- Modify: `Sources/XicoApp/MenuBarController.swift`
- Modify: `Tests/FeatureTests/MetricsGatingTests.swift`

**Interfaces:**
- Consumes: `ProcessSampler.sample(limit:combinesProcesses:)` and `ApplicationUsageSnapshot`.
- Produces: `MetricsFeed.applicationUsage`, `AppModel.topByCPU`, `AppModel.topByMemory`, and `AppModel.prepareApplicationSampling()`.

**Controller dependency resolution:** Task 4 references
`MonitoringPreferences.processLimit()` and
`MonitoringPreferences.combinesProcesses()`, while the original plan introduces
that type in Task 6. Create `Sources/Features/MonitoringPreferences.swift` now
with only stable keys for those two values. Supported process limits are
`4`, `6`, `10`, and `20`, with missing/invalid values defaulting to `6`;
combine-processes defaults to `true` when absent. Task 6 will extend the same
enum with CPU mode, density, and memory-unit preferences. Treat the new file as
part of Task 4's allowed and committed file set.

**Dirty-worktree constraint:** `AppModel.swift` and `MenuBarController.swift`
contain pre-existing user changes. Preserve them and stage only Task 4 hunks,
plus the new preferences file and Task 4 tests. Do not stage either dirty file
wholesale.

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
