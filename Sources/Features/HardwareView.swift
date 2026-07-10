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
    /// 温度趋势（P5·H1）：CPU / GPU / SSD 代表温度的滚动历史（2s 采样 × 60 ≈ 2 分钟窗）。
    @Published var cpuTempHistory: [Double] = []
    @Published var gpuTempHistory: [Double] = []
    @Published var ssdTempHistory: [Double] = []
    private let tempCap = 60
    // 网络接口档案（名称 / 类型 / IP / MAC / 速率）——超越 Sensei 的硬件页网络卡。
    @Published var interfaces: [NetworkInterfaceInfo] = []
    @Published var wifi: WiFiInfo?
    // 系统热压力——档案页的「活」指标。CPU 实时频率（P/E 簇）改从共享 MetricsEngine 读取，
    // 不再由本 VM 各自跑一遍 ~90ms 阻塞的 DVFS 采样（消除硬件页与监视页的重复频率读，审计 P3）。
    @Published var thermal: ProcessInfo.ThermalState = .nominal

    private let hw: HardwareProfileService
    private let sensors: SensorReader
    // 专属网络采样器：接口速率靠「上次采样」增量计算，与菜单栏/监视页共享同一实例会互相污染基线，
    // 故硬件页自持一份，速率读数独立稳定（名称/IP/MAC 本就无状态）。
    private let network = NetworkInfoService()
    private let bgQueue = DispatchQueue(label: "app.xico.hardware", qos: .userInitiated)
    private var timer: Timer?

    init(hw: HardwareProfileService, sensors: SensorReader) {
        self.hw = hw
        self.sensors = sensors
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
        bgQueue.async { [hw, sensors, network] in
            let battery = hw.battery()
            let gpu = hw.gpu()
            let temps = sensors.temperatures()
            let fans = sensors.fans()
            let ifaces = network.interfaces()
            let wifi = network.wifi()
            let thermal = ProcessInfo.processInfo.thermalState
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.battery = battery
                self.gpu = gpu
                self.temps = temps
                self.fans = fans
                self.interfaces = ifaces
                self.wifi = wifi
                self.thermal = thermal
                if let b = battery, abs(b.powerWatts) > 0.01 {
                    self.powerHistory.append(abs(b.powerWatts))
                    if self.powerHistory.count > self.powerCap {
                        self.powerHistory.removeFirst(self.powerHistory.count - self.powerCap)
                    }
                }
                // 温度趋势历史：只在读得到时追加（读不到不补 0——曲线绝不编造）。
                func pushTemp(_ v: Double?, into arr: inout [Double]) {
                    guard let v, v > 0 else { return }
                    arr.append(v)
                    if arr.count > self.tempCap { arr.removeFirst(arr.count - self.tempCap) }
                }
                pushTemp(self.temperature(.cpu), into: &self.cpuTempHistory)
                pushTemp(self.temperature(.gpu), into: &self.gpuTempHistory)
                pushTemp(self.temperature(.ssd), into: &self.ssdTempHistory)
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
    // 引擎引用计数守卫：确保 retain/release 每视图各恰好一次——onAppear/onDisappear 可能因
    // SwiftUI 重建二次触发，无守卫会让计数漂移、采样器在视图消失后仍空转。
    @State private var didRetain = false

    public init(env: XicoEnvironment) {
        self.env = env
        _vm = StateObject(wrappedValue: HardwareViewModel(hw: env.hardware, sensors: env.sensors))
        self.engine = env.metricsEngine
    }


    public var body: some View {
        VStack(spacing: 0) {
            XHeaderBar(title: xLoc("硬件"), subtitle: xLoc("档案 · 健康 · 温度")) {
                HStack(spacing: XSpacing.s) {
                    XLiveDot(size: 7)
                    Text("LIVE").font(XFont.micro).tracking(1).foregroundStyle(XColor.success)
                }
            }
            ScrollView {
                VStack(spacing: XSpacing.m) {
                    heroCard
                    // 非懒 Grid + 成对 GridRow（P8）：①同排两卡强制等高（fillHeight 卡面补齐），
                    // 彻底消灭「一大一小」；②视图不再被 Lazy 回收——往回滚动时环/曲线不会重播入场动画
                    // （此前 GPU 环滚动一次动画一次，像进度条脱缰）。卡片数量固定个位数，无需懒加载。
                    pairedGrid
                }
                .padding(XSpacing.xl)
            }
        }
        .onAppear { vm.start(); if !didRetain { didRetain = true; engine.retain() } }
        .onDisappear { vm.stop(); if didRetain { didRetain = false; engine.release() } }
    }

    /// 卡片成对网格：收集可见卡后两两一排（奇数最后一张独占整排）。
    private var pairedGrid: some View {
        var cards: [(String, AnyView)] = []
        if let b = vm.battery { cards.append(("battery", AnyView(batteryCard(b)))) }
        cards.append(("memory", AnyView(memoryCard)))
        cards.append(("storage", AnyView(storageCard)))
        cards.append(("thermal", AnyView(thermalCard)))
        cards.append(("gpu", AnyView(gpuCard)))
        if !vm.interfaces.isEmpty { cards.append(("network", AnyView(networkCard))) }
        if !vm.displays.isEmpty { cards.append(("display", AnyView(displayCard))) }
        if !vm.temps.isEmpty { cards.append(("sensors", AnyView(sensorsCard))) }
        return Grid(horizontalSpacing: XSpacing.m, verticalSpacing: XSpacing.m) {
            ForEach(Array(stride(from: 0, to: cards.count, by: 2)), id: \.self) { i in
                GridRow {
                    cards[i].1.frame(maxWidth: .infinity, maxHeight: .infinity)
                    if i + 1 < cards.count {
                        cards[i + 1].1.frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                    }
                }
            }
        }
    }

    // MARK: Hero

    private var heroCard: some View {
        XCard {
            VStack(alignment: .leading, spacing: XSpacing.l) {
                // 设备抬头：机型插画（线稿 + 品牌渐变描边，P5·H2）+ 营销全名 + 芯片·内存 副标
                HStack(alignment: .center, spacing: XSpacing.l) {
                    if let family = deviceFamily {
                        DeviceArt(family: family)
                            .frame(width: 64, height: 56)
                            .accessibilityHidden(true)
                    } else {
                        XIconTile(systemImage: heroIcon, colors: XColor.brandGradientColors, size: 56)
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        if let p = vm.profile {
                            Text(p.marketingName)
                                .xTitle().foregroundStyle(XColor.textPrimary)
                                .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                            Text("\(p.chip) · \(p.memoryDescription)")
                                .font(XFont.callout).foregroundStyle(XColor.textSecondary)
                        } else {
                            // 静态档案（system_profiler）尚在后台读取——占位骨架，避免抬头「Mac / —」硬闪。
                            XSkeleton(width: 180, height: 22)
                            XSkeleton(width: 120, height: 13)
                        }
                    }
                    Spacer(minLength: 0)
                }
                Divider().overlay(XColor.hairline)
                // 规格栅格：芯片/核心/内存/系统/型号/型号编号/序列号 各占一格，
                // 完整展开、随宽度自适应换行——不再把关键信息折叠进右上角挤压区。
                specGrid
            }
        }
        // 骨架 → 数据到位：crossfade 而非硬切（P5·H3）。
        .animation(XMotion.crossfade, value: vm.profile != nil)
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

    /// 机型家族（有插画的机型返回非 nil；未知机型回退 SF Symbol，绝不画错设备）。
    private var deviceFamily: DeviceArt.Family? {
        let id = vm.profile?.modelIdentifier ?? ""
        if id.contains("MacBook") { return .laptop }
        if id.contains("Macmini") { return .mini }
        if id.contains("MacStudio") { return .studio }
        if id.contains("iMac") { return .imac }
        if id.contains("MacPro") { return .tower }
        return nil
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
        // 频率取自共享 MetricsEngine（视图 onAppear 已 retain），与监视页复用同一次 DVFS 采样。
        if let p = engine.cpuFreqP, p > 0 {
        }
        if let e = engine.cpuFreqE, e > 0 {
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
            if vm.loaded {
                ForEach(specItems()) { specCell($0) }
            } else {
                // 档案未就绪时预留规格格位（骨架），让抬头高度稳定、不因数据到达而跳动。
                ForEach(0..<6, id: \.self) { _ in specCellSkeleton }
            }
        }
    }

    private var specCellSkeleton: some View {
        VStack(alignment: .leading, spacing: 3) {
            XSkeleton(width: 40, height: 9)
            XSkeleton(width: 90, height: 12)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // 每格独立追踪「已复制」，避免单个共享 flag 让所有可复制格同时切成「已复制」。
    @State private var copiedID: String?
    private func specCell(_ item: SpecItem) -> some View {
        let isCopied = copiedID == item.id
        return VStack(alignment: .leading, spacing: 3) {
            Text(item.label).font(XFont.caption).foregroundStyle(XColor.textTertiary)
            if let copyValue = item.copyValue {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(copyValue, forType: .string)
                    withAnimation { copiedID = item.id }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
                        withAnimation { if copiedID == item.id { copiedID = nil } }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(isCopied ? xLoc("已复制") : item.value)
                            .font(XFont.bodyEmphasis)
                            .foregroundStyle(isCopied ? XColor.success : XColor.textPrimary)
                        Image(systemName: "doc.on.doc").font(XFont.nano).foregroundStyle(XColor.textTertiary)
                    }
                }
                .buttonStyle(.plain)
                .help(xLoc("点击复制序列号"))
                .accessibilityLabel(xLoc("复制序列号"))
            } else {
                Text(item.value).font(XFont.bodyEmphasis).foregroundStyle(XColor.textPrimary)
                    .lineLimit(2).truncationMode(.middle).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: 电池

    private func batteryCard(_ b: BatteryHealth) -> some View {
        HardwareCard(icon: "battery.100.bolt", title: xLoc("电池健康"),
                            iconColors: [XColor.success, XColor.accentTeal]) {
            HStack(alignment: .center, spacing: XSpacing.l) {
                XRingGauge(progress: Double(b.healthPercent) / 100,
                           colors: healthColors(b.healthPercent), lineWidth: 10, size: 104) {
                    VStack(spacing: 0) {
                        Text("\(b.healthPercent)%").xTitle().foregroundStyle(XColor.textPrimary)
                        Text(xLoc("最大容量")).font(XFont.nano).foregroundStyle(XColor.textTertiary)
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
                    Text(xLoc("功率趋势")).font(XFont.nano).foregroundStyle(XColor.textTertiary)
                    XLineChart(values: vm.powerHistory.map { $0 / maxW },
                               colors: b.isCharging ? [XColor.success, XColor.accentTeal] : [XColor.warning, XColor.accentPink],
                               showDot: false)
                        .frame(height: 28)
                        .accessibilityLabel(xLoc("电池功率趋势"))
                }
            } else if abs(b.powerWatts) < 0.05 {
                // 满电接通电源时功率≈0、无波动——如实说明趋势图将在充放电时出现（绝不画一条假的平线）。
                Text(xLoc("充放电时显示功率趋势")).font(XFont.nano).foregroundStyle(XColor.textTertiary)
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
            Image(systemName: icon).font(XFont.captionEmphasis).foregroundStyle(color)
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
                    Text(xLoc(s.model)).font(XFont.caption).foregroundStyle(XColor.textSecondary)
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
                    Image(systemName: "exclamationmark.triangle.fill").font(XFont.captionEmphasis).foregroundStyle(XColor.warning)
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
            tempRow(xLoc("处理器"), cpu, trend: vm.cpuTempHistory)
            tempRow("GPU", gpu, trend: vm.gpuTempHistory)
            tempRow(xLoc("固态硬盘"), ssd, trend: vm.ssdTempHistory)
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
                Image(systemName: "fanblades.fill").font(XFont.caption).foregroundStyle(XColor.metricNetwork[0])
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
                    Text(xLocF("最低 %d", mn)).font(XFont.nano).foregroundStyle(XColor.textTertiary)
                    Spacer()
                    Text(xLocF("最高 %d", mx)).font(XFont.nano).foregroundStyle(XColor.textTertiary)
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

    /// 温度行：当前值 + 可选趋势迷你曲线（P5·H1，照抄电池 powerHistory 模式；
    /// 归一化到 20–105℃ 视窗，与 sensorCell 的热度条同一量纲直觉）。
    @ViewBuilder
    private func tempRow(_ label: String, _ celsius: Double?, trend: [Double] = []) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(label).font(XFont.caption).foregroundStyle(XColor.textSecondary)
                Spacer()
                if let c = celsius {
                    Text(tempString(c)).font(XFont.mono).foregroundStyle(tempColor(c))
                        .contentTransition(.numericText())
                } else {
                    Text("—").font(XFont.mono).foregroundStyle(XColor.textTertiary)
                }
            }
            if trend.count > 1, let cur = celsius {
                XLineChart(values: trend.map { min(max(($0 - 20) / 85, 0), 1) },
                           colors: [tempColor(cur), tempColor(cur).opacity(0.6)],
                           showDot: false, lineWidth: 1.5)
                    .frame(height: 22)
                    .accessibilityLabel(xLocF("%@ 温度趋势", label))
            }
        }
    }

    // MARK: GPU

    private var gpuCard: some View {
        HardwareCard(icon: "cpu.fill", title: "GPU",
                     iconColors: [XColor.auroraViolet, XColor.auroraOrchid]) {
            HStack(alignment: .center, spacing: XSpacing.l) {
                let util = engine.snapshot?.gpuUsage ?? vm.gpu?.utilizationPercent.map { $0 / 100 }
                XRingGauge(progress: util ?? 0, colors: XColor.metricGPU, lineWidth: 10, size: 96) {
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
                        Image(systemName: i.type.icon).font(XFont.callout).foregroundStyle(XColor.accentTeal).frame(width: 18)
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
                    Text(xLoc(name)).font(XFont.micro).foregroundStyle(XColor.textTertiary)
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
                .contentTransition(.numericText())   // 活指标数字滚动而非硬跳（P5·H3）
        }
    }
    private func miniStat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value).font(XFont.mono).foregroundStyle(XColor.textPrimary)
            Text(label).font(XFont.nano).foregroundStyle(XColor.textTertiary)
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

// MARK: - 机型插画（P5·H2：极简线稿 + 品牌渐变描边——比 56pt SF Symbol 更有「这台机器」的实感）

/// 自绘 Path 线稿（2pt 圆角笔画、无填充），设计语言：克制、精密仪表说明书风。
/// 画布 64×56，居中构图；未知机型由调用方回退 SF Symbol，绝不画错设备。
private struct DeviceArt: View {
    enum Family { case laptop, mini, studio, imac, tower }
    let family: Family

    var body: some View {
        artPath
            .stroke(XColor.brandGradient,
                    style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
            .frame(width: 64, height: 56)
    }

    private var artPath: Path {
        switch family {
        case .laptop: return Self.laptopPath()
        case .mini:   return Self.miniPath()
        case .studio: return Self.studioPath()
        case .imac:   return Self.imacPath()
        case .tower:  return Self.towerPath()
        }
    }

    private static func laptopPath() -> Path {
        var p = Path()
        // 屏幕 + 底座（微喇叭口）+ 触控板暗示
        p.addRoundedRect(in: CGRect(x: 12, y: 8, width: 40, height: 28), cornerSize: CGSize(width: 4, height: 4))
        p.move(to: CGPoint(x: 6, y: 42));  p.addLine(to: CGPoint(x: 58, y: 42))
        p.move(to: CGPoint(x: 8, y: 42));  p.addLine(to: CGPoint(x: 12, y: 36))
        p.move(to: CGPoint(x: 56, y: 42)); p.addLine(to: CGPoint(x: 52, y: 36))
        p.move(to: CGPoint(x: 28, y: 39)); p.addLine(to: CGPoint(x: 36, y: 39))
        return p
    }

    private static func miniPath() -> Path {
        var p = Path()
        p.addRoundedRect(in: CGRect(x: 12, y: 20, width: 40, height: 16), cornerSize: CGSize(width: 5, height: 5))
        p.addEllipse(in: CGRect(x: 17, y: 30, width: 2, height: 2))   // 电源指示点
        return p
    }

    private static func studioPath() -> Path {
        var p = Path()
        p.addRoundedRect(in: CGRect(x: 14, y: 12, width: 36, height: 32), cornerSize: CGSize(width: 6, height: 6))
        // 前面板双 USB-C + 读卡口
        p.addEllipse(in: CGRect(x: 22, y: 36, width: 3, height: 3))
        p.addEllipse(in: CGRect(x: 29, y: 36, width: 3, height: 3))
        p.move(to: CGPoint(x: 38, y: 37.5)); p.addLine(to: CGPoint(x: 43, y: 37.5))
        return p
    }

    private static func imacPath() -> Path {
        var p = Path()
        p.addRoundedRect(in: CGRect(x: 8, y: 6, width: 48, height: 30), cornerSize: CGSize(width: 4, height: 4))
        // 下巴分割线 + 支架
        p.move(to: CGPoint(x: 8, y: 29));  p.addLine(to: CGPoint(x: 56, y: 29))
        p.move(to: CGPoint(x: 27, y: 36)); p.addLine(to: CGPoint(x: 24, y: 46))
        p.move(to: CGPoint(x: 37, y: 36)); p.addLine(to: CGPoint(x: 40, y: 46))
        p.move(to: CGPoint(x: 18, y: 46)); p.addLine(to: CGPoint(x: 46, y: 46))
        return p
    }

    private static func towerPath() -> Path {
        var p = Path()
        p.addRoundedRect(in: CGRect(x: 18, y: 8, width: 28, height: 40), cornerSize: CGSize(width: 5, height: 5))
        // 提手 + 散热孔阵
        p.move(to: CGPoint(x: 22, y: 8)); p.addQuadCurve(to: CGPoint(x: 30, y: 8), control: CGPoint(x: 26, y: 2))
        p.move(to: CGPoint(x: 34, y: 8)); p.addQuadCurve(to: CGPoint(x: 42, y: 8), control: CGPoint(x: 38, y: 2))
        for row in 0..<3 {
            for col in 0..<3 {
                p.addEllipse(in: CGRect(x: CGFloat(25 + col * 6), y: CGFloat(18 + row * 7), width: 2.5, height: 2.5))
            }
        }
        return p
    }
}

// MARK: - 卡片容器（薄别名 → 设计系统 XSectionCard，P5·H5 收编）

private struct HardwareCard<Content: View>: View {
    let icon: String
    let title: String
    let iconColors: [Color]
    @ViewBuilder let content: Content
    var body: some View {
        // fillHeight：网格同排两卡等高（P8 用户反馈——「一大一小」难看），内容顶对齐。
        XSectionCard(icon: icon, title: title, iconColors: iconColors, fillHeight: true) { content }
    }
}
