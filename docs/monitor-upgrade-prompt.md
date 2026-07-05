# Xico 监控系统 · 飞跃式升级提示词（Claude Code Prompt）

> 目标：把 Xico 的「顶部菜单栏监控条 + 下拉详情面板 + 应用内监视页 + 硬件档案页」全面做到
> **比 Sensei / iStat Menus 更全、更真、更精致清爽**，达到全球顶尖产品水平。
> 原则：**精致 · 高级 · 清爽 · 真实数据 · 黄金比间距 · 用户体验极佳**。绝不用假数据、不堆砌、不偷懒。

---

## 0. 铁律（每一处都必须遵守）

1. **真实数据**：所有读数必须来自 `SystemSnapshot`（`LiveMetrics.swift`）/`HardwareProfileService` 的真实采样。
   任何占位值（如 Sensei 编辑器里的 "50%"、"Missing data"）在 Xico 里都不允许出现——读不到就显示 `—` 并说明，绝不编造。
2. **边框只圈图形**：菜单栏里，**只有「迷你折线 / 直方图 / 环 / 条」这类真实图形才加圆角边框**；
   「图标+数值」「仅数值」是纯文字，**一律不加框**（加了就怪）。已在 `MenuBarGlyph.render(bordered:)` 落实，后续保持。
3. **黄金比间距**：卡片/胶囊的内边距、图形与数字的间距、行高，按 ~1.618 的层级推导，禁止随手写魔法数字；
   收敛到 `XSpacing` 令牌。菜单栏胶囊高度、圆角、描边粗细全部像素对齐（@2x 落整数设备像素）。
4. **一套动效语言**：走 `XMotion`（snappy/settle/gauge/crossfade）。图表随数据平滑流动，不硬切、不忽快忽慢。
5. **深浅色 + 11 语言 + 无障碍**都要成立；新字符串走 `xLoc`，补齐全部 `.strings`。

---

## 1. 竞品全面对比（Sensei / iStat Menus ⟷ Xico）

### 1.1 顶部菜单栏常驻监控条

| 能力 | Sensei / iStat | Xico 现状 | 目标 |
|---|---|---|---|
| 每指标独立显示样式 | ✅ 图形/数值可选 | ✅ 4 样式（图标+值/仅值/迷你图/可视化） | 保持 + **可视化选择器已做成「点图形选」而非文字下拉** |
| 图形类型 | 折线、直方图、环、条 | 折线(graph)、直方图/环/条(rich) | ✅ 已具备，需打磨精度与像素对齐 |
| 边框/胶囊 | iStat 可选背景 | ✅ **只在图形项加框** | 保持；描边 0.32 主色 / 模板 0.26，圆角 5，1pt |
| 单色/彩色 | 可选 | ✅ 每项独立 colored | 保持 |
| 网络吞吐 ↑↓ | ✅ 带单位 | ✅ `compactRate`（"1.2M"/"0K"，永不裸 0） | 保持；graph 模式加迷你折线 |
| 实时性 | 1–3s | ✅ `MetricsEngine` 引用计数循环 | 保持；间隔可调 |
| 点击→详情面板 | ✅ | ✅ 每项独立 popover | 见 1.2 增强 |

**待办**：① 菜单栏胶囊的高度/内边距/圆角做黄金比 + 像素对齐终检；② network/gpu 的 graph 模式补迷你折线；
③ 可视化选择器磁贴的预览图形做到与真实字形 1:1。

### 1.2 下拉详情面板（点菜单栏项弹出）

Sensei 的面板是「一屏读懂一个子系统」。逐面板对照：

**CPU & GPU（Sensei 截图 4）**：CPU 频率(GHz) + 直方图 + 用户/系统% + 每核心环 + 进程榜；
GPU 段：占用%环 / 显存%环 / 温度环 / 频率环；平均负载量(1/5/15)；电脑开启时间；底部快捷启动。
- Xico 现状（`MenuMetricPanel .cpu`）：环 + 用户/系统/温度/GPU 小卡 + 每核心**条** + 折线 + 进程榜。
- **目标**：① 每核心改「性能核/能效核」分组的**迷你环**（对齐 Sensei）；② 增加 CPU 频率(P/E 核 GHz，`MetricsEngine.cpuFreqP/E` 已有)；
  ③ 增加平均负载(1/5/15，`load1/5/15` 已有)与开机时长(`macInfo.uptime` 已有)；④ 进程榜显示应用图标 + 行内占用条（部分已有）。

**内存（Sensei 截图 6）**：压力%环 + 内存%环 + App/联动/压缩/可用 + 进程榜 + 写入/读取分页 + 已用交换条。
- Xico 现状（`.memory`）：环 + 分段条 + App/联动/压缩图例 + 交换 + 进程榜。
- **目标**：① 增加**内存压力环**（`memoryPressureFraction` 已有，颜色随等级）；② 增加写入/读取分页（`pageIns/pageOuts` 已有）；
  ③ 交换区做成进度条 + "第 X / 共 Y"；④ 图例补「缓存文件/可用」。

**网络（Xico 已有 `.network`）**：下载/上传大数字 + 双线折线。
- **目标**：① 加峰值/累计(本次会话)芯片；② 加接口名/连接类型(Wi-Fi/以太网，`NetworkInfoService` 已有)；③ 上/下行分别标注单位与色。

**存储 / 传感器 / 电池**：Sensei 有独立卡；Xico 目前并入硬件页。
- **目标**：菜单栏「合并总览面板」`MenuBarView` 补齐存储健康 + 关键传感器 + 电池三段，做成 Sensei 式的一屏总览（320pt 定宽，卡片化）。

### 1.3 应用内监视器页（`MonitorView`）

Sensei/iStat 的应用内是「大图 + 可擦洗历史」。
- Xico 现状：`XLineChart` 已平滑流动 + 网格 + 悬停读数；环随主题。
- **目标**：① CPU/内存/网络/GPU 四条**带网格的历史大图**，悬停十字准星读出「值 · 时刻」；
  ② 每核心热力条/环；③ 传感器中心（复用硬件页 2 列）；④ 顶部 `XLiveDot` 脉冲 LIVE。

### 1.4 硬件档案页（`HardwareView`）——要求**比 Sensei 更全更好**

Sensei「硬件」给：型号、电池、存储、GPU、显示器、传感器。Xico 已做设备规格栅格 + 电池环 + 内存明细(分段条+压力) + 存储 SMART + 散热 + GPU 环 + 显示器 + 传感器(2 列)。
- **要超越 Sensei 的点**：
  1. **内存**：补内存**类型/制造商/单条规格**（Intel 逐条 DIMM：容量/速率/厂商/插槽；Apple Silicon：统一内存 + LPDDR 类型）。已解析 `dimm_type`，扩展到 manufacturer/speed/slots。
  2. **电池**：补设计循环上限、健康建议、充放电功率曲线（近 N 次采样迷你图）。
  3. **存储**：补 TBW/剩余寿命/通电时长（`NVMeSMART` 已有）、读写温度、卷列表（内置+外置）。
  4. **散热**：风扇转速 + 目标/最大 RPM、每传感器温度条（已有）、SoC 各簇温度。
  5. **显示**：刷新率/HDR/色域/物理尺寸/缩放（已有），补 ProMotion/Nits（可得则显）。
  6. **网络**：接口清单 + IP/MAC + 连接速率（`NetworkInfoService`）。
  7. **一屏信息密度**做到黄金比：hero 规格栅格 + 2 列卡片，卡片内 12/16/24 间距层级。

---

## 2. 逐区优化指令（可直接执行）

### 2.1 菜单栏条（`MenuBarGlyph.swift` / `MenuBarController.swift`）
- [x] 边框只加在 graph/rich（真实图形）；icon+value / value-only / 无图形退化 → 不加框。
- [x] 可视化选择器改为「点图形选样式」（`SettingsView` 的 `MBStyleTile` + 迷你预览）。
- [ ] network/gpu 的 `.graph` 补迷你折线；rich 的 network 给一条真实迷你折线而非纯文字。
- [ ] 胶囊几何黄金比 + 像素对齐终检（高度、内边距、圆角、描边）。

### 2.2 下拉面板（`MenuPanels.swift`）
- [ ] CPU 面板：每核心迷你环（性能/能效分组）+ 频率 + 平均负载 + 开机时长 + GPU 环段。
- [ ] 内存面板：压力环 + 分页读写 + 交换进度条 + 完整图例。
- [ ] 网络面板：峰值/累计 + 接口名/类型 + 单位色标。
- [ ] 「合并总览」`MenuBarView`：存储 + 传感器 + 电池三段卡片化。

### 2.3 监视器页（`MonitorView.swift`）
- [ ] 四大历史图 + 悬停读数 + 每核心可视化 + 传感器中心 + LIVE 脉冲。

### 2.4 硬件页（`HardwareView.swift` / `HardwareProfile.swift`）
- [ ] 内存规格扩展（厂商/速率/插槽）；电池/存储/散热/显示/网络按 §1.4 补全，务求比 Sensei 更全。

---

## 3. 设计规范（精致 / 高级 / 清爽 / 黄金比）

- **色**：数据用珠宝色相（`XColor.ringColors` 随主题）；菜单栏克制（默认单色模板，彩色可选）。
- **形**：卡片圆角 `XRadius.card(18)`，胶囊 `chip(6)`，图表条 `micro(3)`；描边 `XColor.border` 发丝级。
- **距**：`XSpacing` 4pt 网格，组内 8/12、组间 16/24、区块 32；黄金比推导层级，禁止散落魔法数。
- **字**：`XFont` 阶梯；数字等宽 `.monospacedDigit()`；标识符用 `captionMono`。
- **动**：`XMotion`；图表平滑流动；环渐变填充；LIVE 脉冲；Reduce Motion 全降级。
- **深**：`XElevation` 三级阴影；卡片 resting，悬停 raised，弹窗 overlay。

---

## 4. 验收标准（顶尖产品 checklist）

- [ ] 菜单栏：图形项有框、文字项无框；单色/彩色都清晰；@2x 像素锐利；读数全真实、带单位。
- [ ] 下拉面板：每个子系统一屏读懂，密度与 Sensei 持平或更高，全部真实数据。
- [ ] 监视页：四大图平滑流动 + 悬停可擦洗读数 + 每核心可视化。
- [ ] 硬件页：逐项比 Sensei 更全（内存规格/电池/存储寿命/散热/显示/网络）。
- [ ] 全应用：深浅色、11 语言不截断、AA 对比、VoiceOver、键盘可达。
- [ ] 无假数据、无占位、无「奇奇怪怪」的框，无塑料感动画。

---

## 5. 相关文件

- 菜单栏字形：`Sources/Features/MenuBarGlyph.swift`
- 菜单栏控制器：`Sources/XicoApp/MenuBarController.swift`
- 下拉面板：`Sources/Features/MenuPanels.swift`
- 监视页：`Sources/Features/MonitorView.swift`
- 硬件页：`Sources/Features/HardwareView.swift` · `Sources/Infrastructure/HardwareProfile.swift`
- 实时采样：`Sources/Infrastructure/LiveMetrics.swift`（`SystemSnapshot`）· `MetricsEngine.swift`
- 设计令牌：`Sources/DesignSystem/Tokens.swift` · `Visuals.swift` · `Components.swift` · `Motion.swift`
- 菜单栏离屏验证：`Xico --glyphs` → `/tmp/xico-icon/*.png`
- 页面离屏/真机验证：`--open=<moduleID>`（hardware/monitor/…）+ 截图
