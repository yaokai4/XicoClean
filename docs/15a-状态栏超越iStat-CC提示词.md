> 用途：把本文件全文粘贴给一个新的 Claude Code 会话即可开始实施。配套总方案见 [`docs/15`](15-全面超越竞品-飞跃升级总方案-2026-07.md)。

# Xico 状态栏「飞跃式超越 iStat Menus」实施任务

**一句话目标**：把 Xico 菜单栏系统监控从「能看」升级到「同级 + 独占空档」——先修断裂（主题联动死代码、网络样式等价、口径不准），再补同级能力（多传感器、告警、交互），最后接通三合一独有杀手锏（空间透镜深链、清理闭环、AI 解读）。

## 现有架构约束与不可破坏的红线（动手前必读）

- **菜单栏字形是 CoreGraphics 直绘 + 缓存**：`Sources/Features/MenuBarGlyph.swift`。所有字形走 `compose([Elem], GlyphPalette)`，宽度先量后画，18pt 高度内垂直居中。**任何新样式必须复用 `Elem`/`compose` 管线，不得引入 SwiftUI/ImageRenderer 渲染**（性能红线，菜单栏每秒重绘）。
- **模板图深浅自适应是默认地基**：`palette(colored:tint:)`（`MenuBarGlyph.swift` 约 :262）在 `colored=false` 时返回 `template: true` 的纯黑模板图，由系统 vibrancy 在深/浅栏自动黑白反色。**彩色（colored）永远是 opt-in，模板单色是默认**，不得反过来。数学事实：纯色数字无法在浅栏+深栏同时达 WCAG 文本 4.5:1，所以彩色只锚定「图形 3:1」阈值，且每指标必须「色相+图标+数字」三重编码（HIG 别只靠颜色）。
- **缓存签名**：字形由 `signature(...)` + `cachedImage(id:signature:)` 缓存。**任何影响外观的新入参（新样式、新 tint、传感器选择）都必须并入 signature**，否则切换后图标不刷新（这是最容易踩的坑）。
- **主题 token 单一取色入口**：颜色只从 `Sources/DesignSystem/Tokens.swift` 的 `XColor` 门面取，主题定义只在 `Sources/DesignSystem/Theme.swift`。**禁止在 MenuBarGlyph 里新硬编码 hex**——要新增指标色就走 `XColor.menuXxx` 门面。
- **与 SafetyEngine 无关**，但菜单栏采样跑在主线程定时器（`Sources/Features/AppModel.swift` `startMetricsTimer`）→ **任何新增采样（传感器/FPS/蓝牙电量）都要评估主线程成本，能懒采样/按需采样就别塞进 2s 全量循环**。
- **验证方式**：本项目支持 `--shots`（可带 `--lang=` 出图）与预览。每阶段结束用 `--shots` 出菜单栏相关截图自查。**只改 `Sources/` 真源，忽略 `XicoClean/` 与 `.claude/worktrees/` 副本**。

---

## P0（立即，多为 bug 修正，先做这一阶段然后停下等我确认）

### 改动点

1. **主题联动死代码修复** — `Sources/XicoApp/MenuBarController.swift` 的 `colored(for id:)`（约 :179）当前只读 `xico.mb.<id>.colored` / 全局 `xico.mb.colored`，**从不读主题的 `menuBarColored`**。改为：逐项开关 > 全局开关 > **兜底读 `XThemeStore.shared.current.menuBarColored`**。这样切到 ocean/sunset/magenta 等 `menuBarColored: true` 的主题，菜单栏彩色身份才真正贯通。
   - 陷阱：兜底值要参与 `image(for:)` 的缓存 signature（`colored` 已是 `network/disk/...` 入参，确认切主题会触发重绘——若不重绘，需在主题切换处 invalidate 菜单栏图标缓存或触发 `updateImages`）。

2. **menuGPU / menuDisk 结构补丁（6 行）+ 两套暖主题落地** — 目的：破除 `MenuBarGlyph.disk`/`gpu` 的硬编码 tint，让主题能定制这两个指标的菜单栏色。
   - `Theme.swift`：`XTheme` 加两个可选字段 `menuGPU: Color?` / `menuDisk: Color?`（`init` 默认 `nil` = 回退旧行为，**旧六套主题零改动**）。
   - `Tokens.swift`：加门面（与 `metricCPU` 等并列，读 `XThemeStore.shared.current`）：
     ```swift
     public static var menuGPU:  Color { XThemeStore.shared.current.menuGPU  ?? accentPink }  // 回退旧粉
     public static var menuDisk: Color { XThemeStore.shared.current.menuDisk ?? warning }     // 回退旧橙
     ```
   - `MenuBarGlyph.swift`：`disk(...)` 里 `tint: [XColor.warning]` → `tint: [XColor.menuDisk]`；`gpu(...)` 里 `tint: [XColor.accentPink]` → `tint: [XColor.menuGPU]`。
   - `Theme.swift` 追加两套主题并注册进 `all`（放在 graphite 后）：
     ```swift
     public static let warmLuxe = XTheme(
         id: "warmLuxe", name: "暖阳高级",
         gradient: [XColor.dyn(0xC77D2A, 0xF2B24E), XColor.dyn(0xC85A54, 0xF0897E), XColor.dyn(0x8C5698, 0xC493DE)],
         ring: [XColor.dyn(0xB43F73, 0xEC8FB6),   // ring0 磁盘·上行 莓玫
                XColor.dyn(0xC24E3A, 0xF08A6E),   // ring1 内存 赤陶
                XColor.dyn(0xAE7016, 0xF4B54C),   // ring2 CPU 蜜琥珀
                XColor.dyn(0x1E8F7E, 0x63D6BE)],  // ring3 网络 青碧
         accent: XColor.dyn(0xC96B34, 0xF2A557), menuBarColored: true,
         menuGPU:  XColor.dyn(0x9A5BB8, 0xC79AE8),   // 菜单栏 GPU 兰紫
         menuDisk: XColor.dyn(0xB43F73, 0xEC8FB6))   // 菜单栏 磁盘 莓玫

     public static let jewel = XTheme(
         id: "jewel", name: "珠宝暖调",
         gradient: [XColor.dyn(0xA8264C, 0xE86A88), XColor.dyn(0x7A3EA8, 0xB98AE6), XColor.dyn(0xC98A1E, 0xF0C05A)],
         ring: [XColor.dyn(0x2A5AC8, 0x7FA6F5),   // ring0 磁盘·上行 蓝宝石
                XColor.dyn(0xB2214C, 0xF0708E),   // ring1 内存 石榴红
                XColor.dyn(0xA6760F, 0xF2C24E),   // ring2 CPU 黄玉
                XColor.dyn(0x0E9260, 0x5CE0A0)],  // ring3 网络 祖母绿
         accent: XColor.dyn(0xA8264C, 0xE86A88), menuBarColored: true,
         menuGPU:  XColor.dyn(0x7A3EA8, 0xC79AEE),   // 紫水晶
         menuDisk: XColor.dyn(0x2A5AC8, 0x7FA6F5))   // 蓝宝石
     ```
   - 关键前提（不要改）：CPU/内存/网络已走 `metricCPU/Memory/Network` = `ring(2)/ring(1)/ring(3)`。上面两套的 ring 顺序**特意排成 ring2=CPU、ring1=内存、ring3=网络**，故这三指标无需改代码即命中目标色相。别去动 `metricCPU` 等定义。
   - 诚实账本（写进 commit note，别当 bug 修）：面板 GPU 走 `metricGPU=[ring1,ring2]`，与菜单栏专属 `menuGPU` 紫不完全一致——这是「5 指标挤 4 槽 ring」的历史派生，aurora 等旧主题同样如此，面板靠位置+标题+图标区分足够，本次不重构。

3. **网络 3 样式差异化** — `MenuBarGlyph.network(...)`（约 :125）当前除 `.graph` 加 sparkline 外，`iconValue`/`valueOnly`/`rich` 全部只渲染 `netRows`（双行速率），三者等价，但设置里给了 4 个磁贴 → 名不副实。按样式分支：
   - `iconValue`：加 `↑↓` 方向 SF 符号（`arrow.up`/`arrow.down` 或 `arrow.up.arrow.down`）+ 紧凑单行速率。
   - `valueOnly`：纯双行 `netRows`（保持现状）。
   - `rich`：双向迷你面积双线（上行/下行分色，复用 sparkline/面积元素，上行用 tint[0]、下行 tint[1]，或按 metricNetwork 两色）。
   - `graph`：维持 sparkline + netRows。
   - 陷阱：新分支产出必须并入 `signature`（`style` 已是入参，但如果 `rich` 需要 up/down 两条 history，要确认历史数据源够用；不够就先用现有单 history 双色近似，别为此改采样频率）。

4. **runloop 改 `.common`** — `AppModel.startMetricsTimer` 用 `Timer.scheduledTimer`（默认 `.default` mode）→ 菜单跟踪/窗口缩放时图标暂停刷新。改为手动 `Timer(timeInterval:...)` + `RunLoop.main.add(timer, forMode: .common)`（in-app 引擎已用 `.common`，对齐即可）。一行级改动，注意 invalidate 旧 timer。

5. **换入/换出改差分速率** — `Sources/Features/MenuPanels.swift`（约 :404）内存面板现显示 `s.pageIns.formattedBytes` / `s.pageOuts.formattedBytes`（**自开机累计字节**，参考意义弱）。改为 Δ/dt 速率（`pageIns`/`pageOuts` 已在 snapshot，用上一帧差值 ÷ 采样间隔，显示为 `.../s`）。若 AppModel 未存上一帧 page 计数，补一个 `lastPageIns/Outs` 缓存字段，在 refresh 时算差分。陷阱：首帧无前值时显示「—」，别显示爆表值。

### P0 验收标准（用 --shots 自查）

- 切到 ocean/sunset/warmLuxe/jewel 主题，**不手动开全局彩色开关**，菜单栏图标即呈现该主题彩色（当前是死代码，切了仍单色）；切回 aurora/graphite（`menuBarColored:false`）恢复单色模板。
- warmLuxe/jewel 出现在主题选择器；菜单栏磁盘=莓玫/蓝宝石、GPU=兰紫/紫水晶，五指标互不撞色；深浅栏各出一张对比图，彩色版图形对比度肉眼清晰。
- 网络四样式截图两两可辨：iconValue 有方向箭头、rich 是双色面积、graph 有 sparkline、valueOnly 纯双行。
- 内存面板「换入/换出」显示为速率（带 /s），静置时趋近 0 而非固定大数。
- 拖动窗口/展开菜单时菜单栏数字仍在跳（runloop 生效）。
- 旧六套主题外观零回归（回退分支生效）。

**⏸ 做完 P0 后停下，把 --shots 截图与改动清单发我确认，再进 P1。**

---

## P1（本迭代，补齐到「监控同级」——确认后再做）

### 改动点

- **温度多传感器多入口** — 破 `MenuBarController.swift`（约 :203）`temperature(celsius: s?.cpuTemp)` 的硬编码。加「传感器选择器」：温度项可选 CPU/GPU/SSD/电池/任意命名传感器（`Sources/Infrastructure/SensorReader.swift` 已枚举全部），每传感器可作独立状态项。选择存 `xico.mb.temp.<slot>.sensor`，并入 signature。成本红线：按选中项懒读，别把全部传感器塞进 2s 全量采样。
- **轻量 Rules 告警引擎** — 新增 `Sources/Features/MenuBarAlerts.swift`：CPU>90% 持续 N 秒 / 磁盘剩余<10GB / 温度>85° / 断网 → `UNUserNotificationCenter` 系统通知。带滞后与去抖（别刷屏），阈值可配。这是 iStat 对所有对手的决定性优势，必须补。
- **hover 预览 + 全局快捷键** — `MenuBarController` 的 `handleClick`（约 :262）现仅点击。加 `NSTrackingArea` hover 预览浮窗；全局快捷键唤出（自绘或轻量快捷键库，先做能力开关，默认关）。
- **磁盘卷选择器 + 活动/占用分离** — `Sources/Infrastructure/LiveMetrics.swift`（约 :118/:138）现仅 home 卷却泛标「磁盘占用」。加卷选择器；「活动(读写速率)」与「占用(百分比)」拆成两种可独立添加的项。
- **电池剩余时间** — `LiveMetrics` 补 `IOPSGetTimeRemainingEstimate`，`MenuBarGlyph.battery` 增可选「剩余时间」显示。
- **独立刷新率真驱动** — 现 `startMetricsTimer` 单一 2s 源，逐项设 1s 无实际提速。让采样器支持按项最小间隔驱动（高频项走更短 tick，低频项抽帧）。注意主线程成本，别所有项都拉到 1s。
- **透明栏(Liquid Glass)图形垫底可选** — `palette`/compose 层给彩色模式加可选半透明胶囊底（应对壁纸透栏彩色图对比不足），模板图保持默认无底。
- **新样式 loadAvg / stacked / interface / wifiName** — 扩 `MenuBarStyle` 枚举：`loadAvg`（CPU 项显示 `1.2 1.0 0.9`，数据在 `LiveMetrics` load1/5/15）；`stacked`（两行「CPU 23% / MEM 61%」，刘海省宽）；`interface`/`wifiName`（`CWWifiClient.interface().ssid()`）。每个都要 `title`/`shortTitle` 本地化 + 并入 signature + 在 `MenuBarSettingsView` 可视化选择器可选。
- **一键场景预设** — 扩 `Sources/Features/MenuBarSettingsView.swift` 现有「极简/性能/全景」，加「游戏/续航/开发者」整套配置一键切换。

### P1 验收标准

- 温度项能加多个（CPU+GPU+SSD 各一项），各显对应读数，非全是 CPU 温度。
- 人为触发（占满磁盘测试卷/跑高负载）能收到系统通知，且不刷屏。
- hover 菜单栏项弹预览；快捷键能唤出（开启后）。
- 磁盘可切外置卷；「活动」与「占用」两项并存显示不同数值。
- 电池项显示剩余时间；`--shots` 出 loadAvg/stacked/interface/wifiName 四新样式截图各自可辨。
- 切「游戏/续航/开发者」预设，菜单栏整套项与样式随之切换。

**⏸ P1 做完同样停下发我确认，再进 P2。**

---

## P2（远期杀手锏 + 追平信息中枢——确认后再做）

### 改动点

- **面板深链空间透镜 / 清理闭环（独占空档）** — `MenuPanels.swift` 磁盘/内存面板底部加「深潜空间透镜」「一键清理」入口，deep-link 打开 `Sources/Features/SpaceLensView.swift`(旭日环 `SunburstView`) 与 `SmartScanHub`。菜单栏从「看数字」升级为「看→点→清」。iStat 结构性无法跟进。
- **AI 健康解读 / 异常归因** — 新增 `Sources/Features/MenuInsight.swift`：基于 `ProcessSampler` 排序 + 阈值规则生成轻量洞察（「内存压力偏高，Chrome 占 4.2GB→建议清理」「磁盘剩 8GB→打开透镜」）。非重 LLM。
- **组合项智能布局（刘海感知）+ symbol 槽** — 给 `MenuCombinedSlot.Viz`（`MenuBarGlyph.swift` 约 :44）补 `.symbol` 前缀槽；检测屏宽/刘海，窄屏自动折叠 stacked/单合并项，宽屏展开。
- **GPU FPS / 每核阵样式 / 逐核 P/E 分色** — `fps`（IOKit `IOAccelerator` 帧计数或 CVDisplayLink 差分，做游戏场景卖点）、`coreGrid`（每核迷你环，P/E 核分色，可从 `MenuPanels` CPU 面板每核环下放）。
- **蓝牙外设电量 / VPN 流量开关 / 世界时钟·天气** — `IOBluetooth` 读 AirPods/妙控电量；`LiveMetrics.swift`（约 :394）utun 隧道流量加「计入」开关；时钟/天气排最末（非 Xico 卖点，仅补信息中枢完整度）。

### P2 验收标准

- 菜单栏磁盘/内存面板可一键跳进旭日环与清理中枢，闭环走通。
- 洞察条能对高占用进程给出可执行建议。
- 窄屏(刘海)与宽屏下组合项布局自动不同；组合槽带 symbol 图标。
- FPS/coreGrid 样式出图，逐核 P/E 分色可辨。

---

## 协作节奏（务必遵守）

**先只做 P0，跑 `--shots` 出图后停下，把改动清单 + 深浅栏截图发我确认。** 我确认后你再进 P1，P1 完再停、再确认、再进 P2。每阶段都以可见的 `--shots`/预览结果为验收，不要一口气做完三阶段。任何触碰模板图深浅自适应、CG 直绘管线、缓存 signature 的改动，若有取舍先问我再动。
