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

