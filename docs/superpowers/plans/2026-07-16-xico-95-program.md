# Xico 95+ 全产品升级执行总计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 完成 `docs/20-全量文档任务台账与95分验收矩阵-2026-07-16.md` 中全部仍然有效的活动任务，关闭所有 Critical/Important 问题，并让安全、可靠性、架构、性能、功能、UX、视觉、无障碍八个维度分别达到至少 95/100。

**Architecture:** 先用 Phase 0 的 Operation Facts、Destructive Operation Boundary 和 TrustCore 建立不可绕过的事实与信任边界；再拆分架构和信息架构；随后统一设计系统、全页面状态、动效和辅助功能；最后补齐差异化功能、性能实验室、商业闭环与正式发布证据。每个阶段只根据当前 HEAD 的代码、测试、截图/录屏、真机或发布产物改变台账状态。

**Tech Stack:** Swift 6、SwiftPM、SwiftUI、少量 AppKit、Darwin/POSIX、CryptoKit、系统 SSH/SFTP、Sparkle 2、XCTest、shell 发布脚本、macOS 14+。

## Global Constraints

- 以 `docs/19-Phase0-可信发布基线-设计规格-2026-07-16.md` 和 `docs/20-全量文档任务台账与95分验收矩阵-2026-07-16.md` 为当前规格；历史“全部完成”报告不能覆盖当前证据。
- 每个代码任务严格执行 RED → GREEN → focused regression → full regression；没有先失败测试的功能/修复不得实现。
- 每个请求项必须产生且只产生一个 disposition；只有 reducer 判定的真实完整成功可以触发成功通知、声音、触觉、粒子和成功次数。
- 所有危险动作都使用 prepare → authorize → execute；确认前无副作用，授权绑定 versioned digest、一次性 nonce、时效和目标身份。
- 安全失败一律 fail closed；回滚不能恢复粉碎吞错、模糊卸载归属、深链自动下载、组件 fallback、JSON endpoint 与 Keychain 凭据自由组合或非标准更新签名。
- 不恢复已被后续实机/产品决策覆盖的僵尸设置：状态栏逐项边框、旧六预设、导致白曝的侧栏玻璃、天气/时钟。
- Photos Library 只能经 Photos.framework 与用户授权访问；不得裸枚举 `.photoslibrary`。
- `.fileSize` 可以用于哈希分组的逻辑长度，但不能冒充最终可释放物理字节。
- 保留用户和其他任务的未提交改动；每个提交只暂存当前任务列出的精确路径。
- 不使用破坏性 Git 命令；不得用 mock、旧截图或脚本存在代替 Developer ID、公证、支付、真实 SSH、真机性能等外部证据。
- 每条实际执行的 `swift test` / `swift build` 命令必须在命令本身直接携带 `--disable-automatic-resolution --skip-update`；只使用已锁定且已缓存的 `Package.resolved`，缺缓存时标记 blocked，不得联网解析或改写 lockfile。
- 任一维度低于 95、任一活动任务未 verified、任一 Critical/Important 未关闭时，只能声明阶段完成，不能声明总目标完成。

## Authoritative Inputs

- 审计与基线：`docs/XICO_COMPREHENSIVE_AUDIT_2026-07-16.md`
- Phase 0 规格：`docs/19-Phase0-可信发布基线-设计规格-2026-07-16.md`
- 153 项归一化任务与评分门：`docs/20-全量文档任务台账与95分验收矩阵-2026-07-16.md`
- 当前分支：`codex/precision-monitoring`
- 计划建立时 HEAD：`cca34eded2967bc701cc0dfe813837754a389d85`

## Plan Set and Execution Order

### Phase 0 — 可信发布基线

- [ ] `2026-07-16-xico-phase0-operation-facts.md`：OUT-01…10、CleaningReport、历史、统一副作用。
- [ ] `2026-07-16-xico-phase0-destructive-operations.md`：通用授权、本地身份、粉碎、卸载、Space Lens 删除。
- [ ] `2026-07-16-xico-phase0-ssh-sftp-hosts.md`：SecureHostBinding、SFTP、主机与隧道事务。
- [ ] `2026-07-16-xico-phase0-network-components.md`：外部深链、SSRF、InAppBrowser、组件 catalog/receipt。
- [ ] `2026-07-16-xico-phase0-updates-release-privacy.md`：Sparkle bridge、唯一发布入口、隐私清单、政策同源化。
- [ ] `2026-07-16-xico-phase0-outcome-workflows.md`：清理、维护、优化、更新、卸载、粉碎等结果 UI 与重试/撤销；按下列 task-level prerequisites 分段执行，不等待或绕过未落地的上游 contract。

Outcome workflows 的精确执行前置（覆盖上方文件展示顺序）：

1. 先完成 operation-facts Tasks 1–4；其 Tasks 5–7 仅为 non-executable handoff。
2. outcome Task 1 在 operation-facts Task 4 后执行；outcome Task 2 必须等待 Task 1 的 registry，Task 3 必须等待 Tasks 1–2，Task 4 必须等待 Tasks 1–3。因此共同消费者基座的唯一顺序是 **1 → 2 → 3 → 4**；不得将 Tasks 1–4 并行执行。
3. 只有 outcome Tasks 1–4 完成后才可执行 consumer-family Tasks 5–13；destructive/SSH/network/update 各自的 contract tasks 可与前四任务并行推进，但不能被 consumer 绕过。
4. outcome Tasks 5–7 还必须等待 destructive-operations 对应 Space Lens、uninstall、shred contract。
5. outcome Tasks 8–9 在 Tasks 1–4 后执行，并各自在自身首个实现步骤先建立本地 injectable executor contract；该 contract 是任务内部前置，不是会形成循环的外部 prerequisite。
6. outcome Task 10 还必须等待 updates-release-privacy 的更新 trust contract；Task 13 的 license deactivation 子流程同样等待其 seat/trust contract，其本地子流程可在 Tasks 1–4 后独立推进。
7. outcome Task 11 还必须等待 ssh-sftp-hosts 的 identity/transaction/`stopAndWait` contract；Task 12 还必须等待 network-components 的 trusted installer/receipt contract。
8. outcome Task 14 必须等待 Tasks 1–13 以及全部上述上游 contract evidence，再运行最终门。

### Phase 1 — 架构、IA 与核心工作流

- [ ] `2026-07-16-xico-phase1-architecture.md`：A-01…07，依赖方向、DI、巨型文件、重复事实源和静态门禁。
- [ ] `2026-07-16-xico-phase1-information-architecture.md`：IA-01…04、WF-01…10，Smart Care / Space & Apps / Pro Tools 和原生 Settings。

### Phase 2 — 设计、UI、动效、无障碍

- [ ] `2026-07-16-xico-phase2-design-system.md`：DS-01…10 与 feature 层静态门。
- [ ] `2026-07-16-xico-phase2-product-surfaces.md`：V-01…10 和 docs/08 的 104 个 finding。
- [ ] `2026-07-16-xico-phase2-motion-accessibility.md`：MOT-01…07、AX-01…07、11 语言和视觉矩阵。

### Phase 3 — 差异化、性能、商业与实验室

- [ ] `2026-07-16-xico-phase3-monitoring-cleaning-spacelens.md`：MON-01…15、CLN-01…10、SPL-01…05。
- [ ] `2026-07-16-xico-phase3-commercial-labs.md`：DL、SRV、COM、WEB、LAB、BENCH 活动项与外部证据。
- [ ] `2026-07-16-xico-final-95-acceptance.md`：最终八维评分、0 Critical/Important、正式 artifact 和全部任务 closure。

## Stage Protocol

每个子计划必须执行以下相同协议：

1. 记录开始 HEAD 和 `git status --short`；工作树非干净时只隔离当前任务精确文件。
2. 列出本任务所有 requirement/work-package ID，并逐项映射到测试、实现和验收证据。
3. 先新增一个只验证单一行为的失败测试，运行精确 `swift test --filter ... --disable-automatic-resolution --skip-update` 并保存预期失败原因。
4. 只写让该测试通过的最小生产代码；再次运行同一 focused test。
5. 运行受影响 target 的离线测试、`swift build -c debug --disable-automatic-resolution --skip-update` 和 `swift build -c release --disable-automatic-resolution --skip-update`。
6. 对安全/并发/迁移变更运行对抗或故障注入测试；对 UI 运行确定性截图和辅助功能矩阵；对发布运行真实产物门。
7. 用当前证据更新台账状态和 requirement trace；不得把 `partial` 自动升级成 `verified`。
8. 请求独立代码复核，修复所有 Critical/Important 发现，再复跑验证。
9. 精确暂存并提交；提交信息只描述已验证的行为。

## Program-Level Verification Gates

- [ ] `swift build -c debug --disable-automatic-resolution --skip-update` 通过。
- [ ] `swift test --disable-automatic-resolution --skip-update` 全量通过，0 failure；skip 必须逐项有环境原因且不掩盖活动任务。
- [ ] `swift build -c release --disable-automatic-resolution --skip-update` 通过。
- [ ] `scripts/quality_gate.sh` 和所有静态门通过。
- [ ] 所有 OUT/SHR/UNI/SFT/SSH/SRV/PRV/NET/CMP/UPD/REL/UI-OUT requirement 有当前证据。
- [ ] docs/08 的 104 个 finding 逐项人工/截图验收，而不是按 surface 批量关闭。
- [ ] Premium roadmap 的 26 项 T1/T2/T3 映射任务逐项 verified 或有正式 superseded/invalid 决策。
- [ ] 精准监控 Task 8/9 在最终 HEAD 重跑六图、8/8 真机准确度和同实例性能。
- [ ] 最新 App/DMG 为 Universal、Developer ID、notary Accepted、stapled、`spctl` accepted。
- [ ] Sparkle N-1→N、组件、定义、许可、线上 artifact 回源和 appcast-last 发布链通过。
- [ ] light/dark × aurora/graphite/warmLuxe/jewel × 关键状态 × 窗口宽度截图通过像素与人工双审。
- [ ] 11 语言、VoiceOver、键盘、Reduce Motion、Reduce Transparency、Increase Contrast、Differentiate Without Color 全流程通过。
- [ ] CleanMyMac/iStat/DaisyDisk/Downie/ServerCat 同任务实验室数据完成，并记录设备、版本、输入和测量方法。
- [ ] 八个维度分别 ≥95；0 个未关闭 Critical/Important。

## External Evidence Policy

仓库内可以先完成 fixture、fail-closed 行为和自动门，但下列项目保持 `external`，直到真实条件到位：

- Apple Developer ID 私钥/证书、notarytool profile、App/DMG 公证与 Gatekeeper。
- 生产 Sparkle、组件、定义和许可签名根及 HTTPS endpoint。
- 支付、webhook、发码、退款、吊销、反馈与隐私删除服务。
- 两台许可测试 Mac、真实 SSH/SFTP/jump、Safari/Chrome/Edge、外置卷、APFS clone/快照。
- 干净 VM 的 N-1→N 更新与迁移。

外部条件缺失不会授权伪造证据，也不会把总目标标记 complete；其余所有可在仓库和当前 Mac 完成的任务必须继续推进。
