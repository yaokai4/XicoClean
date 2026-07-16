# Xico Phase 0 Outcome Workflows Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use `superpowers:subagent-driven-development` to execute independent consumer migrations, then use `superpowers:verification-before-completion` before claiming this plan complete.

**Goal:** 让每一个会删除、退出、驱逐、安装、联网检查、远端变更或触发“完成”反馈的用户工作流，都只消费 `OperationOutcomeReducer` 生成的事实；partial / failure / cancelled 必须保留真实成功项、失败上下文、receipt 与精确重试选择，任何页面都不能再用聚合计数、循环次数或漂亮完成页自行声明成功。

**Architecture:** 每个执行器到 Feature 的终态载体必须且只能包含一个 reducer-backed `OperationOutcome`：新的一般工作流使用 `OperationResult<Payload>`，其 payload 禁止再嵌套 outcome/result；清理、Space Trash 与卸载共享逐项清理事实时使用专用 `CleaningReport`（它自身就是唯一终态载体），不得再包一层 `OperationResult`。`OperationOutcome` 决定状态、计数和 reducer-owned `OperationMutationFact`，强类型 payload 保留 URL、远端身份、候选版本、恢复 receipt 和逐项 disposition。`OutcomeSideEffectPolicy` 按 operation kind 与 `OutcomeWorkflowProfile` 分别批准 history、用户通知、庆祝、声触和内部 invalidation。沿用 operation-facts Task 3 的同一个 bounded `OutcomeFeedbackGate`：长期 ViewModel owner 只保存一个 `currentOperationID` 和有限 `consumedChannels`，同 ID 重注册不重置，新 ID 原子淘汰旧 ID，storage 恒定。`TaskOutcomeView` 只接收 reducer outcome 和强类型 presentation context。历史、通知、内部刷新各有 fail-closed 的验证边界，业务页不能直接调用原始 sink。

**Tech Stack:** Swift 6、SwiftPM、SwiftUI、AppKit、Foundation、XCTest、现有 `Domain` / `Infrastructure` / `Features` / `DesignSystem` targets。

---

## Authority, dependency and completion rules

- 当前权威输入：
  - `docs/XICO_COMPREHENSIVE_AUDIT_2026-07-16.md`
  - `docs/19-Phase0-可信发布基线-设计规格-2026-07-16.md`
  - `docs/superpowers/plans/2026-07-16-xico-95-program.md`
  - `docs/superpowers/plans/2026-07-16-xico-phase0-operation-facts.md`
- 初始 consumer inventory 来自 HEAD `0b4b278`，当前 Task 2 事实基线来自 `.superpowers/sdd/xico-opfacts-task-2-report.md`：HEAD `2dbfe87` 上 26/28/7 focused tests、423-test full suite、15 个显式环境 skip、0 failure。Task 2 的类型边界证据是 4 个真实 normal-import `swiftc -typecheck` client tests，而不是已删除的 source-regex fixture。执行任何 task 前必须重新读取当前 HEAD、`git status --short` 与该报告；若报告随后增长，以更新后的更高计数为准，绝不回退到较低基线。
- 本计划 Tasks 1–14 是 operation-facts former Tasks 5–7 所列 registry/sink/consumer/UI/static-gate 工作的**唯一执行权所有者**。operation-facts Tasks 5–7 仅保留 non-executable contract handoff/trace；operation-facts Tasks 1–4 仍是 reducer、mutation、base policy、`OutcomeEffectChannel`/`OutcomeFeedbackGate` 与 durable history 类型的唯一权威前置。共同基座严格按 **Task 1 → Task 2 → Task 3 → Task 4** 串行：Task 2 消费 Task 1 registry，Task 3 消费前两项 policy/sink contract，Task 4 消费 Tasks 1–3 的 registry、typed sinks 与 UI。Tasks 5–13 均等待 Tasks 1–4，再叠加各自标题下的上游 contract；Task 14 等待 Tasks 1–13 和全部上游证据。Task 1 不得重定义 gate enum/actor；Task 2 的 typed history adapter 必须复用 operation-facts Task 4 的唯一内部事务。若措辞冲突，以 operation-facts Tasks 1–4 的类型/不变量为准，以本计划的 registry、consumer 文件归属和执行步骤为准。
- `2026-07-16-xico-phase0-destructive-operations.md` 负责授权、目标身份、fd-relative 删除、粉碎 I/O 和卸载归属；本计划负责其 `OperationResult` consumer、UI、history、retry、undo 和 feedback。
- `2026-07-16-xico-phase0-ssh-sftp-hosts.md` 负责 SecureHostBinding、远端 identity、事务存储与 `stopAndWait`；本计划负责删除结果和刷新结果的诚实呈现。
- `2026-07-16-xico-phase0-network-components.md` 负责组件信任和确认前零网络；本计划负责组件安装逐项 outcome。
- `2026-07-16-xico-phase0-updates-release-privacy.md` 负责 Sparkle、发布与隐私同源；本计划负责更新检查结果，且不得把“无法验证”显示成“已是最新”。
- 若上游 contract 尚未落地，相关 task 保持未完成；禁止添加会把 `(Bool, String)`、`nil` 或异常吞成 success 的临时适配器。
- 每个 `OperationItemOutcome` / 强类型 item fact 必须显式携带 `OperationMutationFact`，不得提供会把未迁移 producer 当作 `.none` 的默认值，也不得从 status、bytes、disposition 或回调次数倒推 mutation。破坏性依赖已调用但 postcondition 不明时必须是 `.possiblyChanged`；policy 记录并 invalidates，但禁止成功通知和庆祝。
- 本计划的自动验证不得读取或删除用户真实文件、终止真实 App、启动真实维护命令、连接 SSH/SFTP、联网检查、安装 helper/组件、构建安装包、公证或发布。故障注入使用 in-memory fake、`URLProtocol` stub、fake process runner 和任务专属 disposable temporary directory。
- 所有下文 `swift build` / `swift test` 命令都已直接包含 `--disable-automatic-resolution --skip-update`，只使用已锁定且已缓存的 `Package.resolved` 依赖；若本机缺缓存则本 task 明确 blocked，禁止联网解析或改写 lockfile。
- 不运行 `.build/debug/Xico --selftest` 或 `scripts/make_app.sh`：当前 selftest 会创建、移入废纸篓并删除真实用户目录下的 fixture；本计划只运行下文明确列出的离线测试和构建门。

## Baseline inventory: raw consumers and sinks

以下数量来自全量 `rg`，不是抽样。多行构造必须用 `-U`；旧计划的单行 `CleaningReport\(removedCount:` 会漏掉 4 个换行 callsite。

| Surface / sink | Baseline count | Exact owners | End state |
|---|---:|---|---|
| `TaskCompletionView(` invocation | 7 | `ShredderView`、`SharedViews` adapter、`OptimizationView`、`CollectionBasket`、`UninstallerView`、`AppUpdaterView`、`MaintenanceView` | 0；旧类型删除，所有业务流改用 `TaskOutcomeView` |
| `CompletionView(` consumer | 2 | `ScanViews.swift:212,409` | 两处继续展示清理结果，但底层改为 `TaskOutcomeView` |
| legacy `CleaningReport` aggregate expression | 6 | `ModuleSessionViewModel` merge + partial undo、`SmartScanHub` merge + partial undo、`ScanViews` historical undo、`SettingsView` historical undo | 0；用 reducer merge 或直接传 `RestorableItem` |
| scalar production `history.record(module:reclaimedBytes:removedCount:)` | 4 | Module、Smart Scan、Shredder、Uninstaller | 0；只接受 validated outcome request |
| raw cleanup notifier caller | 2 | Module、Smart Scan | 0；只接受 `ValidatedCleaningNotification` |
| raw `.xicoDidClean` post | 9 | Module 3、Smart Scan 3、Shredder 1、Uninstaller 1、Settings 1 | 0；只经 typed invalidation center |
| direct `scanIndex.invalidate()` | 10 | AppModel 3、Module 2、Smart Scan 5 | 2 个 operation-terminal 调用改走 typed invalidation；8 个 scan lifecycle/cache 调用保留并精确分类 |
| outcome-completion feedback invocation | 4 | `XAnnihilationBurst`、`XCelebrationBurst`、`XSound.cleanDone`、`XHaptic.levelChange` in `SharedViews` | 移入一个受测 outcome-effects owner；业务 terminal page 为 0 |
| classified non-terminal `XHaptic.levelChange` | 1 | health-score threshold in `ScanViews.swift:597` | 保留为健康分阈值 direct-manipulation feedback；不得被误算成 outcome success |
| `role: .destructive` UI action | 20 | Servers 4、Shredder 1、SFTP 1、cleaning 2、Space views 7、Uninstaller 1、snapshot 1、Settings 2、Maintenance 1 | 每个都映射到下方 manifest；0 个未分类、0 个无确认的不可逆入口 |

执行盘点命令：

```bash
rg -n -U --glob 'Sources/**/*.swift' 'TaskCompletionView\s*\(' Sources
rg -n -U --glob 'Sources/**/*.swift' 'CleaningReport\s*\(\s*removedCount:' Sources
rg -n --glob 'Sources/**/*.swift' '\.history\.record\(|history\.record\(' Sources
rg -n --glob 'Sources/**/*.swift' 'Notifier\.notifyCleaningDone|notifier\.cleaningDone' Sources
rg -n --glob 'Sources/**/*.swift' 'NotificationCenter\.default\.post\(name: \.xicoDidClean' Sources
rg -n --glob 'Sources/Features/*.swift' 'scanIndex\.invalidate\(' Sources/Features
rg -n --glob 'Sources/Features/*.swift' 'role:\s*\.destructive' Sources/Features
rg -n --glob 'Sources/**/*.swift' 'XCelebrationBurst\(|XAnnihilationBurst\(|XSound\.play\(\.cleanDone|XHaptic\.perform\(\.levelChange' Sources
```

### Destructive-button manifest: all 20 baseline locations

| # | Baseline owner | Action | Sole migration task |
|---:|---|---|---:|
| 1 | `ServersView.swift:56` | disconnect all | 11 |
| 2 | `ServersView.swift:159` | delete host row | 11 |
| 3 | `ServersView.swift:227` | delete host detail | 11 |
| 4 | `ServersView.swift:544` | delete snippet | 11 |
| 5 | `ShredderView.swift:90` | irreversible shred | 7 |
| 6 | `ServerFilesView.swift:215` | irreversible SFTP delete | 11 |
| 7 | `ScanViews.swift:170` | confirmed module clean | 4 |
| 8 | `SunburstView.swift:289` | confirmed Trash move | 5 |
| 9 | `SunburstView.swift:406` | request Trash from arc | 5 |
| 10 | `SunburstView.swift:768` | request Trash from selection | 5 |
| 11 | `SunburstView.swift:849` | request Trash from child | 5 |
| 12 | `TreemapView.swift:92` | confirmed Trash move | 5 |
| 13 | `TreemapView.swift:184` | request Trash from child | 5 |
| 14 | `TreemapView.swift:212` | request Trash from child | 5 |
| 15 | `UninstallerView.swift:124` | uninstall to Trash | 6 |
| 16 | `SpaceLensView.swift:768` | permanent local snapshot delete | 5 |
| 17 | `SettingsView.swift:82` | clear cleaning history | 13 |
| 18 | `SettingsView.swift:91` | reset onboarding preferences | 13 |
| 19 | `MaintenanceView.swift:55` | confirmed root maintenance | 8 |
| 20 | `SmartScanHub.swift:621` | confirmed mixed clean | 4 |

The manifest is baseline evidence, not a line-number allowlist. Final architecture tests identify the action/body ownership and expected request-confirm-execute-result route; moving a line cannot make an inline destructive call pass. Tunnel deletion, optimizer actions, component installs, update checks, iCloud eviction, benchmark history clear, ignore removal and license deactivation are not marked `role: .destructive` today, but remain mandatory through the family matrix and their focused tests.

### The six legacy aggregate expressions

1. `ModuleSessionViewModel.merge(_:)` sums report aggregates.
2. `ModuleSessionViewModel.undo()` reconstructs a report after partial undo.
3. `SmartScanHub.clean()` sums reports into a manual aggregate.
4. `SmartScanHub.undo()` reconstructs a report after partial undo.
5. `ScanViews.undoRecord(_:)` fabricates a report from history.
6. `SettingsView.undoRecord(_:)` fabricates a report from history.

### Consumer coverage matrix

| Family | User-facing operations in scope | Production files | Required outcome semantics | Focused evidence |
|---|---|---|---|---|
| Cleaning + undo | Module clean/undo、Smart clean/undo、two historical undo consumers、threat bootout child operation | `ModuleSessionViewModel.swift`、`SmartScanHub.swift`、`ScanViews.swift`、`SettingsView.swift`、`ThreatRemediation.swift`、`SharedViews.swift` | reducer merge、partial receipts、retry only retryable subjects、success notification only full changed success | `CleaningOutcomeConsumerTests`、`ThreatRemediationOutcomeTests` |
| Space Lens | single Trash、basket Trash/countdown、basket undo、local snapshot deletion | `SpaceLensView.swift`、`CollectionBasket.swift`、`SunburstView.swift`、`TreemapView.swift`、`SpaceLedger.swift` | no direct `NSWorkspace.recycle`、failed nodes retained、report bytes only、partial undo remains retryable、snapshot neutral/irreversible | `SpaceLensOutcomeTests`、`CollectionBasketOutcomeTests` |
| Shredder | batch shred、cancel、retry | `ShredderView.swift`、`ShredderService.swift` | item facts survive cancel/partial；permanent success is explicitly non-celebratory | `ShredderOutcomeConsumerTests` + existing service safety tests |
| Uninstaller | uninstall body + associated files、retry、undo receipts | `UninstallerView.swift`、`UninstallerService.swift` | required App body、failed selections retained、App-body failure explained、actual history only | `UninstallerOutcomeTests` |
| Maintenance | user single/batch、root task、helper install、iCloud eviction | `MaintenanceView.swift`、`MaintenanceRunner.swift`、`ICloudEvictor.swift`、`HelperProxy.swift` | loop count is never success count；root/helper neutral；failed iCloud items retained | `MaintenanceOutcomeTests` |
| Optimization | single/batch quit、launch-agent toggle、free-memory in page and menu panel | `OptimizationView.swift`、`OptimizationService.swift`、`MenuPanels.swift` | confirmed postcondition, not `terminate()` request；toggle rename + launchctl partial；no estimated bytes as fact | `OptimizationOutcomeTests` |
| Updates | third-party appcast batch、Xico update check/open-download split | `AppUpdaterView.swift`、`AppUpdateService.swift`、`SettingsView.swift`、`UpdateChecker.swift` | verified current/update in payload with `.unchanged`; network/parse failures are failed, never “all current” | `AppUpdaterOutcomeTests` + existing update trust tests |
| Remote/config | SFTP delete + refresh、host delete、tunnel delete、disconnect-all、snippet delete | `ServerFilesView.swift`、`ServersView.swift`、`ServersViewModel.swift`、`SFTPBrowser.swift`、`ServerHostStore.swift`、`TunnelManager.swift`、`PortForwarder.swift` | irreversible neutral UI；delete fact separate from refresh；transaction/keychain/process partial states retained | `RemoteOutcomeConsumerTests` |
| Downloader/components | terminal `DownloadState` adapter、yt-dlp composite install、ffmpeg、aria2、remove/clear terminal queue | `DownloaderView.swift`、`DownloadManager.swift`、`DownloadEngine.swift` | preserve existing lifecycle；component child failure creates partial；no real network/process in tests | `DownloadOutcomeAdapterTests`、`ComponentInstallOutcomeTests` |
| Local/account data | cleaning-history clear、disk-benchmark history clear、ignore removal、onboarding reset、license deactivation | `SettingsView.swift`、`HistoryStore.swift`、`DiskBenchmarkView.swift`、`DiskBenchmark.swift`、`IgnoreListStore.swift`、`PricingView.swift`、`LicenseService.swift` | throwing/validated persistence、unchanged vs succeeded、remote release and local clear are separate children | `LocalDataOutcomeTests`、`LicenseDeactivationOutcomeTests` |

### Explicitly classified non-terminal side effects

These remain outside `TaskOutcomeView`, but are not ignored:

- Basket row removal / “clear basket” only mutates transient selection before execution; it never claims an operation completed.
- Scan/benchmark/download cancellation requests remain lifecycle events. Only the accepted terminal result enters the reducer.
- Monitor polling, Finder reveal, opening documentation URLs, save panels and drag haptics are navigation/observation/direct-manipulation feedback, not terminal success channels.
- SFTP upload/download and interactive SSH commands are transferred to the SSH/download lifecycle plans; this plan still forbids them from reusing cleanup success/history sinks.
- License activation, background definitions refresh and privacy feedback transport are covered by their TrustCore plans. License **deactivation** is included here because it destroys a seat binding and local license state.

## Canonical policy matrix

| Outcome | Mutation fact | History-capable operation | User success notification | Success visual | Success sound/haptic/particles | Internal invalidation | Retry |
|---|---|---|---|---|---|---|---|
| success | `.changed` | record `.success` facts | only kinds explicitly eligible | only `.celebratory` profile | only `.celebratory` profile | typed changed domains | none |
| success | `.none`, all unchanged | none | none | static neutral result | none | none | none |
| any terminal | `.possiblyChanged` | record conservative facts | none | status-only, never success theater | none | conservative typed domains | payload-selected safe retry/recovery only |
| partial | `.changed` / `.none` | record actual changed facts as `.partial` | none | amber/non-success | none | only domains actually changed | retryable failed/skipped/cancelled subjects only |
| failure | `.none` | none | none | red/non-success | none | none | retryable subjects only |
| cancelled | `.changed` / `.none` | record actual changed facts/receipts as `.cancelled` | none | neutral cancelled | none | only domains actually changed | payload-selected retryable remainder |

Irreversible kinds (`shred`, SFTP delete, remote host/tunnel destructive removal, permanent snapshot deletion) register the approved `.neutral` `OutcomeWorkflowProfile` and always use a static `checkmark.shield`/neutral completion on full success: no confetti, annihilation, count-up, success sound or haptic. Unknown operation kinds fail closed: no history, notification or success effect until registered in the tested registry.

---

### Task 1: Complete the Consumer Contract, Retry Selection and Per-Channel Gate

**Depends on:** operation-facts Tasks 1–4.

**Files:**
- Modify: `Sources/Domain/OperationOutcome.swift` only to add canonical `OperationKind` constants; do not change Tasks 1–4 reducer/mutation visibility
- Create: `Sources/Domain/OperationConsumerFacts.swift`
- Modify: `Sources/Domain/CleaningEngine.swift`
- Modify: `Sources/Features/OutcomeSideEffectPolicy.swift`
- Create: `Tests/DomainTests/OperationConsumerFactsTests.swift`
- Modify: `Tests/DomainTests/CleaningEngineTests.swift`
- Modify: `Tests/FeatureTests/OutcomeSideEffectPolicyTests.swift`

- [ ] **Step 1: Write RED tests for canonical kinds and exact retry selection**

Create reducer-built fixtures only. Tests must cover:

```swift
func testRetrySelectionKeepsOnlyRetryableNonSuccessSubjectsInInputOrder() throws
func testRetrySelectionDoesNotRetrySucceededUnchangedOrNonRetryableSubjects() throws
func testRetryCreatesNewIDAndPreservesParentID() throws
func testUnknownOperationKindHasFailClosedSemantics() throws
func testNeutralIrreversibleKindSuppressesEveryCelebratoryChannel() throws
func testOnlyCleaningExecuteIsCleaningNotificationEligible() throws
func testCallerCannotUpgradeNeutralOrUnknownKindToCelebratory() throws
func testCleaningPurposesProduceOnlyTheirCanonicalReportKinds() async
func testExternalClientCannotPassRawOperationKindAsCleaningPurposeOrMergePurpose() throws
```

`OperationConsumerFacts.retryableSubjectIDs(from:)` accepts the exact `[OperationItemOutcome]` stored by a strong payload; it does not infer subjects from aggregate counts and does not mutate the old outcome.

- [ ] **Step 2: Confirm RED**

Run:

```bash
swift test --filter OperationConsumerFactsTests --disable-automatic-resolution --skip-update
swift test --filter CleaningEngineTests --disable-automatic-resolution --skip-update
```

Expected: FAIL because canonical operation kinds, semantics, retry selector and the closed cleaning-purpose API do not exist.

- [ ] **Step 3: Add canonical kinds and pure subject helpers**

Add typed constants rather than new string literals in consumers:

```swift
public extension OperationKind {
    static let cleaningExecute = OperationKind("cleaning.execute")
    static let cleaningUndo = OperationKind("cleaning.undo")
    static let threatRemediation = OperationKind("threat.remediate")
    static let spaceTrash = OperationKind("space.trash")
    static let snapshotDelete = OperationKind("snapshot.delete")
    static let shred = OperationKind("shred.execute")
    static let uninstall = OperationKind("uninstall.execute")
    static let maintenance = OperationKind("maintenance.execute")
    static let helperInstall = OperationKind("helper.install")
    static let iCloudEvict = OperationKind("icloud.evict")
    static let appTerminate = OperationKind("optimization.terminate")
    static let launchAgentToggle = OperationKind("optimization.launchAgent")
    static let memoryPurge = OperationKind("optimization.memoryPurge")
    static let appUpdateCheck = OperationKind("update.thirdParty.check")
    static let xicoUpdateCheck = OperationKind("update.xico.check")
    static let sftpDelete = OperationKind("remote.sftp.delete")
    static let hostDelete = OperationKind("remote.host.delete")
    static let tunnelDelete = OperationKind("remote.tunnel.delete")
    static let remoteDisconnect = OperationKind("remote.disconnect")
    static let snippetDelete = OperationKind("server.snippet.delete")
    static let downloadJob = OperationKind("download.job")
    static let componentInstall = OperationKind("download.component.install")
    static let historyClear = OperationKind("history.clear")
    static let benchmarkHistoryClear = OperationKind("benchmark.history.clear")
    static let ignoreRemove = OperationKind("ignore.remove")
    static let onboardingReset = OperationKind("settings.onboarding.reset")
    static let licenseDeactivate = OperationKind("license.deactivate")
}

public enum CleaningOperationPurpose: Sendable {
    case standard
    case spaceTrash
    case uninstall

    var operationKind: OperationKind {
        switch self {
        case .standard: return .cleaningExecute
        case .spaceTrash: return .spaceTrash
        case .uninstall: return .uninstall
        }
    }
}
```

Change `CleaningEngine.execute` to accept `purpose: CleaningOperationPurpose = .standard` and pass only `purpose.operationKind` to both the reducer and its internal-failure fallback. The API must not accept a caller-supplied raw `OperationKind`; the closed enum prevents Space Trash or uninstall from masquerading as notification-eligible standard cleaning. Existing callers retain `.standard`; Tasks 5 and 6 pass `.spaceTrash` and `.uninstall`. Focused engine tests prove the three returned `CleaningReport.operation.kind` values, and a normal-import compile-negative fixture proves an arbitrary raw kind cannot be supplied to either execution or report merging.

Add `OperationConsumerFacts.retryableSubjectIDs(from:)` and `retryRequest(parent:kind:subjects:...)`. The latter calls the reducer with a fresh operation ID only after the new executor returns item outcomes; it never fabricates a terminal outcome before execution.

In `OperationConsumerFacts.swift`, define the single cross-target semantics registry used by Domain, Infrastructure and Features:

```swift
public enum OutcomeWorkflowProfile: String, Sendable {
    case celebratory, neutral
}

public enum OutcomeInvalidationDomain: String, Hashable, Sendable {
    case diskCapacity, scanIndex, cleaningHistory, installedApps
    case launchAgents, runningApplications, remoteDirectory, remoteConnections
    case serverConfiguration, tunnels, downloadComponents
    case benchmarkHistory, ignoreList, license
}

public struct OutcomeOperationSemantics: Sendable {
    public let profile: OutcomeWorkflowProfile
    public let recordsHistory: Bool
    public let allowsCleaningSuccessNotification: Bool
    public let invalidationDomains: Set<OutcomeInvalidationDomain>

    // Internal: callers may read reviewed semantics but cannot forge capabilities.
    init(profile: OutcomeWorkflowProfile, recordsHistory: Bool,
         allowsCleaningSuccessNotification: Bool,
         invalidationDomains: Set<OutcomeInvalidationDomain>) {
        self.profile = profile
        self.recordsHistory = recordsHistory
        self.allowsCleaningSuccessNotification = allowsCleaningSuccessNotification
        self.invalidationDomains = invalidationDomains
    }
}

public enum OutcomeOperationRegistry {
    public static func semantics(for kind: OperationKind) -> OutcomeOperationSemantics? {
        switch kind {
        case .cleaningExecute:
            return .init(profile: .celebratory, recordsHistory: true,
                         allowsCleaningSuccessNotification: true,
                         invalidationDomains: [.diskCapacity, .scanIndex, .cleaningHistory])
        case .cleaningUndo:
            return .init(profile: .neutral, recordsHistory: false,
                         allowsCleaningSuccessNotification: false,
                         invalidationDomains: [.diskCapacity, .scanIndex, .cleaningHistory])
        case .threatRemediation:
            return .init(profile: .neutral, recordsHistory: false,
                         allowsCleaningSuccessNotification: false,
                         invalidationDomains: [.diskCapacity, .scanIndex])
        case .spaceTrash:
            return .init(profile: .celebratory, recordsHistory: true,
                         allowsCleaningSuccessNotification: false,
                         invalidationDomains: [.diskCapacity, .scanIndex, .cleaningHistory])
        case .snapshotDelete:
            return .init(profile: .neutral, recordsHistory: false,
                         allowsCleaningSuccessNotification: false,
                         invalidationDomains: [.diskCapacity])
        case .shred:
            return .init(profile: .neutral, recordsHistory: true,
                         allowsCleaningSuccessNotification: false,
                         invalidationDomains: [.diskCapacity, .cleaningHistory])
        case .uninstall:
            return .init(profile: .celebratory, recordsHistory: true,
                         allowsCleaningSuccessNotification: false,
                         invalidationDomains: [.diskCapacity, .installedApps, .cleaningHistory])
        case .maintenance, .iCloudEvict:
            return .init(profile: .neutral, recordsHistory: false,
                         allowsCleaningSuccessNotification: false,
                         invalidationDomains: [.diskCapacity])
        case .helperInstall, .appUpdateCheck, .xicoUpdateCheck,
             .downloadJob, .onboardingReset:
            return .init(profile: .neutral, recordsHistory: false,
                         allowsCleaningSuccessNotification: false,
                         invalidationDomains: [])
        case .appTerminate, .memoryPurge:
            return .init(profile: .neutral, recordsHistory: false,
                         allowsCleaningSuccessNotification: false,
                         invalidationDomains: [.runningApplications])
        case .launchAgentToggle:
            return .init(profile: .neutral, recordsHistory: false,
                         allowsCleaningSuccessNotification: false,
                         invalidationDomains: [.launchAgents])
        case .sftpDelete:
            return .init(profile: .neutral, recordsHistory: false,
                         allowsCleaningSuccessNotification: false,
                         invalidationDomains: [.remoteDirectory])
        case .hostDelete, .snippetDelete:
            return .init(profile: .neutral, recordsHistory: false,
                         allowsCleaningSuccessNotification: false,
                         invalidationDomains: [.serverConfiguration])
        case .tunnelDelete:
            return .init(profile: .neutral, recordsHistory: false,
                         allowsCleaningSuccessNotification: false,
                         invalidationDomains: [.tunnels, .serverConfiguration])
        case .remoteDisconnect:
            return .init(profile: .neutral, recordsHistory: false,
                         allowsCleaningSuccessNotification: false,
                         invalidationDomains: [.remoteConnections])
        case .componentInstall:
            return .init(profile: .neutral, recordsHistory: false,
                         allowsCleaningSuccessNotification: false,
                         invalidationDomains: [.downloadComponents])
        case .historyClear:
            return .init(profile: .neutral, recordsHistory: false,
                         allowsCleaningSuccessNotification: false,
                         invalidationDomains: [.cleaningHistory])
        case .benchmarkHistoryClear:
            return .init(profile: .neutral, recordsHistory: false,
                         allowsCleaningSuccessNotification: false,
                         invalidationDomains: [.benchmarkHistory])
        case .ignoreRemove:
            return .init(profile: .neutral, recordsHistory: false,
                         allowsCleaningSuccessNotification: false,
                         invalidationDomains: [.ignoreList])
        case .licenseDeactivate:
            return .init(profile: .neutral, recordsHistory: false,
                         allowsCleaningSuccessNotification: false,
                         invalidationDomains: [.license])
        default:
            return nil
        }
    }
}
```

The switch above is the executable source of truth; the table below is its review checklist:

| Kinds | Profile | History | Cleaning notification | Invalidation domains |
|---|---|---:|---:|---|
| `cleaningExecute` | celebratory | yes | **yes** | diskCapacity, scanIndex, cleaningHistory |
| `cleaningUndo` | neutral | no | no | diskCapacity, scanIndex, cleaningHistory |
| `threatRemediation` | neutral | no | no | diskCapacity, scanIndex |
| `spaceTrash` | celebratory | yes | no | diskCapacity, scanIndex, cleaningHistory |
| `snapshotDelete` | neutral | no | no | diskCapacity |
| `shred` | neutral | yes | no | diskCapacity, cleaningHistory |
| `uninstall` | celebratory | yes | no | diskCapacity, installedApps, cleaningHistory |
| `maintenance`, `iCloudEvict` | neutral | no | no | diskCapacity |
| `helperInstall`, `appUpdateCheck`, `xicoUpdateCheck`, `downloadJob`, `onboardingReset` | neutral | no | no | none |
| `appTerminate`, `memoryPurge` | neutral | no | no | runningApplications |
| `launchAgentToggle` | neutral | no | no | launchAgents |
| `sftpDelete` | neutral | no | no | remoteDirectory |
| `hostDelete`, `snippetDelete` | neutral | no | no | serverConfiguration |
| `tunnelDelete` | neutral | no | no | tunnels, serverConfiguration |
| `remoteDisconnect` | neutral | no | no | remoteConnections |
| `componentInstall` | neutral | no | no | downloadComponents |
| `historyClear` | neutral | no | no | cleaningHistory |
| `benchmarkHistoryClear` | neutral | no | no | benchmarkHistory |
| `ignoreRemove` | neutral | no | no | ignoreList |
| `licenseDeactivate` | neutral | no | no | license |

Move the Task 3-local `OutcomeWorkflowProfile` declaration to this Domain file rather than defining a second same-named type. Unknown kinds have no row and therefore no history, notification, celebration or invalidation permission.

- [ ] **Step 4: Write RED tests for bounded channel independence and policy matrix**

```swift
func testHistoryConsumptionDoesNotConsumeNotificationOrCelebrationChannel() async
func testConcurrentConsumptionOfSameChannelSucceedsExactlyOnce() async
func testReregisteringSameOperationIDDoesNotResetConsumedChannels() async
func testRegisteringNewOperationRejectsOldOperationID() async
func testGateStorageRemainsConstantAcrossManyTerminalOperations() async
func testAppearanceCannotRegisterAnOperationOrReplayEffects() async
func testHistoricalOutcomeCannotRegisterOrConsumeLiveEffects() async
func testPartialChangedAllowsHistoryAndInvalidationButNoSuccessFeedback() throws
func testCancelledChangedPreservesHistoryAndInvalidationButNoSuccessFeedback() throws
func testSuccessUnchangedSuppressesAllChangedChannels() throws
func testShredAndRemoteDeleteNeverAllowNotificationOrCelebrationEvenWhenSuccessful() throws
func testPossiblyChangedNeverNotifiesOrCelebrates() throws
func testUnknownKindSuppressesHistoryNotificationCelebrationAndInvalidation() throws
```

- [ ] **Step 5: Consume the approved bounded gate and make policy registry-only**

Do **not** redefine or edit `OutcomeEffectChannel` or `OutcomeFeedbackGate`; operation-facts Task 3 is their sole code owner. This task's tests import and exercise that exact actor. Keep its storage invariant at one `currentOperationID` plus one finite `Set<OutcomeEffectChannel>`; never introduce `OutcomeChannel`, `OutcomeChannelGate`, a dictionary or an unbounded `Set<(UUID, Channel)>`.

```swift
enum OutcomeSideEffectPolicy {
    static func evaluate(_ outcome: OperationOutcome) -> OutcomeSideEffectDecision {
        guard let semantics = OutcomeOperationRegistry.semantics(for: outcome.kind) else {
            return OutcomeSideEffectDecision(
                history: .none, successNotification: .suppressed,
                celebration: .suppressed, broadcastsInternalInvalidation: false)
        }
        return evaluateRegistered(outcome, semantics: semantics)
    }

    private static func evaluateRegistered(
        _ outcome: OperationOutcome,
        semantics: OutcomeOperationSemantics
    ) -> OutcomeSideEffectDecision {
        let mutated = outcome.mutation != .none
        let invariant = outcome.issues.contains { $0.category == .internalInvariant }
        let feedbackSafe = outcome.status == .success
            && outcome.mutation == .changed && !invariant
        return OutcomeSideEffectDecision(
            history: mutated && semantics.recordsHistory
                ? .record(status: invariant ? .partial : outcome.status) : .none,
            successNotification: feedbackSafe && semantics.allowsCleaningSuccessNotification
                ? .allowed : .suppressed,
            celebration: feedbackSafe && semantics.profile == .celebratory
                ? .allowed : .suppressed,
            broadcastsInternalInvalidation: mutated
                && !semantics.invalidationDomains.isEmpty)
    }
}
```

Remove every caller-accessible policy overload that accepts a raw profile or notification Boolean. `evaluateRegistered` is private to `OutcomeSideEffectPolicy.swift`: history requires `mutation != .none && semantics.recordsHistory`; notification requires full changed invariant-free success plus `allowsCleaningSuccessNotification`; celebration requires full changed invariant-free success plus `.celebratory`; invalidation requires changed/possibly-changed plus nonempty registered domains. `.failClosed` suppresses every field. This extends the existing policy; it does not create a second policy type.

One long-lived live ViewModel owns the existing gate and calls `registerTerminal` exactly once at a new live terminal transition. Re-registering the same ID preserves consumed channels; a new ID evicts the previous ID/channels. Rendering, `onAppear`, history loading and historical outcome presentation never register. Historical records never receive a live gate.

- [ ] **Step 6: Run focused tests**

```bash
swift test --filter OperationConsumerFactsTests --disable-automatic-resolution --skip-update
swift test --filter CleaningEngineTests --disable-automatic-resolution --skip-update
swift test --filter OutcomeSideEffectPolicyTests --disable-automatic-resolution --skip-update
```

Expected: PASS, including independent one-time consumption for every channel.

- [ ] **Step 7: Commit the consumer contract when executing this plan**

```bash
git add Sources/Domain/OperationOutcome.swift Sources/Domain/OperationConsumerFacts.swift Sources/Domain/CleaningEngine.swift Sources/Features/OutcomeSideEffectPolicy.swift Tests/DomainTests/OperationConsumerFactsTests.swift Tests/DomainTests/CleaningEngineTests.swift Tests/FeatureTests/OutcomeSideEffectPolicyTests.swift
git commit -m "feat: define outcome consumer contracts"
```

---

### Task 2: Add Validated History, Notification and Internal-Invalidation Boundaries

**Depends on:** outcome-workflows Task 1 and operation-facts Task 4's schema/load-state/transaction/idempotency implementation. This task consumes Task 1's registry, wires sinks and adds notification/invalidation boundaries; it does not define a second history DTO or transaction API.

**Files:**
- Create: `Sources/Infrastructure/ShredderPayload.swift`
- Modify: `Sources/Infrastructure/HistoryStore.swift`
- Modify: `Sources/Infrastructure/Notifier.swift`
- Create: `Sources/Infrastructure/OutcomeInvalidationCenter.swift`
- Modify: `Sources/Infrastructure/XicoEnvironment.swift`
- Modify: `Sources/Features/AppModel.swift`
- Modify: `Tests/IntegrationTests/HistoryStoreTests.swift`
- Create: `Tests/IntegrationTests/OutcomeSinkBoundaryTests.swift`

- [ ] **Step 1: Write RED tests for validated requests**

Test these exact boundaries:

```swift
func testHistoryWriterReturnsNotRecordedForMutationNone() throws
func testHistoryWriterPersistsPartialCancelledAndPossiblyChangedFacts() throws
func testValidatedCleaningNotificationOnlyAcceptsChangedFullSuccess() throws
func testValidatedCleaningNotificationRejectsShredRemoteAndUnknownKinds() throws
func testValidatedCleaningNotificationDerivesMetricsFromClosedReport() throws
func testInvalidationRequestRequiresMutationAndNonEmptyRegisteredDomains() throws
func testInvalidationRequestRejectsDomainsOutsideRegisteredKindSemantics() throws
func testExternalInvalidationFakeCanConformToPublicProtocol() throws
func testHistoryRecordIsIdempotentByOperationID() throws
func testInvalidationEventDoesNotMasqueradeAsUserNotification() throws
```

Legacy JSON remains decodable as `legacyUnknown`; it never counts as success.

- [ ] **Step 2: Confirm RED**

Run: `swift test --filter OutcomeSinkBoundaryTests --disable-automatic-resolution --skip-update`

Expected: FAIL because injected sink protocols, validated notification delivery and invalidation center do not exist; Task 4 history persistence tests are already GREEN.

- [ ] **Step 3: Use the approved history writer and validated notification types**

Use the exact operation-facts contracts; do not add `OutcomeHistoryRequest`, `CleaningDoneNotificationRequest` or a generic caller-forgeable record:

```swift
public protocol OutcomeHistoryWriting: Sendable {
    func record(module: String, report: CleaningReport, date: Date) -> HistoryRecordResult
    func record(module: String, result: OperationResult<ShredderPayload>, date: Date) -> HistoryRecordResult
    func remove(id: UUID) -> HistoryUpdateResult
    func updateRestorable(id: UUID, to: [RestorableItem]) -> HistoryUpdateResult
}

public struct ValidatedCleaningNotification: Sendable {
    public let operationID: UUID
    public let reclaimedBytes: Int64
    public let changedCount: Int

    public init?(report: CleaningReport) {
        let outcome = report.operation
        guard OutcomeOperationRegistry.semantics(for: outcome.kind)?
                .allowsCleaningSuccessNotification == true,
              outcome.status == .success,
              outcome.mutation == .changed,
              outcome.counts.succeeded > 0,
              !outcome.issues.contains(where: { $0.category == .internalInvariant }) else {
            return nil
        }
        operationID = outcome.id
        reclaimedBytes = report.reclaimedBytes
        changedCount = outcome.counts.succeeded
    }
}

public protocol CleaningNotificationSending: Sendable {
    func send(_ request: ValidatedCleaningNotification)
}

public enum OutcomeInvalidationPublishResult: Equatable, Sendable {
    case published
    case rejected(code: String)
}

public struct ValidatedOutcomeInvalidation: Sendable {
    public let outcome: OperationOutcome
    public let domains: Set<OutcomeInvalidationDomain>

    public init?(outcome: OperationOutcome, domains: Set<OutcomeInvalidationDomain>) {
        guard outcome.mutation == .changed || outcome.mutation == .possiblyChanged,
              !domains.isEmpty,
              let registered = OutcomeOperationRegistry.semantics(for: outcome.kind)?
                .invalidationDomains,
              domains.isSubset(of: registered) else { return nil }
        self.outcome = outcome
        self.domains = domains
    }
}

public protocol OutcomeInvalidationPublishing: Sendable {
    func publish(_ request: ValidatedOutcomeInvalidation) -> OutcomeInvalidationPublishResult
}
```

Define the payload referenced by the public protocol now, before Task 7 consumes it:

```swift
public struct ShredderItemResult: Sendable {
    public let requestID: UUID
    public let url: URL
    public let disposition: OperationDisposition
    public let mutation: OperationMutationFact
    public let freedBytes: Int64

    init(requestID: UUID, url: URL, disposition: OperationDisposition,
         mutation: OperationMutationFact, freedBytes: Int64) {
        self.requestID = requestID
        self.url = url
        self.disposition = disposition
        self.mutation = mutation
        self.freedBytes = max(0, freedBytes)
    }
}

public struct ShredderPayload: Sendable {
    public let items: [ShredderItemResult]
    public let freedBytes: Int64

    init(items: [ShredderItemResult]) {
        self.items = items
        self.freedBytes = items.reduce(0) { total, item in
            let (sum, overflow) = total.addingReportingOverflow(item.freedBytes)
            return overflow ? .max : sum
        }
    }
}
```

Payload initializers remain Infrastructure-internal; Features can read but cannot forge shred facts. `ValidatedCleaningNotification(report:)` derives outcome, bytes and count from one closed `CleaningReport`; it accepts only the registry's notification-eligible kind (`cleaningExecute`) plus `.success`, mutation exactly `.changed`, succeeded count > 0 and no internal invariant. Shred, remote and unknown kinds fail before formatting/delivery even if their outcome is full changed success; `.possiblyChanged` is never notification-safe. `Notifier` formats localized bytes internally; no caller-supplied `(String, Int)` or `(OperationOutcome, Int64)` boundary is permitted. Keep the legacy static/instance scalar entry point only until its two consumers migrate in Task 4; Task 14 owns deletion of the declaration and proves every capitalization/instance spelling is absent.

Cleaning/uninstall/Space history is written from read-only reducer-backed `CleaningReport`; shred history uses the dedicated read-only `OperationResult<ShredderPayload>` overload. Mark both `HistoryStore` protocol witnesses `public` so the public Infrastructure protocol is usable from Features. Both typed adapters convert to one internal `ValidatedHistoryRecordCandidate` and call operation-facts Task 4's single candidate→persist→publish transaction. The shred conversion supplies permanent intent and never persists `ShredderItemResult.url`; only successful Trash `CleaningReport` facts may persist a protected receipt. Never add a generic public initializer that accepts caller-supplied status/counts/bytes.

- [ ] **Step 4: Reuse, do not redefine, operation-facts Task 4 history semantics**

`CleaningRecord` already persists operation ID, parent ID, operation kind, `HistoryOutcomeStatus`, mutation, all six counts, item facts and receipts. `HistoryStore.record(module:report:)` returns `HistoryRecordResult`, is idempotent by operation ID and never duplicates totals. Consumers handle `.inserted`, `.alreadyRecorded`, `.notRecordedNoChanges` and `.rejected` explicitly. `totalSuccessfulCleanups` counts only trusted `.success + .changed`; display record count is `totalHistoryRecords`, never mislabeled success.

Keep Task 4's degraded read-only and legacy preservation behavior intact. The old scalar overload may remain only during migration; Tasks 4, 6 and 7 remove all callers, and Task 14 proves both calls **and the overload declaration** are gone.

- [ ] **Step 5: Replace `.xicoDidClean` with typed invalidation**

Use the Domain `OutcomeInvalidationDomain` and `OutcomeOperationRegistry` defined in Task 1; do not define a second enum or capability map in Infrastructure. `OutcomeInvalidationCenter` publicly conforms to `OutcomeInvalidationPublishing`; its witness accepts only `ValidatedOutcomeInvalidation`, then publishes an `OutcomeInvalidationEvent` containing operation ID, kind, status, mutation and domains—never localized messages, paths, remote commands, endpoints, credentials or raw errors. Unknown kinds and empty/out-of-registry domains fail request construction. Update `AppModel`, Settings history and scan observers to filter domains instead of subscribing to `.xicoDidClean`.

- [ ] **Step 6: Inject sinks for deterministic consumer tests**

Add protocol-backed history/notifier/invalidation dependencies to `XicoEnvironment` with live defaults and fake injection. Because Features is a separate SwiftPM target, the environment's sink properties, initializer parameters, protocols and protocol witnesses must all be public; implementation-only candidate/DTO types remain internal/private:

```swift
public let history: HistoryStore
public let historySink: any OutcomeHistoryWriting
public let cleaningNotifier: any CleaningNotificationSending
public let invalidationSink: any OutcomeInvalidationPublishing
```

Live construction injects `OutcomeInvalidationCenter` as the protocol witness; external Feature tests inject a fake `OutcomeInvalidationPublishing` conformer. Do not make tests wait on global `NotificationCenter` sleeps or depend on the concrete center.

At a new live terminal transition the long-lived owner first calls `registerTerminal`, then independently consumes `.history`, `.successNotification` and `.internalInvalidation` immediately before each approved sink. Sink-level operation-ID idempotency remains a durable backstop. A repeated render/appearance and a loaded history record neither register nor consume any channel.

- [ ] **Step 7: Run focused tests**

```bash
swift test --filter OutcomeSinkBoundaryTests --disable-automatic-resolution --skip-update
swift test --filter HistoryStoreTests --disable-automatic-resolution --skip-update
```

Expected: PASS; repeated operation IDs do not duplicate history or notifications, and partial/cancelled internal refresh remains independent of user success notification.

- [ ] **Step 8: Commit when executing**

```bash
git add Sources/Infrastructure/ShredderPayload.swift Sources/Infrastructure/HistoryStore.swift Sources/Infrastructure/Notifier.swift Sources/Infrastructure/OutcomeInvalidationCenter.swift Sources/Infrastructure/XicoEnvironment.swift Sources/Features/AppModel.swift Tests/IntegrationTests/HistoryStoreTests.swift Tests/IntegrationTests/OutcomeSinkBoundaryTests.swift
git commit -m "feat: validate outcome side effect sinks"
```

---

### Task 3: Replace the Success-Only Completion Component with Honest Outcome Presentation

**Depends on:** outcome-workflows Tasks 1–2.

**Files:**
- Create: `Sources/Features/TaskOutcomePresentation.swift`
- Create: `Sources/Features/OutcomePresentationEffects.swift`
- Modify: `Sources/Features/SharedViews.swift`
- Create: `Tests/FeatureTests/TaskOutcomePresentationTests.swift`
- Create: `Tests/FeatureTests/TaskOutcomeAccessibilityTests.swift`
- Modify: all `Sources/DesignSystem/Resources/*.lproj/Localizable.strings`

- [ ] **Step 1: Write RED presentation tests for every terminal state**

Tests build outcomes through the reducer and assert icon, semantic role, title key, count summary, available actions, announcement and effect permissions for:

```swift
func testChangedSuccessUsesSuccessStateOnlyForCelebratorySafeKind() throws
func testUnchangedSuccessIsStaticNeutralAndSaysTargetAlreadySatisfied() throws
func testPartialUsesWarningIconTextRetryDetailsAndUndo() throws
func testFailureUsesErrorIconTextRecoveryAndNoCheckmark() throws
func testCancelledReportsCompletedBeforeCancelAndKeepsUndo() throws
func testIrreversibleSuccessUsesStaticShieldAndNoCelebration() throws
```

Assert partial/failure/cancelled are distinguishable without color and never use a success checkmark alone.

- [ ] **Step 2: Confirm RED**

Run: `swift test --filter TaskOutcomePresentationTests --disable-automatic-resolution --skip-update`

Expected: FAIL because the five-state presentation model and action model do not exist.

- [ ] **Step 3: Implement a pure presentation model**

Create:

```swift
struct TaskOutcomeContext: Sendable {
    let operation: OperationOutcome
    let affectedBytes: Int64?
    let primaryDetailKey: String
    let note: String?
    let canUndoChangedItems: Bool
    let retryableSubjectCount: Int
}

struct TaskOutcomeActions {
    var retry: (() -> Void)?
    var details: (() -> Void)?
    var undo: (() -> Void)?
    var recovery: (() -> Void)?
    var done: () -> Void
}
```

`TaskOutcomePresentation.make(context:semantics:)` derives all state text and symbols from the reducer outcome. Payload supplies only domain detail and available action capability; it cannot override status or counts.

- [ ] **Step 4: Add `TaskOutcomeView`, retain a fail-closed compatibility shim and centralize effects**

Add `TaskOutcomeView` without deleting the still-referenced `TaskCompletionView` declaration: seven production call sites remain until later consumer tasks. Convert `TaskCompletionView` into a compile-only compatibility shim that delegates layout to a private `LegacyTaskOutcomeCompatibilityView`, always renders a static neutral “migration pending” result, offers only the existing dismissal action, and never constructs an `OperationOutcome`, registers a gate, starts count-up, or instantiates success effects. Tasks 4–13 remove every invocation; Task 14 owns deletion of the shim declaration after its zero-call test turns RED. Put `XAnnihilationBurst`, `XCelebrationBurst`, `XSound.cleanDone` and `XHaptic.levelChange` only in `OutcomePresentationEffects.swift`. That owner requires policy `.celebration == .allowed` plus one-time `.celebration` / `.successSoundHaptic` consumption from the owning ViewModel's bounded gate.

For a kind registered with `.neutral` profile and irreversible presentation semantics, render a static shield confirmation. Other `.neutral` kinds render a static status. Only `.celebratory + success + mutation == .changed` without an invariant may instantiate an effect layer.

The live ViewModel calls `registerTerminal` before exposing the new terminal result. `TaskOutcomeView`, `OutcomePresentationEffects`, `onAppear`, re-rendering and historical presentation never register or reset the gate; a historical result receives no live gate and therefore cannot replay effects.

- [ ] **Step 5: Make Reduce Motion a construction-time gate**

With `accessibilityReduceMotion == true`:

- do not instantiate burst views;
- do not create delayed or count-up `Task`s;
- set final numeric value synchronously;
- keep focus and action order identical;
- announce status + counts + next action, not only a byte metric.

Add a pure `OutcomeMotionPlan` test so this is verifiable without timing or screenshots.

- [ ] **Step 6: Add accessibility and localization RED/GREEN coverage**

Add keys for all five presentation variants, six counts, retry failed items, retry remaining items, details, undo changed items, recovery actions and irreversible completion. Add them to all 11 locale files with exact placeholder parity.

`TaskOutcomeAccessibilityTests` asserts a nonempty label, status phrase, count summary, deterministic action order, no color-only state and no duplicate announcement per operation.

- [ ] **Step 7: Run focused regressions**

```bash
swift test --filter TaskOutcomePresentationTests --disable-automatic-resolution --skip-update
swift test --filter TaskOutcomeAccessibilityTests --disable-automatic-resolution --skip-update
swift test --filter LocalizationCoverageTests --disable-automatic-resolution --skip-update
swift test --filter LocalizationTests --disable-automatic-resolution --skip-update
swift test --filter TypeScaleTokenGuardTests --disable-automatic-resolution --skip-update
```

Expected: PASS, with no timing sleeps.

- [ ] **Step 8: Commit when executing**

```bash
git add Sources/Features/TaskOutcomePresentation.swift Sources/Features/OutcomePresentationEffects.swift Sources/Features/SharedViews.swift Tests/FeatureTests/TaskOutcomePresentationTests.swift Tests/FeatureTests/TaskOutcomeAccessibilityTests.swift Sources/DesignSystem/Resources
git commit -m "feat: present honest operation outcomes"
```

---

### Task 4: Finish Cleaning Consumers, Threat Remediation and Historical Undo

**This task is the execution of operation-facts Task 5 plus the two `CompletionView` consumers from Task 6.**

**Depends on:** outcome-workflows Tasks 1–3.

**Files:**
- Modify: `Sources/Domain/Models.swift`
- Modify: `Sources/Domain/CleaningEngine.swift`
- Modify: `Sources/Infrastructure/ThreatRemediation.swift`
- Modify: `Sources/Features/ModuleSessionViewModel.swift`
- Modify: `Sources/Features/SmartScanHub.swift`
- Modify: `Sources/Features/ScanViews.swift`
- Modify: `Sources/Features/SettingsView.swift`
- Modify: `Sources/Features/AppModel.swift`
- Create: `Tests/FeatureTests/CleaningOutcomeConsumerTests.swift`
- Create: `Tests/IntegrationTests/ThreatRemediationOutcomeTests.swift`
- Modify: `Tests/IntegrationTests/CleaningRoundTripTests.swift`

- [ ] **Step 1: Write RED consumer tests**

Use injected stateful filesystem/history/notifier/invalidation fakes and reducer outcomes. Required cases:

```swift
func testPartialCleaningRemovesOnlySucceededAndUnchangedSelections() async
func testPartialCleaningRecordsPartialButDoesNotNotifyOrCelebrate() async
func testCancelledCleaningKeepsCompletedReceiptsAndRetryableRemainder() async
func testMixedIntentSmartScanMergesEveryRequestOccurrenceExactlyOnce() async
func testReportMergeRejectsPurposeMismatchAndCannotRelabelFacts() throws
func testCrossChildDuplicateNormalizedPathsFailBeforeAnyDependency() async
func testRepeatedCallerItemIDsRemainDistinctRequestOccurrences() async
func testPartialUndoRetainsOnlyFailedReceiptsWithoutFabricatingReport() async
func testHistoricalUndoPassesRestorableItemsDirectly() async
func testFullChangedSuccessConsumesEachApprovedChannelExactlyOnce() async
```

- [ ] **Step 2: Confirm RED**

Run: `swift test --filter CleaningOutcomeConsumerTests --disable-automatic-resolution --skip-update`

Expected: FAIL because consumers still sum aggregates, set `.finished` unconditionally and call raw sinks.

- [ ] **Step 3: Implement reducer-backed report merge and undo**

Before starting any child execution, Module/Smart builds one parent-wide request inventory. Caller `itemID` may repeat and is never reducer identity. Group by `url.standardizedFileURL.path`; every occurrence in a duplicate-path group receives the reviewed nonretryable `cleaning.request.duplicateTarget` failure before safety, filesystem, helper or remediation calls. Only the remaining unique paths may be partitioned into child executions.

`CleaningReport.merging(_:purpose:parentID:)` accepts only the closed `CleaningOperationPurpose`, requires every child `report.operation.kind == purpose.operationKind`, then concatenates every child `CleaningItemResult` in request order and calls the reducer with per-occurrence request IDs. Module/Smart use `.standard`. The merge rejects a purpose mismatch, duplicate **request IDs** and fact/report inconsistencies, permits repeated caller item IDs, and never collapses occurrences by item ID. It cannot relabel standard cleaning as Space Trash/uninstall (or the reverse) to acquire different registry capabilities. Merge is fact aggregation, not authorization: it must not be used to approve a duplicate target after execution. No count or failure array is accepted as input truth.

Add `CleaningEngine.undo(_ items: [RestorableItem], parentID: UUID?) async -> OperationResult<UndoReport>`; keep the old report overload only as a delegating convenience until all callers migrate. A partial undo stores the remaining receipts directly; it does not construct a new `CleaningReport`.

- [ ] **Step 4: Make threat bootout a child operation instead of a swallowed pre-side-effect**

Change `ThreatRemediation.bootoutUserAgents` to return `OperationResult<ThreatRemediationReport>` with one requested subject per eligible plist. Invalid label/path is `.skipped(safetyPolicy/validation)`; confirmed not loaded is `.unchanged`; successful bootout is `.succeeded`; launchctl failure is `.failed` with an issue code, never a raw command/path.

Module and Smart Scan merge remediation and deletion as children of one parent operation. A deleted plist with failed bootout is partial and explains that the live agent may remain active. It never triggers full-success notification.

- [ ] **Step 5: Apply typed side effects and exact selection mutation**

For Module and Smart Scan:

- retain the terminal result for all nonempty outcomes;
- remove only `.succeeded` / `.unchanged` requested items;
- preserve failed/skipped/cancelled items and their selected state;
- build retry input from payload item outcomes with `retryable == true` and a new child operation ID;
- write cleaning history only through injected `OutcomeHistoryWriting.record(module:report:date:)` and handle every `HistoryRecordResult`;
- construct `ValidatedCleaningNotification(report:)` and send it only after policy `.successNotification == .allowed` and bounded `.successNotification` channel consumption;
- publish typed invalidation when any child is `.changed` or `.possiblyChanged`; the latter is a conservative refresh and still cannot enable success feedback;
- show `TaskOutcomeView` for success, partial, failure and cancelled rather than entering a success-only `.finished` branch.

- [ ] **Step 6: Remove all six legacy aggregate expressions**

`ScanViews` and `SettingsView` pass `CleaningRecord.restorable` to undo. Module and Smart keep remaining undo receipts in an undo payload, not a reconstructed cleaning report. Remove the legacy `CleaningReport(removedCount:reclaimedBytes:failures:restorable:)` initializer.

- [ ] **Step 7: Confirm the multiline zero gate**

Run:

```bash
rg -n -U --glob 'Sources/**/*.swift' 'CleaningReport\s*\(\s*removedCount:' Sources
swift test --filter CleaningOutcomeConsumerTests --disable-automatic-resolution --skip-update
swift test --filter ThreatRemediationOutcomeTests --disable-automatic-resolution --skip-update
swift test --filter CleaningRoundTripTests --disable-automatic-resolution --skip-update
swift test --filter HistoryStoreTests --disable-automatic-resolution --skip-update
```

Expected: `rg` has no output; all tests PASS.

- [ ] **Step 8: Commit when executing**

```bash
git add Sources/Domain/Models.swift Sources/Domain/CleaningEngine.swift Sources/Infrastructure/ThreatRemediation.swift Sources/Features/ModuleSessionViewModel.swift Sources/Features/SmartScanHub.swift Sources/Features/ScanViews.swift Sources/Features/SettingsView.swift Sources/Features/AppModel.swift Tests/FeatureTests/CleaningOutcomeConsumerTests.swift Tests/IntegrationTests/ThreatRemediationOutcomeTests.swift Tests/IntegrationTests/CleaningRoundTripTests.swift
git commit -m "fix: consume truthful cleaning outcomes"
```

---

### Task 5: Migrate Space Lens Single Trash, Basket, Undo and Snapshot Results

**Depends on:** outcome-workflows Tasks 1–4 and destructive-operations plan's local target authorization/identity contract. Do not add a direct `NSWorkspace.recycle` fallback.

**Files:**
- Modify: `Sources/Features/SpaceLensView.swift`
- Modify: `Sources/Features/CollectionBasket.swift`
- Modify: `Sources/Features/SunburstView.swift`
- Modify: `Sources/Features/TreemapView.swift`
- Modify: `Sources/Infrastructure/SpaceLedger.swift`
- Create: `Tests/FeatureTests/SpaceLensOutcomeTests.swift`
- Create: `Tests/FeatureTests/CollectionBasketOutcomeTests.swift`
- Modify: `Tests/IntegrationTests/SpaceLensAggregateSafetyTests.swift`
- Modify: `Tests/IntegrationTests/SpaceLensDeepDrillTests.swift`

- [ ] **Step 1: Write RED tests for the current false-success paths**

```swift
func testSingleTrashUsesCleaningEngineAndKeepsNodeOnFailure() async
func testBasketPartialKeepsFailedNodesSelectedAndPresentsPartial() async
func testBasketUsesReportAffectedBytesRatherThanDiskNodeEstimate() async
func testBasketCancellationDoesNotClearUnstartedNodes() async
func testPartialUndoGraftsOnlyRestoredNodesAndKeepsFailedReceipts() async
func testSpaceTrashReportUsesSpaceTrashKindAndCannotNotify() async
func testSnapshotFailureDoesNotShowCompletedState() async
func testIrreversibleSnapshotSuccessHasNoCelebrationChannels() async
```

Fakes record attempted URLs and dispositions but never call Finder Trash or `tmutil`.

- [ ] **Step 2: Confirm RED**

Run:

```bash
swift test --filter SpaceLensOutcomeTests --disable-automatic-resolution --skip-update
swift test --filter CollectionBasketOutcomeTests --disable-automatic-resolution --skip-update
```

Expected: FAIL because single trash bypasses CleaningEngine, basket clears every item and computes freed bytes from `DiskNode.size`.

- [ ] **Step 3: Route single Trash and basket through one report contract**

Change the basket executor closure to:

```swift
let performTrash: @Sendable ([DiskNode], UUID?) async -> CleaningReport

enum SpaceTrashLifecycle: Sendable {
    case idle
    case running(OperationProgress)
    case cancelling(OperationProgress)
    case terminal(CleaningReport)
}
```

Space Trash uses the cleaning-specialized carrier because its facts are exactly ordered `CleaningItemResult` values. The executor calls `CleaningEngine.execute(..., purpose: .spaceTrash)`, returns that closed `CleaningReport` directly, and never wraps it in `OperationResult` or fabricates another report in Features. The closed purpose makes `report.operation.kind == .spaceTrash`, so registry policy cannot accidentally grant the standard-cleaning notification capability. `itemID` maps each result back to its requested `DiskNode`, so successful prune identities and receipts are derived from the report rather than duplicated into a second payload. `SpaceLensModel.trash(_:)` calls the same path with one node. Remove `NSWorkspace.shared.recycle` from Features.

The model prunes only successful/unchanged nodes. It uses payload-reported reclaimed bytes; estimated node size may remain separately labeled “estimated before operation” but never appears as released fact.

- [ ] **Step 4: Preserve basket state and exact retry input**

`BasketModel` stores `SpaceTrashLifecycle`, not `completedBytes`. On partial/failure/cancelled it retains the exact failed/skipped/cancelled nodes in the basket, presents their count/recovery, and builds retry from retryable item facts with `parentID` pointing to the previous operation. The countdown sound remains countdown feedback; it is not a success sound and does not imply deletion completed.

- [ ] **Step 5: Keep partial undo receipts alive**

Undo returns reducer facts. Graft only restored nodes, keep remaining receipts and their original parent mapping, and allow retry only for retryable restore failures. Do not clear `lastReport` / `lastPruned` until no receipt remains or the user explicitly dismisses it.

- [ ] **Step 6: Make snapshot deletion structured and non-celebratory**

`SpaceLedger.deleteLocalSnapshot(named:)` returns `OperationResult<SnapshotDeletionReport>` with the snapshot name represented by an opaque subject ID and a stable issue code. The View keeps the failed snapshot in the list and uses irreversible `TaskOutcomeView` semantics. It never equates a `Bool` or helper launch with success.

- [ ] **Step 7: Apply validated effects**

Space Trash writes cleaning history through `OutcomeHistoryWriting.record(module:report:date:)` using the same returned `CleaningReport`, and invalidates disk/scan/history through typed requests. It does not send an OS cleanup notification unless the operation-kind registry explicitly permits it. Snapshot deletion only invalidates disk/snapshot facts and never enters cleaning history or celebratory channels.

- [ ] **Step 8: Run focused regressions**

```bash
swift test --filter SpaceLensOutcomeTests --disable-automatic-resolution --skip-update
swift test --filter CollectionBasketOutcomeTests --disable-automatic-resolution --skip-update
swift test --filter SpaceLensAggregateSafetyTests --disable-automatic-resolution --skip-update
swift test --filter SpaceLensDeepDrillTests --disable-automatic-resolution --skip-update
swift test --filter TreemapTests --disable-automatic-resolution --skip-update
```

Expected: PASS; no test reads or deletes outside its fake/disposable root.

- [ ] **Step 9: Commit when executing**

```bash
git add Sources/Features/SpaceLensView.swift Sources/Features/CollectionBasket.swift Sources/Features/SunburstView.swift Sources/Features/TreemapView.swift Sources/Infrastructure/SpaceLedger.swift Tests/FeatureTests/SpaceLensOutcomeTests.swift Tests/FeatureTests/CollectionBasketOutcomeTests.swift Tests/IntegrationTests/SpaceLensAggregateSafetyTests.swift Tests/IntegrationTests/SpaceLensDeepDrillTests.swift
git commit -m "fix: preserve space operation outcomes"
```

---

### Task 6: Migrate Uninstaller Consumer State, History, Retry and Undo

**Depends on:** outcome-workflows Tasks 1–4 and destructive-operations plan's exact ownership and required-App-body executor.

**Files:**
- Modify: `Sources/Features/UninstallerView.swift`
- Modify: `Sources/Infrastructure/UninstallerService.swift`
- Create: `Tests/FeatureTests/UninstallerOutcomeTests.swift`
- Create or Modify: `Tests/IntegrationTests/UninstallerOwnershipTests.swift`
- Modify: `Tests/IntegrationTests/CleaningRoundTripTests.swift`

- [ ] **Step 1: Write RED tests before changing the ViewModel**

```swift
func testAppBodyFailureAndResidualSuccessIsPartialAndKeepsAppSelected() async
func testPartialUninstallRemovesOnlySucceededTargets() async
func testUninstallFailureWritesNoSuccessHistoryOrNotification() async
func testPartialUninstallRecordsActualFactsAndRetainsReceipts() async
func testRetryUsesOnlyRetryableFailedTargetsAndSetsParentID() async
func testUninstallReportUsesUninstallKindAndCannotNotify() async
func testUninstallCompletionCannotCelebrateWithoutReducerSuccess() async
```

Use fixture apps in a fake ownership graph. Do not enumerate `/Applications` or move a real bundle.

- [ ] **Step 2: Confirm RED**

Run: `swift test --filter UninstallerOutcomeTests --disable-automatic-resolution --skip-update`

Expected: FAIL because `UninstallerModel.uninstall()` stores only aggregate bytes/counts, clears the selection for every terminal path and posts raw success side effects.

- [ ] **Step 3: Consume the cleaning-specialized `CleaningReport` contract**

The destructive executor's authorized uninstall plan already resolves `InstalledAppIdentity`, the required App-body `itemID`, and all owned targets. Because execution produces the same per-target `CleaningItemResult` facts as cleaning, it calls `CleaningEngine.execute(..., purpose: .uninstall)` and returns that closed `CleaningReport` directly; it does not embed that report/outcome in an `UninstallReport` or ask Features to construct a fact-backed report. The closed purpose makes `report.operation.kind == .uninstall`, so notification and installed-app invalidation semantics come from the correct registry row. The consumer keeps the authorized identity and required body `itemID` as request context, then correlates them with `CleaningReport.items`. It does not clear `selected` or `targets` until the corresponding item succeeded/was unchanged. If associated data moved but App body failed, title/detail must explicitly say that data was partially moved but the App remains installed. History uses `OutcomeHistoryWriting.record(module:report:date:)` and therefore reaches the same internal transaction without a new adapter.

- [ ] **Step 4: Apply typed effects and honest presentation**

Use the validated history request with actual status/counts/bytes/receipts. Publish installed-app/disk/history invalidation for `.changed` and conservatively for `.possiblyChanged`; the latter triggers refresh but never success notification or celebration. Do not call raw NotificationCenter or a raw notifier. Present every terminal status with retry/details/undo as allowed by payload facts.

Recoverable uninstall-to-Trash may use restrained ordinary success visual, but never a success effect for partial/failure/cancelled.

- [ ] **Step 5: Add retry and undo without rewriting the old operation**

Retry creates a new operation with only retryable failed/skipped subjects and `parentID = old.id`. Undo consumes only successful Trash receipts. Partial undo preserves failed receipts in the same way as cleaning and Space Lens.

- [ ] **Step 6: Run focused regressions**

```bash
swift test --filter UninstallerOutcomeTests --disable-automatic-resolution --skip-update
swift test --filter UninstallerOwnershipTests --disable-automatic-resolution --skip-update
swift test --filter CleaningRoundTripTests --disable-automatic-resolution --skip-update
```

Expected: PASS; wrong-owner/default-selection cases remain fail closed.

- [ ] **Step 7: Commit when executing**

```bash
git add Sources/Features/UninstallerView.swift Sources/Infrastructure/UninstallerService.swift Tests/FeatureTests/UninstallerOutcomeTests.swift Tests/IntegrationTests/UninstallerOwnershipTests.swift Tests/IntegrationTests/CleaningRoundTripTests.swift
git commit -m "fix: retain truthful uninstall outcomes"
```

---

### Task 7: Migrate Shredder Consumer and Enforce Non-Celebratory Permanent Semantics

**Depends on:** outcome-workflows Tasks 1–4 (including Task 2's `ShredderPayload`) and destructive-operations plan's shred I/O state machine. Do not reinterpret the current `(shredded, failed, freedBytes)` aggregate as item-complete.

**Files:**
- Modify: `Sources/Infrastructure/ShredderService.swift`
- Modify: `Sources/Infrastructure/XicoEnvironment.swift`
- Modify: `Sources/Features/ShredderView.swift`
- Create: `Tests/FeatureTests/ShredderOutcomeConsumerTests.swift`
- Modify: `Tests/IntegrationTests/ShredderServiceTests.swift`

- [ ] **Step 1: Write RED tests for cancel/partial/permanent UI semantics**

```swift
func testCancelBeforeFirstItemKeepsEveryFileAndPresentsCancelled() async
func testCancelAfterOneSuccessKeepsRemainingAndPreservesActualHistory() async
func testPossiblyModifiedFileRemainsVisibleWithManualRecoveryExplanation() async
func testPartialShredRetriesOnlyRetryableRemainingFiles() async
func testFullShredSuccessHasNoParticlesSoundHapticOrCountUp() async
func testShredFailureDoesNotPostCleaningDoneOrRawInvalidation() async
```

Consumer tests use a scripted `ShredderExecuting` fake. Service tests use only disposable synthetic files under their test root and never the user's home, Trash or an external volume.

- [ ] **Step 2: Confirm RED**

Run: `swift test --filter ShredderOutcomeConsumerTests --disable-automatic-resolution --skip-update`

Expected: FAIL because the service omits unstarted cancelled subjects and the view still maps full aggregate success to `TaskCompletionView` / `XCelebrationBurst`.

- [ ] **Step 3: Produce and consume the item-complete `ShredderPayload`**

Use the single `ShredderItemResult`/`ShredderPayload` types created in Task 2; do not introduce `ShredReport` or a second payload. `ShredderService` returns `OperationResult<ShredderPayload>` with one disposition for every requested URL, including unstarted cancelled subjects, and keeps any `cancelledPossiblyModified` issue. `ShredderModel.files` retains failed/skipped/cancelled subjects; it never removes an item merely because it is absent from `failed`.

- [ ] **Step 4: Apply history and invalidation without success theater**

Actual changed/possibly-changed item facts use the dedicated `OutcomeHistoryWriting.record(module:result: OperationResult<ShredderPayload>, date:)` overload, producing `.success`, `.partial` or `.cancelled` history as reducer facts require. Disk/history invalidation is permitted for `.changed`/`.possiblyChanged`. Shred never creates a cleanup user notification and its `.neutral` profile plus irreversible presentation semantics prohibit success visual effects, sound, haptic, confetti, annihilation and count-up even for a complete success.

Use a static irreversible outcome card with counts, details and done/retry actions.

- [ ] **Step 5: Run focused and service regressions**

```bash
swift test --filter ShredderOutcomeConsumerTests --disable-automatic-resolution --skip-update
swift test --filter ShredderServiceTests --disable-automatic-resolution --skip-update
```

Expected: PASS including hard-link, short-write, fsync, inode-change and cancellation cases supplied by the destructive plan.

- [ ] **Step 6: Commit when executing**

```bash
git add Sources/Infrastructure/ShredderService.swift Sources/Infrastructure/XicoEnvironment.swift Sources/Features/ShredderView.swift Tests/FeatureTests/ShredderOutcomeConsumerTests.swift Tests/IntegrationTests/ShredderServiceTests.swift
git commit -m "fix: present permanent deletion facts"
```

---

### Task 8: Migrate Maintenance, Helper Installation and iCloud Eviction

**Depends on:** outcome-workflows Tasks 1–4. This task itself owns introducing the local injectable maintenance/helper/iCloud executor contracts in Step 1; they are not an external prerequisite.

**Files:**
- Modify: `Sources/Infrastructure/MaintenanceRunner.swift`
- Modify: `Sources/Infrastructure/ICloudEvictor.swift`
- Modify: `Sources/Infrastructure/HelperProxy.swift`
- Modify: `Sources/Infrastructure/XicoEnvironment.swift`
- Modify: `Sources/Features/MaintenanceView.swift`
- Create: `Tests/FeatureTests/MaintenanceOutcomeTests.swift`
- Create: `Tests/IntegrationTests/MaintenanceRunnerOutcomeTests.swift`
- Create: `Tests/IntegrationTests/ICloudEvictorOutcomeTests.swift`

- [ ] **Step 1: Add injectable executor contracts and RED tests**

Define `MaintenanceExecuting`, `HelperInstalling` and `ICloudEvicting`; live implementations wrap Process/SMAppService/FileManager, tests use scripted fakes.

Required RED cases:

```swift
func testBatchCountsOnlySucceededOrUnchangedTasks() async
func testMixedBatchPresentsPartialAndOffersRetryFailedTasks() async
func testRootFailureNeverUsesCompletedState() async
func testHelperInstallFailureStaysFailureWithoutOpeningSuccessPath() async
func testICloudPartialKeepsFailedItemsAndReportsOnlyConfirmedFreedBytes() async
func testMaintenanceCancellationPreservesCompletedChildFacts() async
```

- [ ] **Step 2: Confirm RED**

Run: `swift test --filter MaintenanceOutcomeTests --disable-automatic-resolution --skip-update`

Expected: FAIL because `runAllUser()` increments `done` for every loop iteration and `maintDone` always opens a success page.

- [ ] **Step 3: Replace tuples with strong reports**

`MaintenanceRunner.run` returns `OperationResult<MaintenanceTaskReport>`. Batch uses one requested subject per task and reducer merge; command exit/request acceptance is not silently converted to “space freed.” For `thinSnapshots`, the UI says the system accepted/failed the thinning request unless a postcondition provides measured bytes.

`HelperProxy.install` is wrapped in an operation with registration/approval children. `requiresApproval` is a recoverable non-success state with an `openSettings` action, not install success.

- [ ] **Step 4: Make iCloud eviction item-complete**

Return one item outcome per requested ubiquitous item and actual confirmed local bytes. Keep failed/skipped/cancelled items in the summary for retry. The payload and UI continue to say cloud originals remain; do not offer Trash undo. Successful eviction is neutral, with disk invalidation but no cleaning notification or celebratory effect.

- [ ] **Step 5: Present single and batch results through the same model**

Remove `maintDone`. Store `OperationLifecycle<MaintenanceBatchReport>`. Single row results use `TaskOutcomePresentation`'s compact form; batch uses `TaskOutcomeView`. Root tasks and helper install are neutral/danger-aware. Only reducer full success can show a completed state, and maintenance never uses cleanup history/notifier.

- [ ] **Step 6: Run focused regressions without real processes/install/iCloud calls**

```bash
swift test --filter MaintenanceOutcomeTests --disable-automatic-resolution --skip-update
swift test --filter MaintenanceRunnerOutcomeTests --disable-automatic-resolution --skip-update
swift test --filter ICloudEvictorOutcomeTests --disable-automatic-resolution --skip-update
```

Expected: PASS; fakes assert zero live `Process`, SMAppService and iCloud calls.

- [ ] **Step 7: Commit when executing**

```bash
git add Sources/Infrastructure/MaintenanceRunner.swift Sources/Infrastructure/ICloudEvictor.swift Sources/Infrastructure/HelperProxy.swift Sources/Infrastructure/XicoEnvironment.swift Sources/Features/MaintenanceView.swift Tests/FeatureTests/MaintenanceOutcomeTests.swift Tests/IntegrationTests/MaintenanceRunnerOutcomeTests.swift Tests/IntegrationTests/ICloudEvictorOutcomeTests.swift
git commit -m "fix: reduce maintenance outcomes honestly"
```

---

### Task 9: Migrate Optimizer Termination, Launch-Agent Toggle and Memory Purge

**Depends on:** outcome-workflows Tasks 1–4. This task itself owns introducing the local injectable application/process executor contracts in Step 3; they are not an external prerequisite.

**Files:**
- Modify: `Sources/Infrastructure/OptimizationService.swift`
- Modify: `Sources/Infrastructure/XicoEnvironment.swift`
- Modify: `Sources/Features/OptimizationView.swift`
- Modify: `Sources/Features/MenuPanels.swift`
- Create: `Tests/FeatureTests/OptimizationOutcomeTests.swift`
- Create: `Tests/IntegrationTests/OptimizationServiceOutcomeTests.swift`

- [ ] **Step 1: Write RED tests around ignored postconditions**

```swift
func testRejectedTerminateIsFailureAndKeepsAppSelected() async
func testAcceptedButStillRunningAfterDeadlineIsFailure() async
func testAcceptedButStillRunningIsPossiblyChangedAndInvalidatesWithoutSuccessFeedback() async
func testBatchQuitCountsOnlyConfirmedExitedApplications() async
func testLaunchAgentRenameSuccessAndLaunchctlFailureIsPartial() async
func testLaunchAgentRenameFailureIsFailure() async
func testMemoryPurgeFailureIsNotDisplayedAsFreedMemory() async
func testMenuAndFullPageConsumeTheSamePurgeOutcomeContract() async
```

- [ ] **Step 2: Confirm RED**

Run: `swift test --filter OptimizationOutcomeTests --disable-automatic-resolution --skip-update`

Expected: FAIL because `quit(pid:)` discards `terminate()`'s Bool, batch counts every selected PID and publishes estimated bytes before a postcondition.

- [ ] **Step 3: Add injectable application/process boundaries**

Introduce `RunningApplicationTerminating` and `OptimizationProcessRunning`. A terminate operation distinguishes request rejected, request accepted but still running at bounded observation, confirmed exited and already absent (`unchanged`). Tests drive the clock/observation deterministically; no real App is terminated.

- [ ] **Step 4: Return composite launch-agent facts**

Represent persistent plist rename and current-session launchctl state as separate child subjects. Rename success + launchctl failure is partial with wording “下次登录会生效，当前会话未确认”; rename failure is failure; already desired state is unchanged. Retry targets only the failed child allowed by current identity.

- [ ] **Step 5: Replace this `TaskCompletionView` call site and estimated-success state**

Store reducer results in `OptimizationView`; retain only non-exited selected apps. Full page and MenuPanels use the same memory-purge result type. Estimated memory may be displayed before the request as an estimate; terminal affected bytes require measurement and otherwise remain absent.

Optimization uses neutral static result presentation, no cleaning history/notifier and no celebratory effects. Publish typed running-app/launch-agent invalidation for `.changed` and conservatively for `.possiblyChanged`; an accepted termination still running at the bounded observation deadline is failure + `.possiblyChanged`, refreshes running-app state, and never enables success feedback.

- [ ] **Step 6: Run focused regressions**

```bash
swift test --filter OptimizationOutcomeTests --disable-automatic-resolution --skip-update
swift test --filter OptimizationServiceOutcomeTests --disable-automatic-resolution --skip-update
```

Expected: PASS with zero live process termination or launchctl execution.

- [ ] **Step 7: Commit when executing**

```bash
git add Sources/Infrastructure/OptimizationService.swift Sources/Infrastructure/XicoEnvironment.swift Sources/Features/OptimizationView.swift Sources/Features/MenuPanels.swift Tests/FeatureTests/OptimizationOutcomeTests.swift Tests/IntegrationTests/OptimizationServiceOutcomeTests.swift
git commit -m "fix: verify optimization outcomes"
```

---

### Task 10: Migrate Third-Party and Xico Update Checks Without False “All Current” Success

**Depends on:** outcome-workflows Tasks 1–4 and updates-release-privacy plan for production trust roots; consumer tests run with a stub session only.

**Files:**
- Modify: `Sources/Infrastructure/AppUpdateService.swift`
- Modify: `Sources/Infrastructure/UpdateChecker.swift`
- Modify: `Sources/Features/AppUpdaterView.swift`
- Modify: `Sources/Features/SettingsView.swift`
- Create: `Tests/FeatureTests/AppUpdaterOutcomeTests.swift`
- Modify: `Tests/IntegrationTests/UpdateCheckerTests.swift`
- Modify: `Tests/IntegrationTests/UpdateFeedBoundsTests.swift`
- Modify: `Tests/IntegrationTests/UpdateSignatureTests.swift`

- [ ] **Step 1: Write RED tests for hidden network/parse failures**

```swift
func testAllCandidateFailuresPresentsFailureNotAllCurrent() async
func testOneVerifiedAndOneFailedPresentsPartialWithRetry() async
func testVerifiedCurrentIsSuccessUnchangedWithoutCelebration() async
func testAvailableUpdateLivesInPayloadWithoutClaimingSideEffect() async
func testXicoAvailableResultDoesNotOpenURLUntilExplicitButton() async
func testCancelledCheckPreservesCompletedCandidateFacts() async
```

Use a custom `URLProtocol` stub or injected `UpdateFetching`; no request leaves the test process.

- [ ] **Step 2: Confirm RED**

Run: `swift test --filter AppUpdaterOutcomeTests --disable-automatic-resolution --skip-update`

Expected: FAIL because `AppUpdateService.check` returns `nil` for transport, redirect, parse and trust failures, and an empty updates array opens the success completion page.

- [ ] **Step 3: Return per-candidate check facts**

Add:

```swift
public enum AppUpdateCheckFact: Sendable {
    case current(AppUpdateCandidate)
    case available(AppUpdateCandidate)
    case failed(candidateID: String, issue: OperationIssue)
}

public struct AppUpdateCheckPayload: Sendable {
    public let itemOutcomes: [OperationItemOutcome]
    public let facts: [AppUpdateCheckFact]
}
```

`AppUpdateService.check` returns `OperationResult<AppUpdateCheckPayload>`; the payload contains no nested outcome. Successfully verified current **or available** candidates use `.unchanged`, because checking did not mutate the app. Payload carries availability. Transport/redirect/parse/trust failures use `.failed` with stable issue codes. No update candidate disappears from the request accounting.

- [ ] **Step 4: Present truthful neutral states**

Replace this `TaskCompletionView` call site with `TaskOutcomeView`. All verified current is success+unchanged and static neutral; available updates display a list and explicit “前往下载”; mixed verified/failed is partial with retry failed candidates; all failed is failure. No branch celebrates, writes cleaning history, notifies cleaning completion or broadcasts disk invalidation.

Settings' Xico check stores its result and never automatically opens the download URL. Opening occurs only from a labeled user button after the available payload is visible.

- [ ] **Step 5: Run focused update regressions**

```bash
swift test --filter AppUpdaterOutcomeTests --disable-automatic-resolution --skip-update
swift test --filter UpdateCheckerTests --disable-automatic-resolution --skip-update
swift test --filter UpdateFeedBoundsTests --disable-automatic-resolution --skip-update
swift test --filter UpdateSignatureTests --disable-automatic-resolution --skip-update
```

Expected: PASS; the session stub records no unregistered URL and no real network access.

- [ ] **Step 6: Commit when executing**

```bash
git add Sources/Infrastructure/AppUpdateService.swift Sources/Infrastructure/UpdateChecker.swift Sources/Features/AppUpdaterView.swift Sources/Features/SettingsView.swift Tests/FeatureTests/AppUpdaterOutcomeTests.swift Tests/IntegrationTests/UpdateCheckerTests.swift Tests/IntegrationTests/UpdateFeedBoundsTests.swift Tests/IntegrationTests/UpdateSignatureTests.swift
git commit -m "fix: report update checks truthfully"
```

---

### Task 11: Migrate SFTP, Host, Tunnel, Disconnect and Snippet-Delete Consumers

**Depends on:** outcome-workflows Tasks 1–4 and ssh-sftp-hosts plan. Its identity/authorization/transaction APIs are mandatory; no string-path `rm` or fire-and-forget stop fallback is allowed.

**Files:**
- Modify: `Sources/Features/ServerFilesView.swift`
- Modify: `Sources/Features/ServersView.swift`
- Modify: `Sources/Features/ServersViewModel.swift`
- Modify: `Sources/Features/TunnelsView.swift`
- Modify: `Sources/Infrastructure/SFTPBrowser.swift`
- Modify: `Sources/Infrastructure/ServerHostStore.swift`
- Modify: `Sources/Infrastructure/KeychainSecretStore.swift`
- Modify: `Sources/Infrastructure/TunnelManager.swift`
- Modify: `Sources/Infrastructure/PortForwarder.swift`
- Create: `Tests/FeatureTests/RemoteOutcomeConsumerTests.swift`
- Create or Modify: `Tests/IntegrationTests/RemoteDeletionTransactionTests.swift`
- Modify: `Tests/IntegrationTests/SSHKeyConnectTests.swift`

- [ ] **Step 1: Write RED tests for current destructive ambiguity**

```swift
func testSFTPDeleteSuccessAndReloadFailureRemainSeparateFacts() async
func testSFTPDeleteFailureKeepsEntryAndDoesNotClaimRefreshFailure() async
func testSFTPRetryNeverDeletesAnAlreadyDeletedSubjectAgain() async
func testHostStoreFailureDoesNotDeleteKeychainFirst() async
func testHostDeletedButCredentialCleanupFailedPresentsPartialCleanupRetry() async
func testTunnelStopFailureKeepsConfiguration() async
func testTunnelStoppedButPersistenceFailedPresentsPartialSafeState() async
func testDisconnectAllReportsOneDispositionPerConnectedHost() async
func testSnippetPersistenceFailureKeepsSnippetVisible() async
func testEveryIrreversibleRemoteSuccessSuppressesCelebratoryChannels() async
```

Use fake remote identity, fake store, fake keychain and fake process waiters. No SSH/SFTP connection or signal is permitted.

- [ ] **Step 2: Confirm RED**

Run: `swift test --filter RemoteOutcomeConsumerTests --disable-automatic-resolution --skip-update`

Expected: FAIL because SFTP combines delete and reload in one `do/catch`, host deletion removes credentials before nonthrowing persistence, tunnel deletion does not await stop and snippet writes swallow errors.

- [ ] **Step 3: Consume the SSH plan's exact operation reports**

Required payloads:

```swift
public struct SFTPDeletionPayload: Sendable {
    public let itemOutcomes: [OperationItemOutcome]
    public let deletionReceipt: RemoteDeletionReceipt?
    public let refreshedSnapshot: RemoteDirectorySnapshot?
    public let deletionSubjectID: String
    public let refreshSubjectID: String?
}

public struct HostDeletionPayload: Sendable {
    public let itemOutcomes: [OperationItemOutcome]
    public let removedHostID: UUID?
    public let credentialCleanupSubjectIDs: [String]
}

public struct TunnelDeletionPayload: Sendable {
    public let itemOutcomes: [OperationItemOutcome]
    public let stopped: Bool
    public let configurationRemoved: Bool
}
```

The owning SSH APIs return `OperationResult<SFTPDeletionPayload>`, `OperationResult<HostDeletionPayload>` and `OperationResult<TunnelDeletionPayload>`. Each parent reducer accounts for deletion/refresh or stop/persistence as distinct subjects, while each payload contains item facts and domain data but no nested `OperationOutcome`/`OperationResult`. The consumer never reruns remote deletion merely to retry refresh. A successful delete plus failed reload says “已删除；列表刷新失败” and offers refresh only. Host/tunnel partial actions target only remaining cleanup/persistence subjects.

- [ ] **Step 4: Add explicit confirmation state to every destructive UI owner**

SFTP confirmation displays host, normalized absolute path, object type and irreversibility. Host confirmation displays endpoint, active connections/tunnels, jump dependencies and credential classes. Tunnel confirmation displays endpoints and active state. Snippet deletion gets a local-data confirmation if the snippet is user-created or edited.

All actions first build the authorized plan from the SSH plan; View buttons never call `remove`, `deleteHost`, `deleteTunnel` or `deleteSnippet` as a one-shot side effect.

- [ ] **Step 5: Use neutral outcome UI and typed invalidation**

Remote deletion, host deletion and tunnel deletion are irreversible/neutral: no sound, haptic, particles, annihilation or count-up. Publish only `.remoteDirectory`, `.serverConfiguration` or `.tunnels` changed domains. Do not write cleaning history or send cleaning notifications.

Disconnect-all is a neutral batch result with one subject per live host. It may be dismissed inline; partial/failure keeps connection rows and exact retry selection.

- [ ] **Step 6: Run focused regressions**

```bash
swift test --filter RemoteOutcomeConsumerTests --disable-automatic-resolution --skip-update
swift test --filter RemoteDeletionTransactionTests --disable-automatic-resolution --skip-update
swift test --filter SSHKeyConnectTests --disable-automatic-resolution --skip-update
```

Expected: PASS with zero live connection, process or Keychain mutation outside fakes.

- [ ] **Step 7: Commit when executing**

```bash
git add Sources/Features/ServerFilesView.swift Sources/Features/ServersView.swift Sources/Features/ServersViewModel.swift Sources/Features/TunnelsView.swift Sources/Infrastructure/SFTPBrowser.swift Sources/Infrastructure/ServerHostStore.swift Sources/Infrastructure/KeychainSecretStore.swift Sources/Infrastructure/TunnelManager.swift Sources/Infrastructure/PortForwarder.swift Tests/FeatureTests/RemoteOutcomeConsumerTests.swift Tests/IntegrationTests/RemoteDeletionTransactionTests.swift Tests/IntegrationTests/SSHKeyConnectTests.swift
git commit -m "fix: present remote mutation outcomes"
```

---

### Task 12: Adapt Download Lifecycle and Component Installation Outcomes

**Depends on:** outcome-workflows Tasks 1–4 and network-components plan for trusted installers and confirmation-before-network. Preserve `DownloadState`; do not replace the established queue state machine.

**Files:**
- Modify: `Sources/Infrastructure/DownloadManager.swift`
- Modify: `Sources/Infrastructure/DownloadEngine.swift`
- Modify: `Sources/Features/DownloaderView.swift`
- Create: `Sources/Features/DownloadOutcomeAdapter.swift`
- Create: `Tests/FeatureTests/DownloadOutcomeAdapterTests.swift`
- Create: `Tests/FeatureTests/ComponentInstallOutcomeTests.swift`
- Modify: `Tests/IntegrationTests/ComponentManifestTrustTests.swift`
- Modify: `Tests/IntegrationTests/TransportInputSafetyTests.swift`

- [ ] **Step 1: Write RED adapter and composite-install tests**

```swift
func testCompletedDownloadAdaptsToSuccessWithoutRewritingState() throws
func testFailedQuarantinedAndCancelledMapToDistinctOutcomes() throws
func testInstallEnginePrimarySuccessFFmpegFailureIsPartial() async
func testComponentInstallFailureRetainsRetryForOnlyFailedComponent() async
func testComponentSuccessIsNeutralAndDoesNotUseCleanupSinks() async
func testRemoveAndClearFinishedReportPersistenceFailure() async
```

- [ ] **Step 2: Confirm RED**

```bash
swift test --filter DownloadOutcomeAdapterTests --disable-automatic-resolution --skip-update
swift test --filter ComponentInstallOutcomeTests --disable-automatic-resolution --skip-update
```

Expected: FAIL because there is no adapter and `installEngine()` swallows ffmpeg failure with `try?`.

- [ ] **Step 3: Add a one-way terminal-state adapter**

`DownloadOutcomeAdapter` maps terminal `DownloadState` to an operation result for presentation/diagnostics. It never feeds back into `DownloadState` and never turns `.quarantined` into success. An adapter call for nonterminal state returns nil rather than fabricating a terminal result.

- [ ] **Step 4: Make component installation item-complete**

The composite “一键准备” request contains distinct subjects for yt-dlp and ffmpeg. ffmpeg best-effort behavior may keep primary engine usable, but the parent outcome is partial and the UI offers retry for ffmpeg. Standalone ffmpeg and aria2 use the same result type. Trusted receipt/postcondition comes from the network-components plan; a download finishing is not enough for `.succeeded`.

- [ ] **Step 5: Make queue mutations truthful**

`remove(job:)` and `clearFinished()` return changed/unchanged/persistence-failed item facts. If queue persistence fails, keep the in-memory item visible or mark the result partial according to the queue transaction contract; do not silently clear and lose recovery context.

- [ ] **Step 6: Present neutral results and keep side-effect domains separate**

Component install uses neutral static success; no cleanup history, cleaning notification or disk-cleaning invalidation. Publish `.downloadComponents` only after trusted postcondition. Existing job rows continue to show their native state and accessible actions.

- [ ] **Step 7: Run focused regressions with no network/subprocess**

```bash
swift test --filter DownloadOutcomeAdapterTests --disable-automatic-resolution --skip-update
swift test --filter ComponentInstallOutcomeTests --disable-automatic-resolution --skip-update
swift test --filter ComponentManifestTrustTests --disable-automatic-resolution --skip-update
swift test --filter TransportInputSafetyTests --disable-automatic-resolution --skip-update
```

Expected: PASS; injected installers/session/process fakes record zero live side effects.

- [ ] **Step 8: Commit when executing**

```bash
git add Sources/Infrastructure/DownloadManager.swift Sources/Infrastructure/DownloadEngine.swift Sources/Features/DownloaderView.swift Sources/Features/DownloadOutcomeAdapter.swift Tests/FeatureTests/DownloadOutcomeAdapterTests.swift Tests/FeatureTests/ComponentInstallOutcomeTests.swift Tests/IntegrationTests/ComponentManifestTrustTests.swift Tests/IntegrationTests/TransportInputSafetyTests.swift
git commit -m "fix: expose download and component outcomes"
```

---

### Task 13: Migrate Local History/Preference Data and License-Deactivation Outcomes

**Depends on:** outcome-workflows Tasks 1–4 and updates-release-privacy's seat-release/trust contract for license deactivation. Local history/preference subcases may proceed after Tasks 1–4 with isolated stores, but the license rows remain blocked until that upstream contract lands.

**Files:**
- Modify: `Sources/Infrastructure/HistoryStore.swift`
- Modify: `Sources/Infrastructure/DiskBenchmark.swift`
- Modify: `Sources/Infrastructure/IgnoreListStore.swift`
- Modify: `Sources/Infrastructure/LicenseService.swift`
- Modify: `Sources/Infrastructure/LicenseActivationClient.swift`
- Modify: `Sources/Features/SettingsView.swift`
- Modify: `Sources/Features/DiskBenchmarkView.swift`
- Modify: `Sources/Features/PricingView.swift`
- Create: `Tests/FeatureTests/LocalDataOutcomeTests.swift`
- Create: `Tests/FeatureTests/LicenseDeactivationOutcomeTests.swift`
- Modify: `Tests/IntegrationTests/HistoryStoreTests.swift`
- Modify: `Tests/IntegrationTests/SeatReleaseTests.swift`

- [ ] **Step 1: Write RED tests for swallowed local persistence and split remote/local state**

```swift
func testCleaningHistoryClearFailureKeepsRowsAndPresentsFailure() async
func testBenchmarkHistoryClearFailureKeepsRowsAndPresentsFailure() async
func testAlreadyEmptyHistoryClearIsSuccessUnchanged() async
func testIgnoreRemoveReturnsUnchangedWhenPathWasAbsent() async
func testOnboardingResetReportsChangedOnlyWhenAFlagChanged() async
func testPersistenceFailureAfterMutationAttemptIsPossiblyChangedAndInvalidates() async
func testRemoteSeatReleaseSuccessLocalClearFailureIsPartial() async
func testAmbiguousLocalLicenseClearIsPossiblyChangedAndInvalidates() async
func testRemoteSeatReleaseFailureDoesNotClearLocalLicense() async
```

Use isolated stores and a fake deactivation client. No production UserDefaults suite, Keychain, license file or endpoint may be touched.

- [ ] **Step 2: Confirm RED**

```bash
swift test --filter LocalDataOutcomeTests --disable-automatic-resolution --skip-update
swift test --filter LicenseDeactivationOutcomeTests --disable-automatic-resolution --skip-update
```

Expected: FAIL because current history clear paths swallow remove/write errors and license deactivation represents remote release + local clear as a single success note.

- [ ] **Step 3: Make local stores return changed/unchanged/failure/possibly-changed facts**

History clear, benchmark history clear and ignore removal become structured operations with injected directories/defaults. Pre-write validation failures are `.failed + .none`; a verified commit is `.succeeded + .changed`; already-absent data is `.unchanged + .none`; an error after remove/write/replace was invoked without a proven postcondition is `.failed + .possiblyChanged`. Views remove rows only after a succeeded/unchanged fact, but `.possiblyChanged` immediately triggers a conservative typed refresh before presentation. Cleaning-history clear is never itself inserted into the history being cleared; it publishes `.cleaningHistory` invalidation for `.changed` and `.possiblyChanged`.

Onboarding reset uses two requested preference subjects. Existing false values are unchanged; changed flags are succeeded. It remains a neutral inline result and does not use history/notification/celebration.

- [ ] **Step 4: Model license deactivation as a two-child transaction**

Child one is remote seat release; child two is local license/anchor clear. Remote failure prevents local clear. Remote success + local failure is partial and exposes “重试本地清理” without releasing the seat twice. If local clear was attempted but its postcondition is unknown, that child is `.failed + .possiblyChanged`, retains the remote receipt, and conservatively refreshes license state. Local license removal only occurs after the remote receipt is retained.

This task supplies the consumer contract; production endpoint/trust/privacy evidence remains owned by updates-release-privacy and cannot be marked verified from fakes.

- [ ] **Step 5: Present neutral state and typed invalidation**

Local clear/deactivation actions never use cleanup notification or celebratory feedback. Publish `.cleaningHistory`, `.benchmarkHistory`, `.ignoreList` or `.license` for `.changed` and conservatively for `.possiblyChanged`; the latter remains non-success and cannot enable celebration/notification. Failure keeps visible state and a retry/recovery action until the typed refresh proves the current state.

- [ ] **Step 6: Run focused regressions**

```bash
swift test --filter LocalDataOutcomeTests --disable-automatic-resolution --skip-update
swift test --filter LicenseDeactivationOutcomeTests --disable-automatic-resolution --skip-update
swift test --filter HistoryStoreTests --disable-automatic-resolution --skip-update
swift test --filter SeatReleaseTests --disable-automatic-resolution --skip-update
```

Expected: PASS with fake-only persistence/network/keychain calls.

- [ ] **Step 7: Commit when executing**

```bash
git add Sources/Infrastructure/HistoryStore.swift Sources/Infrastructure/DiskBenchmark.swift Sources/Infrastructure/IgnoreListStore.swift Sources/Infrastructure/LicenseService.swift Sources/Infrastructure/LicenseActivationClient.swift Sources/Features/SettingsView.swift Sources/Features/DiskBenchmarkView.swift Sources/Features/PricingView.swift Tests/FeatureTests/LocalDataOutcomeTests.swift Tests/FeatureTests/LicenseDeactivationOutcomeTests.swift Tests/IntegrationTests/HistoryStoreTests.swift Tests/IntegrationTests/SeatReleaseTests.swift
git commit -m "fix: report local data mutations honestly"
```

---

### Task 14: Enforce Zero-Ignore Ownership, Privacy and Full Offline Verification

**This task is the expanded execution of operation-facts Task 7.**

**Depends on:** outcome-workflows Tasks 1–13 and every destructive/SSH/network/update contract named by those tasks.

**Files:**
- Create: `Tests/FeatureTests/OutcomeConsumerArchitectureTests.swift`
- Create: `Tests/FeatureTests/OutcomeConsumerInventoryTests.swift`
- Create: `Tests/IntegrationTests/OutcomePrivacyTests.swift`
- Modify: `Sources/Features/SharedViews.swift`
- Modify: `Sources/Infrastructure/Notifier.swift`
- Modify: `Sources/Infrastructure/HistoryStore.swift`
- Modify: `scripts/quality_gate.sh`
- Modify: `docs/20-全量文档任务台账与95分验收矩阵-2026-07-16.md`

- [ ] **Step 1: Write a source gate that understands multiline callsites**

The architecture test scans production source with multiline-capable regular expressions and fails on any of these raw business paths:

- `TaskCompletionView` declaration or invocation;
- `CleaningReport\s*\(\s*removedCount:`;
- scalar production `history.record(module:...reclaimedBytes:...removedCount:)`;
- every scalar cleanup-notifier call or declaration, including whitespace/case-owner variants of `Notifier.notifyCleaningDone(...)`, instance/lowercase `notifier.cleaningDone(...)`, `func notifyCleaningDone(...)` and `func cleaningDone(...)`;
- raw `.xicoDidClean` post;
- Features-side `NSWorkspace.shared.recycle`;
- direct business-terminal `XCelebrationBurst`, `XAnnihilationBurst` or `XSound.cleanDone`, and any `XHaptic.levelChange` outside the two exact classified owners (outcome effects and the health-score threshold block);
- consumer-created `OperationOutcome` or manual terminal status/counts;
- known old false-success fields: `maintDone`, `completedBytes`, `lastFreed` as terminal truth, or aggregate `ShredderModel.Completion`.
- `OperationOutcome` gaining `Codable`/`Decodable`, an `init(from:)`, or a protocol/typealias/extension route to decoding;
- a public `CleaningItemResult` or fact-backed `CleaningReport(operation:items:)` initializer;
- any public Infrastructure history DTO/candidate/full-record initializer;
- the legacy scalar history-writer overload declaration, any `HistoryStore.totalCleanups` declaration/read, or a public generic history `insert`;
- `OutcomeChannel`, `OutcomeChannelGate`, a second gate declaration, or unbounded per-operation storage such as `Set<(UUID, Channel)>`/`[UUID: ...]`.

Add these exact tests:

```swift
func testViolatingMultilineSourceFixtureIsRejected() throws
func testExternalFeatureFixtureCanReadFactsAndEncodeOutcome() throws
func testExternalFeatureFixtureCannotConstructOperationOutcomeOrDomainFacts() throws
func testExternalFeatureFixtureCannotUseInfrastructureDTOOrGenericHistoryCandidate() throws
func testExternalSinkFixtureCanConformToPublicTypedProtocols() throws
func testOperationOutcomeCannotRegainAnyDecodableBoundary() throws
func testLegacyHistoryDeclarationsAndTotalCleanupsAreAbsent() throws
func testGateNameAndStorageRemainCanonicalAndBounded() throws
```

The external fixtures run `swiftc -typecheck` against the already-built local Domain/Infrastructure modules and never resolve packages or access the network. The positive normal-import Domain fixture reads every public `CleaningReport`/`CleaningItemResult` fact (including Task 3 intent/mutation) and encodes `OperationOutcome`; it must exit 0. Negative fixtures assert nonzero exit plus the expected inaccessible/nonconformance diagnostic. The positive sink fixture imports Infrastructure, defines fake `OutcomeHistoryWriting`, `CleaningNotificationSending` and `OutcomeInvalidationPublishing` conformers using the public typed signatures, and must typecheck. Recursively scan every production Swift file, including nested Domain/Infrastructure directories and extensions/typealiases. Do not skip fixtures by filename substring. The production scan excludes Tests entirely; the injected violating fixture uses a separate disposable source root so quoted pattern constants cannot self-match.

- [ ] **Step 2: Assert exact owners instead of broad allowlists**

`OutcomeConsumerInventoryTests` asserts:

- `XAnnihilationBurst`, `XCelebrationBurst` and `XSound.cleanDone` occur only in `OutcomePresentationEffects.swift`; `XHaptic.levelChange` has exactly that outcome owner plus the explicitly tested health-score threshold owner in `ScanViews`;
- cleaning-history writes occur only through the public typed `OutcomeHistoryWriting.record(module:report:date:)` and `record(module:result: OperationResult<ShredderPayload>, date:)` witnesses; both route to the one internal validated transaction;
- cleanup notification delivery occurs only through `CleaningNotificationSending.send(_ request: ValidatedCleaningNotification)` and no scalar notifier declaration remains;
- operation-terminal invalidation publishes only through `OutcomeInvalidationPublishing`; `OutcomeInvalidationCenter` is the sole live witness while external Feature fakes may conform, and the 8 remaining direct `scanIndex.invalidate()` owners are exact scan lifecycle/cache invalidations that cannot grow without a manifest update/test review;
- every canonical `OperationKind` has one semantics-registry row and at least one test;
- standard cleaning, Space Trash and uninstall executors/mergers use only the closed `CleaningOperationPurpose` mapping; focused tests assert `.cleaningExecute`, `.spaceTrash` and `.uninstall` report kinds plus merge-kind equality, while a normal-import compile-negative test rejects a raw `OperationKind` execution or merge purpose;
- all 20 baseline destructive button locations are either replaced by a request/confirmation flow or removed, and none calls a destructive service inline;
- every family in the coverage matrix has a focused test class.

This is an exact-owner assertion, not an ignored-path allowlist. Any additional owner fails the test.

- [ ] **Step 3: Add privacy RED/GREEN tests**

`OutcomePrivacyTests` verifies invalidation events, notification requests, logged issues and ordinary persisted metadata contain only stable codes, counts, operation IDs/kinds and safe display metadata. They must not contain:

- absolute local paths or Trash URLs outside the dedicated protected receipt field;
- SSH endpoint/user/command/path, host-key material or Keychain account names;
- component/update URLs or query tokens;
- localized error descriptions;
- license keys/device IDs.

The one deliberate exception is an exact validated Trash receipt (`originalURL` and `trashedURL`) stored only in the dedicated history archive needed for undo. Tests assert its parent directory is `0700`, archive/recovery/staging/lock files are `0600`, schema 1 encodes each URL pair only under its canonical item receipt field (the top-level `restorable` key is schema-0 read-only compatibility), and permanent/non-restorable facts contain no path. `updateRestorable` must reject additions, changed URL pairs and anything other than an exact remove-only subset of the record's existing validated receipts. Receipt paths must never appear in normal record metadata, logs, notifications or invalidation events. Do not add an encryption dependency in this phase; encrypted receipt storage may be recorded as future hardening. UI localizes stable issue codes at presentation time. OSLog for touched workflow files uses `.private` or redacted identifiers for path/error/endpoint data.

- [ ] **Step 4: Prove the architecture detector with a disposable violating fixture**

Run: `swift test --filter OutcomeConsumerArchitectureTests --disable-automatic-resolution --skip-update`

TDD order: first add the exact tests above while the scanner/typecheck helper is absent and capture the intended RED. Then implement the helper and run against a disposable injected source root containing multiline legacy construction, both scalar notifier spellings/declarations, a Decodable extension/typealias evasion, public fact constructors and unbounded gate storage. Once detection is GREEN on the disposable fixture, the production scan must remain RED on the compile-only `TaskCompletionView` shim and any retained scalar notifier/history declarations. Delete those three compatibility declarations from `SharedViews.swift`, `Notifier.swift` and `HistoryStore.swift` only after Tasks 1–13 have removed their callers, then rerun to GREEN. The current production tree is never deliberately regressed or checked out to an older owner merely to manufacture RED evidence.

- [ ] **Step 5: Run final static gates**

```bash
swift test --filter OutcomeConsumerArchitectureTests --disable-automatic-resolution --skip-update
swift test --filter OutcomeConsumerInventoryTests --disable-automatic-resolution --skip-update
swift test --filter OutcomePrivacyTests --disable-automatic-resolution --skip-update
rg -n -U --glob 'Sources/**/*.swift' 'CleaningReport\s*\(\s*removedCount:' Sources
rg -n -U --glob 'Sources/**/*.swift' 'struct\s+TaskCompletionView\b|TaskCompletionView\s*\(' Sources
rg -n -U --glob 'Sources/**/*.swift' 'NotificationCenter\.default\.post\(name:\s*\.xicoDidClean|(?:Notifier\s*\.\s*notifyCleaningDone|\bnotifier\s*\.\s*cleaningDone)\s*\(|func\s+(?:notifyCleaningDone|cleaningDone)\s*\(' Sources
rg -n --glob 'Sources/Features/**/*.swift' 'NSWorkspace\.shared\.recycle' Sources/Features
rg -n --glob 'Sources/Features/*.swift' 'scanIndex\.invalidate\(' Sources/Features
rg -n --glob 'Sources/Features/*.swift' 'XCelebrationBurst\(|XAnnihilationBurst\(|XSound\.play\(\.cleanDone|XHaptic\.perform\(\.levelChange' Sources/Features
rg -n --glob 'Sources/**/*.swift' 'localizedDescription, privacy: \.public|\.path, privacy: \.public' Sources/Infrastructure Sources/Features
rg -n -U --glob 'Sources/Infrastructure/**/*.swift' 'public\s+.*(CleaningRecordDTO|HistoryOperationDTO|HistoryItemFactDTO|ValidatedHistoryRecordCandidate)|record\s*\([^)]*reclaimedBytes:|\btotalCleanups\b' Sources/Infrastructure
rg -n -U 'OutcomeChannel|OutcomeChannelGate|Set\s*<\s*\(\s*UUID\s*,|\[\s*UUID\s*:' Sources/Features/OutcomeSideEffectPolicy.swift
```

Expected:

- first three tests PASS;
- the legacy constructor, compatibility-shim declaration/invocation, every static/instance scalar cleanup notifier call/declaration, raw notification/recycle, legacy-history and noncanonical-gate `rg` commands have no output;
- the real external compile tests in `OutcomeConsumerArchitectureTests` prove the public read/encode contract, reject external Domain fact/`OperationOutcome` construction and `Decodable` conformance, reject public Infrastructure DTO/candidate construction, and accept public typed sink conformance; raw source regex is only supplemental owner/declaration inventory and is not accepted as the type-boundary proof;
- `scanIndex.invalidate()` output is exactly the 8 reviewed scan lifecycle/cache owners, with no operation-terminal owner;
- outcome-feedback output is exactly the reviewed `OutcomePresentationEffects` owners plus the single health-score threshold haptic;
- privacy `rg` has no output in files touched by this plan. Pre-existing matches in unrelated files must be separately triaged, never silently ignored or mechanically deleted.

- [ ] **Step 6: Run every focused consumer suite**

```bash
swift test --filter OperationConsumerFactsTests --disable-automatic-resolution --skip-update
swift test --filter OutcomeSideEffectPolicyTests --disable-automatic-resolution --skip-update
swift test --filter OutcomeSinkBoundaryTests --disable-automatic-resolution --skip-update
swift test --filter TaskOutcomePresentationTests --disable-automatic-resolution --skip-update
swift test --filter TaskOutcomeAccessibilityTests --disable-automatic-resolution --skip-update
swift test --filter CleaningOutcomeConsumerTests --disable-automatic-resolution --skip-update
swift test --filter ThreatRemediationOutcomeTests --disable-automatic-resolution --skip-update
swift test --filter SpaceLensOutcomeTests --disable-automatic-resolution --skip-update
swift test --filter CollectionBasketOutcomeTests --disable-automatic-resolution --skip-update
swift test --filter UninstallerOutcomeTests --disable-automatic-resolution --skip-update
swift test --filter ShredderOutcomeConsumerTests --disable-automatic-resolution --skip-update
swift test --filter MaintenanceOutcomeTests --disable-automatic-resolution --skip-update
swift test --filter OptimizationOutcomeTests --disable-automatic-resolution --skip-update
swift test --filter AppUpdaterOutcomeTests --disable-automatic-resolution --skip-update
swift test --filter RemoteOutcomeConsumerTests --disable-automatic-resolution --skip-update
swift test --filter DownloadOutcomeAdapterTests --disable-automatic-resolution --skip-update
swift test --filter ComponentInstallOutcomeTests --disable-automatic-resolution --skip-update
swift test --filter LocalDataOutcomeTests --disable-automatic-resolution --skip-update
swift test --filter LicenseDeactivationOutcomeTests --disable-automatic-resolution --skip-update
```

Expected: all PASS, 0 skip. Every fake asserts no unexpected live side-effect call.

- [ ] **Step 7: Run the safe real-sandbox fixture gates**

These may mutate only task-created disposable files under the test runner's temporary directory; they may not touch home, Trash, `/Applications`, Keychain, remote services, real processes or iCloud:

```bash
swift test --filter CleaningRoundTripTests --disable-automatic-resolution --skip-update
swift test --filter ShredderServiceTests --disable-automatic-resolution --skip-update
swift test --filter SpaceLensAggregateSafetyTests --disable-automatic-resolution --skip-update
swift test --filter HistoryStoreTests --disable-automatic-resolution --skip-update
swift test --filter RemoteDeletionTransactionTests --disable-automatic-resolution --skip-update
```

Each test records its fixture root and asserts it is inside the test temporary directory before mutation. Remote tests remain fake-only despite the “real-sandbox” stage.

- [ ] **Step 8: Run full build/test/quality gates without app selftest or release actions**

```bash
swift build -c debug --disable-automatic-resolution --skip-update
swift test --disable-automatic-resolution --skip-update
swift build -c release --disable-automatic-resolution --skip-update
bash scripts/quality_gate.sh
git diff --check
```

Before execution, update `scripts/quality_gate.sh` to include deterministic outcome suites only. Every `swift test` or `swift build` invocation inside that script must directly include both `--disable-automatic-resolution` and `--skip-update`; a wrapper, environment variable or earlier resolve step does not satisfy this rule. The script must not call `--selftest`, `make_app.sh`, `release_preflight.sh` as an executable workflow, notarization, deployment, package installation or any network smoke. Shell syntax lint of release scripts is allowed because it has no release side effect.

Expected: 0 failures; test count is greater than the latest `.superpowers/sdd/xico-opfacts-task-2-report.md` baseline (423 tests on HEAD `2dbfe87` at plan revision time, or any higher count recorded later). A lower count is a regression even if it exceeds the old 373-test audit snapshot. Every skip has a written environment reason, none covers an outcome requirement, and the current 15-skip full-suite environment baseline may not silently grow.

- [ ] **Step 9: Manual UI verification with deterministic reducer fixtures**

Render fixture-only success-changed, success-unchanged, partial, failure and cancelled states for ordinary and irreversible semantics in light/dark, Reduce Motion on/off, Increase Contrast and Differentiate Without Color. Verify:

- no partial/failure/cancelled success glyph/sound/haptic/particle;
- irreversible success is static and non-celebratory;
- status, counts and action labels are readable without color;
- keyboard focus reaches retry/details/undo/done in deterministic order;
- accessibility announcement says status + counts + next action exactly once;
- long 11-locale strings do not truncate at supported window widths.

Use fixture rendering only. Do not execute deletion, maintenance, process, network, install or remote actions to capture states.

- [ ] **Step 10: Update trace evidence and request independent review**

Update only the relevant ledger rows with exact test/static evidence. Keep destructive/SSH/network/update production-real rows `partial` or `external` until their owning plans and external evidence pass. Request independent review for:

- reducer/result integrity;
- per-channel idempotency;
- history/notifier/invalidation validation;
- retry subject selection and parent IDs;
- cancellation receipts;
- irreversible feedback suppression;
- privacy/log redaction;
- source-gate completeness, including multiline patterns.

Resolve every Critical/Important finding, then rerun Steps 5–9.

- [ ] **Step 11: Commit the final gate when executing**

```bash
git add Sources/Features/SharedViews.swift Sources/Infrastructure/Notifier.swift Sources/Infrastructure/HistoryStore.swift Tests/FeatureTests/OutcomeConsumerArchitectureTests.swift Tests/FeatureTests/OutcomeConsumerInventoryTests.swift Tests/IntegrationTests/OutcomePrivacyTests.swift scripts/quality_gate.sh docs/20-全量文档任务台账与95分验收矩阵-2026-07-16.md
git commit -m "test: enforce outcome workflow ownership"
```

---

## Requirement-to-evidence trace

| Requirement | Owning tasks | Required evidence |
|---|---|---|
| OUT-01…10 | Tasks 1, 4–13 | reducer + retry + each consumer focused tests |
| UI-OUT-01 partial/failure/cancel suppress success channels | Tasks 1, 3, 14 | policy, presentation, exact-owner static tests |
| UI-OUT-02 one feedback consumption per operation ID; appearance cannot replay | Tasks 1, 3, 14 | concurrent bounded-gate tests + appearance/history replay tests |
| UI-OUT-03 retain failure context, original selection and retryable subjects | Tasks 1, 4–13 | retry selector + per-consumer retained-state/payload tests |
| UI-OUT-04 VoiceOver announces status, truthful counts, irreversibility and recovery | Tasks 3–14, including Task 4 cleaning consumers | accessibility tests + cleaning/irreversible/consumer fixture matrix |
| UI-OUT-05 Reduce Motion uses a static replacement | Tasks 3, 14 | motion-plan tests + fixture render matrix |
| UI-OUT-06 state is never color-only | Tasks 3, 14 | icon/title/text accessibility tests + fixture verification |
| UI-OUT-07 all 11 locales cover terminal, confirmation and migration copy | Tasks 3, 14 | localization coverage + placeholder-parity tests |
| UI-OUT-08 shred/remote non-celebratory | Tasks 3, 7, 11, 14 | irreversible policy/presentation + owner gate |
| History writes actual facts and invalidation remains separate from user notification | Tasks 1, 2, 4–7, 13–14 | history boundary/migration tests + channel independence + sink boundary tests |
| History `legacyUnknown` and truthful success count | Tasks 2, 14 | `HistoryStoreTests` |
| operation-facts former Tasks 5–7 closure | Tasks 1–14 under the handoff mapping | 6 legacy constructors = 0; 7 TaskCompletion calls = 0; raw sinks = 0; API/DTO/gate declarations remain closed |
| Space/maintenance/optimization/update audit findings | Tasks 5, 8–10 | focused outcome suites |
| Shred/uninstall/remote consumer closure | Tasks 6, 7, 11 | focused consumer + owning-plan integration suites |
| Download lifecycle/component outcome | Task 12 | adapter/component tests; trust remains separate |
| Privacy-safe persisted/emitted facts | Tasks 2, 14 | `OutcomePrivacyTests` + log static scan |

## Definition of done

This plan is complete only when all of the following are true on the same HEAD:

1. The raw inventory gates report zero unowned business callsites; multiline legacy constructors are included.
2. All 10 consumer families in the matrix have reducer-backed terminal results and passing focused tests.
3. Every baseline destructive button is classified and routes through confirmation/plan/result where required.
4. History, notification, success visual, sound/haptic and internal invalidation each use an independent one-time channel gate.
5. History/notifier/invalidation boundaries reject ineligible or inconsistent requests.
6. Partial/cancelled changes preserve actual history/protected receipts and internal refresh without user success feedback; receipt URLs exist only in the private `0600` receipt field.
7. Retry uses only payload-backed retryable subjects and creates a new child operation.
8. Shred and remote irreversible success cannot instantiate celebratory effects.
9. Reduce Motion and accessibility tests pass across all five states; 11-locale placeholder parity passes.
10. Focused suites, safe disposable-fixture suites, full `swift test --disable-automatic-resolution --skip-update`, `swift build -c debug --disable-automatic-resolution --skip-update`, `swift build -c release --disable-automatic-resolution --skip-update` and `quality_gate.sh` pass.
11. No verification step performs a live delete, network request, install, publish, remote connection, real App termination or real maintenance command.
12. Cross-plan/external rows remain honestly `partial`/`external` until their own production evidence exists; this plan never claims the full 95+ program complete by itself.
13. The full suite exceeds the latest Task 2 report baseline (423 at HEAD `2dbfe87`, or a higher subsequently recorded baseline) and no public Decodable/fact/DTO/legacy scalar escape hatch remains.
