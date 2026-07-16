# Task 8 Report — Localization, Accessibility, and Focused Screenshot QA

## Scope

- Completed the approved 20-key Precision Monitoring inventory in all 11 locales.
- Replaced the 14 Task 6 source-language placeholders with professional native translations.
- Added deterministic accessibility composition for application rows, sampling pills, gauges, and charts.
- Added a focused `Xico --monitoring-shots` renderer for live and deterministic degraded states.
- Kept unrelated pre-existing worktree changes unstaged through index-only selective staging.

## TDD Evidence

### Localization

1. Added the exact 20-key inventory, locale parity, format-specifier, and no-source-placeholder tests.
2. Confirmed RED: `LocalizationCoverageTests` reported the missing inventory and the 14 untranslated Task 6 placeholders.
3. Added all translations while preserving `%d` and `%%` exactly.
4. Confirmed GREEN: `LocalizationCoverageTests` passes 6/6.

### Accessibility and Fixtures

1. Added presentation tests for VoiceOver ordering, status-plus-coverage composition, chart latest-value labels, and deterministic fixtures.
2. Confirmed RED for the missing `ApplicationUsageAccessibility` surface.
3. Implemented the pure presentation layer and deterministic DEBUG fixture.
4. Confirmed GREEN: `ApplicationUsagePresentationTests` passes 20/20.

### Offline Renderer Startup

1. The first CLI render hung before `AppDelegate` while the SwiftUI app initialized Keychain licensing state.
2. Added a failing regression test for `AppModel.isOfflineRender(["--monitoring-shots"])`.
3. Added the monitoring flag to the existing offline-render launch classification, keeping normal app launches unchanged.
4. Confirmed the renderer starts, builds, and exits successfully.

## Delivered Behavior

- Application rows are a single accessibility element whose value reads name, process count, CPU state/value, then memory value.
- Sampling pills expose state and coverage together.
- Gauges and charts expose concise labels plus their latest value; decorative fills, strokes, and glows are hidden from VoiceOver.
- Changing numeric columns use monospaced digits.
- Memory history uses the existing application snapshot timestamp as its cadence and records the initial live frame on appearance; it has no dependency on the separate unstaged publisher optimization.
- `renderMonitoringShots()` attaches each view to a real off-screen `NSWindow`.
- Live shots call `prepareApplicationSampling()`, refresh metrics, start the metrics timer, and wait 2.4 seconds (at least two one-second sampling intervals).
- Warming and partial shots use deterministic injected fixtures and settle for only 0.35 seconds.
- The renderer writes exactly six files under `/tmp/xico-monitoring-shots`.

## Screenshot QA

All six files exist, are non-empty, and were inspected at original resolution:

- `cpu-dark.png` — 672×1472, 433,978 bytes
- `cpu-light.png` — 672×1472, 188,894 bytes
- `memory-dark.png` — 672×1640, 222,259 bytes
- `memory-light.png` — 672×1640, 229,177 bytes
- `cpu-warming-dark.png` — 672×1040, 112,345 bytes
- `memory-partial-dark.png` — 672×1640, 243,180 bytes

Visual acceptance at 336 pt passed:

- No clipped text; the memory history selector keeps `交换区` on one line.
- CPU has no GPU primary block; memory has no CPU primary block.
- Every application row shows both CPU and memory columns.
- Light and dark contrast is legible.
- Warming explicitly shows `采样中` with unknown CPU values and real memory values.
- Partial explicitly shows `部分数据` with 76% coverage.

## Verification

- `swift test --filter LocalizationCoverageTests` — PASS (6/6)
- `swift test --filter ApplicationUsagePresentationTests` — PASS (20/20)
- `swift test --filter MetricsGatingTests` — PASS (24/24)
- `swift build` — PASS
- Build from an archive of the exact staged Git tree — PASS
- `.build/debug/Xico --monitoring-shots` — PASS
- Exact staged-tree executable `Xico --monitoring-shots` — PASS; exactly 6/6 non-empty PNGs, with warming/partial states re-inspected.
- `git diff --cached --check` — PASS
- `git diff --check` — PASS

## Selective-Staging Audit

- Staged localization changes contain exactly the 33 expected unique keys: the 20-key inventory plus the 14-key Task 6 debt, with `采样中` shared by both sets.
- `AppModel.swift`, `MenuPanels.swift`, `LiveShotRenderer.swift`, and `XicoApp.swift` were staged through index-only blobs so unrelated worktree features remain outside this commit.
- Existing unrelated changes in the 11 localization files were also preserved unstaged.

## Task 9 Accuracy Follow-up

The live memory screenshots show application aggregate footprints that can exceed `SystemSnapshot.memoryApp` (for example, ChatGPT around 8.7 GiB while the system application-memory bucket is around 3.45 GiB). Task 9 must explicitly verify and explain the difference between process physical-footprint aggregation and macOS system memory-category accounting before accuracy acceptance.

## Commit

- `c13bb9c` — `test: cover precision monitoring presentation`
