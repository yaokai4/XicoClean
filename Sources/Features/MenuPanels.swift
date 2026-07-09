import SwiftUI
import Infrastructure
import DesignSystem
import Shared

public enum MenuMetric: Sendable {
    case cpu, memory, network, temperature, disk, gpu

    var title: String {
        switch self {
        case .cpu: return xLoc("处理器")
        case .memory: return xLoc("内存")
        case .network: return xLoc("网络")
        case .temperature: return xLoc("温度")
        case .disk: return xLoc("磁盘")
        case .gpu: return "GPU"
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
            // 快捷操作：释放内存 + 快速清理（智能扫描），与「打开监视器」并列。
            HStack(spacing: XSpacing.s) {
                Button { freeMemory() } label: {
                    HStack(spacing: XSpacing.xs) {
                        Image(systemName: "memorychip")
                        Text(freeingMemory ? xLoc("释放中…") : xLoc("释放内存"))
                    }.frame(maxWidth: .infinity)
                }
                .buttonStyle(XSecondaryButtonStyle(compact: true))
                .disabled(freeingMemory)
                .accessibilityLabel(xLoc("释放内存"))
                Button { openSmartScan() } label: {
                    HStack(spacing: XSpacing.xs) {
                        Image(systemName: "sparkles")
                        Text(xLoc("快速清理"))
                    }.frame(maxWidth: .infinity)
                }
                .buttonStyle(XSecondaryButtonStyle(compact: true))
                .accessibilityLabel(xLoc("快速清理"))
            }
            if let note = freeMemNote {
                Text(note).font(XFont.caption).foregroundStyle(XColor.textTertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(spacing: XSpacing.s) {
                Button { openMonitor() } label: { Text(xLoc("打开监视器")).frame(maxWidth: .infinity) }
                    .buttonStyle(XPrimaryButtonStyle(compact: true))
                Button { NSApp.terminate(nil) } label: { Image(systemName: "power") }
                    .buttonStyle(XSecondaryButtonStyle(compact: true))
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

    @ViewBuilder private func content(_ s: SystemSnapshot) -> some View {
        switch metric {
        case .cpu:         cpuContent(s)
        case .memory:      memoryContent(s)
        case .network:     networkContent(s)
        case .temperature: temperatureContent(s)
        case .disk:        diskContent(s)
        case .gpu:         gpuContent(s)
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
            XLineChart(values: model.cpuHistory, colors: XColor.ringColors).frame(height: 40)
                .accessibilityLabel(xLoc("处理器占用历史曲线"))
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
            XMiniRing(fraction: g, colors: XColor.gpuGauge(g), size: 34, lineWidth: 4) {
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
                XMiniRing(fraction: s.memoryPressureFraction, colors: pressureColors(s), size: 62, lineWidth: 7) {
                    VStack(spacing: 0) {
                        Text(xLoc(s.memoryPressureLabel)).font(XFont.micro)
                            .foregroundStyle(XColor.textPrimary)
                            .lineLimit(1).minimumScaleFactor(0.5)
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
            memLegendRow(xLoc("缓存文件"), s.memoryCached, XColor.memCached)
            memLegendRow(xLoc("可用"), memoryFree(s), XColor.memFree)
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
        return XSegmentBar(segments: [
            .init(id: 0, fraction: Double(s.memoryApp) / total,        color: XColor.memApp),
            .init(id: 1, fraction: Double(s.memoryWired) / total,      color: XColor.memWired),
            .init(id: 2, fraction: Double(s.memoryCompressed) / total, color: XColor.memCompressed),
            .init(id: 3, fraction: Double(s.memoryCached) / total,     color: XColor.memCached),
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
        let maxV = max((model.netDownHistory + model.netUpHistory).max() ?? 1, 1)
        let down = model.netDownHistory.map { $0 / maxV }
        let up = model.netUpHistory.map { $0 / maxV }
        return ZStack {
            XLineChart(values: down, colors: [XColor.netDown, XColor.ring(2)], showDot: false)
            XLineChart(values: up, colors: [XColor.netUp, XColor.ring(1)], showFill: false, showDot: false)
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
            XLineChart(values: model.gpuHistory, colors: XColor.metricGPU).frame(height: 44)
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
