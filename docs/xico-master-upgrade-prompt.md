# Xico · 全球顶尖化 · Claude Code 优化升级提示词（Master）

> 一句话：把 Xico 从「已经很不错」推到**「全球最好的 Mac 清理 + 监控软件」**——
> 比 CleanMyMac 更克制精致、比 iStat Menus / Sensei 更真实密集，每个像素都像机械精密仪表。

---

## 一、你的角色与任务

你是**世界级 macOS 产品设计师 + Swift/SwiftUI 工程师**。对象是 **Xico**：原生 SwiftUI（SPM 多模块）、CleanMyMac 式清理 + iStat 级系统监控 + Sensei 级硬件档案的 Mac 应用。
任务：**逐项做到顶尖产品水平，飞跃式升级，不偷懒、不留半成品**。每一步都要**编译通过 + 真机/离屏截图验收**。

**语言与本地化铁律**：源码里的中文字面量**就是 i18n 的稳定 key**，在展示处用 `xLoc(...)`/`xLocF(...)` 包裹；新增字符串必须补齐全部 11 种语言的 `.strings`（de/en/es/fr/it/ja/ko/pt-BR/ru/zh-Hans/zh-Hant）。

---

## 二、架构与设计系统速览（别重新推导，直接复用）

**模块**：`DesignSystem`（令牌/组件）· `Infrastructure`（采样/服务）· `Domain`（模型/规则）· `Features`（视图）· `XicoApp`（入口/菜单栏/离屏渲染）· `Shared`/`XicoHelper`（特权删除）。

**设计令牌（`Tokens.swift`）**：
- `XColor`：语义色 + 主题化 `ringColors`/`brandGradient`；`gauge(fraction)` 三段语义配色；`gpuGauge` 永不转红。
- `XSpacing`（4pt 网格）· `XRadius`（micro3/chip6/control8/button11/tile12/card18/large26）· `XFont`（严格阶梯 + 等宽数字）。
- `XMotion`（snappy/settle/celebrate/gauge/crossfade/hover）· `XElevation`（flush/resting/raised/overlay）。

**关键组件**：`XCard` · `XRingGauge`/`XMiniRing` · `XLineChart`（`AnimatableVector` 平滑流动 + 网格 + 悬停擦洗）· `XScanOrb`（恒定弧长彗星，头即渐变最亮端，无分离白点）· `XSegmentBar`（内存分段条）· `XThumbnail`（QuickLook 缩略图）· `XSpinner`（品牌转圈）· `XIconTile(flat:)` · `XLiveDot` · `XCheckbox` · `XPrimary/XSecondaryButtonStyle`。

**数据层（全部真实采样）**：`SystemSnapshot`（`LiveMetrics.swift`：cpu/perCore/user/sys、load1/5/15、memoryApp/Wired/Compressed/Cached、swap、memoryPressure、pageIns/Outs、disk、net↑↓、gpuUsage、cpuTemp/gpuTemp、battery、thermal、fanRPM）· `MetricsEngine`（引用计数单采样循环 + 历史 + 进程榜 + cpuFreqP/E）· `HardwareProfileService`（staticProfile + profilerDetails + battery/gpu/storage/nvmeSMART/displays/sensors）· `NetworkInfoService`。

**验证工作流**：
- 菜单栏字形：`Xico --glyphs` → `/tmp/xico-icon/*.png`（图形离屏，最可靠）。
- 任意页面真机：克隆 `~/Applications/Xico.app` 到临时目录、换入 `.build/debug/Xico` + `Xico_*.bundle`、`codesign --force --deep -s -`、`--open=<moduleID>` 直达该页、清 `~/Library/Saved Application State/com.xico.app.savedState` 让 ScrollView 回顶、截图。（computer-use 截图可用，点击/滚动在多屏下坐标被网关拦，改用 `--open=` 直达。）
- 组件离屏：`--layout`（侧栏/首页，`ImageRenderer` 不渲染 ScrollView 内容）。

---

## 三、现状诚实评估（先认清哪些已到位，别重做）

**已达一线水平（保持，勿推倒）**：设计系统与动效令牌成熟；`XLineChart` 已平滑流动 + 网格 + 悬停读数；`XScanOrb` 已是恒定弧长渐变彗星（无塑料白点）；缩略图画廊、按钮体系、克制侧栏、主题化首页、11 语言、AA 对比、VoiceOver 均已落地；硬件页已有设备规格栅格 + 富内存卡（分段条 + 压力徽章）；监视页 5 Tab（总览/CPU/内存/网络/GPU）已有网格历史图 + 每核心条 + 压力环 + 分页/交换 + 进程榜；菜单栏已做**「边框只圈图形」的胶囊 + iStat 式可视化选择器**。

**真实差距（按性价比排序，这就是本次要攻克的）**：

| # | 差距 | 现状 | 目标（≥ Sensei/iStat） |
|---|---|---|---|
| G1 | **菜单栏下拉面板密度** | `MenuMetricPanel` 有环+分段+进程，但比 Sensei 少：无每核心环分组、无频率/负载/开机时长、内存无压力环/分页、网络无峰值/接口 | 每面板「一屏读懂一个子系统」，密度 ≥ Sensei |
| G2 | **硬件页深度** | 规格/电池/存储/GPU/显示/传感器齐全 | 内存补厂商/速率/插槽；存储补 TBW/寿命/通电；电池补功率趋势；散热补目标 RPM；网络补接口/IP/MAC——**逐项比 Sensei 更全** |
| G3 | **菜单栏图形精度** | 直方图/环/条/折线像素对齐 | network/gpu 的 graph 补迷你折线；胶囊几何黄金比终检 |
| G4 | **每核心可视化** | 监视页 CPU 用「条」 | 增加「性能核/能效核分组的迷你环」选项（对齐 Sensei） |
| G5 | **状态与微交互** | 有 empty/success/loading | 补首帧骨架屏 `XSkeleton`、键盘焦点环、SpaceLens 环/块切换（`TreemapView` 已建未用） |
| G6 | **正确性/性能** | 采样后台化 | i18n 满参数校验、a11y 全覆盖、菜单栏 `ImageRenderer` 频率/能耗复核、冷启动预算 |

> 详细的**监控专项**拆解见 [`docs/monitor-upgrade-prompt.md`](./monitor-upgrade-prompt.md)（G1/G3/G4 的逐面板对照与待办）。

---

## 四、逐项任务（可直接执行，含文件与验收）

### Tier 0 · 招牌视觉（已完成，回归校验勿破坏）
- `XScanOrb`（`Motion.swift`）：恒定弧长彗星、渐变头、无白点。**验收**：`--open=systemJunk --autoscan` 截图，无分离白点、不忽长忽短。
- 菜单栏胶囊（`MenuBarGlyph.swift`）：**边框只加在 graph/rich（真实图形）**，icon+value/仅数值/无图形退化 → 无框。**验收**：`--glyphs` 看 `glyphs-rich-dark.png`（bar/ring/histogram 有框，网络/温度文字无框）。
- 可视化选择器（`SettingsView.MBStyleTile`）：点图形选样式。**验收**：`--open=settings` 截图。

### Tier 1 · 监控做到 Sensei 级（本次主攻）
1. **CPU 下拉面板**（`MenuPanels.swift .cpu`）：每核心迷你环（`perCore` 按性能/能效分组）+ CPU 频率（`cpuFreqP/E`）+ 平均负载（`load1/5/15`）+ 开机时长（`macInfo.uptime`）+ GPU 环段。
2. **内存下拉面板**（`.memory`）：**内存压力环**（`memoryPressureFraction`，色随等级）+ 分页读写（`pageIns/Outs`）+ 交换进度条 + 完整图例（应用/联动/压缩/缓存/可用）。
3. **网络下拉面板**（`.network`）：会话峰值/累计 + 接口名与类型（`NetworkInfoService`）+ 上下行单位色标。
4. **合并总览**（`MenuBarView`）：存储健康 + 关键传感器 + 电池三段，Sensei 式 320pt 卡片总览。
5. **菜单栏图形**：network/gpu 的 `.graph` 补迷你折线；胶囊高度/内边距/圆角/描边黄金比 + @2x 像素对齐终检。

### Tier 2 · 硬件页超越 Sensei（本次主攻）
- **内存**（`HardwareProfile.profilerDetails` 已解析 `dimm_type`）：扩展 manufacturer/speed/slots（Intel 逐条 DIMM；Apple Silicon 统一内存 + LPDDR 代际），硬件页内存卡增「规格」段。
- **存储**：TBW/剩余寿命/通电时长（`NVMeSMART` 已有）已展示，补内置+外置卷列表与读写温度。
- **电池**：补功率趋势迷你图（近 N 次采样）、健康建议、循环上限。
- **散热**：风扇当前/目标/最大 RPM、SoC 各簇温度（传感器已 2 列）。
- **网络卡**：接口清单 + IP/MAC + 链路速率。
- 信息密度按黄金比：hero 规格栅格 + 2 列卡片，卡内 12/16/24 间距层级。

### Tier 3 · 全应用精致化打磨
- `XSkeleton`（surfaceAlt + Reduce-Motion 门控微光）用于首帧未采样的指标卡/环。
- 键盘焦点环（`SidebarTile` + 按钮样式的 2px 品牌描边 + `.focusable()`）。
- SpaceLens 环/块切换（接上已建的 `TreemapView`，`@AppStorage` 记忆）。
- 相似图片/重复文件画廊回归校验（`ResultGroupCard` 已有 `isVisualGroup`）。
- 任务流（Optimization/Maintenance/Shredder/Uninstaller/AppUpdater）统一 `CompletionView` 计数庆祝 + Select-All。

### Tier 4 · 正确性 / 无障碍 / 性能 / 打包
- i18n：所有 `xLocF` 满参数校验；侧栏/环 a11y label 走 `xLoc`；11 语言不截断（放宽 fixedSize）。
- a11y：全应用 VoiceOver 标签 + 键盘可达 + Reduce Motion 降级复核。
- 性能：菜单栏 `ImageRenderer` 渲染频率/能耗复核（隔次/脏检查）；`AppModel.init` 冷启动只走快通道；后台队列不阻塞主线程。
- 打包：`scripts/make_app.sh` 嵌入**全部** `Xico_*.bundle`（漏一个即 `Bundle.module` 启动崩溃）；Universal（arm64+x86_64）；签名校验通过。

---

## 五、设计铁律（每一处都必须成立）

1. **真实数据**：所有读数来自真实采样；读不到显示 `—` 并说明，**绝不编造/占位**（Sensei 编辑器里的 "50%/Missing data" 不允许出现在成品）。
2. **边框只圈图形**：图表/环/条/直方图才加框；纯文字（图标+值、仅数值）不加框。
3. **黄金比间距**：内边距/行高/图形与数字间距按 ~1.618 层级推导，收敛到 `XSpacing`，禁止散落魔法数；菜单栏几何 @2x 像素对齐。
4. **克制配色**：数据用珠宝色相（随主题 `ringColors`），菜单栏默认单色模板、彩色可选；渐变只留给主角（scan orb / 主 CTA）。
5. **一套动效**：走 `XMotion`；图表平滑流动、环渐变填充、LIVE 脉冲、完成计数；Reduce Motion 全降级。
6. **真实层次**：`XElevation` 三级阴影；卡片 resting、悬停 raised、弹窗 overlay。
7. **深浅色 + 11 语言 + AA 对比 + VoiceOver + 键盘**全部成立。

---

## 六、验收 checklist（顶尖产品，逐条打勾）

- [ ] 菜单栏：图形项有框、文字项无框；单色/彩色皆清晰锐利；读数全真实带单位；黄金比几何。
- [ ] 下拉面板：CPU/内存/网络/合并 每个一屏读懂，密度 ≥ Sensei，全真实数据。
- [ ] 监视页：四大历史图平滑流动 + 悬停擦洗读数 + 每核心可视化（条/环可选）。
- [ ] 硬件页：内存规格/电池/存储寿命/散热/显示/网络逐项比 Sensei 更全，密度黄金比。
- [ ] 扫描/加载：彗星无分离白点、无塑料感、恒定弧长；加载统一 `XSpinner`。
- [ ] 全应用：深浅色、11 语言不截断、AA 对比、VoiceOver、键盘可达、Reduce Motion 降级。
- [ ] 无假数据、无占位、无「奇奇怪怪」的框、无卡顿。
- [ ] `swift build` 绿；`scripts/make_app.sh` 出包签名校验通过。

---

## 七、执行方式

按 **Tier 1 → Tier 2 → Tier 3 → Tier 4** 顺序推进；每完成一个 Tier：`swift build` + 对应 `--glyphs`/`--open=` 截图验收，再进入下一 Tier。每次改动**保持 i18n/深浅色/a11y 三线成立**。全部完成后，做一次**全功能审计与评测**（对照本文件 §六 checklist + 逐页与 Sensei/iStat/CleanMyMac 对比），给出「是否达到全球顶尖」的结论与剩余差距清单。
