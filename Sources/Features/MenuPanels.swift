import SwiftUI
import AppKit
import Infrastructure
import DesignSystem
import Shared

/// 每进程网络流量区块（面板可见期间每 ~3s 后台采样一轮；nettop 不可用时整块消失）。
private struct NetTopSection: View {
    @State private var usages: [ProcessNetUsage]?
    @State private var unavailable = false


    var body: some View {
        Group {
            if let usages, !usages.isEmpty {
                VStack(alignment: .leading, spacing: XSpacing.xs) {
                    Divider().padding(.vertical, 1)
                    Text(xLoc("流量排行")).font(XFont.nano).foregroundStyle(XColor.textTertiary).tracking(0.4)
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
    var body: some View {
        Canvas { ctx, size in
            let u = Array(user.suffix(60))
            let sys = Array(system.suffix(60))
            let n = min(u.count, sys.count)
            guard n > 0 else { return }
            let gap: CGFloat = 1
            let barW = max(1, (size.width - CGFloat(n - 1) * gap) / CGFloat(n))
            let userColor = XColor.ring(2), sysColor = XColor.ring(0)
            for i in 0..<n {
                let x = CGFloat(i) * (barW + gap)
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
        case .cpu: return XColor.metricCPU
        case .memory: return XColor.metricMemory
        case .network: return XColor.metricNetwork
        case .temperature: return [XColor.warning, XColor.accentPink]
        case .disk: return XColor.metricDisk
        case .gpu: return XColor.metricGPU
        case .battery: return [XColor.success, XColor.accentTeal]
        }
    }
}

/// 单指标的菜单栏详情面板（CPU / 内存 / 网络 各一个，独立菜单栏项）
public struct MenuMetricPanel: View {
    @ObservedObject var model: AppModel
    /// 高频快照/进程榜/传感器现归 MetricsFeed（AppModel 不再每 tick 重发布，审计 P2）——本面板须观察 feed 才能实时更新。
    @ObservedObject var feed: MetricsFeed
    let metric: MenuMetric
    /// 快速释放内存的进行/结果状态（本面板内联反馈，不弹窗）。
    @State private var freeingMemory = false
    @State private var freeMemNote: String?
    /// 折线时间窗（实时 / 15 分 / 1 时），全部面板共享同一偏好（P3·M4）。
    @AppStorage("xico.mb.panel.window") private var windowRaw = "live"

    private var window: HistoryWindow { HistoryWindow(rawValue: windowRaw) ?? .live }

    public init(model: AppModel, metric: MenuMetric) {
        self.model = model
        self._feed = ObservedObject(wrappedValue: model.liveMetricsFeed)
        self.metric = metric
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

            if let s = model.liveSnapshot {
                content(s)
            } else {
                XSpinner().frame(maxWidth: .infinity)
            }

            Divider().padding(.vertical, 2)
            // 轻页脚（P9 减负）：面板专注监控数据本身——快捷操作只保留「打开监视器」文字链
            // 与退出，不再在每个面板塞「释放内存/快速清理」大按钮。
            HStack {
                Button { openMonitor() } label: {
                    HStack(spacing: XSpacing.xs) {
                        Image(systemName: "waveform.path.ecg")
                        Text(xLoc("打开监视器"))
                    }
                    .font(XFont.captionEmphasis)
                    .foregroundStyle(XColor.brand)
                }
                .buttonStyle(.plain)
                Spacer()
                Button { NSApp.terminate(nil) } label: {
                    Image(systemName: "power").font(XFont.captionEmphasis)
                        .foregroundStyle(XColor.textTertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(xLoc("退出"))
            }
        }
        .padding(XSpacing.m)
        .frame(width: 320)
    }

    /// 打开主窗口的系统监视页。
    private func openMonitor() {
        NSApp.activate(ignoringOtherApps: true)
        model.selection = .monitor
        for w in NSApp.windows where w.canBecomeMain { w.makeKeyAndOrderFront(nil) }
    }

    /// 快速清理：打开主窗口、切到智能扫描模块，并立即开始扫描——让「快速清理」名副其实
    /// （此前仅导航不扫描，标签与行为不符，审计 MenuPanels:119 P3）。已在扫描/已有结果则不打断。
    private func openSmartScan() {
        NSApp.activate(ignoringOtherApps: true)
        model.selection = .smartScan
        for w in NSApp.windows where w.canBecomeMain { w.makeKeyAndOrderFront(nil) }
        if model.smartScanSession.phase == .idle { model.smartScanSession.start() }
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

    // MARK: - CPU 面板（每核心迷你环 + 频率 + 负载 + GPU 环 + 开机时长 + 进程榜）

    @ViewBuilder private func cpuContent(_ s: SystemSnapshot) -> some View {
        VStack(alignment: .leading, spacing: XSpacing.m) {
            HStack(spacing: XSpacing.m) {
                ringGauge(s.cpuUsage)
                VStack(alignment: .leading, spacing: XSpacing.s) {
                    HStack(spacing: XSpacing.l) {
                        metricChip(xLoc("用户"), "\(Int(s.cpuUser * 100))%")
                        metricChip(xLoc("系统"), "\(Int(s.cpuSystem * 100))%")
                    }
                    HStack(spacing: XSpacing.l) {
                        metricChip(xLoc("平均负载"), loadTriple(s))
                        if let t = s.cpuTemp { metricChip(xLoc("温度"), String(format: "%.0f°C", t)) }
                    }
                }
                Spacer(minLength: 0)
            }
            freqLine
            if !s.perCore.isEmpty {
                Divider().padding(.vertical, 1)
                perCoreRings(s.perCore)
                Text(coreCaption).font(XFont.caption).foregroundStyle(XColor.textTertiary)
            }
            Divider().padding(.vertical, 1)
            HStack(spacing: XSpacing.m) {
                if let g = s.gpuUsage { gpuSegment(g) }
                Spacer(minLength: 0)
                metricChip(xLoc("已运行"), model.macInfo?.uptime ?? "—")
            }
            HStack {
                Spacer()
                windowPicker
            }
            // 实时窗：用户/系统双色堆叠条（iStat 招牌视图——一眼分清负载来源）；
            // 15 分/1 时窗：总占用折线（桶均值没有用户/系统拆分，诚实退回单线）。
            if window == .live, feed.cpuUserHistory.count > 1 {
                StackedCPUBars(user: feed.cpuUserHistory, system: feed.cpuSysHistory)
                    .frame(height: 40)
                    .accessibilityLabel(xLoc("处理器占用历史曲线"))
            } else {
                historyChart(feed.rings.cpu, colors: XColor.ringColors, height: 40)
                    .accessibilityLabel(xLoc("处理器占用历史曲线"))
            }
            HStack(spacing: XSpacing.m) {
                HStack(spacing: 3) {
                    Circle().fill(XColor.ring(2)).frame(width: 6, height: 6)
                    Text(xLoc("用户")).font(XFont.nano).foregroundStyle(XColor.textTertiary)
                }
                HStack(spacing: 3) {
                    Circle().fill(XColor.ring(0)).frame(width: 6, height: 6)
                    Text(xLoc("系统")).font(XFont.nano).foregroundStyle(XColor.textTertiary)
                }
                Spacer()
            }
            processList(model.topByCPU, kind: .cpu)
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
                    XMiniRing(fraction: v, colors: XColor.gauge(v), size: 28, lineWidth: 3.5)
                    HStack(spacing: 2) {
                        if hasClusters && clusters[idx] {
                            Circle().fill(XColor.metricCPU[0]).frame(width: 3, height: 3)  // 性能核标记
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

    private func gpuSegment(_ g: Double) -> some View {
        HStack(spacing: XSpacing.s) {
            XMiniRing(fraction: g, colors: XColor.metricGPU, size: 34, lineWidth: 4) {
                Text("\(Int((g * 100).rounded()))").font(XFont.monoMini)
                    .foregroundStyle(XColor.textPrimary)
            }
            Text("GPU").font(XFont.caption).foregroundStyle(XColor.textSecondary)
        }
    }

    private func loadTriple(_ s: SystemSnapshot) -> String {
        String(format: "%.2f  %.2f  %.2f", s.load1, s.load5, s.load15)
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

    // MARK: - 内存面板（压力环 + 用量环 + 分段条 + 完整图例 + 分页 + 交换 + 进程榜）

    @ViewBuilder private func memoryContent(_ s: SystemSnapshot) -> some View {
        VStack(alignment: .leading, spacing: XSpacing.m) {
            HStack(spacing: XSpacing.l) {
                // 压力环：色随等级（正常绿 / 警告橙 / 危险红）。中心状态词随长语言自动缩放不换行。
                XMiniRing(fraction: s.pressureFractionPreferred, colors: pressureColors(s), size: 62, lineWidth: 7) {
                    VStack(spacing: 0) {
                        // 连续压力值（kern.memorystatus_level，与 iStat 同源）优先显示百分数。
                        if let pct = s.memoryPressurePercent {
                            Text("\(Int((pct * 100).rounded()))%").font(XFont.monoMini)
                                .foregroundStyle(XColor.textPrimary)
                        } else {
                            Text(xLoc(s.memoryPressureLabel)).font(XFont.micro)
                                .foregroundStyle(XColor.textPrimary)
                                .lineLimit(1).minimumScaleFactor(0.5)
                        }
                        Text(xLoc("压力")).font(XFont.nano).foregroundStyle(XColor.textTertiary)
                    }
                    .frame(maxWidth: 44)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(xLoc("内存压力"))
                .accessibilityValue(xLoc(s.memoryPressureLabel))
                // 用量环 + 已用 / 总量。
                ringGauge(s.memoryUsedFraction)
                VStack(alignment: .leading, spacing: 2) {
                    Text(s.memoryUsed.formattedMemory).font(XFont.monoLarge).foregroundStyle(XColor.textPrimary)
                    Text(xLocF("/ %@", s.memoryTotal.formattedMemory)).font(XFont.caption).foregroundStyle(XColor.textSecondary)
                }
                Spacer(minLength: 0)
            }
            memSegmentBar(s)
            // 完整图例：应用 / 联动 / 压缩 / 缓存 / 可用（可用 = 空闲轨道，对齐活动监视器口径）。
            memLegendRow(xLoc("应用内存"), s.memoryApp, XColor.memApp)
            memLegendRow(xLoc("联动内存"), s.memoryWired, XColor.memWired)
            memLegendRow(xLoc("已压缩"), s.memoryCompressed, XColor.memCompressed)
            memLegendRow(xLoc("可用"), memoryFree(s) + s.memoryCached, XColor.memFree)
            Text(xLocF("可用中含 %@ 缓存文件，系统随取随回收", s.memoryCached.formattedMemory))
                .font(XFont.nano).foregroundStyle(XColor.textTertiary)
            Divider().padding(.vertical, 1)
            HStack(spacing: XSpacing.l) {
                metricChip(xLoc("换入分页"), s.pageIns.formattedBytes)
                metricChip(xLoc("换出分页"), s.pageOuts.formattedBytes)
                Spacer(minLength: 0)
            }
            if s.swapTotal > 0 { swapBar(s) }
            processList(model.topByMemory, kind: .memory)
        }
    }

    private func memSegmentBar(_ s: SystemSnapshot) -> some View {
        let total = max(1.0, Double(s.memoryTotal))
        // 缓存不再画成「占用段」——缓存随取随回收，计入可用（iStat/活动监视器同口径）。
        return XSegmentBar(segments: [
            .init(id: 0, fraction: Double(s.memoryApp) / total,        color: XColor.memApp),
            .init(id: 1, fraction: Double(s.memoryWired) / total,      color: XColor.memWired),
            .init(id: 2, fraction: Double(s.memoryCompressed) / total, color: XColor.memCompressed),
        ], height: 9)
    }

    private func memoryFree(_ s: SystemSnapshot) -> Int64 {
        max(0, s.memoryTotal - s.memoryApp - s.memoryWired - s.memoryCompressed - s.memoryCached)
    }

    private func memLegendRow(_ label: String, _ bytes: Int64, _ color: Color) -> some View {
        HStack(spacing: XSpacing.s) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(label).font(XFont.caption).foregroundStyle(XColor.textSecondary)
            Spacer()
            Text(bytes.formattedMemory).font(XFont.mono).foregroundStyle(XColor.textPrimary)
        }
    }

    private func swapBar(_ s: SystemSnapshot) -> some View {
        VStack(alignment: .leading, spacing: XSpacing.xs) {
            HStack {
                Text(xLoc("交换区")).font(XFont.caption).foregroundStyle(XColor.textSecondary)
                Spacer()
                Text(xLocF("%@ / %@", s.swapUsed.formattedMemory, s.swapTotal.formattedMemory))
                    .font(XFont.mono).foregroundStyle(XColor.textPrimary)
            }
            XDiskBar(usedFraction: s.swapUsedFraction, label: "", height: 6)
        }
    }

    private func pressureColors(_ s: SystemSnapshot) -> [Color] {
        switch s.memoryPressure {
        case 4: return [XColor.danger, XColor.accentPink]
        case 2: return [XColor.warning, XColor.accentPink]
        default: return [XColor.success, XColor.accentTeal]
        }
    }

    // MARK: - 网络面板（大数字 + 会话峰值/累计 + 双线折线 + 接口清单）

    @ViewBuilder private func networkContent(_ s: SystemSnapshot) -> some View {
        VStack(alignment: .leading, spacing: XSpacing.m) {
            HStack(spacing: XSpacing.xl) {
                rateColumn("arrow.down", XColor.netDown, xLoc("下载"), s.netDownBytesPerSec)
                rateColumn("arrow.up", XColor.netUp, xLoc("上传"), s.netUpBytesPerSec)
                Spacer()
            }
            sessionRow
            networkChart.frame(height: 48)
            // 每进程流量（P6·3，iStat 支柱内容）：nettop 差分采样；不可用时整块隐藏（诚实降级）。
            NetTopSection()
            if !activeInterfaces.isEmpty {
                Divider().padding(.vertical, 1)
                ForEach(activeInterfaces) { interfaceRow($0) }
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

    private enum ProcKind { case cpu, memory }
    private func processList(_ procs: [ProcessUsage], kind: ProcKind) -> some View {
        let shown = Array(procs.prefix(4))
        let maxMem = max(shown.map(\.memoryBytes).max() ?? 1, 1)
        return VStack(spacing: 3) {
            ForEach(shown) { p in
                let frac = kind == .cpu ? min(p.cpuPercent / 100, 1) : Double(p.memoryBytes) / Double(maxMem)
                HStack(spacing: XSpacing.s) {
                    // App 图标（学 iStat：进程行带图标一眼认出是谁）；后台进程无图标时用齿轮。
                    if let icon = NSRunningApplication(processIdentifier: p.id)?.icon {
                        Image(nsImage: icon).resizable().frame(width: 15, height: 15)
                    } else {
                        Image(systemName: "gearshape.fill").font(XFont.nano)
                            .foregroundStyle(XColor.textTertiary).frame(width: 15)
                    }
                    Text(p.name).font(XFont.caption).foregroundStyle(XColor.textSecondary)
                        .lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Text(kind == .cpu ? String(format: "%.1f%%", p.cpuPercent) : p.memoryBytes.formattedMemory)
                        .font(XFont.monoMini)
                        .foregroundStyle(XColor.textPrimary)
                }
                .padding(.vertical, 2).padding(.horizontal, 6)
                // 行内占用条：一眼看出谁在吃资源（对标 iStat 的进程条）。
                .background(alignment: .leading) {
                    GeometryReader { geo in
                        Capsule().fill((kind == .cpu ? XColor.metricCPU[0] : XColor.metricMemory[0]).opacity(0.12))
                            .frame(width: max(0, geo.size.width * frac))
                    }
                    .clipShape(RoundedRectangle(cornerRadius: XRadius.chip))
                }
            }
        }
    }

    /// 彩虹极光圆环 + 中心百分数（详情面板里的「数据」用 App 同款彩色）
    private func ringGauge(_ fraction: Double) -> some View {
        XMiniRing(fraction: fraction, colors: XColor.ringColors, size: 60, lineWidth: 7) {
            Text("\(Int((fraction * 100).rounded()))%")
                .font(XFont.monoMid)
                .foregroundStyle(XColor.textPrimary)
        }
    }

    private var networkChart: some View {
        // 分层时间窗（P3·M4）：按当前挡位取序列，双线同基准归一；悬停给出「↓ 下行 · ↑ 上行」真实速率。
        let downRaw = window.series(from: feed.rings.netDown)
        let upRaw = window.series(from: feed.rings.netUp)
        let maxV = max((downRaw + upRaw).max() ?? 1, 1)
        let down = downRaw.map { $0 / maxV }
        let up = upRaw.map { $0 / maxV }
        return VStack(alignment: .trailing, spacing: XSpacing.xs) {
            windowPicker
            ZStack {
                XLineChart(values: down, colors: [XColor.netDown, XColor.ring(2)], showDot: false, showGrid: true,
                           hoverLabel: { i in
                               guard i >= 0, i < downRaw.count else { return "" }
                               let u = i < upRaw.count ? upRaw[i] : 0
                               return "↓\(downRaw[i].compactRate) ↑\(u.compactRate)"
                           })
                XLineChart(values: up, colors: [XColor.netUp, XColor.ring(1)], showFill: false, showDot: false)
            }
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
                .lineLimit(1).minimumScaleFactor(0.85)
            Text(value).font(XFont.captionEmphasis).foregroundStyle(XColor.textPrimary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - 温度面板（全部传感器 + 热状态 + 风扇，对标 iStat Sensors）

    @ViewBuilder private func temperatureContent(_ s: SystemSnapshot) -> some View {
        // 每帧只排一次序、SSD 均值只算一次（此前在 body 内重复排序/过滤，审计 P3 MenuPanels:472）。
        let sortedSensors = model.sensorTemps.sorted { $0.celsius > $1.celsius }
        let ssdAvg = avgTemp(.ssd)
        VStack(alignment: .leading, spacing: XSpacing.m) {
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
        VStack(alignment: .leading, spacing: XSpacing.m) {
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
            HStack {
                Spacer()
                windowPicker
            }
            historyChart(feed.rings.gpu, colors: XColor.metricGPU, height: 44)
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
        VStack(alignment: .leading, spacing: XSpacing.m) {
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
            XLineChart(values: read, colors: [XColor.netDown, XColor.ring(2)], showDot: false)
            XLineChart(values: write, colors: [XColor.netUp, XColor.ring(1)], showFill: false, showDot: false)
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
