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
    @Published var loaded = false

    private let hw: HardwareProfileService
    private let sensors: SensorReader
    private let bgQueue = DispatchQueue(label: "app.xico.hardware", qos: .userInitiated)
    private var timer: Timer?

    init(hw: HardwareProfileService, sensors: SensorReader) {
        self.hw = hw
        self.sensors = sensors
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
            let smart = hw.nvmeSMART()   // Intel 可读详细日志；Apple Silicon 返回 nil
            Task { @MainActor [weak self] in
                self?.profile = profile
                self?.storage = storage
                self?.smart = smart
                self?.displays = hw.displays()
                self?.loaded = true
            }
        }
    }

    /// 电池 / GPU / 温度 / 风扇：轻量，2 秒刷新。
    private func refreshHealth() {
        bgQueue.async { [hw, sensors] in
            let battery = hw.battery()
            let gpu = hw.gpu()
            let temps = sensors.temperatures()
            let fans = sensors.fans()
            Task { @MainActor [weak self] in
                self?.battery = battery
                self?.gpu = gpu
                self?.temps = temps
                self?.fans = fans
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

    public init(env: XicoEnvironment) {
        self.env = env
        _vm = StateObject(wrappedValue: HardwareViewModel(hw: env.hardware, sensors: env.sensors))
    }

    private let columns = [GridItem(.adaptive(minimum: 320), spacing: XSpacing.m)]

    public var body: some View {
        VStack(spacing: 0) {
            XHeaderBar(title: xLoc("硬件"), subtitle: xLoc("档案 · 健康 · 温度")) {
                HStack(spacing: XSpacing.xs) {
                    Circle().fill(XColor.success).frame(width: 7, height: 7)
                    Text("LIVE").font(.system(size: 10, weight: .bold)).tracking(1).foregroundStyle(XColor.success)
                }
            }
            ScrollView {
                VStack(spacing: XSpacing.m) {
                    heroCard
                    LazyVGrid(columns: columns, spacing: XSpacing.m) {
                        if vm.battery != nil { batteryCard }
                        storageCard
                        thermalCard
                        gpuCard
                        memoryCard
                        if !vm.displays.isEmpty { displayCard }
                        if !vm.temps.isEmpty { sensorsCard }
                    }
                }
                .padding(XSpacing.xl)
            }
        }
        .onAppear { vm.start() }
        .onDisappear { vm.stop() }
    }

    // MARK: Hero

    private var heroCard: some View {
        XCard {
            HStack(alignment: .center, spacing: XSpacing.xl) {
                XIconTile(systemImage: heroIcon, colors: XColor.brandGradientColors, size: 52)
                VStack(alignment: .leading, spacing: 4) {
                    Text(vm.profile?.marketingName ?? "Mac").xTitle().foregroundStyle(XColor.textPrimary)
                    Text(vm.profile.map { "\($0.chip) · \($0.memoryDescription)" } ?? "—")
                        .font(XFont.callout).foregroundStyle(XColor.textSecondary)
                }
                Spacer()
                HStack(spacing: XSpacing.xl) {
                    heroCol(xLoc("核心"), vm.profile?.coreDescription ?? "—")
                    heroCol(xLoc("系统"), vm.profile?.macOS ?? "—")
                    serialCol
                }
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

    private func heroCol(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(XFont.caption).foregroundStyle(XColor.textTertiary)
            Text(value).font(XFont.bodyEmphasis).foregroundStyle(XColor.textPrimary)
        }
        .frame(minWidth: 60, alignment: .leading)   // 与监视页 hero 一致的列对齐栅格
    }

    @State private var copied = false
    private var serialCol: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(vm.profile?.serialNumber ?? "", forType: .string)
            withAnimation { copied = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { withAnimation { copied = false } }
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(copied ? xLoc("已复制") : xLoc("序列号"))
                    .font(XFont.caption).foregroundStyle(copied ? XColor.success : XColor.textTertiary)
                HStack(spacing: 4) {
                    Text(vm.profile?.serialNumber ?? "—").font(XFont.bodyEmphasis).foregroundStyle(XColor.textPrimary)
                    Image(systemName: "doc.on.doc").font(.system(size: 9)).foregroundStyle(XColor.textTertiary)
                }
            }
        }
        .buttonStyle(.plain)
        .help(xLoc("点击复制序列号"))
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
        }
    }

    private func chargeState(_ b: BatteryHealth) -> String {
        if b.isCharging { return xLoc("充电中") }
        if b.externalConnected { return xLoc("已充满") }
        return xLoc("使用电池")
    }

    // MARK: 存储

    private var storageCard: some View {
        HardwareCard(icon: "internaldrive", title: xLoc("存储健康"),
                     iconColors: [XColor.auroraBlue, XColor.accentTeal]) {
            if vm.storage.isEmpty {
                Text(xLoc("正在读取…")).font(XFont.caption).foregroundStyle(XColor.textTertiary)
            }
            ForEach(vm.storage) { s in
                VStack(alignment: .leading, spacing: XSpacing.s) {
                    HStack {
                        Text(s.name).font(XFont.bodyEmphasis).foregroundStyle(XColor.textPrimary)
                        Spacer()
                        if s.isInternal {
                            XBadge(xLocF("SMART %@", s.smartStatus),
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
            if !vm.fans.isEmpty {
                Divider().overlay(XColor.hairline)
                ForEach(vm.fans) { fan in
                    HStack {
                        Image(systemName: "fanblades.fill").font(.system(size: 11)).foregroundStyle(XColor.accentTeal)
                        Text(xLocF("风扇 %d", fan.id + 1)).font(XFont.caption).foregroundStyle(XColor.textSecondary)
                        Spacer()
                        Text("\(fan.rpm) RPM").font(XFont.mono).foregroundStyle(XColor.textPrimary)
                    }
                }
            }
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
                let util = env.metricsEngine.snapshot?.gpuUsage ?? vm.gpu?.utilizationPercent.map { $0 / 100 }
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
            metricRow(xLoc("容量"), vm.profile?.memoryDescription ?? "—")
            if let snap = env.metricsEngine.snapshot {
                metricRow(xLoc("已使用"), "\(snap.memoryUsed.formattedMemory)（\(Int(snap.memoryUsedFraction * 100))%）")
                metricRow(xLoc("缓存文件"), snap.memoryCached.formattedMemory)
                if snap.swapTotal > 0 { metricRow(xLoc("交换区"), snap.swapUsed.formattedMemory) }
            }
        }
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
                        Spacer()
                        Text("\(d.refreshHz) Hz").font(XFont.mono).foregroundStyle(XColor.textSecondary)
                    }
                    metricRow(xLoc("原生分辨率"), d.resolutionText)
                    metricRow(xLoc("缩放"), d.scaledText)
                    if let inch = d.diagonalInches {
                        metricRow(xLoc("尺寸"), String(format: "%.1f 英寸", inch))
                    }
                }
                .padding(.vertical, 2)
            }
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
                VStack(alignment: .leading, spacing: 3) {
                    Text(name).font(.system(size: 10, weight: .semibold)).foregroundStyle(XColor.textTertiary)
                        .textCase(.uppercase).tracking(0.5)
                    // 用下标做 id：传感器名可能重复（如多个 "gas gauge battery"），\.id 会冲突
                    ForEach(Array(temps.enumerated()), id: \.offset) { _, t in
                        HStack {
                            Text(t.name).font(XFont.caption).foregroundStyle(XColor.textSecondary)
                                .lineLimit(1).truncationMode(.tail)
                            Spacer()
                            Text(String(format: "%.0f°C", t.celsius)).font(XFont.mono).foregroundStyle(tempColor(t.celsius))
                        }
                    }
                }
                .padding(.vertical, 1)
            }
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
                    XIconTile(systemImage: icon, colors: iconColors, size: 28)
                    Text(title).font(XFont.captionEmphasis).foregroundStyle(XColor.textSecondary)
                        .textCase(.uppercase).tracking(0.6)
                    Spacer()
                }
                content
            }
        }
    }
}
