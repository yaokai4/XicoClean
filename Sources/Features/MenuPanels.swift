import SwiftUI
import AppKit
import Combine
import Domain
import Infrastructure
import DesignSystem
import Shared

enum MemoryPressureDisplayCopy {
    static let indexLabel = "Xico 压力指数"
    static let stateLabel = "内存压力"
    static let explanation = "综合内存压力状态、可用内存、压缩和交换区计算，不是 macOS 提供的百分比。"

    static func percentage(_ value: Double?) -> String {
        guard let value else { return "—" }
        let bounded = min(1, max(0, value))
        return "\(Int((bounded * 100).rounded()))%"
    }
}

/// 已用/总量的单行展示（"11.15 / 16.00 GiB"）：单位相同只在总量标注一次；
/// 已用不足 1 GiB 等单位不同的场合，已用侧带上自己的单位，避免误读成同单位。
struct MemoryUsedOfTotalDisplay: Equatable {
    let used: String    // 与总量同单位时不带单位（"11.15"），否则完整（"512.00 MiB"）
    let total: String   // 恒带单位（"16.00 GiB"）

    init(usedBytes: Int64, totalBytes: Int64, style: MemoryUnitStyle) {
        let usedText = usedBytes.formattedMemory(style: style)
        let totalText = totalBytes.formattedMemory(style: style)
        total = totalText
        let usedParts = usedText.split(separator: " ")
        if usedParts.count == 2, let totalUnit = totalText.split(separator: " ").last,
           usedParts[1] == totalUnit {
            used = String(usedParts[0])
        } else {
            used = usedText
        }
    }
}

/// 每进程网络流量区块（面板可见期间每 ~3s 后台采样一轮；nettop 不可用时整块消失）。
private struct NetTopSection: View {
    @State private var usages: [ProcessNetUsage]?
    @State private var unavailable = false


    var body: some View {
        Group {
            if let usages, !usages.isEmpty {
                XMonitoringSection {
                    VStack(alignment: .leading, spacing: XSpacing.xs + 2) {
                        Text(xLoc("流量排行")).font(XFont.captionEmphasis).foregroundStyle(XColor.textPrimary)
                        ForEach(usages) { u in
                            HStack(spacing: XSpacing.s) {
                                Text(u.name).font(XFont.caption).foregroundStyle(XColor.textPrimary)
                                    .lineLimit(1).truncationMode(.middle)
                                Spacer(minLength: XSpacing.s)
                                Text("↓" + u.bytesInPerSec.compactRate).font(XFont.microMono).foregroundStyle(XColor.netDown)
                                Text("↑" + u.bytesOutPerSec.compactRate).font(XFont.microMono).foregroundStyle(XColor.netUp)
                            }
                        }
                    }
                }
            }
        }
        .task {
            guard !unavailable else { return }
            while !Task.isCancelled {
                let result = await Task.detached(priority: .utility) { netTopGlobalSampler.sample(top: 4) }.value
                guard !Task.isCancelled else { return }
                if let result {
                    withAnimation(XMotion.crossfade) { usages = result }
                } else {
                    unavailable = true   // nettop 不可用：不再重试、整块隐藏
                    return
                }
                try? await Task.sleep(nanoseconds: 3_000_000_000)
            }
        }
    }
}

/// 用户/系统双色堆叠直方条（iStat 式 CPU 历史）：底层=用户（冷蓝），顶层=系统（玫红）。
private struct StackedCPUBars: View {
    let user: [Double]
    let system: [Double]
    /// 槽位固定 60、右对齐：条宽不随样本数变化，冷启动前几秒不会渲染成几块巨大的色板。
    private static let slots = 60
    var body: some View {
        Canvas { ctx, size in
            let u = Array(user.suffix(Self.slots))
            let sys = Array(system.suffix(Self.slots))
            let n = min(u.count, sys.count)
            guard n > 0 else { return }
            let gap: CGFloat = 1
            let barW = max(1, (size.width - CGFloat(Self.slots - 1) * gap) / CGFloat(Self.slots))
            let userColor = XColor.auroraBlue, sysColor = XColor.accentPink
            for i in 0..<n {
                let slot = Self.slots - n + i   // 最新样本贴右缘，历史向左生长
                let x = CGFloat(slot) * (barW + gap)
                let uh = size.height * CGFloat(min(max(u[u.count - n + i], 0), 1))
                let sh = size.height * CGFloat(min(max(sys[sys.count - n + i], 0), 1))
                // 用户段（底）
                ctx.fill(Path(CGRect(x: x, y: size.height - uh, width: barW, height: uh)),
                         with: .color(userColor.opacity(0.9)))
                // 系统段（叠在用户之上）
                ctx.fill(Path(CGRect(x: x, y: size.height - uh - sh, width: barW, height: sh)),
                         with: .color(sysColor.opacity(0.9)))
            }
        }
        .accessibilityHidden(true)
    }
}

/// 图表区头：标题（含可选图例）+ 时间窗选择器。选择器的布局宽度不可压缩（scaleEffect 只缩
/// 渲染不缩布局），de/fr/ru 等长文案语种一行放不下时，优雅折成「标题行 + 右对齐选择器行」。
private struct ChartSectionHeader<Leading: View, Trailing: View>: View {
    private let leading: Leading
    private let trailing: Trailing
    init(@ViewBuilder leading: () -> Leading, @ViewBuilder trailing: () -> Trailing) {
        self.leading = leading()
        self.trailing = trailing()
    }
    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: XSpacing.s) {
                leading
                Spacer(minLength: XSpacing.s)
                trailing
            }
            VStack(alignment: .leading, spacing: XSpacing.xs) {
                HStack(spacing: XSpacing.s) { leading }
                HStack { Spacer(minLength: 0); trailing }
            }
        }
    }
}

private enum MemoryPanelHistoryMetric: String, CaseIterable {
    case pressure
    case compression
    case swap

    var title: String {
        switch self {
        case .pressure: return xLoc("压力")
        case .compression: return xLoc("压缩")
        case .swap: return xLoc("交换区")
        }
    }
}

public enum MenuMetric: Sendable {
    case cpu, memory, network, temperature, disk, gpu, battery

    var title: String {
        switch self {
        case .cpu: return xLoc("处理器")
        case .memory: return xLoc("内存")
        case .network: return xLoc("网络")
        case .temperature: return xLoc("温度")
        case .disk: return xLoc("磁盘")
        case .gpu: return "GPU"
        case .battery: return xLoc("电池")
        }
    }
    var icon: String {
        switch self {
        case .cpu: return "cpu"
        case .memory: return "memorychip"
        case .network: return "antenna.radiowaves.left.and.right"
        case .temperature: return "thermometer.medium"
        case .disk: return "internaldrive"
        case .gpu: return "cpu.fill"
        case .battery: return "battery.100percent"
        }
    }
    var colors: [Color] {
        switch self {
        case .cpu: return [XColor.auroraBlue]
        case .memory: return [XColor.auroraViolet]
        case .network: return XColor.metricNetwork
        case .temperature: return [XColor.warning, XColor.accentPink]
        case .disk: return XColor.metricDisk
        case .gpu: return XColor.metricGPU
        case .battery: return [XColor.success, XColor.accentTeal]
        }
    }
}

@MainActor
enum MenuMetricPanelTelemetryUpdate {
    static var transaction: Transaction {
        var transaction = Transaction()
        transaction.animation = nil
        transaction.disablesAnimations = true
        return transaction
    }
}

/// 单指标的菜单栏详情面板（CPU / 内存 / 网络 各一个，独立菜单栏项）
public struct MenuMetricPanel: View {
    @ObservedObject var model: AppModel
    /// 卡片只订阅菜单栏专用流，不加入 MetricsFeed 的全局 ObservableObject 失效域。
    let feed: MetricsFeed
    let metric: MenuMetric
    @State private var currentSnapshot: SystemSnapshot?
    /// 快速释放内存的进行/结果状态（本面板内联反馈，不弹窗）。
    @State private var freeingMemory = false
    @State private var freeMemNote: String?
    /// 折线时间窗（实时 / 15 分 / 1 时），全部面板共享同一偏好（P3·M4）。
    @AppStorage("xico.mb.panel.window") private var windowRaw = "live"
    @AppStorage(MonitoringPreferences.cpuModeKey) private var cpuModeRaw = CPUDisplayMode.normalized.rawValue
    @AppStorage(MonitoringPreferences.memoryUnitKey) private var memoryStyleRaw = MemoryUnitStyle.binary.rawValue
    @AppStorage(MonitoringPreferences.densityKey) private var densityRaw = MonitoringPanelDensity.balanced.rawValue
    @State private var selectedApplication: ApplicationIdentity?
    @State private var memoryHistoryMetricRaw = MemoryPanelHistoryMetric.pressure.rawValue
    @State private var memoryHistory = MemoryPanelHistoryAccumulator()
    /// 图例字号的动态字体档位（与 XFont.caption / XFont.mono 的默认磅值对齐），
    /// 供 legendColumnCount 用真实字宽预检双列是否放得下。
    @ScaledMetric(relativeTo: .subheadline) private var legendLabelFontSize: CGFloat = 11
    @ScaledMetric(relativeTo: .body) private var legendValueFontSize: CGFloat = 13

    private var window: HistoryWindow { HistoryWindow(rawValue: windowRaw) ?? .live }
    private var cpuMode: CPUDisplayMode { CPUDisplayMode(rawValue: cpuModeRaw) ?? .normalized }
    private var memoryStyle: MemoryUnitStyle { MemoryUnitStyle(rawValue: memoryStyleRaw) ?? .binary }
    private var density: MonitoringPanelDensity { MonitoringPanelDensity(rawValue: densityRaw) ?? .balanced }
    private var panelWidth: CGFloat {
        switch density {
        case .compact: return 320
        case .balanced: return 336
        case .detailed: return 380
        }
    }

    public init(model: AppModel, metric: MenuMetric) {
        self.model = model
        self.feed = model.liveMetricsFeed
        self.metric = metric
        self._currentSnapshot = State(initialValue: model.liveMetricsFeed.liveSnapshot)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: XSpacing.m) {
            HStack(spacing: XSpacing.s) {
                XIconTile(systemImage: metric.icon, colors: metric.colors, size: 28, flat: true)
                Text(xLoc(metric.title)).font(XFont.headline).foregroundStyle(XColor.textPrimary)
                Spacer()
                if let chip = model.macInfo?.chip {
                    Text(chip).font(XFont.caption).foregroundStyle(XColor.textTertiary)
                }
            }

            if let s = currentSnapshot {
                if let hint = insight(s) { insightBar(hint) }
                content(s)
            } else {
                XSpinner().frame(maxWidth: .infinity)
            }

            Divider().padding(.vertical, 2)
            // 页脚 = 可执行入口（KILLER-1，三合一独占空档）：监控面板不止「看数字」，
            // 磁盘 → 深潜空间透镜；内存/磁盘 → 一键清理。iStat 只能看不能做。
            HStack(spacing: XSpacing.m) {
                Button { openMonitor() } label: {
                    HStack(spacing: XSpacing.xs) {
                        Image(systemName: "waveform.path.ecg")
                        Text(xLoc("打开监视器"))
                    }
                    .font(XFont.captionEmphasis)
                    .foregroundStyle(XColor.brand)
                }
                .buttonStyle(.plain)
                if metric == .disk {
                    Button { openModule(.spaceLens) } label: {
                        HStack(spacing: XSpacing.xs) {
                            Image(systemName: "circle.hexagongrid.fill")
                            Text(xLoc("空间透镜"))
                        }
                        .font(XFont.captionEmphasis)
                        .foregroundStyle(XColor.brand)
                    }
                    .buttonStyle(.plain)
                }
                if metric == .disk || metric == .memory {
                    Button { openSmartScan() } label: {
                        HStack(spacing: XSpacing.xs) {
                            Image(systemName: "sparkles")
                            Text(xLoc("一键清理"))
                        }
                        .font(XFont.captionEmphasis)
                        .foregroundStyle(XColor.brand)
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
                Button { NSApp.terminate(nil) } label: {
                    Image(systemName: "power").font(XFont.captionEmphasis)
                        .foregroundStyle(XColor.textTertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(xLoc("退出"))
            }
            .layoutPriority(2)
        }
        .padding(XSpacing.m)
        .frame(width: panelWidth)
        .onReceive(feed.snapshotPublisher.compactMap { $0 }) { snapshot in
            withTransaction(MenuMetricPanelTelemetryUpdate.transaction) {
                currentSnapshot = snapshot
                if metric == .memory { recordMemoryHistory(snapshot) }
            }
        }
        .sheet(item: $selectedApplication) { identity in
            ApplicationUsageInspector(
                feed: feed,
                identity: identity,
                cpuMode: cpuMode,
                memoryStyle: memoryStyle)
        }
    }

    /// 打开主窗口的系统监视页。
    private func openMonitor() { openModule(.monitor) }

    /// 打开主窗口的任意模块（深链通用入口，KILLER-1）。
    private func openModule(_ id: ModuleID) {
        NSApp.activate(ignoringOtherApps: true)
        model.selection = id
        for w in NSApp.windows where w.canBecomeMain { w.makeKeyAndOrderFront(nil) }
    }

    // MARK: 轻量洞察（P2·AI 解读的规则内核：阈值 + 进程榜归因，严格基于真实数据，不编造）

    /// 面板顶部的一句话洞察；无异常返回 nil（不占位、不制造焦虑）。
    private func insight(_ s: SystemSnapshot) -> String? {
        switch metric {
        case .memory:
            if s.memoryPressure >= 4 || (s.memoryPressureIndex ?? 0) >= 0.7 {
                if let top = model.topByMemory.first {
                    return xLocF("内存压力偏高——%@ 占 %@，建议关闭或一键清理", top.name, top.memoryBytes.formattedMemory)
                }
                return xLoc("内存压力偏高，建议关闭大内存应用")
            }
            if s.swapTotal > 0, s.swapUsedFraction >= 0.8 {
                return xLoc("交换区接近占满，系统正频繁换页")
            }
        case .disk:
            if s.diskTotal > 0, s.diskFree < 10 << 30 {
                return xLocF("磁盘仅剩 %@——用空间透镜找出大文件", s.diskFree.formattedBytes)
            }
        case .cpu:
            if s.cpuUsage >= 0.9, let top = model.topByCPU.first {
                return xLocF("CPU 接近满载——%@ 占 %.0f%%", top.name, top.cpuPercent)
            }
        case .temperature:
            if s.thermal == .critical || s.thermal == .serious {
                return xLoc("机器偏热，系统可能已降频——检查高占用进程")
            }
        case .battery:
            if let pct = s.batteryPercent, pct <= 15, !s.batteryCharging {
                return xLoc("电量偏低，建议连接电源")
            }
        default: break
        }
        return nil
    }

    private func insightBar(_ text: String) -> some View {
        HStack(spacing: XSpacing.s) {
            Image(systemName: "lightbulb.fill").font(XFont.micro).foregroundStyle(XColor.warning)
            Text(text).font(XFont.caption).foregroundStyle(XColor.textSecondary)
                .lineLimit(2).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, XSpacing.s).padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: XRadius.chip, style: .continuous)
            .fill(XColor.warning.opacity(0.10)))
    }

    /// 快速清理：打开主窗口、切到智能扫描模块，并立即开始扫描——让「快速清理」名副其实
    /// （此前仅导航不扫描，标签与行为不符，审计 MenuPanels:119 P3）。已在扫描/已有结果则不打断。
    private func openSmartScan() {
        NSApp.activate(ignoringOtherApps: true)
        model.selection = .smartScan
        for w in NSApp.windows where w.canBecomeMain { w.makeKeyAndOrderFront(nil) }
        if model.smartScanHub.phase == .idle { model.smartScanHub.start() }
    }

    /// 快速释放非活跃内存（purge，经特权助手）。助手未安装则优雅降级为提示，不静默失败。
    private func freeMemory() {
        guard !freeingMemory else { return }
        guard model.env.helper.status() == .installed else {
            freeMemNote = xLoc("需先在「维护」页安装后台助手")
            return
        }
        freeingMemory = true
        freeMemNote = nil
        Task {
            let (ok, out) = await model.env.helper.runMaintenance(.freeMemory)
            freeingMemory = false
            freeMemNote = ok ? xLoc("已释放非活跃内存") : (out ?? xLoc("释放失败"))
        }
    }

    /// 折线时间窗切换（实时 / 15 分 / 1 时）——只在有分层数据的面板显示（P3·M4）。
    private var windowPicker: some View {
        XSegmentedControl(selection: $windowRaw, options: HistoryWindow.allCases.map {
            .init(tag: $0.rawValue, label: xLoc($0.title), a11y: xLoc($0.title))
        })
        .scaleEffect(0.88, anchor: .trailing)   // 面板内收紧一号
    }

    /// 带时间窗与悬停擦洗的历史折线（网格 + 值·时刻读数——能力在 XLineChart 里躺了很久，P3 启用）。
    private func historyChart(_ rings: HistoryRings, colors: [Color], height: CGFloat) -> some View {
        let series = window.series(from: rings)
        return XLineChart(values: series, colors: colors, showGrid: true,
                          updateCadence: .realtime,
                          hoverLabel: { i in
                              guard i >= 0, i < series.count else { return "" }
                              return "\(Int((series[i] * 100).rounded()))%"
                          })
            .frame(height: height)
    }

    @ViewBuilder private func content(_ s: SystemSnapshot) -> some View {
        switch metric {
        case .cpu:         cpuContent(s)
        case .memory:      memoryContent(s)
        case .network:     networkContent(s)
        case .temperature: temperatureContent(s)
        case .disk:        diskContent(s)
        case .gpu:         gpuContent(s)
        case .battery:     batteryContent(s)
        }
    }

    // MARK: - CPU 面板（CPU 单一主叙事 + 应用双指标排行）

    @ViewBuilder private func cpuContent(_ s: SystemSnapshot) -> some View {
        VStack(alignment: .leading, spacing: XSpacing.s) {
            XMonitoringSection {
                VStack(alignment: .leading, spacing: XSpacing.s) {
                    HStack(spacing: XSpacing.m) {
                        semanticGauge(s.cpuUsage, color: XColor.auroraBlue)
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel(xLoc("处理器"))
                            .accessibilityValue("\(Int((s.cpuUsage * 100).rounded()))%")
                        VStack(alignment: .leading, spacing: XSpacing.s) {
                            // 间距用 m：三芯片并排时给长标签语种（Temperature/Température）留满格宽。
                            HStack(spacing: XSpacing.m) {
                                metricChip(xLoc("用户"), "\(Int(s.cpuUser * 100))%")
                                metricChip(xLoc("系统"), "\(Int(s.cpuSystem * 100))%")
                                if let t = s.cpuTemp {
                                    metricChip(xLoc("温度"), String(format: "%.0f°C", t))
                                }
                            }
                            // 三个采样值并排会把它挤到折行——平均负载独占整行
                            //（高负载三元组如 173.43 · 224.24 · 146.20 需要 ~140pt）。
                            metricChip(xLoc("平均负载"), loadTriple(s))
                        }
                        Spacer(minLength: 0)
                    }
                    freqLine
                    if !s.perCore.isEmpty {
                        Divider().padding(.vertical, 1)
                        perCoreRings(s.perCore)
                    }
                    // 核构成与已运行同为静态元数据，合并成一行安静的注脚；
                    // 长文案语种（en/de/fr）一行放不下时折成两行，不截断。
                    if model.macInfo != nil {
                        ViewThatFits(in: .horizontal) {
                            HStack(spacing: XSpacing.s) {
                                cpuMetaCaption(s)
                                Spacer(minLength: XSpacing.s)
                                cpuUptimeCaption
                            }
                            VStack(alignment: .leading, spacing: 2) {
                                cpuMetaCaption(s)
                                cpuUptimeCaption
                            }
                        }
                    }
                }
            }
            XMonitoringSection {
                VStack(alignment: .leading, spacing: XSpacing.s) {
                    ChartSectionHeader {
                        // 实时窗：图例并入标题行，窗名后缀让位（选中的「实时」分段片已在同一行，
                        // 不省则 标题+图例+选择器 三者挤爆折行）；长窗单线无图例，保留窗名。
                        if window == .live, feed.cpuUserHistory.count > 1 {
                            Text("CPU")
                                .font(XFont.captionEmphasis)
                                .foregroundStyle(XColor.textPrimary)
                            chartLegendDot(XColor.auroraBlue, xLoc("用户"))
                            chartLegendDot(XColor.accentPink, xLoc("系统"))
                        } else {
                            Text("CPU · \(xLoc(window.title))")
                                .font(XFont.captionEmphasis)
                                .foregroundStyle(XColor.textPrimary)
                                .lineLimit(1)
                        }
                    } trailing: {
                        windowPicker
                    }
                    // 实时窗保留用户/系统拆分；长窗使用单一 CPU 蓝总占用线。
                    if window == .live, feed.cpuUserHistory.count > 1 {
                        StackedCPUBars(user: feed.cpuUserHistory, system: feed.cpuSysHistory)
                            .frame(height: 40)
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel(xLoc("处理器占用历史曲线"))
                            .accessibilityValue("\(Int((s.cpuUsage * 100).rounded()))%")
                    } else {
                        historyChart(feed.rings.cpu, colors: [XColor.auroraBlue], height: 40)
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel(xLoc("处理器占用历史曲线"))
                            .accessibilityValue("\(Int((s.cpuUsage * 100).rounded()))%")
                    }
                }
            }
            ApplicationUsageList(
                focus: .cpu,
                snapshot: feed.applicationUsage,
                cpuMode: cpuMode,
                memoryStyle: memoryStyle,
                totalMemory: s.memoryTotal,
                onSelect: { selectedApplication = $0 })
        }
    }

    /// P/E 核频率行（读得到才显；两者都 nil 时整行隐藏）。
    @ViewBuilder private var freqLine: some View {
        if model.cpuFreqP != nil || model.cpuFreqE != nil {
            HStack(spacing: XSpacing.l) {
                if let p = model.cpuFreqP { metricChip(xLoc("性能核频率"), freqText(p)) }
                if let e = model.cpuFreqE { metricChip(xLoc("能效核频率"), freqText(e)) }
                Spacer(minLength: 0)
            }
        }
    }

    /// 每核心迷你环：**统一一张按内核序号排列的网格**（不再拆成性能/能效两排，太挤太小）。
    /// 每行最多 8 个、核多自动换行，多核机型（M1 Max / M2 Ultra 等）也按序整齐铺开。
    /// 性能核在序号旁点一枚主色小点标注 P/E，既并排又不丢分组信息；构成另见下方文案。
    private func perCoreRings(_ cores: [Double]) -> some View {
        let clusters = model.macInfo?.coreClusters ?? []
        let hasClusters = clusters.count == cores.count
        let perRow = min(max(cores.count, 1), 8)
        let cols = Array(repeating: GridItem(.flexible(), spacing: XSpacing.xs), count: perRow)
        return LazyVGrid(columns: cols, spacing: XSpacing.s) {
            ForEach(Array(cores.enumerated()), id: \.offset) { idx, v in
                VStack(spacing: 2) {
                    XMiniRing(fraction: v, colors: [XColor.auroraBlue], size: 28, lineWidth: 3.5)
                    HStack(spacing: 2) {
                        if hasClusters && clusters[idx] {
                            Circle().fill(XColor.auroraBlue).frame(width: 3, height: 3)  // 性能核标记
                        }
                        Text("\(idx)").font(XFont.nano).foregroundStyle(XColor.textTertiary)
                    }
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(xLoc("每核心占用"))
        .accessibilityValue(xLocF("平均 %d%%", Int((cores.reduce(0, +) / Double(max(cores.count, 1))) * 100)))
    }

    /// 核构成注脚（有每核数据才显示，与环形网格呼应）。
    @ViewBuilder private func cpuMetaCaption(_ s: SystemSnapshot) -> some View {
        if !s.perCore.isEmpty {
            Text(coreCaption).font(XFont.caption).foregroundStyle(XColor.textTertiary)
                .lineLimit(1)
        }
    }

    /// 已运行注脚。
    @ViewBuilder private var cpuUptimeCaption: some View {
        if let uptime = model.macInfo?.uptime {
            Text("\(xLoc("已运行")) \(uptime)")
                .font(XFont.caption).foregroundStyle(XColor.textTertiary)
                .lineLimit(1)
        }
    }

    /// 历史图图例小点（标题行内联，不再独占一行）。
    private func chartLegendDot(_ color: Color, _ label: String) -> some View {
        HStack(spacing: 3) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(label).font(XFont.nano).foregroundStyle(XColor.textTertiary)
        }
        .accessibilityHidden(true)
    }

    private func loadTriple(_ s: SystemSnapshot) -> String {
        String(format: "%.2f · %.2f · %.2f", s.load1, s.load5, s.load15)
    }
    private func freqText(_ mhz: Double) -> String {
        mhz >= 1000 ? String(format: "%.2f GHz", mhz / 1000) : String(format: "%.0f MHz", mhz)
    }
    /// 有权威簇信息时环已按 P/E 真实分组标注，文案如实陈述总构成；否则只说逻辑核心数。
    private var coreCaption: String {
        guard let m = model.macInfo else { return "" }
        if !m.coreClusters.isEmpty && m.performanceCores > 0 && m.efficiencyCores > 0 {
            return xLocF("%d 核 · %d 性能 + %d 能效", m.cores, m.performanceCores, m.efficiencyCores)
        }
        return xLocF("%d 逻辑核心 · 每核实时", m.cores)
    }

    // MARK: - 内存面板（压力语义 + 物理组成 + 真实历史 + 应用双指标排行）

    @ViewBuilder private func memoryContent(_ s: SystemSnapshot) -> some View {
        let pressureIndexText = MemoryPressureDisplayCopy.percentage(s.memoryPressureIndex)
        let pressureGauge = XicoPressureGaugePresentation(index: s.memoryPressureIndex)
        let usedOfTotal = MemoryUsedOfTotalDisplay(
            usedBytes: s.memoryUsed, totalBytes: s.memoryTotal, style: memoryStyle)
        let usedPercentText = "\(Int((s.memoryUsedFraction * 100).rounded()))%"
        VStack(alignment: .leading, spacing: XSpacing.s) {
            XMonitoringSection {
                VStack(alignment: .leading, spacing: XSpacing.s) {
                    // 两只同规格仪表 + 一列文字：压力/用量各归其位，
                    // 「已用 / 总量」同一基线一行排完（此前总量折到第二行，像换行事故）。
                    HStack(alignment: .top, spacing: XSpacing.m) {
                        gaugeColumn(
                            fraction: pressureGauge.fraction,
                            color: pressureGauge.hasValue ? XColor.auroraViolet : XColor.textTertiary,
                            center: pressureIndexText,
                            label: xLoc(MemoryPressureDisplayCopy.indexLabel))
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel(xLoc(MemoryPressureDisplayCopy.indexLabel))
                            .accessibilityValue(pressureIndexText)
                        gaugeColumn(
                            fraction: s.memoryUsedFraction,
                            color: XColor.auroraViolet,
                            center: usedPercentText,
                            label: xLoc("已用"))
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel(xLoc("内存"))
                            .accessibilityValue(usedPercentText)
                        VStack(alignment: .leading, spacing: XSpacing.m) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(xLoc(MemoryPressureDisplayCopy.stateLabel)).font(XFont.nano)
                                    .foregroundStyle(XColor.textTertiary)
                                Text(xLoc(s.memoryPressureLabel)).font(XFont.captionEmphasis)
                                    .foregroundStyle(pressureColor(s))
                            }
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel(xLoc(MemoryPressureDisplayCopy.stateLabel))
                            .accessibilityValue(xLoc(s.memoryPressureLabel))
                            HStack(alignment: .firstTextBaseline, spacing: 3) {
                                Text(usedOfTotal.used)
                                    .font(XFont.monoLarge)
                                    .foregroundStyle(XColor.textPrimary)
                                Text(xLocF("/ %@", usedOfTotal.total))
                                    .font(XFont.caption)
                                    .foregroundStyle(XColor.textSecondary)
                            }
                            .monospacedDigit()
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel(xLoc("已用"))
                            .accessibilityValue("\(usedOfTotal.used) / \(usedOfTotal.total)")
                        }
                        .padding(.top, 2)
                        .layoutPriority(1)   // 数值列优先拿宽：128 GiB 机型的大数字不许截断
                        Spacer(minLength: 0)
                    }
                    memSegmentBar(s)
                    memLegendGrid(s)
                    Divider().padding(.vertical, 1)
                    HStack(spacing: XSpacing.l) {
                        metricChip(xLoc("换入分页"), feed.pageInRate.map(\.formattedRate) ?? "—")
                        metricChip(xLoc("换出分页"), feed.pageOutRate.map(\.formattedRate) ?? "—")
                        Spacer(minLength: 0)
                    }
                    if s.swapTotal > 0 { swapBar(s) }
                }
            }

            memoryHistorySection

            ApplicationUsageList(
                focus: .memory,
                snapshot: feed.applicationUsage,
                cpuMode: cpuMode,
                memoryStyle: memoryStyle,
                totalMemory: s.memoryTotal,
                onSelect: { selectedApplication = $0 })
        }
    }

    /// 仪表 + 底部小标签的一列（内存面板双仪表统一规格：同尺寸、同字号——此前两环大小/字号各异）。
    /// 定宽 64：长文案语种的标签在列内缩放/截断消化（悬停见全文），绝不挤压右侧数值列。
    private func gaugeColumn(fraction: Double, color: Color, center: String, label: String) -> some View {
        VStack(spacing: 3) {
            XSemanticGauge(fraction: fraction, color: color, size: 54, lineWidth: 6) {
                Text(center).font(XFont.monoMid)
                    .foregroundStyle(XColor.textPrimary)
                    .lineLimit(1).minimumScaleFactor(0.7)
            }
            Text(label).font(XFont.nano)
                .foregroundStyle(XColor.textTertiary)
                .lineLimit(1).minimumScaleFactor(0.7)
        }
        .frame(width: 64)
        .help(label)
    }

    /// 物理组成图例：双列网格（5 行压成 3 行，面板显著变短，内容一条不少）。
    /// 列数按真实字宽预检：CJK 标签双列绰绰有余；de/fr/ru 长标签或辅助大字号下
    /// 「最长标签 + 最宽值」放不下双列格时退回单列——绝不截断数据。
    private func memLegendGrid(_ s: SystemSnapshot) -> some View {
        let items: [(label: String, bytes: Int64, color: Color)] = [
            (xLoc("应用内存"), s.memoryApp, XColor.memApp),
            (xLoc("联动内存"), s.memoryWired, XColor.memWired),
            (xLoc("已压缩"), s.memoryCompressed, XColor.memCompressed),
            (xLoc("缓存文件"), s.memoryCached, XColor.memCached),
            (xLoc("可用"), s.memoryAvailable, XColor.memFree),
        ]
        return LazyVGrid(
            columns: Array(
                repeating: GridItem(.flexible(), spacing: XSpacing.l),
                count: legendColumnCount(items)),
            alignment: .leading,
            spacing: XSpacing.xs + 2) {
            ForEach(items, id: \.label) { item in
                memLegendRow(item.label, item.bytes, item.color)
            }
        }
    }

    private func legendColumnCount(_ items: [(label: String, bytes: Int64, color: Color)]) -> Int {
        // 内容宽 = 面板宽 − 面板留白（m×2）− 卡片留白（s×2）；双列格宽再减列距 l 对半。
        let contentWidth = panelWidth - XSpacing.m * 2 - XSpacing.s * 2
        let cellWidth = (contentWidth - XSpacing.l) / 2
        let labelFont = NSFont.systemFont(ofSize: legendLabelFontSize)
        let valueFont = NSFont.monospacedDigitSystemFont(ofSize: legendValueFontSize, weight: .semibold)
        let maxLabel = items
            .map { ($0.label as NSString).size(withAttributes: [.font: labelFont]).width }
            .max() ?? 0
        let maxValue = items
            .map { ($0.bytes.formattedMemory(style: memoryStyle) as NSString)
                .size(withAttributes: [.font: valueFont]).width }
            .max() ?? 0
        let dotAndGaps = 7 + XSpacing.s * 2   // 圆点 + 点距 + 标签值最小间隔
        return maxLabel + maxValue + dotAndGaps <= cellWidth ? 2 : 1
    }

    private func memSegmentBar(_ s: SystemSnapshot) -> some View {
        let total = max(1.0, Double(s.memoryTotal))
        // Available already includes cached files. Only mutually exclusive used categories become
        // colored segments; the unfilled track is available, while cached remains an explicit row.
        return XSegmentBar(segments: [
            .init(id: "app", fraction: Double(s.memoryApp) / total,        color: XColor.memApp),
            .init(id: "wired", fraction: Double(s.memoryWired) / total,    color: XColor.memWired),
            .init(id: "comp", fraction: Double(s.memoryCompressed) / total, color: XColor.memCompressed),
        ], height: 9, updateCadence: .realtime)
        .accessibilityHidden(true)
    }

    private func memLegendRow(_ label: String, _ bytes: Int64, _ color: Color) -> some View {
        HStack(spacing: XSpacing.s) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(label).font(XFont.caption).foregroundStyle(XColor.textSecondary)
                .lineLimit(1)
            Spacer(minLength: XSpacing.s)
            Text(bytes.formattedMemory(style: memoryStyle)).font(XFont.mono).foregroundStyle(XColor.textPrimary)
                .monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.8)
        }
    }

    private func swapBar(_ s: SystemSnapshot) -> some View {
        VStack(alignment: .leading, spacing: XSpacing.xs) {
            HStack {
                Text(xLoc("交换区")).font(XFont.caption).foregroundStyle(XColor.textSecondary)
                Spacer()
                Text(xLocF(
                    "%@ / %@",
                    s.swapUsed.formattedMemory(style: memoryStyle),
                    s.swapTotal.formattedMemory(style: memoryStyle)))
                    .font(XFont.mono).foregroundStyle(XColor.textPrimary)
            }
            XDiskBar(usedFraction: s.swapUsedFraction, label: "", height: 6)
        }
    }

    private func pressureColor(_ s: SystemSnapshot) -> Color {
        switch s.memoryPressure {
        case 4: return XColor.danger
        case 2: return XColor.warning
        default: return XColor.success
        }
    }

    private var memoryHistoryMetric: MemoryPanelHistoryMetric {
        MemoryPanelHistoryMetric(rawValue: memoryHistoryMetricRaw) ?? .pressure
    }

    private var selectedMemoryHistory: [Double] {
        switch memoryHistoryMetric {
        case .pressure: return memoryHistory.pressure
        case .compression: return memoryHistory.compression
        case .swap: return memoryHistory.swap
        }
    }

    private var memoryHistorySection: some View {
        XMonitoringSection {
            VStack(alignment: .leading, spacing: XSpacing.s) {
                ChartSectionHeader {
                    Text("\(xLoc("内存")) · 60 s")
                        .font(XFont.captionEmphasis)
                        .foregroundStyle(XColor.textPrimary)
                        .lineLimit(1)
                } trailing: {
                    XSegmentedControl(
                        selection: $memoryHistoryMetricRaw,
                        options: MemoryPanelHistoryMetric.allCases.map {
                            .init(tag: $0.rawValue, label: $0.title, a11y: $0.title)
                        })
                    .fixedSize(horizontal: true, vertical: false)
                    .scaleEffect(0.80, anchor: .trailing)
                }
                if selectedMemoryHistory.count > 1 {
                    XLineChart(
                        values: selectedMemoryHistory,
                        colors: [XColor.auroraViolet],
                        showGrid: true,
                        updateCadence: .realtime,
                        hoverLabel: { index in
                            guard selectedMemoryHistory.indices.contains(index) else { return "" }
                            return "\(Int((selectedMemoryHistory[index] * 100).rounded()))%"
                        })
                    .frame(height: 40)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(memoryHistoryMetric.title)
                    .accessibilityValue("\(Int(((selectedMemoryHistory.last ?? 0) * 100).rounded()))%")
                } else {
                    Text(xLoc("采样中"))
                        .font(XFont.caption)
                        .foregroundStyle(XColor.textTertiary)
                        .frame(maxWidth: .infinity, minHeight: 40, alignment: .center)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(memoryHistoryMetric.title)
                        .accessibilityValue(xLoc("采样中"))
                }
            }
        }
    }

    private func recordMemoryHistory(_ snapshot: SystemSnapshot) {
        memoryHistory.record(
            pressureIndex: snapshot.memoryPressureIndex,
            totalBytes: snapshot.memoryTotal,
            compressedBytes: snapshot.memoryCompressed,
            swapUsedBytes: snapshot.swapUsed,
            swapTotalBytes: snapshot.swapTotal)
    }

    // MARK: - 网络面板（大数字 + 会话峰值/累计 + 双线折线 + 接口清单）

    @ViewBuilder private func networkContent(_ s: SystemSnapshot) -> some View {
        VStack(alignment: .leading, spacing: XSpacing.s) {
            // 与 CPU/内存同一套卡片语言：实时速率、历史曲线、流量排行、接口各归其卡。
            XMonitoringSection {
                VStack(alignment: .leading, spacing: XSpacing.s) {
                    HStack(spacing: XSpacing.xl) {
                        rateColumn("arrow.down", XColor.netDown, xLoc("下载"), s.netDownBytesPerSec)
                        rateColumn("arrow.up", XColor.netUp, xLoc("上传"), s.netUpBytesPerSec)
                        Spacer()
                    }
                    Divider().padding(.vertical, 1)
                    sessionRow
                }
            }
            XMonitoringSection {
                VStack(alignment: .leading, spacing: XSpacing.s) {
                    ChartSectionHeader {
                        Text("\(xLoc("网络")) · \(xLoc(window.title))")
                            .font(XFont.captionEmphasis)
                            .foregroundStyle(XColor.textPrimary)
                            .lineLimit(1)
                    } trailing: {
                        windowPicker
                    }
                    networkChart.frame(height: 44)
                }
            }
            // 每进程流量（P6·3，iStat 支柱内容）：nettop 差分采样；不可用时整块隐藏（诚实降级）。
            NetTopSection()
            if !activeInterfaces.isEmpty {
                XMonitoringSection {
                    VStack(alignment: .leading, spacing: XSpacing.s) {
                        ForEach(activeInterfaces) { interfaceRow($0) }
                    }
                }
            }
        }
    }

    /// 会话峰值 / 累计芯片（下行薄荷、上行玫瑰，与折线同色系）。
    private var sessionRow: some View {
        HStack(spacing: XSpacing.l) {
            sessionStat(xLoc("峰值"), "↓ \(model.netDownPeak.compactRate)", "↑ \(model.netUpPeak.compactRate)")
            sessionStat(xLoc("本次累计"), "↓ \(model.sessionDownBytes.formattedBytes)", "↑ \(model.sessionUpBytes.formattedBytes)")
            Spacer(minLength: 0)
        }
    }
    private func sessionStat(_ label: String, _ down: String, _ up: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(XFont.caption).foregroundStyle(XColor.textTertiary)
            Text(down).font(XFont.microMono).foregroundStyle(XColor.netDown)
            Text(up).font(XFont.microMono).foregroundStyle(XColor.netUp)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var activeInterfaces: [NetworkInterfaceInfo] {
        Array(model.networkInterfaces.filter { $0.isActive }.prefix(3))
    }
    private func interfaceRow(_ i: NetworkInterfaceInfo) -> some View {
        HStack(spacing: XSpacing.s) {
            Image(systemName: i.type.icon).font(XFont.callout).foregroundStyle(XColor.accentTeal).frame(width: 18)
            VStack(alignment: .leading, spacing: 0) {
                Text(i.displayName).font(XFont.caption).foregroundStyle(XColor.textPrimary).lineLimit(1)
                if let ip = i.ipv4 ?? i.ipv6 {
                    Text(ip).font(XFont.captionMono).foregroundStyle(XColor.textTertiary).lineLimit(1)
                }
            }
            Spacer(minLength: XSpacing.s)
            VStack(alignment: .trailing, spacing: 0) {
                Text("↓ \(i.downBytesPerSec.compactRate)").font(XFont.microMono).foregroundStyle(XColor.netDown)
                Text("↑ \(i.upBytesPerSec.compactRate)").font(XFont.microMono).foregroundStyle(XColor.netUp)
            }
        }
    }

    private func semanticGauge(_ fraction: Double, color: Color) -> some View {
        XSemanticGauge(fraction: fraction, color: color, size: 60, lineWidth: 7) {
            Text("\(Int((fraction * 100).rounded()))%")
                .font(XFont.monoMid)
                .foregroundStyle(XColor.textPrimary)
        }
    }

    /// 非 CPU/内存面板保留现有主题环；精密 CPU/内存主指标只使用 semanticGauge。
    private func ringGauge(_ fraction: Double) -> some View {
        XMiniRing(fraction: fraction, colors: XColor.ringColors, size: 60, lineWidth: 7) {
            Text("\(Int((fraction * 100).rounded()))%")
                .font(XFont.monoMid)
                .foregroundStyle(XColor.textPrimary)
        }
    }

    private var networkChart: some View {
        // 分层时间窗（P3·M4）：按当前挡位取序列，双线同基准归一；悬停给出「↓ 下行 · ↑ 上行」真实速率。
        // 时间窗选择器已上移到区块标题行（与 CPU/内存历史区同构），这里只画图。
        let downRaw = window.series(from: feed.rings.netDown)
        let upRaw = window.series(from: feed.rings.netUp)
        let maxV = max((downRaw + upRaw).max() ?? 1, 1)
        let down = downRaw.map { $0 / maxV }
        let up = upRaw.map { $0 / maxV }
        return ZStack {
            XLineChart(values: down, colors: [XColor.netDown, XColor.ring(2)], showDot: false, showGrid: true,
                       updateCadence: .realtime,
                       hoverLabel: { i in
                           guard i >= 0, i < downRaw.count else { return "" }
                           let u = i < upRaw.count ? upRaw[i] : 0
                           return "↓\(downRaw[i].compactRate) ↑\(u.compactRate)"
                       })
            XLineChart(values: up, colors: [XColor.netUp, XColor.ring(1)], showFill: false, showDot: false,
                       updateCadence: .realtime)
        }
    }

    private func rateColumn(_ icon: String, _ color: Color, _ label: String, _ rate: Double) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: XSpacing.xs) {
                Image(systemName: icon).font(XFont.captionEmphasis).foregroundStyle(color)
                Text(label).font(XFont.caption).foregroundStyle(XColor.textSecondary)
            }
            Text(rate.formattedRate).font(XFont.monoLarge).foregroundStyle(XColor.textPrimary)
        }
    }

    private func metricChip(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(XFont.caption).foregroundStyle(XColor.textTertiary)
                .lineLimit(1).minimumScaleFactor(0.75)  // ru/fr 长标签在窄格里缩放而非截断
            Text(value).font(XFont.captionEmphasis).foregroundStyle(XColor.textPrimary)
                .monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.8)   // 数值宁可微缩不许折行（平均负载三元组等）
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - 温度面板（全部传感器 + 热状态 + 风扇，对标 iStat Sensors）

    @ViewBuilder private func temperatureContent(_ s: SystemSnapshot) -> some View {
        // 每帧只排一次序、SSD 均值只算一次（此前在 body 内重复排序/过滤，审计 P3 MenuPanels:472）。
        let sortedSensors = model.sensorTemps.sorted { $0.celsius > $1.celsius }
        let ssdAvg = avgTemp(.ssd)
        VStack(alignment: .leading, spacing: XSpacing.s) {
            // 三大代表温度：CPU / GPU / SSD（读不到的自动隐藏）
            HStack(spacing: XSpacing.l) {
                if let c = s.cpuTemp { tempHero(xLoc("处理器"), c) }
                if let g = s.gpuTemp { tempHero("GPU", g) }
                if let d = ssdAvg { tempHero(xLoc("固态硬盘"), d) }
                Spacer(minLength: 0)
                thermalChip(s.thermal)
            }
            if !sortedSensors.isEmpty {
                Divider().padding(.vertical, 1)
                // 全部命名传感器（按温度降序，滚动查看）——密度即诚意
                ScrollView {
                    VStack(spacing: 3) {
                        ForEach(sortedSensors) { t in
                            sensorRow(t)
                        }
                    }
                }
                .frame(maxHeight: 240)
            }
            if !model.fans.isEmpty {
                Divider().padding(.vertical, 1)
                Text(xLoc("风扇")).font(XFont.caption).foregroundStyle(XColor.textTertiary)
                ForEach(model.fans) { fan in fanRow(fan) }
            }
        }
    }

    private func tempHero(_ label: String, _ celsius: Double) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(XFont.caption).foregroundStyle(XColor.textSecondary)
                .lineLimit(1).minimumScaleFactor(0.85)
            Text("\(Int(celsius.rounded()))°")
                .font(XFont.monoLarge).foregroundStyle(tempColor(celsius))
                .contentTransition(.numericText())
        }
    }

    private func thermalChip(_ level: ThermalLevel) -> some View {
        let (color, icon): (Color, String) = {
            switch level {
            case .nominal: return (XColor.success, "checkmark.circle.fill")
            case .fair:    return (XColor.accentTeal, "thermometer.low")
            case .serious: return (XColor.warning, "thermometer.high")
            case .critical: return (XColor.danger, "flame.fill")
            }
        }()
        return HStack(spacing: 4) {
            Image(systemName: icon).font(XFont.micro)
            Text(xLoc(level.rawValue)).font(XFont.captionEmphasis)
        }
        .foregroundStyle(color)
        .padding(.horizontal, XSpacing.s).padding(.vertical, 4)
        .background(Capsule().fill(color.opacity(0.12)))
    }

    private func avgTemp(_ cat: TempReading.Category) -> Double? {
        let vals = model.sensorTemps.filter { $0.category == cat }.map(\.celsius)
        guard !vals.isEmpty else { return nil }
        return vals.reduce(0, +) / Double(vals.count)
    }

    /// 传感器显示名：把冗长的固件命名压成可读短名（完整名保留在悬停提示里）。
    /// 例：pACC MTR Temp Sensor4 → pACC #4 · SOC MTR Temp Sensor1 → SOC #1
    private func sensorDisplayName(_ raw: String) -> String {
        raw.replacingOccurrences(of: " MTR Temp Sensor", with: " #")
           .replacingOccurrences(of: " Temp Sensor", with: " #")
           .replacingOccurrences(of: "Temp Sensor", with: "#")
    }

    /// 单个传感器行：名称 + 热度条（20…105℃ 归一）+ 读数。
    private func sensorRow(_ t: TempReading) -> some View {
        let frac = min(1, max(0, (t.celsius - 20) / 85))
        return HStack(spacing: XSpacing.s) {
            Text(sensorDisplayName(t.name)).font(XFont.caption).foregroundStyle(XColor.textSecondary)
                .lineLimit(1).truncationMode(.middle)
                .frame(width: 128, alignment: .leading)
                .help(t.name)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(XColor.surfaceAlt)
                    Capsule()
                        .fill(LinearGradient(colors: [XColor.accentTeal, XColor.warning, XColor.danger],
                                             startPoint: .leading, endPoint: .trailing))
                        .frame(width: max(4, geo.size.width * frac))
                }
            }
            .frame(height: 5)
            Text(String(format: "%.0f°", t.celsius))
                .font(XFont.microMono).foregroundStyle(tempColor(t.celsius))
                .frame(width: 34, alignment: .trailing)
                .monospacedDigit()
        }
    }

    private func tempColor(_ c: Double) -> Color {
        if c >= 85 { return XColor.danger }
        if c >= 70 { return XColor.warning }
        return XColor.textPrimary
    }

    /// 风扇行：编号 + 区间条（含目标刻度）+ 当前转速。
    private func fanRow(_ fan: FanInfo) -> some View {
        HStack(spacing: XSpacing.s) {
            Image(systemName: "fan.fill").font(XFont.micro).foregroundStyle(XColor.accentTeal)
                .frame(width: 14)
            Text(xLocF("风扇 %d", fan.id + 1)).font(XFont.caption).foregroundStyle(XColor.textSecondary)
                .frame(width: 60, alignment: .leading)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(XColor.surfaceAlt)
                    Capsule().fill(XColor.accentTeal)
                        .frame(width: max(4, geo.size.width * fan.fraction))
                    if let tf = fan.targetFraction {
                        Rectangle().fill(XColor.textSecondary)
                            .frame(width: 1.5, height: 9)
                            .offset(x: geo.size.width * tf)
                    }
                }
            }
            .frame(height: 5)
            Text(xLocF("%d 转", fan.rpm))
                .font(XFont.microMono).foregroundStyle(XColor.textPrimary)
                .frame(width: 58, alignment: .trailing)
                .monospacedDigit()
        }
        .help(fan.target.map { xLocF("目标 %d", $0) } ?? "")
    }

    // MARK: - GPU 面板（利用率环 + 显存/核心/温度 + 历史曲线）

    @ViewBuilder private func gpuContent(_ s: SystemSnapshot) -> some View {
        VStack(alignment: .leading, spacing: XSpacing.s) {
            HStack(spacing: XSpacing.l) {
                ringGauge(s.gpuUsage ?? 0)
                VStack(alignment: .leading, spacing: 3) {
                    Text(model.gpuInfo?.name ?? model.macInfo?.chip ?? "GPU")
                        .font(XFont.bodyEmphasis).foregroundStyle(XColor.textPrimary)
                    if let cores = model.gpuInfo?.coreCount {
                        Text(xLocF("%d 核心", cores)).font(XFont.caption).foregroundStyle(XColor.textSecondary)
                    }
                }
                Spacer()
                if let t = s.gpuTemp { tempHero(xLoc("温度"), t) }
            }
            HStack(spacing: XSpacing.l) {
                if let mem = model.gpuInfo?.inUseMemoryBytes {
                    metricChip(xLoc("显存占用"), mem.formattedMemory)
                }
                metricChip(xLoc("利用率"), "\(Int(((s.gpuUsage ?? 0) * 100).rounded()))%")
                Spacer(minLength: 0)
            }
            ChartSectionHeader {
                Text("GPU · \(xLoc(window.title))")
                    .font(XFont.captionEmphasis)
                    .foregroundStyle(XColor.textPrimary)
                    .lineLimit(1)
            } trailing: {
                windowPicker
            }
            historyChart(feed.rings.gpu, colors: XColor.metricGPU, height: 40)
        }
    }

    // MARK: - 电池面板（P3·M10：真实快照数据——百分比 + 充电状态；台式机无电池时给明确说明）

    @ViewBuilder private func batteryContent(_ s: SystemSnapshot) -> some View {
        if let pct = s.batteryPercent {
            VStack(alignment: .leading, spacing: XSpacing.m) {
                HStack(spacing: XSpacing.l) {
                    XRingGauge(progress: Double(pct) / 100,
                               colors: s.batteryCharging ? [XColor.success, XColor.accentTeal]
                                                         : (pct <= 20 ? [XColor.danger, XColor.accentPink] : XColor.metricMemory),
                               lineWidth: 9, size: 96,
                               a11yLabel: xLoc("电池")) {
                        VStack(spacing: 0) {
                            Text("\(pct)%").font(XFont.monoMid).foregroundStyle(XColor.textPrimary)
                            if s.batteryCharging {
                                Image(systemName: "bolt.fill").font(XFont.nano).foregroundStyle(XColor.success)
                            }
                        }
                    }
                    VStack(alignment: .leading, spacing: XSpacing.s) {
                        XBadge(s.batteryCharging ? xLoc("充电中") : xLoc("使用电池"),
                               color: s.batteryCharging ? XColor.success : XColor.textSecondary)
                        // 剩余时间估算（P1 追平 iStat）：系统尚在估算/外接电源时不显示。
                        if let mins = s.batteryMinutesRemaining, mins > 0 {
                            Text(xLocF("剩余约 %d 小时 %d 分", mins / 60, mins % 60))
                                .font(XFont.captionEmphasis).foregroundStyle(XColor.textPrimary)
                        }
                        Text(xLoc("循环次数 / 健康度见「硬件」页"))
                            .font(XFont.caption).foregroundStyle(XColor.textTertiary)
                        Button(xLoc("打开硬件页")) {
                            NSApp.activate(ignoringOtherApps: true)
                            model.selection = .hardware
                            for w in NSApp.windows where w.canBecomeMain { w.makeKeyAndOrderFront(nil) }
                        }
                        .buttonStyle(XSecondaryButtonStyle(compact: true))
                    }
                    Spacer(minLength: 0)
                }
            }
        } else {
            Text(xLoc("此设备没有电池，或电池信息暂不可用。"))
                .font(XFont.body).foregroundStyle(XColor.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - 磁盘面板（读写大数字 + 双线图 + 每卷用量 + 健康，对标 iStat Disks）

    @ViewBuilder private func diskContent(_ s: SystemSnapshot) -> some View {
        VStack(alignment: .leading, spacing: XSpacing.s) {
            HStack(spacing: XSpacing.xl) {
                rateColumn("arrow.down.doc", XColor.netDown, xLoc("读取"), s.diskReadBytesPerSec)
                rateColumn("arrow.up.doc", XColor.netUp, xLoc("写入"), s.diskWriteBytesPerSec)
                Spacer()
            }
            diskChart.frame(height: 48)
            // 只展示真实磁盘：内置卷始终显示；外置卷剔除只读挂载镜像（0 可用的 DMG 噪音）。
            let realVolumes = model.storageVolumes.filter { $0.isInternal || $0.freeBytes > 0 }
            if !realVolumes.isEmpty {
                Divider().padding(.vertical, 1)
                ForEach(realVolumes) { vol in volumeRow(vol) }
            }
            // SSD 温度（有传感器才显示，与硬件页同源）
            if let ssdT = avgTemp(.ssd) {
                HStack(spacing: XSpacing.l) {
                    metricChip(xLoc("固态温度"), String(format: "%.0f℃", ssdT))
                    if let trim = model.storageVolumes.first(where: { $0.isInternal })?.trimEnabled {
                        metricChip("TRIM", trim ? xLoc("已启用") : xLoc("未启用"))
                    }
                    Spacer(minLength: 0)
                }
            }
        }
    }

    private var diskChart: some View {
        let maxV = max((model.diskReadHistory + model.diskWriteHistory).max() ?? 1, 1)
        let read = model.diskReadHistory.map { $0 / maxV }
        let write = model.diskWriteHistory.map { $0 / maxV }
        return ZStack {
            XLineChart(values: read, colors: [XColor.netDown, XColor.ring(2)], showDot: false,
                       updateCadence: .realtime)
            XLineChart(values: write, colors: [XColor.netUp, XColor.ring(1)], showFill: false, showDot: false,
                       updateCadence: .realtime)
        }
    }

    /// 单卷行：名称 + SMART 徽章 + 用量条 + 「可用/总量」。
    private func volumeRow(_ vol: StorageHealth) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: XSpacing.s) {
                Image(systemName: vol.isInternal ? "internaldrive.fill" : "externaldrive.fill")
                    .font(XFont.micro).foregroundStyle(XColor.accentTeal)
                Text(vol.name).font(XFont.captionEmphasis).foregroundStyle(XColor.textPrimary)
                    .lineLimit(1).truncationMode(.middle)
                if vol.isInternal, vol.smartStatus == "正常" {
                    Text("SMART").font(XFont.nano)
                        .foregroundStyle(XColor.success)
                        .padding(.horizontal, 4).padding(.vertical, 1.5)
                        .background(Capsule().fill(XColor.success.opacity(0.14)))
                }
                Spacer()
                Text(xLocF("%@ 可用", vol.freeBytes.formattedBytes))
                    .font(XFont.microMono).foregroundStyle(XColor.textSecondary)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(XColor.surfaceAlt)
                    Capsule()
                        .fill(LinearGradient(colors: XColor.metricDisk, startPoint: .leading, endPoint: .trailing))
                        .frame(width: max(4, geo.size.width * vol.usedFraction))
                }
            }
            .frame(height: 6)
        }
    }
}

/// 文件级采样器实例（NetTopSampler 为 Sendable 类；避免 @MainActor View 的静态属性隔离限制）。
private let netTopGlobalSampler = NetTopSampler()
