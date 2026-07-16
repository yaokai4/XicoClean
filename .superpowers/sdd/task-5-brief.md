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

**Dirty-worktree constraint:** `LiveMetrics.swift` and
`MenuBarController.swift` contain pre-existing user changes; stage only Task 5
hunks. `PerformanceProbe.swift` is a pre-existing untracked user file. Update
only its pressure-field reference in the working tree if needed for the current
package build, but do not add or commit the file. Preserve the rest of its
content. The committed sources must also build without depending on that
untracked file. Document this exception in the report.

**Controller scope resolution:** `Sources/Features/MenuPanels.swift` contains
two tracked references to the removed `memoryPressurePercent` name. Task 5 may
mechanically migrate only those references to `memoryPressureIndex` and commit
them; the Task 7 panel redesign remains out of scope. When the menu-bar memory
glyph is configured for pressure, collect swap input even without a detail
consumer so the declared pressure-index formula is not silently degraded.

**Review-fix resolution:** Task 5 may add the dedicated pressure history and
honest Xico-index/state presentation across `AppModel.swift`,
`MenuBarSettingsView.swift`, and focused feature tests. It may also selectively
remove only the obsolete `压力（同 iStat）` localization entry from each dirty
localization file; Task 8 will add translated copies for the replacement labels
and explanation. No other localization changes may be staged here.

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
