# Xico 全面产品、代码、安全与体验审计

- 审计日期：2026-07-16
- 审计对象：`codex/precision-monitoring` / `ef58e236b3e01681658e4051c309490c6a6ed84f`
- 审计规模：369 个受版本控制文件、约 54,981 行 Swift/C/JS/Shell、160 个源码文件、53 个测试源文件
- 审计基线：当前工作树、当前 HEAD、当前 Debug/Release 构建、当前测试与当前离屏截图；旧版自评仅作历史材料，不作为结论

## Executive Summary

- **综合评分：72/100。** Xico 已经不是原型，而是一款功能广、视觉成熟、具备明显差异化的 macOS 工具；但它目前还不能被评为“顶级可发布产品”。主要短板是数据安全、结果真实性、发布供应链、隐私披露、无障碍和全球化，而不是缺少渐变或动画。
- **发布结论：有条件阻断。** 当前 HEAD 的质量门和 373 个测试可以通过，但仍有多个测试未覆盖的高严重度逻辑问题：粉碎取消/写入失败后仍可能删除原文件，硬链接粉碎还会破坏同一 inode 的其他路径；卸载器可能误选其他应用数据；多个模块失败后仍显示成功；当前自定义更新签名语义与标准 Sparkle 归档签名冲突；隐私政策与实际联网行为不一致。
- **产品结论：功能广度强于单一清理器，核心叙事弱于 CleanMyMac。** Xico 同时覆盖清理、磁盘空间、硬件、监控、服务器和下载器，这是优势；但隐藏工具过多、模块边界松散、结果状态不可信，使其更像“漂亮的工具集合”，还不是一个高度聚焦的 Mac 健康与效率中枢。
- **视觉结论：暗色视觉已接近成熟商业产品，浅色、空态、语义色和动效预算仍需重构。** 下一次飞跃不应继续叠加辉光，而应建立 outcome-aware 结果系统、Calm/Precision 视觉层级、原生窗口工作流、全量 Reduce Motion 和 VoiceOver 支持。

## 1. 评分与判定口径

综合分使用加权模型。通过测试只证明被覆盖行为，不会抵消测试之外已经确认的逻辑缺陷；视觉完成度也不会抵消清理器的潜在数据损失风险。

| 领域 | 权重 | 分数 | 主要依据 |
|---|---:|---:|---|
| 安全、隐私与发布链 | 20% | 61 | helper 删除设计很强；粉碎、卸载、深链、SSH 元数据、隐私政策和更新发布链有高风险缺口 |
| 正确性与可靠性 | 20% | 72 | 373 个测试通过；多个真实失败被 UI 成功化，批量操作和错误传播不完整 |
| 产品能力与差异化 | 15% | 82 | 清理、Space Lens、监控、服务器、下载器组合少见，核心能力广 |
| UX 与信息架构 | 15% | 78 | 主流程完整；隐藏工具、设置长页、危险态和状态模型拖分 |
| 视觉与动效 | 10% | 81 | 暗色、品牌环、卡片和图表成熟；浅色层级、动效常驻和语义一致性不足 |
| 架构与可维护性 | 10% | 68 | Swift 6、模块化基础良好；依赖倒置、全局状态、巨型文件和第二仓库事实源明显 |
| 性能与能效 | 5% | 74 | 标准探针表现优秀；Release/高负载、动画 GPU、长时间能耗仍缺权威数据 |
| 无障碍与全球化 | 5% | 60 | 局部实现优秀；菜单栏、图表、键盘、高对比、11 语言质量尚未系统达标 |
| **综合** | **100%** | **72** | 当前可作为高质量 beta/内部候选，不建议以“已超越 CleanMyMac”的口径正式发布 |

评分含义：

- 90–100：可证明的行业顶级品质，发布链、可访问性、可靠性和体验闭环完整。
- 80–89：成熟商业产品，只有有限、非阻断缺口。
- 70–79：有明显产品价值，但存在发布阻断或系统性体验债务。
- 60–69：能用但风险、质量或定位存在明显短板。
- 60 以下：不建议面向真实用户发布。

## 2. 实际构建、测试与性能证据

### 2.1 已通过的质量门

在沙箱外、允许 Swift/Clang 正常写缓存和测试废纸篓行为的环境中，项目自带 `scripts/quality_gate.sh` 完整通过：

- Swift 6 Debug 构建通过，首次增量耗时 10.70 秒。
- 默认测试套件通过：373 个测试，15 个跳过，0 个失败，约 7.43 秒。
- ProcessSnapshotProvider、ApplicationUsageAggregator、HelperProcessSampling、MemoryMetrics、ApplicationUsagePresentation 专项套件通过。
- ScanIntelligence 与 ScanSnapshotStore 回归预算通过；1,000 文件快照测试约 0.319 秒。
- `make_app.sh`、`notarize.sh`、`release_preflight.sh` Shell 语法检查通过。
- 主应用和 helper entitlements 的 `plutil` 检查通过。
- 11 个 `Localizable.strings` 的 plist 语法检查通过。
- Chrome 扩展 manifest、background/content/popup JS 语法检查通过。
- definitions、download components、license 三套 Ed25519 签名工具 self-test 通过。
- Swift Release 构建通过，耗时 104.64 秒。
- `git diff --check` 通过。

### 2.2 标准性能探针

当前 Debug 二进制的 `--perfprobe=standard` 在沙箱外完成：

| 指标 | 实测 | 项目目标 | 判定 |
|---|---:|---:|---|
| 采样进程 CPU | 0.091% | 菜单栏稳态 < 0.5% | 通过，且有余量 |
| 单次采样平均耗时 | 1.03 ms | 未设置硬阈值 | 良好 |
| 单次采样 P95 | 1.60 ms | 未设置硬阈值 | 良好 |
| 进程 physical footprint | 34.7 MB | < 80 MB | 通过 |
| 采样间隔 | 1 秒 | 支持 1/2/5 秒 | 最高频配置 |

这个结果只证明标准采样器在当前机器、Debug 构建和短观察窗下表现良好。它不能替代以下尚未完成的证据：Release 冷启动、60 秒 live pipeline、CPU/内存详情进程枚举、峰值 RSS、动画 GPU、Energy Log、长时间菜单栏稳态和真实大目录扫描。

### 2.3 测试环境与测试设计缺口

在 Codex 文件沙箱内复跑 `swift test --skip-build` 时，真实废纸篓写入被拒绝，`CleaningRoundTripTests` 随后失败；其中 `report.restorable[0]` 在前置断言失败后仍直接索引，触发 `Index out of range`。沙箱外同套测试通过，因此这不是已证实的产品清理回归，但揭示两个测试工程问题：

1. 往返测试依赖真实用户废纸篓，不是完全隔离、可移植的测试夹具。
2. 测试在关键前置条件失败后继续用下标访问，导致“清晰的测试失败”升级为测试进程崩溃。

应为 FileSystem/Trash 注入确定性双替身，并用 `XCTUnwrap` 或 guard 保护前置条件；真实废纸篓测试保留为单独、显式授权的端到端套件。

### 2.4 仍然缺少的发布证据

- 干净 checkout 和空 `.build` 的可重复构建。
- Intel 真机运行；CI 当前只验证 universal 架构，不等于 Intel 行为正确。
- 最终 `.app`/`.dmg` 的 `codesign --verify --strict`、嵌套 helper、`spctl`、`stapler validate` 和公证日志。
- 全新用户账户上的安装、FDA、helper 批准、升级、卸载和拒绝权限路径。
- 真机 SSH、SFTP、隧道、浏览器深链和私网目标策略测试。
- Instruments 的 SwiftUI、Time Profiler、Allocations、Energy Log 和 Accessibility Inspector 证据。

本机 `/Users/yaokai/Applications/Xico.app` 当前不能通过严格签名校验，但该产物可能陈旧或被修改，不能直接归因于当前源码；它只能说明“当前没有可证明合格的发布产物”。

## 3. 功能地图与成熟度

| 工作区/功能 | 当前能力 | 成熟度 | 主要问题 |
|---|---|---:|---|
| 首次使用 | 欢迎、能力介绍、FDA 实时检测、首扫 | 8/10 | 本地隐私和“不读取内容”文案不准确 |
| 许可与购买 | 试用、买断、激活、深链确认、席位释放 | 7/10 | 试用天数和隐私披露不一致，自动复验未充分告知 |
| 智能扫描 | 六类并行、逐类状态、Review、混合意图确认、撤销 | 8/10 | 部分/全部失败仍落入成功完成态 |
| 系统垃圾/废纸篓 | 规则库、权限覆盖、分组选择、忽略、撤销 | 8/10 | 用户级路径删除仍有父目录 TOCTOU |
| 大文件/重复/相似图片 | 共享索引、哈希、Vision、结果选择 | 7/10 | 多数工具隐藏，发现性弱；内容读取文案错误 |
| 文件粉碎 | 多轮覆写、不可恢复说明、确认 | 5/10 | 取消或写入失败后仍可能 unlink；硬链接会连带损坏其他路径 |
| Space Lens | 环图、Treemap、搜索、下钻、收集篮、整篮恢复 | 9/10 | 批量失败项会从篮子消失；多盘并行不足 |
| 卸载器 | App 与关联文件、细选、移入废纸篓 | 5/10 | bundle ID 子串误匹配；执行失败被忽略 |
| 应用更新器 | Sparkle feed 枚举、版本检测、前往下载 | 4/10 | 网络/解析失败显示“全部最新”；自定义签名语义与 Sparkle 标准冲突；不校验最终 App 身份 |
| 优化 | 内存、运行应用、启动项、内存释放 | 6/10 | 忽略 terminate 返回值，可能虚报已退出 |
| 维护 | 用户级/特权任务、iCloud 驱逐、确认 | 7/10 | 批量失败仍累加完成并庆祝；helper 管道可死锁 |
| 磁盘测速 | 顺序/随机、取消、历史、规格映射 | 8/10 | 真机性能和卷异常矩阵仍需扩大 |
| 硬件与系统监视 | CPU/GPU/内存/磁盘/网络/传感器/进程/历史 | 8/10 | 重复采样引擎、私有 SPI、图表无障碍摘要不足 |
| 菜单栏 | 多指标、样式、顺序、刷新、告警、卡片、热键 | 9/10 | 状态项缺 accessibility label/value；高对比未覆盖 |
| 服务器 | SSH config、指纹信任、终端、SFTP、隧道、片段、告警 | 8/10 | 元数据完整性、退出隧道、远程永久删除确认 |
| 下载器 | URL、磁力、队列、暂停、隔离、浏览抓取、扩展 | 7/10 | 外部深链 SSRF、浏览器主动联网、组件信任回退、恢复能力不足 |
| 设置 | 许可、规则、忽略、外观、语言、主题、权限、诊断 | 7/10 | 主窗口单一长页，不符合高端 macOS Settings 工作流 |

## 4. 发布阻断与高严重度问题

### P0-1：粉碎器在取消/覆写失败后仍可能删除，且硬链接会连带损坏其他路径

证据：`Sources/Infrastructure/ShredderService.swift` 约 147–202 行。覆写函数没有向调用者返回成功/失败；取消、seek、write、sync 错误被 `return`/`try?` 吞掉，调用侧随后仍校验 inode、unlink 并计成功。`fstat` 后也没有检查 `st_nlink`：覆写任一硬链接等同于覆写该 inode 的全部链接路径。

影响：

- 用户点击取消仍可能永久失去原文件。
- 磁盘满或 I/O 错误时，文件并未完成承诺的覆写，但产品仍可能报告“已粉碎”。
- 用户只选中一个硬链接时，其他未选中的硬链接内容也会被不可恢复地覆写。
- 这是数据丢失与安全承诺同时失真，优先级高于任何 UI 改造。

修复验收：硬链接数大于 1 默认拒绝；每个 pass、`pwrite`、`fsync` 和取消都返回结构化结果；只有所有 pass 完成才允许 unlink；取消只在文件边界生效；I/O 中途失败时保留路径并诚实标记“内容可能已部分覆写”；增加取消、短写、`EINTR`、磁盘满、fsync 失败、inode 变化与硬链接测试。

### P0-2：卸载器可能把其他应用数据纳入默认删除

证据：`Sources/Infrastructure/UninstallerService.swift` 约 61–70、121–127 行使用长度最低仅 2 的 bundle ID token，并用 `lastPathComponent.contains(bundleID)` 匹配 Group Containers/LaunchAgents，结果默认勾选。

影响：畸形或恶意 App 使用 `com` 等弱 bundle ID 时，可能把大量不相关容器和启动项加入删除计划。

修复验收：bundle ID 必须是规范 reverse-DNS；容器使用精确路径组件或系统元数据；模糊证据默认不选；确认页逐路径展示归属依据；加入跨 App 冲突和恶意 bundle ID 测试。

### P0-3：任务结束被系统性伪装成任务成功

涉及：

- `SharedViews.swift`：通用完成页固定绿勾、粒子和成功播报。
- `ModuleSessionViewModel.swift`、`SmartScanHub.swift`：清理后无条件进入 finished。
- `UninstallerView.swift`：忽略 `report.failures` 并清空选择。
- `AppUpdaterView.swift`：空 updates 即显示“全部最新”。
- `OptimizationService.swift`/`OptimizationView.swift`：忽略 `terminate()` 结果并宣称退出 N 个 App。
- `MaintenanceView.swift`：批量任务无论 `ok` 都增加 done。
- `CollectionBasket.swift`：成功和失败后都清空全部项目。

影响：用户会基于错误的成功反馈做进一步删除、更新或性能决策，直接破坏高信任工具的可信度。

修复验收：引入统一 `OperationOutcome`（success/partial/failure/cancelled）；只有全成功才允许庆祝、成功音效、成功通知和历史统计；partial 必须保留失败上下文与重试；all-failed 不得写入成功历史。

### P0-4：隐私政策、onboarding 和真实数据流冲突

政策声称“不收集、不上传、许可完全离线、请求不含设备标识”；实际行为包括：

- `DeviceIdentity.swift` 读取持久 IOPlatformUUID。
- `LicenseActivationClient.swift` 上传激活码、deviceId、device label、licenseId。
- `AppModel.swift` 启动后每 15 天自动复验许可，并以定时器检查。
- `ProPricingClient.swift` 请求 pricing/geo。
- 网络监控会请求 Xico `/ip` 并连接 Cloudflare 测 RTT。
- 浏览器扩展拥有 `<all_urls>`、`all_frames` 和 `webRequest`，会在网页和 iframe 中捕获并暂存完整媒体 URL，其中可能包含临时令牌。

onboarding 还声称“不读取文件内容，只统计名称与大小”，但重复文件、相似图片和威胁扫描显然会读取本地内容；EULA 写 14 天试用而代码是 15 天，复验注释也同时存在 72 小时/3 天与真实 15 天两套口径。

影响：法律、商店披露、用户信任和企业采购审核风险。

修复验收：建立完整 data inventory；把“内容仅在本机处理”与“从不读取内容”区分；列出所有自动/手动联网、目的、字段、保留期和开关；首次使用给出网络控制；政策、EULA、定价页和产品内文案使用同一来源。

### P0-5：自更新签名发布链没有闭环

运行时把 `sparkle:edSignature` 解释为自定义 `version\nURL\nsha256` 描述符的 Ed25519 签名；标准 Sparkle 2 则用该字段签更新归档字节。发布脚本只可选调用 Sparkle `generate_appcast`，仓库 `sign_update.swift` 没有进入公证发布主链，因此标准工具生成的合法签名会被当前客户端按错误消息验签。设置页最终只是打开下载 URL，也没有对实际下载字节和 App 身份完成闭环验证。

影响：按当前标准发布流程生成的正常更新可能被客户端拒绝；人工绕过则削弱供应链保证。

修复验收：不再让同一个 `sparkle:edSignature` 承担两种消息语义；旧客户端使用独立 legacy feed 发布一次 bridge 版本，新版采用 Sparkle 2、`SUPublicEDKey`、`SPUStandardUpdaterController` 和标准 archive 签名；实际下载后验证归档签名、Developer ID、Team ID、bundle ID、版本和 Gatekeeper；缺任何密钥或 `generate_appcast` 时正式发布 fail closed。

### P0-6：下载组件在未配置签名目录时存在 fail-open 信任回退

签名组件 catalog 路径配置完整时设计较强；但未配置时，Release 路径可以从同一个 GitHub release 下载 yt-dlp 与 checksum，随后 chmod、清除 quarantine 并执行。同源 checksum 无法抵御 release 账户或产物整体被替换；Release 构造路径还未从类型层禁止 `file://` catalog。

修复验收：生产只接受 HTTPS、内嵌独立公钥签名的 catalog；同源 checksum 与 `file://` 回退仅允许显式 DEBUG；安装使用 staging、fsync、原子替换和签名 receipt；任何签名、大小、Mach-O、架构、版本或执行前 hash 不一致都保留 quarantine 并拒绝执行。

### P0-7：外部 `xico://download` 可触发任意 HTTP(S) 与私网目标

任何网页或 App 可发送 `xico://download?url=...`；当前只做约 0.8 秒节流，无来源认证或用户确认。`DownloadManager` 接受任意 HTTP/HTTPS host，未阻止 loopback、RFC1918、link-local，图片模式会立即抓取网页并批量下载。

影响：盲 SSRF、本机/内网 GET 副作用、自动网络和磁盘消耗；由于应用无 sandbox，影响面更大。

修复验收：外部 scheme 只能创建 `PendingDownloadIntent`，确认前网络、磁盘和子进程副作用必须为零；扩展使用 fixed-extension-ID native messaging 或带时效的一次性 nonce；解析 DNS 后阻止私网/loopback/link-local/CGNAT/ULA/混合公私结果，重定向每跳复检；外部来源只允许 HTTPS；对数量、大小、并发和频率做全局预算。

### P0-8：SSH 主机信任元数据与 Keychain 凭据没有完整性绑定

`ServerHostStore.swift` 把 host UUID、hostname、pinnedHostKeys 存在普通 JSON；连接时按 UUID 从 Keychain 取密码并信任 JSON 中的 endpoint/pin。同用户恶意进程可保留 UUID 和显示名、替换地址与指纹，诱导 Xico 把保存密码发往攻击者。

修复验收：Keychain 保存完整 `SecureHostBinding`，把规范化 endpoint、用户名、端口、auth kind、credential reference、jump host 和 pinned keys 绑定在同一权威记录中；普通 JSON 只保存展示元数据；任何不一致必须阻止读取凭据和联网，并要求重新核对 endpoint/指纹，不能只依赖熟悉的显示名。

### P0-9：远程不可恢复删除缺少危险确认

SFTP 文件/目录删除、服务器配置和隧道删除都可直接执行；远程文件不可通过本机废纸篓撤销。主机删除还会先删除 Keychain 再异步写普通 JSON，写盘失败可能形成“主机仍在、凭据已丢”；自定义/共享 `privateKeyRef` 的清理也没有正确生命周期。活动隧道只发停止请求，没有等待底层进程真正退出。

修复验收：确认页显示主机、绝对路径、对象类型和不可撤销性；SFTP 列表与删除间复核远端 inode/dev/type/mtime，并继续禁止递归目录删除；主机配置使用 throwing/transactional 原子存储，持久化成功后才清理 Keychain；共享 key ref 引用计数；隧道必须 `stopAndWait`；批量操作返回逐项 outcome。

## 5. 中高优先级安全、可靠性与发布问题

| ID | 严重度 | 问题 | 影响与建议 |
|---|---|---|---|
| S-10 | Medium-High | 用户级路径删除存在父目录 TOCTOU | 复校后仍用路径 API 删除；在 FDA/无 sandbox 下应复用 helper 的 fd/openat/O_NOFOLLOW 设计 |
| S-11 | Medium | helper 先 `waitUntilExit` 再读 stdout/stderr | 输出超过 pipe 容量可能死锁；需并发排空或 readability handler |
| S-12 | Medium | 退出应用不调用 `TunnelManager.stopAll()` | SSH `-N` 子进程、端口和临时密钥材料可能残留；退出需同步回收 |
| S-13 | Medium | definitions 下载完整缓冲且无体积上限 | 服务异常可造成内存压力；检查 Content-Length、流式累计和解码预算 |
| S-14 | Medium | 文件路径以 `.public` 写 OSLog 并原样导出 | 用户名、项目名、文档名可能泄露；默认 private/hash/basename，导出前预览 |
| S-15 | Medium | 激活、更新、购买 endpoint 未统一强制 HTTPS | Release 运行时与预检都应拒绝非 HTTPS；仅 DEBUG 允许 localhost |
| S-16 | Medium | browser extension 拥有 `<all_urls>`、all frames | 改为用户触发的 optional host permission/active tab，明确 URL 暂存与清除规则 |
| S-17 | Medium | browser extension 暂存完整媒体 URL | 签名 URL/token 查询参数可能敏感；最小化、短时、脱敏并按 tab 关闭清理 |
| S-18 | Medium | `build.env` key 被插入 `eval` | 污染配置可在签名机执行 shell；移除 eval 并校验标识符 |
| S-19 | Medium | release 默认取最近 tag，不要求 HEAD exact-tag | tag 后代码可能以旧版本号发布；release 模式必须 exact tag 或显式 CI 版本 |
| S-20 | Medium | 旧部署脚本硬编码 ID、路径、服务器、版本 | 可能上传旧 DMG；删除/隔离或参数化，只保留一个发布入口 |
| S-21 | Medium | 本机已安装 App 严格签名失败 | 当前产物不可作为发布证据；干净重建并验证 app/helper/entitlements/notarization |

没有发现源码中提交的真实生产密钥；静态规则只命中测试中的 PEM header。没有发现生产 `fatalError`、`try!`、`as!`。这两个正面结论不等于应用没有错误传播问题：全仓约 221 处 `try?`，其中一部分会吞掉真实业务失败。

## 6. 架构与可维护性

### 6.1 模块边界

SwiftPM target 拆分是正面基础，但 `Infrastructure` 反向依赖 `DesignSystem`，至少 17 个网络、许可、SSH、扫描和下载文件直接引用 UI/本地化层。建议把本地化 key/业务错误放入 Shared/Domain，由 Features/DesignSystem 决定呈现。

### 6.2 全局状态与依赖注入

- `AppModel` 超过 1,100 行并承担许可、导航、指标、菜单、扫描、pricing 等多类责任。
- `AppModel` 部分服务硬编码创建，注入不完整。
- `MonitorView` 直接读取 `AppModel.shared`，破坏测试和离屏渲染隔离。
- `MetricsEngine` 与 AppModel 菜单循环可能同时采样 CPU/网络/GPU/进程。

目标架构应是一套 demand-driven sampling graph：消费者声明所需指标和频率，中央 coordinator 合并需求、共享缓存、保证 single-flight，并输出带新鲜度/覆盖率的 snapshot。

### 6.3 巨型文件热点

| 文件 | 行数 | 建议边界 |
|---|---:|---|
| `Features/MenuPanels.swift` | 1,287 | 按 CPU/Memory/Network/Disk/Temperature/GPU 面板拆分 |
| `Infrastructure/Scanners.swift` | 1,245 | 按 scanner/collection/policy/report 拆分 |
| `Features/SmartScanHub.swift` | 1,182 | state machine、orchestrator、review、result UI 分离 |
| `Features/AppModel.swift` | 1,107 | license/navigation/metrics/lifecycle coordinators |
| `Features/HardwareView.swift` | 1,078 | overview/sensors/storage/battery/network sections |

### 6.4 第二事实源

根目录忽略的 `XicoClean/` 是独立旧 clone。107 个同路径源码中 96 个已与根项目不同，根项目另多 68 个源码文件。它不参与根 Package 构建，但会让搜索、AI 编辑、人工审计和发布操作落入错误仓库。应移出工作区或归档为不可编辑快照，并在工具配置中排除。

## 7. 产品与 UX 审计

### 7.1 产品定位

Xico 的真实优势不是“另一个清理器”，而是：

- 本地优先、证据驱动、默认可撤销的清理。
- Space Lens 与整篮恢复。
- 接近 iStat 级的菜单栏监控。
- 同一产品内的硬件、SSH/SFTP/隧道和下载器。

问题是这些能力目前没有被一个清晰的产品结构承接。建议采用“Mac Command Center”定位，但保持三层优先级：

1. Health & Care：智能扫描、清理、优化、维护、安全。
2. Space & Apps：Space Lens、大文件、重复、相似、卸载、更新。
3. Pro Tools：监控、硬件、服务器、下载器；可按用户角色隐藏或固定。

### 7.2 信息架构与发现性

Space Lens 被放在 Applications；废纸篓、大文件、重复、相似、粉碎和威胁多数隐藏，只能从智能扫描或深链进入。命令面板也主要收录可见模块。

建议：

- 增加“全部工具”，支持搜索、收藏、最近使用、角色化推荐。
- `⌘K` 同时搜索页面、工具、主机、设置和上下文动作。
- Smart Scan 保持首页，但不垄断独立工具发现入口。
- 隐藏高级工具由用户固定到侧边栏，默认 IA 保持克制。

### 7.3 macOS 原生工作流

- 使用独立 SwiftUI `Settings` scene，分 General、Cleaning、Appearance、Monitoring、Privacy & Permissions、License/About。
- 保持一个主窗口，同时允许 Server Terminal/SFTP、Monitor 和 Space Lens 在新窗口打开。
- 恢复窗口尺寸、位置、最近 pane 和最近任务。
- 统一 `⌘,`、`⌘F`、Esc、Return、Delete、Reveal in Finder 和 App menu commands。
- 主窗口关闭、仅菜单栏存活时，设置、扫描和监视命令必须可靠重开正确窗口。

### 7.4 升级器、威胁防护与承诺边界

当前 App Updater 只覆盖可解析 Sparkle feed，并打开下载 URL；它不是完整安装器。ThreatScanner 主要检测 launchd plist 特征和启发式风险，不是通用恶意软件扫描或实时防护。

产品文案应在能力升级前诚实命名：

- “应用更新检查”而不是“自动更新所有应用”。
- “启动项风险检查”而不是泛化“威胁防护”。
- 只有在具备安全数据库、样本/规则更新、隔离、实时监控和误报申诉闭环后，才能对标 CleanMyMac 的 malware protection。

## 8. UI、视觉与动效审计

### 8.1 已经做得好的部分

- 暗色背景、卡片高程、品牌环、图表色阶和服务器信任界面已经成熟。
- 8 套主题不是单纯换 accent，能贯穿环形图、图表、菜单栏和背景。
- 材质主要用于导航/浮层，没有无差别把内容全部玻璃化。
- Smart Scan、Space Lens、菜单栏和服务器信任具有清晰的品牌辨识度。
- 多处已经正确响应 Reduce Transparency/Reduce Motion，说明设计系统具备扩展基础。

### 8.2 当前视觉问题

- 浅色模式过白、过雾：canvas、surface、shadow、border 的明度差太小。
- 大窗口空态留白过多，像营销海报而不是可工作的桌面工具。
- 状态色语义不纯：失败和 partial 也能进入绿色庆祝页。
- Smart Scan 在磁盘 87–94%、内存 80%+ 时仍可能说“运行顺畅”，文案和数据冲突。
- Theme/Downloader/System Junk 浅色表面层次最弱；Menu Bar Settings 控件密度和微型箭头过高。

### 8.3 建议的视觉提升原则

不是“更多特效”，而是“更高信息密度下仍然安静、准确、精致”：

- 浅色 canvas 与 card 拉开约 2–4% 明度差，减少大范围 diffuse shadow，增加克制的 1px 实体边界。
- 主操作之外降低彩色辉光；语义色只对应真实状态。
- 空态加入最近任务、可信统计、下一步和快捷键，不用装饰填空。
- outcome 系统使用 Success/Partial/Failure/Cancelled 四种构图、文案、色彩和动作层级。
- 高价值数据采用更紧凑的 typographic hierarchy，减少重复标题和解释。
- Theme 选择除色相外，同时使用名称、check、边框、selected trait 和图案差异。

### 8.4 动效预算

应保留：

- 扫描环与确定性进度。
- 真实全成功后的一次性短 burst。
- Space Lens 有空间连续性的层级变换。
- 实时采样 live dot。
- 低频、可读的数字变化。

应降级或移除：

- 侧边栏每次切换 bounce。
- 大量 hover lift/scale 与 Theme 1.04 放大。
- Reduce Motion 开启后仍缩放的按钮按压反馈。
- 状态结束后仍存活的 repeatForever。
- partial/failure 的粒子、成功音效和触感。

确认的动效/重绘问题：

- `AppBackground` 在 Smart Scan finished 后可能因 animated 标志长期保持而以 TimelineView 约 20fps 重绘。
- 下载器不定进度、Treemap、Root transitions、Theme hover、通用按钮和 Smart Scan 呼吸动画的 Reduce Motion 覆盖不完整。
- `XRingGauge` 在系统运行时切换 Reduce Motion 后，既有 repeatForever 是否停止需要实测并显式复位。

## 9. 无障碍、本地化与自适应

### 9.1 VoiceOver 与键盘

高优先缺口：

- AppKit 状态项没有 tooltip、accessibility label/value/help。
- 自绘 `NSImage` 没有 accessibility description。
- 下载任务、内置浏览器后退/前进/刷新按钮只有视觉图标或 help。
- 命令面板行使用 `onTapGesture` 而不是语义 Button。
- 主机图标/颜色选择器没有 selected trait，且依赖颜色。
- `XLineChart` 没有强制 label/value/trend/peak 的无障碍 API。
- SFTP、隧道等危险按钮需要键盘焦点、确认和可读名称。

全仓几乎没有系统性的 `accessibilityContrast` 或 `accessibilityDifferentiateWithoutColor` 适配。应建立 Accessibility Inspector 验收，而不是只靠静态 modifier 数量。

### 9.2 11 语言质量

键集合 parity 是正面基础，但不是翻译完成：日语/韩语/俄语等服务器和下载器区有大块英语回退。与英语完全相同的非专名条目约为：de 219、es 214、fr 223、it 213、ja 182、ko 182、pt-BR 220、ru 184。

9 个 locale 使用 `\u201c` 形式；Apple `.strings` 会把它解析成字面 `u201c`，例如 UI 可能显示 `Click u201cConnectu201d...`。

质量门目前只证明 plist 语法和 key parity。应新增：

- 全目录 printf placeholder parity。
- 非英语 locale 英文回退白名单。
- 中文/英文意外泄漏检测。
- 非法 Unicode escape 检测。
- de/fr/ru/pt-BR 长文案和 ja/ko 新模块截图矩阵。
- 1080×640、1280×800、1440×900 与 100/135/200% 字号组合。

## 10. 与 2026 同类产品的真实差距

### CleanMyMac

Xico 已有优势：更强菜单栏监控、硬件/服务器/下载能力、Space Lens 可撤销篮、本地优先和买断叙事。

仍落后的关键能力：

- 成熟 Safety Database、长期误删治理和品牌信任记录。
- 真正 malware scanner 与 real-time monitor。
- Cloud Cleanup。
- App Permissions 管理。
- 能完成安装/身份校验的应用更新器。
- My Tools 的搜索、收藏和独立工具发现性。
- Health activity、解释和长期建议。
- 12 语言的母语质量与发布一致性。

参考：

- [CleanMyMac Smart Care](https://macpaw.com/support/cleanmymac/knowledgebase/smart-care)
- [CleanMyMac Safety](https://macpaw.com/support/cleanmymac/knowledgebase/cleanmymac-safety)
- [CleanMyMac My Tools](https://macpaw.com/support/cleanmymac/knowledgebase/my-tools)
- [CleanMyMac Cloud Cleanup](https://macpaw.com/support/cleanmymac/knowledgebase/cloud-cleanup-start)
- [CleanMyMac Mac Health](https://macpaw.com/support/cleanmymac/knowledgebase/mac-health)

### iStat Menus、DaisyDisk、Downie

- iStat Menus 仍领先于长历史、组合项、告警成熟度、本地化和状态项可访问性。
- DaisyDisk 仍领先于多磁盘并行和极成熟的空间探索；Xico 的恢复能力是差异点。
- Downie 仍领先于浏览器扩展、登录浏览器、拖放/多 URL、历史和失败恢复；Xico 的统一队列和隔离状态是基础。

“比 CleanMyMac 更好”应被定义为可验证指标，而不是审美口号：

- 删除误报率和不可恢复误删为零。
- partial/failure 结果 100% 诚实呈现。
- 核心任务到达时间、撤销成功率和权限解释优于对手。
- 标准菜单栏 CPU < 0.5%、footprint < 80 MB。
- VoiceOver、Reduce Motion、高对比和 11 语言全部通过矩阵。
- 发布产物签名、公证、更新验证和隐私数据流可被独立复核。

## 11. 推荐路线图

### Phase 0：可信发布基线

1. 建立统一 `OperationOutcome` reducer：每个请求项只能有一个 disposition，业务页面不能自行声明成功。
2. 危险操作采用不可变计划、短期确认授权、执行前身份复核和结构化结果四层边界。
3. 修复粉碎器精确写入/同步、文件边界取消和硬链接拒绝；重建卸载器精确归属与不可取消的 App 本体。
4. 建立 TrustCore，关闭深链 SSRF、组件信任回退和 SSH 元数据/凭据解绑。
5. 用 legacy bridge 隔离旧自定义更新协议，新版迁移到标准 Sparkle 2 归档签名与安装闭环。
6. 建立隐私 data inventory，重写 onboarding、EULA、浏览器扩展披露和联网控制。
7. SFTP、主机和隧道加入危险确认、远端身份复核、事务持久化与 `stopAndWait`。
8. 收敛为唯一发布入口：quality gate、release preflight、exact tag、最终 App/DMG 签名、公证、回源 hash 与 update E2E 全部硬失败。

### Phase 1：产品架构与核心工作流

1. 重构 Smart Care/Space & Apps/Pro Tools IA。
2. 增加 All Tools、收藏、最近使用与全局 `⌘K`。
3. 独立 Settings scene 与专业多窗口工作流。
4. 把 App Updater 与 Threat Protection 的能力/文案边界做实。
5. 合并采样引擎，拆分 AppModel 和五个巨型文件。

### Phase 2：视觉、动效与无障碍飞跃

1. 重标定浅色 surface/canvas/border/shadow。
2. 设计 success/partial/failure/cancelled 完整状态系统。
3. 缩减海报式空态，提升桌面工具的信息密度。
4. 建立统一 motion tokens、生命周期和 Reduce Motion 静态替代。
5. 完成菜单栏、图表、命令面板、下载器、服务器的 VoiceOver/键盘闭环。
6. 完成 11 语言母语质量和窗口/字号矩阵。

### Phase 3：差异化能力

1. Health timeline：解释变化、提供可验证建议，不做恐吓式评分。
2. 多盘并行 Space Lens 与跨卷对比。
3. 可安装、可验证、可回滚的应用更新。
4. Native Messaging 下载扩展、历史和登录浏览器工作流。
5. 角色化工作区：Care、Creator、Developer/Operator。

## 12. 验收矩阵

发布前必须覆盖以下状态，而不是只截 idle 与 success：

- Smart Scan：active、单类失败、partial、all-failed、cancel、undo partial failure。
- Uninstaller：关联文件 loading/error、部分失败、全部失败、恶意 bundle ID。
- App Updater：全网断开、部分 feed 不可验证、不安全 feed、版本预发布。
- Space Lens：扫描取消、篮子部分失败、重试、撤销失败、快照错误。
- Shredder：取消前/覆写中取消、短写、`EINTR`、磁盘满、fsync 失败、inode 变化、硬链接、部分覆写失败。
- Downloader：外部深链确认前零副作用；组件签名失败、缺生产 catalog、私网/loopback/CGNAT/ULA、混合 DNS、DNS rebinding、逐跳重定向与预算。
- Servers：首次指纹、指纹变化、JSON endpoint/username/port/pin/ref/jump 篡改、SecureHostBinding 迁移、远端身份复核、删除确认、共享 key ref、退出隧道回收。
- Settings/Menu Bar：主窗口关闭后重开、浅/深壁纸、VoiceOver、刘海省宽。
- Accessibility：Reduce Motion、Reduce Transparency、Increase Contrast、Differentiate Without Color、Full Keyboard Access、200% 字号。
- Locales：zh-Hans、zh-Hant、en、ja、ko、de、fr、es、ru、pt-BR、it。
- Window：1080×640、1280×800、1440×900、多显示器、窗口恢复。
- Release：clean checkout、exact signed tag、universal、inside-out codesign、nested helper、Team ID/bundle ID/entitlements、spctl、stapler、notary log、Sparkle N-1→N、篡改 archive、线上回源 hash 与 appcast 最后发布。

## 13. 审计限制与结论置信度

高置信/已确认结论来自当前源码控制流、当前 HEAD 构建、当前测试、当前离屏截图和项目脚本。没有执行破坏性 TOCTOU PoC、真实恶意网络目标、生产付款、真实公证发布或物理 SSD 安全擦除实验。

因此：

- 本报告可以证明当前产品有明确发布阻断和升级方向。
- 本报告不能证明尚未运行的高负载、能耗、签名、公证、Intel 和真实权限矩阵已经合格。
- 任何旧版“94/100”“全部安全”或“已经超越 CleanMyMac”的结论，均不能覆盖本次当前 HEAD 证据。

最终判断：**Xico 具备成为一流 Mac Command Center 的产品基础，但当前真实评分是 72/100。先把可信度和发布链做到行业顶级，再做信息架构与视觉动效升级，才有机会在用户体验上真正超过 CleanMyMac。**
