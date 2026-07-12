> 用途：把本文件全文粘贴给一个新的 Claude Code 会话即可开始实施。配套总方案见 [`docs/15`](15-全面超越竞品-飞跃升级总方案-2026-07.md)。

# 任务:Xico 清理引擎「更准 · 更安全 · 中国区破局」升级(P0→P1→P2 分阶段实施)

你是在 `/Users/yaokai/Desktop/IT/MacApp/XicoApp` 工作的 Swift/SwiftUI 工程师。只改 `Sources/` 下真实代码,**忽略 `XicoClean/` 与 `.claude/worktrees/`(副本,非源)**。这是一个原生 macOS 清理器,清理引擎的第一卖点是「删得更安全、体积更准、可撤销、可解释」。任何改动**不得触碰或削弱下列红线**:

## 不可逾越的红线(改动前先读,改动后逐条自查)
1. **三道安全闸(纵深防御,禁止绕过)**:摄入期 `Domain/SafetyEngine.swift` 的 `DefinitionPathPolicy`(约 :88)→ 删除期 `verify(_:intent:)`(约 :51,所有删除必须先过)→ 助手期 `Shared/HelperSecurity.swift`(约 :48,特权边界)。共用红线常量在 `Shared/SafetyRules.swift`。**新增任何扫描器/定义,其产出路径都必须能通过 `verify(url, intent: .trash).isAllowed`,不允许在扫描器里私自 `FileManager.removeItem`。**
2. **只移废纸篓 + 100% 可撤销**:删除一律走 `Domain/CleaningEngine.swift` 的 `trashItem`;`.permanent` 永久删除仅限现有缓存/日志白名单,新类别默认一律 `.trash`。
3. **特权边界**:需 root 的系统级路径(`/Library/Caches`、`/Library/Logs` 等)必须标 `requiresHelper` 走 XPC 助手,禁止在主进程直接操作。
4. **体积口径准确**:物理占用一律用 `allocatedSize` / `URLResourceValues.totalFileAllocatedSize`,**全程禁用 `.fileSize`/`fileSize`(逻辑大小)**。对 APFS 克隆/稀疏文件必须按「预计可释放」措辞,不得谎报「精确释放」。
5. **用户个人文件默认不勾**:照片、聊天媒体、安装包、大文件、重复文件一律 `isSelected = false`,与现有 `largeFiles`/`threats` 永不自动勾的姿态统一。

## 已核对的代码现状(避免重复劳动 / 防止改坏)
- `Infrastructure/SpaceLedger.swift` **已实现真实 purgeable**:`collect()`(:29)读 `volumeAvailableCapacityForImportantUsage − volumeAvailableCapacity`,快照走 `tmutil listlocalsnapshots`(3 秒看门狗)。`SmartScanHub.swift:329` 落定后已调用 `SpaceLedger.collect()` 回填。**`SmartScanHub.swift:528` 的 `4.6GB` 常量只存在于 demo/海报注入路径,不是生产路径——不要动它,更不要把生产账本改回常量。** 本项 P0 只需「验证真机上 ledger 三本账真实展示 + purgeable/快照只解释不计入可回收」,无需重写。
- `Infrastructure/DuplicatesScanner.swift:120` 现状:保留路径最短者,`isSelected: idx != 0`(其余全默认勾),`safety: .caution`,已有 `anyAreClones` 克隆提示但仍用 `size`(需核实是否物理值)。
- `Infrastructure/SimilarImagesScanner.swift:126` 现状:保留最大者,`isSelected: idx != 0`(其余全默认勾);roots 默认仅 Pictures/Desktop/Downloads(:37),不含 `.photoslibrary`;`maxGroups=200`。
- `Infrastructure/Scanners.swift:598` 安装包:`stale`(>30 天)时 `isSelected: stale` **默认勾**;:120 区日志已保守化(仅异常膨胀 ≥500MB 勾),但**诊断/崩溃报告**需确认是否默认勾。
- `Features/AppModel.swift:254` 重复文件扫描根 `duplicatesFolderBox` 默认仅 `~/Downloads`。

---

## P0(上线前必修 · 信任红线 + 中国区破局)——**做完必须暂停,等我确认后再继续 P1**

**改动点:**

1. **修四处激进默认勾(核心信任动作)**
   - `DuplicatesScanner.swift:120`:重复组内非保留项由默认全勾改为**默认不勾**(`isSelected = false`),把「删哪个」交回用户。
   - `SimilarImagesScanner.swift:124-127`:相似图非保留项**默认不勾**。
   - `Scanners.swift:598`:>30 天安装包 DMG **不再自动勾**(`isSelected = false`),对齐 CleanMyMac 安全姿态;保留「装完即可删」提示文案。
   - 崩溃/诊断报告(`diagnostic-reports` 一类):从默认勾改为 `caution` 且默认不勾——删了会毁诊断史。先 `grep -rn "diagnostic\|CrashReporter\|DiagnosticReports" Sources/Domain/Resources/definitions.json Sources/Infrastructure/Scanners.swift` 定位真实规则再改。

2. **重复文件默认扫描根扩到全家目录**
   - `AppModel.swift:254`:`duplicatesFolderBox` 默认从单一 `~/Downloads` 改为多根(`~/Downloads`、`~/Documents`、`~/Desktop`、`~/Movies`),保持用户可在 `DuplicatesView` 手动更换目录的能力。确认 `DuplicatesScanner` 支持多根输入,不支持则加。

3. **全局体积口径统一为物理值 + APFS 克隆扣除**
   - 审计 `DuplicatesScanner.swift` 与 `SimilarImagesScanner.swift` 的 `size` 来源,凡走 `LocalFileSystemService` 逻辑 `fileSize`(约 `LocalFileSystemService.swift:137`)的,改为 `.totalFileAllocatedSizeKey`/`allocatedSize`。
   - 重复/相似图的组内「可回收」措辞统一为「**预计可释放**」;对 `anyAreClones` 命中的组,`wasted` 展示明确标注「含 APFS 克隆,实际释放可能接近 0」。
   - 删除落定后(`SmartScanHub.swift:329` 附近,`SpaceLedger.collect()` 同一时机),用**卷级实测差值**(删前/删后 `volumeAvailableCapacity` 之差)回填「实测释放」,与「预计」并列展示。若本次改动过大,P0 先只保证「预计」口径正确 + 克隆标注,实测回填放 P1。

4. **微信专清(中国区最大差异化,新增扫描器)**
   - 新增 `Sources/Infrastructure/WeChatScanner.swift`,bundleId `com.tencent.xinWeChat`。
   - **动态枚举路径**(硬编码会随版本失效):容器内 4.0 版 `Documents/xwechat_files/wxid_*/`,旧版 `.../Message/{MessageTemp,Video,Image}`,两条路径都枚举。
   - 分级:头像/表情/小程序 `.wxapplet` 缓存 = `safe`;聊天图片/视频/文件/语音 = `caution` **默认不勾**,支持「仅清 N 天前」时间档(默认 90 天);`Message/*.db`(聊天记录数据库)= `risky`,**永不删、只列出解释**。
   - 所有产出路径必须过 `SafetyEngine.verify`;删除走 `trashItem`。集成进 `Domain/Definitions.swift` 与 `Features/SmartScanHub.swift` 六类并行中枢(作为「中国区专清」类目或并入 junk 子组,按现有 `SmartCategory` 结构决定)。

5. **诚实账本 P0 验证(不重写)**:确认 `SpaceLedger.collect()` 在真机返回真实 purgeable/快照,UI 三本账(永久回收 / purgeable / 本地快照)分开陈述,purgeable 与快照**只解释不计入可回收**。

**P0 验收标准(逐条真机自证后再暂停):**
- 编译通过、六类并行扫描能在真机跑完不崩。
- 四处默认勾已改:全新扫描后,重复/相似图/安装包/诊断报告初始均为未勾,总「可回收」数字只含 safe 类。
- 微信专清能扫出真实容器数据,聊天媒体默认不勾,90 天档生效,`.db` 不可删;删任一 safe 项走废纸篓且可从废纸篓恢复。
- 重复/相似图体积对得上 Finder「显示简介」与 `du -h`(物理值),克隆文件有明确标注,不再谎报精确释放。
- 账本 purgeable 值与 `df` / 系统「关于本机-储存空间」量级一致,未计入可回收。
- **完成后停下,汇报改了哪些文件、真机验证结果、体积对账结果,等我确认。**

---

## P1(全面性与准确性补齐 · 中国区扩面)——P0 确认后再做

- **系统垃圾补全(`definitions.json`)**:字体缓存 `~/Library/Caches/com.apple.FontRegistry`(safe);Xcode `DocumentationCache`、`ModuleCache.noindex`;Darwin TEMP(`_CS_DARWIN_USER_TEMP_DIR`)+ `/tmp`、`/private/var/tmp` 通用临时残留。系统级字体缓存维护走 `atsutil` 脚本(归 `MaintenanceRunner`,**不删文件**)。每条新增定义必须同步进 `SafetyEngine.swift:114-121` 的 `libraryExtraAllowedSubtrees`。
- **判活/保留策略**:iOS `DeviceSupport` 改「按版本保留最近 N 个」不整删;`CoreSimulator` 废弃 runtime 走 `xcrun simctl delete unavailable` 判活,不硬删 Devices;iOS 设备备份「最近一次永不勾」白名单。
- **相似图纳入 Photos 库**:`SimilarImagesScanner.swift:37` roots 加 `~/Pictures/*.photoslibrary`;`maxGroups` 放宽。
- **大文件**:阈值可调 + 纳入外置卷 + 提高封顶(`Scanners.swift:370,451`)。
- **中国区扩面**:QQ/TIM(`com.tencent.qq*`)、钉钉(`5ZSL2CJU2T.com.dingtalk.mac`)、飞书/Lark 专清;**一条 Chromium 通用规则**吃掉 360/搜狗/UC/夸克/QQ/Edge——只删 `Cache/Code Cache/GPUCache/Service Worker/CacheStorage`,**绝不碰 `Cookies/History/Login Data`(risky)**;`OrphanScanner.swift` 补国产厂商前缀表(`com.tencent./com.alibaba./com.baidu./com.bytedance./com.kingsoft./com.xunlei./com.sogou.`)。
- **Docker 引导项**:加 `caution` 引导跑 `docker system prune`,**绝不删 `Docker.raw`**(risky 只提示)。
- **判活统一 bundleId**:`Scanners.swift:250` 由进程/App 名判活改为 `NSWorkspace.runningApplications` 的 `bundleIdentifier`(参照 `OrphanScanner.swift:52`);运行中 App 的活缓存降 `caution` 默认不勾。
- **性能让步**:`Scanners.swift:216` 同步递归 `allocatedSize` 内插 `await Task.yield()`,或复用 `BulkDirectoryReader` 的 `getattrlistbulk` 批读,避免大容器缓存拖慢逐类到达。
- **逐规则可解释**:`definitions.json` 每条补 `explanation`(是什么/为何可删/删后影响/能否重建),在「Xico 安全库」逐条展示。
- **缺权限不算 0**:扫 `~/Library/Mail`/`Safari`/`Messages` 缺 FDA 时明确标「部分未读」,不静默算 0。
- **删后实测回填**(若 P0 未做):落定用卷级差值回填「实测释放」,结果页展示「预计 X / 实测 Y」。
- **CI 红线单测**:加单测遍历 `definitions.json` 每条 path,断言 `DefinitionPathPolicy.isAllowed(...) == true`,把「定义 ↔ 白名单」同步纪律固化为 CI 红线。

**P1 验收:** 真机能扫出新增类目;体积对得上 Finder/`du`;判活对运行中 App 生效(删活跃 Electron 的 Code Cache 不会误勾);新增单测通过;缺权限场景有「未读」标注而非 0。

---

## P2(差异化纵深)——P1 确认后再做

- 新增「损坏登录项/悬空别名/失效偏好」扫描器(对标 CMM);`ThreatScanner.swift` 扩面(登录项 btm/描述文件/扩展),`threatSignatures` 走 `DefinitionsUpdateService` 的 Ed25519 签名通道下发,**不在本地硬拼病毒库**。
- 网盘(百度/迅雷/夸克,`fsCachedData` safe、未完成下载 caution)、WPS、企业微信/腾讯会议(录屏大文件)专清。
- 僵尸 `node_modules` 全盘扫荡(按父目录 mtime 分档)、构建产物 `target/dist/.next`、Android `~/.android/avd`。
- 健康分(`HealthScore.swift`)联动扫描结果子项;AI 自然语言解读:「本次可精准回收 X GB(已扣 APFS 克隆),另有 Y GB 系统快照 Xico 不代删并解释原因」——严格基于真实数据,不编造。

**P2 验收:** 各扫描器真机可跑;签名下发链路走通;AI 摘要数字与账本一致。

---

## 全程纪律
- 每完成一个阶段,先自查上面全部红线,再在真机跑一遍受影响的扫描类目,用 `du -h`/Finder 简介核对体积口径,然后暂停汇报,等我确认才进入下一阶段。
- **先只做 P0,做完立即停下等我确认,不要一口气做到 P1/P2。**
