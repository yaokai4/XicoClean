# Xico UI / 设计 / 体验 全面超越 CleanMyMac · 升级方案（2026-07）

> 目标：在 **美观 · 精致度 · 高级感 · 用户体验** 四个维度全面超越 CleanMyMac（CMM）。
> 本方案由 7 个智能体并行调研产出：审计 Xico 现有设计系统 + Web 调研 CMM 最新 UX（2025–2026）+ 顶级参照 App（Linear/Raycast/Arc/Things/macOS Tahoe）+ 高级感工艺（材质/渐变/配色/字体）+ 精致度与惊艳时刻（动效/招牌/触感/声音）。
> 所有锚点为真实文件/类型/API。配套「可直接粘贴给 Claude Code 的实施提示词」见 [`docs/16a`](16a-UI设计升级-CC提示词.md)。

---

## 〇、核心判断（先看这一段）

**Xico 的静态设计功力已站在同类工具顶端，多处优于 CMM 的「干净塑料」审美**——字号系统、双层投影、高程双通道、连续曲率(.continuous)、珠宝色工程、matchedGeometry 转场都是**世界级**。所以「超越 CMM」的路径**不是加更多粒子、更花的 3D**，而是踩在 CMM 的**四个结构性盲区**上：

| CMM 盲区 | Xico 现状 | 做了就是代差 |
|---|---|---|
| **① 触感 haptic** | 全仓 0 处 `NSHapticFeedbackManager` | CMM 完全没有——最强差异化，代码量极小 |
| **② 有质感的材质** | 无 grain 噪点、无 MeshGradient、`.blur` 仅 2 处 | 塑料感的本质是「过于干净的数字平滑」，1–3% 微粒把渲染图变实物照片 |
| **③ 声/触/光对齐的统一招牌时刻** | 视觉招牌已达标，但三感各自为政 | 三感齐发同一 60ms 窗口=大脑绑成一个事件（Taptic 上瘾机制） |
| **④ 深色 + Liquid Glass** | Liquid Glass 仅菜单栏卡片用到 | CMM 用自研 3D 塑料贴图、**未上 Liquid Glass**，深色是其弱项 |

**一句话战略**：不与 CMM 正面碰它的护城河（情绪化关怀 + Smart Care 单页流）；用「**触感 + grain/mesh 物质感 + 声触光统一招牌 + 全局原生玻璃深色招牌 + 全程零打扰**」这五条踩在其明确空档上的路径，把「渲染图般干净」推进到「实物般高级」。

---

## 一、设计北极星

**一句话定位**：Xico 是「**桌面之上的一件珠宝级精密仪器**」——把 Mac 维护做成冷静、克制、可信赖的专业动作，而非一场热闹的情绪表演。

**三关键词**：**克制（Restraint）· 原生（Tahoe-native）· 物质感（Materiality）**

**凭什么比 CMM 更高级——差异化立场（四条对位）：**

| | CleanMyMac 5（2024-10 重设计） | Xico 的反向立场 |
|---|---|---|
| 气质 | 「情绪化关怀」+ 3D 动画玩具 + 拟人营销（官方明说基于「情绪旅程研究」） | **珠宝级冷静克制**：一处强调色 + 大片带主题偏的冷灰，读起来像工程文档而非糖果盒 |
| 材质 | 自研 3D 塑料光泽贴图，**未上 Liquid Glass** | **2026 原生玻璃 + 深色招牌**：真玻璃实时折射 vs 贴图光泽 |
| 动效 | **默认盛大**，重到必须出 Reduce Motion 开关 | **默认克制、峰值盛大**：只在「有确定后果」时爆发，规避 CMM 的动效疲劳 |
| 打扰 | 打扰式通知 + 激进升级引导（多篇评测点名） | **全程零打扰**：不打扰本身就是高级感与信任 |

---

## 二、要超越的清单（CMM 有的 → Xico 现状 → 如何更好）

| # | CMM 做得好/有的 | Xico 现状（file/类型） | 我们如何更高级 |
|---|---|---|---|
| 1 | 3D 动画界面（塑料贴图光泽） | `VisualEffect.swift:57` `xFloatingGlass` 已有 macOS 26 `glassEffect` 分支，但**仅菜单栏卡片用到** | Liquid Glass 提为全局材质（侧栏选中态/定价卡/popover），真玻璃镜面折射 vs 贴图 |
| 2 | Space Lens 气泡图（好看，信息效率一般） | `SunburstView.swift` + `TreemapView.swift` 双视图 + APFS clone 去重 | 主推 sunburst/treemap 专业双视图，信息密度与准确度压制气泡，且随 8 套主题换色 |
| 3 | Smart Care 单页流（心智极简，强） | `SmartScanHub.swift` 六类并行中枢（已具备） | **保持单入口叙事，不硬碰这条护城河**，赢在材质/动效/触感层 |
| 4 | 氛围化 3D 扫描动画 + 声音 | `ScanAmbience` 三道声呐环 + S3 matchedGeometry orb→环 + `XSound`×6 | 已同级/局部超越；**补触感 + 统一声/触/光**即拉开 |
| 5 | 菜单栏健康 Tile + 实时监控 | 菜单栏页 + Liquid Glass 卡片、`MonitorView`/`HardwareView` | Liquid Glass + `scrollEdgeEffectStyle(.hard)` 做「更原生的 iStat」 |
| 6 | 专业签名音效 | `XSound.swift` 架构完美，但**当前是系统内置音占位**（Tink/Glass/Pop，TODO 已注明） | 换 3 条定制资产，零代码只改 name 映射——唯一「听起来像别人家」的点 |
| 7 | 触感反馈 | **全仓 0 处** | 新增 `XHaptic` 令牌，挂完成/拖拽吸附/阈值跨越——CMM 完全盲区 |
| 8 | 材质细节 | 无 grain、无 MeshGradient | 全屏 grain（`.blendMode(.overlay)`）+ MeshGradient 活极光底 |

---

## 三、设计系统层升级（地基，影响全局）

> 原则：**新增令牌与现有体系对称**（`XHaptic` 对齐 `XSound`/`XMotion`），**不推翻已达世界级的部分**（双层投影/高程双通道/连续曲率/珠宝色工程——重构风险 > 收益）。

### 3.1 新增/增强令牌（含可粘贴代码）

**① `GrainOverlay`（新增 `Visuals.swift`）— P0，单点最强性价比**
```swift
struct GrainOverlay: View {
    var body: some View {
        Canvas { ctx, size in
            for _ in 0..<Int(size.width * size.height / 900) {
                let x = CGFloat.random(in: 0..<size.width)
                let y = CGFloat.random(in: 0..<size.height)
                ctx.fill(Path(ellipseIn: CGRect(x: x, y: y, width: 1, height: 1)),
                         with: .color(.white.opacity(Double.random(in: 0.015...0.04))))
            }
        }
        .blendMode(.overlay)        // 只扰明度不改色相
        .allowsHitTesting(false)
        .drawingGroup()             // 栅格化一次，滚动零重算
    }
}
```
挂 `AppBackground` 最上层 `opacity(0.5)`；大面积实色处（`XIconTile` 渐变底、按钮胶囊、`XEmptyState` 染色圆）共享 `.overlay(GrainOverlay().opacity(0.4))`。**顺手消灭暗色渐变 banding**。塑料感的本质是「过于干净的数字平滑」，真实材质都有微粒——这是把 Xico 与 CMM「干净塑料」拉开档次的单点最强手段。

**② `XHaptic`（新增 `Infrastructure/`，与 `XSound` 同目录）— P0**
```swift
NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
```
封装 `.levelChange`（跨台阶）/`.alignment`（拖拽吸附，Apple 专为此设计）/`.generic`；全局可关（`xico.haptics.enabled` 默认 true）、系统自动降级。**铁律：比声音还克制——危险操作（粉碎/删除）永不配触感，hover/滚动永不配。**

| 触发点 | pattern |
|---|---|
| 清理完成（S-A 幕2） | `.levelChange` |
| 健康分跨过优秀阈值 | `.levelChange` |
| 文件拖入收集篮吸附 | `.alignment` |
| 六类落定 sweep 终点 | `.alignment`（轻） |

**③ `XMotion.celebrateSoft`（增强 `Tokens.swift:338`）**：`.spring(response:0.62, dampingFraction:0.55)`——0.55 阻尼让主数字/对勾落定有两次可感余荡（沉稳有生命 vs iOS `.bouncy` 玩具感）。

**④ `XTransition.stagger` 自适应（`Tokens.swift:354`）**：改 `delay = min(0.05, 0.30/count)*index`，封顶 0.30s，防 50 行列表累积到 2.5s 拖沓。

**⑤ MeshGradient 品牌背景（重写 `AppBackground`，`Visuals.swift:5`，macOS 15+ 带降级）**：
```swift
if #available(macOS 15, *) {
    MeshGradient(width: 3, height: 3,
        points: [[0,0],[0.5,0],[1,0],
                 [0,0.5],[0.5 + 0.08*sin(t*0.3), 0.5 + 0.08*cos(t*0.4)],[1,0.5],  // 只动中心点
                 [0,1],[0.5,1],[1,1]],
        colors: [/* 复用品牌极光 0x5478F0 / 0x8B6FE6 / 0xB873D8，经 XColor */],
        colorSpace: .perceptual)      // 暗色中段不发灰
    .blur(radius: 40)                 // mesh 硬边必须糊
}
```
只微动中心控制点、四角锁死（`TimelineView(.animation)`，Reduce Motion 静止）。**替换现双 RadialGradient**（消同心圆 banding）。品牌色从「两颗可辨识光斑」变成「整屏若有若无的场」——Apple Intelligence 光晕、Vision Pro 环境光那种「贵」的来源。

### 3.2 破了自家语言的一致性硬伤（P0，纯修复，立竿见影）

| 位置 | 现状 | 改为 | 为什么 |
|---|---|---|---|
| `MonitorView.swift:62/171/327` | 系统 `.pickerStyle(.segmented)` | `XSegmentedControl`（`Components.swift:242`） | 全 app 唯一「macOS 13 观感」残留 |
| `SpaceLensView.swift:584` | 系统 `ProgressView().controlSize(.small)` | `XSpinner`（`Visuals.swift:150`，品牌彗星环） | 高级环图嵌系统菊花=拼接感（同文件 :717 已正确用 `XSpinner`，自相矛盾） |
| `PricingView.swift:309` | `.textFieldStyle(.roundedBorder)` 灰框 | 自绘胶囊（`surfaceAlt` 底 + 品牌焦点环） | 付费转化页最不该出现系统灰控件 |

### 3.3 ⭐ 全案最重要的战略取舍：渐变预算（Gradient Budget）

Xico 的品牌根基**就是**极光渐变 + 8 套主题，不能照搬「flat 默认」；但也不能放任「彩虹用太多」——**立规矩**：

> **每屏渐变只留给唯一主角**（hero 环 / 主 CTA / 进度弧）；其余一切（卡头图标、导航瓦片、未选段、幽灵环轨道）一律 flat 主题染色。`XIconTile` 默认改 `flat:true`；`XSectionCard` 卡头已是 flat 染色（方向对），扩为全局铁律。

**为什么**：既保住品牌识别（主角仍是招牌极光），又避免「彩虹显廉价」——**克制才是奢侈**。这是反超 CMM 紫调糖果风最快的一招，且不牺牲自我。

### 3.4 组件与细节增强

- **Liquid Glass 分层契约**：MeshGradient 铺**内容层背景**，`glassEffect` 只上**悬浮导航层**（收集篮/钉住面板/侧栏选中态）——`VisualEffect.swift:56` 铁律「内容层禁上玻璃」保留；多玻璃元件用 `GlassEffectContainer(spacing:)` 分组（玻璃不能采样玻璃）。
- **SF Symbol 动画铺开**（全仓仅 1 处）：`CategoryTile` done 时 `.symbolEffect(.bounce, value:status)`、`ResultGroupCard` chevron `.contentTransition(.symbolEffect(.replace))`、`XLiveDot` 旁 `.symbolEffect(.pulse)`——macOS 15+ 免费高级动效。
- **焦点环统一**（`Components.swift:112/169/202`）：三套 ButtonStyle 只处理 hover/pressed，补 `.focusable()` + `@Environment(\.isFocused)` 画 2px 品牌描边——无障碍审计最常见失分点。
- **`hoverLift` 联动阴影散开**（`Motion.swift`）：升起时 `raised → overlay` 插值——物体离桌面越远接触影越淡越散，交互时的光学诚实。
- **双色发丝线**：关键分隔（操作条顶沿/卡内分区）升级 `hairline` + 其下 `0.5px .white.opacity(0.04)`——单色发丝线在暗底会「消失或死板」。
- **`XEmptyState`/spotless 用宝石插画替 SF Symbol**：换呼吸的 `FacetedSpark`（`IconArt.swift:66`，品牌已有语言）——定制插画是 Linear/Notion 空态的高级感来源。

---

## 四、高级感工艺手册（材质 / 配色 / 字体 / 细节）

### 4.1 材质与景深
- **已做对（勿动）**：`XSurface` 三档语义 + `xFloatingGlass` 的 macOS 26 分叉、`xHardScrollEdges()` 用 `scrollEdgeEffectStyle(.hard)` 防数据密集页边缘被渐进模糊吃掉——教科书级。
- **可进一步**：侧栏「背景大玻璃 + 前景选中项小玻璃」双层景深（`GlassEffectContainer` 让选中项切换 morph）；`xFloatingGlass` 低版本分支补方向性内高光（现只有单色描边）；`XSurface` 增 `.panel → .regularMaterial` 档给菜单栏这类**持久面板**（`.ultraThinMaterial` 留给 toast 这类短暂浮层）。

### 4.2 配色高级感（Xico 的强项）
- **已做对**：中性色是「选择而非默认」（`textSecondary 0x666C80` 带蓝紫偏冷灰）；珠宝色 vs 糖果荧光的自觉（`ringRose/Lav/Peri/Mint` 注释明写「更沉的珠宝色相去糖果塑料感」）；暗色高程双通道（`surfaceResting/Raised/Overlay` +1.5%/3%/5% 混白 + 顶部内高光）——暗色高级感核心机制，教科书级；`textTertiary` 有 WCAG 对比度台账。
- **可进一步**：把「暖色不脏不土五铁律」写成 `Theme.swift` 顶部注释契约 + DEBUG 断言（①推明度不推饱和 ②金压在 36–42° 死区外 ③暖色配冷墨底 ④相邻指标色相 ≥52° ⑤每套一枚冷宝石破红绿盲）；浅色卡补底部 1px 内阴影制造「凹进纸面」的接触感（浅色是高级感照妖镜，靠内衬光影而非描边撑纵深）。

### 4.3 字体排版（罕见的严谨）
- **已做对**：`XFont` 1.25 模数 + 圆润等宽数字 + `XScaledFont` Dynamic Type + 负字距锚点（大字紧 `-0.5`、标签松 `+1.0` uppercase）。
- **可进一步**：大数字内部分级字重（「88」`.bold` + 「%」`.medium`+`textSecondary`，Apple 电池/存储大数字同款「主数字满重、单位降重降色」）；多行标题统一测量宽度 ~340pt 防孤字（widow）；两处大写小标字距统一到 `1.0`。

### 4.4 细节质感（Xico 的隐形护城河，几乎满分）
- **已做对（须表扬勿动）**：连续曲率 `.continuous` 全覆盖、双层投影（环境光柔影+接触实影）、1px 方向性内高光、发丝分隔收编魔法 alpha、按钮哑光高光收敛（`.white.opacity(0.13)` 到 center）。
- **可进一步**：见 §3.4（grain 收尾、hover 阴影联动、双色发丝线、焦点环）。

---

## 五、动效与 Xico 专属招牌惊艳时刻

> 取舍：全部留在现有 `Canvas`+`TimelineView`，**不上 SpriteKit/CAEmitterLayer**——`XCelebrationBurst` 已证明 Canvas 30–40 粒子能耗可控（1.5s 自停、稳态零帧）；CAEmitter 与 Liquid Glass 混排 z-order/色彩不可控。

**动效底座已追平/超越 CMM**（按压反馈、skeleton shimmer、toast、`.numericText` 数字滚动、S3 matchedGeometry、KeyframeAnimator、`XCelebrationBurst` 全部达标）。真正的空档只有 4 个：触感、MeshGradient、定制音效资产、招牌时刻的叙事升级。

### ⭐ S-A「空间湮灭」清理完成时刻（首推，可截图分享）
现状 `TaskCompletionView`（`SharedViews.swift:395`）是 30 粒子**四散爆炸**——语义是「消失」。升级为**三幕叙事**（CMM 没有的「回收」隐喻）：
- **幕1（0–0.6s）汇聚**：碎片从四周向中心吸入（`dist=150*gather²`，ease-in）
- **幕2（0.6–0.8s）闪光**：中心 radial 白闪 `scale 0→1.4 + opacity 1→0`，**同一帧齐发** `XSound.cleanDone` + `XHaptic.levelChange`
- **幕3（0.8s+）释放**：对勾 `celebrateSoft` pop + 数字 0→X count-up（ease-out cubic）

**为什么越级**：声/触/光对齐同一 60ms 窗口=大脑绑成一个事件（Taptic Engine 上瘾机制）；「汇聚→转化→迸发」是有意义的回收叙事，不是无意义四散。CMM 只有视觉。

### S-B「健康分登场」（`SharedViews.swift:639`）
`phaseAnimator` 三阶段（seed→overshoot 1.06→settle）；环 0→分数用 `XMotion.gauge`，中心数字 `.numericText()` 同步滚动；**≥85 分时环色由中性 graphite 跃迁到品牌极光 + 一次 `.levelChange` 触感**——把「跨过一道坎」物理化。数字应「当着你的面被算出来」，不是「已经在那儿」。

### S-C「六类落定」光扫（`SmartScanHub.swift:867`）
六卡波次弹跳之上叠一道 45° 高光 sweep 掠过网格（≈300ms），终点配 `.alignment` 轻触感。六卡各自弹跳是「点」，一道扫过全局的光是「面」——面级动效给「一览无余、大功告成」的整体收束感，CMM 逐条打勾没有。

### 声音资产升级
`XSound` 架构完美但当前是系统内置音占位（Tink/Glass/Pop，TODO 已注明）。换 3 条定制资产：`scanDone` 高频叮（<200ms 无混响）/`cleanDone` 玻璃水滴（略带尾韵暗示「干净」）/`countdownDone` 低频确认。零代码只改 name 映射——唯一在盲测里会「掉一档」的点。

### 键盘/无障碍即体验
全局快捷键 ⌘R（扫描）/⌘⏎（执行）/⌘Z（撤销）；焦点环补齐（见 §3.4）；招牌时刻 `AccessibilityNotification.Announcement("已释放 3.2 GB")` 让盲用户也「听到」结果；MeshGradient/glass 加 `@Environment(\.accessibilityReduceTransparency)` 判定退实色底。

---

## 六、屏幕级升级（逐屏）

- **侧栏（`RootView.swift:88`，已精致）**：选中态从「淡染胶囊」升级为 `glassEffect` 玻璃药丸（macOS 26），整组导航包 `GlassEffectContainer(spacing:8)` 让切换 morph——**选中态从「涂色」升「材质」**；加大分组间距（`XSpacing.xl→xxl`，Arc 式呼吸）；修 `brandHeader` 与首组标题挤间距（:159）；图标补 `symbolEffect`。
- **Onboarding（`OnboardingView.swift`，全 app 最惊艳之一）**：底子已顶级（KeyframeAnimator 多轨 logo + 真组件缩影非贴图）；hero 背景叠 MeshGradient 活极光；`readyStep` 补一次宝石呼吸。
- **定价页（`PricingView.swift`，专业但缺卖相）**：推荐档 `planCard`（:158）加 `brandGradient` 描边发光 + `.scaleEffect(1.02)` + 顶部「最超值」渐变 ribbon；激活输入换自绘胶囊（:309）；macOS 26 开 `glassEffect`。**付费转化页零系统灰控件**。
- **扫描态/结果（`ScanViews.swift`+`SharedViews.swift`，招牌级）**：**P0 修首帧硬闪**（:506–519 `?? 0` 直接渲染「0%/0GB/0 分」再跳真值→换 `XSkeleton`，世界级首帧从不显示假 0）；主 296pt 稳态环背后叠 MeshGradient；`XMetricCard.value` 补 `.numericText()`（23 处未覆盖）。
- **智能中枢（`SmartScanHub.swift`，很强）**：六卡波次弹跳 + S-C 光扫；窄窗单列 tile 略空——补最小高度或改双列断点；spotless 空态（:698）换 `FacetedSpark` 呼吸插画。
- **空间透镜（`SpaceLensView`/`SunburstView`，DaisyDisk 级）**：修系统菊花；**`vividPalette` 随主题走**——切 warmLuxe/jewel 暖调时环图仍固定蓝紫玫青彩虹、与全局暖调割裂，应让色轮跟随主题基色相偏移。
- **监视/硬件（`MonitorView`/`HardwareView`，专业）**：修 `.segmented`；深色 `XCard` 叠 grain 消塑料感；hover 给环一次呼吸。

---

## 七、分期路线 P0 / P1 / P2

### P0（半天～一天/项，立见高级感，先做这一批然后停）
| 事项 | 涉及文件 | 越级点 |
|---|---|---|
| `XHaptic` 令牌 + 接入完成/拖拽/阈值 | 新增 `Infrastructure/XHaptic.swift` + 调用点 | CMM=0，最强差异化 |
| 定制 3 条音效资产 | `XSound.swift` + bundle | 消除唯一掉档点 |
| `GrainOverlay` + 大面积实色叠 grain | `Visuals.swift`(新) + AppBackground/XIconTile/按钮 | 塑料→哑光，顺手消 banding |
| 修 3 处系统控件残留 | MonitorView/SpaceLensView/PricingView | 消除唯一「旧 macOS 观感」 |
| 首帧 skeleton 替 `?? 0` 硬闪 | `ScanViews.swift:506` | 廉价感第一来源 |
| 渐变预算铁律（flat 默认） | `XIconTile`/Tokens/全局 | 去糖果风、显专业，保品牌 |

### P1（每项半天～两天，P0 确认后再做）
MeshGradient 活极光 hero 底（带降级）· S-A 湮灭三幕 + `celebrateSoft` · SF Symbol 动画铺开 · 焦点环 + 全局快捷键 ⌘R/⌘⏎/⌘Z

### P2（打磨与全局玻璃）
侧栏选中态升 `glassEffect` + `GlassEffectContainer` · S-B 健康分 `phaseAnimator` 登场 + 阈值跃迁 · S-C 六类落定光扫 · 定价/popover/菜单栏面板全面 Liquid Glass · `vividPalette` 随主题 · 打磨项（stagger 自适应、双色发丝线、hoverLift 联动阴影、宝石空态插画、⌘K 命令面板）

---

## 八、超越计分卡（四维 vs CMM）

| 维度 | CMM 水平 | Xico 赢法 | 判定 |
|---|---|---|---|
| **更好看** | 浅色通透 + 3D 塑料光泽，暖度用力过猛（被吐槽 bubbly/悬浮侧栏 off） | MeshGradient 活极光 + grain 哑光物质感 + 渐变预算克制；**深色 + Liquid Glass 招牌**（CMM 弱项） | ✅ 深色正面超越，浅色靠内衬光影打平 |
| **更精致** | 干净但塑料，圆角/材质偏光滑 | 双层投影 + 高程双通道 + 连续曲率 + 珠宝色工程（**已优于 CMM**）+ 补 grain/双色发丝/分级字重 | ✅ 已领先，补最后一公里即碾压 |
| **更高级感** | 情绪营销 + 奖状叙事，但通知打扰伤信任 | 珠宝级冷静克制 + 全局原生玻璃 + 建筑感排版（巨数字×微标签 5:1）+ **全程零打扰** | ✅ 立场差异化，不硬碰其体验公理 |
| **更好用** | 单页流心智极简（强）+ 声音，但**无触感、动效过载** | 保单入口叙事 + **触感开辟新维度** + 声/触/光统一招牌 + 默认克制峰值盛大 + 键盘优先 | ✅ 触感是结构性代差，做了就赢 |

**结论**：P0 六项均为半天到一天、立见高级感的高性价比动作，建议一个冲刺内全部落地；触感（P0）+ grain/mesh（P0/P1）+ 声触光统一招牌（P1）是踩在 CMM 明确空档上的越级路径。

---

## 附：红线（实施时不可违反）

1. 单一取色入口 `XColor`，禁止裸 `Color(hex:)`，新色走 `dynamic(light:dark:)`。
2. 令牌化不硬编码（间距/圆角/字阶/投影/动效/透明度）；新增动效/触感/材质也落成令牌。
3. 深浅色双写，暗色不 banding。
4. Reduce Motion 降级（MeshGradient/幽灵环静止、粒子叙事退淡入、count-up 直接显终值）。
5. 性能不掉帧：`Canvas` 噪点/粒子 `.drawingGroup()` + `.allowsHitTesting(false)`，稳态零重绘、零 `TimelineView` 空转。
6. 无障碍不回退：焦点环/触感不破坏 VoiceOver/键盘/对比度；触感全局可关随系统降级。
7. macOS 26 Liquid Glass 必须 `if #available(macOS 26, *)` + 低版本 `xFloatingGlass` 回退（回退也要方向性内高光）；内容层禁上玻璃，多玻璃 `GlassEffectContainer` 分组。
8. 不推翻已达世界级的部分（双层投影/高程双通道/连续曲率/珠宝色工程/matchedGeometry）——只叠加增强。

**关键文件索引**：`Sources/DesignSystem/{Tokens:338,Theme,Components:112/169/202/242/521,Visuals:5/150,VisualEffect:56,Motion:238,IconArt:66}.swift`；`Sources/Features/{RootView:88,OnboardingView:68,PricingView:158/309,ScanViews:506,SharedViews:395/639,SmartScanHub:698/867,SpaceLensView:584,SunburstView,MonitorView:62/171/327}.swift`；`Sources/Infrastructure/XSound.swift`（`XHaptic` 建议同目录）。
