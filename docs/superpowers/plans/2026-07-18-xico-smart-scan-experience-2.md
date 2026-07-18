# Xico Smart Scan Experience 2.0 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the visibly dated Smart Scan home, scanning, review, execution, and terminal journey with a premium native macOS experience whose value is immediately understandable, whose motion is finite and accessible, and whose safety/result claims remain reducer-backed.

**Architecture:** Keep `SmartScanHubViewModel`, Domain reducers, scanners, and deletion ownership as the only mutable sources of truth. Add a pure immutable `SmartScanPresentationState` projection between those facts and a stable SwiftUI experience shell. Isolate navigation/discovery state in a bounded `RecentToolStore`, route recommendations through typed destinations, and render all nine journey states from deterministic DEBUG fixtures. Execute in an isolated Git worktree so the current unfinished Task 5 uninstaller/localization changes remain untouched.

**Tech Stack:** Swift 6, SwiftUI for macOS 14+, AppKit only for existing platform integrations, XCTest, Swift Package Manager, existing `DesignSystem`, existing `TaskOutcomePresentation`, `CleaningOutcomeConsumption`, and DEBUG `ImageRenderer` screenshot infrastructure.

## Global Constraints

- The design source of truth is `docs/superpowers/specs/2026-07-18-xico-smart-scan-experience-2-design.md`.
- Create branch `codex/smartscan-experience-2` in `/private/tmp/xico-smartscan-experience-2` from the exact plan commit (the committed `f721885` product baseline plus this plan only). Never implement this plan in the dirty `codex/precision-monitoring` checkout and never copy its working tree.
- Preserve every existing uncommitted Task 5 file and never add, stage, edit, delete, or move `docs/21-全量开发交接与产品差距-2026-07-18.md`.
- The clean UI worktree intentionally starts before Task 5's 18 new keys per locale. Add Smart Scan keys in a dedicated `/* Smart Scan Experience 2.0 */` section immediately before the existing `/* Task Outcome */` section, not at EOF and without reordering/regenerating the 1,600+ existing keys. After Task 5 is committed, rebase/integrate this branch and reconcile all 11 tables as key sets; never resolve a table conflict with whole-file `ours`/`theirs`. Rerun plist parsing, duplicate-key, parity, and format tests.
- Every SwiftPM command must include `--disable-automatic-resolution --skip-update`, use `--jobs 1`, and set both module caches to `/private/tmp`.
- Never run `scripts/make_app.sh`, `--selftest`, a real Trash/delete/helper/tmutil/network operation, or a scanner against the user's real home directory during this milestone.
- Production views may consume only real hub/domain/consumer facts. Synthetic facts are restricted to a `#if DEBUG` fixture and screenshot command.
- Do not add a global percentage unless normalized work units exist. Display resolved categories and per-category progress only.
- Do not display aggregate counts for an untrusted/uncertain terminal. Reuse `TaskOutcomePresentation.make(context:)`; do not invent a second outcome reducer.
- Every permanent/helper/caution/risky item defaults to unselected and requires explicit confirmation. Informational/incomplete/untrusted items are never selectable.
- All animation drivers must stop. No idle `TimelineView(.animation)`, random-per-frame `Canvas`, fake progress loop, or repeated success feedback.
- Each task ends with focused tests and an exact commit. Do not combine unrelated Task 5 files into any commit.

---

## Planner checkpoint: commit the plan without Task 5 (required before handoff)

This checkpoint is performed by the planning agent before any implementation worker starts. Stage only this plan, verify its parent is the committed product baseline, and commit it. Never stage the dirty Task 5 files or the untracked handoff document.

```bash
git add docs/superpowers/plans/2026-07-18-xico-smart-scan-experience-2.md
git diff --cached --check
test "$(git diff --cached --name-only | wc -l | tr -d ' ')" = "1"
test "$(git diff --cached --name-only)" = "docs/superpowers/plans/2026-07-18-xico-smart-scan-experience-2.md"
git commit -m "docs: plan Smart Scan Experience 2.0 implementation"
test "$(git rev-parse HEAD^)" = "$(git rev-parse f721885)"
git diff-tree --no-commit-id --name-only -r HEAD
git cat-file -e HEAD:docs/superpowers/plans/2026-07-18-xico-smart-scan-experience-2.md
```

Expected: the new commit has parent `f721885`, changes exactly this plan, and contains no Task 5 or user handoff file.

---

## Task 1: Create the isolated execution worktree and baseline gates

**Files:**

- Read: `Package.swift`
- Read: `docs/superpowers/specs/2026-07-18-xico-smart-scan-experience-2-design.md`
- Read: `docs/superpowers/plans/2026-07-18-xico-smart-scan-experience-2.md`
- Do not modify production or test files in this task.

- [ ] **Step 1: Load the required isolation skill**

Read `superpowers:using-git-worktrees` in full, then inspect ignored worktree locations and current branch state.

- [ ] **Step 2: Prove the source checkout contains user work that must remain isolated**

Run from `/Users/yaokai/Code/IT/MacApp/XicoApp`:

```bash
git status --short
git diff -- docs/21-全量开发交接与产品差距-2026-07-18.md
```

Expected: Task 5 source/tests and 11 localization tables are dirty; the handoff document is untracked; no content is altered.

- [ ] **Step 3: Create the isolated worktree**

```bash
PLAN_COMMIT="$(git rev-parse HEAD)"
test "$(git rev-parse "$PLAN_COMMIT^")" = "$(git rev-parse f721885)"
test "$(git diff-tree --no-commit-id --name-only -r "$PLAN_COMMIT" | wc -l | tr -d ' ')" = "1"
test "$(git diff-tree --no-commit-id --name-only -r "$PLAN_COMMIT")" = "docs/superpowers/plans/2026-07-18-xico-smart-scan-experience-2.md"
git worktree add -b codex/smartscan-experience-2 /private/tmp/xico-smartscan-experience-2 "$PLAN_COMMIT"
git -C /private/tmp/xico-smartscan-experience-2 status --short --branch
git -C /private/tmp/xico-smartscan-experience-2 show --stat --oneline --summary HEAD
```

Expected: branch `codex/smartscan-experience-2`, clean worktree, and this plan/spec present.

- [ ] **Step 4: Run the non-mutating baseline tests**

```bash
cd /private/tmp/xico-smartscan-experience-2
CLANG_MODULE_CACHE_PATH=/private/tmp/xico-clang-module-cache \
SWIFTPM_MODULECACHE_OVERRIDE=/private/tmp/xico-swiftpm-module-cache \
swift test --jobs 1 --filter 'LocalizationCoverageTests|TaskOutcomePresentationTests|CleaningOutcomeConsumerTests|TypeScaleTokenGuardTests' \
  --disable-automatic-resolution --skip-update
```

Expected: the selected existing FeatureTests pass. If an existing failure appears, record the exact test and do not hide it by changing an unrelated assertion.

- [ ] **Step 5: Record the baseline without a code commit**

```bash
git status --short
```

Expected: clean. This task creates the branch/worktree but no new commit.

---

## Task 2: Add pure presentation facts and explicit cancellation contracts

**Files:**

- Create: `Sources/Features/SmartScanPresentation.swift`
- Modify: `Sources/Features/SmartScanHub.swift:80-340`
- Create: `Tests/FeatureTests/SmartScanPresentationTests.swift`
- Create: `Tests/FeatureTests/SmartScanHubCancellationTests.swift`
- Create: `Tests/FeatureTests/SmartScanTestFixtures.swift`
- Reference: `Sources/Domain/Models.swift`
- Reference: `Sources/Features/CleaningOutcomeConsumer.swift`
- Reference: `Sources/Features/TaskOutcomePresentation.swift`

- [ ] **Step 1: Write failing phase-mapping tests**

Add `SmartScanPresentationTests` with these tests:

```swift
@MainActor
final class SmartScanPresentationTests: XCTestCase {
    func testIdleMapsToIdleWithoutInventingReclaimableBytes()
    func testActiveUnsettledMapsToScanningWithResolvedCategoryCount()
    func testActiveSettledMapsToReview()
    func testCleaningMapsToExecutingEvenWhenAllCategoriesAreSettled()
    func testTrustedFinishedOutcomeMapsToTerminal()
    func testFinishedWithoutTrustedConsumptionMapsToUncertainTerminal()
    func testImpossiblePhaseCombinationFailsClosedToUncertain()
}
```

Test the public pure input rather than reaching into private view state. The initial API contract is:

```swift
enum SmartScanJourneyPhase: Equatable, Sendable {
    case idle
    case scanning(resolved: Int, total: Int)
    case review(termination: ScanSessionTermination?)
    case executing(stopping: Bool)
    case terminal(SmartScanTerminalState)
}

struct SmartScanPresentationInput: Sendable {
    let hubPhase: SmartScanHubViewModel.Phase
    let categories: [SmartCategory: SmartScanCategoryFact]
    let cleaning: Bool
    let cleanCancellationRequested: Bool
    let scanTermination: ScanSessionTermination?
    let outcome: CleaningOutcomeConsumption?
}

struct SmartScanPresentationState: Equatable, Sendable {
    let phase: SmartScanJourneyPhase
    let categories: [SmartScanCategoryPresentation]
    let headline: SmartScanHeadline

    static func make(input: SmartScanPresentationInput) -> Self
}
```

`SmartScanPresentationState` must be a value, not `ObservableObject`, and must not own a `Task`, scanner, store, closure, or deletion action.

- [ ] **Step 2: Run the new presentation tests and confirm RED**

```bash
CLANG_MODULE_CACHE_PATH=/private/tmp/xico-clang-module-cache \
SWIFTPM_MODULECACHE_OVERRIDE=/private/tmp/xico-swiftpm-module-cache \
swift test --jobs 1 --filter 'SmartScanPresentationTests' \
  --disable-automatic-resolution --skip-update
```

Expected: compile failure because the presentation types do not exist.

- [ ] **Step 3: Write failing scan-cancellation tests**

Add these exact cases in `SmartScanHubCancellationTests` using a deterministic `XicoEnvironment` test harness whose scanners suspend until cancellation and never touch the real filesystem:

```swift
func testCancelBeforeAnyResultEntersVisibleCancelledReview()
func testCancelAfterPartialResultPreservesCommittedGroupsAndMarksPendingCategoriesCancelled()
func testNewStartClearsPriorScanTermination()
func testCancelledCategoriesAreNotCountedAsCompletedOrZeroResult()
func testCleanCancellationRequestOnlySetsStoppingFactAndIsIdempotent()
func testResetClearsCleanCancellationRequested()
```

The closed contract is:

```swift
public enum ScanSessionTermination: Equatable, Sendable {
    case userCancelled
}

public enum CategoryState.Status: Equatable {
    case pending
    case scanning
    case done
    case cancelled
    case failed(String)
}
```

Because the current hub has no controllable scan seam, add one internal injection point before writing asynchronous cancellation assertions:

```swift
typealias SmartScanCategoryProvider = @Sendable (
    _ category: SmartCategory,
    _ progress: @escaping ProgressHandler
) async throws -> [ScanResult]

init(
    env: XicoEnvironment,
    duplicatesRoot: PathBox,
    scanProvider: SmartScanCategoryProvider? = nil
)
```

Production passes `nil` and continues through the existing `provider(for:)` implementation. Tests inject a continuation-backed provider. The seam returns facts only; it cannot clean, delete, authorize, or mutate hub state directly. Do not use `loadDemoResults()` as a test seam because it cannot model task cancellation, partial arrival, or races.

Put the shared actor/lock-safe `SuspendingScanProvider`, reducer-backed report/outcome builders, category/group/coverage builders, fixed dates/receipts, and `@MainActor waitUntil` helper in `SmartScanTestFixtures.swift`. `ProgressHandler` is `@Sendable`; tests must not capture an ordinary mutable array or the XCTestCase instance from that closure.

- [ ] **Step 4: Run cancellation tests and confirm RED**

```bash
CLANG_MODULE_CACHE_PATH=/private/tmp/xico-clang-module-cache \
SWIFTPM_MODULECACHE_OVERRIDE=/private/tmp/xico-swiftpm-module-cache \
swift test --jobs 1 --filter 'SmartScanHubCancellationTests' \
  --disable-automatic-resolution --skip-update
```

Expected: compile failure for missing termination/cancelled/stopping facts.

- [ ] **Step 5: Implement the smallest hub facts**

In `SmartScanHub.swift`:

```swift
@Published public private(set) var scanTermination: ScanSessionTermination?
@Published public private(set) var cleanCancellationRequested = false
```

Behavior:

- A new accepted `start()` and a non-cleaning `reset()` clear both facts. While cleaning, `reset()` continues to delegate to cancellation and returns without clearing the stopping fact before a reducer terminal.
- `cancel()` always keeps `phase = .active`, sets `.userCancelled`, changes only still-pending/scanning categories to `.cancelled`, and preserves submitted groups/coverage.
- `cancelCleaning()` guards `cleaning && !cleanCancellationRequested`, sets the fact before cancelling the task, and changes no report, selection, receipt, count, or phase.
- The reducer-backed terminal transition clears `cleanCancellationRequested` only after the engine/consumer returns.
- `allDone` treats `.cancelled` as settled, while presentation separately retains incomplete/cancelled meaning.
- Mark nested `Phase` and `CategoryState.Status` `Sendable` so strict Swift 6 permits them inside immutable presentation inputs.

- [ ] **Step 6: Implement the pure presentation mapping**

Create `SmartScanPresentation.swift`. Convert each hub state to immutable category facts. For terminal mapping:

```swift
guard let consumption = input.outcome, consumption.isTrusted else {
    return .uncertain(validatedRecovery: validatedRecovery(from: input.outcome))
}
let canonical = TaskOutcomePresentation.make(context: consumption.presentationContext)
```

Do not access `operation.counts` in the uncertain branch. Add a source guard test that confirms the uncertain builder has no `counts`, `requested`, `succeeded`, `failed`, `skipped`, or `cancelled` access.

- [ ] **Step 7: Run focused tests and refactor names only after GREEN**

```bash
CLANG_MODULE_CACHE_PATH=/private/tmp/xico-clang-module-cache \
SWIFTPM_MODULECACHE_OVERRIDE=/private/tmp/xico-swiftpm-module-cache \
swift test --jobs 1 --filter 'SmartScanPresentationTests|SmartScanHubCancellationTests' \
  --disable-automatic-resolution --skip-update
```

Expected: all new tests pass.

- [ ] **Step 8: Commit Task 2**

```bash
git add Sources/Features/SmartScanPresentation.swift \
  Sources/Features/SmartScanHub.swift \
  Tests/FeatureTests/SmartScanPresentationTests.swift \
  Tests/FeatureTests/SmartScanHubCancellationTests.swift \
  Tests/FeatureTests/SmartScanTestFixtures.swift
git diff --cached --check
git commit -m "feat(smart-scan): add truthful journey presentation"
```

---

## Task 3: Enforce review grouping and irreversible-default safety

**Files:**

- Modify: `Sources/Features/SmartScanPresentation.swift`
- Modify: `Sources/Features/SmartScanHub.swift:177-480`
- Create: `Tests/FeatureTests/SmartScanReviewSafetyTests.swift`
- Reference: `Sources/Domain/Models.swift:79-210`

- [ ] **Step 1: Write failing classification tests**

Create these exact tests:

```swift
func testSafeTrashIntentItemDefaultsIntoReversibleSelectedGroup()
func testLowConfidenceSingleEvidenceAndCompatibilityAssessmentNeverDefaultSelect()
func testPermanentIntentItemDefaultsUnselectedAndNeedsConfirmation()
func testHelperItemDefaultsUnselectedEvenWhenSafetyIsSafe()
func testCautionAndRiskyItemsDefaultUnselected()
func testInformationalItemIsNeverSelectableOrCountedAsReclaimable()
func testIncompleteOrUntrustedItemIsNeverSelectable()
func testReversibleIrreversibleAndInformationalBytesRemainSeparate()
func testPermanentSelectionCannotBypassExplicitConfirmation()
```

The pure projection must expose:

```swift
enum SmartScanReviewGroupKind: Equatable, Sendable {
    case reversible
    case needsConfirmation
    case informational
}

struct SmartScanReviewSummary: Equatable, Sendable {
    let reversibleSelectedBytes: Int64
    let irreversibleSelectedBytes: Int64
    let informationalBytes: Int64
    let selectedCount: Int
    let requiresConfirmation: Bool
}
```

- [ ] **Step 2: Run the safety tests and confirm RED**

```bash
CLANG_MODULE_CACHE_PATH=/private/tmp/xico-clang-module-cache \
SWIFTPM_MODULECACHE_OVERRIDE=/private/tmp/xico-swiftpm-module-cache \
swift test --jobs 1 --filter 'SmartScanReviewSafetyTests' \
  --disable-automatic-resolution --skip-update
```

Expected: compile failures for missing review classification.

- [ ] **Step 3: Implement one eligibility function used by both scan arrival and UI**

Add a pure policy with the actual category intent supplied explicitly:

```swift
enum SmartScanSelectionPolicy {
    static func group(
        item: CleanableItem,
        intent: DeleteIntent,
        coverageTrusted: Bool
    ) -> SmartScanReviewGroupKind

    static func mayDefaultSelect(
        item: CleanableItem,
        intent: DeleteIntent,
        coverageTrusted: Bool
    ) -> Bool
}
```

Only `.safe`, non-helper, non-informational, trusted `.trash` items whose real `item.assessment.qualifiesForAutomaticSelection` is true may default-select. Low-confidence, single-evidence, missing, and compatibility/default assessments remain unselected even when safety is `.safe`. When a category result arrives, normalize every item's `isSelected` through this policy; do not rely on `CleanableItem`'s generic initializer default because it does not know the category's real deletion intent or assessment strength.

- [ ] **Step 4: Make mutation APIs fail closed**

`toggleItem` and `setGroup` must refuse selection for `.informational` and untrusted/incomplete facts. Selection of `.permanent`, helper, caution, or risky facts remains possible only in the confirmation group; `selectionNeedsConfirm` derives from the same policy and cannot diverge.

- [ ] **Step 5: Run safety and existing cleaning tests**

```bash
CLANG_MODULE_CACHE_PATH=/private/tmp/xico-clang-module-cache \
SWIFTPM_MODULECACHE_OVERRIDE=/private/tmp/xico-swiftpm-module-cache \
swift test --jobs 1 --filter 'SmartScanReviewSafetyTests|ScanIntelligenceTests|CleaningOutcomeConsumerTests|CleaningEngineTests/testMixedIntentSmartScanMergesEveryRequestOccurrenceExactlyOnce' \
  --disable-automatic-resolution --skip-update
```

Expected: all focused tests pass and no existing mixed-intent deletion semantics change.

- [ ] **Step 6: Commit Task 3**

```bash
git add Sources/Features/SmartScanPresentation.swift \
  Sources/Features/SmartScanHub.swift \
  Tests/FeatureTests/SmartScanReviewSafetyTests.swift
git diff --cached --check
git commit -m "fix(smart-scan): default irreversible review items off"
```

---

## Task 4: Add All Tools, recent tools, and typed recommendations

**Files:**

- Modify: `Sources/Domain/Models.swift:6-37`
- Modify: `Sources/Infrastructure/XicoEnvironment.swift:219-263`
- Modify: `Sources/Features/AppModel.swift`
- Create: `Sources/Features/RecentToolStore.swift`
- Create: `Sources/Features/AllToolsView.swift`
- Create: `Sources/Features/ToolDiscoveryRail.swift`
- Modify: `Sources/Features/RootView.swift:80-370`
- Create: `Tests/FeatureTests/ToolDiscoveryTests.swift`
- Create: `Tests/FeatureTests/RecentToolStoreTests.swift`
- Create: `Tests/FeatureTests/AllToolsNavigationTests.swift`

- [ ] **Step 1: Write failing bounded-store tests**

```swift
final class RecentToolStoreTests: XCTestCase {
    func testDeduplicatesKeepsNewestAndCapsAtEight()
    func testReopeningModuleUpdatesTimestampWithoutDuplicate()
    func testPersistsOnlyToolIDAndLastOpenedAt()
    func testRejectsUnknownAndNonNavigableModuleIDs()
    func testSortIsDeterministicForEqualTimestamps()
    func testMalformedPayloadRecoversAsEmpty()
    func testOpeningCatalogToolRecordsRecentButNavigationPseudoDestinationsDoNot()
}
```

Contract:

```swift
struct RecentToolEntry: Codable, Equatable, Sendable {
    let moduleID: ModuleID
    let lastOpenedAt: Date
}

@MainActor
final class RecentToolStore: ObservableObject {
    @Published private(set) var entries: [RecentToolEntry]
    func record(_ moduleID: ModuleID, at date: Date = Date())
}
```

Inject a small `RecentToolPersistence` protocol for tests; production uses a namespaced `UserDefaults` key. Do not persist the synthesized `ModuleID` Codable shape. Encode a private payload with exactly `toolID: String` and `lastOpenedAt: Date`; the schema contains no path, title, search query, result, bytes, or user content. Malformed payloads fail closed to an empty list.

- [ ] **Step 2: Write failing discovery/navigation tests**

```swift
func testAllToolsListsEveryNavigableCatalogModuleOnce()
func testAllToolsSearchMatchesLocalizedTitleAndSubtitle()
func testAllToolsSelectionOnlyReturnsDestinationAndExecutesNoWork()
func testColdStartCommonToolsAreUninstallerSpaceLensAndMaintenance()
func testEvidenceRanksAheadOfRecencyAndColdDefaults()
func testDuplicateRecommendationsCollapseToHighestPriority()
func testMissingStaleOrWrongVolumeEvidenceProducesNoRecommendation()
func testTerminalRecommendationsAreCappedAtTwo()
func testWhatsNewItemsAreCappedAtThree()
func testCommonToolRankingDeduplicatesCapsAtFourAndBreaksTiesByStableModuleID()
func testEveryCatalogEntryHasExplicitDetailRoute()
```

Typed recommendation contract:

```swift
struct ToolRecommendation: Equatable, Sendable, Identifiable {
    let toolID: ModuleID
    let reason: ToolRecommendationReason
    let evidence: ToolRecommendationEvidence
    let priority: Int
    let destination: ToolDestination
    let observedAt: Date
}

enum ToolDestination: Equatable, Sendable {
    case module(ModuleID)
    case allTools
}

enum RootDestination: Equatable, Sendable {
    case smartScan
    case allTools
    case module(ModuleID)

    static func resolve(selection: ModuleID?) -> RootDestination
}
```

`ToolRecommendationReason` and `ToolRecommendationEvidence` are closed enums. They contain no closure and cannot invoke scanners, deletion, authorization, URLs, or shell commands.

- [ ] **Step 3: Run both suites and confirm RED**

```bash
CLANG_MODULE_CACHE_PATH=/private/tmp/xico-clang-module-cache \
SWIFTPM_MODULECACHE_OVERRIDE=/private/tmp/xico-swiftpm-module-cache \
swift test --jobs 1 --filter 'RecentToolStoreTests|ToolDiscoveryTests|AllToolsNavigationTests' \
  --disable-automatic-resolution --skip-update
```

Expected: compile failures for missing types/routes.

- [ ] **Step 4: Add the route without polluting the catalog**

Add `ModuleID.allTools = ModuleID("all-tools")`. Keep it a navigation destination rather than a scanner/tool record. Add catalog helpers:

```swift
public static var navigableTools: [ModuleMetadata] { all }
public static func metadata(for id: ModuleID) -> ModuleMetadata?
```

Do not add an `allTools` pseudo-module to `ModuleCatalog.all`, because the all-tools page must not recursively list itself.
`navigableTools` intentionally includes the current 19 catalog modules, including Smart Scan and hidden-but-directly-routable tools, exactly as the approved specification requires. The separate common-tools ranking excludes `.smartScan`, `.allTools`, and `.settings` because those already have stable destinations outside that ranker.

- [ ] **Step 5: Implement store, ranking, and pure All Tools selection**

`AllToolsView` accepts `[ModuleMetadata]` and `(ModuleID) -> Void`; its rows only return a module ID. Group by `ModuleCategory`, use searchable localized title/subtitle, and add keyboard/VoiceOver labels.

`ToolDiscoveryRail` renders a supplied recommendation array capped at two and routes only through `(ToolDestination) -> Void`.

Own one `RecentToolStore` from `AppModel` so locale-driven view reconstruction and sidebar/detail transitions do not create competing stores. Record accepted catalog IDs in `AppModel.selection.didSet`; this captures existing direct `model.selection = ...` routes without a risky whole-product navigation rewrite. The initializer's `--open=` assignment must explicitly record once because property observers do not run during initialization. Ignore `.smartScan`, `.settings`, `.allTools`, unknown IDs, and failed routes.

Keep storage and ranking separate. Add a pure `CommonToolRanker` that applies current deterministic evidence, then recency, then cold defaults; it deduplicates, caps at four, and breaks equal-rank ties by `ModuleID.rawValue`.

- [ ] **Step 6: Integrate three-level navigation**

In `SidebarView`, render:

1. Today: Smart Scan.
2. Common tools: at most four from evidence, recency, then cold defaults.
3. All Tools: one stable entry.

Record only actual common-tool destinations, never `.smartScan`, `.settings`, or `.allTools`. Add `case .allTools` in `DetailView` and route an All Tools row through `model.selection`.

Route `DetailView` through the pure `RootDestination.resolve(selection:)` contract so tests can prove `.allTools` is explicit and unknown IDs fail closed to Smart Scan without instantiating a SwiftUI view or an environment.

- [ ] **Step 7: Run focused tests and compile Features**

```bash
CLANG_MODULE_CACHE_PATH=/private/tmp/xico-clang-module-cache \
SWIFTPM_MODULECACHE_OVERRIDE=/private/tmp/xico-swiftpm-module-cache \
swift test --jobs 1 --filter 'RecentToolStoreTests|ToolDiscoveryTests|AllToolsNavigationTests' \
  --disable-automatic-resolution --skip-update
CLANG_MODULE_CACHE_PATH=/private/tmp/xico-clang-module-cache \
SWIFTPM_MODULECACHE_OVERRIDE=/private/tmp/xico-swiftpm-module-cache \
swift build --jobs 1 --product Xico \
  --disable-automatic-resolution --skip-update
```

Expected: tests pass and Xico builds.

- [ ] **Step 8: Commit Task 4**

```bash
git add Sources/Domain/Models.swift \
  Sources/Infrastructure/XicoEnvironment.swift \
  Sources/Features/AppModel.swift \
  Sources/Features/RecentToolStore.swift \
  Sources/Features/AllToolsView.swift \
  Sources/Features/ToolDiscoveryRail.swift \
  Sources/Features/RootView.swift \
  Tests/FeatureTests/RecentToolStoreTests.swift \
  Tests/FeatureTests/ToolDiscoveryTests.swift \
  Tests/FeatureTests/AllToolsNavigationTests.swift
git diff --cached --check
git commit -m "feat(navigation): make high-value tools discoverable"
```

---

## Task 5: Build the stable premium shell and idle experience

**Files:**

- Create: `Sources/Features/SmartScanExperienceView.swift`
- Create: `Sources/Features/SmartScanTodayBar.swift`
- Create: `Sources/Features/SmartScanInstrument.swift`
- Create: `Sources/Features/SmartScanInsightStack.swift`
- Create: `Sources/Features/SmartScanExperienceFixture.swift`
- Modify: `Sources/Features/SmartScanPresentation.swift`
- Modify: `Sources/Features/ScanViews.swift:393-490`
- Modify: `Sources/Features/RootView.swift:270-305`
- Create: `Tests/FeatureTests/SmartScanExperienceStructureTests.swift`

- [ ] **Step 1: Write failing structure and truth tests**

```swift
func testExperienceUsesOneStableRootAcrossAllJourneyPhases()
func testIdleWithoutCapacityOrScanFactsUsesLoadingInsteadOfZero()
func testIdleShowsNoExpectedReclaimableBytes()
func testScreenHasAtMostOneGradientHero()
func testExperienceContainsNoPixelRobotOverlay()
func testExperienceContainsNoIdleTimelineViewOrRandomCanvas()
func testInstrumentAccessibilityCombinesStateValueUnitAndAction()
func testDebugFixtureIsUnavailableToReleaseCompilationBranch()
func testTerminalAuthorizationIsNotStoredInEquatablePresentationState()
func testIdleFactsAreInjectedAndViewsNeverReadEnvironmentDirectly()
```

Use source guards only for architectural prohibitions; use pure state assertions for data truth.

- [ ] **Step 2: Run and confirm RED**

```bash
CLANG_MODULE_CACHE_PATH=/private/tmp/xico-clang-module-cache \
SWIFTPM_MODULECACHE_OVERRIDE=/private/tmp/xico-swiftpm-module-cache \
swift test --jobs 1 --filter 'SmartScanExperienceStructureTests' \
  --disable-automatic-resolution --skip-update
```

Expected: missing experience types/files.

- [ ] **Step 3: Reuse the approved type and motion system**

Use the existing `XFont`/View modifiers (`xLargeTitle`, `xTitle`, `xHeroNumber`, `xHeroCompactNumber`, `xNumber`, and mono variants) and existing semantic color/spacing/radius/elevation tokens. Use the closest existing finite `XMotion` animation where its measured duration matches the specification; define a Smart Scan-local finite animation constant only when the exact 180 ms, 420 ms, 220 ms, 300 ms, or 500–700 ms contract cannot be expressed by an existing token. Do not duplicate global tokens merely to rename them.

Do not place raw `.font(.system(size:))` calls in feature files.

- [ ] **Step 4: Implement the stable shell**

Extend the pure projection with explicit Today facts:

```swift
struct SmartScanCapacityFact: Equatable, Sendable {
    let totalBytes: Int64
    let availableBytes: Int64
}

struct SmartScanTodayFacts: Equatable, Sendable {
    let capacity: SmartScanCapacityFact?
    let healthScore: Int?
    let lastCommittedSuccess: SmartScanCommittedSuccessFact?
    let verifiedAt: Date?
}

struct SmartScanCommittedSuccessFact: Equatable, Sendable {
    let processedBytes: Int64
    let processedAt: Date
}
```

`SmartScanView` builds these from the `capacity`, metrics/health, and committed history facts it already owns. `nil` maps to loading, never zero. Views do not query `XicoEnvironment`, disk capacity, metrics, history, or current time directly.

Keep the one-shot terminal authorization outside the Equatable projection:

```swift
struct SmartScanTerminalRenderInput {
    let context: TaskOutcomeContext
    let authorization: OutcomePresentationEffectAuthorization?
}
```

`SmartScanExperienceView` accepts the value presentation, an optional non-Equatable `terminalRenderInput`, and actions:

```swift
struct SmartScanExperienceActions {
    let start: () -> Void
    let cancelScan: () -> Void
    let requestClean: () -> Void
    let cancelClean: () -> Void
    let retry: (() -> Void)?
    let undo: (() -> Void)?
    let done: () -> Void
    let openTool: (ToolDestination) -> Void
}
```

The root layout stays mounted while content transitions between phases. It contains one `SmartScanTodayBar`, one central content region, and an optional `ToolDiscoveryRail`; phase changes do not replace the entire page with unrelated hierarchies. The adapter maps `CleaningOutcomeConsumption.presentationContext` and the original `presentationAuthorization` directly into `SmartScanTerminalRenderInput`; the authorization never enters `SmartScanPresentationState`, recommendation data, persistence, or screenshot fixtures.

- [ ] **Step 5: Implement the idle instrument and insights**

- Main question: current Mac state, not a decorative score.
- Primary action: start Smart Scan.
- Capacity/health facts render only when available; unknown facts use `XSkeleton` or “正在读取”.
- Show at most three deterministic insights and no reclaimable estimate before a scan.
- Remove the pixel assistant from this journey. If assistant value remains, express it as a normal evidence-backed tool recommendation.
- Use one hero gradient on the instrument; all secondary content uses semantic surfaces.
- Do not reuse `XScanOrb` for the settled idle page or as six simultaneous category orbs: its `TimelineView(.animation)` is lifecycle-driven. Build this journey's instrument from static shapes plus finite state transitions.

- [ ] **Step 6: Add a DEBUG-only deterministic fixture**

Wrap fixture declarations in `#if DEBUG`. Inputs include fixed date, locale, scheme, size, AX preferences, category facts, volume identity/capacity, selection, outcome/receipts, and recommendations. It never constructs `XicoEnvironment` and never calls a scanner or engine.

- [ ] **Step 7: Replace `SmartScanView` phase switching**

Keep `SmartScanView` as the adapter from `AppModel`/hub to pure presentation. Replace the old `Group { switch hub.phase ... }` body with `SmartScanExperienceView`; preserve existing alerts and refresh behavior. Disable the old finished-phase animated background so success motion has a single owner.

- [ ] **Step 8: Run focused tests and build**

```bash
CLANG_MODULE_CACHE_PATH=/private/tmp/xico-clang-module-cache \
SWIFTPM_MODULECACHE_OVERRIDE=/private/tmp/xico-swiftpm-module-cache \
swift test --jobs 1 --filter 'SmartScanExperienceStructureTests|TypeScaleTokenGuardTests' \
  --disable-automatic-resolution --skip-update
CLANG_MODULE_CACHE_PATH=/private/tmp/xico-clang-module-cache \
SWIFTPM_MODULECACHE_OVERRIDE=/private/tmp/xico-swiftpm-module-cache \
swift build --jobs 1 --product Xico \
  --disable-automatic-resolution --skip-update
```

Expected: tests pass and Xico builds.

- [ ] **Step 9: Commit Task 5**

```bash
git add Sources/Features/SmartScanExperienceView.swift \
  Sources/Features/SmartScanTodayBar.swift \
  Sources/Features/SmartScanInstrument.swift \
  Sources/Features/SmartScanInsightStack.swift \
  Sources/Features/SmartScanExperienceFixture.swift \
  Sources/Features/SmartScanPresentation.swift \
  Sources/Features/ScanViews.swift \
  Sources/Features/RootView.swift \
  Tests/FeatureTests/SmartScanExperienceStructureTests.swift
git diff --cached --check
git commit -m "feat(smart-scan): introduce premium stable experience shell"
```

---

## Task 6: Implement truthful scanning and stopping motion

**Files:**

- Create: `Sources/Features/SmartScanCategoryMatrix.swift`
- Modify: `Sources/Features/SmartScanInstrument.swift`
- Modify: `Sources/Features/SmartScanExperienceView.swift`
- Modify: `Sources/Features/SmartScanPresentation.swift`
- Modify: `Sources/Features/SmartScanHub.swift:330-370`
- Create: `Tests/FeatureTests/SmartScanProgressPresentationTests.swift`
- Create: `Tests/FeatureTests/SmartScanMotionPolicyTests.swift`

- [ ] **Step 1: Write failing progress tests**

```swift
func testGlobalProgressUsesResolvedCategoriesOutOfSixNotFakePercent()
func testKnownLocalFractionIsClampedToZeroThroughOne()
func testUnknownLocalFractionProducesIndeterminateCategoryProgress()
func testLocalFractionNeverRegressesWithinOneScanRound()
func testCancelledAndFailedCategoriesAreVisuallyDistinctFromDone()
func testStoppingScanPreservesCommittedCategoryFacts()
```

Extend `CategoryState` with a stored `fraction: Double?` and a private per-round monotonic update. Reset it only on `start()`/`rescan(category)`.

- [ ] **Step 2: Run progress tests and confirm RED**

```bash
CLANG_MODULE_CACHE_PATH=/private/tmp/xico-clang-module-cache \
SWIFTPM_MODULECACHE_OVERRIDE=/private/tmp/xico-swiftpm-module-cache \
swift test --jobs 1 --filter 'SmartScanProgressPresentationTests' \
  --disable-automatic-resolution --skip-update
```

Expected: failures because the hub currently drops `ScanProgress.fraction`.

- [ ] **Step 3: Preserve real local progress**

In the progress handler, accept only finite values, clamp to `0...1`, and keep `max(previous, incoming)` within the same round. A missing value remains `nil`; never synthesize it from bytes or elapsed time.

- [ ] **Step 4: Write failing finite-motion policy tests**

```swift
func testEverySmartScanAnimationHasFiniteDurationAtMostOnePointSixSeconds()
func testReduceMotionDisablesTranslationScaleSweepAndParticles()
func testReduceTransparencyUsesOpaqueSemanticSurface()
func testIdleAndSettledViewsOwnNoAnimationTimeline()
func testCategoryCompletionSweepCanFireAtMostOncePerRound()
```

- [ ] **Step 5: Implement category matrix and instrument morph**

Render six compact rows/tiles in stable order. Each exposes category name, state icon/text, found count/bytes when known, and local determinate/indeterminate progress. Use text and icon in addition to color. The idle-to-scanning instrument morph keeps the same center anchor and completes in 420 ms. The all-settled sweep is a one-shot 300 ms transition and does not survive state completion.

Do not use `XProgressBar(indeterminate: true)` in Reduce Motion because its current implementation repeats forever. In normal motion, any indeterminate indicator must be lifecycle-bounded to the active category; in Reduce Motion it becomes a static unresolved track plus status text.

- [ ] **Step 6: Run focused tests and build**

```bash
CLANG_MODULE_CACHE_PATH=/private/tmp/xico-clang-module-cache \
SWIFTPM_MODULECACHE_OVERRIDE=/private/tmp/xico-swiftpm-module-cache \
swift test --jobs 1 --filter 'SmartScanProgressPresentationTests|SmartScanMotionPolicyTests' \
  --disable-automatic-resolution --skip-update
CLANG_MODULE_CACHE_PATH=/private/tmp/xico-clang-module-cache \
SWIFTPM_MODULECACHE_OVERRIDE=/private/tmp/xico-swiftpm-module-cache \
swift build --jobs 1 --product Xico \
  --disable-automatic-resolution --skip-update
```

Expected: focused tests pass and build succeeds.

- [ ] **Step 7: Commit Task 6**

```bash
git add Sources/Features/SmartScanCategoryMatrix.swift \
  Sources/Features/SmartScanInstrument.swift \
  Sources/Features/SmartScanExperienceView.swift \
  Sources/Features/SmartScanPresentation.swift \
  Sources/Features/SmartScanHub.swift \
  Tests/FeatureTests/SmartScanProgressPresentationTests.swift \
  Tests/FeatureTests/SmartScanMotionPolicyTests.swift
git diff --cached --check
git commit -m "feat(smart-scan): show truthful category progress"
```

---

## Task 7: Implement review and executing views users can understand

**Files:**

- Create: `Sources/Features/SmartScanReviewView.swift`
- Modify: `Sources/Features/SmartScanExperienceView.swift`
- Modify: `Sources/Features/SmartScanPresentation.swift`
- Modify: `Sources/Features/SmartScanHub.swift:440-650`
- Create: `Tests/FeatureTests/SmartScanReviewPresentationTests.swift`
- Create: `Tests/FeatureTests/SmartScanExecutingPresentationTests.swift`

- [ ] **Step 1: Write failing review-copy and grouping tests**

```swift
func testReviewHeadlineNamesSelectedReversibleEstimate()
func testReviewSeparatelyNamesIrreversibleEstimateAndRiskCount()
func testReviewStatesNoFilesChangedBeforeConfirmation()
func testInformationalRowsExposeRecoveryButNoSelectionControl()
func testReviewBottomBarAlwaysShowsCountBytesAndReversibility()
func testReviewNumbersUseMonospacedDigitsAndRightAlignmentContract()
func testCancelledReviewNeverSaysScanCompleted()
```

- [ ] **Step 2: Run review tests and confirm RED**

```bash
CLANG_MODULE_CACHE_PATH=/private/tmp/xico-clang-module-cache \
SWIFTPM_MODULECACHE_OVERRIDE=/private/tmp/xico-swiftpm-module-cache \
swift test --jobs 1 --filter 'SmartScanReviewPresentationTests' \
  --disable-automatic-resolution --skip-update
```

Expected: missing review view/presentation facts.

- [ ] **Step 3: Implement a single-container review list**

Use three sections inside one semantic surface with dividers, not a floating card per row. Bind item/group selection back to existing hub APIs only after policy validation. Permanent selection invokes the existing confirmation path; the view cannot call `clean()` directly around that path.

- [ ] **Step 4: Write failing executing tests**

```swift
func testExecutingUsesSafeProcessingCopyNotScanningCopy()
func testFirstCancelRequestShowsStoppingAndDisablesRepeatCancel()
func testStoppingDoesNotChangeTerminalCountsSelectionsOrReceipts()
func testExecutingDoesNotPlayTerminalSoundHapticOrCelebration()
func testCancellationWarningAdmitsSomeItemsMayAlreadyHaveMoved()
```

- [ ] **Step 5: Implement executing presentation**

Keep the same review geometry where practical, freeze selection controls, and show processing/stopping state from `cleanCancellationRequested`. Do not transition to cancelled until the consumer supplies the terminal. Do not render a fake per-file operation percentage unless Domain provides normalized work.

- [ ] **Step 6: Run focused tests and build**

```bash
CLANG_MODULE_CACHE_PATH=/private/tmp/xico-clang-module-cache \
SWIFTPM_MODULECACHE_OVERRIDE=/private/tmp/xico-swiftpm-module-cache \
swift test --jobs 1 --filter 'SmartScanReviewPresentationTests|SmartScanExecutingPresentationTests|SmartScanReviewSafetyTests' \
  --disable-automatic-resolution --skip-update
CLANG_MODULE_CACHE_PATH=/private/tmp/xico-clang-module-cache \
SWIFTPM_MODULECACHE_OVERRIDE=/private/tmp/xico-swiftpm-module-cache \
swift build --jobs 1 --product Xico \
  --disable-automatic-resolution --skip-update
```

Expected: all focused tests pass and build succeeds.

- [ ] **Step 7: Commit Task 7**

```bash
git add Sources/Features/SmartScanReviewView.swift \
  Sources/Features/SmartScanExperienceView.swift \
  Sources/Features/SmartScanPresentation.swift \
  Sources/Features/SmartScanHub.swift \
  Tests/FeatureTests/SmartScanReviewPresentationTests.swift \
  Tests/FeatureTests/SmartScanExecutingPresentationTests.swift
git diff --cached --check
git commit -m "feat(smart-scan): make review and execution understandable"
```

---

## Task 8: Implement honest terminal states and finite signature completion

**Files:**

- Create: `Sources/Features/SmartScanTerminalView.swift`
- Modify: `Sources/Features/SmartScanExperienceView.swift`
- Modify: `Sources/Features/SmartScanPresentation.swift`
- Modify: `Sources/Features/SmartScanHub.swift`
- Modify: `Sources/Features/ScanViews.swift`
- Reference: `Sources/Features/TaskOutcomePresentation.swift`
- Reference: `Sources/Features/SharedViews.swift:490-760`
- Reference: `Sources/Features/OutcomePresentationEffects.swift`
- Reference: `Sources/Features/CleaningOutcomeConsumer.swift`
- Create: `Tests/FeatureTests/SmartScanTerminalPresentationTests.swift`
- Create: `Tests/FeatureTests/SmartScanTerminalEffectsTests.swift`

- [ ] **Step 1: Write failing terminal truth tests**

```swift
func testTrustedSuccessSeparatesProcessedBytesFromSameVolumeAvailableDelta()
func testDifferentOrMissingVolumeIdentitySuppressesAvailableDelta()
func testAPFSDelayShowsExplanationInsteadOfFakeBeforeAfterComparison()
func testReceiptWithoutExpirySaysUndoAvailableWithoutCountdown()
func testPartialFailureAndCancelledUseReducerBackedCounts()
func testUncertainRendersNoAggregateCountsOrBytes()
func testUncertainMayExposeOnlyIndependentlyValidatedRecoveryAndReceiptCapability()
func testTerminalRecommendationsAreEvidenceBackedAndCappedAtTwo()
```

Model the two space facts separately:

```swift
struct SmartScanProcessedFact: Equatable, Sendable {
    let succeededItemCount: Int
    let bytes: Int64
}

enum SmartScanAvailableSpaceDelta: Equatable, Sendable {
    case measured(bytes: Int64)
    case delayedExplanation
    case unavailable
}

struct SmartScanVolumeSample: Equatable, Sendable {
    let volumeUUID: String
    let volumeDisplayName: String
    let availableBytes: Int64
    let sampledAt: Date
}

protocol SmartScanVolumeSampling: Sendable {
    func sample() -> SmartScanVolumeSample?
}
```

Never alias either type to `selectedSize`, `estimatedReclaimableBytes`, or the other space fact.

`VolumeCapacity` currently has no volume identity. Keep this milestone isolated from the dirty Task 5 `Domain/Models.swift` and `LocalFileSystemService.swift` by defining the sample in Features. Capture `URLResourceValues.volumeUUIDString` and the capacity for the same explicit home/system-volume URL through an injected `SmartScanVolumeSampling` dependency. Store one sample immediately before execution and one only after the reducer/consumer returns. Missing UUID, missing capacity, different UUID, or time/order inconsistency yields `.unavailable`; it never falls back to comparing anonymous capacities.

- [ ] **Step 2: Run terminal truth tests and confirm RED**

```bash
CLANG_MODULE_CACHE_PATH=/private/tmp/xico-clang-module-cache \
SWIFTPM_MODULECACHE_OVERRIDE=/private/tmp/xico-swiftpm-module-cache \
swift test --jobs 1 --filter 'SmartScanTerminalPresentationTests' \
  --disable-automatic-resolution --skip-update
```

Expected: missing terminal presentation/view.

- [ ] **Step 3: Build terminal presentation from canonical outcome presentation**

For trusted outcomes, call `TaskOutcomePresentation.make(context:)` once and carry its semantic role, title, actions, and effect eligibility into Smart Scan presentation. Partial/failure/cancelled use canonical counts. For untrusted outcomes, construct `.uncertain` before reading any aggregates and expose only independently validated recovery/receipt capabilities.

- [ ] **Step 4: Write failing effect ownership tests**

```swift
func testOnlyTrustedChangedReversibleFullSuccessCanCelebrate()
func testPartialFailureCancelledAndUncertainCreateNoSuccessEffects()
func testSignatureAnimationStopsWithinOnePointSixSeconds()
func testReduceMotionCreatesNoParticlesTranslationOrCountUpTask()
func testTerminalConsumesEffectAuthorizationExactlyOnce()
func testReturningToTerminalCannotReplaySoundHapticOrAnnouncement()
func testStableShellPassesOriginalAuthorizationToCanonicalOwnerWithoutProjectingIt()
func testRemountingSameTerminalOperationCannotRetakeAuthorization()
```

- [ ] **Step 5: Implement terminal view by extending the canonical terminal composition**

Refactor `TaskOutcomeView`/`TaskOutcomeSessionView` narrowly so `SmartScanTerminalView` can supply Smart Scan-specific processed-space, available-space-delta, undo availability, and recommendation sections while preserving the existing canonical status/header/count/action layout. The view receives the original `SmartScanTerminalRenderInput` from the adapter and passes its context/authorization unmodified to the canonical session. `OutcomePresentationEffectSession` and `OutcomePresentationEffects` remain the single production owner of authorization consumption, burst, sound/haptic, and announcement. `SmartScanTerminalView` must not construct `XAnnihilationBurst`, `XCelebrationBurst`, `XSound`, or `XHaptic` directly. Other states use static semantic icons. Show result conclusion first, then facts, then at most two actions/recommendations. Never use green particles or “全部完成” for partial/failure/cancelled/uncertain.

- [ ] **Step 6: Run terminal and canonical outcome tests**

```bash
CLANG_MODULE_CACHE_PATH=/private/tmp/xico-clang-module-cache \
SWIFTPM_MODULECACHE_OVERRIDE=/private/tmp/xico-swiftpm-module-cache \
swift test --jobs 1 --filter 'SmartScanTerminalPresentationTests|SmartScanTerminalEffectsTests|TaskOutcomePresentationTests|CleaningOutcomeConsumerTests|OutcomeSideEffectPolicyTests' \
  --disable-automatic-resolution --skip-update
```

Expected: all pass, including exactly-once side effects.

- [ ] **Step 7: Commit Task 8**

```bash
git add Sources/Features/SmartScanTerminalView.swift \
  Sources/Features/SmartScanExperienceView.swift \
  Sources/Features/SmartScanPresentation.swift \
  Sources/Features/SmartScanHub.swift \
  Sources/Features/ScanViews.swift \
  Sources/Features/SharedViews.swift \
  Tests/FeatureTests/SmartScanTerminalPresentationTests.swift \
  Tests/FeatureTests/SmartScanTerminalEffectsTests.swift
git diff --cached --check
git commit -m "feat(smart-scan): present honest premium terminal outcomes"
```

---

## Task 9: Complete localization, keyboard, VoiceOver, and adaptive layout

**Files:**

- Modify: `Sources/DesignSystem/Resources/{de,en,es,fr,it,ja,ko,pt-BR,ru,zh-Hans,zh-Hant}.lproj/Localizable.strings`
- Modify: `Tests/FeatureTests/LocalizationCoverageTests.swift`
- Create: `Tests/FeatureTests/SmartScanAccessibilityTests.swift`
- Create: `Tests/FeatureTests/SmartScanAdaptiveLayoutTests.swift`
- Modify: `Sources/XicoApp/XicoApp.swift:286-315`
- Modify: `Sources/Features/CommandPalette.swift:115-145`
- Modify: `Sources/Features/RootView.swift:305-332`
- Modify: Smart Scan view files created in Tasks 4–8 as failures require.

- [ ] **Step 1: Inventory every new localized key**

Add a fixed `smartScanExperienceKeyInventory` to `LocalizationCoverageTests`. Include every new title, status, explanation, button, recommendation reason, accessibility label, and format string. Verify the same format specifier sequence in all 11 languages.

Also add `testEveryDynamicModuleCatalogTitleSubtitleAndCategoryExistsInEveryLocale`. The existing literal-call regex cannot discover dynamic `ModuleCatalog` keys; this test must enumerate `ModuleCatalog.all` plus every `ModuleCategory.title`. It must catch current omissions such as `工具` and `视频 / 音频 / 图片下载队列` rather than allowing source Chinese to leak into other locales.

Add `testSmartScanExperienceTranslationsPreserveFormatSpecifiers` and `testAllLocalizableFilesContainNoDuplicateRawKeys`; PropertyList parsing alone can silently hide a duplicate raw key.

- [ ] **Step 2: Run localization coverage and confirm RED**

```bash
CLANG_MODULE_CACHE_PATH=/private/tmp/xico-clang-module-cache \
SWIFTPM_MODULECACHE_OVERRIDE=/private/tmp/xico-swiftpm-module-cache \
swift test --jobs 1 --filter 'LocalizationCoverageTests|LocalizationTests' \
  --disable-automatic-resolution --skip-update
```

Expected: missing keys/parity failures until translations are added.

- [ ] **Step 3: Add reviewed translations in all 11 tables**

Translate meaning, not word order. Keep “estimated”, “successfully processed”, “available space change”, “reversible”, and “permanent” semantically distinct. Do not leave source Chinese in non-Chinese values. Validate `.strings` as property lists. Edit only the dedicated Smart Scan section and specific pre-existing missing dynamic keys; do not sort or regenerate whole tables.

- [ ] **Step 4: Write failing accessibility and layout tests**

```swift
func testReadingOrderIsConclusionEvidencePrimaryActionInsightsRecommendations()
func testEveryCategoryExposesNameStateCountAndAttentionSemantics()
func testStateNeverReliesOnColorAlone()
func testPrimaryJourneyHasCommandRCommandReturnAndCommandZRoutes()
func testVoiceOverAnnouncementChangesOnlyAtPhaseOrTerminalBoundary()
func testMinimumWindowContractIs1080By640()
func testGermanRussianEnglishJapaneseChineseFixturesFitWithoutForbiddenTruncation()
func testReduceMotionTransparencyAndIncreaseContrastFixturesRemainOperable()
func testSmartScanStatesRemainDistinguishableWithIncreaseContrastAndDifferentiateWithoutColor()
```

- [ ] **Step 5: Implement accessibility and adaptive refinements**

- Combine instrument semantics into one accessible element.
- Supply an explicit state/value/unit/hint accessibility string for the Smart Scan instrument; do not reuse `XRingGauge`'s fixed percentage value when the visible fact is bytes or categories resolved.
- Use explicit sort priorities matching the approved reading order.
- Keep visible focus rings and native button/list semantics.
- Move ⌘R, ⌘⏎, and ⌘Z into a discoverable Smart Scan command menu, enabled only for the Smart Scan destination and disabled while the command palette/text input owns focus. Remove duplicate hidden-button shortcut owners so each shortcut has one route and text editing outside Smart Scan is never intercepted.
- Replace command-palette row `onTapGesture` activation with a semantic `Button` while preserving arrow-key highlight and Enter/Escape behavior.
- At 1080×640, keep primary conclusion/action visible and scroll details rather than shrinking below tokens.
- At 1440×900, expand useful content width without a blank central void.
- Reduce Transparency replaces glass with opaque semantic surfaces; Increase Contrast strengthens borders/text without neon glow.
- Read both `colorSchemeContrast` and `accessibilityDifferentiateWithoutColor`; add symbol, text, and border distinctions so states and selections remain understandable when color differences are removed.

- [ ] **Step 6: Run localization, accessibility, and layout tests**

```bash
CLANG_MODULE_CACHE_PATH=/private/tmp/xico-clang-module-cache \
SWIFTPM_MODULECACHE_OVERRIDE=/private/tmp/xico-swiftpm-module-cache \
swift test --jobs 1 --filter 'LocalizationCoverageTests|LocalizationTests|TaskOutcomeAccessibilityTests|SmartScanAccessibilityTests|SmartScanAdaptiveLayoutTests' \
  --disable-automatic-resolution --skip-update
```

Expected: all tests pass for 11 languages and accessibility branches.

- [ ] **Step 7: Commit Task 9**

```bash
git add Sources/DesignSystem/Resources/*/Localizable.strings \
  Tests/FeatureTests/LocalizationCoverageTests.swift \
  Tests/FeatureTests/SmartScanAccessibilityTests.swift \
  Tests/FeatureTests/SmartScanAdaptiveLayoutTests.swift \
  Sources/XicoApp/XicoApp.swift \
  Sources/Features/CommandPalette.swift \
  Sources/Features/RootView.swift \
  Sources/Features/SmartScanExperienceView.swift \
  Sources/Features/SmartScanTodayBar.swift \
  Sources/Features/SmartScanInstrument.swift \
  Sources/Features/SmartScanInsightStack.swift \
  Sources/Features/SmartScanCategoryMatrix.swift \
  Sources/Features/SmartScanReviewView.swift \
  Sources/Features/SmartScanTerminalView.swift \
  Sources/Features/ToolDiscoveryRail.swift \
  Sources/Features/AllToolsView.swift
git diff --cached --check
git commit -m "feat(smart-scan): complete global accessible experience"
```

---

## Task 10: Add deterministic current-HEAD screenshot and performance evidence

**Files:**

- Modify: `Package.swift`
- Create: `Sources/Features/SmartScanVisualFixtureMatrix.swift`
- Create: `Sources/XicoVisualFixtures/main.swift`
- Modify: `Sources/Features/AppModel.swift:665-685`
- Create: `Tests/FeatureTests/SmartScanFixtureTests.swift`
- Create: `Tests/FeatureTests/SmartScanVisualGuardTests.swift`
- Create: `docs/qa/smart-scan-experience-2-visual-rubric.md`
- Create: `docs/qa/smart-scan-experience-2-acceptance.md`

- [ ] **Step 1: Write failing fixture/renderer tests**

```swift
func testFixtureCoversAllNineJourneyStates()
func testFixtureCoversLightDarkAndBothWindowSizes()
func testFixtureCoversZhEnglishJapaneseAndGerman()
func testFixtureCoversReduceMotionTransparencyAndIncreaseContrast()
func testFixtureExecutableTargetHasNoAppModelOrEnvironmentDependency()
func testVisualFixturePackageBoundaryExposesOnlyCaseMatrixAndRenderFactory()
func testEveryRenderedFilenameEncodesStateLocaleSchemeSizeAndAccessibilityMode()
func testRendererSetsEachFixtureLocaleExplicitlyAndRestoresThePreviousLocale()
func testCLILanguageOverrideWinsOverPersistedPreference()
```

- [ ] **Step 2: Run and confirm RED**

```bash
CLANG_MODULE_CACHE_PATH=/private/tmp/xico-clang-module-cache \
SWIFTPM_MODULECACHE_OVERRIDE=/private/tmp/xico-swiftpm-module-cache \
swift test --jobs 1 --filter 'SmartScanFixtureTests|SmartScanVisualGuardTests' \
  --disable-automatic-resolution --skip-update
```

Expected: renderer/fixture matrix missing.

- [ ] **Step 3: Add an isolated DEBUG visual-fixture executable**

Add a separate `XicoVisualFixtures` executable product/target depending only on `Features` and `DesignSystem`; it is never embedded in `Xico.app`. Put the pure DEBUG matrix, case IDs, filenames, locale/scheme/size/accessibility inputs, and fixture construction in `SmartScanVisualFixtureMatrix.swift` so `FeatureTests` can compile and test them. Keep `Sources/XicoVisualFixtures/main.swift` as a thin `ImageRenderer`/PNG writer over `SmartScanExperienceView`.

Do not make the production experience public merely for QA. Expose only a DEBUG package boundary from `Features`:

```swift
#if DEBUG
package enum SmartScanVisualStateID: String, CaseIterable, Sendable {
    case idle, scanning, review, executing
    case success, partial, failure, cancelled, uncertain
}

package enum SmartScanVisualScheme: String, Sendable {
    case light, dark
}

package enum SmartScanVisualAccessibilityProfile: String, Sendable {
    case standard, reduceMotion, reduceTransparency, increaseContrast
}

package struct SmartScanVisualFixtureCase: Identifiable, Sendable {
    package let id: String
    package let state: SmartScanVisualStateID
    package let localeID: String
    package let scheme: SmartScanVisualScheme
    package let width: Int
    package let height: Int
    package let accessibility: SmartScanVisualAccessibilityProfile
}

package enum SmartScanVisualFixtureMatrix {
    package static let all: [SmartScanVisualFixtureCase]
}

@MainActor
package func makeSmartScanVisualFixtureView(
    _ fixture: SmartScanVisualFixtureCase
) -> AnyView
#endif
```

The package factory owns access to internal `SmartScanExperienceView` and fixture builders. The executable sees only the case matrix and `AnyView` factory; no production scanner/environment API becomes public. The Step 4 `swift build --product XicoVisualFixtures` command is the compile gate for this access boundary.

The Package additions are explicit:

```swift
.executable(name: "XicoVisualFixtures", targets: ["XicoVisualFixtures"])

.executableTarget(
    name: "XicoVisualFixtures",
    dependencies: ["Features", "DesignSystem"]
)
```

The executable outputs to `/private/tmp/xico-smartscan-shots/current-head`. Neither its source nor dependency graph may reference or initialize `AppModel`, `AppModel.shared`, `XicoEnvironment`, scanners, engines, helpers, or the main `XicoApp` executable. Set `XLocale.current` explicitly for each fixture and restore it after rendering. Cover the full required matrix, with a smaller mandatory review subset kept in versioned QA documentation.

Separately fix the real `--lang` precedence in `AppModel`: load the saved language first, then apply a valid explicit CLI language override before assigning `language`. Test the pure precedence rule; do not depend on AppDelegate's later assignment.

- [ ] **Step 4: Build debug and render the matrix**

```bash
CLANG_MODULE_CACHE_PATH=/private/tmp/xico-clang-module-cache \
SWIFTPM_MODULECACHE_OVERRIDE=/private/tmp/xico-swiftpm-module-cache \
swift build -c debug --jobs 1 --product XicoVisualFixtures \
  --disable-automatic-resolution --skip-update
rm -rf /private/tmp/xico-smartscan-shots/current-head
.build/debug/XicoVisualFixtures
find /private/tmp/xico-smartscan-shots/current-head -type f -name '*.png' | sort
```

Expected: deterministic PNGs for every named fixture; no scanner, delete, helper, tmutil, network, or selftest process starts.

- [ ] **Step 5: Inspect mandatory screenshots at original detail**

Use visual inspection for at least:

- idle light 1080×640 zh-Hans;
- scanning dark 1440×900 en;
- review light 1080×640 de;
- executing dark 1080×640 ja;
- success light and dark;
- partial, failure, cancelled, uncertain;
- Reduce Motion, Reduce Transparency, Increase Contrast.

Record issues with exact screenshot path and rubric item. Fix all P0/P1; one P2 maximum is required for ≥95 but target 100 before user review.

- [ ] **Step 6: Run finite-idle performance probe**

Add a fixture-only measurement path or Instruments capture that compares static baseline with settled Smart Scan after all finite animations end. Record:

- input response P95 <100 ms;
- first meaningful content P95 <500 ms;
- settled idle GPU delta <1.0 percentage point;
- zero renders driven by an animation timeline after completion.

Do not claim these gates from source inspection alone. Put measured device/macOS/build and command in `docs/qa/smart-scan-experience-2-acceptance.md`.

- [ ] **Step 7: Have two independent reviewers score the 20-item rubric**

Each reviewer fills H1–H4, L1–L4, T1–T3, C1–C3, N1–N3, M1–M3 independently with pass/fail, severity, evidence path, and reason. Use the lower score. If any item differs or scores differ by at least 5, request a third adjudication for disputed items only. Preserve raw reviews.

- [ ] **Step 8: Commit Task 10**

Do not commit generated PNGs unless explicitly approved as goldens. Commit renderer, tests, rubric, and measured acceptance record:

```bash
git add Package.swift \
  Sources/Features/SmartScanVisualFixtureMatrix.swift \
  Sources/XicoVisualFixtures/main.swift \
  Sources/Features/AppModel.swift \
  Tests/FeatureTests/SmartScanFixtureTests.swift \
  Tests/FeatureTests/SmartScanVisualGuardTests.swift \
  docs/qa/smart-scan-experience-2-visual-rubric.md \
  docs/qa/smart-scan-experience-2-acceptance.md
git diff --cached --check
git commit -m "test(smart-scan): add deterministic visual acceptance"
```

---

## Task 11: Full verification, safe preview packaging, install, and live acceptance

**Files:**

- Create: `scripts/install_preview_app.sh`
- Create: `Tests/FeatureTests/PreviewPackagingSafetyTests.swift`
- Modify only files required by verified failures.
- Update: `docs/qa/smart-scan-experience-2-acceptance.md`

- [ ] **Step 1: Write a failing packaging safety test**

The script contract is deliberately narrow:

```swift
func testPreviewInstallerContainsNoSelftestScannerDeleteHelperRegistrationTmutilOrNetworkInvocation()
func testPreviewInstallerCopiesSwiftPMResourceBundles()
func testPreviewInstallerDoesNotOverwriteUntilNewBundlePassesCodeSignatureVerification()
func testPreviewInstallerBacksUpExistingInstalledBundleBeforeAtomicReplacement()
```

The script builds current-architecture debug `Xico`, assembles a temporary `.app`, embeds SwiftPM resource bundles, writes a valid Info.plist, signs ad hoc, verifies, backs up the existing installed app, then atomically replaces `/Users/yaokai/Applications/Xico.app`. It never registers the helper and never runs the binary with `--selftest`.

- [ ] **Step 2: Run packaging tests and confirm RED**

```bash
CLANG_MODULE_CACHE_PATH=/private/tmp/xico-clang-module-cache \
SWIFTPM_MODULECACHE_OVERRIDE=/private/tmp/xico-swiftpm-module-cache \
swift test --jobs 1 --filter 'PreviewPackagingSafetyTests' \
  --disable-automatic-resolution --skip-update
```

Expected: script missing.

- [ ] **Step 3: Implement the fail-closed preview installer**

Use `mktemp -d`, a cleanup trap, `ditto`, `/usr/bin/codesign --sign -`, and `codesign --verify --strict`. Build with the required caches/offline flags. If any build/copy/plist/signature step fails, leave the currently installed app untouched. Preserve its backup path in the command output.

- [ ] **Step 4: Run complete automated gates**

```bash
CLANG_MODULE_CACHE_PATH=/private/tmp/xico-clang-module-cache \
SWIFTPM_MODULECACHE_OVERRIDE=/private/tmp/xico-swiftpm-module-cache \
swift test --jobs 1 \
  --disable-automatic-resolution --skip-update
CLANG_MODULE_CACHE_PATH=/private/tmp/xico-clang-module-cache \
SWIFTPM_MODULECACHE_OVERRIDE=/private/tmp/xico-swiftpm-module-cache \
swift build -c release --jobs 1 --product Xico \
  --disable-automatic-resolution --skip-update
```

Expected: all tests pass and release product builds. A build is not packaging/notarization/product-completion evidence; record only the gate actually passed.

- [ ] **Step 5: Inspect diff and run independent code review**

Load `superpowers:requesting-code-review`. Review against the spec, focusing on:

- false success/space claims;
- permanent default selection or confirmation bypass;
- untrusted aggregate leakage;
- cancellation races;
- replayed effects;
- unbounded persistence;
- hidden destructive routes;
- idle animation/GPU loops;
- minimum-size and localization regressions.

Fix every P0/P1 and rerun the relevant focused plus full gates.

- [ ] **Step 6: Commit safe preview packaging**

```bash
git add scripts/install_preview_app.sh \
  Tests/FeatureTests/PreviewPackagingSafetyTests.swift \
  docs/qa/smart-scan-experience-2-acceptance.md
git diff --cached --check
git commit -m "build: add safe Smart Scan preview installer"
```

- [ ] **Step 7: Install the verified preview without real cleaning**

```bash
cd /private/tmp/xico-smartscan-experience-2
scripts/install_preview_app.sh
codesign --verify --strict /Users/yaokai/Applications/Xico.app
plutil -p /Users/yaokai/Applications/Xico.app/Contents/Info.plist | head -40
open -n /Users/yaokai/Applications/Xico.app
```

Expected: new UI app opens from the bundle, signature verifies, resources/localization load, and no scan starts automatically.

- [ ] **Step 8: Perform live non-destructive acceptance**

In the installed app:

- verify idle visual hierarchy and All Tools;
- start a scan only if explicitly using a safe fixture route; otherwise use DEBUG fixture UI for scanning/review/terminal;
- do not execute real cleaning;
- verify ⌘R/⌘⏎/⌘Z availability without triggering deletion;
- inspect light/dark, minimum window, Reduce Motion, and one non-Chinese language;
- capture current installed-app screenshots for idle, scanning fixture, review fixture, success fixture, and partial fixture.

Record paths, build/commit, and any residual issue in the acceptance document.

- [ ] **Step 9: Final branch-state verification**

```bash
git status --short
git log --oneline --decorate -12
git diff HEAD~10..HEAD --check
```

Expected: clean execution worktree and no Task 5/user handoff files in this branch's commits.

- [ ] **Step 10: Mark only this visible milestone accurately**

State explicitly:

- implemented code/test/build/install gates;
- visual rubric score and reviewer evidence;
- which external gates remain unverified (10-user comprehension/discoverability study and same-device current CleanMyMac blind comparison unless actually executed);
- that Smart Scan Experience 2.0 passing does not complete the full-product 95+ program.

---

## Post-Milestone Product Sequence

After Task 11 is accepted, continue the full active goal in this order, each with its own specification/plan/TDD/visual gates:

1. Global shell and All Tools consistency across every page.
2. Uninstaller visible value and Task 5 safety completion.
3. Space Lens premium exploration and truthful storage explanations.
4. Maintenance action clarity, history, and reversible/irreversible boundaries.
5. Monitoring, Hardware, Network, Servers, Downloader, Settings, Pricing, onboarding, and menu-bar visual alignment.
6. Full 11-language, keyboard, VoiceOver, contrast, Reduce Motion/Transparency matrix.
7. Release, signing, notarization, installed-bundle, performance, and real-user/competitor evidence gates.

No later phase may use the Smart Scan milestone score as a substitute for its own ≥95 evidence.
