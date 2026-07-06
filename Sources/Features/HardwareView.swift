import SwiftUI
import AppKit
import Domain
import Infrastructure
import DesignSystem

// MARK: - ViewModel

@MainActor
final class HardwareViewModel: ObservableObject {
    @Published var profile: HardwareProfile?
    @Published var battery: BatteryHealth?
    @Published var gpu: GPUInfo?
    @Published var storage: [StorageHealth] = []
    @Published var displays: [DisplayInfo] = []
    @Published var temps: [TempReading] = []
    @Published var fans: [FanInfo] = []
    @Published var smart: NVMeSMART?
    @Published var details: HardwareDetails?
    @Published var loaded = false
    /// 电池功率趋势（近 N 次采样的瓦数绝对值，正=充电/放电功率大小），供迷你曲线。
    @Published var powerHistory: [Double] = []
    private let powerCap = 48
    // 网络接口档案（名称 / 类型 / IP / MAC / 速率）——超越 Sensei 的硬件页网络卡。
    @Published var interfaces: [NetworkInterfaceInfo] = []
    @Published var wifi: WiFiInfo?
    // CPU 实时频率（P/E 簇，MHz）与系统热压力——档案页的「活」指标。
    @Published var freqP: Double?
    @Published var freqE: Double?
    @Published var thermal: ProcessInfo.ThermalState = .nominal

    private let hw: HardwareProfileService
    private let sensors: SensorReader
    private let metrics: LiveMetricsSampler
    // 专属网络采样器：接口速率靠「上次采样」增量计算，与菜单栏/监视页共享同一实例会互相污染基线，
    // 故硬件页自持一份，速率读数独立稳定（名称/IP/MAC 本就无状态）。
    private let network = NetworkInfoService()
    private let bgQueue = DispatchQueue(label: "app.xico.hardware", qos: .userInitiated)
    private var timer: Timer?

    init(hw: HardwareProfileService, sensors: SensorReader, metrics: LiveMetricsSampler) {
        self.hw = hw
        self.sensors = sensors
        self.metrics = metrics
    }

    /// 真实开机时刻（kern.boottime；systemUptime 睡眠会漂移，不用它）。
    var bootDate: Date? {
        var mib: [Int32] = [CTL_KERN, KERN_BOOTTIME]
        var boot = timeval()
        var size = MemoryLayout<timeval>.stride
        guard sysctl(&mib, 2, &boot, &size, nil, 0) == 0, boot.tv_sec != 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(boot.tv_sec))
    }

    func start() {
        guard timer == nil else { return }   // 幂等：防 onAppear 二次触发泄漏 Timer
        loadStatic()
        refreshHealth()
        let t = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshHealth() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() { timer?.invalidate(); timer = nil }

    /// 静态档案 + 存储 + 显示器 + SMART：system_profiler 较慢，后台一次。
    private func loadStatic() {
        bgQueue.async { [hw] in
            let profile = hw.staticProfile()
            let storage = hw.storageHealth()
            let details = hw.profilerDetails()   // 复用 storageHealth 已触发的 profiler 缓存
            let smart = hw.nvmeSMART()   // Intel 可读详细日志；Apple Silicon 返回 nil
            Task { @MainActor [weak self] in
                self?.profile = profile
                self?.storage = storage
                self?.details = details
                self?.smart = smart
                self?.displays = hw.displays()   // NSScreen 需主线程
                self?.loaded = true
            }
        }
    }

    /// 电池 / GPU / 温度 / 风扇 / 网络接口：轻量，2 秒刷新。
    private func refreshHealth() {
        bgQueue.async { [hw, sensors, network, metrics] in
            let battery = hw.battery()
            let gpu = hw.gpu()
            let temps = sensors.temperatures()
            let fans = sensors.fans()
            let ifaces = network.interfaces()
            let wifi = network.wifi()
            let freq = metrics.cpuFrequency()   // 阻塞 ~90ms，已在后台队列
            let thermal = ProcessInfo.processInfo.thermalState
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.battery = battery
                self.gpu = gpu
                self.temps = temps
                self.fans = fans
                self.interfaces = ifaces
                self.wifi = wifi
                self.freqP = freq?.performance
                self.freqE = freq?.efficiency
                self.thermal = thermal
                if let b = battery, abs(b.powerWatts) > 0.01 {
                    self.powerHistory.append(abs(b.powerWatts))
                    if self.powerHistory.count > self.powerCap {
                        self.powerHistory.removeFirst(self.powerHistory.count - self.powerCap)
                    }
                }
            }
        }
    }

    /// 按类别聚合的代表温度（取该类均值）。
    func temperature(_ category: TempReading.Category) -> Double? {
        let vals = temps.filter { $0.category == category }.map(\.celsius)
        guard !vals.isEmpty else { return nil }
        return vals.reduce(0, +) / Double(vals.count)
    }
}

// MARK: - View

public struct HardwareView: View {
    private let env: XicoEnvironment
    @StateObject private var vm: HardwareViewModel
    // 观察并引用计数共享指标引擎：让内存/GPU 卡在硬件页也能拿到实时运行状态。
    // （旧实现只读 env.metricsEngine.snapshot 却从不 retain，非监视页时恒为 nil → 内存卡空白。）
    @ObservedObject private var engine: MetricsEngine

    public init(env: XicoEnvironment) {
        self.env = env
        _vm = StateObject(wrappedValue: HardwareViewModel(hw: env.hardware, sensors: env.sensors,
                                                          metrics: env.liveMetrics))
        self.engine = env.metricsEngine
    }

    private let columns = [GridItem(.adaptive(minimum: 320), spacing: XSpacing.m)]

    public var body: some View {
        VStack(spacing: 0) {
            XHeaderBar(title: xLoc("硬件"), subtitle: xLoc("档案 · 健康 · 温度")) {
                HStack(spacing: XSpacing.s) {
                    XLiveDot(size: 7)
                    Text("LIVE").font(.system(size: 10, weight: .bold)).tracking(1).foregroundStyle(XColor.success)
                }
            }
            ScrollView {
                VStack(spacing: XSpacing.m) {
                    heroCard
                    LazyVGrid(columns: columns, spacing: XSpacing.m) {
                        if vm.battery != nil { batteryCard }
                        memoryCard
                        storageCard
                        gpuCard
                        thermalCard
                        if !vm.interfaces.isEmpty { networkCard }
                        if !vm.displays.isEmpty { displayCard }
                        if !vm.temps.isEmpty { sensorsCard }
                    }
                }
                .padding(XSpacing.xl)
            }
        }
        .onAppear { vm.start(); engine.retain() }
        .onDisappear { vm.stop(); engine.release() }
    }

    // MARK: Hero

    private var heroCard: some View {
        XCard {
            VStack(alignment: .leading, spacing: XSpacing.l) {
                // 设备抬头：图标 + 营销全名 + 芯片·内存 副标（名称可换行，不再挤压）
                HStack(alignment: .center, spacing: XSpacing.l) {
                    XIconTile(systemImage: heroIcon, colors: XColor.brandGradientColors, size: 56)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(vm.profile?.marketingName ?? "Mac")
                            .xTitle().foregroundStyle(XColor.textPrimary)
                            .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                        Text(vm.profile.map { "\($0.chip) · \($0.memoryDescription)" } ?? "—")
                            .font(XFont.callout).foregroundStyle(XColor.textSecondary)
                    }
                    Spacer(minLength: 0)
                }
                Divider().overlay(XColor.hairline)
                // 规格栅格：芯片/核心/内存/系统/型号/型号编号/序列号 各占一格，
                // 完整展开、随宽度自适应换行——不再把关键信息折叠进右上角挤压区。
                specGrid
            }
        }
    }

    private var heroIcon: String {
        let id = vm.profile?.modelIdentifier ?? ""
        if id.contains("MacBook") { return "laptopcomputer" }
        if id.contains("Macmini") { return "macmini" }
        if id.contains("MacStudio") { return "macstudio" }
        if id.contains("iMac") { return "desktopcomputer" }
        if id.contains("MacPro") { return "macpro.gen3" }
        return "cpu"
    }

    // MARK: 规格栅格（展开全部关键信息）

    private struct SpecItem: Identifiable {
        let id: String        // = label，稳定 diff
        let label: String
        let value: String
        let copyValue: String?
    }

    private func specItems() -> [SpecItem] {
        guard let p = vm.profile else { return [] }
        var out: [SpecItem] = [
            SpecItem(id: "chip",   label: xLoc("芯片"), value: p.chip, copyValue: nil),
            SpecItem(id: "cores",  label: xLoc("核心"), value: p.coreDescription, copyValue: nil),
            SpecItem(id: "memory", label: xLoc("内存"), value: memorySpecText, copyValue: nil),
            SpecItem(id: "os",     label: xLoc("系统"), value: p.macOS, copyValue: nil),
        ]
        if !p.modelIdentifier.isEmpty {
            out.append(SpecItem(id: "model", label: xLoc("型号"), value: p.modelIdentifier, copyValue: nil))
        }
        if let mn = vm.details?.modelNumber, !mn.isEmpty {
            out.append(SpecItem(id: "modelno", label: xLoc("型号编号"), value: mn, copyValue: nil))
        }
        if let serial = vm.profile?.serialNumber, !serial.isEmpty {
            out.append(SpecItem(id: "serial", label: xLoc("序列号"), value: serial, copyValue: serial))
        }
        // 活指标：CPU 实时频率（P/E 簇）与开机信息——档案不止是静态铭牌。
        if let p = vm.freqP, p > 0 {
            out.append(SpecItem(id: "freqp", label: xLoc("性能核频率"), value: freqText(p), copyValue: nil))
        }
        if let e = vm.freqE, e > 0 {
            out.append(SpecItem(id: "freqe", label: xLoc("能效核频率"), value: freqText(e), copyValue: nil))
        }
        if let boot = vm.bootDate {
            out.append(SpecItem(id: "uptime", label: xLoc("开机时长"),
                                value: uptimeText(since: boot), copyValue: nil))
            let fmt = DateFormatter()
            fmt.locale = XLocale.swiftUILocale
            fmt.dateStyle = .medium; fmt.timeStyle = .short
            out.append(SpecItem(id: "boot", label: xLoc("上次开机"), value: fmt.string(from: boot), copyValue: nil))
        }
        return out
    }

    private func freqText(_ mhz: Double) -> String {
        mhz >= 1000 ? String(format: "%.2f GHz", mhz / 1000) : String(format: "%.0f MHz", mhz)
    }

    private func uptimeText(since boot: Date) -> String {
        let s = Int(Date().timeIntervalSince(boot))
        let d = s / 86400, h = (s % 86400) / 3600, m = (s % 3600) / 60
        if d > 0 { return xLocF("%d 天 %d 小时", d, h) }
        if h > 0 { return xLocF("%d 小时 %d 分钟", h, m) }
        return xLocF("%d 分钟", m)
    }

    /// 内存规格文案：容量 + 类型（如「16 GB 统一内存 · LPDDR5」），读不到类型则只显容量。
    private var memorySpecText: String {
        guard let p = vm.profile else { return "—" }
        if let t = vm.details?.memoryType, !t.isEmpty {
            let speed = vm.details?.memorySpeed ?? ""
            return speed.isEmpty ? "\(p.memoryDescription) · \(t)" : "\(p.memoryDescription) · \(t) \(speed)"
        }
        return p.memoryDescription
    }

    private var specGrid: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: XSpacing.l, alignment: .topLeading)],
                  alignment: .leading, spacing: XSpacing.m) {
            ForEach(specItems()) { specCell($0) }
        }
    }

    @State private var copied = false
    private func specCell(_ item: SpecItem) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(item.label).font(XFont.caption).foregroundStyle(XColor.textTertiary)
            if let copyValue = item.copyValue {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(copyValue, forType: .string)
                    withAnimation { copied = true }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { withAnimation { copied = false } }
                } label: {
                    HStack(spacing: 4) {
                        Text(copied ? xLoc("已复制") : item.value)
                            .font(XFont.bodyEmphasis)
                            .foregroundStyle(copied ? XColor.success : XColor.textPrimary)
                        Image(systemName: "doc.on.doc").font(.system(size: 9)).foregroundStyle(XColor.textTertiary)
                    }
                }
                .buttonStyle(.plain)
                .help(xLoc("点击复制序列号"))
            } else {
                Text(item.value).font(XFont.bodyEmphasis).foregroundStyle(XColor.textPrimary)
                    .lineLimit(2).truncationMode(.middle).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: 电池

    private var batteryCard: some View {
        let b = vm.battery!
        return HardwareCard(icon: "battery.100.bolt", title: xLoc("电池健康"),
                            iconColors: [XColor.success, XColor.accentTeal]) {
            HStack(alignment: .center, spacing: XSpacing.l) {
                XRingGauge(progress: Double(b.healthPercent) / 100,
                           colors: healthColors(b.healthPercent), lineWidth: 10, size: 104) {
                    VStack(spacing: 0) {
                        Text("\(b.healthPercent)%").xTitle().foregroundStyle(XColor.textPrimary)
                        Text(xLoc("最大容量")).font(.system(size: 9)).foregroundStyle(XColor.textTertiary)
                    }
                }
                VStack(alignment: .leading, spacing: XSpacing.s) {
                    metricRow(xLoc("循环次数"), "\(b.cycleCount)")
                    metricRow(xLoc("温度"), tempString(b.temperature))
                    metricRow(xLoc("电量"), "\(b.currentChargePercent)%")
                    HStack {
                        Text(xLoc("状态")).font(XFont.caption).foregroundStyle(XColor.textSecondary)
                        Spacer()
                        XBadge(chargeState(b), color: b.isCharging ? XColor.success : XColor.textSecondary)
                    }
                }
            }
            Divider().overlay(XColor.hairline)
            HStack {
                miniStat(xLoc("满充容量"), "\(b.fullChargeCapacity) mAh")
                Spacer()
                miniStat(xLoc("设计容量"), "\(b.designCapacity) mAh")
                Spacer()
                miniStat(xLoc("功率"), String(format: "%.1f W", abs(b.powerWatts)))
            }
            // 健康建议：仅从真实健康度 / 循环次数推导（Apple Silicon 电池设计寿命约 1000 次循环保 80%）。
            batteryAdviceRow(b)
            // 功率趋势迷你图（近 N 次采样）——放/充电功率随时间的曲线，超越 Sensei 的静态读数。
            if vm.powerHistory.count > 1 {
                let maxW = max(vm.powerHistory.max() ?? 1, 1)
                HStack(spacing: XSpacing.s) {
                    Text(xLoc("功率趋势")).font(.system(size: 9)).foregroundStyle(XColor.textTertiary)
                    XLineChart(values: vm.powerHistory.map { $0 / maxW },
                               colors: b.isCharging ? [XColor.success, XColor.accentTeal] : [XColor.warning, XColor.accentPink],
                               showDot: false)
                        .frame(height: 28)
                        .accessibilityLabel(xLoc("电池功率趋势"))
                }
            } else if abs(b.powerWatts) < 0.05 {
                // 满电接通电源时功率≈0、无波动——如实说明趋势图将在充放电时出现（绝不画一条假的平线）。
                Text(xLoc("充放电时显示功率趋势")).font(.system(size: 9)).foregroundStyle(XColor.textTertiary)
            }
        }
    }

    private func chargeState(_ b: BatteryHealth) -> String {
        if b.isCharging { return xLoc("充电中") }
        if b.externalConnected { return xLoc("已充满") }
        return xLoc("使用电池")
    }

    /// 电池健康建议——只从真实健康度与循环次数推导，绝不编造。三段：良好 / 正常 / 建议关注。
    @ViewBuilder private func batteryAdviceRow(_ b: BatteryHealth) -> some View {
        let (text, icon, color) = batteryAdvice(health: b.healthPercent, cycles: b.cycleCount)
        HStack(spacing: XSpacing.s) {
            Image(systemName: icon).font(.system(size: 11, weight: .semibold)).foregroundStyle(color)
            Text(text).font(XFont.caption).foregroundStyle(XColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
    }

    private func batteryAdvice(health: Int, cycles: Int) -> (String, String, Color) {
        if health < 80 || cycles >= 1000 {
            return (xLoc("容量已明显衰减，可考虑更换电池以恢复续航"), "exclamationmark.triangle.fill", XColor.warning)
        }
        if health >= 90 && cycles < 800 {
            return (xLoc("电池健康良好，正常使用即可"), "checkmark.seal.fill", XColor.success)
        }
        return (xLoc("电池健康正常，随循环增加会逐步衰减"), "battery.75", XColor.accentTeal)
    }

    // MARK: 存储

    private var storageCard: some View {
        HardwareCard(icon: "internaldrive", title: xLoc("存储健康"),
                     iconColors: [XColor.auroraBlue, XColor.accentTeal]) {
            if vm.storage.isEmpty {
                XSkeletonRows(count: 3)
            }
            // 内置卷始终显示；外置卷剔除 0 可用的只读挂载镜像（DMG 噪音，不是真磁盘）。
            ForEach(vm.storage.filter { $0.isInternal || $0.freeBytes > 0 }) { s in
                VStack(alignment: .leading, spacing: XSpacing.s) {
                    HStack {
                        Text(s.name).font(XFont.bodyEmphasis).foregroundStyle(XColor.textPrimary)
                        Spacer()
                        if s.isInternal {
                            XBadge(xLocF("SMART %@", xLoc(s.smartStatus)),
                                   color: s.smartStatus == "正常" ? XColor.success : XColor.warning)
                            if let trim = s.trimEnabled, trim {
                                XBadge("TRIM", color: XColor.accentTeal)
                            }
                        }
                    }
                    Text(s.model).font(XFont.caption).foregroundStyle(XColor.textSecondary)
                    XDiskBar(usedFraction: s.usedFraction, label: "", height: 8)
                    Text(xLocF("%@ 可用 / %@", s.freeBytes.formattedBytes, s.totalBytes.formattedBytes))
                        .font(XFont.caption).foregroundStyle(XColor.textTertiary)
                    if s.isInternal { smartDetail }
                }
                .padding(.vertical, 2)
            }
        }
    }

    /// 内置盘 SMART 详细（Intel 可读寿命/TBW/通电；Apple Silicon 退化为 SSD 温度）。
    @ViewBuilder private var smartDetail: some View {
        if let sm = vm.smart {
            Divider().overlay(XColor.hairline)
            HStack {
                metricRow(xLoc("剩余寿命"), "\(sm.lifeRemaining)%")
            }
            HStack(spacing: XSpacing.l) {
                miniStat(xLoc("已写入"), String(format: "%.1f TB", sm.terabytesWritten))
                Spacer()
                miniStat(xLoc("通电时长"), xLocF("%d 小时", sm.powerOnHours))
                Spacer()
                miniStat(xLoc("温度"), "\(sm.temperature)°C")
            }
            // 寿命预警：仅在剩余寿命真实偏低时提示（不对健康盘编造告警）。
            if sm.lifeRemaining < 20 {
                HStack(spacing: XSpacing.s) {
                    Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 11, weight: .semibold)).foregroundStyle(XColor.warning)
                    Text(xLoc("固态硬盘剩余寿命偏低，建议及时备份重要数据")).font(XFont.caption).foregroundStyle(XColor.textSecondary)
                    Spacer(minLength: 0)
                }
            }
        } else if let ssdTemp = vm.temperature(.ssd) {
            // Apple Silicon：详细 SMART 日志硬件不透传，退化展示固态温度（IOHID）
            Divider().overlay(XColor.hairline)
            HStack {
                Text(xLoc("固态温度")).font(XFont.caption).foregroundStyle(XColor.textSecondary)
                Spacer()
                Text(String(format: "%.0f°C", ssdTemp)).font(XFont.mono).foregroundStyle(tempColor(ssdTemp))
            }
        }
    }

    // MARK: 散热

    private var thermalCard: some View {
        HardwareCard(icon: "thermometer.medium", title: xLoc("散热"),
                     iconColors: [XColor.warning, XColor.accentPink]) {
            let cpu = vm.temperature(.cpu)
            let gpu = vm.temperature(.gpu)
            let ssd = vm.temperature(.ssd)
            let bat = vm.battery?.temperature
            if cpu == nil && gpu == nil && ssd == nil && bat == nil {
                Text(xLoc("此机型不提供温度读数")).font(XFont.caption).foregroundStyle(XColor.textTertiary)
            }
            tempRow(xLoc("处理器"), cpu)
            tempRow("GPU", gpu)
            tempRow(xLoc("固态硬盘"), ssd)
            tempRow(xLoc("电池"), bat)
            // 系统热压力（macOS 官方口径）：正常之外的状态才值得担心，用色点直说。
            HStack {
                Text(xLoc("热压力")).font(XFont.caption).foregroundStyle(XColor.textSecondary)
                Spacer()
                HStack(spacing: 5) {
                    Circle().fill(thermalColor(vm.thermal)).frame(width: 7, height: 7)
                    Text(thermalLabel(vm.thermal)).font(XFont.mono).foregroundStyle(thermalColor(vm.thermal))
                }
            }
            if !vm.fans.isEmpty {
                Divider().overlay(XColor.hairline)
                ForEach(vm.fans) { fan in fanRow(fan) }
            }
        }
    }

    /// 风扇行：当前 RPM + 在 [最低, 最高] 区间的位置条 + 区间标注（超越 Sensei 的静态转速）。
    private func fanRow(_ fan: FanInfo) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Image(systemName: "fanblades.fill").font(.system(size: 11)).foregroundStyle(XColor.metricNetwork[0])
                Text(xLocF("风扇 %d", fan.id + 1)).font(XFont.caption).foregroundStyle(XColor.textSecondary)
                Spacer()
                // 目标转速（SMC 暴露则显）——超越 Sensei 的静态转速。读不到即不显，绝不编造。
                if let tg = fan.target, tg > 0 {
                    Text(xLocF("目标 %d", tg)).font(XFont.caption).foregroundStyle(XColor.textTertiary)
                    Text("·").font(XFont.caption).foregroundStyle(XColor.textTertiary)
                }
                Text("\(fan.rpm) RPM").font(XFont.mono).foregroundStyle(XColor.textPrimary)
            }
            if let mn = fan.minimum, let mx = fan.maximum, mx > mn {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(XColor.surfaceAlt)
                        Capsule().fill(LinearGradient(colors: [XColor.metricNetwork[0], XColor.warning],
                                                      startPoint: .leading, endPoint: .trailing))
                            .frame(width: max(3, geo.size.width * fan.fraction))
                        // 目标转速刻度：在区间条上标一根竖线（SMC 有目标键才画）。
                        if let tf = fan.targetFraction {
                            Rectangle().fill(XColor.textPrimary.opacity(0.7))
                                .frame(width: 1.5, height: 8)
                                .position(x: max(1, geo.size.width * tf), y: 2)
                        }
                    }
                }
                .frame(height: 4)
                HStack {
                    Text(xLocF("最低 %d", mn)).font(.system(size: 9)).foregroundStyle(XColor.textTertiary)
                    Spacer()
                    Text(xLocF("最高 %d", mx)).font(.system(size: 9)).foregroundStyle(XColor.textTertiary)
                }
            }
        }
    }

    private func thermalLabel(_ t: ProcessInfo.ThermalState) -> String {
        switch t {
        case .nominal:  return xLoc("正常")
        case .fair:     return xLoc("一般")
        case .serious:  return xLoc("偏热")
        case .critical: return xLoc("过热")
        @unknown default: return xLoc("正常")
        }
    }

    private func thermalColor(_ t: ProcessInfo.ThermalState) -> Color {
        switch t {
        case .nominal:  return XColor.success
        case .fair:     return XColor.accentTeal
        case .serious:  return XColor.warning
        case .critical: return XColor.danger
        @unknown default: return XColor.success
        }
    }

    private func tempRow(_ label: String, _ celsius: Double?) -> some View {
        HStack {
            Text(label).font(XFont.caption).foregroundStyle(XColor.textSecondary)
            Spacer()
            if let c = celsius {
                Text(tempString(c)).font(XFont.mono).foregroundStyle(tempColor(c))
            } else {
                Text("—").font(XFont.mono).foregroundStyle(XColor.textTertiary)
            }
        }
    }

    // MARK: GPU

    private var gpuCard: some View {
        HardwareCard(icon: "cpu.fill", title: "GPU",
                     iconColors: [XColor.auroraViolet, XColor.auroraOrchid]) {
            HStack(alignment: .center, spacing: XSpacing.l) {
                let util = engine.snapshot?.gpuUsage ?? vm.gpu?.utilizationPercent.map { $0 / 100 }
                XRingGauge(progress: util ?? 0, colors: XColor.gpuGauge(util ?? 0), lineWidth: 10, size: 96) {
                    Text(util.map { "\(Int($0 * 100))%" } ?? "—").xHeadline().foregroundStyle(XColor.textPrimary)
                }
                VStack(alignment: .leading, spacing: XSpacing.s) {
                    metricRow(xLoc("型号"), vm.gpu?.name ?? "—")
                    if let cores = vm.gpu?.coreCount { metricRow(xLoc("核心"), "\(cores)") }
                    if let mem = vm.gpu?.inUseMemoryBytes { metricRow(xLoc("显存占用"), mem.formattedBytes) }
                }
                Spacer(minLength: 0)
            }
        }
    }

    // MARK: 内存

    private var memoryCard: some View {
        HardwareCard(icon: "memorychip", title: xLoc("内存"),
                     iconColors: [XColor.accentTeal, XColor.auroraBlue]) {
            // 规格行：容量 + 类型 + 已用占比（右）
            HStack(alignment: .firstTextBaseline) {
                Text(memorySpecText).font(XFont.bodyEmphasis).foregroundStyle(XColor.textPrimary)
                    .lineLimit(1).truncationMode(.tail)
                Spacer(minLength: XSpacing.s)
                if let snap = engine.snapshot {
                    Text("\(Int(snap.memoryUsedFraction * 100))%")
                        .font(XFont.mono).foregroundStyle(memColor.app)
                }
            }
            if let snap = engine.snapshot {
                let total = max(1, Double(snap.memoryTotal))
                XSegmentBar(segments: [
                    .init(id: 0, fraction: Double(snap.memoryApp) / total,        color: memColor.app),
                    .init(id: 1, fraction: Double(snap.memoryWired) / total,       color: memColor.wired),
                    .init(id: 2, fraction: Double(snap.memoryCompressed) / total,  color: memColor.compressed),
                    .init(id: 3, fraction: Double(snap.memoryCached) / total,      color: memColor.cached),
                ], height: 10)
                .padding(.top, 2)
                Divider().overlay(XColor.hairline)
                // 运行状态明细：每项一枚色点 = 对应上方分段条
                memLegendRow(xLoc("应用内存"), snap.memoryApp, memColor.app)
                memLegendRow(xLoc("联动内存"), snap.memoryWired, memColor.wired)
                memLegendRow(xLoc("已压缩"), snap.memoryCompressed, memColor.compressed)
                memLegendRow(xLoc("缓存文件"), snap.memoryCached, memColor.cached)
                if snap.swapTotal > 0 {
                    metricRow(xLoc("交换区"), xLocF("%@ / %@", snap.swapUsed.formattedMemory, snap.swapTotal.formattedMemory))
                }
                HStack {
                    Text(xLoc("内存压力")).font(XFont.caption).foregroundStyle(XColor.textSecondary)
                    Spacer()
                    XBadge(xLoc(snap.memoryPressureLabel), color: pressureColor(snap.memoryPressure))
                }
            } else {
                XSkeletonRows(count: 4)
            }
            // 规格（超越 Sensei）：制造商 / 插槽——读得到才显（Apple Silicon 板载；Intel 逐条 DIMM）。
            if let d = vm.details, !d.memoryManufacturer.isEmpty || !d.memorySlots.isEmpty {
                Divider().overlay(XColor.hairline)
                if !d.memoryManufacturer.isEmpty { metricRow(xLoc("制造商"), d.memoryManufacturer) }
                if !d.memorySlots.isEmpty { metricRow(xLoc("插槽"), d.memorySlots) }
            }
        }
    }

    private typealias MemColors = (app: Color, wired: Color, compressed: Color, cached: Color)
    private var memColor: MemColors {
        (app: XColor.memApp, wired: XColor.memWired, compressed: XColor.memCompressed, cached: XColor.memCached)
    }

    private func memLegendRow(_ label: String, _ bytes: Int64, _ color: Color) -> some View {
        HStack(spacing: XSpacing.s) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(label).font(XFont.caption).foregroundStyle(XColor.textSecondary)
            Spacer()
            Text(bytes.formattedMemory).font(XFont.mono).foregroundStyle(XColor.textPrimary)
        }
    }

    private func pressureColor(_ level: Int) -> Color {
        switch level { case 4: return XColor.danger; case 2: return XColor.warning; default: return XColor.success }
    }

    // MARK: 显示器

    private var displayCard: some View {
        HardwareCard(icon: "display", title: xLoc("显示器"),
                     iconColors: [XColor.auroraBlue, XColor.auroraViolet]) {
            ForEach(vm.displays) { d in
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: XSpacing.s) {
                        Text(d.name).font(XFont.bodyEmphasis).foregroundStyle(XColor.textPrimary)
                        if d.isBuiltin { XBadge(xLoc("内建"), color: XColor.accentTeal) }
                        if d.isHDR { XBadge("HDR", color: XColor.auroraViolet) }
                        // ProMotion 徽标：仅在显示器真实支持 >60Hz 可变刷新时显示（读不到即无）。
                        if d.proMotion { XBadge("ProMotion", color: XColor.metricGPU[0]) }
                        Spacer()
                        Text("\(d.refreshHz) Hz").font(XFont.mono).foregroundStyle(XColor.textSecondary)
                    }
                    metricRow(xLoc("原生分辨率"), d.resolutionText)
                    metricRow(xLoc("缩放"), d.scaledText)
                    if let inch = d.diagonalInches {
                        metricRow(xLoc("尺寸"), xLocF("%.1f 英寸", inch))
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }

    // MARK: 网络（接口清单 + IP / MAC + Wi-Fi 链路，超越 Sensei）

    private var networkCard: some View {
        HardwareCard(icon: "network", title: xLoc("网络"),
                     iconColors: [XColor.accentTeal, XColor.auroraBlue]) {
            let active = vm.interfaces.filter { $0.isActive }
            if active.isEmpty {
                Text(xLoc("无活动网络接口")).font(XFont.caption).foregroundStyle(XColor.textTertiary)
            }
            ForEach(Array(active.enumerated()), id: \.element.id) { idx, i in
                if idx > 0 { Divider().overlay(XColor.hairline) }
                VStack(alignment: .leading, spacing: XSpacing.xs) {
                    HStack(spacing: XSpacing.s) {
                        Image(systemName: i.type.icon).font(.system(size: 12)).foregroundStyle(XColor.accentTeal).frame(width: 18)
                        Text(i.displayName).font(XFont.bodyEmphasis).foregroundStyle(XColor.textPrimary).lineLimit(1)
                        Spacer()
                        if i.type == .wifi, let tx = vm.wifi?.txRate {
                            Text(xLocF("%d Mbps", Int(tx))).font(XFont.mono).foregroundStyle(XColor.textSecondary)
                        }
                    }
                    if let ip = i.ipv4 { netIDRow("IPv4", ip) }
                    if let ip6 = i.ipv6 { netIDRow("IPv6", ip6) }
                    if let mac = i.macAddress { netIDRow("MAC", mac) }
                    if i.type == .wifi, let w = vm.wifi {
                        if let ssid = w.ssid { metricRow(xLoc("网络名称"), ssid) }
                        if let ch = w.channel { metricRow(xLoc("信道"), "\(ch)") }
                        if let rssi = w.rssi { metricRow(xLoc("信号"), "\(rssi) dBm") }
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }

    private func netIDRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).font(XFont.caption).foregroundStyle(XColor.textSecondary)
            Spacer()
            Text(value).font(XFont.captionMono).foregroundStyle(XColor.textPrimary)
                .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
        }
    }

    // MARK: 全部温度传感器（Sensei 式传感器中心）

    private var sensorsCard: some View {
        HardwareCard(icon: "sensor.tag.radiowaves.forward", title: xLoc("传感器"),
                     iconColors: [XColor.warning, XColor.accentTeal]) {
            let grouped = sensorGroups()
            if grouped.isEmpty {
                Text(xLoc("此机型不提供温度读数")).font(XFont.caption).foregroundStyle(XColor.textTertiary)
            }
            ForEach(grouped, id: \.0) { name, temps in
                VStack(alignment: .leading, spacing: XSpacing.s) {
                    Text(xLoc(name)).font(.system(size: 10, weight: .semibold)).foregroundStyle(XColor.textTertiary)
                        .textCase(.uppercase).tracking(0.5)
                    // 两列密排：M1 这类机型传感器可达十几个，单列会刷屏——收成两列，像 iStat 传感器面板。
                    // 用下标做 id：传感器名可能重复（如多个 "gas gauge battery"），\.id 会冲突。
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

    /// 单个传感器格：名称 + 温度 + 归一化温度条（0–100°C）。两列密排复用。
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
        let all = vm.temps
        let order: [(TempReading.Category, String)] = [
            (.cpu, xLoc("处理器")), (.gpu, "GPU"), (.ssd, xLoc("固态硬盘")),
            (.battery, xLoc("电池")), (.ambient, xLoc("环境")), (.other, xLoc("其他"))
        ]
        var out: [(String, [TempReading])] = []
        for (cat, name) in order {
            let items = all.filter { $0.category == cat }.sorted { $0.celsius > $1.celsius }
            // "其他" 类只取前 8 个避免刷屏
            let capped = cat == .other ? Array(items.prefix(8)) : items
            if !capped.isEmpty { out.append((name, capped)) }
        }
        return out
    }

    // MARK: 共用

    private func metricRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).font(XFont.caption).foregroundStyle(XColor.textSecondary)
            Spacer()
            Text(value).font(XFont.bodyEmphasis).foregroundStyle(XColor.textPrimary)
                .lineLimit(1).truncationMode(.middle)
        }
    }
    private func miniStat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value).font(XFont.mono).foregroundStyle(XColor.textPrimary)
            Text(label).font(.system(size: 9)).foregroundStyle(XColor.textTertiary)
        }
    }

    private func tempString(_ c: Double) -> String { String(format: "%.0f°C", c) }
    private func tempColor(_ c: Double) -> Color {
        if c >= 85 { return XColor.danger }
        if c >= 70 { return XColor.warning }
        if c >= 55 { return XColor.accentTeal }
        return XColor.success
    }
    private func healthColors(_ percent: Int) -> [Color] {
        if percent < 80 { return [XColor.warning, XColor.accentPink] }
        return [XColor.success, XColor.accentTeal]
    }
}

// MARK: - 卡片容器（标题 + 图标 + 内容）

private struct HardwareCard<Content: View>: View {
    let icon: String
    let title: String
    let iconColors: [Color]
    @ViewBuilder let content: Content
    var body: some View {
        XCard {
            VStack(alignment: .leading, spacing: XSpacing.m) {
                HStack(spacing: XSpacing.s) {
                    XIconTile(systemImage: icon, colors: iconColors, size: 28, flat: true)
                    Text(title).font(XFont.captionEmphasis).foregroundStyle(XColor.textSecondary)
                        .textCase(.uppercase).tracking(0.6)
                    Spacer()
                }
                content
            }
        }
    }
}
