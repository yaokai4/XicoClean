# Task 2 Report: Resolve Application Ownership and Aggregate CPU/Memory

## Resumed-task context

This was a resumed task. A prior implementer had already written the five Task 2 files and had observed the initial missing-type RED, but was interrupted before the final review, report, and commit. The resumed work preserved those uncommitted changes, reviewed them against the complete Task 2 brief, added the missing dictionary-metadata-provider coverage, strengthened the long-gap baseline test, reran the required verification, and committed only the five scoped files.

Base: `9c9527f fix: capture every visible process`

## Implementation summary

- Added the exact application identity, member usage, aggregate usage, trend, coverage, sampling-status, CPU-display-mode, and snapshot models.
- Added deterministic ownership resolution using the outermost `.app` path, recursive parent ownership, executable-path fallback, and name fallback.
- Added an injectable `ApplicationMetadataProviding` seam and production bundle metadata lookup for bundle identifier, display name, and bundle name.
- Added monotonic, PID-reuse-safe CPU deltas that update their baseline on every capture and warm up after first, invalid, or overlong intervals.
- Added application aggregation for member CPU, physical footprint, and peak footprint, with CPU normalization capped at 100%.
- Added raw-CPU/memory ranking with the specified 3% stability band and deterministic identity tie-breaker.
- Refactored `ProcessSampler` into an actor that publishes application snapshots, preserves unknown CPU as `nil`, keeps warming CPU rankings empty while publishing memory rows, bounds trends to 60 samples for the top-20 CPU/memory union, and evicts identities absent for 120 seconds.
- Preserved temporary synchronous compatibility methods for existing consumers that are migrated by later tasks in the precision-monitoring plan.

## Files changed

- `Sources/Infrastructure/ApplicationUsageModels.swift`
- `Sources/Infrastructure/ApplicationOwnershipResolver.swift`
- `Sources/Infrastructure/ApplicationUsageAggregator.swift`
- `Sources/Infrastructure/ProcessSampler.swift`
- `Tests/IntegrationTests/ApplicationUsageAggregatorTests.swift`

The commit contains only these five files. This report remains outside the commit because the task explicitly limited the commit to those paths.

## RED

The initial RED belongs to the prior, interrupted portion of this resumed task. The prior agent ran:

```text
swift test --filter ApplicationUsageAggregatorTests
```

and observed the expected compiler failure because the tests referenced the new interfaces before their production definitions existed. The reported missing-type evidence included:

```text
error: cannot find 'ApplicationOwnershipResolver' in scope
error: cannot find 'ApplicationUsageAggregator' in scope
error: cannot find 'ProcessCPUDeltaCalculator' in scope
error: fatalError
```

No raw terminal log for that interrupted run persisted in the working tree, so these excerpts are recorded as the prior agent's observed test history rather than as a newly reproduced RED. The resumed work did not discard or revert the already-written implementation solely to recreate that compiler failure.

## GREEN

Fresh final command:

```text
swift test --filter ApplicationUsageAggregatorTests && swift test --filter MonitoringTests
```

Observed output:

```text
Test Suite 'ApplicationUsageAggregatorTests' passed.
Executed 10 tests, with 0 failures (0 unexpected)

Test Suite 'MonitoringTests' passed.
Executed 9 tests, with 0 failures (0 unexpected)
```

The chained command exited successfully and exercised 19 selected XCTest cases with zero failures.

## Self-review

- Confirmed `outermostApplicationPath(in:)` selects the first path component ending in `.app`, keeping nested Chrome/Electron helpers under the outer bundle.
- Confirmed ownership precedence is own application bundle, nearest resolvable parent, `exec:<path>`, then `name:<name>`.
- Confirmed injected metadata supplies `CFBundleIdentifier`-based identity and display name, with bundle filename fallback when metadata is absent; a dictionary fake now covers this path and parent inheritance.
- Confirmed CPU baselines update before every early return, including first, non-monotonic, and overlong captures; the strengthened long-gap test verifies the next capture computes from the overlong capture rather than an older baseline.
- Confirmed process identity includes PID and start time, so PID reuse cannot inherit prior CPU time, and decreasing cumulative CPU values are omitted rather than producing negative rates.
- Confirmed aggregation sums member raw CPU, current physical footprint, and peak footprint; normalized CPU is `min(100, raw / logicalCPUCount)`.
- Confirmed unknown CPU remains `nil`, a warmup snapshot has current memory rows and no CPU rows, and CPU display mode does not participate in ranking.
- Confirmed stable ranking uses raw CPU or memory, immediately follows metric order outside the 3% band, and uses previous visible order plus application identity inside the band.
- Confirmed `combinesProcesses: false` produces one usage row per process identity.
- Confirmed trends are selected before the caller-visible `limit`, cover the union of top 20 CPU and top 20 memory rows, cap CPU and memory arrays independently at 60, and retain absent identities only until the 120-second eviction threshold.
- Confirmed the actor serializes CPU baselines, ranking history, and trend cache mutations while the provider remains asynchronously injectable.
- Ran the exact required focused aggregation and monitoring test command after the final test edits.
- Ran `git diff --cached --check` before commit and inspected the complete staged diff and staged path list.
- Confirmed no unrelated pre-existing user changes were staged or committed.

## Concerns

No unresolved concerns.

The legacy synchronous `sample(top:)` and `memoryFootprint(pid:)` compatibility adapter intentionally remains until later plan tasks migrate existing feature consumers to the new asynchronous application snapshot API.

## Fix Review

### Review findings addressed

- Replaced the non-transitive pairwise hysteresis comparator with deterministic stable topological ordering. Metric differences greater than 3% become mandatory acyclic edges; previous visible order and identity select among rows that are not currently constrained by those edges.
- Added a FIFO async sampling permit around the complete `ProcessSampler.sample(...)` operation, including `await provider.capture()`, so concurrent calls cannot apply capture 2 before capture 1 and move CPU baselines or trends backward.
- Reworked the synchronous compatibility sampler to capture monotonic `ProcessCapture` values and use `ProcessCPUDeltaCalculator`/`ProcessIdentity`. Unknown first, reused-PID, and overlong-gap CPU values are omitted from `byCPU`, while memory rows remain available to existing callers.
- Separated representative-root selection from member ordering. Representatives are selected explicitly from records whose parent is outside the application group; members use hierarchy depth and deterministic process identity rather than a mixed parent/PID comparator.

### Changed files

- `Sources/Infrastructure/ApplicationUsageAggregator.swift`
- `Sources/Infrastructure/ProcessSampler.swift`
- `Tests/IntegrationTests/ApplicationUsageAggregatorTests.swift`

No other Task 2 or unrelated user files changed in the review-fix commit. This report remains outside the commit because the task continues to restrict commits to the five Task 2 paths.

### Regression evidence

- The three-item ranking regression initially produced different outputs for different input permutations, including `[a, c, b]` and `[c, b, a]`; the latter also placed 96 before 100 despite a difference above the 3% band.
- The delayed concurrent provider initially produced the older trend as `[450000000, 400000000]` and left the newer snapshot in `warmingUp`, proving that actor reentrancy had applied captures out of order.
- The compatibility tests initially failed at the hard-wired legacy capture boundary; the new injected synchronous capture seam then exercised first-sample unknown CPU, PID reuse, long-gap warmup, and post-gap baseline recovery through the public `sample(top:)` wrapper.
- The root/child/grandchild permutations initially selected PID 10 or 20 as representative and produced `[10, 30, 20]` or `[20, 10, 30]` member order instead of the root-first hierarchy.

### Final GREEN

Exact command:

```text
swift test --filter ApplicationUsageAggregatorTests && swift test --filter MonitoringTests
```

Observed output counts:

```text
Test Suite 'ApplicationUsageAggregatorTests' passed.
Executed 15 tests, with 0 failures (0 unexpected)

Test Suite 'MonitoringTests' passed.
Executed 9 tests, with 0 failures (0 unexpected)
```

The chained command exited successfully and exercised 24 selected XCTest cases with zero failures.

### Fix self-review

- Confirmed the hysteresis graph can only point from a known higher metric to a lower metric, or from known CPU to unknown CPU, so mandatory edges are acyclic; Kahn ordering therefore returns every row exactly once.
- Confirmed every pair outside the 3% band creates a mandatory metric edge, while the ready-queue priority deterministically uses prior visible index, application identity, and original index.
- Ran all six permutations of the `A=100, B=98, C=96` cycle five times and confirmed the same `[B, A, C]` order while preserving mandatory `A` before `C` precedence.
- Confirmed the sampling permit is acquired before provider capture and released with `defer`; queued samples resume FIFO while `sampleInProgress` stays true during handoff.
- Confirmed the delaying-provider regression forces the old implementation to complete the newer capture first and now observes ordered warmup/live snapshots with trends `[400000000]` then `[400000000, 450000000]`.
- Confirmed the legacy compatibility path holds one lock across capture, CPU baseline mutation, and row construction; it uses PID plus start time and updates the baseline even when an interval is overlong.
- Confirmed legacy memory rankings remain available during CPU warmup, but `byCPU` does not publish fabricated zeroes for first samples, reused PIDs, or long gaps.
- Confirmed representative selection is independent of member sorting, hierarchy depth is cycle-safe, and PID/start/name/path provide deterministic ordering within a depth.
- Ran all six input permutations of a root PID 30 → child PID 20 → grandchild PID 10 hierarchy and confirmed representative 30 with member order `[30, 20, 10]`.
- Inspected the complete scoped diff and confirmed the review fixes touch only three of the allowed five Task 2 files.

### Fix concerns

No unresolved concerns.
