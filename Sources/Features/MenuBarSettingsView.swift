import SwiftUI
import AppKit
import Domain
import Infrastructure
import DesignSystem

// MARK: - 状态栏（独立页，P0 IA 重组：原设置页「菜单栏状态项」卡整体迁出）
// 四层渐进披露不变：预设 → 项目列表（排序+开关）→ 逐项详情 → 全局。
// 所有状态外化在 xico.mb.* UserDefaults；MenuBarController 经 defaults 快照比对自动重建，
// 本页零控制器耦合（仅 applyRefreshInterval 走 AppModel 重启采样节拍）。

public struct MenuBarSettingsView: View {
    @ObservedObject var model: AppModel
    // 僵尸键清理沿革见 SettingsView 旧注：全局 xico.mb.style 与逐项 .border 键已废除。
    @AppStorage("xico.mb.interval") private var mbInterval = 2.0
    // 默认单色（模板图，随菜单栏深浅自动黑/白）——克制、像 Sensei/iStat 默认那样不刺眼。
    @AppStorage("xico.mb.colored") private var mbColored = false
    @AppStorage("xico.mb.order") private var mbOrderCSV = ""
    @AppStorage("xico.mb.combined.values") private var mbCombinedValues = false
    /// 展开逐项详情的条目（同一时间只展开一个——渐进披露，防设置迷宫）。
    @State private var mbExpanded: String?

    public init(model: AppModel) { self.model = model }

    public var body: some View {
        VStack(spacing: 0) {
            XHeaderBar(title: xLoc("状态栏"), subtitle: xLoc("菜单栏样式、排序与刷新"))
            ScrollView {
                VStack(spacing: XSpacing.m) {
                    presetsCard
                    itemsCard
                    globalCard
                }
                .padding(XSpacing.xl)
                .frame(maxWidth: 720)
                .frame(maxWidth: .infinity)
            }
        }
    }

    // MARK: 菜单栏项元数据（顺序 = 默认显示顺序左→右，与 MenuBarController.config 对齐）。

    private struct MBItem: Identifiable {
        let id: String
        let title: String
        let icon: String
        let tint: Color
        let defOn: Bool
        let defStyle: MenuBarStyle
        /// 该项可选的样式集合（网络/温度无占比 → 无圆环；电池/温度无图表 → 无迷你图/可视化；合并项无样式）。
        let styles: [MenuBarStyle]
    }

    private var mbItems: [MBItem] {
        [
            MBItem(id: "network", title: xLoc("网络速度"), icon: "antenna.radiowaves.left.and.right",
                   tint: XColor.metricNetwork[0], defOn: true, defStyle: .graph,
                   styles: [.iconValue, .valueOnly, .graph, .rich]),
            MBItem(id: "disk", title: xLoc("磁盘占用"), icon: "internaldrive",
                   tint: XColor.warning, defOn: false, defStyle: .iconValue,
                   styles: [.iconValue, .valueOnly, .rich, .ring]),
            MBItem(id: "temp", title: xLoc("处理器温度"), icon: "thermometer.medium",
                   tint: XColor.warning, defOn: false, defStyle: .iconValue,
                   styles: [.iconValue, .valueOnly]),
            MBItem(id: "battery", title: xLoc("电池"), icon: "battery.100percent",
                   tint: XColor.success, defOn: false, defStyle: .iconValue,
                   styles: [.iconValue, .valueOnly, .ring]),
            MBItem(id: "gpu", title: xLoc("GPU 占用"), icon: "display",
                   tint: XColor.accentPink, defOn: false, defStyle: .rich,
                   styles: [.iconValue, .valueOnly, .graph, .rich, .ring]),
            MBItem(id: "memory", title: xLoc("内存"), icon: "memorychip",
                   tint: XColor.metricMemory[0], defOn: true, defStyle: .rich,
                   styles: [.iconValue, .valueOnly, .graph, .rich, .ring]),
            MBItem(id: "cpu", title: xLoc("处理器 CPU"), icon: "cpu",
                   tint: XColor.metricCPU[0], defOn: true, defStyle: .rich,
                   styles: [.iconValue, .valueOnly, .graph, .rich, .ring]),
            MBItem(id: "combined", title: xLoc("合并项（多迷你图并排）"), icon: "gauge.with.dots.needle.50percent",
                   tint: XColor.textSecondary, defOn: false, defStyle: .rich, styles: []),
        ]
    }

    /// 用户顺序（左→右）；新增项自动补到末尾。
    private var mbOrder: [String] {
        let all = mbItems.map(\.id)
        let saved = mbOrderCSV.split(separator: ",").map(String.init).filter { all.contains($0) }
        guard !saved.isEmpty else { return all }
        return saved + all.filter { !saved.contains($0) }
    }

    private func moveMB(_ id: String, up: Bool) {
        var order = mbOrder
        guard let i = order.firstIndex(of: id) else { return }
        let j = up ? i - 1 : i + 1
        guard j >= 0, j < order.count else { return }
        order.swapAt(i, j)
        withAnimation(XMotion.snappy) { mbOrderCSV = order.joined(separator: ",") }
    }

    // UserDefaults 直连绑定（@AppStorage 无法表达「每项动态键」与三态）。
    private func mbBool(_ key: String, default def: Bool) -> Binding<Bool> {
        Binding(get: { UserDefaults.standard.object(forKey: key) == nil ? def : UserDefaults.standard.bool(forKey: key) },
                set: { UserDefaults.standard.set($0, forKey: key) })
    }
    private func mbStyleBinding(_ item: MBItem) -> Binding<String> {
        Binding(get: { UserDefaults.standard.string(forKey: "xico.mb.\(item.id).style") ?? item.defStyle.rawValue },
                set: { UserDefaults.standard.set($0, forKey: "xico.mb.\(item.id).style") })
    }
    /// 三态彩色：global（跟随全局开关）/ mono / colored。
    private func mbColorBinding(_ id: String) -> Binding<String> {
        let key = "xico.mb.\(id).colored"
        return Binding(get: {
            guard UserDefaults.standard.object(forKey: key) != nil else { return "global" }
            return UserDefaults.standard.bool(forKey: key) ? "colored" : "mono"
        }, set: { v in
            switch v {
            case "colored": UserDefaults.standard.set(true, forKey: key)
            case "mono":    UserDefaults.standard.set(false, forKey: key)
            default:        UserDefaults.standard.removeObject(forKey: key)
            }
        })
    }
    /// 每项独立刷新率：0 = 跟随全局节拍。
    private func mbIntervalBinding(_ id: String) -> Binding<Double> {
        let key = "xico.mb.\(id).interval"
        return Binding(get: { UserDefaults.standard.double(forKey: key) },
                       set: { v in
                           if v <= 0 { UserDefaults.standard.removeObject(forKey: key) }
                           else { UserDefaults.standard.set(v, forKey: key) }
                       })
    }

    // MARK: 第一层：一键预设（真实字形缩影预览）

    private var presetsCard: some View {
        XCard {
            VStack(alignment: .leading, spacing: XSpacing.s) {
                HStack(spacing: XSpacing.m) {
                    XIconTile(systemImage: "menubar.rectangle", colors: XColor.metricCPU, size: 36)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(xLoc("菜单栏状态项")).xHeadline().foregroundStyle(XColor.textPrimary)
                        Text(xLoc("一键预设开箱即好看；想细调再逐项展开")).font(XFont.caption).foregroundStyle(XColor.textSecondary)
                    }
                    Spacer()
                }
                Divider().padding(.vertical, XSpacing.xxs)
                HStack(spacing: XSpacing.s) {
                    mbPresetCard(xLoc("极简"), desc: xLoc("单一合并项 · 单色"), preview: presetPreviewMinimal) { applyPreset("minimal") }
                    mbPresetCard(xLoc("性能"), desc: xLoc("CPU + 内存 + GPU"), preview: presetPreviewPerformance) { applyPreset("performance") }
                    mbPresetCard(xLoc("全景"), desc: xLoc("五项常驻 · 彩色"), preview: presetPreviewPanorama) { applyPreset("panorama") }
                }
            }
        }
    }

    // MARK: 第二 + 三层：项目列表（排序 + 开关 + 逐项详情）

    private var itemsCard: some View {
        XCard {
            VStack(alignment: .leading, spacing: XSpacing.s) {
                ForEach(Array(mbOrder.enumerated()), id: \.element) { idx, id in
                    if let item = mbItems.first(where: { $0.id == id }) {
                        mbItemRow(item, index: idx, count: mbOrder.count)
                    }
                }
            }
        }
    }

    // MARK: 第四层：全局

    private var globalCard: some View {
        XCard {
            VStack(alignment: .leading, spacing: XSpacing.s) {
                VStack(alignment: .leading, spacing: 3) {
                    toggleRow(xLoc("彩色图标"), $mbColored)
                    Text(xLoc("关：随菜单栏深浅自动黑白（推荐，克制）；开：每指标按代表色着色"))
                        .font(XFont.caption).foregroundStyle(XColor.textTertiary)
                }
                HStack {
                    Text(xLoc("更新频率")).font(XFont.bodyEmphasis).foregroundStyle(XColor.textPrimary)
                    Spacer()
                    Picker("", selection: $mbInterval) {
                        Text(xLoc("快速（1 秒）")).tag(1.0)
                        Text(xLoc("标准（2 秒）")).tag(2.0)
                        Text(xLoc("省电（3 秒）")).tag(3.0)
                    }
                    .labelsHidden().pickerStyle(.menu).frame(width: 150)
                    .accessibilityLabel(xLoc("更新频率"))
                    .onChange(of: mbInterval) { model.applyRefreshInterval(mbInterval) }
                }
            }
        }
    }

    // MARK: 预设卡（真实字形渲染的缩影，点击一键应用；应用后仍可逐项微调）

    private static let mbDemoHist: [Double] = [0.3, 0.5, 0.4, 0.7, 0.6, 0.8, 0.5, 0.9, 0.7, 0.6, 0.8, 0.7, 0.62]

    private var presetPreviewMinimal: NSImage {
        MenuBarGlyph.combined(slots: [
            MenuCombinedSlot(viz: .histogram(Self.mbDemoHist), tint: XColor.metricCPU),
            MenuCombinedSlot(viz: .pie(0.71), tint: XColor.metricMemory),
            MenuCombinedSlot(viz: .net(down: "1.2M", up: "386K"), tint: XColor.metricNetwork),
        ])
    }
    private var presetPreviewPerformance: NSImage {
        MenuBarGlyph.combined(slots: [
            MenuCombinedSlot(viz: .histogram(Self.mbDemoHist), tint: XColor.metricCPU, value: "62%"),
            MenuCombinedSlot(viz: .pie(0.71), tint: XColor.metricMemory, value: "71%"),
            MenuCombinedSlot(viz: .pie(0.26), tint: XColor.metricGPU, value: "26%"),
        ])
    }
    private var presetPreviewPanorama: NSImage {
        MenuBarGlyph.combined(slots: [
            MenuCombinedSlot(viz: .histogram(Self.mbDemoHist), tint: XColor.metricCPU),
            MenuCombinedSlot(viz: .pie(0.71), tint: XColor.metricMemory),
            MenuCombinedSlot(viz: .net(down: "1.2M", up: "386K"), tint: XColor.metricNetwork),
            MenuCombinedSlot(viz: .text("44°"), tint: [XColor.warning]),
            MenuCombinedSlot(viz: .pie(0.39), tint: XColor.metricDisk),
        ])
    }

    private func mbPresetCard(_ title: String, desc: String, preview: NSImage, apply: @escaping () -> Void) -> some View {
        Button(action: apply) {
            VStack(spacing: 5) {
                Image(nsImage: preview)
                    .renderingMode(.template)
                    .foregroundStyle(XColor.textPrimary)
                    .frame(height: 18)
                    .scaleEffect(0.9)
                Text(title).font(XFont.captionEmphasis).foregroundStyle(XColor.textPrimary)
                Text(desc).font(XFont.nano).foregroundStyle(XColor.textTertiary).lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, XSpacing.s)
            .background(RoundedRectangle(cornerRadius: XRadius.control, style: .continuous)
                .fill(XColor.surfaceAlt.opacity(0.5)))
            .overlay(RoundedRectangle(cornerRadius: XRadius.control, style: .continuous)
                .strokeBorder(XColor.border, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title + " · " + desc)
    }

    /// 一键预设：写一组 xico.mb.* 键，MenuBarController 经 defaults 快照比对自动重建。
    private func applyPreset(_ name: String) {
        let d = UserDefaults.standard
        let allIDs = mbItems.map(\.id)
        func enable(_ ids: [String]) {
            for id in allIDs { d.set(ids.contains(id), forKey: "xico.mb.\(id)") }
        }
        switch name {
        case "minimal":
            enable(["combined"])
            for id in allIDs { d.removeObject(forKey: "xico.mb.combined.\(id)") }   // 恢复默认 cpu+mem+net
            mbColored = false
        case "performance":
            enable(["cpu", "memory", "gpu"])
            d.set(MenuBarStyle.rich.rawValue, forKey: "xico.mb.cpu.style")
            d.set(MenuBarStyle.rich.rawValue, forKey: "xico.mb.memory.style")
            d.set(MenuBarStyle.rich.rawValue, forKey: "xico.mb.gpu.style")
            mbColored = false
        default:   // panorama
            enable(["cpu", "memory", "network", "temp", "disk"])
            d.set(MenuBarStyle.rich.rawValue, forKey: "xico.mb.cpu.style")
            d.set(MenuBarStyle.rich.rawValue, forKey: "xico.mb.memory.style")
            d.set(MenuBarStyle.graph.rawValue, forKey: "xico.mb.network.style")
            mbColored = true
        }
        withAnimation(XMotion.snappy) { mbExpanded = nil }
    }

    // MARK: 项目行（开关 + 上下排序 + 展开逐项详情）

    private func mbItemRow(_ item: MBItem, index: Int, count: Int) -> some View {
        let enabled = mbBool("xico.mb.\(item.id)", default: item.defOn)
        let expanded = mbExpanded == item.id
        return VStack(spacing: 8) {
            HStack(spacing: XSpacing.s) {
                // 排序（上/下移，键盘可达——比裸拖拽更可靠、可无障碍）。
                VStack(spacing: 0) {
                    Button { moveMB(item.id, up: true) } label: {
                        Image(systemName: "chevron.up").font(XFont.nano)
                    }.buttonStyle(.plain).disabled(index == 0)
                        .accessibilityLabel(xLocF("上移 %@", item.title))
                    Button { moveMB(item.id, up: false) } label: {
                        Image(systemName: "chevron.down").font(XFont.nano)
                    }.buttonStyle(.plain).disabled(index == count - 1)
                        .accessibilityLabel(xLocF("下移 %@", item.title))
                }
                .foregroundStyle(XColor.textTertiary)
                Image(systemName: item.icon).font(XFont.callout).foregroundStyle(item.tint).frame(width: 18)
                Text(item.title).font(XFont.bodyEmphasis).foregroundStyle(XColor.textPrimary)
                if enabled.wrappedValue {
                    Button {
                        withAnimation(XMotion.snappy) { mbExpanded = expanded ? nil : item.id }
                    } label: {
                        Image(systemName: "chevron.right")
                            .font(XFont.nano).foregroundStyle(XColor.textTertiary)
                            .rotationEffect(.degrees(expanded ? 90 : 0))
                            .frame(width: 16, height: 16)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(xLocF("展开 %@ 详情", item.title))
                }
                Spacer()
                Toggle("", isOn: enabled).toggleStyle(.switch).labelsHidden()
                    .accessibilityLabel(item.title)
            }
            if enabled.wrappedValue, expanded {
                mbItemDetail(item)
                    .padding(.leading, XSpacing.xl + 2)
                    .transition(.opacity)
            }
        }
        .padding(.vertical, 1)
    }

    /// 第三层：逐项详情（样式磁贴 + 彩色三态 + 独立刷新率；合并项 = 子项勾选 + 显示数值）。
    @ViewBuilder private func mbItemDetail(_ item: MBItem) -> some View {
        VStack(alignment: .leading, spacing: XSpacing.s) {
            if item.id == "combined" {
                Text(xLoc("包含哪些指标（用各指标自己的紧凑图形）"))
                    .font(XFont.caption).foregroundStyle(XColor.textSecondary)
                ForEach(mbItems.filter { $0.id != "combined" }) { sub in
                    HStack {
                        Image(systemName: sub.icon).font(XFont.caption).foregroundStyle(sub.tint).frame(width: 16)
                        Text(sub.title).font(XFont.body).foregroundStyle(XColor.textPrimary)
                        Spacer()
                        Toggle("", isOn: mbBool("xico.mb.combined.\(sub.id)",
                                                default: ["cpu", "memory", "network"].contains(sub.id)))
                            .toggleStyle(.switch).labelsHidden().controlSize(.mini)
                            .accessibilityLabel(sub.title)
                    }
                }
                toggleRow(xLoc("图形旁显示数值"), $mbCombinedValues)
            } else if !item.styles.isEmpty {
                let styleBinding = mbStyleBinding(item)
                HStack(spacing: 6) {
                    ForEach(item.styles, id: \.rawValue) { st in
                        MBStyleTile(style: st, tint: item.tint, icon: item.icon,
                                    selected: styleBinding.wrappedValue == st.rawValue) {
                            withAnimation(XMotion.snappy) { styleBinding.wrappedValue = st.rawValue }
                        }
                    }
                }
            }
            // 内存口径（P8）：压力（kern.memorystatus_level，与 iStat 菜单栏一致，默认）/ 占用（已用÷总量）。
            if item.id == "memory" {
                HStack(spacing: XSpacing.xs) {
                    Text(xLoc("口径")).font(XFont.caption).foregroundStyle(XColor.textSecondary)
                    Picker("", selection: Binding(
                        get: { UserDefaults.standard.string(forKey: "xico.mb.memory.metric") ?? "pressure" },
                        set: { UserDefaults.standard.set($0, forKey: "xico.mb.memory.metric") })) {
                        Text(xLoc("压力（同 iStat）")).tag("pressure")
                        Text(xLoc("占用")).tag("used")
                    }
                    .labelsHidden().pickerStyle(.menu).fixedSize()
                    .accessibilityLabel(xLoc("口径"))
                }
            }
            if item.id != "combined" {
                HStack(spacing: XSpacing.l) {
                    HStack(spacing: XSpacing.xs) {
                        Text(xLoc("颜色")).font(XFont.caption).foregroundStyle(XColor.textSecondary)
                        Picker("", selection: mbColorBinding(item.id)) {
                            Text(xLoc("跟随全局")).tag("global")
                            Text(xLoc("单色")).tag("mono")
                            Text(xLoc("彩色")).tag("colored")
                        }
                        .labelsHidden().pickerStyle(.menu).fixedSize()
                        .accessibilityLabel(xLoc("颜色"))
                    }
                    HStack(spacing: XSpacing.xs) {
                        Text(xLoc("刷新")).font(XFont.caption).foregroundStyle(XColor.textSecondary)
                        Picker("", selection: mbIntervalBinding(item.id)) {
                            Text(xLoc("跟随全局")).tag(0.0)
                            Text("1s").tag(1.0)
                            Text("2s").tag(2.0)
                            Text("3s").tag(3.0)
                            Text("5s").tag(5.0)
                        }
                        .labelsHidden().pickerStyle(.menu).fixedSize()
                        .accessibilityLabel(xLoc("刷新"))
                    }
                    Spacer()
                }
            }
        }
    }

    private func toggleRow(_ title: String, _ binding: Binding<Bool>) -> some View {
        HStack {
            Text(title).font(XFont.bodyEmphasis).foregroundStyle(XColor.textPrimary)
            Spacer()
            Toggle("", isOn: binding).toggleStyle(.switch).labelsHidden()
                .accessibilityLabel(title)
        }
    }
}

// MARK: - 菜单栏显示样式：可视化选择器磁贴（点图形选样式，像 iStat）

/// 一枚样式磁贴：上方是该样式的真实缩影（图标+数值 / 纯数值 / 迷你折线 / 直方图），
/// 下方短标签。选中态描品牌边、淡底。让用户「看着图形选」，而不是读文字下拉。
private struct MBStyleTile: View {
    let style: MenuBarStyle
    let tint: Color
    let icon: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 5) {
                preview
                    .foregroundStyle(selected ? tint : XColor.textSecondary)
                    .frame(height: 15)
                Text(style.shortTitle)
                    .font(XFont.nano).fontWeight(selected ? .semibold : .regular)
                    .foregroundStyle(selected ? XColor.brand : XColor.textTertiary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, XSpacing.s)
            .background(RoundedRectangle(cornerRadius: XRadius.control, style: .continuous)
                .fill(selected ? XColor.brand.opacity(0.12) : XColor.surfaceAlt.opacity(0.5)))
            .overlay(RoundedRectangle(cornerRadius: XRadius.control, style: .continuous)
                .strokeBorder(selected ? XColor.brand : XColor.border, lineWidth: selected ? 1.5 : 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(style.title)
        .accessibilityLabel(style.title)
    }

    /// 软框（与真实字形 1:1，P10R2）：描边 0.55 + 淡底 0.07。
    @ViewBuilder private func chipped<V: View>(_ content: V) -> some View {
        content
            .padding(.horizontal, 3).padding(.vertical, 1.5)
            .background(RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill((selected ? tint : XColor.textSecondary).opacity(0.07)))
            .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous)
                .strokeBorder((selected ? tint : XColor.textSecondary).opacity(0.55), lineWidth: 1))
    }

    @ViewBuilder private var preview: some View {
        switch style {
        case .iconValue:
            HStack(spacing: 2) {
                Image(systemName: icon).font(XFont.nano)
                Text("42%").font(XFont.microMono)
            }
        case .valueOnly:
            Text("42%").font(XFont.microMono)
        case .graph:
            HStack(spacing: 2) {
                chipped(MBSparkPreview())
                Text("42%").font(XFont.microMono)
            }
        case .rich:
            HStack(spacing: 2) {
                // 与真实字形一致：CPU=软框直方图，内存/GPU/磁盘=饼盘
                if icon == "cpu" {
                    chipped(MBHistoPreview())
                } else {
                    MBPiePreview()
                }
                Text("42%").font(XFont.microMono)
            }
        case .ring:
            HStack(spacing: 2) {
                MBRingPreview()
                Text("42%").font(XFont.microMono)
            }
        }
    }
}

private struct MBPiePreview: View {
    var body: some View {
        ZStack {
            Circle().opacity(0.18)
            MBPieSector(fraction: 0.42)
            Circle().stroke(lineWidth: 1).opacity(0.4)
        }
        .frame(width: 12, height: 12)
    }
}

private struct MBPieSector: Shape {
    var fraction: Double
    func path(in rect: CGRect) -> Path {
        let c = CGPoint(x: rect.midX, y: rect.midY)
        var p = Path()
        p.move(to: c)
        p.addArc(center: c, radius: min(rect.width, rect.height) / 2,
                 startAngle: .degrees(-90), endAngle: .degrees(-90 + 360 * fraction), clockwise: false)
        p.closeSubpath()
        return p
    }
}

private struct MBRingPreview: View {
    var body: some View {
        ZStack {
            Circle().stroke(lineWidth: 1.8).opacity(0.22)
            Circle().trim(from: 0, to: 0.42)
                .stroke(style: StrokeStyle(lineWidth: 1.8, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: 12, height: 12)
    }
}

private struct MBSparkPreview: View {
    private let pts: [Double] = [0.30, 0.50, 0.34, 0.62, 0.42, 0.72, 0.5, 0.82]
    var body: some View {
        GeometryReader { g in
            Path { p in
                let w = g.size.width, h = g.size.height
                for (i, v) in pts.enumerated() {
                    let x = w * CGFloat(i) / CGFloat(pts.count - 1)
                    let y = h * (1 - CGFloat(v))
                    if i == 0 { p.move(to: CGPoint(x: x, y: y)) } else { p.addLine(to: CGPoint(x: x, y: y)) }
                }
            }
            .stroke(style: StrokeStyle(lineWidth: 1.3, lineCap: .round, lineJoin: .round))
        }
        .frame(width: 22, height: 12)
    }
}

private struct MBHistoPreview: View {
    private let bars: [Double] = [0.4, 0.7, 0.45, 0.9, 0.55, 0.8, 0.5]
    var body: some View {
        // 与真实字形同语言：软框内近实色圆角条（框即坐标系）。
        HStack(alignment: .bottom, spacing: 1) {
            ForEach(Array(bars.enumerated()), id: \.offset) { _, v in
                Capsule().opacity(0.82 + 0.18 * v)
                    .frame(width: 2.5, height: max(2.5, 10 * CGFloat(v)))
            }
        }
        .frame(width: 23.5, height: 10, alignment: .bottom)
    }
}
