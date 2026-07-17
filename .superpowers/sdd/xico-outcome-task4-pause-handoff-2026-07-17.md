# Xico 95+ Program — Outcome Workflows Task 4 暂停交接

暂停时间：2026-07-17 10:11 JST
工作分支：`codex/precision-monitoring`
当前 HEAD：`913bc7516d7df8ece251a27b02aa88fc8791b6b1`
当前目标：完成全部有效文档任务，并让安全、可靠性、架构、性能、功能、UX、视觉、无障碍八个维度分别达到 95 分以上。
当前阶段：`docs/superpowers/plans/2026-07-16-xico-phase0-outcome-workflows.md` Task 4。
暂停结论：**Task 4 尚未完成、尚未提交、当前有一个刻意保留的 RED 测试。不要把此检查点描述为可发布或总目标完成。**

## 1. 暂停时的运行状态

- 用户要求今天停止，之后会明确要求恢复。
- 所有仍在运行的审查子任务已中止；ThreatRemediation 子任务已正常结束。
- 没有继续运行的 SwiftPM 测试、构建、打包、安装、公证或发布任务。
- 没有执行真实用户 Trash、真实 `~/Library/Application Support`、真实 `~/Library/LaunchAgents`、真实 App 终止、真实 helper 安装、真实网络或 SSH/SFTP 破坏性操作。
- 当前工作树包含 Task 4 的大批未提交实现。不要 `git reset --hard`、不要 `git checkout --`、不要清理或覆盖这些改动。
- 暂停前最后一步是为一个独立审查发现新增 RED 测试；生产修复尚未写入。这是有意留下的精确恢复点。

## 2. 已经提交并完成的工作

### 2.1 Operation Facts 基座

以下均已完成、提交、全量回归并独立审查：

1. Operation Facts Task 1：基础 reducer、事实模型与边界。
2. Operation Facts Task 2：逐项 disposition、CleaningEngine 事实与外部构造限制。
3. Operation Facts Task 3：显式 mutation、receipt 验证、成功反馈门。
4. Operation Facts Task 4：持久化历史、schema/load fail-closed、CAS/flock、隐私和 receipt 身份。

关键已提交生产提交：

- `d7339c7 fix: persist honest operation history`
- `ef4902d test: stabilize helper sampling synchronization`
- 文档关闭提交：`8552983`

### 2.2 Outcome Workflows Tasks 1–3

以下均已完成、提交、全量回归并独立审查：

1. Task 1：27 个 canonical operation kinds、不可伪造的 semantics registry、精确 retry selection、closed cleaning purpose、有限通道 gate。
   - 生产：`480b22b feat: define outcome consumer contracts`
   - 文档：`aff1406 docs: close outcome workflows task 1`
2. Task 2：强类型 history / notification / invalidation sinks、operation-ID 幂等与 bounded storage。
   - 生产：`327b1b8 feat: validate outcome side effect sinks`
   - 文档：`7e28d4b docs: close outcome workflows task 2`
3. Task 3：诚实的 success / partial / failure / cancelled 结果呈现、动作排序、无障碍、Reduce Motion、原子 presentation authorization。
   - 生产：`46e7ac9 feat: present honest operation outcomes`
   - 文档：`1c670eb docs: close outcome workflows task 3`

Task 3 最后一个已提交的全量基线：599 tests executed、15 个显式环境 skip、0 failures；Release build、Swift parse、11 语言 plist、diff gates 通过；两次独立审查均无 Critical/Important。

### 2.3 Task 4 权威合同文档

- `913bc75 docs: harden outcome workflows task 4 contract` 已提交。
- 当前计划中另有 1 行未提交的签名/顺序澄清：`CleaningReport.merging(...occurrenceOrder:)` 和显式 parent inventory 定义稳定 `D → R` 顺序。

## 3. Task 4 已实现但尚未最终验收/提交的内容

这些实现已存在于当前工作树，但只有在恢复后完成剩余 RED→GREEN、focused/full regression、Release build 和双重审查后，才能标记 Task 4 complete。

### 3.1 Domain：清理事实、合并、重试、撤销

- 一次建立 parent-wide、有序 request inventory；caller `itemID` 重复仍是独立 occurrence。
- 按 standardized path 在任何依赖调用前发现重复目标，重复 occurrence 全部产生不可重试的 `cleaning.request.duplicateTarget`。
- compound report 使用 canonical `D → R`：deletion fact 后紧跟其可选 threat-remediation auxiliary fact。
- merge 验证 purpose、child kind、parent correlation、request ID 唯一性、auxiliary link、payload/outcome 一致性；拒绝时返回 reducer-backed、未注册 kind 的 fail-closed report。
- `CleaningReport` 的 removed count、bytes、receipt 只来自成功 deletion fact；辅助成功不膨胀清理指标。
- `CleaningEngine.retry` 只执行 Domain 授权且 payload-backed 的 retryable facts；生成新 operation ID，并把 `parentID` 绑定到前代 terminal。
- D+R 重试不会复用旧 plist token；会安全重新读取当前源 plist。auxiliary-only retry 才可使用仍有效的 token。
- receipt ledger 跨 retry generation 保留 owner operation ID 和 deletion request ID；admission rejection 也不会丢失之前的可撤销 receipt。
- `.possiblyChanged` deletion 不可重试；只有 `mutation == .none` 且带 Domain authority 才可重复删除。
- undo 直接接收 `[RestorableItem]`；原 report overload 仅委托。original/trash 两端都加入并发 reservation，避免 undo 与新清理竞态。
- initial 与 retry 的取消不会覆盖已经确定的 duplicate、inFlight、informational、safety-preflight 或 context-unchanged 事实。
- `.plist` / `.PLIST` eligibility 统一为 case-insensitive。
- 最大 terminal fact 数统一为 256。初次执行在生成 request ID 前计算 projected count；超限返回 0 facts、真实 requested/failed count、1 个全局非重试 issue。
- prior facts >256 的 retry 直接走有界 aggregate，不遍历或分配 receipt ledger；由 <=256 prior 推导出的 projected retry overlimit 可保留有界 receipt。

### 3.2 Infrastructure：ThreatRemediation

- 从静态 best-effort bridge 迁移为注入式 `ThreatRemediationExecuting` child operation。
- eligibility 仅允许注入 root 下的直接、普通、非 symlink `.plist` 子项；缺失 Label 不再用文件名猜测。
- root 使用 `O_DIRECTORY | O_NOFOLLOW` 打开；目标用 `openat(...O_NOFOLLOW)`、`fstat`，读取限制 1 MiB。
- root identity 与 target identity 在最接近副作用的位置复核；重建 regular file、symlink、root replacement 都 fail closed。
- retry authorization store 是 bounded actor：默认容量 1024，不驱逐仍有效 token。
- token 状态为 available / inUse / pendingBatch；claim 原子化，双重 claim 返回 in-use/collision。
- user-action TTL 默认 5 分钟，起点锚定整批 operation 即将返回的时刻，避免顺序批次中早期 token 在用户看到结果前过期。
- 只发布当前 batch、当前 root identity、仍 retryable 的 token；过期、错误 root、错误 target 或 stale target 均不可用。
- request 数 >256 使用 bounded aggregate admission failure；50,000 项测试不创建 per-item payload、issue 或依赖调用。
- `/bin/launchctl` 驱动改为 POSIX `posix_spawn` / `waitpid`；无共享 Foundation `Process` 状态。
- timeout/cancel 执行有界 TERM → grace → KILL → hard deadline → detached best-effort reaper，调用方按硬截止返回。
- 极端残余风险：SIGKILL 后若子进程卡在内核不可中断状态，PID 交给 detached best-effort reaper；这不阻塞调用方终态。

### 3.3 Infrastructure：History / sinks

- 清理历史 schema 2 保存 deletion/auxiliary role 和 reducer 事实，不保存原路径、显示名或 launch-agent label。
- schema 0/1 继续可读；不合格 operation kind、破损 compound relation、超限 issues/facts 均 fail closed。
- history record 与 issue 上限都与 `CleaningOperationLimits.maximumFactCount == 256` 对齐。
- archive 同时受 500 records 和 1 MiB encoded bytes 约束；插入时从最旧记录开始逐条淘汰，最新 receipt 记录保留。
- CAS conflict 后重新评估大小保留策略；equal-date tie 行为有测试。
- mixed/possiblyChanged historical undo 在成功 receipt 被移除后仍保留诚实的 operation 记录。
- notifier 的 changed count 来自 deletion removedCount，不使用 parent succeeded count。
- history、notification、invalidation 都走 typed validated sink，不允许 Feature 直接调用 raw sink。

### 3.4 Features：清理消费者和结果页

- 新增 `CleaningOutcomeConsumer`，统一完成：trusted report 检查、selection mutation、retry facts、receipt、history、notification、invalidation、presentation authorization。
- Module 与 Smart Scan 仅按原 occurrence position 移除 succeeded/unchanged 选择，不按 path 或 caller itemID 猜测。
- retry selection 使用 Domain 返回的 prior occurrence index 与新 deletion request ID；重复 caller ID 安全。
- Module/Smart 保留 receipt ledger、history ownership 和 exact retry inventory。
- Smart Scan 保存 cleaning task，支持 cancelling 状态并等待 reducer-backed cancelled terminal；不丢弃部分成功事实。
- clean / retry / undo 互斥，reset/cancel 不会覆盖正在进行的 undo。
- 两个 `CompletionView` 已改为通用 `TaskOutcomeView`，并提供详情 sheet；failure/skipped/cancelled/issue 都能进入详情。
- historical undo 直接传递 record.restorable，不再伪造 legacy `CleaningReport`。
- legacy `CleaningReport(removedCount:reclaimedBytes:failures:restorable:)` 已移除。
- retained receipt 已能在“当前 retry unchanged”时显示 undo；但 admission-rejected failure 的 actionOrder 仍有一个已知缺口，详见第 5 节。

## 4. 暂停前验证证据

### 已通过

- ThreatRemediation focused：37 tests、0 failures，13.29 秒。
- Threat focused 覆盖：50k bounded admission、`.PLIST`、nil-token D+R reread、capacity/no-eviction、concurrent claim/collision、batch-end TTL、stale regular/symlink、真实 sleep timeout/cancel、TERM/KILL hard deadline。
- Threat final static parse、`git diff --check`、旧 Process bridge 禁止门通过；独立逐行审查为 CLEAN、0 Critical/Important。
- Domain：Swift parse、raw Domain module emit、raw DomainTests typecheck、`git diff --check` 通过。
- Feature/History 相关文件此前已通过 Swift parse；TaskOutcomePresentation retained-unchanged receipt 测试已编码。
- 当前暂停采集时 `git diff --check` 通过。

### 刻意保留的 RED

测试：

```text
TaskOutcomePresentationTests.testAdmissionRejectedRetryStillOffersUndoForRetainedPriorReceipt
```

命令：

```bash
CLANG_MODULE_CACHE_PATH=/private/tmp/xico-clang-module-cache \
SWIFTPM_MODULECACHE_OVERRIDE=/private/tmp/xico-swiftpm-module-cache \
swift test \
  --filter TaskOutcomePresentationTests.testAdmissionRejectedRetryStillOffersUndoForRetainedPriorReceipt \
  --disable-automatic-resolution --skip-update
```

结果：1 test、1 expected failure、0 unexpected；实际 action order 为：

```text
[recovery, details, done]
```

预期为：

```text
[recovery, details, undoChanged, done]
```

这证明 receipt 已传到 context，但 `.failure` 分支没有消费 `canUndo`。

### 尚未运行/尚不能宣称通过

- 新 RED 对应的生产修复尚未写。
- TaskOutcomePresentationTests 整套尚未在最新工作树重跑。
- Task 4 计划列出的 7 个 focused suite 尚未在最新最终组合上串行全跑。
- 最新工作树的全量 `swift test` 尚未运行。
- 最新工作树的 Debug / Release build 尚未运行。
- Task 4 第二次全量独立 final review 在用户要求暂停时被中止，尚无最终结论。
- Task 4 文档 checkbox、progress closure、requirement trace、production/docs commit 尚未完成。

## 5. 当前唯一已知 Important，以及恢复后的第一处代码修改

独立 reviewer 发现：`Sources/Features/TaskOutcomePresentation.swift` 的 `.failure` action-order 分支完全忽略 `canUndo`。因此，retry 因 256-fact admission limit 被拒绝时，Domain 已验证并保留的旧 receipt 无法从结果页撤销。

恢复后第一步应只做以下最小生产修改：

```swift
case .failure:
    var actions: [TaskOutcomeActionKind] = []
    if hasRetry { actions.append(.retryFailed) }
    if hasRecovery { actions.append(.recovery) }
    actions.append(.details)
    if canUndo { actions.append(.undoChanged) }
    actions.append(.done)
    return actions
```

然后原样重跑第 4 节中的单测，必须从 RED 变 GREEN。不要删除、放宽或改写该测试来获得绿灯。

## 6. 当前工作树清单

当前共有 26 个 porcelain entries：23 个 tracked modified + 3 个 untracked new files。

### Domain

- `Sources/Domain/CleaningEngine.swift`
- `Sources/Domain/Models.swift`
- `Sources/Domain/OperationConsumerFacts.swift`
- `Sources/Domain/OperationOutcome.swift`
- `Tests/DomainTests/CleaningEngineTests.swift`
- `Tests/DomainTests/OperationConsumerFactsTests.swift`
- `Tests/DomainTests/OperationOutcomeReducerTests.swift`

### Features

- `Sources/Features/AppModel.swift`
- `Sources/Features/ModuleSessionViewModel.swift`
- `Sources/Features/ScanViews.swift`
- `Sources/Features/SettingsView.swift`
- `Sources/Features/SharedViews.swift`
- `Sources/Features/SmartScanHub.swift`
- `Sources/Features/TaskOutcomePresentation.swift`
- `Tests/FeatureTests/TaskOutcomePresentationTests.swift`
- 新文件：`Sources/Features/CleaningOutcomeConsumer.swift`（433 行）
- 新文件：`Tests/FeatureTests/CleaningOutcomeConsumerTests.swift`（853 行）

### Infrastructure / integration

- `Sources/Infrastructure/HistoryStore.swift`
- `Sources/Infrastructure/Notifier.swift`
- `Sources/Infrastructure/ThreatRemediation.swift`
- `Sources/Infrastructure/XicoEnvironment.swift`
- `Tests/IntegrationTests/CleaningRoundTripTests.swift`
- `Tests/IntegrationTests/HistoryStoreTests.swift`
- `Tests/IntegrationTests/OutcomeSinkBoundaryTests.swift`
- 新文件：`Tests/IntegrationTests/ThreatRemediationOutcomeTests.swift`（1755 行）

### Plan

- `docs/superpowers/plans/2026-07-16-xico-phase0-outcome-workflows.md`

Tracked diff：8746 insertions / 675 deletions；untracked new files 共 3041 行。不要用统计规模代替验证结论。

## 7. 精确恢复顺序

### 7.1 恢复前只读核对

```bash
cd /Users/yaokai/Code/IT/MacApp/XicoApp
git branch --show-current
git rev-parse HEAD
git status --short
git diff --check
git log --oneline -12
```

预期 branch 为 `codex/precision-monitoring`，HEAD 为 `913bc75...`，除非用户或另一工具明确改变了仓库。若状态不同，先审计差异，不要覆盖。

### 7.2 先关闭当前 RED

1. 在 failure action order 中把 `.undoChanged` 放在 `.details` 后、`.done` 前，条件为 `canUndo`。
2. 重跑精确单测，确认 1/1 green。
3. 跑 `TaskOutcomePresentationTests` 全套。

### 7.3 串行跑 Task 4 focused suites

所有 SwiftPM 命令都必须直接带离线参数；一次只跑一个：

```bash
CLANG_MODULE_CACHE_PATH=/private/tmp/xico-clang-module-cache SWIFTPM_MODULECACHE_OVERRIDE=/private/tmp/xico-swiftpm-module-cache swift test --filter CleaningOutcomeConsumerTests --disable-automatic-resolution --skip-update
CLANG_MODULE_CACHE_PATH=/private/tmp/xico-clang-module-cache SWIFTPM_MODULECACHE_OVERRIDE=/private/tmp/xico-swiftpm-module-cache swift test --filter ThreatRemediationOutcomeTests --disable-automatic-resolution --skip-update
CLANG_MODULE_CACHE_PATH=/private/tmp/xico-clang-module-cache SWIFTPM_MODULECACHE_OVERRIDE=/private/tmp/xico-swiftpm-module-cache swift test --filter CleaningRoundTripTests --disable-automatic-resolution --skip-update
CLANG_MODULE_CACHE_PATH=/private/tmp/xico-clang-module-cache SWIFTPM_MODULECACHE_OVERRIDE=/private/tmp/xico-swiftpm-module-cache swift test --filter HistoryStoreTests --disable-automatic-resolution --skip-update
CLANG_MODULE_CACHE_PATH=/private/tmp/xico-clang-module-cache SWIFTPM_MODULECACHE_OVERRIDE=/private/tmp/xico-swiftpm-module-cache swift test --filter OutcomeSinkBoundaryTests --disable-automatic-resolution --skip-update
CLANG_MODULE_CACHE_PATH=/private/tmp/xico-clang-module-cache SWIFTPM_MODULECACHE_OVERRIDE=/private/tmp/xico-swiftpm-module-cache swift test --filter CleaningEngineTests --disable-automatic-resolution --skip-update
CLANG_MODULE_CACHE_PATH=/private/tmp/xico-clang-module-cache SWIFTPM_MODULECACHE_OVERRIDE=/private/tmp/xico-swiftpm-module-cache swift test --filter OperationConsumerFactsTests --disable-automatic-resolution --skip-update
```

另外跑：

```bash
rg -n -U --glob 'Sources/**/*.swift' 'CleaningReport\s*\(\s*removedCount:' Sources
```

预期无输出。

### 7.4 最新组合的完整门

focused 全绿后：

```bash
CLANG_MODULE_CACHE_PATH=/private/tmp/xico-clang-module-cache SWIFTPM_MODULECACHE_OVERRIDE=/private/tmp/xico-swiftpm-module-cache swift test --disable-automatic-resolution --skip-update
CLANG_MODULE_CACHE_PATH=/private/tmp/xico-clang-module-cache SWIFTPM_MODULECACHE_OVERRIDE=/private/tmp/xico-swiftpm-module-cache swift build -c debug --disable-automatic-resolution --skip-update
CLANG_MODULE_CACHE_PATH=/private/tmp/xico-clang-module-cache SWIFTPM_MODULECACHE_OVERRIDE=/private/tmp/xico-swiftpm-module-cache swift build -c release --disable-automatic-resolution --skip-update
```

随后执行 Swift parse、11 语言 `plutil`、privacy/raw-sink/static gates、`git diff --check`。

### 7.5 审查、文档与提交

1. 请求两次独立、只读 final review。
2. 修复全部 Critical/Important 后重跑受影响 focused + full regression。
3. 更新 outcome plan Task 4 的 Step 1–8 checkbox、requirement trace 和 `.superpowers/sdd/progress.md`。
4. 精确暂存 Task 4 production/test 文件，提交 `fix: consume truthful cleaning outcomes`。
5. 再提交文档关闭记录；不要把未验证实现与“完成”声明混在同一提交。

## 8. Task 4 之后仍未完成的工作

### 8.1 Outcome Workflows Tasks 5–14

- Task 5：Space Lens single Trash、basket、partial retention、undo、snapshot result。
- Task 6：Uninstaller ownership consumer、required App body、history、retry、undo。
- Task 7：Shredder item-complete result、取消/部分覆写、永久操作禁庆祝。
- Task 8：Maintenance、helper install、iCloud eviction。
- Task 9：Optimizer terminate postcondition、LaunchAgent composite result、memory purge。
- Task 10：third-party/Xico update check，禁止网络失败伪装“全部最新”。
- Task 11：SFTP、host、tunnel、disconnect、snippet-delete。
- Task 12：download lifecycle 与 component installation。
- Task 13：history/preferences/local account data 与 license deactivation。
- Task 14：zero-ignore ownership、privacy、全量离线门。

### 8.2 Task 5–7 的必须前置

`docs/superpowers/plans/2026-07-16-xico-phase0-destructive-operations.md` 尚未创建。Task 4 完成后必须先按 writing-plans 规格建立并审查该计划，再实施：

1. 通用 prepare → authorize → execute capability。
2. versioned canonical digest、一次性 nonce、expiry、kind/plan/digest binding。
3. LocalFileIdentity 的 device/inode/type/size/mtime/hardLinkCount 复核。
4. Shredder SHR-01…15。
5. Uninstaller UNI-01…15。
6. Space Lens 普通 Trash、snapshot delete identity/policy。

Task 5、6、7 不得绕过此 contract，也不得添加 direct `NSWorkspace.recycle` 或路径字符串 fallback。

### 8.3 其余总计划仍未创建/实施的子计划

- Phase 0 SSH/SFTP/hosts。
- Phase 0 network/components。
- Phase 0 updates/release/privacy。
- Phase 1 architecture。
- Phase 1 information architecture/workflows。
- Phase 2 design system。
- Phase 2 product surfaces（含 docs/08 的 104 个 finding 逐项证据）。
- Phase 2 motion/accessibility/11-language visual matrix。
- Phase 3 monitoring/cleaning/Space Lens differentiation。
- Phase 3 commercial/labs。
- Final 95 acceptance。

### 8.4 仍需要真实外部条件的验收

仓库内工作必须继续，但以下不能伪造完成：

- Developer ID、Apple notarization Accepted、staple、Gatekeeper。
- Production Sparkle/component/definition/license signing roots 与 HTTPS endpoints。
- 支付、webhook、退款、吊销、隐私删除服务。
- 两台真实许可测试 Mac、真实 SSH/SFTP/jump host。
- Safari/Chrome/Edge、外置卷、APFS clone/snapshot、干净 VM N-1→N。
- CleanMyMac/iStat/DaisyDisk/Downie/ServerCat 同任务实验室对标。

只要任一维度 <95、任一活动项未 verified、任一 Critical/Important 未关闭，不能声明总目标完成。

## 9. 恢复时可直接使用的用户指令

用户回来后可以直接说：

> 请从 `.superpowers/sdd/xico-outcome-task4-pause-handoff-2026-07-17.md` 的第 7 节恢复。先修复 admission-rejected failure 漏掉 retained-receipt undo 的 RED 测试，然后完成 Task 4 全部 focused/full/build/双重审查/提交，再继续 destructive-operations 计划和 Outcome Tasks 5–14。不要跳过任何门，也不要宣称总目标完成。

## 10. 禁止事项

- 不要重置、清理或覆盖当前未提交 Task 4 工作树。
- 不要同时启动多个 SwiftPM build/test。
- 不要联网解析依赖；始终使用 `--disable-automatic-resolution --skip-update`。
- 不要运行会触碰真实用户文件的 selftest。
- 不要打包、安装、公证、发布或使用真实密钥，除非进入相应任务且获得必要授权与真实证据。
- 不要把 Threat 37/37、Domain raw typecheck 或单个 focused green 误写成 Task 4/full-program complete。
