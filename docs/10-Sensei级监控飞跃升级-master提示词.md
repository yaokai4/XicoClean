# Xico · Sensei / iStat 级飞跃升级 · Claude Code Master 提示词（配色 · 监控 · 硬件）

> 一句话：把 Xico 的**配色系统、顶部菜单栏监控条、下拉面板、应用内监视页、硬件页**一次性推到
> **「比 Sensei 更精致、比 iStat 更真实密集、每个像素都像机械精密仪表」**的全球顶尖水平——
> **往 Sensei/iStat 靠，但绝不 100% 模仿**：保留 Xico 品牌辨识度 + 用户可自定义配色。
>
> 铁律：**真实数据 · 边框只圈图形（清爽·黄金比·像素对齐）· 精致高级清爽 · 极佳 UX**。不偷懒、不留半成品、不编造数据。

---

## 〇、你的角色

你是**世界级 macOS 产品设计师 + Swift/SwiftUI 工程师**。对象是 **Xico**：原生 SwiftUI（SPM 多模块），CleanMyMac 式清理 + iStat/Sensei 级系统监控 + 硬件档案。
目标：**逐项做到顶尖产品水平，飞跃式升级**。每一步都要**编译通过 + 离屏/真机截图验收**。全部完成后做**全面审计与评测**，给出「是否达到全球第一」的结论与剩余差距清单。

---

## 一、架构与令牌速览（直接复用，别重新推导）

**模块**：`DesignSystem`（令牌/组件/主题/本地化）· `Infrastructure`（采样/服务）· `Domain`（模型/规则）· `Features`（视图）· `XicoApp`（入口/菜单栏控制器/离屏渲染）· `Shared`/`XicoHelper`（特权删除）。

**关键文件**（改这些）：
- 菜单栏字形：`Sources/Features/MenuBarGlyph.swift`
- 菜单栏控制器：`Sources/XicoApp/MenuBarController.swift`（NSStatusItem + 单一瞬态 NSPopover）
- 下拉面板：`Sources/Features/MenuPanels.swift`（CPU/内存/网络）
- 合并总览面板：`Sources/Features/RootView.swift` 的 `MenuBarView`（已是 Sensei 式卡片+横条）
- 应用内监视页：`Sources/Features/MonitorView.swift`
- 硬件页：`Sources/Features/HardwareView.swift` · `Sources/Infrastructure/HardwareProfile.swift`
- 设计令牌：`Sources/DesignSystem/Tokens.swift`（XColor/XSpacing/XRadius/XFont/XMotion/XElevation）· `Visuals.swift` · `Components.swift` · `Motion.swift`
- 主题（可调配色的核心）：`Sources/DesignSystem/Theme.swift`（`XTheme`/`XThemeStore.current`：accent/ring/gradient）
- 菜单栏样式可视化选择器：`Sources/Features/SettingsView.swift` 的 `MBStyleTile`
- 实时采样：`Sources/Infrastructure/LiveMetrics.swift`（`SystemSnapshot`）· `MetricsEngine.swift`（共享单采样循环）· `NetworkInfoService.swift`

**数据层（全部真实采样，读不到即 `—`/隐藏，绝不编造）**：
`SystemSnapshot`：cpuUsage/perCore/cpuUser/cpuSystem、load1/5/15、memoryApp/Wired/Compressed/Cached、swap、memoryPressure/Fraction、pageIns/Outs、disk、net↑↓、gpuUsage、cpuTemp/gpuTemp、battery、thermal、fanRPM。
`MetricsEngine`：cpuFreqP/E、gpuHistory、perCoreHistory、进程榜。
`MacInfo.coreClusters`（每逻辑 CPU 是否性能核，读自 IODeviceTree 的 `cluster-type`，权威——**不猜核序**）。
`HardwareProfileService`：staticProfile + profilerDetails（型号编号/内存类型/速率/制造商/插槽）+ battery/gpu/storage/nvmeSMART/displays/sensors；`NetworkInfoService`：接口/IP/MAC/Wi-Fi。

**验证工作流（务必按此，否则白改）**：
- 菜单栏字形：`Xico --glyphs` → `/tmp/xico-icon/glyphs-*.png`（模板/彩色/graph/rich 各一张）。
- 合并/下拉面板：`Xico --menubar` → `/tmp/xico-icon/menubar-dark.png` + `mb-cpu/mb-memory/mb-network.png`。
- 任意页面真机：`scripts/make_app.sh release` 出签名包 → 克隆 `~/Applications/Xico.app` 换二进制 → `--open=hardware|monitor` → 清 `~/Library/Saved Application State/com.xico.app.savedState` → 截图。
- ⚠️ **两个致命坑（务必规避）**：
  1. `ImageRenderer` **不渲染 ScrollView 内容**——硬件页/监视页这类滚动页只能真机截图；离屏只能渲染非滚动的卡片/面板。
  2. `ImageRenderer` + **弹性宽 `GeometryReader`（`.frame(height:)` 但宽度靠父级）会死循环卡死**离屏渲染——菜单栏/面板里凡是离屏要渲染的进度条，**一律用定宽**（`.frame(width: barW, height: 5)`），不要用 GeometryReader 取宽。
- 菜单栏字形默认渲染为**模板图**（`isTemplate=true`，系统按深浅自动黑/白）；彩色为可选。

---

## 二、现状诚实评估（先认清，别重做已到位的）

**已到位**：设计系统/动效令牌成熟；菜单栏「边框只圈图形、数值在框外」已落实（折线软框、直方图/环/条裸露、温度无框）；下拉 CPU 面板（环+用户/系统+负载+温度+P/E频率+**性能核/能效核分组迷你环**+GPU环+开机时长+曲线+进程榜）已对齐 Sensei 图4；内存面板（压力环+用量环+分段条+5项图例+分页+交换条+进程榜）已对齐 Sensei 图5；合并总览已是 Sensei 式**卡片+横向进度条**；硬件页已有规格栅格+电池功率趋势+内存制造商/插槽+存储 SMART+散热风扇区间+网络接口 IP/MAC；11 语言、a11y、真机核验齐全；`make_app.sh` Universal 签名包冒烟通过。

**真实差距（本次要飞跃攻克的）**：

| # | 差距 | 目标（≥ Sensei/iStat，且有 Xico 自己的味道） |
|---|---|---|
| G1 | **全局配色不统一**：各页环/卡/渐变色相散乱 | 建**统一配色系统**：所有数据可视化随一套主题色阶；渐变背景全应用一致；**用户可在设置里调主色/主题**（对标 Sensei/iStat 的颜色自定义，见图1图2） |
| G2 | **菜单栏「加框」体验未做到顶级** | 动态图形**加一枚清爽软框**（只圈图形、数值在框外、黄金比几何、@2x 像素对齐）；框可**按项开关 + 调色**；单色/彩色皆锐利 |
| G3 | **样式选择仍偏文字** | 做成**纯「点图形选」**（iStat 式）：磁贴预览 = 与真实字形 1:1 的迷你图形，点图形即切样式，弱化文字下拉 |
| G4 | **监控信息密度/精致度** | CPU/内存/网络是用户常盯项——重点打磨：读数刀锋级带单位、动效平滑流动、悬停可擦洗、黄金比间距 |
| G5 | **硬件页要「更全更好」** | 逐项比 Sensei 更全 + 显示效果更佳（见 §五） |
| G6 | **黄金比间距未收敛** | 内边距/行高/图与数字间距按 ~1.618 层级推导，收敛到 `XSpacing`，禁散落魔法数；菜单栏几何 @2x 落整数设备像素 |

---

## 三、逐项任务（可直接执行，含文件与验收）

### 任务 A · 统一配色系统 + 渐变背景 + 用户可调（G1）

1. **单一色阶事实源**：所有数据可视化（环/条/直方图/折线/卡片强调）**只从 `XThemeStore.current`（Theme.swift）取色**——`accent` / `ring[]` / `gradient[]`。禁止各页硬编码 `auroraBlue/auroraViolet…` 散落色相；语义色（success/warning/danger）保留。
2. **渐变背景统一**：`AppBackground`（Visuals.swift）+ 合并总览卡片背景 + 首页 hero，全部用**同一套主题渐变**，克制（贴边一丝辉光，非满屏彩虹）。可参考 Sensei 合并面板那种「蓝→粉→绿」竖向柔和渐变，但**用 Xico 自己的珠宝色相**，不照抄。
3. **用户可调配色**（对标图1图2 iStat/Sensei 的颜色选择）：设置页增「主题/主色」选择——已有 `XTheme` 多主题（极光/深海/暖阳/终端/品红/石墨），做成**可视化色卡点选** + 即时全局生效（`XThemeStore.current` 切换 → 根视图 `.id` 重建）。可选：菜单栏每项独立调色（复用 `xico.mb.<id>.colored` + 增 `.tint`）。
4. **精致高级清爽**：卡片 `XRadius.card`、发丝描边 `XColor.border`、`XElevation` 三级阴影；渐变只留给主角（scan orb / 主 CTA / hero）；数据用珠宝色相不刺眼。
- **验收**：`--layout` + `--menubar` 截图；切换主题后所有页环/条/渐变**同步改色**；深浅色都成立。

### 任务 B · 顶部菜单栏监控条：加框 + 点图形选（G2/G3/G4）— **本次重点**

> 用户常盯 **CPU / 内存 / 网络**，这条是门面，必须做到 iStat/Sensei 级舒服。

1. **动态图形加清爽软框**（`MenuBarGlyph.swift`）：
   - 折线 / 直方图 / 环 / 进度条这类**动态运行状况图形**，各自套一枚**只圈图形本身**的圆角软框（淡底 `~0.06–0.08` + 发丝描边 `~0.22–0.32`，圆角 3.5–4，1pt）；**数值百分比一律在框外并排，绝不进框**。
   - 框**可按项开关**（`xico.mb.<id>.border` 默认开）+ 跟随该项颜色。纯文字项（图标+值 / 仅数值 / 温度）不加框。
   - **黄金比几何 + @2x 像素对齐**：胶囊高度/内边距/圆角/描边粗细按 ~1.618 推导，@2x 落整数设备像素（直方图 8×2pt 条+1pt 隙=23pt 已对齐，其余同法核对）。
2. **network / gpu 的 graph 补真实迷你折线**（已具备，回归核对，别糊成灰块）。
3. **iStat 式「点图形选样式」**（`SettingsView.MBStyleTile`）：
   - 每个样式磁贴 = **与真实菜单栏字形 1:1 的迷你预览图形**（图标+值 / 仅值 / 迷你折线 / 可视化环·条·直方图），**点图形即切**，文字仅作辅助标签。
   - 每项可独立选：显示与否、样式、颜色（单色/彩色）、是否加框。像 iStat Menus 那样「所见即所得」。
4. **读数刀锋级**：全真实带单位；网络永不裸 0（`compactRate` "0K"）；温度 nil→"—°" 不误导。
- **验收**：`--glyphs` 看 4 张（模板/彩色/graph/rich）——图形有框、数值在框外、单色/彩色皆锐利、无空框、无糊块；`--open=settings` 看可视化选择器点图形可切。

### 任务 C · 下拉面板 + 合并总览（G4）

1. **合并总览 `MenuBarView`**（已是 Sensei 卡片+横条）：回归打磨——卡片背景随主题微渐变、条形黄金比、长语言单行缩放不换行、真实数据。可选：给每张卡片头一枚极淡主题色底（像 Sensei 图3 每卡不同色调），但**用主题色阶**。
2. **CPU 面板**（`MenuPanels.swift .cpu`）：保持（环+用户/系统+负载+P/E频率+性能核/能效核分组环+GPU环+开机时长+曲线+进程榜）。可选升级：CPU 用**双色直方图**（系统/用户 堆叠，对齐 Sensei 图4），GPU 段扩成 **4 环**（占用/显存/温度/频率）。
3. **内存面板 `.memory`**：保持（压力环+用量环+分段条+5项图例+分页+交换条+进程榜，已对齐图5）。
4. **网络面板 `.network`**：保持（大数字+峰值/累计+双线折线+接口清单）。
- **验收**：`--menubar` 四张截图密度 ≥ Sensei、全真实、黄金比、无中文残留（新字符串补齐 11 语言）。

### 任务 D · 应用内监视页顶级升级（G4）

`MonitorView.swift`：四大历史大图（CPU/内存/网络/GPU）平滑流动 + 网格 + **悬停十字准星读「值·时刻」**；每核心「**热力条 / 迷你环**」可切（迷你环按 `coreClusters` 真实分性能核/能效核）；传感器中心（复用硬件页 2 列）；顶部 `XLiveDot` LIVE 脉冲。配色随主题。
- **验收**：真机 `--open=monitor` 截图，四图流动、悬停读数、条/环可切、P/E 分组正确。

### 任务 E · 硬件页超越 Sensei（G5）

`HardwareView.swift` / `HardwareProfile.swift`，**逐项比 Sensei 更全 + 显示更佳**：
1. **内存**：容量/类型/速率/**制造商/插槽**（已解析；Intel 逐条 DIMM，Apple Silicon 板载）。可补：带宽、通道数（可得则显）。
2. **电池**：健康/循环/温度/电压/**功率趋势迷你图**（已有，充放电时显）+ 设计容量对比 + 健康建议。
3. **存储**：TBW/剩余寿命/通电时长/读写温度/TRIM/**内置+外置卷列表**（已有 SMART，补外置卷）。
4. **散热**：风扇当前 + **区间条 + 目标/最大 RPM**（若 SMC 有目标键）；SoC 各簇温度（传感器 2 列）。
5. **显示**：分辨率/刷新/HDR/物理尺寸/缩放（已有）+ ProMotion/Nits（可得则显）。
6. **网络**：接口清单 + IP/MAC + Wi-Fi 链路速率/信道/信号（已有，回归核对 MAC 真实）。
7. **信息密度黄金比**：hero 规格栅格 + 2 列卡片，卡内 12/16/24 间距层级；显示效果精致（图标砖 flat 染色、发丝描边、resting 阴影）。
- **验收**：真机 `--open=hardware` 逐卡截图，每项真实、比 Sensei 更全、密度黄金比、读不到即隐藏。

### 任务 F · 黄金比间距 + 真实数据终检（G6）

- 全应用内边距/行高/图与数字间距按 ~1.618 层级推导，收敛到 `XSpacing`（4pt 网格：组内 8/12、组间 16/24、区块 32），禁散落魔法数。
- 菜单栏几何 @2x 像素对齐终检。
- **真实数据全盘扫**：任何读不到的字段显示 `—` 或隐藏，绝无 "50% / Missing data" 式占位（Sensei 编辑器里的假数据在成品里不允许出现）。

---

## 四、设计铁律（每一处都必须成立）

1. **真实数据**：所有读数来自真实采样；读不到显示 `—`/隐藏并说明，**绝不编造/占位**。
2. **边框只圈图形**：动态图形（折线/直方图/环/条）套一枚清爽软框、**数值在框外**；纯文字不加框；框可开关可调色。
3. **黄金比间距**：~1.618 层级推导，收敛 `XSpacing`；菜单栏几何 @2x 像素对齐。
4. **统一克制配色**：全应用数据可视化随**一套主题色阶**（`XThemeStore.current`）；渐变背景一致；用户可调主色/主题；渐变只留给主角。
5. **一套动效**：走 `XMotion`；图表平滑流动、环渐变填充、LIVE 脉冲、完成计数；Reduce Motion 全降级。
6. **真实层次**：`XElevation` 三级阴影；卡片 resting、悬停 raised、弹窗 overlay。
7. **深浅色 + 11 语言不截断 + AA 对比 + VoiceOver + 键盘可达**全部成立；新字符串走 `xLoc`/`xLocF` 补齐全部 11 种 `.strings`（de/en/es/fr/it/ja/ko/pt-BR/ru/zh-Hans/zh-Hant）。

---

## 五、验收 checklist（顶尖产品，逐条打勾）

- [ ] 配色：切换主题后**所有页**环/条/直方图/折线/渐变背景**同步改色**；深浅色成立；用户可调主色。
- [ ] 菜单栏：动态图形有清爽软框、**数值在框外**；框可按项开关+调色；单色/彩色皆锐利；黄金比几何 @2x 对齐；读数全真实带单位。
- [ ] 样式选择：**点图形即切**（iStat 式），磁贴预览与真实字形 1:1。
- [ ] 合并总览 + CPU/内存/网络下拉：每个一屏读懂，密度 ≥ Sensei，全真实，黄金比。
- [ ] 监视页：四大历史图平滑流动 + 悬停擦洗读数 + 每核心条/环可切（P/E 真实分组）。
- [ ] 硬件页：内存规格/电池/存储寿命/散热/显示/网络**逐项比 Sensei 更全**，显示更佳，密度黄金比。
- [ ] 无假数据、无占位、无「奇奇怪怪」的框、无卡顿。
- [ ] `swift build` 绿；`swift test` 全过；`make_app.sh` 出 Universal 签名包冒烟通过；11 语言 0 缺失。

---

## 六、执行方式 + 最终审计评测

1. 按 **A（配色）→ B（菜单栏加框+点图形选）→ C（面板）→ D（监视页）→ E（硬件页）→ F（间距/真实数据）** 顺序推进。
2. 每完成一项：`swift build` + 对应 `--glyphs` / `--menubar` / 真机 `--open=` 截图**逐张验收**，再进入下一项；每次改动**保持 真实数据 / 配色统一 / 深浅色 / 11语言 / a11y / 黄金比** 六线成立。
3. **全部完成后，做一次全功能审计与评测**：对照本文件 §五 checklist，**逐页与 Sensei / iStat Menus / CleanMyMac 逐项对比**，给出**「是否达到全球第一」的明确结论**与**剩余差距清单**（诚实，不粉饰）。审计写成 `docs/` 文档留档。

> 记住：往 Sensei/iStat 靠是为了「顶级的舒适与密度」，但 Xico 是**我们自己的产品**——保留品牌辨识度、可调配色、更全的硬件、更真实的数据。**做到全球第一好，不偷懒，不留半成品。**
