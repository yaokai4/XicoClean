# Task 5 Report: Trustworthy Memory Semantics

## Result

- Commit: `063b175` (`fix: define trustworthy memory pressure semantics`)
- Branch: `codex/precision-monitoring`
- No compatibility alias was added for `memoryPressurePercent`.
- `rg -n 'memoryPressurePercent' Sources` returned no matches before commit.

## Strict RED / GREEN Evidence

### RED 1: pure memory APIs

Added `Tests/IntegrationTests/MemoryMetricsTests.swift` first, then ran:

```text
swift test --filter MemoryMetricsTests
```

The build failed for the intended missing APIs:

```text
cannot find 'MemoryPageCounts' in scope
cannot find 'MemoryBreakdown' in scope
cannot find 'MemoryPressureIndex' in scope
```

After adding the pure implementation, the focused suite passed 3/3 tests.

### RED 2: pressure-consumer swap gate

Added the swap-gating test before the gating helper, then reran the focused suite. The build failed for the intended reason:

```text
type 'LiveMetricsSampler' has no member 'shouldSampleSwap'
```

After implementing and wiring the helper, the focused suite passed 4/4 tests.

### Final requested verification

Ran the requested sequence fresh before committing:

```text
swift test --filter MemoryMetricsTests && swift test --filter MonitoringTests && swift build
```

Results:

- `MemoryMetricsTests`: 4 tests, 0 failures.
- `MonitoringTests`: 9 tests, 0 failures.
- `swift build`: exit 0 (`Build complete!`).
- `git diff --cached --check`: clean.

## Exact Semantics and Formulae

`MemoryBreakdown.calculate(...)` uses page counts as follows:

```text
applicationPages = max(0, internalPages - purgeablePages)
applicationBytes = applicationPages * pageSize
wiredBytes       = wiredPages * pageSize
compressedBytes  = compressorPages * pageSize
cachedBytes      = (externalPages + purgeablePages) * pageSize
usedBytes        = applicationBytes + wiredBytes + compressedBytes
availableBytes   = max(0, totalBytes - usedBytes)
```

Cached memory is deliberately excluded from `usedBytes` and therefore remains inside `availableBytes`.

`MemoryPressureIndex.score(...)` clamps every contribution and the final score to `0...1`:

```text
kernel      = 1 - clamp(kernelAvailableLevel / 100), or 0 when unavailable
stateFloor  = 0.85 for pressure state 4; 0.60 for state 2; otherwise 0
availability = clamp((0.20 - availableFraction) / 0.20) * 0.55
compression  = clamp(compressedFraction / 0.35) * 0.25
swap         = clamp(swapFraction) * 0.20
score        = clamp(max(kernel, stateFloor, availability + compression + swap))
```

`SystemSnapshot.memoryAvailable` is sampled explicitly from the pure breakdown. `SystemSnapshot.memoryPressureIndex` replaces the ambiguous percent property and is `nil` only when VM statistics are invalid or total memory is unavailable. `memoryPressureFraction` is documented and retained only as the normal/warning/critical three-state fallback for the detail pressure ring. The menu-bar pressure glyph uses `memoryPressureIndex ?? memoryUsedFraction`, never the three-state fallback.

Swap is sampled when a detail consumer is visible or when the enabled memory menu glyph is configured for pressure. Hidden steady state skips swap only when no pressure consumer needs it. The pure gate test covers visible, pressure, used-only, and disabled-glyph cases.

## Committed Files and Hunks

- `Sources/Infrastructure/MemoryMetrics.swift` (new): pure page-count, breakdown, and bounded pressure-index APIs.
- `Sources/Infrastructure/LiveMetrics.swift`: explicit snapshot fields; three-state fallback documentation; pressure-aware swap gate; pressure-index binding; pure VM breakdown; raw `kern.memorystatus_level` availability reader.
- `Sources/XicoApp/MenuBarController.swift`: only the pressure metric hunk, using `memoryPressureIndex ?? memoryUsedFraction`.
- `Sources/Features/MenuPanels.swift`: authorized minimal scope expansion for the two tracked `memoryPressurePercent` use sites, plus the adjacent semantics comment; no Task 7 layout work.
- `Tests/IntegrationTests/MemoryMetricsTests.swift` (new): category math, state floor/kernel contribution, bounds, and swap-gate tests.

The commit contains exactly those five tracked files. `Sources/XicoApp/PerformanceProbe.swift` is not in the commit.

## Dirty-Worktree Preservation

Initial recorded diffs before Task 5 edits:

- `Sources/Infrastructure/LiveMetrics.swift`: 66 insertions / 9 deletions, covering pre-existing sampling/capacity/interface optimizations.
- `Sources/XicoApp/MenuBarController.swift`: 8 insertions / 5 deletions, covering the pre-existing snapshot publisher and image-cache update path.

Both files were staged interactively by hunk. The pre-existing capacity cache, per-core/disk/load/GPU/temperature/battery gates, combined-glyph helper, disk baseline reset, interface string conversion, publisher subscription, and image identity optimization remain unstaged in the working tree. The only overlap was the pre-existing `needSwap = consumerVisible` line, which Task 5 intentionally replaced with the explicitly authorized pressure-consumer gate. After commit, the remaining unstaged diffs are:

- `Sources/Infrastructure/LiveMetrics.swift`: 64 insertions / 8 deletions.
- `Sources/XicoApp/MenuBarController.swift`: 8 insertions / 5 deletions.

No unrelated user file was staged or reverted.

## Untracked Performance Probe Handling

`Sources/XicoApp/PerformanceProbe.swift` was a pre-existing untracked user file. Only its single pressure-field reference was updated in the working tree:

```text
memoryPressurePercent -> memoryPressureIndex
```

All other probe content was preserved. The file remains untracked and was not added or committed. The cached commit tree contains neither `probeMetricsPerformance` nor a dependency on this untracked file.

## Concerns / Follow-up Boundary

- The current legacy memory panel now reads the Xico index correctly, but its full visible “Xico 压力指数” product labeling and the switch to `SystemSnapshot.memoryAvailable` are part of the planned Task 7 panel redesign; no Task 7 work was started here.
- Swap totals are intentionally zero in hidden snapshots when no pressure consumer exists. Any future hidden consumer of `memoryPressureIndex` must join the same sampling gate rather than assuming swap was sampled.

---

## Review Fix Follow-up

### Commit

- `cd464bd` — `fix: align memory pressure presentation and history`

### Review findings resolved

1. **Honest labeling and accessibility**
   - Added canonical presentation copy with the exact numeric name `Xico 压力指数` and separate state name `内存压力`.
   - Settings now describe the index as combining memory-pressure state, available memory, compression, and swap, and explicitly state that it is not a macOS-provided percentage.
   - The memory panel exposes the index percentage and the normal/warning/critical memory-pressure state as separate visible and accessibility values.
   - Removed the obsolete `压力（同 iStat）` entry from all 11 localization files. No composite-index UI or comment claims that the number is a raw kernel/iStat percentage.

2. **Correct pressure-mode history**
   - Added `MetricsFeed.memoryPressureHistory` and the AppModel forwarding property.
   - Each frame pushes `memoryPressureIndex ?? memoryUsedFraction` through the existing capped `push` helper.
   - `MetricsFeed.memoryHistory(for:)` selects pressure history for the default/`pressure` mode and usage history only for `used`.
   - `MenuBarController` now sends the selected metric's matching history to `MenuBarGlyph.memory`.

3. **Safe public arithmetic boundary**
   - `MemoryBreakdown.calculate` clamps negative totals, page size, and page counts to zero.
   - Application-page subtraction is guarded to avoid underflow.
   - Page addition, byte multiplication, and used-byte addition saturate at `Int64.max` instead of trapping.
   - Available subtraction is performed only when `totalBytes > usedBytes`.

### Review RED / GREEN evidence

The copy/history tests were written first in `MetricsGatingTests`.

RED failed on the intended missing APIs:

```text
cannot find 'MemoryPressureDisplayCopy' in scope
value of type 'MetricsFeed' has no member 'memoryPressureHistory'
value of type 'MetricsFeed' has no member 'memoryHistory'
```

After the minimal implementation, `MetricsGatingTests` passed 13/13.

The extreme/negative arithmetic tests were written before the safe implementation. The RED run reproduced the public-API bug directly:

```text
xctest exited with unexpected signal code 5
testBreakdownSaturatesAtInt64MaxWithoutOverflowing
```

After nonnegative/saturating arithmetic was added, `MemoryMetricsTests` passed 6/6.

### Final review verification

Ran fresh before the review-fix commit:

```text
swift test --filter MemoryMetricsTests
swift test --filter MetricsGatingTests
swift test --filter MonitoringTests
swift build
rg -n 'memoryPressurePercent|压力（同 iStat）|kern\.memorystatus_level.*iStat' Sources
```

Results:

- Memory metrics: 6 tests, 0 failures.
- Metrics gating/copy/history selection: 13 tests, 0 failures.
- Monitoring regressions: 9 tests, 0 failures.
- Full build: exit 0.
- Misleading-reference scan: no matches.
- `git diff --cached --check`: clean before commit.

### Selective staging and dirty-worktree preservation

- `Sources/Features/AppModel.swift`: staged only the pressure-history storage, selector, forwarding, and capped per-frame push. The pre-existing Combine/publishing, sampling, capacity, scan-index, offline-render, and identity changes remain in the working tree. The staged tree uses `@Published` to match the committed MetricsFeed style; the dirty working-tree optimization consistently removes it along with the other pre-existing publisher removals.
- `Sources/Features/MenuBarSettingsView.swift`: staged only the pressure name/help block. The three pre-existing custom-toggle hunks remain unstaged (3 insertions / 3 deletions).
- `Sources/XicoApp/MenuBarController.swift`: staged only the metric/history selection hunk. The pre-existing snapshot-publisher and image-identity hunks remain unstaged (8 insertions / 5 deletions).
- Localization scope was explicitly expanded to delete exactly one obsolete key per locale. Cached resource audit showed `0 insertions / 1 deletion` in each of the 11 files; every file's pre-existing localization additions remain unstaged (109 insertions per locale after commit).
- `Sources/XicoApp/PerformanceProbe.swift` remains untracked and was not committed.

### Remaining boundary

Task 8 will add professional translations for the new index label and explanatory copy. Until then `xLoc` safely falls back to the canonical source-language strings; no obsolete or misleading translation key remains.

---

## Complete-Input Follow-up

### Commit

- `835aaad` — `fix: require complete memory pressure inputs`

### Semantics fixed

1. **The composite index now requires a complete sample**
   - `SystemSnapshot.memoryPressureIndex` is `nil` when VM memory data is invalid, swap sampling was intentionally skipped, or the swap sysctl failed.
   - `sampleSwap` now returns an explicit validity bit. A successful sysctl result with `swapTotal == 0` is still valid and scores with a zero swap fraction; a failed read is not silently treated as zero swap.
   - `hasCompleteSwapSample` and `pressureIndexForSample` are pure internal seams used directly by the sampler and tests.
   - The snapshot field documentation now states that `nil` also means required inputs are incomplete.

2. **Pressure history contains only complete Xico indices**
   - `MetricsFeed.recordMemoryPressureIndex` rejects `nil`, preserves existing valid points, and applies the requested cap.
   - `AppModel.applyMetrics` no longer appends `memoryUsedFraction` as a pressure-history fallback.
   - The glyph's current-value fallback remains unchanged (`memoryPressureIndex ?? memoryUsedFraction`), so a used-to-pressure transition can temporarily show used memory while its pressure graph remains empty until a fresh complete index arrives.

### RED / GREEN evidence

Tests were added before each production change.

Initial RED failures:

```text
type 'LiveMetricsSampler' has no member 'pressureIndexForSample'
value of type 'MetricsFeed' has no member 'recordMemoryPressureIndex'
```

The review tightening for failed swap reads had its own RED:

```text
type 'LiveMetricsSampler' has no member 'hasCompleteSwapSample'
```

GREEN coverage proves:

- memory-valid + swap skipped => no index;
- memory-valid + swap requested but sysctl-invalid => no index;
- memory-valid + successful zero-total swap sample => index;
- used-mode incomplete samples add no pressure point;
- switching to pressure exposes no incomplete history;
- the first complete pressure index appears and is selected;
- nil recording preserves historic valid points, and overflow drops only the oldest point.

### Final verification

Fresh commands on the final implementation:

```text
swift test --filter MemoryMetricsTests
swift test --filter MetricsGatingTests
swift test --filter MonitoringTests
swift build
git diff --cached --check
```

Results:

- Memory metrics: 7 tests, 0 failures.
- Metrics gating/history transition: 15 tests, 0 failures.
- Monitoring regressions: 9 tests, 0 failures.
- Full build: exit 0.
- Cached diff check: clean.

### Selective staging and dirty-worktree preservation

The commit contains exactly these four allowed files:

- `Sources/Infrastructure/LiveMetrics.swift`
- `Sources/Features/AppModel.swift`
- `Tests/IntegrationTests/MemoryMetricsTests.swift`
- `Tests/FeatureTests/MetricsGatingTests.swift`

The two dirty production files were staged through a task-only cached patch. Pre-existing Combine/publishing, sampling/capacity, scan-index, offline-render, identity, per-core/disk/load, combined-glyph, and interface-conversion work remains unstaged. After the commit, their combined remaining working-tree diff is 146 insertions / 52 deletions. `Sources/XicoApp/PerformanceProbe.swift` remains untracked and was not staged or committed.
