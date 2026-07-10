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
    /// 每核心可视化：当前条 / 迷你环 / 历史热力图，持久化记住偏好（对齐 Sensei 的可选每核心视图）。
    @AppStorage("xico.monitor.coreViz") private var coreViz = "bars"
    /// 全部命名温度传感器（传感器中心）——独立于快照采样，进页面时读一次、每 3 秒刷新。
    @State private var allTemps: [TempReading] = []
    /// 单次持有门闩：SwiftUI 可能重复触发 onAppear（导航复用/父树重建），
    /// 用它保证 engine.retain()/release() 与 netVM.start()/stop() 严格配对，杜绝采样器泄漏（审计 P2）。
    @State private var engineRetained = false
    private let sensorTick = Timer.publish(every: 3, on: .main, in: .common).autoconnect()

    enum ProcTab { case cpu, memory }
    public enum MonitorTab: String, CaseIterable, Sendable {
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

    public init(env: XicoEnvironment, initialTab: MonitorTab = .overview) {
        self.env = env
        self.engine = env.metricsEngine
        _netVM = StateObject(wrappedValue: NetworkViewModel(service: env.network))
        _tab = State(initialValue: initialTab)
    }

    private var snap: SystemSnapshot? { engine.snapshot }
    private let cardColumns = [GridItem(.adaptive(minimum: 250), spacing: XSpacing.m)]

    public var body: some View {
        VStack(spacing: 0) {
            XHeaderBar(title: xLoc("系统监视"), subtitle: xLoc("实时刷新 · 每秒")) {
                HStack(spacing: XSpacing.s) {
                    XLiveDot(size: 7)
                    Text("LIVE").font(XFont.micro).tracking(1).foregroundStyle(XColor.success)
                }
            }
            Picker("", selection: $tab) {
                ForEach(MonitorTab.allCases, id: \.self) { Text(xLoc($0.title)).tag($0) }
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
            // 共享 MetricsEngine 是全 App 唯一采样循环；仅在真正未持有时 retain，防重复 onAppear 泄漏。
            if !engineRetained {
                engine.retain()
                netVM.start()
                engineRetained = true
            }
            refreshTemps()
        }
        .onReceive(sensorTick) { _ in refreshTemps() }
        .onDisappear {
            if engineRetained {
                engine.release()
                netVM.stop()
                engineRetained = false
            }
        }
    }

    /// 全量温度枚举（HID 遍历 + 归类）搬到后台，仅回主线程发布，避免每 3 秒在主线程阻塞（审计 P3）。
    /// 镜像 HardwareView.refreshHealth 的 detached-then-hop 写法。
    private func refreshTemps() {
        let sensors = env.sensors
        Task { @MainActor in
            let temps = await Task.detached(priority: .utility) { sensors.temperatures() }.value
            allTemps = temps
        }
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
                      colors: XColor.metricGPU)
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
            .animation(XMotion.gauge, value: value)
        }
    }

    private var historyCard: some View {
        XCard {
            VStack(alignment: .leading, spacing: XSpacing.m) {
                HStack {
                    cardHeader("waveform.path.ecg", xLoc("历史曲线"))
                    Spacer()
                    Picker("", selection: $historyRange) {
                        ForEach(MetricsHistoryStore.Range.allCases, id: \.self) { Text(xLoc($0.title)).tag($0) }
                    }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                }
                let series = historySeries()
                chartRow(xLoc("处理器"), series.cpu, XColor.brandGradientColors, "\(Int((snap?.cpuUsage ?? 0) * 100))%") { i in hoverStamp("\(Int(series.cpu[i] * 100))%", index: i, times: series.times) }
                chartRow(xLoc("内存"), series.mem, XColor.metricMemory, "\(Int((snap?.memoryUsedFraction ?? 0) * 100))%") { i in hoverStamp("\(Int(series.mem[i] * 100))%", index: i, times: series.times) }
                chartRow("GPU", series.gpu, XColor.metricGPU, snap?.gpuUsage.map { "\(Int($0 * 100))%" } ?? "—") { i in hoverStamp("\(Int(series.gpu[i] * 100))%", index: i, times: series.times) }
                chartRow(xLoc("网络"), series.net, XColor.metricNetwork,
                         "↓\((snap?.netDownBytesPerSec ?? 0).formattedRate)") { i in
                    series.netRaw.indices.contains(i) ? hoverStamp("↓\(series.netRaw[i].formattedRate)", index: i, times: series.times) : ""
                }
            }
        }
    }

    private func historySeries() -> (cpu: [Double], mem: [Double], gpu: [Double], net: [Double], netRaw: [Double], times: [Date]) {
        if historyRange == .minute {
            let cpu = engine.cpuHistory
            // 分钟视图为内存中 ~1 秒粒度采样（页头即标注「每秒」）：末点为现在，向前每点 -1 秒。
            let now = Date()
            let times = cpu.indices.map { now.addingTimeInterval(-Double(cpu.count - 1 - $0)) }
            return (cpu, engine.memHistory, engine.gpuHistory, engine.netDownNormalized(), engine.netDownHistory, times)
        }
        let pts = env.metricsHistory.points(in: historyRange, now: Date())
        guard pts.count > 1 else { return ([], [], [], [], [], []) }
        let netMax = max(pts.map { max($0.netDown, $0.netUp) }.max() ?? 1, 1)
        return (pts.map(\.cpu), pts.map(\.mem), pts.map(\.gpu), pts.map { $0.netDown / netMax },
                pts.map(\.netDown), pts.map { Date(timeIntervalSince1970: $0.t) })
    }

    /// 悬停读数「值 · 时刻」（对齐 iStat 的可擦洗）。分钟视图显示「N 秒前 / 刚刚」，长范围显示真实时钟。
    private func hoverStamp(_ value: String, index i: Int, times: [Date]) -> String {
        guard times.indices.contains(i) else { return value }
        if historyRange == .minute {
            let ago = Int(Date().timeIntervalSince(times[i]).rounded())
            return ago <= 0 ? xLocF("%@ · 刚刚", value) : xLocF("%@ · %d 秒前", value, ago)
        }
        let f = DateFormatter()
        f.dateFormat = (historyRange == .day || historyRange == .week) ? "M/d HH:mm" : "HH:mm"
        return "\(value) · \(f.string(from: times[i]))"
    }

    private func chartRow(_ title: String, _ values: [Double], _ colors: [Color], _ value: String,
                          _ hoverFmt: ((Int) -> String)?) -> some View {
        HStack(spacing: XSpacing.m) {
            Text(title).font(XFont.caption).foregroundStyle(XColor.textSecondary)
                .lineLimit(1).truncationMode(.tail).frame(width: 72, alignment: .leading)  // 可截断，长语言不挤压图表
            // 网格基线 + 悬停读数（对标 iStat 的可擦洗历史曲线）。
            XLineChart(values: values, colors: colors, showGrid: true,
                       hoverLabel: hoverFmt.map { fmt in { i in i < values.count ? fmt(i) : "" } })
                .frame(height: 46)
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
            sensorCenterCard
            processCard(kind: .cpu)
        }
    }

    // MARK: 传感器中心（复用硬件页 2 列网格：全部命名温度传感器，读不到即隐藏整卡）

    @ViewBuilder private var sensorCenterCard: some View {
        let grouped = sensorGroups()
        if !grouped.isEmpty {
            MonitorCard(icon: "sensor.tag.radiowaves.forward", title: xLoc("传感器"), colors: [XColor.warning, XColor.metricNetwork[0]]) {
                ForEach(grouped, id: \.0) { name, temps in
                    VStack(alignment: .leading, spacing: XSpacing.s) {
                        Text(xLoc(name)).font(XFont.micro).foregroundStyle(XColor.textTertiary)
                            .textCase(.uppercase).tracking(0.5)
                        LazyVGrid(columns: [GridItem(.flexible(), spacing: XSpacing.l, alignment: .leading),
                                            GridItem(.flexible(), alignment: .leading)],
                                  alignment: .leading, spacing: XSpacing.s) {
                            ForEach(Array(temps.enumerated()), id: \.offset) { _, t in sensorCell(t) }
                        }
                    }
                    .padding(.vertical, 1)
                }
            }
        }
    }

    private func sensorCell(_ t: TempReading) -> some View {
        VStack(spacing: 3) {
            HStack(spacing: XSpacing.xs) {
                Text(xLoc(t.name)).font(XFont.caption).foregroundStyle(XColor.textSecondary)
                    .lineLimit(1).truncationMode(.tail)
                Spacer(minLength: XSpacing.xs)
                Text(String(format: "%.0f°C", t.celsius)).font(XFont.mono).foregroundStyle(tempColor(t.celsius))
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(XColor.surfaceAlt)
                    Capsule().fill(tempColor(t.celsius))
                        .frame(width: max(2, geo.size.width * min(t.celsius / 100, 1)))
                }
            }
            .frame(height: 4)
        }
    }

    private func sensorGroups() -> [(String, [TempReading])] {
        let order: [(TempReading.Category, String)] = [
            (.cpu, xLoc("处理器")), (.gpu, "GPU"), (.ssd, xLoc("固态硬盘")),
            (.battery, xLoc("电池")), (.ambient, xLoc("环境")), (.other, xLoc("其他"))
        ]
        var out: [(String, [TempReading])] = []
        for (cat, name) in order {
            let items = allTemps.filter { $0.category == cat }.sorted { $0.celsius > $1.celsius }
            let capped = cat == .other ? Array(items.prefix(8)) : items
            if !capped.isEmpty { out.append((name, capped)) }
        }
        return out
    }

    private var cpuCard: some View {
        XCard {
            VStack(alignment: .leading, spacing: XSpacing.m) {
                HStack {
                    cardHeader("cpu", xLoc("处理器 · 每核心"))
                    Spacer()
                    // 当前条 / 迷你环 / 历史热力图 切换（记忆偏好）。
                    Picker("", selection: $coreViz) {
                        Image(systemName: "chart.bar.fill").tag("bars")
                            .accessibilityLabel(xLoc("柱状"))
                        Image(systemName: "circle.grid.2x2").tag("rings")
                            .accessibilityLabel(xLoc("圆环"))
                        Image(systemName: "square.grid.3x3.fill").tag("heat")
                            .accessibilityLabel(xLoc("热力图"))
                    }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                    .accessibilityLabel(xLoc("每核心视图"))
                    if let s = snap {
                        Text(xLocF("用户 %d%%  系统 %d%%", Int(s.cpuUser * 100), Int(s.cpuSystem * 100)))
                            .font(XFont.caption).foregroundStyle(XColor.textSecondary)
                    }
                }
                let cores = snap?.perCore ?? []
                if cores.isEmpty {
                    XSkeletonRows(count: 3)
                } else {
                    if coreViz == "rings" {
                        coreRings(cores)
                    } else if coreViz == "heat" {
                        coreHeatmap(cores)
                    } else {
                        HStack(alignment: .bottom, spacing: 6) {
                            ForEach(Array(cores.enumerated()), id: \.offset) { idx, v in coreBar(index: idx, value: v) }
                        }
                        .frame(height: 96)
                    }
                    HStack {
                        Text(coreSummary).font(XFont.caption).foregroundStyle(XColor.textTertiary)
                        Spacer()
                        Text(xLocF("平均负载 %@", loadTriple)).font(XFont.caption).foregroundStyle(XColor.textTertiary)
                    }
                }
            }
        }
    }

    /// 每核心迷你环：逐核实时占用，颜色随三段语义。有权威簇信息（Apple Silicon）时按
    /// 「性能核 / 能效核」真实分组标注（对齐 Sensei）；否则按内核顺序密排网格。
    private func coreRings(_ cores: [Double]) -> some View {
        let clusters = info?.coreClusters ?? []
        let grouped = clusters.count == cores.count && clusters.contains(true) && clusters.contains(false)
        return VStack(alignment: .leading, spacing: XSpacing.m) {
            if grouped {
                coreRingCluster(xLoc("性能核"), cores.indices.filter { clusters[$0] }.map { ($0, cores[$0]) })
                coreRingCluster(xLoc("能效核"), cores.indices.filter { !clusters[$0] }.map { ($0, cores[$0]) })
            } else {
                coreRingGrid(Array(cores.enumerated()).map { ($0.offset, $0.element) })
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(xLoc("每核心占用"))
        .accessibilityValue(xLocF("平均 %d%%", Int((cores.reduce(0, +) / Double(max(cores.count, 1))) * 100)))
    }

    private func coreRingCluster(_ label: String, _ pairs: [(Int, Double)]) -> some View {
        VStack(alignment: .leading, spacing: XSpacing.s) {
            Text(label).font(XFont.micro).foregroundStyle(XColor.textTertiary)
                .textCase(.uppercase).tracking(0.5)
            coreRingGrid(pairs)
        }
    }

    /// 一组「核心序号 + 占用」的迷你环网格。序号如实取自逻辑 CPU id。
    private func coreRingGrid(_ pairs: [(Int, Double)]) -> some View {
        let cols = Array(repeating: GridItem(.flexible(), spacing: XSpacing.s),
                         count: min(max(pairs.count, 1), 8))
        return LazyVGrid(columns: cols, spacing: XSpacing.m) {
            ForEach(Array(pairs.enumerated()), id: \.offset) { _, pair in
                VStack(spacing: 3) {
                    XMiniRing(fraction: pair.1, colors: XColor.gauge(pair.1), size: 40, lineWidth: 5) {
                        Text("\(Int((pair.1 * 100).rounded()))").font(XFont.monoMini)
                            .foregroundStyle(XColor.textPrimary)
                    }
                    Text("\(pair.0)").font(XFont.nano).foregroundStyle(XColor.textTertiary)
                }
            }
        }
    }

    // MARK: 每核心历史热力图（iStat 式：每核心一行随时间的负载热力带）

    /// 每核心随时间的负载热力带：行=核心（P/E 真实分组），列=时间样本，色随负载由暗到亮。
    /// 数据取自 `engine.perCoreHistory`（`[时间][核心]`），逐核切片为时间序列；读不到则退回当前条。
    @ViewBuilder private func coreHeatmap(_ cores: [Double]) -> some View {
        let hist = engine.perCoreHistory
        if hist.count < 2 {
            // 历史尚未积累（刚进页面）：先显示当前条，避免空白。
            HStack(alignment: .bottom, spacing: 6) {
                ForEach(Array(cores.enumerated()), id: \.offset) { idx, v in coreBar(index: idx, value: v) }
            }
            .frame(height: 96)
        } else {
            let clusters = info?.coreClusters ?? []
            let grouped = clusters.count == cores.count && clusters.contains(true) && clusters.contains(false)
            VStack(alignment: .leading, spacing: XSpacing.s) {
                if grouped {
                    heatCluster(xLoc("性能核"), cores.indices.filter { clusters[$0] }, hist, hot: XColor.metricCPU[0])
                    heatCluster(xLoc("能效核"), cores.indices.filter { !clusters[$0] }, hist, hot: XColor.metricCPU[1])
                } else {
                    ForEach(cores.indices, id: \.self) { c in
                        CoreHeatRow(index: c, series: hist.map { $0.indices.contains(c) ? $0[c] : 0 }, hot: XColor.metricCPU[0])
                    }
                }
                Text(xLoc("每核心近 60 秒负载 · 越亮越忙")).font(XFont.nano).foregroundStyle(XColor.textTertiary)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(xLoc("每核心负载历史热力图"))
        }
    }

    private func heatCluster(_ label: String, _ indices: [Int], _ hist: [[Double]], hot: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(XFont.nano).foregroundStyle(XColor.textTertiary)
                .textCase(.uppercase).tracking(0.5)
            ForEach(indices, id: \.self) { c in
                CoreHeatRow(index: c, series: hist.map { $0.indices.contains(c) ? $0[c] : 0 }, hot: hot)
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
                        .animation(XMotion.gauge, value: value)
                }
            }
            Text("\(index)").font(XFont.nano).foregroundStyle(XColor.textTertiary)
        }
        .frame(maxWidth: .infinity)
    }

    /// 核心构成摘要：改读 onAppear 已载入的 MacInfo（含 P/E 核数），不在 body 里调
    /// env.hardware.staticProfile()（会取 HardwareProfileService 锁、首帧还会跑 IORegistry/sysctl 探测，审计 P3）。
    private var coreSummary: String {
        guard let m = info else { return "" }
        if m.performanceCores > 0 && m.efficiencyCores > 0 {
            return xLocF("%d 核 · %d 性能 + %d 能效", m.cores, m.performanceCores, m.efficiencyCores)
        }
        return xLocF("%d 逻辑核心", m.cores)
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
                        Text(xLoc(snap?.memoryPressureLabel ?? "—")).xHeadline().foregroundStyle(XColor.textPrimary)
                        Text(xLoc("压力")).font(XFont.nano).foregroundStyle(XColor.textTertiary)
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
                        Text((snap?.memoryUsed ?? 0).formattedMemory).font(XFont.nano).foregroundStyle(XColor.textTertiary)
                    }
                }
                Text(xLocF("已用 / %@", (snap?.memoryTotal ?? 0).formattedMemory)).font(XFont.captionEmphasis).foregroundStyle(XColor.textSecondary)
            }
            .frame(maxWidth: .infinity)
        }
    }

    private var memoryBreakdownCard: some View {
        MonitorCard(icon: "memorychip.fill", title: xLoc("内存明细"), colors: XColor.metricMemory) {
            memBar
            breakdownRow(xLoc("应用内存"), snap?.memoryApp, XColor.memApp)
            breakdownRow(xLoc("联动内存"), snap?.memoryWired, XColor.memWired)
            breakdownRow(xLoc("已压缩"), snap?.memoryCompressed, XColor.memCompressed)
            breakdownRow(xLoc("缓存文件"), snap?.memoryCached, XColor.memCached)
        }
    }

    private var memBar: some View {
        GeometryReader { geo in
            let s = snap
            let total = Double(s?.memoryTotal ?? 1)
            HStack(spacing: 1) {
                seg(Double(s?.memoryApp ?? 0) / total, geo.size.width, XColor.memApp)
                seg(Double(s?.memoryWired ?? 0) / total, geo.size.width, XColor.memWired)
                seg(Double(s?.memoryCompressed ?? 0) / total, geo.size.width, XColor.memCompressed)
                seg(Double(s?.memoryCached ?? 0) / total, geo.size.width, XColor.memCached)
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
        MonitorCard(icon: "arrow.up.arrow.down", title: xLoc("分页"), colors: XColor.metricMemory) {
            statRow(xLoc("换入分页"), (snap?.pageIns ?? 0).formattedBytes)
            statRow(xLoc("换出分页"), (snap?.pageOuts ?? 0).formattedBytes)
        }
    }

    private var swapCard: some View {
        MonitorCard(icon: "internaldrive", title: xLoc("交换区"), colors: XColor.metricMemory) {
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
                    XRingGauge(progress: snap?.gpuUsage ?? 0, colors: XColor.metricGPU, lineWidth: 12, size: 150) {
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
                MonitorCard(icon: "cpu.fill", title: "GPU", colors: XColor.metricGPU) {
                    statRow(xLoc("占用率"), snap?.gpuUsage.map { "\(Int($0 * 100))%" } ?? "—")
                    if let t = snap?.gpuTemp { statRow(xLoc("温度"), String(format: "%.0f°C", t)) }
                }
                MonitorCard(icon: "waveform.path.ecg", title: xLoc("历史"), colors: XColor.metricGPU) {
                    XLineChart(values: engine.gpuHistory, colors: XColor.metricGPU).frame(height: 44)
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
                XBadge(xLoc(snap?.thermal.rawValue ?? "—"), color: thermalColor)
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
                    XSkeletonRows(count: 4).padding(.vertical, XSpacing.xs)
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
            XIconTile(systemImage: icon, colors: colors, size: 28, flat: true)
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

// MARK: - 每核心历史热力带（一行=一核，随时间由暗到亮）

/// 一核心的负载历史热力带：用 Canvas 逐列绘制，负载越高越亮（+高段偏暖）。
/// 序号如实取自逻辑 CPU id；`series` 为该核 0…1 的时间序列（旧→新）。
private struct CoreHeatRow: View {
    let index: Int
    let series: [Double]
    let hot: Color

    var body: some View {
        HStack(spacing: XSpacing.s) {
            Text("\(index)").font(XFont.microMono)
                .foregroundStyle(XColor.textTertiary).frame(width: 16, alignment: .trailing)
            Canvas { ctx, size in
                let n = series.count
                guard n > 0 else { return }
                let cw = size.width / CGFloat(n)
                for (i, v) in series.enumerated() {
                    let f = min(max(v, 0), 1)
                    let rect = CGRect(x: CGFloat(i) * cw, y: 0, width: cw + 0.6, height: size.height)
                    // 主色随负载提亮；高段（>0.8）叠一层暖色，形成「热」的顶端。
                    ctx.fill(Path(rect), with: .color(hot.opacity(0.08 + 0.92 * f)))
                    if f > 0.8 {
                        ctx.fill(Path(rect), with: .color(XColor.warning.opacity((f - 0.8) * 5 * 0.5)))
                    }
                }
            }
            .frame(height: 12)
            .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 3, style: .continuous).strokeBorder(XColor.hairline, lineWidth: 0.5))
            Text("\(Int((series.last ?? 0) * 100))%")
                .font(XFont.microMono)
                .foregroundStyle(XColor.textSecondary).frame(width: 30, alignment: .trailing)
        }
    }
}
