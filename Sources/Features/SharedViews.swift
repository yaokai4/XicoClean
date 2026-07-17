import SwiftUI
import Domain
import Infrastructure
import DesignSystem

// MARK: - 安全级别 → 视觉

extension SafetyLevel {
    var tint: Color {
        switch self {
        case .safe: return XColor.success
        case .caution: return XColor.warning
        case .risky: return XColor.danger
        }
    }
    /// 删除后会怎样——给用户「删这个安全吗」的判断依据（智能解释）。
    var explanation: String {
        switch self {
        case .safe: return xLoc("删除安全：这些是可再生的缓存/临时文件，应用会在需要时自动重建。默认已勾选。")
        case .caution: return xLoc("请留意：删除本身可恢复（移入废纸篓），但重建或再获取需要时间/流量。默认不勾选，确认后再删。")
        case .risky: return xLoc("高风险：可能涉及重要或不可逆的数据。请逐项确认，默认不勾选。")
        }
    }
    var gradient: [Color] {
        switch self {
        case .safe: return [XColor.accentTeal, XColor.success]
        case .caution: return [XColor.warning, XColor.accentPink]
        case .risky: return [XColor.danger, XColor.accentPink]
        }
    }
}

// MARK: - 单行可清理项

struct ItemRowView: View {
    let item: CleanableItem
    let onToggle: () -> Void
    var onIgnore: (() -> Void)? = nil
    /// 「报告误报」（P5 安全库）：匿名上报规则 id + 本地立即忽略。nil = 该列表不支持上报。
    var onReport: (() -> Void)? = nil
    @State private var hover = false
    @State private var showEvidence = false

    var body: some View {
        HStack(spacing: XSpacing.m) {
            // 「仅提示」项不给勾选框（三层闸第二层）：给 info 图标表明「这行是说明，不是操作」。
            if item.isInformational {
                Image(systemName: "info.circle")
                    .font(.system(size: 15))
                    .foregroundStyle(XColor.textTertiary)
                    .frame(width: 19, height: 19)
                    .help(xLoc("仅提示项：请按其说明用官方方式处置，Xico 不代删"))
                    .accessibilityLabel(xLoc("仅提示，不可勾选"))
            } else {
                XCheckbox(isOn: item.isSelected, accessibilityLabel: item.displayName, toggle: onToggle)
            }

            // 真实缩略图（图片/视频/PDF 等），非可视文件回退类型图标——告别灰色文字行。
            XThumbnail(url: item.url, side: 30)

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(item.displayName)
                        .font(XFont.bodyEmphasis).foregroundStyle(XColor.textPrimary).lineLimit(1)
                    if let note = item.note {
                        Text(xLoc(note))
                            .font(XFont.nano)
                            .foregroundStyle(XColor.warning)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(XColor.warning.opacity(0.15), in: Capsule())
                            .lineLimit(1).fixedSize()
                    }
                }
                Text(xLoc(item.detail))
                    .font(XFont.caption).foregroundStyle(XColor.textTertiary)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            if item.safety != .safe {
                XBadge(item.safety.label, color: item.safety.tint)
            }
            Button { showEvidence.toggle() } label: {
                HStack(spacing: 3) {
                    Image(systemName: "checkmark.shield")
                    Text("\(Int((item.assessment.confidence * 100).rounded()))%")
                        .monospacedDigit()
                }
                .font(XFont.nano)
                .foregroundStyle(confidenceColor)
            }
            .buttonStyle(.plain)
            .help(xLoc("查看判断依据"))
            .accessibilityLabel(xLocF("判断置信度 %d%%，查看依据",
                                      Int((item.assessment.confidence * 100).rounded())))
            .popover(isPresented: $showEvidence, arrowEdge: .bottom) {
                FindingEvidenceView(item: item)
            }
            Text(item.size.formattedBytes)
                .font(XFont.mono).foregroundStyle(XColor.textSecondary)
                .frame(minWidth: 76, alignment: .trailing)
        }
        .padding(.horizontal, XSpacing.s)
        .padding(.vertical, 6)
        .background(hover ? XColor.surfaceHover : .clear, in: RoundedRectangle(cornerRadius: XRadius.control))
        .animation(XMotion.hover, value: hover)
        .onHover { hover = $0 }
        .contextMenu {
            Button(xLoc("快速查看")) { quickLook(item.url) }
            Button(xLoc("在 Finder 中显示")) { revealInFinder(item.url) }
            Button(xLoc("查看判断依据")) { showEvidence = true }
            if onIgnore != nil || onReport != nil { Divider() }
            if let onIgnore {
                Button(xLoc("永不清理此项")) { onIgnore() }
            }
            if let onReport {
                // 匿名上报（仅规则 id，不含路径/文件名）+ 本地立即忽略——误报闭环（P5）。
                Button(xLoc("报告误报并忽略")) { onReport() }
            }
        }
    }

    private var confidenceColor: Color {
        if item.assessment.confidence >= 0.95 { return XColor.success }
        if item.assessment.confidence >= 0.8 { return XColor.warning }
        return XColor.danger
    }
}

private struct FindingEvidenceView: View {
    let item: CleanableItem

    var body: some View {
        VStack(alignment: .leading, spacing: XSpacing.s) {
            HStack(spacing: XSpacing.s) {
                Image(systemName: "checkmark.shield.fill").foregroundStyle(confidenceColor)
                VStack(alignment: .leading, spacing: 1) {
                    Text(xLoc("判断依据")).font(XFont.bodyEmphasis).foregroundStyle(XColor.textPrimary)
                    Text(xLocF("置信度 %d%%", Int((item.assessment.confidence * 100).rounded())))
                        .font(XFont.caption).foregroundStyle(confidenceColor).monospacedDigit()
                }
            }
            Divider()
            ForEach(item.assessment.evidence) { evidence in
                VStack(alignment: .leading, spacing: 2) {
                    Text(xLoc(evidence.title)).font(XFont.captionEmphasis).foregroundStyle(XColor.textPrimary)
                    if !evidence.detail.isEmpty {
                        Text(xLoc(evidence.detail)).font(XFont.caption).foregroundStyle(XColor.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            Divider()
            Label(xLoc(item.assessment.recovery.label), systemImage: "arrow.uturn.backward.circle")
                .font(XFont.caption).foregroundStyle(XColor.textSecondary)
            if let owner = item.assessment.ownerBundleID {
                Label(owner, systemImage: "app.badge")
                    .font(XFont.captionMono).foregroundStyle(XColor.textSecondary)
            }
            if let impact = item.assessment.impact {
                Text(xLoc(impact)).font(XFont.caption).foregroundStyle(XColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(XSpacing.m)
        .frame(width: 340)
    }

    private var confidenceColor: Color {
        if item.assessment.confidence >= 0.95 { return XColor.success }
        if item.assessment.confidence >= 0.8 { return XColor.warning }
        return XColor.danger
    }
}

func revealInFinder(_ url: URL) {
    NSWorkspace.shared.activateFileViewerSelecting([url])
}

/// 用系统 Quick Look 预览（qlmanage -p 弹出标准预览面板，稳健且无需接管 responder 链）。
func quickLook(_ url: URL) {
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/usr/bin/qlmanage")
    proc.arguments = ["-p", url.path]
    proc.standardOutput = FileHandle.nullDevice
    proc.standardError = FileHandle.nullDevice
    try? proc.run()
}

// MARK: - 结果分组卡片（含交错入场动画）

struct ResultGroupCard: View {
    let group: ScanResultGroup
    let index: Int
    /// 列表总卡数（自适应 stagger 用，docs/16）：>0 时交错总编排封顶 0.30s，长列表不拖沓。
    var count: Int = 0
    let allSelected: Bool
    let onToggleGroup: (Bool) -> Void
    let onToggleItem: (UUID) -> Void
    var onIgnoreItem: ((UUID) -> Void)? = nil
    @State private var expanded = false
    @State private var appeared = false
    @State private var showAll = false
    @State private var showInfo = false
    @State private var evidenceItem: CleanableItem?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// 结果项按大小降序，最能省空间的排在最前，信息层级更清晰。
    private var sortedItems: [CleanableItem] {
        group.items.sorted { $0.size > $1.size }
    }
    private static let previewCap = 80

    /// 视觉组：过半为可预览的图片/视频 → 用缩略图画廊而非文字行。
    private var isVisualGroup: Bool {
        guard !group.items.isEmpty else { return false }
        let vis = group.items.filter { XThumbnail.isPreviewable($0.url) }.count
        return Double(vis) / Double(group.items.count) >= 0.5
    }

    private func galleryGrid(_ items: [CleanableItem]) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 108), spacing: XSpacing.s)], spacing: XSpacing.m) {
            ForEach(items) { item in galleryTile(item) }
        }
        .padding(.top, XSpacing.xs)
    }

    /// 报告误报（P5）：匿名 POST 规则 id（= 分组 id）+ 模块语境，随后本地忽略该项。
    /// 两处右键菜单（文字行 / 画廊磁贴）共用。
    private func report(_ item: CleanableItem, ignore: ((UUID) -> Void)? = nil) {
        DefinitionsFeedbackClient.reportFalsePositive(ruleID: group.id, module: group.title)
        if let ignore {
            ignore(item.id)
        } else {
            onIgnoreItem?(item.id)
        }
    }

    private func galleryTile(_ item: CleanableItem) -> some View {
        // 用 Button 承载磁贴：键盘可聚焦 + 空格/回车切换勾选（原 onTapGesture 对键盘/VoiceOver 均不可达）。
        Button { onToggleItem(item.id) } label: {
            VStack(spacing: 4) {
                XThumbnail(url: item.url, side: 104, corner: XRadius.tile)
                    .overlay(alignment: .topTrailing) {
                        if item.isSelected {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 19)).foregroundStyle(.white, XColor.brand)
                                .padding(5)
                        }
                    }
                    .overlay(RoundedRectangle(cornerRadius: XRadius.tile, style: .continuous)
                        .strokeBorder(item.isSelected ? XColor.brand : Color.clear, lineWidth: 2))
                    .overlay(alignment: .bottomLeading) {
                        Text(item.size.formattedBytes)
                            .font(XFont.nano).foregroundStyle(.white)
                            .padding(.horizontal, 5).padding(.vertical, 2)
                            .background(.black.opacity(0.55), in: Capsule())
                            .padding(5)
                    }
                Text(item.displayName).font(XFont.nano).foregroundStyle(XColor.textSecondary)
                    .lineLimit(1).truncationMode(.middle).frame(maxWidth: 104)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(item.displayName)
        .contextMenu {
            Button(xLoc("快速查看")) { quickLook(item.url) }
            Button(xLoc("在 Finder 中显示")) { revealInFinder(item.url) }
            Button(xLoc("查看判断依据")) { evidenceItem = item }
            if let onIgnoreItem {
                Divider()
                Button(xLoc("永不清理此项")) { onIgnoreItem(item.id) }
                Button(xLoc("报告误报并忽略")) { report(item) }
            }
        }
        // 单一无障碍元素：念出「<文件名> · <大小>」并把勾选态作为 .isSelected trait 播报。
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(item.displayName)
        .accessibilityValue(item.size.formattedBytes)
        .accessibilityAddTraits(item.isSelected ? [.isButton, .isSelected] : .isButton)
    }

    var body: some View {
        XCard {
            VStack(alignment: .leading, spacing: XSpacing.s) {
                HStack(spacing: XSpacing.m) {
                    // 整组都是「仅提示」项（容器虚拟磁盘/休眠镜像等 guidance 组）：不给组勾选框——
                    // 否则是个永远勾不动的死控件；单项混排时保留组勾选（setGroup 会跳过提示项）。
                    if group.items.allSatisfy(\.isInformational) {
                        Image(systemName: "info.circle")
                            .font(.system(size: 15))
                            .foregroundStyle(XColor.textTertiary)
                            .frame(width: 19, height: 19)
                            .accessibilityLabel(xLoc("仅提示，不可勾选"))
                    } else {
                        XCheckbox(isOn: allSelected, accessibilityLabel: xLoc(group.title)) { onToggleGroup(!allSelected) }
                    }
                    XIconTile(systemImage: group.systemImage, colors: group.safety.gradient, size: 36)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(xLoc(group.title)).xHeadline().foregroundStyle(XColor.textPrimary)
                        if !group.description.isEmpty {
                            Text(xLoc(group.description)).font(XFont.caption)
                                .foregroundStyle(XColor.textSecondary).lineLimit(2)
                        }
                    }
                    Spacer()
                    // 智能解释：这是什么 / 删了会怎样
                    Button { showInfo.toggle() } label: {
                        Image(systemName: "info.circle")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(XColor.textTertiary)
                    }
                    .buttonStyle(.plain)
                    .help(xLoc("这是什么 / 删除后会怎样"))
                    .accessibilityLabel(xLoc("这是什么 / 删除后会怎样"))
                    .popover(isPresented: $showInfo, arrowEdge: .bottom) {
                        VStack(alignment: .leading, spacing: XSpacing.s) {
                            Text(xLoc(group.title)).xHeadline().foregroundStyle(XColor.textPrimary)
                            if !group.description.isEmpty {
                                Text(xLoc(group.description)).font(XFont.caption).foregroundStyle(XColor.textSecondary)
                            }
                            // 「为什么可删」（P5 安全库）：逐条规则的判定依据，基于 macOS 事实。
                            if let explanation = group.explanation {
                                Divider()
                                HStack(spacing: 6) {
                                    Image(systemName: "text.book.closed").foregroundStyle(XColor.brand)
                                    Text(xLoc("为什么可删")).font(XFont.captionEmphasis).foregroundStyle(XColor.brand)
                                }
                                Text(xLoc(explanation)).font(XFont.caption).foregroundStyle(XColor.textSecondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Divider()
                            HStack(spacing: 6) {
                                Image(systemName: "checkmark.shield").foregroundStyle(group.safety.tint)
                                Text(xLoc(group.safety.label)).font(XFont.caption).foregroundStyle(group.safety.tint)
                            }
                            Text(xLoc(group.safety.explanation)).font(XFont.caption).foregroundStyle(XColor.textSecondary)
                        }
                        .padding(XSpacing.m).frame(width: 320)
                    }
                    Text(group.totalSize.formattedBytes).xNumber().foregroundStyle(XColor.textPrimary)
                    Button {
                        withAnimation(XMotion.snappy) { expanded.toggle() }
                    } label: {
                        Image(systemName: expanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 12, weight: .semibold))
                            .contentTransition(.symbolEffect(.replace))   // 符号原生替换（docs/16 P1-3）
                            .foregroundStyle(XColor.textSecondary)
                            .frame(width: 22, height: 22)
                            .background(XColor.surfaceAlt, in: Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(expanded ? xLoc("收起") : xLoc("展开"))
                }

                if expanded {
                    Divider().padding(.vertical, 2)
                    let items = sortedItems
                    let shown = showAll ? items : Array(items.prefix(Self.previewCap))
                    VStack(spacing: 0) {
                        // 图片/视频组 → 缩略图画廊；其余 → 文字行。
                        if isVisualGroup {
                            galleryGrid(shown)
                        } else {
                            ForEach(shown) { item in
                                ItemRowView(item: item, onToggle: { onToggleItem(item.id) },
                                            onIgnore: onIgnoreItem.map { cb in { cb(item.id) } },
                                            onReport: onIgnoreItem.map { cb in { report(item, ignore: cb) } })
                            }
                        }
                        if items.count > Self.previewCap && !showAll {
                            // 关键：隐藏项仍会被清理。给出可点击入口让用户能审阅全部，
                            // 并明确说明"未展示项也在清理范围内"（审计 C2）。
                            Button {
                                // 展开淡入走统一动效令牌；Reduce Motion 下不加动画（nil）。
                                withAnimation(reduceMotion ? nil : XMotion.crossfade) { showAll = true }
                            } label: {
                                Text(xLocF("显示全部 %d 项（其余 %d 项已勾选，将一并清理）", items.count, items.count - Self.previewCap))
                                    .font(XFont.caption).foregroundStyle(XColor.brand)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.top, XSpacing.xs)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
        }
        .hoverLift(2)
        .popover(item: $evidenceItem, arrowEdge: .bottom) { item in
            FindingEvidenceView(item: item)
        }
        .opacity(appeared ? 1 : 0)
        .offset(y: (appeared || reduceMotion) ? 0 : 16)
        .onAppear {
            if reduceMotion {
                appeared = true   // 降低动态效果：不做交错入场位移
            } else {
                // 自适应 stagger（docs/16）：知道总数时封顶 0.30s 总编排——50 张卡不再排队 2.5s。
                let anim = count > 0 ? XTransition.stagger(index, of: count)
                                     : XTransition.stagger(index)
                withAnimation(anim) { appeared = true }
            }
        }
    }
}

// MARK: - 扫描中（招牌动画）

struct ScanningIndicator: View {
    let bytes: Int64
    let message: String
    var progress: Double? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        VStack(spacing: XSpacing.xl) {
            ZStack {
                // 运行氛围（P9）：声呐脉冲环 + 缓旋极光辉光——只在扫描期间存在，
                // 随视图消失即停；Reduce Motion 下完全不画。
                if !reduceMotion {
                    ScanAmbience(size: 300)
                }
                XScanOrb(value: bytes.formattedBytes, label: xLoc("已发现"), size: 300, progress: progress)
            }
            // 状态胶囊：脉冲点 + 正在扫描的位置（等宽、居中截断）+ 确定性进度百分比
            HStack(spacing: XSpacing.s) {
                XLiveDot()
                Text(message.isEmpty ? xLoc("正在扫描…") : message)
                    .font(XFont.captionMono).foregroundStyle(XColor.textSecondary)
                    .lineLimit(1).truncationMode(.middle)
                if let p = progress {
                    Text("\(Int((min(max(p, 0), 1) * 100).rounded()))%")
                        .font(XFont.captionEmphasis).foregroundStyle(XColor.brand)
                        .monospacedDigit()
                        .contentTransition(.numericText())
                }
            }
            .padding(.horizontal, XSpacing.l).padding(.vertical, 7)
            .background(Capsule().fill(XColor.surface.opacity(0.6)))
            .overlay(Capsule().stroke(XColor.hairline, lineWidth: 1))
            .frame(maxWidth: 440)
            .animation(XMotion.crossfade, value: message)
        }
    }
}

/// 扫描氛围层：三道错相「声呐」脉冲环（从 orb 边缘扩散淡出）+ 两团缓慢环绕的品牌辉光。
/// 生命周期与扫描视图一致（TimelineView 随视图销毁即停，符合「动画必须停表」铁律）。
private struct ScanAmbience: View {
    let size: CGFloat

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30)) { tl in
            let t = tl.date.timeIntervalSinceReferenceDate
            Canvas { ctx, canvasSize in
                let c = CGPoint(x: canvasSize.width / 2, y: canvasSize.height / 2)
                let base = size / 2 - 10
                // 声呐脉冲：周期 2.4s、三道错相 1/3；从 orb 边缘扩散到 1.35 倍处淡出。
                let brand = XThemeStore.shared.current.accent
                for i in 0..<3 {
                    let phase = (t / 2.4 + Double(i) / 3).truncatingRemainder(dividingBy: 1)
                    let r = base * (1 + 0.35 * phase)
                    let alpha = 0.22 * (1 - phase)
                    let rect = CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)
                    ctx.stroke(Path(ellipseIn: rect), with: .color(brand.opacity(alpha)), lineWidth: 1.5)
                }
                // 两团环绕辉光：慢速对转，半径极大、透明度极低——氛围而非焦点。
                let ring = XThemeStore.shared.current.ring
                for (i, speed) in [0.05, -0.035].enumerated() {
                    let ang = t * speed * 2 * .pi
                    let gx = c.x + cos(ang) * base * 0.9
                    let gy = c.y + sin(ang) * base * 0.9
                    let color = ring[i % max(ring.count, 1)]
                    let grad = Gradient(colors: [color.opacity(0.10), .clear])
                    ctx.fill(Path(ellipseIn: CGRect(x: gx - 120, y: gy - 120, width: 240, height: 240)),
                             with: .radialGradient(grad, center: CGPoint(x: gx, y: gy),
                                                   startRadius: 0, endRadius: 120))
                }
            }
        }
        .frame(width: size * 1.5, height: size * 1.5)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

// MARK: - 诚实结果页

@MainActor
struct TaskOutcomeView: View {
    let context: TaskOutcomeContext
    let actions: TaskOutcomeActions
    let authorization: OutcomePresentationEffectAuthorization?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(
        context: TaskOutcomeContext,
        actions: TaskOutcomeActions,
        authorization: OutcomePresentationEffectAuthorization? = nil
    ) {
        self.context = context
        self.actions = actions
        self.authorization = authorization
    }

    var body: some View {
        TaskOutcomeSessionView(
            context: context,
            actions: actions,
            authorization: authorization,
            initialReduceMotion: reduceMotion)
            .id(context.operation.id)
    }
}

/// Operation-keyed child ownership ensures a new terminal ID receives a new
/// frozen effect session, while focus/body recomputation for the same ID cannot
/// flip its motion plan after the one-shot authorization is taken.
@MainActor
private struct TaskOutcomeSessionView: View {
    let context: TaskOutcomeContext
    let actions: TaskOutcomeActions

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var focusedAction: TaskOutcomeActionKind?
    @StateObject private var effectSession: OutcomePresentationEffectSession
    @State private var motionSession: OutcomeMotionSessionState

    init(
        context: TaskOutcomeContext,
        actions: TaskOutcomeActions,
        authorization: OutcomePresentationEffectAuthorization?,
        initialReduceMotion: Bool
    ) {
        self.context = context
        self.actions = actions
        _effectSession = StateObject(wrappedValue: OutcomePresentationEffectSession(
            authorization: authorization,
            expectedOperationID: context.operation.id))
        _motionSession = State(initialValue: OutcomeMotionSessionState(
            initialReduceMotion: initialReduceMotion))
    }

    var body: some View {
        let presentation = TaskOutcomePresentation.make(context: context)
            .resolvingAvailableActions(actions.availableKinds)
        let motionPlan = OutcomeMotionPlan.make(
            context: context,
            presentation: presentation,
            visualEffectGranted: effectSession.grant?.celebration == true,
            reduceMotion: motionSession.shouldSuppress(
                currentReduceMotion: reduceMotion))

        ZStack {
            OutcomeResultBackdrop(role: presentation.semanticRole)

            if let grant = effectSession.grant {
                OutcomePresentationEffects(
                    context: context,
                    presentation: presentation,
                    motionPlan: motionPlan,
                    grant: grant)
                    .frame(width: 380, height: 380)
            }

            ScrollView {
                VStack(spacing: XSpacing.xl) {
                    OutcomeStatusHeader(
                        presentation: presentation,
                        motionPlan: motionPlan)

                    XCard(padding: XSpacing.l, elevated: true) {
                        OutcomeCountGrid(summary: presentation.countSummary)
                    }
                    .frame(maxWidth: 620)

                    VStack(spacing: XSpacing.s) {
                        Text(xLoc(presentation.detailKey))
                            .font(XFont.bodyEmphasis)
                            .foregroundStyle(XColor.textSecondary)
                            .multilineTextAlignment(.center)
                        if let note = presentation.note,
                           !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            Text(note)
                                .font(XFont.caption)
                                .foregroundStyle(XColor.textTertiary)
                                .multilineTextAlignment(.center)
                        }
                    }
                    .frame(maxWidth: 560)

                    OutcomeActionBar(
                        presentation: presentation,
                        actions: actions,
                        focusedAction: $focusedAction)
                        .onAppear {
                            focusedAction = motionPlan.initialFocus
                        }
                }
                .padding(.horizontal, XSpacing.xxl)
                .padding(.vertical, XSpacing.xxl)
                .frame(maxWidth: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: reduceMotion) { _, enabled in
            motionSession.observe(reduceMotion: enabled)
        }
    }
}

private struct OutcomeResultBackdrop: View {
    let role: TaskOutcomeSemanticRole

    var body: some View {
        ZStack {
            XColor.surface(at: .resting)
            Circle()
                .fill(RadialGradient(
                    colors: [role.tint.opacity(0.16), .clear],
                    center: .center,
                    startRadius: 0,
                    endRadius: 320))
                .frame(width: 640, height: 640)
                .offset(y: -180)
                .blur(radius: 12)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private struct OutcomeStatusHeader: View {
    let presentation: TaskOutcomePresentation
    let motionPlan: OutcomeMotionPlan

    var body: some View {
        VStack(spacing: XSpacing.m) {
            if motionPlan.createsDelayedRevealTask {
                AnimatedOutcomeStatusOrb(
                    systemImage: presentation.systemImage,
                    role: presentation.semanticRole)
            } else {
                OutcomeStatusOrb(
                    systemImage: presentation.systemImage,
                    role: presentation.semanticRole)
            }

            Text(xLoc(presentation.titleKey))
                .xLargeTitle()
                .foregroundStyle(XColor.textPrimary)
                .multilineTextAlignment(.center)

            if presentation.affectedBytes != nil || motionPlan.finalNumericValue > 0 {
                if motionPlan.createsCountUpTask {
                    AnimatedOutcomeMetric(
                        plan: motionPlan,
                        formatsBytes: presentation.affectedBytes != nil)
                } else {
                    OutcomeMetricText(
                        value: motionPlan.finalNumericValue,
                        formatsBytes: presentation.affectedBytes != nil)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(presentation.accessibilityLabel)
    }
}

private struct OutcomeStatusOrb: View {
    let systemImage: String
    let role: TaskOutcomeSemanticRole

    var body: some View {
        ZStack {
            Circle()
                .fill(role.tint.opacity(0.12))
            Circle()
                .strokeBorder(
                    LinearGradient(
                        colors: role.gradientColors.map { $0.opacity(0.72) },
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing),
                    lineWidth: 1.5)
                .padding(1)
            Image(systemName: systemImage)
                .font(XFont.heroCompact)
                .foregroundStyle(LinearGradient(
                    colors: role.gradientColors,
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing))
        }
        .frame(width: 116, height: 116)
        .shadow(color: role.tint.opacity(0.22), radius: 22, y: 8)
        .accessibilityHidden(true)
    }
}

private struct AnimatedOutcomeStatusOrb: View {
    let systemImage: String
    let role: TaskOutcomeSemanticRole
    @State private var revealed = false

    var body: some View {
        OutcomeStatusOrb(systemImage: systemImage, role: role)
            .scaleEffect(revealed ? 1 : 0.72)
            .opacity(revealed ? 1 : 0)
            .task {
                try? await Task.sleep(nanoseconds: 620_000_000)
                guard !Task.isCancelled else { return }
                withAnimation(XMotion.celebrateSoft) {
                    revealed = true
                }
            }
    }
}

private struct OutcomeMetricText: View {
    let value: Int64
    let formatsBytes: Bool

    var body: some View {
        Text(formatsBytes ? value.formattedBytes : xLocF("完成 %d 项", Int(clamping: value)))
            .font(XFont.monoHero)
            .foregroundStyle(XColor.textPrimary)
            .monospacedDigit()
            .contentTransition(.numericText())
    }
}

private struct AnimatedOutcomeMetric: View {
    let plan: OutcomeMotionPlan
    let formatsBytes: Bool
    @State private var shown: Int64

    init(plan: OutcomeMotionPlan, formatsBytes: Bool) {
        self.plan = plan
        self.formatsBytes = formatsBytes
        _shown = State(initialValue: plan.initialNumericValue)
    }

    var body: some View {
        OutcomeMetricText(value: shown, formatsBytes: formatsBytes)
            .task {
                try? await Task.sleep(nanoseconds: 700_000_000)
                guard !Task.isCancelled else { return }
                let target = plan.finalNumericValue
                for step in 1...36 {
                    guard !Task.isCancelled else { return }
                    let progress = Double(step) / 36
                    let eased = 1 - pow(1 - progress, 3)
                    shown = plan.interpolatedNumericValue(at: eased)
                    try? await Task.sleep(nanoseconds: 24_000_000)
                }
                shown = target
            }
    }
}

private struct OutcomeCountGrid: View {
    let summary: TaskOutcomeCountSummary

    private var facts: [(String, Int)] {
        [
            ("请求 %d 项", summary.requested),
            ("完成 %d 项", summary.succeeded),
            ("无需更改 %d 项", summary.unchanged),
            ("跳过 %d 项", summary.skipped),
            ("失败 %d 项", summary.failed),
            ("取消 %d 项", summary.cancelled),
        ]
    }

    var body: some View {
        LazyVGrid(
            columns: [
                GridItem(.flexible(), spacing: XSpacing.s),
                GridItem(.flexible(), spacing: XSpacing.s),
            ],
            spacing: XSpacing.s
        ) {
            ForEach(Array(facts.enumerated()), id: \.offset) { _, fact in
                Text(xLocF(fact.0, fact.1))
                    .font(XFont.captionEmphasis)
                    .foregroundStyle(fact.1 > 0 ? XColor.textPrimary : XColor.textTertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, XSpacing.m)
                    .padding(.vertical, XSpacing.s)
                    .background(XColor.surfaceAlt.opacity(0.72), in: RoundedRectangle(
                        cornerRadius: XRadius.button,
                        style: .continuous))
            }
        }
        .accessibilityElement(children: .combine)
    }
}

@MainActor
private struct OutcomeActionBar: View {
    let presentation: TaskOutcomePresentation
    let actions: TaskOutcomeActions
    let focusedAction: FocusState<TaskOutcomeActionKind?>.Binding

    private var available: [(TaskOutcomeActionKind, String, () -> Void)] {
        presentation.actionOrder.compactMap { kind in
            guard let action = action(for: kind) else { return nil }
            return (kind, presentation.actionTitle(for: kind), action)
        }
    }

    var body: some View {
        let buttons = available
        ViewThatFits(in: .horizontal) {
            HStack(spacing: XSpacing.m) {
                ForEach(Array(buttons.enumerated()), id: \.offset) { index, item in
                    actionButton(item, isPrimary: index == 0)
                }
            }
            VStack(spacing: XSpacing.s) {
                ForEach(Array(buttons.enumerated()), id: \.offset) { index, item in
                    actionButton(item, isPrimary: index == 0)
                }
            }
        }
        .frame(maxWidth: 620)
    }

    @ViewBuilder
    private func actionButton(
        _ item: (TaskOutcomeActionKind, String, () -> Void),
        isPrimary: Bool
    ) -> some View {
        if isPrimary {
            Button(item.1, action: item.2)
                .focused(focusedAction, equals: item.0)
                .buttonStyle(XPrimaryButtonStyle())
        } else {
            Button(item.1, action: item.2)
                .focused(focusedAction, equals: item.0)
                .buttonStyle(XSecondaryButtonStyle())
        }
    }

    private func action(for kind: TaskOutcomeActionKind) -> (() -> Void)? {
        switch kind {
        case .retryFailed, .retryRemaining: actions.retry
        case .details: actions.details
        case .undoChanged: actions.undo
        case .recovery: actions.recovery
        case .done: actions.done
        }
    }
}

private extension TaskOutcomeSemanticRole {
    var tint: Color {
        switch self {
        case .success: XColor.success
        case .neutral: XColor.brand
        case .warning: XColor.warning
        case .error: XColor.danger
        case .cancelled: XColor.textSecondary
        case .irreversible: XColor.accentTeal
        }
    }

    var gradientColors: [Color] {
        switch self {
        case .success: [XColor.success, XColor.accentTeal]
        case .neutral: [XColor.brand, XColor.ring(2)]
        case .warning: [XColor.warning, XColor.accentPink]
        case .error: [XColor.danger, XColor.accentPink]
        case .cancelled: [XColor.textSecondary, XColor.brand]
        case .irreversible: [XColor.accentTeal, XColor.brand]
        }
    }
}

/// 仅用于尚未迁移的调用点。它故意不解释旧的聚合数字，也不播放任何成功反馈；
/// Tasks 4–13 会逐个用 reducer-backed `TaskOutcomeView` 替换这些调用。
struct TaskCompletionView: View {
    private let onDone: (() -> Void)?

    init(
        animateTo: Int64,
        metricText: @escaping (Int64) -> String,
        detail: String,
        undoTitle: String? = nil,
        onUndo: (() -> Void)? = nil,
        doneTitle: String? = nil,
        onDone: (() -> Void)? = nil,
        signature: Bool = true
    ) {
        _ = animateTo
        _ = metricText
        _ = detail
        _ = undoTitle
        _ = onUndo
        _ = doneTitle
        _ = signature
        self.onDone = onDone
    }

    var body: some View {
        LegacyTaskOutcomeCompatibilityView(onDone: onDone)
    }
}

private struct LegacyTaskOutcomeCompatibilityView: View {
    let onDone: (() -> Void)?

    var body: some View {
        VStack(spacing: XSpacing.l) {
            ZStack {
                Circle()
                    .fill(XColor.brand.opacity(0.10))
                    .frame(width: 112, height: 112)
                Circle()
                    .strokeBorder(XColor.brand.opacity(0.24), lineWidth: 1)
                    .frame(width: 112, height: 112)
                Image(systemName: "circle.dotted")
                    .font(XFont.heroCompact)
                    .foregroundStyle(XColor.brandGradient)
            }

            VStack(spacing: XSpacing.s) {
                Text(xLoc("结果展示正在升级"))
                    .xTitle()
                    .foregroundStyle(XColor.textPrimary)
                Text(xLoc("请返回并重新执行此操作以查看完整结果。"))
                    .font(XFont.body)
                    .foregroundStyle(XColor.textSecondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
            }

            if let onDone {
                Button(xLoc("完成"), action: onDone)
                    .buttonStyle(XPrimaryButtonStyle())
                    .padding(.top, XSpacing.s)
            }
        }
        .padding(XSpacing.xxl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }
}

/// 清理流唯一的 reducer-backed 结果页适配器。
///
/// `CleaningOutcomeConsumer` 已在公开终态前冻结 sink 决策与一次性展示授权；
/// 这里仅把可用动作交给通用 `TaskOutcomeView`，不重算成功、不发通知、也不注册 gate。
@MainActor
struct CompletionView: View {
    let outcome: CleaningOutcomeConsumption
    var onRetry: (() -> Void)?
    var onUndo: (() -> Void)?
    let onDone: () -> Void
    @State private var showingDetails = false

    private var hasDetails: Bool {
        let counts = outcome.presentationContext.operation.counts
        return !outcome.presentationContext.operation.issues.isEmpty
            || counts.failed > 0
            || counts.skipped > 0
            || counts.cancelled > 0
    }

    var body: some View {
        TaskOutcomeView(
            context: outcome.presentationContext,
            actions: TaskOutcomeActions(
                retry: onRetry,
                details: hasDetails ? { showingDetails = true } : nil,
                undo: onUndo,
                done: onDone),
            authorization: outcome.presentationAuthorization)
            .sheet(isPresented: $showingDetails) {
                CleaningOutcomeDetailsSheet(
                    operation: outcome.presentationContext.operation,
                    onDone: { showingDetails = false })
            }
    }
}

@MainActor
private struct CleaningOutcomeDetailsSheet: View {
    let operation: OperationOutcome
    let onDone: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: XSpacing.l) {
            HStack(spacing: XSpacing.s) {
                Image(systemName: "list.bullet.clipboard")
                    .foregroundStyle(XColor.brand)
                Text(xLoc("操作详情")).xTitle()
                Spacer()
            }

            OutcomeCountGrid(summary: TaskOutcomeCountSummary(operation.counts))

            if operation.issues.isEmpty {
                Text(xLoc("没有需要处理的问题。"))
                    .font(XFont.body)
                    .foregroundStyle(XColor.textSecondary)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: XSpacing.s) {
                        ForEach(Array(operation.issues.enumerated()), id: \.offset) { _, issue in
                            XCard(padding: XSpacing.m) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(xLoc(issue.code))
                                        .font(XFont.bodyEmphasis)
                                        .foregroundStyle(XColor.textPrimary)
                                    Text(xLoc(issue.recovery.rawValue))
                                        .font(XFont.caption)
                                        .foregroundStyle(XColor.textSecondary)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                }
            }

            HStack {
                Spacer()
                Button(xLoc("完成"), action: onDone)
                    .buttonStyle(XPrimaryButtonStyle())
            }
        }
        .padding(XSpacing.xl)
        .frame(minWidth: 520, minHeight: 380)
    }
}
