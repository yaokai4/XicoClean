# Xico Phase 0 Destructive Operations Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use `superpowers:subagent-driven-development` to drive each task's RED→GREEN loop, then use `superpowers:verification-before-completion` before claiming any task or this plan complete.

**Goal:** 让每一个会**永久删除用户文件**（粉碎器）或**移除 App 及其数据**（卸载器），以及 Space Lens 的普通废纸篓 / 本地快照删除通道，都只经过统一的 `prepare → authorize → execute` 危险操作边界：不可变计划、一次性授权、执行前在最靠近副作用处复核本地身份（device/inode/type，粉碎额外 hardLinkCount），并把每一次删除的真实结果以逐项 disposition + mutation 事实如实交代。安全第一，一切 fail-closed：授权重放、身份漂移、短写/EINTR/ENOSPC/EIO/fsync 失败、取消、含受保护或不可识别子项的目录，全部在造成或扩大破坏之前失败关闭，绝不用聚合成功计数或庆祝完成页掩盖部分破坏。

**Architecture:** 新增一个跨 target 的领域能力核心 `DestructiveOperation`：`prepare(_:)` 生成带 `planID / createdAt / expiresAt / 规范化目标 / LocalFileIdentity 快照 / 可恢复性 / 归属证据 / 版本化 canonical digest` 的不可变 `DestructivePlan`；`authorize(_:confirmation:)` 签发绑定 `planID + digest + nonce + expiresAt + kind` 的 `Authorization`（初始化器只对 issuer 可见）；`execute(_:authorization:)` 在**任何副作用之前**原子消费一次性 nonce，并校验 digest / 时效 / kind，任一不符即 fail closed。粉碎器与卸载器都改为该边界的执行器：粉碎的执行阶段引入注入式 POSIX syscall adapter（`FileSyscalls`），复用 `ShredderService` 已经扎实的 fd 锚定 / `openat(O_NOFOLLOW)` / `unlinkat` / 删前 inode 复核基座（SHR-07 不回退），只替换错误处理与取消粒度；卸载器新增 `OwnershipEvidence`/`SelectionPolicy`/`UninstallMode` 与严格 ASCII reverse-DNS bundleID 解析，执行前在 `CleaningEngine` 边界复核归属+身份，并逐项消费 `CleaningReport`。逐项终态一律复用现有 `OperationItemOutcome`（`OperationDisposition` + `OperationMutationFact`）与 `ShredderPayload`/`ShredderItemResult`，规格里的 `cancelledPossiblyModified`/`failedPossiblyModified` 表达为 `disposition=.cancelled/.failed + mutation=.possiblyChanged`。

**Tech Stack:** Swift 6、SwiftPM、SwiftUI、AppKit、Foundation、Darwin、Security、XCTest；现有 `Domain` / `Infrastructure` / `Features` targets。

---

## Authority, dependency and completion rules

- 权威输入：
  - `docs/19-Phase0-可信发布基线-设计规格-2026-07-16.md`（§6.1 危险操作 API、§6.2 本地身份、§7 粉碎器 SHR-01…15、§8 卸载器 UNI-01…15、§14.2 验收）
  - `docs/XICO_COMPREHENSIVE_AUDIT_2026-07-16.md`
  - `docs/superpowers/plans/2026-07-16-xico-phase0-operation-facts.md`（Tasks 1–4：reducer / mutation / base policy / `OperationKind` / durable history 的唯一权威前置）
  - `docs/superpowers/plans/2026-07-16-xico-phase0-outcome-workflows.md`（Task 4 已完成：cleaning consumer、`TaskOutcomeView`、history/notifier/invalidation 边界）
- **跨计划所有权边界（不得越界）：** 本计划**独占**授权能力、目标身份快照、fd-relative 删除、粉碎 I/O 语义、卸载归属证据与选择策略的执行权。`OperationResult<Payload>` / `CleaningReport` 的 **UI 呈现**（`TaskOutcomeView`、Reduce Motion、VoiceOver、庆祝抑制、11 语言文案）与 Space Lens/Shredder/Uninstaller 的 **Feature 层 outcome 消费**由 outcome-workflows Tasks 5/6/7 拥有。凡本计划触及消费/呈现处，仅落地**身份、结果载体正确性与非愉悦强化的服务层不变量**，并把最终 `TaskOutcomeView` 渲染留给 outcome-workflows；若措辞冲突，类型/reducer 以 operation-facts Tasks 1–4 为准，consumer 文件归属以 outcome-workflows 为准，身份/授权/执行语义以本计划为准。
- **串行顺序：** 严格 **Task 1 → (Task 2 → Task 3) → (Task 4 → Task 5) → Task 6**。Task 1 是能力核心，其余全部依赖它。粉碎 Task 3 消费 Task 2 的准备阶段 manifest；卸载 Task 5 消费 Task 4 的归属/选择模型；Task 6 只依赖 Task 1。Tasks 2–6 之间无横向依赖，但粉碎/卸载各自内部严格串行。
- 执行任何 task 前必须重新读取当前 HEAD、`git status --short`，并确认 operation-facts Tasks 1–4 与 outcome-workflows Task 4 的类型仍在（`OperationDisposition`、`OperationMutationFact`、`OperationItemOutcome`、`OperationKind.shred/.uninstall/.spaceTrash/.snapshotDelete`、`ShredderPayload`）。若上游类型缺失，本 task 保持 blocked，禁止在本计划内重定义它们。
- **fail-closed 铁律：** 授权 nonce 只能成功消费一次，必须在真实副作用开始前原子消费；重复、过期、digest 不符、kind 不符全部拒绝。已进入终态的 operation 不接受迟到取消，也不能被取消请求改写历史事实。破坏性依赖已启动但 postcondition 不明时，逐项 mutation 必须是 `.possiblyChanged`，绝不倒推成 `.none`；覆写/卸载失败或取消绝不 unlink 已进行中的目标，并如实标注。
- **测试绝不触碰真实数据：** 本计划所有自动验证只用任务专属可弃置临时目录、in-memory fake `FileSyscalls`、fake process/entitlement reader；禁止删除真实用户文件、移入真实废纸篓、调用真实 `tmutil`、启动真实 App 或联网。禁止运行 `.build/debug/Xico --selftest` 与 `scripts/make_app.sh`（当前 selftest 会在真实用户目录创建并删除 fixture）。
- 所有 `swift build` / `swift test` 命令都直接包含 `--disable-automatic-resolution --skip-update`，只用已锁定缓存的 `Package.resolved`；缺缓存则本 task 明确 blocked，禁止联网解析或改写 lockfile。

## Baseline inventory: what already exists and must be reused

| 现状锚点 | 位置 | Phase 0 处置 |
|---|---|---|
| `ShredderService.shred(_:progress:) -> Result{shredded,failed,freedBytes}`（聚合、无逐项） | `Sources/Infrastructure/ShredderService.swift:26-49` | 保留 fd 锚定/`O_NOFOLLOW`/`unlinkat`/删前 inode 复核（SHR-07），改为 prepare/execute 两阶段并产出 `ShredderPayload` |
| `overwriteFile` 用 `FileHandle.write` + `try?` 吞错、remaining 按意图递减、取消在每 pass 开头 | `ShredderService.swift:172-204,181` | 全部替换为注入式 `FileSyscalls.pwrite` 循环 + per-chunk 取消 + 成功 fsync 校验 |
| `ShredderPayload` / `ShredderItemResult`（requestID/url/disposition/mutation/freedBytes） | `Sources/Infrastructure/ShredderPayload.swift` | 由 `ShredderService` 端到端产出（当前仅 HistoryStore 测试手工构造） |
| `UninstallerService.uninstallTargets(for:)` / `isValidPathToken` / 8 固定 bundleID 路径 / `contains(bundleID)` 子串匹配 | `Sources/Infrastructure/UninstallerService.swift:64-132` | 保留红线闸与 Library 深度≥6 闸；叠加严格 bundleID 解析、`OwnershipEvidence`、`SelectionPolicy` |
| `CleaningEngine.execute(purpose:)/undo/retry`、执行前后 SafetyEngine 复核、`resolvingSymlinksInPath` 双验、`CleaningReport` + `RestorableItem` | `Sources/Domain/CleaningEngine.swift:82,96,674-811,894` | 卸载与 Space Lens 复用为删除执行器与逐项回执源 |
| `SafetyEngine.verify(_:intent:)`、`DeleteIntent.trash/.permanent` | `Sources/Domain/SafetyEngine.swift:51`、`Sources/Domain/Models.swift:407-409` | 身份复核的红线基础判定，逐层复用 |
| `SpaceLensModel.trash` 直接 `NSWorkspace.shared.recycle`（绕过引擎、无身份复核） | `Sources/Features/SpaceLensView.swift:264-286` | 改走 `CleaningEngine` + 身份快照 |
| `SpaceLedger.deleteLocalSnapshot(named:) -> Bool`（date 粒度、裸 Bool） | `Sources/Infrastructure/SpaceLedger.swift:50-72` | 改为 neutral `OperationResult`，date 粒度超删如实交代 |
| `POSIXLaunchctlProcessDriver` 注入范式 | `Sources/Infrastructure/ThreatRemediation.swift:964,1074` | 作为 `FileSyscalls` 注入接缝的参照实现 |

盘点命令：

```bash
rg -n -U 'FileHandle\.write|synchronize\(\)|SecRandomCopyBytes' Sources/Infrastructure/ShredderService.swift
rg -n 'st_nlink|hardLinkCount' Sources
rg -n 'contains\(bid\)|contains\(bundleID\)|isValidPathToken' Sources/Infrastructure/UninstallerService.swift
rg -n 'NSWorkspace\.shared\.recycle|deleteLocalSnapshot' Sources/Features Sources/Infrastructure
```

---

## Safety-review amendments (mandatory RED additions before any GREEN)

An independent destructive-operations safety review of this plan's first draft found three CRITICAL data-loss gaps and several weak spots. These amendments are **binding**: the named RED tests below must exist and pass in their owning task before that task may be marked complete. They override any softer wording later in this document.

- **C1 — Shredder must re-verify identity + `st_nlink == 1` immediately BEFORE the first overwrite pass, not only before `unlink` (Task 3).** The prepare-phase `st_nlink > 1` gate (SHR-04) and the pre-`unlink` inode recheck (SHR-11) leave the destructive overwrite itself unguarded across the ≤5-minute prepare→execute window. If a hard link is created (or the path is swapped to a same-name/different-inode file) in that window, the overwrite clobbers an unselected hard link's content before SHR-11 ever runs. Task 3 MUST, on the O_NOFOLLOW-opened fd, `fstat` and re-check `dev`/`inode`/`S_IFREG` **and `st_nlink == 1`** before writing the first byte; any drift fails closed with `disposition=.skipped`/`mutation=.none` and never writes.
  - Add to Task 3 Step 1: `testHardLinkCreatedBetweenPrepareAndExecuteIsRecheckedBeforeOverwriteAndSkipped`, `testIdentityDriftBeforeFirstOverwritePassFailsClosedWithoutWriting`.
- **C2 — Uninstaller must have negative tests that a mere substring match does NOT attribute a path (Task 4).** Replacing the legacy `contains(bundleID)` matching (UNI-05) is not proven until a container/agent whose name merely *contains* the bundleID substring but does not belong to the app is shown to be excluded. This is historically the #1 cross-app mis-deletion source.
  - Add to Task 4 Step 1: `testGroupContainerMerelyContainingBundleIDSubstringIsNotAttributed`, `testLaunchAgentLabelContainingButNotEqualBundleIDIsNotRecommended`.
- **C3 — Snapshot date-granularity over-deletion must be enumerated as authorized targets at PREPARE time and folded into the digest (Task 6), not merely reported after.** `tmutil deletelocalsnapshots <date>` removes every snapshot for that date. Honestly reporting the over-deletion after the fact still means the consumed nonce/digest never covered the real blast radius, violating "authorization binds the plan's targets."
  - Add to Task 6 Step 1: `testSnapshotPrepareEnumeratesAllSameDateSnapshotsAsAuthorizedTargetsBeforeAuthorize` (the confirmation surface shows the true set; the digest covers all of them).

Minor (also required):
- Task 1: `PlannedTarget` MUST carry an explicit `riskLevel` alongside `recoverability` (doc 19 §6.1 lists both); add `testPlanCarriesRiskLevelAndRecoverability`.
- Task 3: add `testShredTargetsAreNeverMarkedRestorable` (shred is irreversible; no restorable receipt may ever be minted).
- Task 1: assert the concrete local TTL (5 minutes) in `testLocalAuthorizationExpiresAtFiveMinutes`, not only "expired ⇒ rejected".
- Task 5/6 residual (documented, not blocking): uninstall/trash ultimately delete via string-path `FileManager`/`NSWorkspace`, leaving a recheck→call TOCTOU window that fd-relative shred does not. Where feasible, hold a re-verified parent-dir fd and use fd-relative recycle; otherwise record this residual explicitly in the task report.

---

### Task 1: Two-phase destructive capability core (prepare → authorize → execute) + LocalFileIdentity + versioned canonical digest + one-time nonce

**Depends on:** operation-facts Tasks 1–4（`OperationKind`、`OperationDisposition`、`OperationMutationFact`、`OperationItemOutcome`、reducer）。

**Files:**
- Create: `Sources/Domain/DestructiveOperation.swift`（`DestructiveKind`、`LocalFileIdentity`、`PlannedTarget`、`DestructivePlan`、`Authorization`、`PlanDigest` + versioned canonical encoder、`prepare/authorize/execute` 协议）
- Create: `Sources/Domain/AuthorizationLedger.swift`（`actor`，一次性 nonce 原子消费）
- Modify: `Sources/Domain/OperationConsumerFacts.swift`（仅复用现有 `.shred/.uninstall/.spaceTrash/.snapshotDelete` 常量映射到 `DestructiveKind`；不新增 kind）
- Create: `Tests/DomainTests/DestructiveOperationCapabilityTests.swift`

- [x] **Step 1: Write RED tests for the capability core**

仅用 in-memory fixture，绝不触碰文件系统。测试覆盖授权重放、身份、digest 确定性、时效、kind 绑定：

```swift
func testPrepareProducesImmutablePlanWithIdentitySnapshotAndExpiry() throws
func testCanonicalDigestIsDeterministicAcrossDictionaryOrderAndLocale() throws
func testCanonicalDigestIsVersionedAndChangesWhenSchemaVersionChanges() throws
func testDigestChangesWhenAnyTargetIdentityOrPathChanges() throws
func testAuthorizationBindsPlanIDDigestNonceExpiryAndKind() throws
func testNonceIsConsumedExactlyOnceAndReplayFailsClosed() async
func testConcurrentExecuteConsumesNonceExactlyOnceOthersFailClosed() async
func testExpiredAuthorizationFailsClosedBeforeAnySideEffect() throws
func testDigestMismatchFailsClosed() throws
func testKindMismatchBetweenPlanAndAuthorizationFailsClosed() throws
func testLateCancelAfterTerminalDoesNotRewriteOutcome() async
func testAuthorizationInitializerIsNotReachableOutsideIssuer() throws // compile-negative, normal import
func testExecuteInvokesSideEffectClosureOnlyAfterNonceConsumed() async
func testLocalFileIdentityIncludesHardLinkCountForShredKind() throws
```

`prepare/execute` 用一个注入的 `IdentitySampler`（fake，返回构造好的 `LocalFileIdentity`）与一个记录调用顺序的 fake side-effect sink，从而无需真实文件即可断言「nonce 消费在副作用之前」。

- [x] **Step 2: Confirm RED**

```bash
swift test --filter DestructiveOperationCapabilityTests --disable-automatic-resolution --skip-update
```

Expected: FAIL —— 类型与 API 尚不存在。

- [x] **Step 3: Define identity, plan, digest and authorization types**

```swift
public struct LocalFileIdentity: Equatable, Sendable {
    public let device: UInt64
    public let inode: UInt64
    public let mode: UInt32            // st_mode；type 位 load-bearing
    public let size: Int64
    public let mtimeNanoseconds: Int64
    public let hardLinkCount: UInt64   // 粉碎复核用；卸载/Trash 至少复核 device/inode/type
}

public enum DestructiveKind: String, Sendable { case shred, uninstall, spaceTrash, snapshotDelete }

public struct PlannedTarget: Sendable {
    public let canonicalPath: String
    public let identity: LocalFileIdentity?      // 快照删除等无文件身份的目标为 nil，digest 里以显式 sentinel 编码
    public let recoverability: Recoverability     // trashRestorable / irreversible / neutral
    public let attribution: AttributionEvidence   // Task 4 归属证据；粉碎目标为 .userSelected
}

public struct DestructivePlan: Sendable {
    public let planID: UUID
    public let kind: DestructiveKind
    public let createdAt: Date
    public let expiresAt: Date
    public let targets: [PlannedTarget]
    public let digest: PlanDigest
}

public struct Authorization: Sendable {
    public let planID: UUID
    let digest: PlanDigest
    let nonce: UUID
    let expiresAt: Date
    let kind: DestructiveKind
    // init 仅对 DestructiveOperationIssuer 可见（fileprivate/内部工厂）
}
```

`PlanDigest` 用**带 schema 版本的确定性 canonical 编码**：固定字段顺序、按 `canonicalPath` 字节序稳定排序 targets、整数一律 big-endian 定长、路径按「长度前缀 + UTF-8 字节」编码、身份缺失以显式 tag 编码——绝不依赖字典顺序、locale、`String(describing:)` 或 Swift 默认描述。编码器产出 `[UInt8]` 再取 SHA-256（`Security`/`CryptoKit`）。schema 版本作为编码首字节，版本变化即 digest 变化。

- [x] **Step 4: Implement prepare / authorize / execute + one-time nonce ledger**

`prepare(_:)`：对每个规范化目标取一次 `LocalFileIdentity` 快照（经注入 `IdentitySampler`），计算 `expiresAt`（本地粉碎/卸载 = createdAt + 5 分钟；快照删除按 §6.1 归入 neutral，同样 5 分钟），组装 digest，返回不可变 plan。`authorize(_:confirmation:)`：校验 plan 未过期，生成新 `nonce`，签发绑定 `planID+digest+nonce+expiresAt+kind` 的 `Authorization`。`execute(_:authorization:)`：**先**校验 `authorization.kind == plan.kind`、`authorization.digest == plan.digest`、未过期，**再**经 `AuthorizationLedger.consume(nonce:)`（actor 内 `Set<UUID>` 一次性插入，返回是否首次）原子消费，只有返回 true 才调用执行器闭包；任一步失败返回 fail-closed 结果且执行器闭包一次都不调用。终态一旦产生，`execute` 忽略迟到取消。

- [x] **Step 5: Run focused tests + zero-gate**

```bash
swift test --filter DestructiveOperationCapabilityTests --disable-automatic-resolution --skip-update
swift build -c debug --disable-automatic-resolution --skip-update
```

Expected: PASS，含并发 nonce 竞争恰好一次成功、compile-negative 断言 `Authorization` 初始化器在 normal import 下不可达。

- [x] **Step 6: Commit**

```bash
git add Sources/Domain/DestructiveOperation.swift Sources/Domain/AuthorizationLedger.swift Sources/Domain/OperationConsumerFacts.swift Tests/DomainTests/DestructiveOperationCapabilityTests.swift
git commit -m "feat: two-phase destructive capability core with one-time authorization"
```

**Requirement trace (Task 1):**

| 规格条款 | 测试 |
|---|---|
| §6.1 plan 含 planID/createdAt/expiresAt/规范化目标/身份快照/可恢复性/归属/digest | `testPrepareProducesImmutablePlanWithIdentitySnapshotAndExpiry` |
| §6.1 digest 版本化确定性、不依赖字典序/locale | `testCanonicalDigestIsDeterministic…`、`…IsVersioned…`、`…ChangesWhenAnyTargetIdentity…` |
| §6.1 授权绑定 planID+digest+nonce+expiresAt+kind；issuer-only init | `testAuthorizationBinds…`、`testAuthorizationInitializerIsNotReachableOutsideIssuer` |
| §6.1 nonce 一次性、副作用前原子消费、重放/过期/摘要/kind fail closed | `testNonceIsConsumedExactlyOnce…`、`testConcurrentExecute…`、`testExpired…`、`testDigestMismatch…`、`testKindMismatch…`、`testExecuteInvokesSideEffectClosureOnlyAfterNonceConsumed` |
| §6.1 终态不接受迟到取消 | `testLateCancelAfterTerminalDoesNotRewriteOutcome` |
| §6.2 本地身份至少 device/inode/type，粉碎加 hardLinkCount | `testLocalFileIdentityIncludesHardLinkCountForShredKind` |

---

### Task 2: Shredder preparation phase — bounded identity manifest, pre-authorization gate, injectable `FileSyscalls`

**Depends on:** Task 1。

**Files:**
- Create: `Sources/Infrastructure/FileSyscalls.swift`（`protocol FileSyscalls` + `SystemFileSyscalls`（openat/fstatat/fstat/openat-dir/readdir/pwrite/fsync/close/unlinkat/ftruncate）+ 错误注入用的 fake 供测试）
- Modify: `Sources/Infrastructure/ShredderService.swift`（新增 `prepare(_ urls:) -> ShredderPlan` 阶段，注入 `FileSyscalls`，保留 SHR-07 基座）
- Create: `Tests/IntegrationTests/ShredderPreparationTests.swift`

- [ ] **Step 1: Write RED tests for the preparation phase**

用任务专属临时目录构造真实 fixture（安全，可弃置）+ fake `FileSyscalls` 注错：

```swift
func testPrepareBuildsBoundedIdentityManifestForDirectoryTree() throws          // SHR-05
func testPrepareRejectsRootWhoseChildIsRedLinedProtected() throws               // SHR-06
func testPrepareRejectsRootWhoseChildIsUnrecognizedType() throws                // SHR-06/SHR-03
func testPrepareRefusesRegularFileWithMultipleHardLinks() throws                // SHR-04
func testPrepareRefusesFifoSocketAndDeviceEntries() throws                      // SHR-03
func testPrepareDoesNotFollowSymlinksAndManifestsLinkItself() throws            // SHR-02
func testPrepareRunsSafetyEngineOnEveryTopLevelAndChild() throws                // SHR-01
func testPrepareExceedingEntryBudgetRequiresSplitAndDoesNotExecute() throws     // SHR-05
func testPreparePerformsNoWritesOrUnlinks() throws                              // check-then-execute 分离
func testPreparedManifestCarriesPerTargetLocalFileIdentityWithHardLinkCount() throws
```

- [ ] **Step 2: Confirm RED**

```bash
swift test --filter ShredderPreparationTests --disable-automatic-resolution --skip-update
```

Expected: FAIL —— 无 prepare 阶段、无 manifest、无 `FileSyscalls` 接缝。

- [ ] **Step 3: Extract injectable `FileSyscalls`**

按 `POSIXLaunchctlProcessDriver` 范式定义 `protocol FileSyscalls: Sendable`，把 `ShredderService` 现有全局 `openat/fstatat/fstat/fdopendir/readdir/unlinkat` 与新引入的 `pwrite/fsync/ftruncate` 收拢到 `SystemFileSyscalls`。`ShredderService.init` 增加 `syscalls: FileSyscalls = SystemFileSyscalls()`。保留 fd 锚定、`O_NOFOLLOW`、`fcntl(F_DUPFD_CLOEXEC)`、快照式 drain、`maxRecursionDepth=256`（SHR-07 不回退）。

- [ ] **Step 4: Implement the check-then-execute preparation pass**

新增 `prepare(_ urls:)`：从父目录 fd 锚定，只读地深度遍历，产出**有界 identity manifest**（每条含 canonical path + `LocalFileIdentity`）。对每一顶层与每一子项过 `safety.verify(_, intent:.trash)`（SHR-01）；`fstatat(AT_SYMLINK_NOFOLLOW)` 判类型，符号链接只登记链接本身（SHR-02），非常规类型（FIFO/socket/设备）登记为 unrecognized（SHR-03），常规文件 `st_nlink>1` 登记为 hard-linked refusal（SHR-04）。**顶层预授权门（SHR-06）：** 任一根的子树里出现红线拒绝、unrecognized 或 hard-linked，该根整体不进入授权，`prepare` 返回该根为 `rejected`，绝不 best-effort 删兄弟项。设定条目/manifest 预算：超预算的根返回 `requiresSplit`，不带未知覆盖面执行（SHR-05）。prepare 阶段**零写入零 unlink**。manifest 交给 Task 1 `prepare(_:)` 组装成 `DestructivePlan(kind:.shred)`。

- [ ] **Step 5: Run focused tests + zero-gate**

```bash
swift test --filter ShredderPreparationTests --disable-automatic-resolution --skip-update
swift test --filter ShredderServiceTests --disable-automatic-resolution --skip-update   # 既有安全测试不回归
```

Expected: PASS，既有 `testDoesNotFollowSymlinksIntoProtectedTargets` / 红线拒绝仍绿。

- [ ] **Step 6: Commit**

```bash
git add Sources/Infrastructure/FileSyscalls.swift Sources/Infrastructure/ShredderService.swift Tests/IntegrationTests/ShredderPreparationTests.swift
git commit -m "feat(shredder): bounded identity manifest with pre-authorization gate"
```

**Requirement trace (Task 2):**

| SHR | 测试 |
|---|---|
| SHR-01 每顶层+子项过 SafetyEngine | `testPrepareRunsSafetyEngineOnEveryTopLevelAndChild` |
| SHR-02 不跟随符号链接 | `testPrepareDoesNotFollowSymlinksAndManifestsLinkItself` |
| SHR-03 非常规整项拒绝 | `testPrepareRefusesFifoSocketAndDeviceEntries`、`…UnrecognizedType` |
| SHR-04 st_nlink>1 拒绝 | `testPrepareRefusesRegularFileWithMultipleHardLinks` |
| SHR-05 有界身份 manifest + 预算拆分 | `testPrepareBuildsBoundedIdentityManifest…`、`…ExceedingEntryBudgetRequiresSplit…` |
| SHR-06 含受保护/不可识别子项的根不进入授权 | `testPrepareRejectsRootWhoseChildIsRedLined…`、`…IsUnrecognizedType` |
| SHR-07 保留 fd-relative/O_NOFOLLOW/inode 基座 | 既有 `ShredderServiceTests` 不回归 |
| SHR-08 注入式 syscall adapter | 上列全部经 fake `FileSyscalls` 驱动 |
| check-then-execute 分离 | `testPreparePerformsNoWritesOrUnlinks` |

---

### Task 3: Shredder execution phase — pwrite/fsync per-pass verification, unlink gate, per-chunk cancel & failure marking, per-item `ShredderPayload`

**Depends on:** Task 2。

**Files:**
- Modify: `Sources/Infrastructure/ShredderService.swift`（重写 `overwriteFile` 为 pwrite 循环；`shredRegularFile` unlink 门绑定「全 pass 真实成功」；产出逐项结果）
- Modify: `Sources/Infrastructure/ShredderPayload.swift`（若需暴露 `ShredderItemResult` 的 possiblyChanged 构造给服务层，仅放开 Infrastructure-internal 工厂，不放开 Feature 伪造）
- Modify: `Sources/Infrastructure/FileSyscalls.swift`（fake 支持短写 / EINTR / ENOSPC / EIO / fsync 失败 注入）
- Create: `Tests/IntegrationTests/ShredderExecutionIOTests.swift`
- Modify: `Tests/IntegrationTests/ShredderServiceTests.swift`（端到端断言逐项 `ShredderPayload`）

- [ ] **Step 1: Write RED tests for execution I/O, cancel and marking**

```swift
func testPwriteLoopAdvancesOffsetByActualBytesOnShortWrite() throws            // SHR-09
func testPwriteRetriesOnEINTRWithoutDoubleCountingBytes() throws               // SHR-09
func testEachPassMustFullyWriteAndSuccessfullyFsyncBeforeNextPass() throws     // SHR-10
func testENOSPCDuringOverwriteNeverUnlinksAndMarksFailedPossiblyModified() throws  // SHR-13
func testEIODuringOverwriteNeverUnlinksAndMarksFailedPossiblyModified() throws     // SHR-13
func testFsyncFailureBlocksUnlinkAndMarksFailedPossiblyModified() throws       // SHR-10/11/13
func testUnlinkOnlyAfterAllPassesTrulySucceededAndIdentityRecheckPasses() throws   // SHR-11
func testCancellationCheckedBetweenBoundedChunksNotOnlyPerPass() throws        // SHR-12
func testCancelDuringOverwriteStopsImmediatelyAndNeverUnlinks() throws         // SHR-12
func testCancelAfterPartialOverwriteMarksCancelledPossiblyModified() throws    // SHR-12
func testIdentityChangedBeforeUnlinkFailsClosedAndDoesNotDelete() throws       // SHR-11/§6.2
func testDirectoryPartialSuccessProducesPerItemDispositions() throws           // SHR-14
func testShredderProducesShredderPayloadNotAggregateOnlyResult() throws        // SHR-14
func testFullSuccessProducesNonCelebratoryNeutralTerminal() throws             // SHR-15
```

- [ ] **Step 2: Confirm RED**

```bash
swift test --filter ShredderExecutionIOTests --disable-automatic-resolution --skip-update
```

Expected: FAIL —— 当前 `try?` 吞错、remaining 按意图递减、取消在 pass 开头、无逐项结果。

- [ ] **Step 3: Rewrite overwrite as a precise pwrite loop with per-pass verification**

`overwriteFile` 改为：每轮 pass 用 1MB chunk 循环 `syscalls.pwrite(fd, buf, len, offset)`；`SecRandomCopyBytes` 填随机（失败退回 SystemRNG，绝不写全零，保留现状）；返回值为真实写入字节，`remaining` 只按真实字节推进（SHR-09）；`EINTR` 重试不重复计数；短写从新 offset 继续。每 chunk 之间检查 `Task.isCancelled` / 取消 flag（SHR-12），命中即返回 `.cancelled(possiblyModified: true)`，绝不继续。每轮 pass 结束 `syscalls.fsync`，失败即整体失败（SHR-10）。任一 chunk 写失败（ENOSPC/EIO/短写无法完成）→ 返回 `.failed(possiblyModified: true)`。

- [ ] **Step 4: Bind the unlink gate to true全-pass success + final identity recheck**

`shredRegularFile`：只有 `overwriteFile` 返回 `.completed`（全 pass 真实成功 + fsync 成功）才继续；删前仍 `fstatat` 复核 `st_ino/st_dev/S_IFREG` 未变（SHR-11，保留现有 157-162 逻辑），身份漂移即 fail closed 不删（§6.2）。`overwriteFile` 返回 `.cancelled`/`.failed` 时**直接跳过 close→复核→unlink**，登记逐项结果，绝不删除进行中的文件（修复当前最严重 bug）。

- [ ] **Step 5: Emit per-item `ShredderPayload` with disposition + mutation**

`shred`/`execute` 改为对 manifest 每一目标产出 `ShredderItemResult`：成功 = `.succeeded + .changed + freedBytes`；取消未改写 = `.cancelled(nil) + .none`；取消已部分覆写 = `.cancelled(issue) + .possiblyChanged`（cancelledPossiblyModified）；I/O 失败 = `.failed(issue) + .possiblyChanged`（failedPossiblyModified）；身份漂移/红线 = `.skipped/.failed + .none`。聚合仍可保留但不再是唯一载体。目录非事务：先成功后失败/取消形成逐项 partial（SHR-14）。全成功经 Task 1 `execute` 返回 neutral 终态；`.shred` 在 `OutcomeOperationRegistry` 已是 `profile:.neutral`——服务层断言不产生任何庆祝信号（SHR-15，UI 呈现由 outcome-workflows Task 7 落地）。

- [ ] **Step 6: Run focused tests + zero-gate**

```bash
swift test --filter ShredderExecutionIOTests --disable-automatic-resolution --skip-update
swift test --filter ShredderServiceTests --disable-automatic-resolution --skip-update
swift test --filter ShredderPreparationTests --disable-automatic-resolution --skip-update
swift build -c debug --disable-automatic-resolution --skip-update
```

Expected: PASS。取消 P95<500ms 的产品目标由 per-chunk 粒度保障（阻塞 I/O 无法满足时上层显示「正在停止」，属 outcome-workflows UI，不在本 task 断言）。

- [ ] **Step 7: Commit**

```bash
git add Sources/Infrastructure/ShredderService.swift Sources/Infrastructure/ShredderPayload.swift Sources/Infrastructure/FileSyscalls.swift Tests/IntegrationTests/ShredderExecutionIOTests.swift Tests/IntegrationTests/ShredderServiceTests.swift
git commit -m "fix(shredder): pwrite/fsync-verified overwrite, unlink gate, honest cancel/failure facts"
```

**Requirement trace (Task 3):**

| SHR | 测试 |
|---|---|
| SHR-09 精确 pwrite、按真实字节递减、短写/EINTR | `testPwriteLoopAdvancesOffsetByActualBytesOnShortWrite`、`…RetriesOnEINTR…` |
| SHR-10 每 pass 完整写入 + 成功 fsync | `testEachPassMustFullyWriteAndSuccessfullyFsync…`、`…FsyncFailureBlocksUnlink…` |
| SHR-11 全 pass 成功 + 最终身份复核后才 unlink | `testUnlinkOnlyAfterAllPassesTrulySucceeded…`、`testIdentityChangedBeforeUnlinkFailsClosed…` |
| SHR-12 per-chunk 取消 + cancelledPossiblyModified + 绝不删进行中文件 | `testCancellationCheckedBetweenBoundedChunks…`、`…StopsImmediatelyAndNeverUnlinks`、`…MarksCancelledPossiblyModified` |
| SHR-13 I/O 失败绝不 unlink + failedPossiblyModified | `testENOSPC…`、`testEIO…`、`…MarksFailedPossiblyModified` |
| SHR-14 目录非事务逐项结果 | `testDirectoryPartialSuccessProducesPerItemDispositions`、`testShredderProducesShredderPayloadNotAggregateOnly…` |
| SHR-15 完整成功禁止愉悦强化（服务层） | `testFullSuccessProducesNonCelebratoryNeutralTerminal` |

---

### Task 4: Uninstaller attribution model — strict reverse-DNS bundleID parser, `OwnershipEvidence`, `SelectionPolicy`, `UninstallMode`

**Depends on:** Task 1。

**Files:**
- Create: `Sources/Infrastructure/UninstallerAttribution.swift`（`BundleIdentifier`（严格 ASCII reverse-DNS 解析）、`OwnershipEvidence`、`SelectionPolicy`、`UninstallMode`、`EntitlementReader`/`LaunchAgentReader` 协议）
- Modify: `Sources/Infrastructure/UninstallerService.swift`（`uninstallTargets` 产出带 evidence + policy 的候选；保留红线闸与 Library 深度≥6 闸；注入 entitlement/launch-agent reader）
- Create: `Tests/IntegrationTests/UninstallerAttributionTests.swift`

- [ ] **Step 1: Write RED tests**

fixture 用临时 App bundle + fake `EntitlementReader`/`LaunchAgentReader`：

```swift
func testStrictReverseDNSParserRejectsEmptySegments() throws                    // UNI-01
func testStrictReverseDNSParserRejectsPathAndIllegalCharacters() throws         // UNI-01
func testStrictReverseDNSParserRejectsWeakShortTokenAndOverlongComponents() throws  // UNI-01
func testMissingBundleIDDoesNotFallBackToURLPathForAttribution() throws         // UNI-01
func testExactBundleIDPathsGetRecommendedSelectionPolicy() throws               // UNI-04
func testAppGroupsReadFromSignedEntitlementsAreMarkedManualOnly() throws        // UNI-06
func testUnsignedOrMismatchedAppGroupIsNotRecommended() throws                  // UNI-06
func testLaunchAgentRecommendedOnlyWhenLabelExactAndProgramInsideBundle() throws   // UNI-07
func testLaunchAgentWithProgramOutsideBundleIsNotRecommended() throws           // UNI-07
func testDisplayNameDirectoryIsHeuristicDefaultUnselected() throws              // UNI-08
func testSelectAllExcludesManualOnlyAndHeuristicCandidates() throws             // UNI-08
func testUninstallAppModeMarksAppBodyRequiredNonDeselectable() throws           // UNI-02
func testCleanLeftoversModeRequiresAppAbsent() throws                           // UNI-03
func testEveryCandidateCarriesOwnershipEvidenceAndRecoveryHint() throws         // UNI-09
```

- [ ] **Step 2: Confirm RED**

```bash
swift test --filter UninstallerAttributionTests --disable-automatic-resolution --skip-update
```

Expected: FAIL —— 无解析器 / evidence / policy / mode。

- [ ] **Step 3: Implement strict bundleID parser and attribution/selection model**

```swift
public enum OwnershipEvidence: Sendable {
    case exactBundleIDPath        // §8 8 路径精确
    case signedApplicationGroup   // 从签名 entitlements 读取
    case launchAgentProgramInsideBundle
    case displayNameHeuristic
    case unverified
}
public enum SelectionPolicy: Sendable { case required, recommended, manualOnly, blocked }
public enum UninstallMode: Sendable { case uninstallApp, cleanLeftovers }
```

`BundleIdentifier` 按段解析 reverse-DNS：仅 ASCII 字母数字与连字符、拒空段、拒 `/`/`\`/`.`/`..`、拒过短弱 token 与超长分量（UNI-01）；取不到 bundleID 时**不回退 url.path**，归 `.unverified` 且不推荐。8 固定路径 → `exactBundleIDPath` + `recommended`（UNI-04）。Group Containers 改为读签名 entitlements 的 `application-groups`（注入 `EntitlementReader`），命中才 `signedApplicationGroup` 且标 `manualOnly`（UNI-06）。LaunchAgent 解析 plist `Label`/`Program`/`ProgramArguments`（注入 `LaunchAgentReader`），仅当 Label 精确且 Program 指向该 bundle 内才 `launchAgentProgramInsideBundle` + `recommended`（UNI-07）。显示名目录 `displayNameHeuristic` + 默认不选（UNI-08）。保留现有红线闸与 Library `pathComponents.count<6` 闸。

- [ ] **Step 4: Wire mode + policy into `uninstallTargets`**

`uninstallApp` 模式：App 本体 `SelectionPolicy.required`，不可取消选择（UNI-02）。`cleanLeftovers` 模式前置校验 App 不存在（UNI-03）。全选逻辑改为「只选 `required`/`recommended`，排除 `manualOnly`/`heuristic`」（UNI-08）。每候选携带 `OwnershipEvidence` + 恢复方式提示（trash 可恢复）（UNI-09）。候选交 Task 1 `prepare(kind:.uninstall)` 组装 plan。

- [ ] **Step 5: Run focused tests + zero-gate**

```bash
swift test --filter UninstallerAttributionTests --disable-automatic-resolution --skip-update
swift build -c debug --disable-automatic-resolution --skip-update
```

Expected: PASS。

- [ ] **Step 6: Commit**

```bash
git add Sources/Infrastructure/UninstallerAttribution.swift Sources/Infrastructure/UninstallerService.swift Tests/IntegrationTests/UninstallerAttributionTests.swift
git commit -m "feat(uninstaller): ownership evidence, selection policy and strict bundleID parsing"
```

**Requirement trace (Task 4):** UNI-01→parser tests；UNI-02/03→mode tests；UNI-04→exactBundleID recommended；UNI-05/06→app-group signed entitlement tests；UNI-07→launch-agent Program-inside-bundle tests；UNI-08→select-all exclusion + heuristic-unselected；UNI-09→evidence+recovery test。

---

### Task 5: Uninstaller execution consumption — pre-execution attribution+identity recheck, per-item `CleaningReport`, partial retain/retry/undo

**Depends on:** Task 4；outcome-workflows Task 4（`CleaningEngine.execute(purpose:.uninstall)`、`CleaningReport`、`undo`、`retry`、`RestorableItem`）。**边界：** 本 task 落地 `UninstallerModel` 的**结果消费与选择/模式门控逻辑**及执行前归属复核；`TaskOutcomeView` 的最终视觉呈现属 outcome-workflows Task 6，本 task 只断言 model 侧不变量（不再无条件清空/庆祝）。

**Files:**
- Modify: `Sources/Domain/CleaningEngine.swift`（执行前在最靠近副作用处复核归属证据 + `LocalFileIdentity`，与现有 SafetyEngine/inode/symlink 复核并列）
- Modify: `Sources/Features/UninstallerView.swift`（`UninstallerModel.uninstall()` 消费逐项 `CleaningReport`：保留失败、区分本体/数据、partial undo；不再无条件 `selected=nil;targets=[]`）
- Create: `Tests/IntegrationTests/UninstallerServiceTests.swift`

- [ ] **Step 1: Write RED tests**

```swift
func testExecutionRechecksOwnershipEvidenceAndIdentityBeforeDelete() throws     // UNI-10
func testIdentityChangedSinceScanSkipsCandidateAndDoesNotDelete() throws        // UNI-10/§6.2
func testConsumesPerItemCleaningReportAndRetainsFailuresAndRestorable() throws  // UNI-11
func testOnlySuccessfulCandidatesRemovedFailedRetainedForRetry() throws         // UNI-12
func testAppBodyFailureWithPartialDataSuccessIsExplicitlyExplained() throws     // UNI-13
func testPartialUninstallCanUndoAlreadyTrashedItems() throws                    // UNI-14
func testOnlyFullSuccessClearsContextAndEntersSuccessPresentation() throws      // UNI-15
func testRequiredAppBodyCannotBeExecutedAsDeselected() throws                   // UNI-02 执行侧
```

- [ ] **Step 2: Confirm RED**

```bash
swift test --filter UninstallerServiceTests --disable-automatic-resolution --skip-update
```

Expected: FAIL —— 当前 `uninstall()` 丢弃 failures/restorable、无条件清空并庆祝。

- [ ] **Step 3: Add execution-boundary attribution + identity recheck in `CleaningEngine`**

在 `executeItem` 现有 post-admission SafetyEngine recheck / `resolvingSymlinksInPath` 双验 / permanent-symlink 守卫旁，增加对卸载候选的**归属证据 + `LocalFileIdentity`（device/inode/type）复核**：plan 快照身份与执行时不一致即跳过该候选归 `identityChanged`（可重试），绝不按相同路径删除（§6.2 UNI-10）。`unverified`/`blocked` 证据的候选在执行边界 fail closed。

- [ ] **Step 4: Rewrite `UninstallerModel.uninstall()` to consume per-item facts**

改为逐项消费 `CleaningReport`：只 prune 成功候选，失败候选保留并暴露重试入口（复用 `CleaningEngine.retry`）（UNI-11/12）；App 本体失败而部分数据成功时显式呈现「数据部分移入废纸篓，但 App 未卸载」（UNI-13）；partial 提供撤销已成功 trash 项（复用 `CleaningEngine.undo` + 保留 `RestorableItem`，不再丢弃回执）（UNI-14）；只有完整成功才 `selected=nil;targets=[]` 并进入成功呈现（UNI-15）；`required` App 本体不可作为未勾选执行（UNI-02 执行侧）。

- [ ] **Step 5: Run focused tests + zero-gate**

```bash
swift test --filter UninstallerServiceTests --disable-automatic-resolution --skip-update
swift test --filter CleaningEngineTests --disable-automatic-resolution --skip-update   # 引擎不回归
swift build -c debug --disable-automatic-resolution --skip-update
```

Expected: PASS。

- [ ] **Step 6: Commit**

```bash
git add Sources/Domain/CleaningEngine.swift Sources/Features/UninstallerView.swift Tests/IntegrationTests/UninstallerServiceTests.swift
git commit -m "fix(uninstaller): execution-boundary attribution recheck and honest per-item consumption"
```

**Requirement trace (Task 5):** UNI-10→recheck/identity tests；UNI-11→per-item retain test；UNI-12→failed-retained-retry；UNI-13→app-body-failure-explained；UNI-14→partial-undo；UNI-15→full-success-only-clears；UNI-02(exec)→`testRequiredAppBodyCannotBeExecutedAsDeselected`。

---

### Task 6: Space Lens Trash & snapshot — identity recheck, engine routing, partial-undo retention, neutral snapshot result

**Depends on:** Task 1。**边界：** 本 task 落地 Space Lens 删除通道的**身份复核与结果载体正确性**（服务/引擎/账本层）；`TaskOutcomeView` 呈现与 `OperationResult` 消费的 UI 归 outcome-workflows Task 5，本 task 只断言删除不再绕过引擎、快照结果不再吞成裸 Bool、partial undo 保留回执。

**Files:**
- Modify: `Sources/Features/SpaceLensView.swift`（`SpaceLensModel.trash` 改走 `CleaningEngine.execute(purpose:.spaceTrash)`，移除直接 `NSWorkspace.shared.recycle`；freed 用 report bytes）
- Modify: `Sources/Features/CollectionBasket.swift` / `Sources/Features/SunburstView.swift` / `Sources/Features/TreemapView.swift`（单项/批量统一经引擎；partial undo 不清空 report）
- Modify: `Sources/Infrastructure/SpaceLedger.swift`（`deleteLocalSnapshot` 改返回 neutral `OperationResult`，date 粒度超删如实交代）
- Create: `Tests/IntegrationTests/SpaceLensDeletionOutcomeTests.swift`

- [ ] **Step 1: Write RED tests**

```swift
func testSingleTrashRoutesThroughCleaningEngineNotDirectRecycle() throws        // Task5/no-direct-recycle
func testSingleTrashRechecksDeviceInodeTypeBeforeMove() throws                  // §6.2
func testIdentityChangedSingleTargetIsSkippedNotRecycledByPath() throws         // §6.2 TOCTOU
func testAggregateBucketRemainsUndeletableInSingleAndBatch() throws             // 审计 P0（保持）
func testBasketFreedBytesComeFromReportNotNodeSizeSum() throws                  // report bytes only
func testPartialBasketUndoKeepsUnrestoredReceiptsRetryable() throws             // partial-undo retryable
func testSnapshotDeletionReturnsNeutralOperationResultNotBareBool() throws      // snapshot neutral
func testSnapshotDeletionByDateHonestlyReportsAllRemovedWhenMultipleSameDay() throws  // date 粒度超删诚实
```

- [ ] **Step 2: Confirm RED**

```bash
swift test --filter SpaceLensDeletionOutcomeTests --disable-automatic-resolution --skip-update
```

Expected: FAIL —— 当前单项直接 recycle、freed 用 node.size、快照裸 Bool、partial undo 清空 report。

- [ ] **Step 3: Route single Trash through the engine with identity recheck**

`SpaceLensModel.trash` 改为构造 `CleaningPlan(intent:.trash)` 经 `CleaningEngine.execute(purpose:.spaceTrash)`，获得执行期二次 SafetyEngine 复核 + `LocalFileIdentity`（device/inode/type）复核 + permanent-symlink 守卫，彻底移除 `NSWorkspace.shared.recycle` 裸路径；扫描到执行期间身份变化的目标跳过，不按相同路径回收（§6.2）。保留聚合桶双闸 guard（`!node.isAggregate`）与 `SpaceLensAggregateSafetyTests` 不变量。

- [ ] **Step 4: Report bytes + retryable partial undo**

收集篮 freed 改用 `report.reclaimedBytes`（不再 `node.size` 求和，去除硬链接高估）；`undoLastBasket` partial 失败后**不置 `lastReport=nil`**，保留未恢复项回执以可重试。

- [ ] **Step 5: Neutral snapshot result with honest granularity**

`SpaceLedger.deleteLocalSnapshot` 改返回 neutral（irreversible）`OperationResult`（kind `.snapshotDelete`，已在 registry 为 `profile:.neutral`）。若 `tmutil deletelocalsnapshots <date>` 因同日多快照而删除超出用户所选，结果如实枚举实际被删集合并令 UI 与磁盘一致（不再只移除单个 name 造成失真）。

- [ ] **Step 6: Run focused tests + zero-gate**

```bash
swift test --filter SpaceLensDeletionOutcomeTests --disable-automatic-resolution --skip-update
swift test --filter SpaceLensAggregateSafetyTests --disable-automatic-resolution --skip-update
swift build -c debug --disable-automatic-resolution --skip-update
```

Expected: PASS，聚合桶不可删不变量保持绿。快照删除测试用 fake `tmutil` runner，绝不调用真实 `tmutil`。

- [ ] **Step 7: Commit**

```bash
git add Sources/Features/SpaceLensView.swift Sources/Features/CollectionBasket.swift Sources/Features/SunburstView.swift Sources/Features/TreemapView.swift Sources/Infrastructure/SpaceLedger.swift Tests/IntegrationTests/SpaceLensDeletionOutcomeTests.swift
git commit -m "fix(spacelens): engine-routed trash with identity recheck and neutral snapshot result"
```

**Requirement trace (Task 6):** no-direct-recycle→`testSingleTrashRoutesThroughCleaningEngine…`；§6.2 身份→`…RechecksDeviceInodeType…`、`…IdentityChangedSingleTargetIsSkipped…`；聚合桶 P0→`…AggregateBucketRemainsUndeletable…`；report bytes→`…FreedBytesComeFromReport…`；partial-undo→`…KeepsUnrestoredReceiptsRetryable`；snapshot neutral/granularity→`…ReturnsNeutralOperationResult…`、`…HonestlyReportsAllRemovedWhenMultipleSameDay`。

---

## Definition of done

同一 HEAD 上全部成立：

1. Task 1 能力核心通过：一次性 nonce 在副作用前原子消费、并发恰好一次、digest 版本化确定性、过期/摘要/kind 全 fail closed、`Authorization` init issuer-only。
2. 粉碎器：prepare 产出有界身份 manifest 且含受保护/不可识别/硬链接子项的根不进入授权（SHR-04/05/06）；执行用 pwrite/fsync 逐 pass 验证、unlink 门绑定全 pass 成功 + 最终身份复核、per-chunk 取消绝不删进行中文件、I/O 失败绝不 unlink，全部以逐项 `ShredderPayload` disposition+mutation 如实交代（SHR-07…15），SHR-07 基座不回退。
3. 卸载器：严格 reverse-DNS 解析 + `OwnershipEvidence` + `SelectionPolicy` + `UninstallMode`（UNI-01…09）；执行前复核归属+身份、逐项消费 `CleaningReport`、保留失败可重试、区分本体/数据、partial 可撤销、仅完整成功清空（UNI-10…15，UNI-02 双侧）。
4. Space Lens 三通道统一经引擎并复核 device/inode/type、freed 用 report bytes、partial undo 保留回执、快照返回 neutral 结果且 date 粒度超删诚实，聚合桶不可删不变量保持。
5. 所有新逻辑禁止对破坏性操作产出愉悦型声/触/庆祝；neutral kind 在服务层零庆祝信号（视觉呈现留 outcome-workflows）。
6. 所有验证零真实删除/零真实废纸篓/零真实 `tmutil`/零真实 App 退出/零联网，仅用可弃置临时目录与 in-memory fake。
7. 聚焦套件 + `swift test --disable-automatic-resolution --skip-update` 全量 + `swift build -c debug/-c release --disable-automatic-resolution --skip-update` 全绿；不新增 public 逃逸口令（`Authorization` init、`ShredderItemResult`/`ShredderPayload` 工厂对 Feature 保持不可伪造）。
8. 跨计划边界诚实：`OperationResult`/`CleaningReport` 的 UI 呈现与 Feature outcome 消费明确归 outcome-workflows Tasks 5/6/7，本计划不越界声称其完成。

---

计划正文完。关键复用锚点（绝对路径）：`/Users/yaokai/Code/IT/MacApp/XicoApp/Sources/Infrastructure/ShredderService.swift`、`/Users/yaokai/Code/IT/MacApp/XicoApp/Sources/Infrastructure/ShredderPayload.swift`、`/Users/yaokai/Code/IT/MacApp/XicoApp/Sources/Infrastructure/UninstallerService.swift`、`/Users/yaokai/Code/IT/MacApp/XicoApp/Sources/Domain/CleaningEngine.swift`、`/Users/yaokai/Code/IT/MacApp/XicoApp/Sources/Domain/SafetyEngine.swift`、`/Users/yaokai/Code/IT/MacApp/XicoApp/Sources/Domain/OperationOutcome.swift`、`/Users/yaokai/Code/IT/MacApp/XicoApp/Sources/Domain/OperationConsumerFacts.swift`、`/Users/yaokai/Code/IT/MacApp/XicoApp/Sources/Infrastructure/ThreatRemediation.swift`（`POSIXLaunchctlProcessDriver` 注入范式）、`/Users/yaokai/Code/IT/MacApp/XicoApp/Sources/Features/SpaceLensView.swift`、`/Users/yaokai/Code/IT/MacApp/XicoApp/Sources/Infrastructure/SpaceLedger.swift`；规格权威 `/Users/yaokai/Code/IT/MacApp/XicoApp/docs/19-Phase0-可信发布基线-设计规格-2026-07-16.md` §6.1/§6.2/§7/§8。格式模板取自 `/Users/yaokai/Code/IT/MacApp/XicoApp/docs/superpowers/plans/2026-07-16-xico-phase0-outcome-workflows.md`。

按仓库惯例，此计划应落盘为 `/Users/yaokai/Code/IT/MacApp/XicoApp/docs/superpowers/plans/2026-07-16-xico-phase0-destructive-operations.md`（outcome-workflows 计划已以该文件名交叉引用本计划）。