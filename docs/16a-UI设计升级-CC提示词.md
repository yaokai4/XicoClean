> 用途：把本文件全文粘贴给一个新的 Claude Code 会话即可开始实施。配套完整分析与升级方案见 [`docs/16`](16-UI设计全面超越CleanMyMac-升级方案-2026-07.md)。

# Xico UI/设计升级实施任务（P0 优先，做完暂停等我确认）

**一句话目标**：不改扫描算法/后端，只做 UI、视觉、材质、动效、体验的精致化升级，踩在 CleanMyMac 的三个结构性空档（触感=0、有质感的材质=0、声/触/光统一招牌=0）上，把「渲染图般干净」推进到「实物般高级」，四维（更好看/更精致/更高级/更好用）全面反超。

代码根目录 `/Users/yaokai/Desktop/IT/MacApp/XicoApp`，**只改 `Sources/`**，忽略 `XicoClean/` 与 `.claude/worktrees/` 副本。

## 红线与约束（每一处改动都必须遵守，违反即回滚）

1. **单一取色入口 = `XColor`（`Sources/DesignSystem/Tokens.swift`）**。禁止在视图里写裸 `Color(hex:)`/`Color(red:…)`；新色一律进 `XColor`，且用 `dynamic(light:dark:)` 给深浅两套值。
2. **令牌化，不硬编码**。间距用 `XSpacing`、圆角用 `XRadius`、字阶用 `XFont`、投影用 `XShadow/XElevation`、动效用 `XMotion/XTransition`、透明度用 `XAlpha`。新增的动效/触感/材质也要落成令牌，组织方式对齐现有体系（例如 `XHaptic` 与 `XSound`/`XMotion` 同构、同目录）。
3. **深浅色双写**。任何新视觉都要在 light + dark 两套下都成立，尤其暗色不能出现 banding。
4. **Reduce Motion 降级**。所有新动效读 `@Environment(\.accessibilityReduceMotion)`；开启时：MeshGradient/幽灵环静止、粒子叙事退化为一次淡入、count-up 直接显示终值。
5. **性能不掉帧**。`Canvas` 噪点/粒子必须 `.drawingGroup()` 栅格化 + `.allowsHitTesting(false)`；稳态（无扫描/无交互）必须零重绘、零 `TimelineView` 空转。任何持续动效都要能在稳态停下。
6. **无障碍不回退**。新增焦点环/触感不得破坏 VoiceOver、键盘导航、对比度；触感全局可关（`xico.haptics.enabled` 默认 true）并随系统设置自动降级。
7. **macOS 26 Liquid Glass 必须版本判定**。`.glassEffect(...)` / `NSGlassEffectView` 只在 `if #available(macOS 26, *)` 分支使用；低版本走已有 `xFloatingGlass` 手绘玻璃回退分支（`Sources/DesignSystem/VisualEffect.swift`），且回退分支也要拿到方向性内高光，不能只有单色描边。铁律保留：**内容层禁上玻璃，玻璃只上悬浮导航层**；多玻璃元件用 `GlassEffectContainer` 分组。
8. **不推翻已达世界级的部分**：双层投影、高程双通道、连续曲率、珠宝色工程、matchedGeometry orb→环 一律不动，只做叠加增强。

---

## P0（半天～一天/项，立见高级感，先只做这一批然后停）

### P0-1 新增 `XHaptic` 触感令牌（最强差异化，CMM=0）
- 新建 `Sources/Infrastructure/XHaptic.swift`（与 `XSound.swift` 同目录、同风格）。封装 `NSHapticFeedbackManager.defaultPerformer.perform(_:performanceTime:.now)`，暴露 `.levelChange`（跨台阶）/`.alignment`（拖拽吸附）/`.generic`；读 `xico.haptics.enabled`。
- 接入点：清理完成、健康分跨过优秀阈值 → `.levelChange`；文件拖入收集篮吸附、六类落定终点 → `.alignment`。
- **铁律**：比声音更克制——危险操作（粉碎/删除）永不配触感，hover/滚动永不配。

### P0-2 定制 3 条签名音效资产
- 只换 `XSound.swift` 里的 name 映射与 bundle 资产，**零逻辑改动**：`scanDone` 高频叮 / `cleanDone` 玻璃水滴 / `countdownDone` 低频确认，替换现有系统内置占位（Tink/Glass/Pop，TODO 已注明）。若暂无资产，先留清晰 TODO 与占位映射，不要伪造音频文件。

### P0-3 `GrainOverlay` 微粒纹理（塑料→哑光，顺手消 banding）
- 在 `Sources/DesignSystem/Visuals.swift` 新增 `GrainOverlay`：`Canvas` 随机 1px 点，`opacity 0.015…0.04`，`.blendMode(.overlay)`（只扰明度不改色相）、`.allowsHitTesting(false)`、`.drawingGroup()`。
- 挂载：`AppBackground` 最上层 `opacity(0.5)`；大面积实色处（`XIconTile` 渐变底、按钮胶囊、`XEmptyState` 染色圆）共享 `.overlay(GrainOverlay().opacity(0.4))`。
- **陷阱**：别整页高密度点（性能/颗粒过粗）；overlay 混合模式在纯黑底会偏灰，确认暗色下是「哑光」而非「起雾」。

### P0-4 修 3 处系统控件残留（消除唯一「旧 macOS 观感」）
- `Sources/Features/MonitorView.swift`（约 :62/:171/:327）：系统 `.pickerStyle(.segmented)` → 自家 `XSegmentedControl`（`Components.swift`）。
- `Sources/Features/SpaceLensView.swift`（约 :584）：系统 `ProgressView().controlSize(.small)` → `XSpinner`（`Visuals.swift`，品牌彗星环）。同文件 :717 已正确用 `XSpinner`，对齐它。
- `Sources/Features/PricingView.swift`（约 :309）：`.textFieldStyle(.roundedBorder)` → 自绘胶囊（`surfaceAlt` 底 + 品牌焦点环）。付费页零系统灰控件。

### P0-5 首帧 skeleton 替 `?? 0` 硬闪（廉价感第一来源）
- `Sources/Features/ScanViews.swift`（约 :506–:519）：`capacity`/`metrics` 为 nil 时不要 `?? 0` 直接渲染「0% / 0GB / 0 分」再跳真值。改为 `XSkeleton` 占位（环用 spinning 占位、数字用 `XSkeleton(width:120)`），拿到真值再 crossfade。世界级首帧从不显示假 0。

### P0-6 渐变预算铁律（去糖果风、保品牌）
- 立规矩并落地：**每屏渐变只留给唯一主角**（hero 环 / 主 CTA / 进度弧）；其余（卡头图标、导航瓦片、未选段、幽灵环轨道）一律 flat 主题染色。
- 具体：`XIconTile` 默认参数改为 `flat: true`；把 `XSectionCard` 卡头已有的 flat 染色扩为全局约定，逐屏清掉多余渐变。**保留招牌极光渐变作主角**，不是取消渐变，是收敛。

**P0 验收标准（做完必须自检并给我看）**
- 跑 `--shots`，覆盖 light + dark ×（至少 aurora / graphite / warmLuxe / jewel 四主题）出图。
- 目视确认：暗色渐变/大实色处无可见 banding、无颗粒过粗；三处系统控件全部替换（截图对比前后）；扫描首帧是 skeleton 而非 0 硬跳（给出首帧截图）；各屏每屏只剩一个渐变主角。
- 触感/音效在真机手动验证一次（列出触发点与实测感受）；Reduce Motion 开启后逐项确认降级生效。
- 报告改动文件清单 + 每项「为什么这让它更高级」一句话，然后**停下等我确认，不要继续 P1**。

---

## P1（每项半天～两天，P0 确认后再做）

### P1-1 MeshGradient 活极光 hero 底（补齐唯一缺席的现代手法）
- 重写 `AppBackground`（`Visuals.swift`，`if #available(macOS 15, *)` 带降级到现双 `RadialGradient`）：`MeshGradient(width:3, height:3, …, colorSpace:.perceptual)`，颜色复用品牌极光 `0x5478F0/0x8B6FE6/0xB873D8`（经 `XColor`），四角锁死、只微动中心控制点（`TimelineView(.animation)`，Reduce Motion 静止），`.blur(radius:40)` 糊掉 mesh 硬边。替换现同心圆 banding 源。
- 扫描稳态环背后、Onboarding hero、定价页也叠这层。**陷阱**：不 blur 会露硬边；中心点漂移幅度 ≤0.08 否则「果冻晃」；`.perceptual` 防暗色中段发灰。

### P1-2 S-A「空间湮灭」清理完成三幕（招牌截图分享点）
- 升级 `TaskCompletionView`（`SharedViews.swift` 约 :395）从四散爆炸 → 回收叙事：幕1（0–0.6s）碎片向中心吸入（ease-in）；幕2（0.6–0.8s）中心 radial 白闪 `scale 0→1.4 + opacity 1→0`，**同一帧齐发** `XSound.cleanDone` + `XHaptic.levelChange`；幕3（0.8s+）对勾 `celebrateSoft` pop + 数字 0→X count-up（ease-out cubic）。
- 配套令牌：`Tokens.swift` 新增 `XMotion.celebrateSoft = .spring(response:0.62, dampingFraction:0.55)`（两次可感余荡，沉稳非玩具）。
- **陷阱**：声/触/光务必落在同一 60ms 窗口；粒子留在 Canvas，30–40 颗、1.5s 自停、稳态零帧，不上 SpriteKit/CAEmitter。

### P1-3 SF Symbol 动画铺开（macOS 15+ 免费高级动效）
- `CategoryTile` done 时 `.symbolEffect(.bounce, value:status)`；`ResultGroupCard` chevron `.contentTransition(.symbolEffect(.replace))`；`XLiveDot` 旁 `.symbolEffect(.pulse)`。`XMetricCard.value`（约 23 处未覆盖）补 `.contentTransition(.numericText())`。

### P1-4 焦点环 + 全局快捷键（无障碍 + 键盘党口碑）
- 三套 ButtonStyle（`Components.swift` 约 :112/:169/:202）补 `.focusable()` + `@Environment(\.isFocused)` 画 2px 品牌描边（当前只处理 hover/pressed）。
- `RootView` 挂全局快捷键 ⌘R（扫描）/⌘⏎（执行）/⌘Z（撤销）。

**P1 验收标准**
- `--shots` 出图：MeshGradient hero 在 light/dark ×多主题下无硬边无 banding、色相跟品牌；给出 S-A 三幕的关键帧截图或录屏说明；焦点环在键盘 Tab 下可见（截图）。
- Reduce Motion 下 MeshGradient 静止、S-A 退化为淡入 + 直接显示终值。
- 稳态帧率自检（无扫描时应无持续重绘）。报告后停下等确认再进 P2。

---

## P2（打磨与全局玻璃，P1 确认后再做）

- **侧栏选中态升 `glassEffect` + `GlassEffectContainer`**（`RootView.swift` 约 :88）：选中态从「淡染胶囊」→玻璃药丸（仅 macOS 26），整组导航包容器让切换 morph；加大分组间距（`XSpacing.xl→xxl`），修 `brandHeader` 与首组标题挤间距（约 :159）；图标选中/hover 补 `symbolEffect`。
- **S-B 健康分登场**（`SharedViews.swift` 约 :639）：`phaseAnimator` 三阶段（seed→overshoot 1.06→settle），环 0→分用 `XMotion.gauge`；**≥85 分环色由中性 graphite 跃迁到品牌极光 + 一次 `.levelChange` 触感**。
- **S-C 六类落定光扫**（`SmartScanHub.swift` 约 :867）：六卡波次弹跳之上叠 45° 高光 sweep 掠过网格（≈300ms），终点配 `.alignment` 轻触感；窄窗单列补最小高度或改双列断点（约 :698 spotless 空态换 `FacetedSpark` 呼吸插画，`IconArt.swift`）。
- **定价/popover/菜单栏面板全面 Liquid Glass**（版本判定 + 回退）；推荐档 `planCard`（`PricingView.swift` 约 :158）加 `brandGradient` 描边发光 + `.scaleEffect(1.02)` + 顶部「最超值」ribbon。
- **`vividPalette` 随主题**（`SunburstView.swift`/`SpaceLensView.swift`）：切 warmLuxe/jewel 时色轮跟随主题基色相偏移，消除环图与全局暖调割裂；悬停/钻取严格贴 `XMotion.hover`/`settle`。
- **打磨项**：`XTransition.stagger` 自适应（`delay = min(0.05, 0.30/count)*index`，封顶 0.30s，防长列表拖沓）；双色发丝线（`hairline` + 其下 `0.5px .white.opacity(0.04)`）；`hoverLift` 升起时 `raised→overlay` 阴影插值联动；`XEmptyState` 宝石插画替 SF Symbol；⌘K 命令面板（可再后置到 P3）。

**P2 验收标准**：`--shots` 覆盖 light/dark ×八主题抽样，确认玻璃分层无「玻璃采样玻璃」、无辉光过度/材质滥用；侧栏选中态在 macOS 26 与低版本回退分支都成立；健康分 ≥85 阈值跃迁 + 触感在真机验证；透镜切暖色主题不再割裂。

---

## 协作节奏（务必遵守）
**只先做 P0 全部 6 项**，做完出 `--shots` 图 + 自检报告 + 改动文件清单，然后**暂停等我确认**。我确认后你再进 P1，同样做完停一次；再进 P2。任何一步遇到红线冲突（取色入口、版本判定、Reduce Motion、掉帧）先停下说明，不要自行绕过。
