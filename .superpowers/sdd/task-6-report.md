# Task 6 Report: Monitoring Preferences and Application Usage Presentation

## Result

Implemented and committed as `2555d99d0e48e11ca6141bad3ca2aa579eb22600`
(`feat: configure application monitoring presentation`).

Reviewer follow-up committed as
`6bc84577ebe89848ff59cee3294b29cb1253c688`
(`fix: validate monitoring refresh intervals`).

Final review coverage committed as
`2fcccbce592e607f63f88590121724242b864778`
(`test: cover nonfinite refresh migration`).

## RED

- Added `Tests/FeatureTests/ApplicationUsagePresentationTests.swift` before production code.
- `swift test --filter ApplicationUsagePresentationTests` failed because
  `ApplicationUsageRowPresentation`, `ApplicationUsageFocus`, `MemoryUnitStyle`,
  and `formattedMemory(style:)` did not exist.
- Extended `MetricsGatingTests` first; its RED compile also proved that the
  canonical public preference keys, typed accessors, and injectable
  `UserDefaults` reads were absent.
- For the reviewer follow-up, added refresh-interval tests before production
  code. `swift test --filter MetricsGatingTests` failed to compile because
  `MonitoringRefreshInterval`, `MonitoringPreferences.refreshIntervalKey`, and
  the typed refresh accessor did not exist.

## GREEN

- `swift test --filter ApplicationUsagePresentationTests`: 6 tests, 0 failures.
- `swift test --filter MetricsGatingTests`: 18 tests, 0 failures.
- `swift test --filter LocalizationCoverageTests`: 3 tests, 0 failures.
- `swift build`: exit 0.
- `git diff --cached --check`: exit 0 before commit.

Reviewer follow-up verification:

- `swift test --filter MetricsGatingTests`: 22 tests, 0 failures.
- `swift test --filter ApplicationUsagePresentationTests`: 6 tests, 0 failures.
- `swift test --filter LocalizationCoverageTests`: 3 tests, 0 failures.
- `swift build`: exit 0.
- `git diff --cached --check`: exit 0 before commit.

Final review verification:

- `swift test --filter MetricsGatingTests`: 23 tests, 0 failures.
- `swift build`: exit 0.
- `git diff --cached --check`: exit 0 before commit.

The presentation tests cover CPU-primary/memory-secondary ordering,
memory-primary/CPU-secondary ordering, unknown CPU as `采样中`, normalized and
total-core CPU display, 0...1 fill clamping, and explicit decimal/binary memory
units.

## Preference Migration

Canonical public keys are exactly:

- `xico.monitor.cpuMode`
- `xico.monitor.combinesProcesses`
- `xico.monitor.processLimit`
- `xico.monitor.density`
- `xico.monitor.memoryUnit`

Canonical values take precedence whenever present. The temporary Task 4 keys
`xico.monitoring.combinesProcesses` and `xico.monitoring.processLimit` are read
only when their canonical counterparts are absent. Reads do not write or delete
either key. Tests use unique `UserDefaults` suites and remove their persistent
domains deterministically.

Defaults are normalized CPU, combined processes, 6 rows, balanced density, and
binary memory units. Allowed row counts are 4, 6, 10, and 20.

## UI Controls

CPU and memory item details now share controls for CPU scale, process grouping,
row count, density, and memory unit. The bindings use canonical `@AppStorage`
keys while their initial values preserve legacy Task 4 choices. Changing process
grouping calls `model.prepareApplicationSampling()`; the other presentation
preferences are persisted for the next rendered frame. Global refresh options
are exactly 1, 2, and 5 seconds.

All newly introduced user-facing labels and accessibility labels pass through
`xLoc`. The 14 canonical source keys were added to every locale as source-value
placeholders to keep localization key parity green; Task 8 must replace the ten
non-Simplified-Chinese placeholder values with professional translations.

## Validated Global Refresh Interval

`MonitoringRefreshInterval` is the shared typed contract for the only supported
choices: 1, 2, and 5 seconds. `MonitoringRefreshIntervalStore` owns the exact
`xico.mb.interval` key and is the production read/write boundary. A missing key
defaults to 1 second without an unnecessary write. Exact supported values are
preserved, legacy 3 seconds migrates to 2 seconds, and other finite invalid
values migrate to the nearest supported choice (with lower-value tie breaking).
Non-finite invalid values migrate to 1 second.

The final review test explicitly covers `Double.nan`, `Double.infinity`, and
`-Double.infinity`, asserting both the typed `.oneSecond` result and migration
of the persisted value to `1.0`. The `SensorReader` cache-TTL comment also now
describes the shared store's 1-second default accurately; runtime behavior was
not changed.

The settings `@AppStorage` default, typed picker binding, `AppModel` metrics
timer, and sensor-reader cache timing now consume that same validated value.
Picker tags are typed enum cases, so the selection always matches a supported
tag. Writes accept the typed enum rather than arbitrary doubles.

## Exact Committed Scope

- `Sources/Features/MonitoringPreferences.swift`: typed preferences, exact keys,
  defaults, and legacy fallback reads.
- `Sources/Features/ApplicationUsageViews.swift`: pure dual-metric row
  presentation.
- `Sources/Domain/Models.swift`: only `MemoryUnitStyle` and
  `formattedMemory(style:)`; the existing `formattedMemory` body is unchanged.
- `Sources/Features/MenuBarSettingsView.swift`: only Task 6 preference storage,
  shared CPU/memory controls, grouping reset hook, and the 1/2/5-second global
  picker.
- `Tests/FeatureTests/ApplicationUsagePresentationTests.swift`: six presentation
  and formatting tests.
- `Tests/FeatureTests/MetricsGatingTests.swift`: deterministic defaults and
  canonical/legacy migration coverage.
- Reviewer follow-up: `Sources/Infrastructure/MonitoringRefreshInterval.swift`
  plus narrowly staged refresh-interval changes in `MonitoringPreferences.swift`,
  `MenuBarSettingsView.swift`, `AppModel.swift`, `SensorReader.swift`, and
  `MetricsGatingTests.swift`.
- Eleven `Localizable.strings` files: exactly 14 insertions and 0 deletions per
  locale, with no pre-existing resource hunks staged.

## Dirty-Worktree Preservation

Before Task 6, `Sources/Domain/Models.swift` contained the user's scan evidence,
coverage, reclaimable-size, and progress changes. `MenuBarSettingsView.swift`
contained three user `XThemeSwitchStyle` substitutions. All were recorded before
editing and excluded with interactive hunk staging. After the Task 6 commit,
those hunks remain unstaged in the worktree. Pre-existing localization additions
also remain unstaged; only the 14 authorized keys per locale entered the commit.

The reviewer follow-up likewise staged only its refresh-interval hunks. Existing
`AppModel`, `XThemeSwitchStyle`, and `SensorReader` worktree changes remain
unstaged and were not included in `6bc84577ebe89848ff59cee3294b29cb1253c688`.

The final coverage commit staged only the focused test and the single stale
default-value comment line. The overlapping user `SensorReader` cache-TTL
implementation remains unstaged and was not included in
`2fcccbce592e607f63f88590121724242b864778`.

No Task 7 panel layout or application-inspector work was included.

## Concerns / Follow-up

- Task 8 must replace source-value placeholders in en, zh-Hant, ja, ko, de, fr,
  es, it, pt-BR, and ru before final delivery.
- Task 7 is responsible for consuming these preferences in the panel layouts;
  Task 6 intentionally supplies only the pure presentation contract and settings
  bindings.
