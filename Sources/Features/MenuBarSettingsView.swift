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
    @AppStorage(MonitoringPreferences.refreshIntervalKey)
    private var mbIntervalRaw = MonitoringPreferences.refreshInterval().rawValue
    // 默认单色（模板图，随菜单栏深浅自动黑/白）——克制、像 Sensei/iStat 默认那样不刺眼。
    @AppStorage("xico.mb.colored") private var mbColored = false
    @AppStorage("xico.mb.order") private var mbOrderCSV = ""
    @AppStorage("xico.mb.combined.values") private var mbCombinedValues = false
    @AppStorage(MonitoringPreferences.cpuModeKey)
    private var monitoringCPUMode = MonitoringPreferences.cpuMode().rawValue
    @AppStorage(MonitoringPreferences.combinesProcessesKey)
    private var monitoringCombinesProcesses = MonitoringPreferences.combinesProcesses()
    @AppStorage(MonitoringPreferences.processLimitKey)
    private var monitoringProcessLimit = MonitoringPreferences.processLimit()
    @AppStorage(MonitoringPreferences.densityKey)
    private var monitoringDensity = MonitoringPreferences.density().rawValue
    @AppStorage(MonitoringPreferences.memoryUnitKey)
    private var monitoringMemoryUnit = MonitoringPreferences.memoryUnit().rawValue
    /// 展开逐项详情的条目（同一时间只展开一个——渐进披露，防设置迷宫）。
    @State private var mbExpanded: String?

    /// true = 官网离屏截图（ImageRenderer 画不出 ScrollView 内容）：非滚动海报态。
    private let poster: Bool

    public init(model: AppModel) { self.model = model; self.poster = false }
    #if DEBUG
    public init(model: AppModel, poster: Bool) { self.model = model; self.poster = poster }
    #endif

    public var body: some View {
        VStack(spacing: 0) {
            XHeaderBar(title: xLoc("状态栏"), subtitle: xLoc("菜单栏样式、排序与刷新"))
            if poster {
                cards.padding(XSpacing.xl).frame(maxWidth: 720).frame(maxWidth: .infinity)
                Spacer(minLength: 0)
            } else {
                ScrollView {
                    cards.padding(XSpacing.xl).frame(maxWidth: 720).frame(maxWidth: .infinity)
                }
            }
        }
    }

    private var cards: some View {
        VStack(spacing: XSpacing.m) {
            presetsCard
            itemsCard
            globalCard
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
            // 网络速度默认纯数值（2026-07 用户拍板）：不带图标、不带折线图/横条速率计——那些
            // 让它比 CPU/内存还宽、还"像图形"。可选样式收窄到 纯数值 / 图标+数值 两档。
            MBItem(id: "network", title: xLoc("网络速度"), icon: "arrow.up.arrow.down",
                   tint: XColor.metricNetwork[0], defOn: true, defStyle: .valueOnly,
                   styles: [.valueOnly, .iconValue]),
            MBItem(id: "disk", title: xLoc("磁盘占用"), icon: "internaldrive",
                   tint: XColor.menuDisk, defOn: false, defStyle: .iconValue,
                   styles: [.iconValue, .valueOnly, .rich, .ring]),
            MBItem(id: "diskio", title: xLoc("磁盘活动（读/写）"), icon: "arrow.up.arrow.down.circle",
                   tint: XColor.menuDisk, defOn: false, defStyle: .valueOnly,
                   styles: [.iconValue, .valueOnly, .graph, .rich]),
            MBItem(id: "temp", title: xLoc("温度"), icon: "thermometer.medium",
                   tint: XColor.warning, defOn: false, defStyle: .iconValue,
                   styles: [.iconValue, .valueOnly]),
            MBItem(id: "battery", title: xLoc("电池"), icon: "battery.100percent",
                   tint: XColor.success, defOn: false, defStyle: .iconValue,
                   styles: [.iconValue, .valueOnly, .ring]),
            MBItem(id: "gpu", title: xLoc("GPU 占用"), icon: "display",
                   tint: XColor.menuGPU, defOn: false, defStyle: .rich,
                   styles: [.iconValue, .valueOnly, .graph, .rich, .ring]),
            MBItem(id: "memory", title: xLoc("内存"), icon: "memorychip",
                   tint: XColor.metricMemory[0], defOn: true, defStyle: .rich,
                   styles: [.iconValue, .valueOnly, .graph, .rich, .ring]),
            MBItem(id: "cpu", title: xLoc("处理器 CPU"), icon: "cpu",
                   tint: XColor.metricCPU[0], defOn: true, defStyle: .rich,
                   styles: [.iconValue, .valueOnly, .graph, .rich, .ring, .loadAvg, .stacked, .coreGrid]),
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

    private var globalRefreshIntervalBinding: Binding<MonitoringRefreshInterval> {
        Binding(
            get: { MonitoringPreferences.refreshInterval() },
            set: { interval in
                mbIntervalRaw = interval.rawValue
                model.applyRefreshInterval(interval)
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
                // 三档组合（2026-07 用户拍板）：正常就是 网络+内存+CPU，往后依次加温度、磁盘——
                // 这五项即全部。此前六个花哨预设（GPU/电池/游戏/续航等）被否决；高级项仍可在下方
                // 逐项列表里手动开，不删功能。
                HStack(spacing: XSpacing.s) {
                    mbPresetCard(xLoc("基础"), desc: xLoc("网络 + 内存 + CPU"), preview: presetPreviewBasic) { applyPreset("basic") }
                    mbPresetCard(xLoc("加温度"), desc: xLoc("基础 + 温度"), preview: presetPreviewTemp) { applyPreset("temp") }
                    mbPresetCard(xLoc("全部"), desc: xLoc("再加磁盘"), preview: presetPreviewAll) { applyPreset("all") }
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
                    Picker("", selection: globalRefreshIntervalBinding) {
                        Text(xLoc("快速（1 秒）")).tag(MonitoringRefreshInterval.oneSecond)
                        Text(xLoc("标准（2 秒）")).tag(MonitoringRefreshInterval.twoSeconds)
                        Text(xLoc("省电（5 秒）")).tag(MonitoringRefreshInterval.fiveSeconds)
                    }
                    .labelsHidden().pickerStyle(.menu).frame(width: 150)
                    .accessibilityLabel(xLoc("更新频率"))
                }
                Divider().padding(.vertical, XSpacing.xxs)
                // 交互与口径（P1）：悬停预览 / 全局快捷键 / 彩色垫底 / VPN 计入。
                VStack(alignment: .leading, spacing: 3) {
                    toggleRow(xLoc("悬停展开面板"), mbBool("xico.mb.hover", default: false))
                    Text(xLoc("鼠标悬停状态项 0.35 秒即展开详情，无需点击"))
                        .font(XFont.caption).foregroundStyle(XColor.textTertiary)
                }
                VStack(alignment: .leading, spacing: 3) {
                    toggleRow(xLoc("全局快捷键 ⌃⌥M"), mbBool("xico.mb.hotkey", default: false))
                    Text(xLoc("任意应用内按 ⌃⌥M 唤出/收起菜单栏面板"))
                        .font(XFont.caption).foregroundStyle(XColor.textTertiary)
                }
                VStack(alignment: .leading, spacing: 3) {
                    toggleRow(xLoc("彩色图形垫底"), mbBool("xico.mb.backing", default: false))
                    Text(xLoc("透明菜单栏/浅色壁纸下给彩色图形垫半透明底，任何背景都清晰"))
                        .font(XFont.caption).foregroundStyle(XColor.textTertiary)
                }
                VStack(alignment: .leading, spacing: 3) {
                    toggleRow(xLoc("计入 VPN 流量"), mbBool("xico.mb.net.includeVPN", default: false))
                    Text(xLoc("默认排除 utun 隧道防止双计；只关注隧道内流量时可打开"))
                        .font(XFont.caption).foregroundStyle(XColor.textTertiary)
                }
            }
        }
    }

    // MARK: 预设卡（真实字形渲染的缩影，点击一键应用；应用后仍可逐项微调）

    private static let mbDemoHist: [Double] = [0.3, 0.5, 0.4, 0.7, 0.6, 0.8, 0.5, 0.9, 0.7, 0.6, 0.8, 0.7, 0.62]

    // 三档预览缩影：网络用 .net 双行数字（真实渲染即 valueOnly 纯数值）、内存/CPU 用饼盘/直方，
    // 温度/磁盘按档递增——与 applyPreset 的组合逐一对应。
    private var presetPreviewBasic: NSImage {
        MenuBarGlyph.combined(slots: [
            MenuCombinedSlot(viz: .net(down: "1.2M", up: "386K"), tint: XColor.metricNetwork),
            MenuCombinedSlot(viz: .pie(0.71), tint: XColor.metricMemory),
            MenuCombinedSlot(viz: .histogram(Self.mbDemoHist), tint: XColor.metricCPU),
        ])
    }
    private var presetPreviewTemp: NSImage {
        MenuBarGlyph.combined(slots: [
            MenuCombinedSlot(viz: .net(down: "1.2M", up: "386K"), tint: XColor.metricNetwork),
            MenuCombinedSlot(viz: .pie(0.71), tint: XColor.metricMemory),
            MenuCombinedSlot(viz: .histogram(Self.mbDemoHist), tint: XColor.metricCPU),
            MenuCombinedSlot(viz: .text("44°"), tint: [XColor.warning]),
        ])
    }
    private var presetPreviewAll: NSImage {
        MenuBarGlyph.combined(slots: [
            MenuCombinedSlot(viz: .net(down: "1.2M", up: "386K"), tint: XColor.metricNetwork),
            MenuCombinedSlot(viz: .pie(0.71), tint: XColor.metricMemory),
            MenuCombinedSlot(viz: .histogram(Self.mbDemoHist), tint: XColor.metricCPU),
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
        // 网络一律 valueOnly（纯数值）；内存/CPU 用 rich（饼盘/直方）；顺序钉成 网络→内存→CPU→温度→磁盘。
        func base() {
            d.set(MenuBarStyle.valueOnly.rawValue, forKey: "xico.mb.network.style")
            d.set(MenuBarStyle.rich.rawValue, forKey: "xico.mb.memory.style")
            d.set(MenuBarStyle.rich.rawValue, forKey: "xico.mb.cpu.style")
        }
        switch name {
        case "basic":
            enable(["network", "memory", "cpu"])
            base()
            d.set("network,memory,cpu", forKey: "xico.mb.order")
            mbColored = false
        case "temp":
            enable(["network", "memory", "cpu", "temp"])
            base()
            d.set(MenuBarStyle.iconValue.rawValue, forKey: "xico.mb.temp.style")
            d.set("network,memory,cpu,temp", forKey: "xico.mb.order")
            mbColored = false
        default:   // all
            enable(["network", "memory", "cpu", "temp", "disk"])
            base()
            d.set(MenuBarStyle.iconValue.rawValue, forKey: "xico.mb.temp.style")
            d.set(MenuBarStyle.rich.rawValue, forKey: "xico.mb.disk.style")
            d.set("network,memory,cpu,temp,disk", forKey: "xico.mb.order")
            mbColored = false
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
                toggleRow(xLoc("图形前显示图标"), mbBool("xico.mb.combined.icons", default: false))
                VStack(alignment: .leading, spacing: 3) {
                    toggleRow(xLoc("刘海屏自动省宽"), mbBool("xico.mb.combined.notchAdapt", default: false))
                    Text(xLoc("检测到刘海时自动收起数值文字，寸土寸金"))
                        .font(XFont.caption).foregroundStyle(XColor.textTertiary)
                }
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
            // 温度传感器源（P1 多传感器）：CPU（默认）/ GPU / SSD。
            if item.id == "temp" {
                HStack(spacing: XSpacing.xs) {
                    Text(xLoc("传感器")).font(XFont.caption).foregroundStyle(XColor.textSecondary)
                    Picker("", selection: Binding(
                        get: { UserDefaults.standard.string(forKey: "xico.mb.temp.source") ?? "cpu" },
                        set: { UserDefaults.standard.set($0, forKey: "xico.mb.temp.source") })) {
                        Text(xLoc("处理器")).tag("cpu")
                        Text("GPU").tag("gpu")
                        Text(xLoc("固态硬盘")).tag("ssd")
                    }
                    .labelsHidden().pickerStyle(.menu).fixedSize()
                    .accessibilityLabel(xLoc("传感器"))
                }
            }
            // 磁盘卷选择（P1）：默认主卷；可切外置/其他卷（0 = 跟随主卷）。
            if item.id == "disk" {
                HStack(spacing: XSpacing.xs) {
                    Text(xLoc("卷")).font(XFont.caption).foregroundStyle(XColor.textSecondary)
                    Picker("", selection: Binding(
                        get: { UserDefaults.standard.string(forKey: "xico.mb.disk.volume") ?? "" },
                        set: { v in
                            if v.isEmpty { UserDefaults.standard.removeObject(forKey: "xico.mb.disk.volume") }
                            else { UserDefaults.standard.set(v, forKey: "xico.mb.disk.volume") }
                        })) {
                        Text(xLoc("主卷（默认）")).tag("")
                        ForEach(mountedVolumePaths(), id: \.self) { path in
                            Text(URL(fileURLWithPath: path).lastPathComponent).tag(path)
                        }
                    }
                    .labelsHidden().pickerStyle(.menu).fixedSize()
                    .accessibilityLabel(xLoc("卷"))
                }
            }
            // 内存口径：Xico 解释性压力指数（默认）/ 物理占用（已用÷总量）。
            if item.id == "memory" {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: XSpacing.xs) {
                        Text(xLoc("口径")).font(XFont.caption).foregroundStyle(XColor.textSecondary)
                        Picker("", selection: Binding(
                            get: { UserDefaults.standard.string(forKey: "xico.mb.memory.metric") ?? "pressure" },
                            set: { UserDefaults.standard.set($0, forKey: "xico.mb.memory.metric") })) {
                            Text(xLoc(MemoryPressureDisplayCopy.indexLabel)).tag("pressure")
                            Text(xLoc("占用")).tag("used")
                        }
                        .labelsHidden().pickerStyle(.menu).fixedSize()
                        .accessibilityLabel(xLoc("口径"))
                    }
                    Text(xLoc(MemoryPressureDisplayCopy.explanation))
                        .font(XFont.caption).foregroundStyle(XColor.textTertiary)
                }
            }
            if item.id == "cpu" || item.id == "memory" {
                monitoringPresentationControls
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

    private var monitoringPresentationControls: some View {
        VStack(alignment: .leading, spacing: XSpacing.s) {
            Divider()
            HStack(spacing: XSpacing.xs) {
                Text(xLoc("CPU · 口径")).font(XFont.caption).foregroundStyle(XColor.textSecondary)
                Picker("", selection: $monitoringCPUMode) {
                    Text(xLoc("归一化 0–100%")).tag(CPUDisplayMode.normalized.rawValue)
                    Text(xLoc("总核心 0–N×100%")).tag(CPUDisplayMode.totalCore.rawValue)
                }
                .labelsHidden().pickerStyle(.menu).fixedSize()
                .accessibilityLabel(xLoc("CPU · 口径"))
                Spacer()
            }
            HStack {
                Text(xLoc("合并应用进程")).font(XFont.caption).foregroundStyle(XColor.textSecondary)
                Spacer()
                Toggle("", isOn: $monitoringCombinesProcesses)
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .labelsHidden()
                    .accessibilityLabel(xLoc("合并应用进程"))
                    .onChange(of: monitoringCombinesProcesses) {
                        model.prepareApplicationSampling()
                    }
            }
            HStack(spacing: XSpacing.l) {
                HStack(spacing: XSpacing.xs) {
                    Text(xLoc("排行数量")).font(XFont.caption).foregroundStyle(XColor.textSecondary)
                    Picker("", selection: $monitoringProcessLimit) {
                        ForEach([4, 6, 10, 20], id: \.self) { limit in
                            Text("\(limit)").tag(limit)
                        }
                    }
                    .labelsHidden().pickerStyle(.menu).fixedSize()
                    .accessibilityLabel(xLoc("排行数量"))
                }
                HStack(spacing: XSpacing.xs) {
                    Text(xLoc("密度")).font(XFont.caption).foregroundStyle(XColor.textSecondary)
                    Picker("", selection: $monitoringDensity) {
                        Text(xLoc("紧凑")).tag(MonitoringPanelDensity.compact.rawValue)
                        Text(xLoc("均衡")).tag(MonitoringPanelDensity.balanced.rawValue)
                        Text(xLoc("详细")).tag(MonitoringPanelDensity.detailed.rawValue)
                    }
                    .labelsHidden().pickerStyle(.menu).fixedSize()
                    .accessibilityLabel(xLoc("密度"))
                }
                Spacer()
            }
            HStack(spacing: XSpacing.xs) {
                Text(xLoc("内存单位")).font(XFont.caption).foregroundStyle(XColor.textSecondary)
                Picker("", selection: $monitoringMemoryUnit) {
                    Text(xLoc("十进制 GB / MB")).tag(MemoryUnitStyle.decimal.rawValue)
                    Text(xLoc("二进制 GiB / MiB")).tag(MemoryUnitStyle.binary.rawValue)
                }
                .labelsHidden().pickerStyle(.menu).fixedSize()
                .accessibilityLabel(xLoc("内存单位"))
                Spacer()
            }
        }
    }

    /// 已挂载的可写数据卷路径（/Volumes 下 + 根卷），供磁盘项卷选择器。
    private func mountedVolumePaths() -> [String] {
        let keys: [URLResourceKey] = [.volumeIsBrowsableKey, .volumeIsLocalKey]
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys,
                                                         options: [.skipHiddenVolumes]) ?? []
        return urls.compactMap { url in
            guard let rv = try? url.resourceValues(forKeys: Set(keys)),
                  rv.volumeIsBrowsable == true else { return nil }
            return url.path
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
        case .loadAvg:
            Text("1.2 1.0 0.9").font(XFont.microMono)
        case .stacked:
            VStack(alignment: .leading, spacing: 0) {
                Text("CPU 42%").font(XFont.nano)
                Text("MEM 61%").font(XFont.nano).opacity(0.7)
            }
        case .coreGrid:
            HStack(alignment: .bottom, spacing: 1) {
                ForEach(Array([0.4, 0.8, 0.3, 0.9, 0.5, 0.7, 0.2, 0.6].enumerated()), id: \.offset) { _, v in
                    Capsule().opacity(0.55 + 0.45 * v)
                        .frame(width: 1.5, height: max(2, 12 * CGFloat(v)))
                }
            }
        case .interface:
            VStack(alignment: .leading, spacing: 0) {
                Text("en0").font(XFont.nano)
                Text("↓1.2M ↑386K").font(XFont.nano).opacity(0.7)
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
