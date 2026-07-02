import SwiftUI
import Domain
import Infrastructure
import DesignSystem

public struct MonitorView: View {
    private let env: XicoEnvironment
    @ObservedObject private var engine: MetricsEngine
    @StateObject private var netVM: NetworkViewModel
    @State private var info: MacInfo?
    @State private var procTab: ProcTab = .cpu
    @State private var tab: MonitorTab = .overview
    @State private var historyRange: MetricsHistoryStore.Range = .minute

    enum ProcTab { case cpu, memory }
    enum MonitorTab: String, CaseIterable {
        case overview, cpu, memory, network, gpu
        var title: String {
            switch self {
            case .overview: return xLoc("总览")
            case .cpu: return xLoc("处理器")
            case .memory: return xLoc("内存")
            case .network: return xLoc("网络")
            case .gpu: return "GPU"
            }
        }
    }

    public init(env: XicoEnvironment) {
        self.env = env
        self.engine = env.metricsEngine
        _netVM = StateObject(wrappedValue: NetworkViewModel(service: env.network))
    }

    private var snap: SystemSnapshot? { engine.snapshot }
    private let cardColumns = [GridItem(.adaptive(minimum: 250), spacing: XSpacing.m)]

    public var body: some View {
        VStack(spacing: 0) {
            XHeaderBar(title: xLoc("系统监视"), subtitle: xLoc("实时刷新 · 每秒")) {
                HStack(spacing: XSpacing.xs) {
                    Circle().fill(XColor.success).frame(width: 7, height: 7)
                    Text("LIVE").font(.system(size: 10, weight: .bold)).tracking(1).foregroundStyle(XColor.success)
                }
            }
            Picker("", selection: $tab) {
                ForEach(MonitorTab.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden()
            .padding(.horizontal, XSpacing.xl).padding(.bottom, XSpacing.s)

            ScrollView {
                VStack(spacing: XSpacing.m) {
                    switch tab {
                    case .overview: overviewTab
                    case .cpu: cpuTab
                    case .memory: memoryTab
                    case .network: NetworkView(vm: netVM, history: engine.netDownNormalized())
                    case .gpu: gpuTab
                    }
                }
                .padding(XSpacing.xl)
            }
        }
        .onAppear {
            info = env.liveMetrics.macInfo()
            engine.retain()
            netVM.start()
        }
        .onDisappear { engine.release(); netVM.stop() }
    }

    // MARK: 总览

    private var overviewTab: some View {
        Group {
            macCard
            gaugeRow
            historyCard
        }
    }

    private var macCard: some View {
        XCard {
            HStack(alignment: .center, spacing: XSpacing.xl) {
                XIconTile(systemImage: "laptopcomputer", colors: XColor.brandGradientColors, size: 52)
                VStack(alignment: .leading, spacing: 3) {
                    Text(info?.chip ?? "—").xHeadline().foregroundStyle(XColor.textPrimary)
                    Text(info?.model ?? "—").font(XFont.caption).foregroundStyle(XColor.textSecondary)
                }
                Spacer()
                HStack(spacing: XSpacing.xl) {
                    if let p = engine.cpuFreqP { infoCol(xLoc("主频"), freqText(p)) }
                    infoCol(xLoc("负载"), snap.map { String(format: "%.2f", $0.load1) } ?? "—")
                    infoCol(xLoc("核心"), info.map { "\($0.cores)" } ?? "—")
                    infoCol(xLoc("已运行"), info?.uptime ?? "—")
                }
            }
        }
    }

    private var gaugeRow: some View {
        HStack(spacing: XSpacing.m) {
            miniGauge(xLoc("处理器"), snap?.cpuUsage ?? 0, "\(Int((snap?.cpuUsage ?? 0) * 100))%")
            miniGauge(xLoc("内存"), snap?.memoryUsedFraction ?? 0, "\(Int((snap?.memoryUsedFraction ?? 0) * 100))%")
            // GPU 全 App 统一走不变红的紫罗兰环（高占用是常态，与 GPU tab / 硬件页一致）。
            miniGauge("GPU", snap?.gpuUsage ?? 0, snap?.gpuUsage.map { "\(Int($0 * 100))%" } ?? "—",
                      colors: XColor.gpuGauge(snap?.gpuUsage ?? 0))
            miniGauge(xLoc("磁盘"), snap?.diskUsedFraction ?? 0, "\(Int((snap?.diskUsedFraction ?? 0) * 100))%")
        }
    }

    private func miniGauge(_ title: String, _ value: Double, _ text: String, colors: [Color]? = nil) -> some View {
        XCard {
            VStack(spacing: XSpacing.s) {
                XRingGauge(progress: value, colors: colors ?? XColor.gauge(value), lineWidth: 9, size: 96) {
                    Text(text).font(XFont.monoLarge).foregroundStyle(XColor.textPrimary)
                        .lineLimit(1).minimumScaleFactor(0.5).fixedSize()
                }
                Text(title).font(XFont.captionEmphasis).foregroundStyle(XColor.textSecondary)
            }
            .frame(maxWidth: .infinity)
            .animation(.easeOut(duration: 0.5), value: value)
        }
    }

    private var historyCard: some View {
        XCard {
            VStack(alignment: .leading, spacing: XSpacing.m) {
                HStack {
                    cardHeader("waveform.path.ecg", xLoc("历史曲线"))
                    Spacer()
                    Picker("", selection: $historyRange) {
                        ForEach(MetricsHistoryStore.Range.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 280)
                }
                let series = historySeries()
                chartRow(xLoc("处理器"), series.cpu, XColor.brandGradientColors, "\(Int((snap?.cpuUsage ?? 0) * 100))%")
                chartRow(xLoc("内存"), series.mem, [XColor.auroraViolet, XColor.auroraRose], "\(Int((snap?.memoryUsedFraction ?? 0) * 100))%")
                chartRow("GPU", series.gpu, [XColor.auroraOrchid, XColor.auroraViolet], snap?.gpuUsage.map { "\(Int($0 * 100))%" } ?? "—")
                chartRow(xLoc("网络"), series.net, [XColor.accentTeal, XColor.auroraBlue],
                         "↓\((snap?.netDownBytesPerSec ?? 0).formattedRate)")
            }
        }
    }

    private func historySeries() -> (cpu: [Double], mem: [Double], gpu: [Double], net: [Double]) {
        if historyRange == .minute {
            return (engine.cpuHistory, engine.memHistory, engine.gpuHistory, engine.netDownNormalized())
        }
        let pts = env.metricsHistory.points(in: historyRange, now: Date())
        guard pts.count > 1 else { return ([], [], [], []) }
        let netMax = max(pts.map { max($0.netDown, $0.netUp) }.max() ?? 1, 1)
        return (pts.map(\.cpu), pts.map(\.mem), pts.map(\.gpu), pts.map { $0.netDown / netMax })
    }

    private func chartRow(_ title: String, _ values: [Double], _ colors: [Color], _ value: String) -> some View {
        HStack(spacing: XSpacing.m) {
            Text(title).font(XFont.caption).foregroundStyle(XColor.textSecondary)
                .lineLimit(1).fixedSize().frame(width: 60, alignment: .leading)
            XLineChart(values: values, colors: colors).frame(height: 38)
            Text(value).font(XFont.mono).foregroundStyle(XColor.textPrimary).frame(width: 84, alignment: .trailing)
        }
    }

    // MARK: 处理器 Tab

    private var cpuTab: some View {
        Group {
            cpuCard
            LazyVGrid(columns: cardColumns, spacing: XSpacing.m) {
                cpuStatCard
                thermalCard
            }
            processCard(kind: .cpu)
        }
    }

    private var cpuCard: some View {
        XCard {
            VStack(alignment: .leading, spacing: XSpacing.m) {
                HStack {
                    cardHeader("cpu", xLoc("处理器 · 每核心"))
                    Spacer()
                    if let s = snap {
                        Text(xLocF("用户 %d%%  系统 %d%%", Int(s.cpuUser * 100), Int(s.cpuSystem * 100)))
                            .font(XFont.caption).foregroundStyle(XColor.textSecondary)
                    }
                }
                let cores = snap?.perCore ?? []
                if cores.isEmpty {
                    Text(xLoc("正在采样…")).font(XFont.caption).foregroundStyle(XColor.textTertiary)
                } else {
                    HStack(alignment: .bottom, spacing: 6) {
                        ForEach(Array(cores.enumerated()), id: \.offset) { idx, v in coreBar(index: idx, value: v) }
                    }
                    .frame(height: 96)
                    HStack {
                        Text(coreSummary).font(XFont.caption).foregroundStyle(XColor.textTertiary)
                        Spacer()
                        Text(xLocF("平均负载 %@", loadTriple)).font(XFont.caption).foregroundStyle(XColor.textTertiary)
                    }
                }
            }
        }
    }

    private var cpuStatCard: some View {
        MonitorCard(icon: "gauge.with.dots.needle.67percent", title: xLoc("负载"), colors: XColor.brandGradientColors) {
            if let s = snap {
                statRow(xLoc("总占用"), "\(Int(s.cpuUsage * 100))%")
                statRow(xLoc("用户"), "\(Int(s.cpuUser * 100))%")
                statRow(xLoc("系统"), "\(Int(s.cpuSystem * 100))%")
                if let p = engine.cpuFreqP { statRow(xLoc("性能核频率"), freqText(p)) }
                if let e = engine.cpuFreqE { statRow(xLoc("能效核频率"), freqText(e)) }
                statRow(xLoc("平均负载"), loadTriple)
                if let t = s.cpuTemp { statRow(xLoc("温度"), String(format: "%.0f°C", t)) }
            }
        }
    }

    private func freqText(_ mhz: Double) -> String {
        mhz >= 1000 ? String(format: "%.2f GHz", mhz / 1000) : String(format: "%.0f MHz", mhz)
    }

    private func coreBar(index: Int, value: Double) -> some View {
        VStack(spacing: 4) {
            GeometryReader { geo in
                ZStack(alignment: .bottom) {
                    RoundedRectangle(cornerRadius: 4).fill(XColor.surfaceAlt)
                    RoundedRectangle(cornerRadius: 4)
                        .fill(LinearGradient(colors: XColor.gauge(value), startPoint: .bottom, endPoint: .top))
                        .frame(height: max(3, geo.size.height * value))
                        .animation(.easeOut(duration: 0.35), value: value)
                }
            }
            Text("\(index)").font(.system(size: 8, weight: .medium)).foregroundStyle(XColor.textTertiary)
        }
        .frame(maxWidth: .infinity)
    }

    private var coreSummary: String {
        guard let p = info?.cores else { return "" }
        let profile = env.hardware.staticProfile()
        if profile.performanceCores > 0 && profile.efficiencyCores > 0 {
            return xLocF("%d 核 · %d 性能 + %d 能效", p, profile.performanceCores, profile.efficiencyCores)
        }
        return xLocF("%d 逻辑核心", p)
    }
    private var loadTriple: String {
        guard let s = snap else { return "—" }
        return String(format: "%.2f  %.2f  %.2f", s.load1, s.load5, s.load15)
    }

    // MARK: 内存 Tab

    private var memoryTab: some View {
        Group {
            HStack(spacing: XSpacing.m) {
                pressureCard
                usageCard
            }
            memoryBreakdownCard
            LazyVGrid(columns: cardColumns, spacing: XSpacing.m) {
                pagesCard
                swapCard
            }
            processCard(kind: .memory)
        }
    }

    private var pressureCard: some View {
        XCard {
            VStack(spacing: XSpacing.s) {
                XRingGauge(progress: snap?.memoryPressureFraction ?? 0.25,
                           colors: pressureColors, lineWidth: 11, size: 120) {
                    VStack(spacing: 0) {
                        Text(snap?.memoryPressureLabel ?? "—").xHeadline().foregroundStyle(XColor.textPrimary)
                        Text(xLoc("压力")).font(.system(size: 9)).foregroundStyle(XColor.textTertiary)
                    }
                }
                Text(xLoc("内存压力")).font(XFont.captionEmphasis).foregroundStyle(XColor.textSecondary)
            }
            .frame(maxWidth: .infinity)
        }
    }
    private var pressureColors: [Color] {
        switch snap?.memoryPressure {
        case 4: return [XColor.danger, XColor.accentPink]
        case 2: return [XColor.warning, XColor.accentPink]
        default: return [XColor.success, XColor.accentTeal]
        }
    }

    private var usageCard: some View {
        XCard {
            VStack(spacing: XSpacing.s) {
                XRingGauge(progress: snap?.memoryUsedFraction ?? 0, colors: XColor.gauge(snap?.memoryUsedFraction ?? 0), lineWidth: 11, size: 120) {
                    VStack(spacing: 0) {
                        Text("\(Int((snap?.memoryUsedFraction ?? 0) * 100))%").xTitle().foregroundStyle(XColor.textPrimary)
                        Text((snap?.memoryUsed ?? 0).formattedMemory).font(.system(size: 9)).foregroundStyle(XColor.textTertiary)
                    }
                }
                Text(xLocF("已用 / %@", (snap?.memoryTotal ?? 0).formattedMemory)).font(XFont.captionEmphasis).foregroundStyle(XColor.textSecondary)
            }
            .frame(maxWidth: .infinity)
        }
    }

    private var memoryBreakdownCard: some View {
        MonitorCard(icon: "memorychip.fill", title: xLoc("内存明细"), colors: [XColor.accentTeal, XColor.auroraBlue]) {
            memBar
            breakdownRow(xLoc("应用内存"), snap?.memoryApp, XColor.auroraBlue)
            breakdownRow(xLoc("联动内存"), snap?.memoryWired, XColor.accentPink)
            breakdownRow(xLoc("已压缩"), snap?.memoryCompressed, XColor.warning)
            breakdownRow(xLoc("缓存文件"), snap?.memoryCached, XColor.accentTeal)
        }
    }

    private var memBar: some View {
        GeometryReader { geo in
            let s = snap
            let total = Double(s?.memoryTotal ?? 1)
            HStack(spacing: 1) {
                seg(Double(s?.memoryApp ?? 0) / total, geo.size.width, XColor.auroraBlue)
                seg(Double(s?.memoryWired ?? 0) / total, geo.size.width, XColor.accentPink)
                seg(Double(s?.memoryCompressed ?? 0) / total, geo.size.width, XColor.warning)
                seg(Double(s?.memoryCached ?? 0) / total, geo.size.width, XColor.accentTeal)
                Spacer(minLength: 0)
            }
            .frame(height: 10).clipShape(Capsule()).background(Capsule().fill(XColor.surfaceAlt))
        }
        .frame(height: 10)
    }
    private func seg(_ frac: Double, _ width: CGFloat, _ color: Color) -> some View {
        Rectangle().fill(color).frame(width: max(0, width * min(1, max(0, frac))))
    }
    private func breakdownRow(_ label: String, _ bytes: Int64?, _ color: Color) -> some View {
        HStack(spacing: XSpacing.s) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(label).font(XFont.caption).foregroundStyle(XColor.textSecondary)
            Spacer()
            Text((bytes ?? 0).formattedMemory).font(XFont.mono).foregroundStyle(XColor.textPrimary)
        }
    }

    private var pagesCard: some View {
        MonitorCard(icon: "arrow.up.arrow.down", title: xLoc("分页"), colors: [XColor.auroraViolet, XColor.auroraOrchid]) {
            statRow(xLoc("换入分页"), (snap?.pageIns ?? 0).formattedBytes)
            statRow(xLoc("换出分页"), (snap?.pageOuts ?? 0).formattedBytes)
        }
    }

    private var swapCard: some View {
        MonitorCard(icon: "internaldrive", title: xLoc("交换区"), colors: [XColor.accentPink, XColor.auroraRose]) {
            if let s = snap, s.swapTotal > 0 {
                statRow(xLoc("已使用"), s.swapUsed.formattedMemory)
                statRow(xLoc("总量"), s.swapTotal.formattedMemory)
                XDiskBar(usedFraction: s.swapUsedFraction, label: "", height: 8)
            } else {
                Text(xLoc("未使用交换")).font(XFont.caption).foregroundStyle(XColor.textTertiary)
            }
        }
    }

    // MARK: GPU Tab

    private var gpuTab: some View {
        Group {
            XCard {
                VStack(spacing: XSpacing.m) {
                    XRingGauge(progress: snap?.gpuUsage ?? 0, colors: [XColor.auroraViolet, XColor.auroraOrchid], lineWidth: 12, size: 150) {
                        VStack(spacing: 0) {
                            Text(snap?.gpuUsage.map { "\(Int($0 * 100))%" } ?? "—").xLargeTitle().foregroundStyle(XColor.textPrimary)
                            Text(xLoc("占用率")).font(XFont.caption).foregroundStyle(XColor.textTertiary)
                        }
                    }
                    Text(info?.chip ?? "GPU").font(XFont.captionEmphasis).foregroundStyle(XColor.textSecondary)
                }
                .frame(maxWidth: .infinity)
            }
            LazyVGrid(columns: cardColumns, spacing: XSpacing.m) {
                MonitorCard(icon: "cpu.fill", title: "GPU", colors: [XColor.auroraViolet, XColor.auroraOrchid]) {
                    statRow(xLoc("占用率"), snap?.gpuUsage.map { "\(Int($0 * 100))%" } ?? "—")
                    if let t = snap?.gpuTemp { statRow(xLoc("温度"), String(format: "%.0f°C", t)) }
                }
                MonitorCard(icon: "waveform.path.ecg", title: xLoc("历史"), colors: [XColor.auroraOrchid, XColor.auroraViolet]) {
                    XLineChart(values: engine.gpuHistory, colors: [XColor.auroraOrchid, XColor.auroraViolet]).frame(height: 44)
                }
            }
        }
    }

    // MARK: 散热 / 进程

    private var thermalCard: some View {
        MonitorCard(icon: "thermometer.medium", title: xLoc("散热"), colors: [XColor.warning, XColor.accentPink]) {
            if let t = snap?.cpuTemp { tempRow(xLoc("处理器"), t) }
            if let t = snap?.gpuTemp { tempRow("GPU", t) }
            HStack {
                Text(xLoc("热压力")).font(XFont.caption).foregroundStyle(XColor.textSecondary)
                Spacer()
                XBadge(snap?.thermal.rawValue ?? "—", color: thermalColor)
            }
            if let rpm = snap?.fanRPM {
                HStack {
                    Text(xLoc("风扇")).font(XFont.caption).foregroundStyle(XColor.textSecondary)
                    Spacer()
                    Text("\(rpm) RPM").font(XFont.mono).foregroundStyle(XColor.textPrimary)
                }
            }
        }
    }
    private func tempRow(_ label: String, _ c: Double) -> some View {
        HStack {
            Text(label).font(XFont.caption).foregroundStyle(XColor.textSecondary)
            Spacer()
            Text(String(format: "%.0f°C", c)).font(XFont.mono).foregroundStyle(tempColor(c))
        }
    }

    private func processCard(kind: ProcTab) -> some View {
        XCard {
            VStack(alignment: .leading, spacing: XSpacing.m) {
                cardHeader("list.bullet.rectangle", xLocF("%@ · 进程榜", kind == .cpu ? xLoc("处理器") : xLoc("内存")))
                let list = kind == .cpu ? engine.topByCPU : engine.topByMemory
                if list.isEmpty {
                    Text(xLoc("正在采样…")).font(XFont.caption).foregroundStyle(XColor.textTertiary)
                        .frame(maxWidth: .infinity, alignment: .center).padding(.vertical, XSpacing.m)
                } else {
                    ForEach(list) { proc in
                        HStack(spacing: XSpacing.m) {
                            Text(proc.name).font(XFont.body).foregroundStyle(XColor.textPrimary)
                                .lineLimit(1).truncationMode(.middle)
                            Spacer()
                            Text(kind == .cpu ? String(format: "%.1f%%", proc.cpuPercent) : proc.memoryBytes.formattedMemory)
                                .font(XFont.mono).foregroundStyle(XColor.textSecondary)
                        }
                        .padding(.vertical, 1)
                    }
                }
            }
        }
    }

    // MARK: 共用

    private func infoCol(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(XFont.caption).foregroundStyle(XColor.textTertiary)
            Text(value).font(XFont.bodyEmphasis).foregroundStyle(XColor.textPrimary)
        }
        .frame(minWidth: 60, alignment: .leading)   // 列对齐成栅格，标签/值左对齐
    }
    private func statRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).font(XFont.caption).foregroundStyle(XColor.textSecondary)
            Spacer()
            Text(value).font(XFont.mono).foregroundStyle(XColor.textPrimary)
        }
    }
    // 与 MonitorCard / HardwareCard 统一：渐变图标砖 size 28 + 大写字距标题，全 App 卡片头一致。
    private func cardHeader(_ icon: String, _ title: String, _ colors: [Color] = XColor.brandGradientColors) -> some View {
        HStack(spacing: XSpacing.s) {
            XIconTile(systemImage: icon, colors: colors, size: 28)
            Text(title).font(XFont.captionEmphasis).foregroundStyle(XColor.textSecondary)
                .textCase(.uppercase).tracking(0.6)
            Spacer()
        }
    }
    private var thermalColor: Color {
        switch snap?.thermal {
        case .nominal: return XColor.success
        case .fair: return XColor.accentTeal
        case .serious: return XColor.warning
        case .critical: return XColor.danger
        default: return XColor.textSecondary
        }
    }
    private func tempColor(_ c: Double) -> Color {
        if c >= 85 { return XColor.danger }
        if c >= 70 { return XColor.warning }
        if c >= 55 { return XColor.accentTeal }
        return XColor.success
    }
}
