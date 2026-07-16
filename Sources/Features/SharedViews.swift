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

// MARK: - 完成页（庆祝动画）

/// 全应用统一的「任务完成」庆祝页：喷发彩带 + 打勾弹入 + 主数字从 0 数到目标（ease-out）。
/// 清理 / 粉碎 / 卸载 / 更新检查等所有批量任务流共用同一套庆祝语言与动效，达成一致的「完成」体验。
/// `metricText` 把当前动画值格式化为主标题（字节量或计数由调用方决定）；按钮均可选。
struct TaskCompletionView: View {
    let animateTo: Int64
    let metricText: (Int64) -> String
    let detail: String
    var undoTitle: String? = nil
    var onUndo: (() -> Void)? = nil
    var doneTitle: String? = nil
    var onDone: (() -> Void)? = nil
    /// 招牌 S-A「空间湮灭」三幕 + 声/触反馈（docs/16）。危险操作（粉碎）传 false——
    /// 铁律：危险操作永不配「愉悦」的声/触强化，走朴素庆祝。
    var signature: Bool = true

    @State private var pop = false
    @State private var shown: Int64 = 0   // 从 0 数到目标的动画值
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            // S-A 三幕（docs/16）：汇聚→闪光→释放。幕2 闪光帧齐发 声(cleanDone)+触(levelChange)——
            // 声/触/光对齐同一窗口，大脑绑成一个事件（CMM 只有视觉）。
            if signature {
                XAnnihilationBurst(onFlash: {
                    XSound.play(.cleanDone)
                    XHaptic.perform(.levelChange)
                })
                .frame(width: 360, height: 360)
            } else {
                XCelebrationBurst().frame(width: 360, height: 360)
            }
            VStack(spacing: XSpacing.l) {
                ZStack {
                    Circle().fill(XColor.success.opacity(0.15)).frame(width: 124, height: 124)
                    Image(systemName: "checkmark")
                        .font(XFont.hero)
                        .foregroundStyle(XColor.successGradient)
                }
                .scaleEffect(pop ? 1 : 0.3)
                .opacity(pop ? 1 : 0)

                Text(metricText(shown))
                    .xLargeTitle().foregroundStyle(XColor.textPrimary)
                    .monospacedDigit()
                    .contentTransition(.numericText())
                Text(detail)
                    .font(XFont.body).foregroundStyle(XColor.textSecondary)
                    .multilineTextAlignment(.center)
                if (undoTitle != nil && onUndo != nil) || (doneTitle != nil && onDone != nil) {
                    HStack(spacing: XSpacing.m) {
                        if let undoTitle, let onUndo {
                            Button(undoTitle) { onUndo() }.buttonStyle(XSecondaryButtonStyle())
                        }
                        if let doneTitle, let onDone {
                            Button(doneTitle) { onDone() }.buttonStyle(XPrimaryButtonStyle())
                        }
                    }
                    .padding(.top, XSpacing.s)
                    .opacity(pop ? 1 : 0)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            // 幕3（0.75s 起）：对勾 celebrateSoft 弹出（两次可感余荡）+ 数字 count-up——
            // 招牌模式下等幕1汇聚/幕2闪光走完再登场；朴素模式/Reduce Motion 立即到位。
            if signature && !reduceMotion {
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 750_000_000)
                    withAnimation(XMotion.celebrateSoft) { pop = true }
                    countUp()
                }
            } else {
                withAnimation(XMotion.celebrate) { pop = true }
                countUp()
            }
            // 盲用户也「听到」结果（docs/16 §5）：完成播报，不只视觉粒子。
            AccessibilityNotification.Announcement(metricText(animateTo)).post()
        }
    }

    /// 主数字从 0 数到目标（ease-out cubic），命中 CleanMyMac 式满足感的关键动效。Reduce Motion 直接到位。
    private func countUp() {
        let target = animateTo
        guard target > 0, !reduceMotion else { shown = target; return }
        Task { @MainActor in
            let start = Date()
            let duration = 0.9
            while true {
                let t = min(1, Date().timeIntervalSince(start) / duration)
                let eased = 1 - pow(1 - t, 3)   // ease-out cubic
                shown = Int64(Double(target) * eased)
                if t >= 1 { break }
                try? await Task.sleep(nanoseconds: 16_000_000)   // ~60fps
            }
            shown = target
        }
    }
}

/// 清理流的完成页——薄封装 `TaskCompletionView`（释放字节数计数庆祝 + 撤销/完成）。
/// `note`：可选的诚实附注（如 P3 的「空间被快照暂存」解释），追加在明细行之后。
struct CompletionView: View {
    let report: CleaningReport
    let intent: DeleteIntent
    var note: String? = nil
    let onUndo: () -> Void
    let onDone: () -> Void

    private var canUndo: Bool { intent == .trash && !report.restorable.isEmpty }

    var body: some View {
        TaskCompletionView(
            animateTo: report.reclaimedBytes,
            metricText: { xLocF("已释放 %@", $0.formattedBytes) },
            detail: xLocF("清理了 %d 项", report.removedCount) +
                (report.failures.isEmpty ? "" : xLocF(" · %d 项被跳过", report.failures.count)) +
                (note.map { "\n" + $0 } ?? ""),
            undoTitle: canUndo ? xLoc("撤销") : nil,
            onUndo: canUndo ? onUndo : nil,
            doneTitle: xLoc("完成"),
            onDone: onDone)
    }
}
