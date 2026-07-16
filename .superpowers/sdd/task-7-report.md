# Task 7 Report — Precision CPU/Memory Panels and Application Inspector

## Scope

- Added domain-neutral Precision Glass monitoring primitives in DesignSystem.
- Replaced the legacy PID-only CPU/memory menu rows with application-level dual-metric lists.
- Rebuilt CPU and memory panel hierarchy around a single primary metric.
- Added a live, identity-based application inspector presented with a native SwiftUI sheet.

## TDD Evidence

1. Added tests for CPU/memory column order and coverage copy first.
2. Confirmed RED with compile failures for missing `columnTitles` and `displayText`.
3. Added the minimal presentation APIs and confirmed GREEN (9/9 focused tests).

## Delivered Behavior

- `XMonitoringSection`: 14 pt adaptive raised surface with a one-device-pixel border and no metric-tinted card fill.
- `XSamplingStatusPill`: live green, warming blue, partial/stale amber, unavailable neutral.
- `XSemanticGauge`: explicit single metric color; CPU and memory totals never use `ringColors`.
- Application rows show 18 pt bundle icons (gear fallback), application/member count, CPU and footprint together, memory share of total RAM, and a low-opacity semantic fill.
- CPU warming is shown as `采样中`; unavailable data is a status block, not a fabricated zero.
- CPU panel has no GPU block and retains total/user/system, load, temperature, P/E frequency, per-core, uptime, and history.
- Memory panel separates kernel pressure state from `Xico 压力指数`, uses `SystemSnapshot.memoryAvailable` directly, exposes app/wired/compressed/cached/available, page rates, swap, and true pressure/compression/swap rolling histories.
- Inspector selection stores only `ApplicationIdentity`; it resolves current data from both rankings, keeps the last snapshot, confirms GUI exit via the representative PID, and does not expose terminate actions.
- Inspector shows preference CPU plus raw/normalized CPU, physical/peak footprint, 60-second CPU/memory charts, member PID/name/CPU/memory, source, sample time, and coverage.
- Balanced density now uses the specified 336 pt width; compact/detailed map to 320/380 pt.

## Verification

- `swift test --filter ApplicationUsagePresentationTests` — PASS (9/9)
- `swift test --filter MetricsGatingTests` — PASS (23/23)
- `swift build` — PASS
- `git diff --check` — PASS
- `LocalizationCoverageTests/testAllUsedKeysExistInBaseTable` — expected RED for 13 keys, all within Task 8's exact 20-key inventory; no extra Task 7 localization keys remain.

## Deferred to Task 8/9

- Add professional translations for the planned monitoring key inventory and run full localization parity.
- Render and visually inspect light/dark/warming/partial focused monitoring screenshots.
- Perform signed helper/live-machine accuracy and performance acceptance.

## Commit

- `43f66df` — `feat: add precision CPU and memory panels`

## Review Follow-up

The independent Task 7 review identified one critical window-lifecycle defect plus accuracy and
scalability findings. The follow-up implements and verifies all requested corrections:

- Attached inspector sheets are classified as card-internal AppKit windows. Parent resign-key,
  local-click, and Escape dismissal paths no longer close the card while a sheet is attached, so
  the metrics detail consumer stays visible for the complete sheet lifecycle.
- Card size and origin are clamped to the active screen visible frame. Application rows use a
  density-aware bounded scroll viewport through all supported 4/6/10/20 limits, with a flexible
  minimum and high-priority footer for constrained screens.
- Warming CPU lists fall back to current memory-ranked applications while preserving `采样中` as
  CPU primary and real footprint as the secondary value.
- Memory pressure/compression/swap histories now append atomically only when the same frame has a
  complete non-nil pressure index. Valid zero-swap frames append `0`; all three series cap at 60.
- A missing Xico pressure index renders an empty neutral gauge and `—`; the separate kernel pressure
  state remains the only state-colored signal.
- Application icons are loaded outside `body` through a path-keyed main-actor cache and
  `.task(id:)`, eliminating repeated filesystem/workspace calls on every metrics tick.
- Inspector exit state is injectable and conservative: only bundle identities absent from
  `NSWorkspace` with every member PID confirmed gone become `已退出`; `kill(pid, 0)` success or
  `EPERM` counts as alive.
- CPU history headings now show the selected `HistoryWindow.title`.

### Follow-up TDD and Verification

- New tests were first observed RED for the missing narrow presentation/lifecycle APIs.
- `swift test --filter ApplicationUsagePresentationTests` — PASS (16/16)
- `swift test --filter MonitoringWindowRelationshipTests` — PASS (2/2), using a real
  `NSPanel.beginSheet(NSWindow)` relationship; no hang
- `swift test --filter MetricsGatingTests` — PASS (23/23)
- `swift build` — PASS
- `git diff --check` — PASS
- Localization coverage remains expected RED for exactly the same 13 keys, all contained in Task
  8's approved key inventory.

### Follow-up Commit

- `f62d4bd` — `fix: stabilize precision monitoring UI`.
