# Task 4 Report: Publish Honest Sampling State Through AppModel

## Status

Complete. Task 4 was implemented with test-first RED/GREEN evidence, selectively staged, and committed on `codex/precision-monitoring`.

Commit: `f948187 feat: publish live application sampling state`

## RED evidence

1. After adding the lifecycle tests first, `swift test --filter MetricsGatingTests` failed with exit 1 for the intended missing APIs:
   - `AppModel` had no member `shouldResetProcessBaseline`.
   - `ProcessSamplingStatus` had no member `from`.
   - `ApplicationUsageSnapshot` had no member `effectiveStatus`.
2. The preference-default test was also added before `MonitoringPreferences.swift`. Its RED build reported `cannot find 'MonitoringPreferences' in scope`.
3. That build exposed a prior-task dependency-order issue: synthesized memberwise initializers for `ProcessCoverage`, `ApplicationUsageSnapshot`, and `ProcessUsage` were internal. The controller explicitly authorized minimal public initializers in the two Infrastructure files; no other Infrastructure behavior changed.

## GREEN verification

Fresh pre-commit command:

```text
swift test --filter MetricsGatingTests && swift test --filter ApplicationUsageAggregatorTests
```

Result:

- `MetricsGatingTests`: 7 executed, 0 failures.
- `ApplicationUsageAggregatorTests`: 15 executed, 0 failures.
- Both SwiftPM builds completed successfully, including affected `Features`, `MenuPanels`, and `XicoApp` compilation.
- `git diff --cached --check`: clean before commit.

## Committed files and hunks

- `Sources/Features/AppModel.swift`
  - Added coverage-to-status mapping and unavailable/warming/stale snapshot helpers.
  - Made `MetricsFeed.applicationUsage` the sole stored application-ranking state.
  - Added application-level forwarding arrays plus controller-approved, computed `ProcessUsage` compatibility projections for existing menu rows; no duplicate PID arrays are stored.
  - Added hidden-to-visible baseline transition logic and `prepareApplicationSampling()`.
  - Replaced synchronous legacy process enumeration with utility-priority detached async sampling.
  - Preserved AppModel single-flight gating and skipped all process sampling when no detail consumer is visible.
  - Applied the complete application snapshot atomically in `applyMetrics` and replaced the two list fields in `MetricsSample` with one optional snapshot.
- `Sources/XicoApp/MenuBarController.swift`
  - Calls preparation before changing `metricsDetailConsumerVisible` to true.
- `Sources/Features/MonitoringPreferences.swift`
  - Added only process limit and process-combining preferences.
  - Process limit accepts `4`, `6`, `10`, or `20`; missing/invalid values use `6`.
  - Combining defaults to `true` when the key is absent.
- `Tests/FeatureTests/MetricsGatingTests.swift`
  - Added lifecycle, coverage threshold, staleness, and preference-default coverage.
- `Sources/Infrastructure/ApplicationUsageModels.swift`
  - Controller-authorized public initializers for `ProcessCoverage` and `ApplicationUsageSnapshot` only.
- `Sources/Infrastructure/ProcessSampler.swift`
  - Controller-authorized public `ProcessUsage` initializer only, needed for the temporary computed compatibility projection.

## Dirty-worktree preservation evidence

- `AppModel.swift` and `MenuBarController.swift` were already modified before Task 4; their initial diffs were recorded before editing.
- Neither dirty file was staged wholesale. Task-specific zero-context patches were applied directly to the index.
- Immediately before commit, both files showed `MM`: Task 4 hunks staged and unrelated user hunks still unstaged.
- The cached diff contained exactly the six files listed above. It excluded the pre-existing Combine snapshot publisher/manual publishing, menu image update optimization, capacity reuse, offline-render licensing bypass, scan prewarming, and safe UTF-8 changes.
- Immediately after commit, `git status --short` still reports:

```text
 M Sources/Features/AppModel.swift
 M Sources/XicoApp/MenuBarController.swift
```

  This confirms the pre-existing user edits remain in the working tree and were not included in `f948187`.

## Concerns and handoff notes

- Existing `MenuPanels` still consumes `[ProcessUsage]`. Per controller direction, Task 4 keeps it buildable through computed compatibility projections while exposing `applicationTopByCPU` and `applicationTopByMemory`. Task 7 should migrate the menu rows and remove the compatibility surface.
- The preserved user changes provide the coalesced `MetricsFeed.publish(...)` path referenced by the Task 4 design. They remain intentionally uncommitted by this task.
- No Task 5+ UI, memory semantics, settings UI, or inspector work was included.

## Review-fix follow-up

Commit: `96be1c2 fix: serialize application sampling lifecycle`

### Findings and root causes

- Production `AppModel` constructed a local-only sampler, so the helper-enhanced hybrid capture path was never selected.
- `ProcessSampler.resetBaseline()` could run while an actor method was suspended in provider capture. Actor reentrancy therefore allowed a reset to split an in-flight sample instead of acting as a FIFO barrier.
- AppModel had no sampling generation, so a result started before a visibility reset could overwrite the new warming state. Reset completion also did not request an immediate replacement sample.
- Menu card preparation and visibility were set after SwiftUI hosting construction, and card-to-card switches briefly published a false hidden transition.
- Coverage divided by every enumerated PID, allowing normal exited-process churn to reduce coverage as though access had been denied.

### TDD evidence

The review tests were added before production fixes.

- `MetricsGatingTests` initially failed to compile because `ApplicationSamplingLifecycle` did not exist. After that seam was introduced, the exited-churn assertion remained RED at `0.89` instead of `1.0`.
- `ApplicationUsageAggregatorTests.testResetWaitsForInFlightSampleAndPrecedesNextSample` initially observed the in-flight sample as `warmingUp` and the post-reset sample as `live`, proving that reset had crossed the suspended capture.
- `HelperProcessSamplingTests` initially failed to compile because `ProcessSampler.production(...)` did not exist.

### Fixes

- Added an injectable production sampler factory backed by `HybridProcessSnapshotProvider`; AppModel now defaults to that factory.
- Put reset operations through the same FIFO permit as sampling.
- Added AppModel lifecycle generations, stale-result rejection, reset readiness gating, and immediate/deferred refresh after reset completion. No application enumeration begins while the reset barrier is pending.
- Moved preparation and visibility ahead of hosting-controller construction. Click and hover card switches keep detail visibility continuously true.
- Excluded exited churn from the coverage denominator while keeping denied processes in it, with zero safety and clamping.

### Final GREEN verification

- `swift test --filter MetricsGatingTests`: 10 executed, 0 failures.
- `swift test --filter ApplicationUsageAggregatorTests`: 16 executed, 0 failures.
- `swift test --filter HelperProcessSamplingTests`: 3 executed, 0 failures.
- `swift build`: succeeded for the affected working tree.
- A clean materialization of the staged index completed a full SwiftPM build and reran `MetricsGatingTests`: 10 executed, 0 failures. This verified that the commit does not depend on preserved unstaged changes.
- `git diff --cached --check`: clean before commit.

### Commit scope and preservation

The fix commit contains seven files: the two selectively staged AppModel/menu files, two Infrastructure files, and three focused test files. Immediately after commit, `AppModel.swift` and `MenuBarController.swift` remain modified in the working tree, confirming their unrelated pre-existing edits were preserved and excluded. Existing compiler warnings in untouched code were observed during the clean staged build; no new test or build failures remain.

## Second review-fix follow-up

Commit: `da20fe0 fix: reject stale application sampling epochs`

### Remaining root causes

- Menu visibility transitions still compared only the card flag. Opening a card while the main window was already visible therefore looked like hidden-to-visible and reset the process baseline unnecessarily.
- AppModel rejected obsolete results only when publishing. A request carrying an old UI generation could still reach `ProcessSampler` after a reset, capture processes, and advance the newly reset CPU baseline before its result was discarded.

### RED evidence

- `swift build --target FeatureTests` failed on the intentionally missing aggregate transition seam, lifecycle baseline epoch, and reset epoch parameter.
- `swift test --filter MetricsGatingTests` also compiled the integration target and failed on the intentionally missing `sample(requiringBaselineEpoch:)` overload and the reset method still returning `Void`.
- Test-harness actor reads were moved outside XCTest autoclosures before recording RED, leaving the missing production APIs as the expected failures.

### Fixes

- AppModel now owns card visibility changes through `setMetricsDetailConsumerVisible(_:)`. It evaluates aggregate visibility before and after changing the card flag and prepares only on aggregate hidden-to-visible.
- Menu show, close, and `windowWillClose` paths use that method. Preparation still precedes hosting-view construction, while click and hover card switches keep the card flag continuously true.
- `ProcessSampler` now owns a monotonic baseline epoch. Its FIFO reset clears CPU state, advances the epoch, and returns it.
- The epoch-aware sample overload acquires the FIFO permit, rejects mismatched epochs immediately, and only then performs provider capture and CPU-delta mutation. The compatibility sample API remains unchanged.
- AppModel stores the epoch accepted by the current lifecycle generation, supplies both UI generation and sampler epoch with each request, and treats an obsolete nil result as non-publishable while the current reset completion drives immediate or deferred refresh.

### Final GREEN verification

- `swift test --filter MetricsGatingTests`: 11 executed, 0 failures.
- `swift test --filter ApplicationUsageAggregatorTests`: 17 executed, 0 failures.
- `swift test --filter HelperProcessSamplingTests`: 3 executed, 0 failures.
- `swift build`: succeeded.
- The continuation-gated stale request produced no provider capture; capture count stayed at one. The first accepted post-reset sample was `warmingUp`, the next was `live`, and total capture count reached three.
- `git diff --cached --check`: clean before commit. The cached diff was manually audited in full and contained exactly five permitted files.

### Preservation

AppModel and MenuBarController were selectively staged with interactive hunk splitting where Task 4 changes touched the same larger diff as unrelated user work. Both files were `MM` before commit and remain modified afterward; the pre-existing Combine publisher, menu rendering, capacity reuse, offline-render licensing, scan prewarming, and safe UTF-8 edits were excluded. A second clean staged materialization was not run because the cached diff was self-contained and the requested working-tree focused suites plus full build had just completed; the previous follow-up already established the clean-materialization workflow.
