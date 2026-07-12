> 用途：把本文件全文粘贴给一个新的 Claude Code 会话即可开始实施。配套总方案见 [`docs/15`](15-全面超越竞品-飞跃升级总方案-2026-07.md)。

# Xico 空间透镜「飞跃式超越 DaisyDisk」实施提示词

你是 Xico（原生 macOS 三合一系统工具）的资深 Swift/SwiftUI 工程师。现在要对「空间透镜（Space Lens）」模块做一次分期升级，目标是在**更好看 / 更好用 / 更全面 / 更准**四个维度全面超越 DaisyDisk。

## 一、绝对红线（任何阶段都不得触碰）

1. **体积口径不得再虚高**。历史上修过「1.79TB 虚高」四病根（硬链接、稀疏/压缩、跨挂载点、云占位）。本次新增去重逻辑只能让总量更准、更保守，**严禁任何路径导致同一物理块被重复计数**。总量口径必须能和卷「已用空间」对得上账。
2. **删除必须走 SafetyEngine 红线 + 可撤销**。禁止任何绕过 `Sources/Domain/SafetyEngine.swift` 的删除；禁止永久删除、禁止绕过废纸篓（快照删除是唯一例外，见 P0-2，需独立二次确认分支）。所有删除必须可恢复。
3. **扫描不得卡 UI**。扫描全程在后台并发执行，主线程只做渲染；不得因为透镜扫描拖慢菜单栏每 2s 的指标采样。旭日环下钻/动画必须顺滑（60fps 目标）。
4. **只读改 `Sources/` 下真实代码**。忽略 `XicoClean/` 与 `.claude/worktrees/`（副本，非真源）。

## 二、关键文件锚点（改动前先通读确认现状，行号可能已漂移，以符号定位为准）

- 扫描内核：`Sources/Infrastructure/BulkDirectoryReader.swift`（attrs 定义 ~:70-79 / `O_NOFOLLOW` ~:62 / `parseRecord` ~:164 / 回退 `readViaFileManager` ~:187）、`Sources/Infrastructure/DiskTreeScanner.swift`（`withTaskGroup` ~:125 / 去重 `countFirstSighting`+`seenHardLinks` ~:327 / `hiddenSpaceNode` ~:298 / `ScanContext` ~:311）
- 数据模型：`Sources/Domain/DiskNode.swift`（`pruneSubtree` ~:74 / `isAggregate` ~:38）、`Sources/Domain/Models.swift`（`CleaningPlan` ~:198 / `CleanableItem` ~:199 / `VolumeCapacity` ~:272 / `RestorableItem` ~:224）
- 可视化：`Sources/Features/SunburstView.swift`（`vividPalette` ~:167 / `familyShades` ~:180 / `arcButton`+`RingSector` ~:272 / 中心盘 ~:412 / `buildArcs` ~:621 / `contextMenu` ~:312 / 隐藏空间文案 ~:203）、`Sources/Features/TreemapView.swift`（`readableText` ~:189）
- 操作闭环：`Sources/Features/SpaceLensView.swift`（`scanRoot` ~:22 / FDA 引导 `lacksFullDiskAccess`/`openFullDiskAccessSettings` ~:229 / `trash` ~:238 / `trashMany` ~:281 / `emptyResult` ~:517）、`Sources/Features/CollectionBasket.swift`（`performTrash` ~:99 / 庆祝页 `BasketCompletionHost` ~:292）
- 引擎/协议：`Sources/Domain/CleaningEngine.swift`（`execute` ~:18 / `undo` ~:138）、`Sources/Domain/SafetyEngine.swift`（`verify` ~:51 / `permanentHomeAllowlistLower` 白名单 ~:37）、`Sources/Infrastructure/ICloudEvictor.swift`、`Sources/Domain/Protocols.swift`（`volumeCapacity` ~:29）

## 三、P0（准确性 + 竞争缺口，本轮先只做这三项）

**P0-1 修 APFS clone（CoW 克隆）重复计数** — 最大准确缺口
- 现状：只对 `linkCount>1` 硬链接去重，对 CoW clone（`cp -c`、Xcode DerivedData、原子写）**零去重**，共享块被算两遍。
- 落地（推荐方案 A）：在 `BulkDirectoryReader` 的 `attrs.forkattr` 增加 `ATTR_CMNEXT_PRIVATESIZE`（macOS 10.13+），必须配 `ATTR_CMN_RETURNED_ATTRS` 并按 `returned.forkattr` 位判断该字段是否真的返回，解析逻辑接在 `parseRecord` 之后。节点尺寸口径改为**优先 privatesize（独占块）作真值**，同时保留 `ATTR_FILE_ALLOCSIZE` 作展示值另存字段。总量 = Σ privatesize = 真实可释放空间，**无需维护全局 clone 表、零额外内存**。
- 波及 `DiskTreeScanner` 中尺寸累加与聚合的三处（子节点 size 求和、collapse、aggregate）。改完必须验证：privatesize 缺失（老系统/非 APFS）时优雅回退到 allocsize，不得崩、不得算 0。

**P0-2 隐藏空间拆分 + 本地快照一键清理**
- 现状：`hiddenSpaceNode`（卷已用 − 可见）是单块恒不可删的灰色聚合桶，快照/purgeable 全糊在一起。
- 落地：把它升级为可展开目录节点，拆三段子节点：
  - `本地快照 (可删)`：`tmutil listlocalsnapshots /` 枚举，给可操作子项（`isAggregate=false` + 新增 `snapshotDate` 字段）。删除**不走废纸篓**，走新增独立通道 `tmutil deletelocalsnapshots`，必须**二次确认弹窗** + 经 `env.safety` 的独立放行分支判定，绝不复用普通文件删除路径。
  - `可清除 (purgeable)` = 已用 − 已扫描 − 快照，`isAggregate=true` 只解释。
  - `无权限读取区`，`isAggregate=true` 只解释（P1 再接 FDA 引导）。
- 更新 `SunburstView` 隐藏空间文案 ~:203。

**P0-3 收集篮删除改走 CleaningEngine + 应用内 Undo**
- 现状：`trashMany` 直接裸调 `NSWorkspace.shared.recycle` 循环，无应用内撤销栈，与「清理」页两套口径。
- 落地：新增 `DiskNode → CleanableItem` 适配层（映射 url/size/displayName）；`trashMany` 改为构造 `CleaningPlan(items:, intent: .trash)` 调 `env.cleaningEngine.execute(plan)`，拿回 `CleaningReport`（含 `restorable`）。在 `BasketCompletionHost` 庆祝页加「撤销」按钮，调 `CleaningEngine.undo(report)` 把废纸篓项移回原位。删除成功后仍就地 `pruneSubtree` 剪枝。
- 收益：红线口径统一（execute 内含逐项 `safety.verify` + TOCTOU 复校，比现状单次 verify 更严）。

## 四、P0 验收标准（真机，Apple Silicon）

- **体积对得上**：对含大量 DerivedData/克隆的 `~/Library/Developer` 与整卷根扫描，透镜总量与 `df`/「关于本机-储存空间」已用误差 < 3%，且**去重后总量只减不增**。
- **快照可删**：能列出真实本地快照并成功 `deletelocalsnapshots` 释放空间，删除前必弹二次确认；普通文件删除路径完全不受影响。
- **Undo 生效**：收集篮删除后点「撤销」，文件从废纸篓回到原路径，透镜重扫可见其归位。
- **不卡 UI**：P0-1 新增 attr 解析后，256GB 级目录扫描时长不劣于改动前；扫描中菜单栏指标采样无明显卡顿。
- **回退安全**：非 APFS 卷 / privatesize 不返回时，尺寸口径正确回退，无崩溃、无 0 值。

## 五、P1 / P2（P0 确认通过后再排期，本轮不做）

**P1（快 + 全面）**：P1-4 `withTaskGroup` 加并发信号量限流（`activeProcessorCount*4`）；P1-5 硬链接/clone 去重表 `fileID % 64` 分片锁；P1-6 无权限区上报 `deniedDirs` + 结果页横幅引导开 FDA（复用 `emptyResult` 按钮）；P1-7 环段内嵌切向标签（sweep ≥18° 且径向 ≥28pt 才画，字色用 `readableText`）+ 卷根「可用空间」低饱和楔形 + 中心副行显示可用容量；P1-8 iCloud 已下载大文件 contextMenu「从本地移除（保留云端）」调 `ICloudEvictor`；P1-9 `⌘⌫` 键盘删除选中项。

**P2（顺滑 + 差异化）**：P2-10 增量 mtime 缓存（加 `ATTR_CMN_MODTIME`，目录 mtime 未变则复用子树，DaisyDisk 无此项）；P2-11 多卷选择器 + 跨树搜索（`SpaceLensModel` 加 `searchText`）；P2-12 `TreemapView` 改 squarified + 2 层嵌套；P2-13 中心盘 Liquid Glass 质感；P2-14 缓冲区 A/B（256KB→128KB 实测）+ URL 零桥接；P2-15「可安全清理」徽标联动 `SafetyEngine` 白名单。

## 六、执行方式（重要）

**先只实施 P0-1、P0-2、P0-3 三项，完成后停下来汇报改动清单与自测结果，等我确认，再进入 P1。** 不要一次性把 P1/P2 也写了。每完成一项 P0 先跑构建（`swift build`）确保通过。涉及体积口径与删除路径的改动，在汇报里明确写清「新口径如何保证不虚高」「快照删除的二次确认与红线分支在哪」「Undo 走的是哪条恢复路径」。
