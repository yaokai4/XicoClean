# Xico Smart Scan Experience 2.0 设计规格

> 日期：2026-07-18  
> 状态：已确定方向，等待书面规格复核后进入实施计划  
> 所属总目标：Xico 95+ 全产品升级计划  
> 第一可见里程碑：首页、智能扫描过程、结果与后续工具发现

## 1. 决策与背景

本里程碑选择“主旅程优先”，而不是先做全局换肤或单独强化 Space Lens。原因是用户当前最强烈的问题不是功能缺失，而是已经完成的功能没有形成可见、可理解、可感知的产品价值。当前安装版 build 152 的 Smart Scan 首页仍以大圆环、三张小指标卡、长侧栏和单一“开始智能扫描”按钮为主；它不能回答用户打开软件后的四个核心问题：

1. 我的 Mac 现在有什么问题？
2. Xico 能为我改善什么？
3. 扫描正在做什么，结果是否可信？
4. 完成以后具体变好了多少，接下来还能做什么？

本设计保留现有扫描引擎、`SmartScanHubViewModel`、诚实结果 reducer、安全边界和 11 语言体系，重做其上层的信息架构、视觉层级、状态叙事、功能发现与交互动效。它是首个肉眼可见的产品里程碑，不代表 95+ 总计划或所有页面已经完成。

## 2. 设计北极星

Xico 是“桌面之上的珠宝级精密仪器”：冷静、可信、原生、有物质感，但不会像概念稿一样堆满辉光，也不会像玩具一样用无意义动画掩盖结果。

设计约束：

- 每屏只允许一个渐变主角；其余图标、标签和次级操作使用语义化扁平色。
- 视觉重点必须对应真实信息：空间、进度、风险、完成事实或下一步行动。
- 动效必须解释状态变化，不做常驻无意义运动。
- 只有 reducer 判定的真实完整成功可以触发成功声音、触感和招牌完成动效。
- 所有失败、取消、部分成功和不确定状态必须保持诚实，并保留重试或撤销路径。
- Light 与 Dark 都是第一等主题；不得用低对比雾光掩盖信息。
- Reduce Motion、Reduce Transparency、Increase Contrast、键盘、VoiceOver 和 11 语言不是后补项。

## 3. 备选路线与选择

### 路线 A：主旅程优先（采用）

重做首页、扫描、复核、执行结果与工具推荐。优点是用户打开 App 后立即看到变化，并能理解已经开发的功能。代价是需要同时处理多个 UI 状态和确定性截图 fixture。

### 路线 B：全局外壳优先（暂后置）

先统一侧栏、导航、工具栏、卡片和排版。优点是全 App 一致；缺点是核心价值叙事不变，用户仍可能觉得只是换皮。

### 路线 C：视觉奇观优先（暂后置）

先强化 Space Lens、粒子和大型动画。优点是展示效果强；缺点是主扫描体验仍旧，且容易让装饰领先于可信结果。

## 4. 成功标准

本里程碑只有在以下条件同时成立时才算完成：

- 用户在首页 5 秒内能说出当前健康状态、预计可改善项和主操作。
- 用户无需滚动长侧栏即可找到 Smart Scan、卸载器、Space Lens、维护和全部工具入口。
- 扫描期间能看到类别完成度、当前阶段、六类子任务状态、累计发现和安全取消入口。
- 结果页能区分“安全且可撤销建议”“需要确认的不可逆/风险项”“仅供参考或不确定项”，并解释默认选择。
- 完成页分别显示成功处理大小、同卷可用空间变化（可取得时）、实际处理数量、失败或跳过数量、撤销状态和下一步建议。
- 新功能不是只有侧栏名称，而是在上下文中展示用途、收益和明确 CTA。
- idle、scanning、review、executing、success、partial、failure、cancelled、uncertain 九种状态均有真实渲染证据。
- 1080×640 最小窗口与常用大窗口均无截断、重叠或必须横向滚动。
- Light/Dark、11 语言、键盘、VoiceOver、Reduce Motion/Transparency 和 Increase Contrast 通过验收。

## 5. 信息架构

### 5.1 全局框架

继续使用原生 `NavigationSplitView`，不重建系统侧栏。侧栏从“所有功能平铺成长列表”调整为三层：

1. **今天**：智能扫描、最近结果。
2. **常用工具**：根据最近使用和当前问题固定展示最多四项，默认包含卸载器、Space Lens、维护。
3. **全部工具**：打开可搜索的工具总览，不在主侧栏永久铺满所有模块。

侧栏宽度保持 232–300pt 的现有约束。品牌头缩短纵向占用，磁盘摘要保留在底部，但只显示一个诚实指标和明确标签。设置继续使用底部原生入口，不与工具模块争夺信息层级。

### 5.2 首页结构

首页使用一个稳定的内容框架，不在状态切换时整体替换根布局：

1. 顶部 56pt **Today Bar**：设备名、最近一次已验证操作的时间、搜索或命令入口。没有可信扫描快照时不得显示“最近扫描”或沿用旧扫描估算。
2. 中央 **Scan Instrument**：唯一渐变主角，按当前阶段只展示一个可信主事实：idle 显示“需要扫描”、scanning 显示真实进度、review 显示当前已选预计空间、terminal 显示实际结果。不得在扫描前猜测可释放空间，也不得同时混用已用率与可用空间。
3. 右侧/下方 **Insight Stack**：最多三条可操作洞察，例如“磁盘空间偏紧”“有 6 个大型应用”“维护已 14 天未运行”。
4. 底部 **Tool Discovery Rail**：最多三张上下文工具卡，说明功能、预期收益和动作，不重复堆叠所有模块。

在 1080pt 最小宽度，Scan Instrument 与 Insight Stack 使用 2:1 双列；空间不足时工具卡横向压缩为一行摘要，不能把主 CTA 推出首屏。

### 5.3 状态流

```text
idle → scanning → review → executing → terminal
                                  ├─ success
                                  ├─ partial
                                  ├─ failure
                                  ├─ cancelled
                                  └─ uncertain
```

`idle`、`scanning`、`review`、`executing` 和 `terminal` 共用同一内容骨架。中央仪表、洞察区域和操作条在位置稳定的前提下改变内容，避免整页闪切和用户视线丢失。

新展示状态不成为第二个业务状态机，而是严格从现有 hub 事实推导：

- `idle`：`phase == .idle`；
- `scanning`：`phase == .active && !allDone && !cleaning`；
- `review`：`phase == .active && allDone && !cleaning`，其中 spotless、权限不足和显式取消是 review 的具名变体；扫描取消必须由新的闭合 `ScanSessionTermination.userCancelled` 事实表达，不能解析本地化错误字符串；
- `executing`：`phase == .active && cleaning`；
- `terminal`：`phase == .finished && outcomeConsumption != nil`。先要求 `outcomeConsumption.isTrusted`，再复用唯一的 `TaskOutcomePresentation.make(context:)` 判定语义与副作用；未注册 kind、`internalInvariant`、`.possiblyChanged` 或任何 reducer/consumer 不一致一律使用现有“结果需要确认”语义并映射为 `uncertain`，其优先级高于原始 status；其余 success/partial/failure/cancelled 直接来自 reducer status；
- 任何无法满足上述映射的组合都进入 `uncertain` 展示，不从数量或文案反推成功。

允许动作同样来自现有 presentation/consumer capability：scanning 只允许取消；review 允许复核、选择、重扫和按现有安全门执行；executing 只允许 cooperative cancel；terminal 只显示已经解析为可执行的 retry/details/undo/recovery/done。展示层不得补造按钮或写回终态。

executing 具有一个不改变 Domain 终态的 UI 子事实 `cleanCancellationRequested`：用户点击取消时同步置为 true 并请求 cooperative cancel，随后禁用重复取消、显示“正在安全停止”；它绝不代表取消已经成功，也不提前改变 counts、selection 或 receipts。只有 reducer terminal 已安装，或新的 start/reset 开始时才清除该事实。

## 6. 页面与组件设计

### 6.1 Idle：首页

idle 阶段不猜测可释放空间，也不在本里程碑新增或持久化扫描结果缓存。中央仪表显示“准备检查这台 Mac”；可用磁盘空间只是次级上下文。若历史中存在已提交的真实清理记录，可以显示“上次成功处理 2.4 GB”，但必须同时显示发生时间，且不能把它当作本次预计值或可用空间增量。

idle 仪表只表达“扫描准备/覆盖需求”，不能用弧线同时表示磁盘已用率。进入 scanning 后，同一仪表才表达确定性扫描进度；进入 review 后表达当前已选预计空间，并明确标注“预计”。中心文案与弧线方向始终同义。

主按钮使用具体动词：“扫描这台 Mac”。按钮下方用短句交代“六类检查、本地完成、确认前不修改文件”。不再把六类模块名称压成一行小字。

Insight 卡必须包含：状态图标、结论、证据数字、动作。禁止只有装饰性图标和标题。

### 6.2 Scanning：扫描过程

Scan Instrument 从 idle 的静态仪表原位变形成扫描仪表，不跳到另一张页面。它展示：

- 确定性的“已落定 n/6 类”，而不是伪造的时间百分比；
- 当前读取或检查的对象类别；
- 累计发现的逻辑大小与项目数，明确标注“预计”而非“已释放”；
- 暂停不可用时的“正在安全停止”状态，而不是按钮立即消失。

六类任务以 2×3 状态矩阵呈现，每项使用闭合状态：等待、运行、完成、需要注意、已取消。主仪表只按落定类目数表达类别完成度；单类扫描器若提供同一轮、单调且 0…1 的 `ScanProgress.fraction`，该 tile 可以显示自己的局部进度，否则显示 indeterminate。只有未来所有 provider 都提供经过单调性、取消冻结和最终 100% 测试的归一化 work units 后，才允许增加总百分比。完成落定可以有一次轻微 symbol bounce；失败、取消或需要注意不能使用成功色或庆祝动画。

### 6.3 Review：结果复核

结果顶部先给结论，再给细节，且把可撤销与不可逆口径分开：

- 标题：“已选可撤销项预计 6.4 GB”；
- 副标题：“另有 2.0 GB 永久操作和 3 项风险内容需要确认”；
- 安全说明：“确认前未修改文件”。

结果分为三组：

1. **安全且可撤销建议**：只包含 `safety == .safe`、assessment 满足自动选择资格、`!requiresHelper`、`!isInformational`，且实际 `CleaningPlan.intent == .trash` 的项目；默认选择并展示规则依据。
2. **需要确认**：任何 `.permanent`（包括清空废纸篓和 requiresHelper）、caution/risky 或高危类目项目；默认不选，展示原因、位置类型、不可逆性和二次确认。实施时必须把当前可能默认勾选的永久项目改为显式选择，并以 RED 测试锁定。
3. **仅供参考/未处理/不确定**：informational、覆盖不完整、权限缺失或不可信项目；不可选择，也不可混入任何预计可处理总量，提供正确处置、重新扫描或查看详情动作。

可撤销预计、不可逆预计和仅供参考体量必须分别汇总，不能合并成一个“可以安全释放”数字。

列表采用一个容器加分隔线，不把每一行做成独立浮卡。数字使用等宽字体并右对齐。底部操作条持续显示选中数量、预计空间、可撤销性和具体主动作。

### 6.4 Executing：执行

执行阶段不复用扫描文案。主状态使用“正在安全处理”，逐项事实来自现有 `CleaningReport`/operation result。取消动作必须反映真实边界：若已发生变更，界面显示“正在停止，部分项目可能已经移动”，不能假装全部未变化。

首次取消同步写入 `cleanCancellationRequested` 并禁用取消按钮；等待引擎返回期间仍属于 executing，不得提前跳到 cancelled、移除选择或播放终态反馈。只有 reducer-backed terminal 可以决定最终是 success、partial、failure 还是 cancelled。

### 6.5 Terminal：结果与下一步

完整成功：

- 显示 reducer-backed succeeded facts 的“成功处理大小”和实际处理数量；
- 仅当执行前后采样来自同一 volume identity 时，另行展示“系统可用空间变化”；读取失败、APFS 延迟或本地快照导致差异时显示解释，不画虚假前后对比；“成功处理大小”与“可用空间变化”不得互称；
- 若回执当前仍有效，提供“可撤销”；现有 `RestorableItem` 没有 expiry，因此不得显示剩余有效时间；
- 允许一次 1.6s 内自停的招牌完成动效。

Partial、failure、cancelled：

- 禁止成功粒子、成功声音和“全部完成”文案；
- 仅显示 reducer-backed requested/succeeded/unchanged/skipped/failed/cancelled counts；
- 保留可撤销回执、失败项重试和重新扫描入口；
- 不把预计空间或成功处理大小冒充系统可用空间变化。

Uncertain：

- 不显示 requested/succeeded/failed/skipped 或所谓“不确定数量”的任何聚合数字，因为触发 uncertain 的事实本身无法一致验证；
- 只显示“结果事实无法一致验证”和已经独立验证的 issue/recovery；若 consumer 仍持有经过严格验证的具体回执，可以保留相应撤销能力，但不能由回执数量反推整体结果；
- 除非 Domain 将来新增 reducer-backed `unknownCount`，否则 UI 永远不得捏造“不确定项目数”。

结果页底部给出最多两个上下文推荐，例如“大型应用占用较多 → 打开卸载器”“可用空间仍偏低 → 打开 Space Lens”。推荐必须来自本次结果事实，不能是固定广告轮播。

## 7. 功能可发现性

每个重要功能需要同时具备四个要素：名称、解决的问题、最近或预计收益、可执行入口。

实施新增 `ModuleID.allTools` 和 `AllToolsView` 作为纯导航目的地。工具总览从 `ModuleCatalog.all` 读取可直达模块，支持搜索和类别分组；它不执行扫描、删除或授权。冷启动时常用工具固定为卸载器、Space Lens、维护；之后由 `RecentToolStore` 记录最多 8 个 `ModuleID + lastOpenedAt`，只存模块标识与时间，不存路径、扫描结果或用户内容。排序顺序为：有当前确定性问题证据的推荐、最近使用、冷启动默认；同优先级按稳定 ModuleID 排序。

新增 `ToolRecommendation` 只承载 UI 展示事实，不持有执行闭包：

- `toolID`
- `reason`（闭合枚举）
- `evidence`（闭合的强类型值枚举）
- `priority`
- `destination`（闭合工具目的地枚举）

视图只通过现有模块路由解析 `destination`，不能让推荐对象执行扫描、删除或任意闭包。推荐的 reason/evidence 必须来自本地确定性事实，例如磁盘占用、已扫描应用大小、维护上次运行时间或实际扫描结果。不得为提高点击率伪造紧迫感。

每条推荐包含 evidence 的采集时间；证据缺失、过期或与当前 volume/session 不一致时隐藏。若多个 reason 指向同一工具，只保留优先级最高的一条，并合并为不超过两行的解释。每个 reason 至少有一个固定 fixture 和一个“无证据不显示”测试。

首页提供“本版本新增”入口，但最多展示三项；看过后降级为工具总览中的普通徽标。新功能说明使用“能做什么 + 何时使用”，不使用内部任务名或技术术语。

## 8. 视觉系统

### 8.1 色彩与材质

- 内容底使用主题化石墨/冷白语义色，保证文字与数据对比。
- 每屏唯一渐变用于 Scan Instrument 或当前主 CTA，二者不能同时大面积发光。
- 侧栏和工具栏使用系统材质；内容卡默认不叠 Liquid Glass。
- 自定义玻璃只用于悬浮操作、命令面板或选中态，并在 macOS 26 下使用系统 `glassEffect`。
- Light 模式减少大范围白雾和 blur；Dark 模式用高程差而不是荧光描边制造层次。
- 微粒纹理必须确定性生成并缓存，禁止每帧随机 Canvas 导致视觉闪烁和持续 GPU 消耗。

### 8.2 排版

- 页面主标题 22–28pt；结论数字 34–52pt；单位降一级字重与颜色。
- 所有 GB、MB、百分比、项目数使用等宽数字。
- 正文有效阅读宽度控制在 680pt；长副标题不得横跨整窗。
- 标签最多两级，避免当前 11–16pt 区间堆叠过多近似字号。

### 8.3 图标与插画

- 主界面移除与精密仪器气质不一致的像素机器人。
- 若助手功能保留，改为有明确用途、证据与 CTA 的上下文工具卡，不再以悬浮像素吉祥物遮挡主内容。
- 使用 SF Symbols、现有 FacetedSpark 和扫描仪表语言，保证同一产品家族。
- 彩色图标只表达状态；普通工具图标使用单色主题染色。

## 9. 动效规格

| 事件 | 时长 | 曲线 | 行为 |
|---|---:|---|---|
| 页面内容淡入 | 180ms | easeOut | 仅透明度与 4pt 位移 |
| hover/press | 120–180ms | snappy | 最大缩放 1.015 / 0.98 |
| idle→scanning 仪表变形 | 420ms | spring 0.42/0.82 | 保持中心位置，不闪切 |
| 分类开始/完成 | 220ms | snappy | 颜色、图标替换、一次落定 |
| 六类全部落定 sweep | 300ms | easeInOut | 只播放一次 |
| review 数字落定 | 500–700ms | easeOut | 数字滚动，内容不抖动 |
| 完整成功招牌时刻 | ≤1600ms | 分三幕 | 自停，稳态零帧 |

Reduce Motion 下取消位移、缩放、粒子与 sweep，只保留 100–150ms 交叉淡化和静态状态变化。Reduce Transparency 下所有玻璃使用不透明语义表面。动画不得用永久 `TimelineView(.animation)` 驱动 idle 页面。

## 10. 代码边界

现有扫描与结果事实源保持不变。实现按职责拆分，避免继续扩大 `ScanViews.swift` 和 `SmartScanHub.swift`：

- `SmartScanExperienceView.swift`：稳定的主旅程根布局与状态路由。
- `SmartScanTodayBar.swift`：顶部上下文与命令入口。
- `SmartScanInstrument.swift`：idle/scanning/review 的中央仪表。
- `SmartScanInsightStack.swift`：最多三条确定性洞察。
- `SmartScanCategoryMatrix.swift`：六类状态矩阵。
- `SmartScanReviewView.swift`：分组结果与选择摘要。
- `SmartScanTerminalView.swift`：诚实终态和下一步。
- `ToolDiscoveryRail.swift`：上下文工具推荐。
- `SmartScanPresentation.swift`：定义不可变 `SmartScanPresentationState` 及纯构造器，把现有 hub/result facts 映射为展示状态，不执行扫描或删除。
- `AllToolsView.swift`：可搜索的纯导航工具总览。
- `RecentToolStore.swift`：有界、低隐私的最近模块标识与时间存储。
- `SmartScanExperienceFixture.swift`（DEBUG-only）：确定性状态、时间、容量、终态和无障碍截图输入。
- 修改 `SmartScanHub.swift`：增加闭合扫描取消事实、类目 cancelled 状态和 `cleanCancellationRequested` UI 子事实；取消请求只改变“正在停止”显示，不改写 reducer 终态，并保留现有扫描/清理所有权。
- 修改 `RootView.swift`：三层侧栏、全部工具路由和稳定桌面导航。

`SmartScanPresentationState` 是一次性值快照，不是 `ObservableObject`，不拥有扫描任务，不重复持久化 Domain 结果，也不产生成功事实。它只根据现有状态推导标题、数字、推荐和允许动作；唯一可变事实源仍是现有 hub/consumer。

## 11. 数据流与错误处理

```text
SmartScanHubViewModel / OperationResult / CleaningReport
                         ↓
        SmartScanPresentationState（不可变纯映射）
                         ↓
         SmartScanExperienceView（稳定布局）
                         ↓
      用户动作回到现有 hub / consumer API
```

- 数据尚未就绪：显示 skeleton，不显示假 0。
- 单类失败：该类进入需要注意，总扫描可继续；总结果不得宣称完整。
- 权限缺失：显示可恢复动作和系统设置入口，不渲染为普通空态。
- 扫描取消：保留已知发现，但标注覆盖不完整，禁止显示“扫描完成”。
- 结果事实自相矛盾：进入 uncertain，隐藏全部聚合 counts、空间数字和成功动效。
- 推荐证据缺失：不显示该推荐，不用静态占位凑满三张卡。

为避免当前 `failed("已取消")` 与普通失败混淆，hub 增加闭合 `ScanSessionTermination` 事实，并给 Category status 增加 `.cancelled`。`start()` 清空旧 termination；用户取消时即使尚无结果也进入可见 cancelled review，不静默回 idle。取消只保留已经由扫描器提交的结果与 coverage，未落定类目不推测为零或完成。

## 12. 无障碍与本地化

- 阅读顺序：结论 → 证据 → 主操作 → 洞察 → 推荐工具。
- 中央仪表作为一个可访问元素，标签包含状态、数值、单位和动作提示。
- 六类矩阵每项提供类别、状态、发现数量和是否需要注意。
- 颜色不作为唯一状态编码；同时使用图标、标题和状态文字。
- 所有按钮具有可见焦点环和键盘等价操作；保留 ⌘R、⌘⏎、⌘Z，并在菜单中可发现。
- 11 语言必须 key parity；德语、俄语等长文本以真实字符串跑最小窗口截图。
- VoiceOver announcement 只在阶段变化或真实终态触发，不在实时数字每次刷新时朗读。

## 13. 验证与验收证据

### 13.1 本里程碑 95+ 评分门

本里程碑单独对以下六维评分；每一维都必须达到 95/100，不能用平均分掩盖短板：

视觉与层级使用固定的 20 项二值 rubric，每项 5 分：

| 组 | 通过条件（每条 5 分） |
|---|---|
| H · 信息层级 | H1 当前状态首屏唯一且清楚；H2 主动作 5 秒内可识别；H3 预计/成功处理/空间变化与可撤销/不可逆层级明确；H4 terminal 下一步不抢夺结果结论 |
| L · 布局 | L1 1080×640 无截断重叠；L2 1440×900 不出现无意义空洞；L3 阅读顺序在所有状态稳定；L4 侧栏和 All Tools 无需猜测即可到达五个关键入口 |
| T · 排版数据 | T1 字号只用批准 token 且层级不倒挂；T2 数字等宽、单位降级、列右对齐；T3 zh/en/ja/de 无孤字、错误截断或中英混排 |
| C · 色彩材质 | C1 正文/控件对比达到 WCAG AA；C2 每屏唯一渐变主角且 Light 无白雾、Dark 无霓虹描边墙；C3 状态同时有文字/图标，不只靠颜色 |
| N · 原生一致性 | N1 使用原生 sidebar/toolbar/keyboard 语义；N2 卡片、按钮、列表、焦点环遵循同一组件契约；N3 图标与插画属于同一 Xico 精密仪器语言 |
| M · 动效细节 | M1 动效解释状态且全部有限时自停；M2 动画中输入与布局无可见卡顿/跳动；M3 Reduce Motion/Transparency/Increase Contrast 降级完整 |

严重度与扣分规则固定如下：

- P0：误导删除/结果、主旅程不可用、关键内容不可读或无障碍阻断；该维直接失败且总里程碑不通过。
- P1：影响主旅程的可见错误、重叠截断、错误口径、主要状态不一致或任一必测矩阵缺失；该维最高 89，不能以其他分数补偿。
- P2：一个局部但真实的 rubric 条件失败；对应二值项记 0，即扣 5 分。
- P3：不影响任务的微小偏差；记录但不自动扣分，若同一 rubric 条件出现两个及以上 P3，则该项失败并扣 5 分。

两名 reviewer 必须独立填写 20 项 pass/fail、严重度、截图或运行证据和理由；视觉分取两份独立结果的较低值。对任一条目结论不同或总分相差 ≥5 时，由第三名 reviewer 仅裁决争议条目，保留三份原始记录，裁决后重新计算；不得通过平均分消除失败。用户最终观感复核是独立必过门，不替代上述记录。

| 维度 | 95 分门槛与证据 |
|---|---|
| 主旅程可理解性 | 10 名目标用户各完成“说出当前状态、开始扫描、找到需确认项、说明完成结果”4 个任务；40 次任务至少 38 次无需提示成功，且错误理解预计/实际或可撤销/不可逆记为失败 |
| 视觉与层级 | 完整 current-HEAD 截图矩阵无 P0/P1；两名独立 UI reviewer 按上方固定 rubric 复核，较低分而非平均分 ≥95；用户观感另设必过门 |
| 信息真实性与安全 | 预计/成功处理/可用空间、可撤销/不可逆、partial/uncertain 全部语义测试通过；错误成功强化为 0，永久项目默认选择为 0 |
| 功能可发现性 | 上述 10 名用户在 10 秒内找到 Smart Scan、卸载器、Space Lens、维护和全部工具；50 次查找至少 48 次成功，推荐无证据展示为 0 |
| 交互、动效与性能 | 所有动画有限时并支持降级；输入反馈 P95 <100ms，首个有意义内容 P95 <500ms，动画结束后空闲 GPU 相对静态基线增量 <1.0pp |
| 无障碍与全球化 | 键盘与 VoiceOver 主旅程 100% 可达；11 语言 key/格式 100% 通过；正文/控件达到 WCAG AA，对比度或状态不得只靠颜色 |

用户研究、独立评分或竞品实验室尚未执行时，该维度保持 `external`/`unverified`，不得由开发者自评补成 95。与当前安装版及当时最新可获得的 CleanMyMac 使用同一台 Mac、同一窗口尺寸和同一任务脚本做随机顺序盲测；记录产品版本、设备、输入数据与评分原表。本里程碑 95+ 也不等于全产品八维 95+，后者仍须完成 §15 后续页面和总计划最终矩阵。

### 13.2 自动测试

- Presentation state 对九种状态的纯映射测试，以及非法组合一律 uncertain 的测试。
- 扫描取消事实测试：无结果和有部分结果都进入显式 cancelled review，且未落定类目不被伪装为完成。
- 类别完成度与局部 fraction 单调性测试；未知 fraction 不渲染总百分比。
- 假 0 禁止测试：事实未就绪时只能得到 loading/skeleton。
- full-success-only celebration 测试。
- partial/failure/cancelled/uncertain 禁止成功强化测试。
- uncertain 不读取或渲染任何 `OperationCounts` 聚合测试；只允许经过独立验证的 issue/recovery/receipt capability。
- `cleanCancellationRequested` 只改变 stopping UI、禁用重复请求且不提前改 terminal/counts/selection/receipts 的测试。
- 永久、helper、caution/risky 项默认不选且必须进入需要确认组；informational 永不可选。
- 成功处理大小、同卷可用空间 delta 和不可用/延迟说明三种口径不可互换测试。
- 无 expiry 的 receipt 不显示撤销倒计时测试。
- 推荐 reason/evidence/destination 一致性测试。
- All Tools 只导航不执行、最近工具存储上限/隐私字段和稳定排序测试。
- 最多三条洞察、最多三条新增功能、最多两个终态推荐的边界测试。
- Reduce Motion/Transparency 分支结构测试。
- 11 语言 key parity 与格式参数测试。

### 13.3 确定性 fixture 与视觉矩阵

新增 DEBUG-only `SmartScanExperienceFixture`，其公开输入固定为：presentation state、六类状态与局部 progress、固定 `Date`、volume identity/capacity、coverage、permission state、选择事实、Domain outcome/receipts、locale、颜色方案、窗口尺寸和 accessibility 环境。fixture 只注入已构造事实，不调用真实 scanner、Trash、helper、tmutil 或网络；Release target 不暴露注入入口。

每个状态至少生成以下确定性截图：

- Light 与 Dark；
- 1080×640 与 1440×900；
- zh-Hans、en、ja，另加最长字符串语言 de；
- idle、scanning（已落定 3/6 类）、review、executing、success、partial、failure、cancelled、uncertain；
- Reduce Motion、Reduce Transparency、Increase Contrast。

截图必须来自当前 HEAD 的真实 SwiftUI 视图和 fixture，不接受旧图、设计稿或 mock 图片冒充实现证据。同一 macOS build、scale 和字体环境下保存已人工批准的 current-HEAD golden；自动差异门为超过感知阈值的像素不多于 0.5%，同时运行布局/文案/AX 语义断言。任何超过阈值的变更必须附新旧图人工批准，不能直接重录 golden 消除失败。

### 13.4 运行验收

- 打包为 `.app` 后启动，不以裸 SwiftPM 可执行文件代替。
- 在安装包中手动走一次 idle→scan→review，不执行真实删除即可验证主要交互。
- 使用纯临时沙箱 fixture 验证 review→terminal、undo 和错误状态。
- 记录首屏、扫描中、复核、完整成功和 partial 五张当前截图。
- 验证动画结束后没有常驻 TimelineView 或明显空闲 GPU 增量。

## 14. 明确不在本里程碑内

- 不重写扫描引擎、删除引擎或卸载归属安全边界。
- 不在本里程碑宣称 Space Lens、设置、监控、定价等全部页面达到 95 分。
- 不用 3D 模型、视频贴图或持续粒子墙制造表面冲击。
- 不恢复已被用户否决的高亮玻璃侧栏、天气、时钟或旧六预设。
- 不把预计空间、逻辑大小、选中大小或成功处理大小冒充系统可用空间变化。

## 15. 后续顺序

本里程碑通过后，依次推进：

1. 全局侧栏、工具总览与页面外壳一致性。
2. Uninstaller、Space Lens、Maintenance 三个高价值页面的可见升级。
3. 监控、硬件、网络和设置的信息架构与数据视觉精修。
4. 动效、无障碍、11 语言全产品矩阵。
5. 回收 Phase 0 剩余安全任务和最终 95+ 全量验收。

每一步仍需当前代码、测试、运行截图和安装包证据；不得用本规格或单个可见里程碑替代总目标完成证明。
