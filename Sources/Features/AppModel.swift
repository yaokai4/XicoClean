import SwiftUI
import AppKit
import Domain
import Infrastructure
import DesignSystem

public extension Notification.Name {
    /// 清理完成后广播，便于各处刷新磁盘占用
    static let xicoDidClean = Notification.Name("xicoDidClean")
    /// 授权门禁触发后打开设置页
    static let xicoOpenSettings = Notification.Name("xicoOpenSettings")
    /// 展示会员/定价升级页
    static let xicoShowPricing = Notification.Name("xicoShowPricing")
}

/// 外观偏好：跟随系统 / 浅色 / 深色
public enum AppAppearance: String, CaseIterable, Identifiable, Sendable {
    case system, light, dark
    public var id: String { rawValue }
    public var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
    public var icon: String {
        switch self {
        case .system: return "circle.lefthalf.filled"
        case .light: return "sun.max.fill"
        case .dark: return "moon.fill"
        }
    }
}

/// 应用级状态：环境、当前选中模块、权限、实时指标。
@MainActor
public final class AppModel: ObservableObject {
    /// 共享实例：主窗口与菜单栏控制器（AppKit）共用同一份状态
    public static let shared = AppModel()

    public let env: XicoEnvironment

    @Published public var selection: ModuleID? = .smartScan
    @Published public var hasFullDiskAccess: Bool = false
    @Published public var permissionBannerDismissed: Bool = false {
        didSet { UserDefaults.standard.set(permissionBannerDismissed, forKey: "xico.fdaDismissed") }
    }
    @Published public var liveSnapshot: SystemSnapshot?
    @Published public var capacity: VolumeCapacity?
    @Published public var macInfo: MacInfo?
    @Published public var licenseStatus: LicenseStatus?
    @Published public var licenseBannerDismissed: Bool = false
    /// 在线激活进行中（供输入框/按钮显示「激活中…」并禁用重复点击）。
    @Published public var activating: Bool = false
    private let activationClient = LicenseActivationClient()

    // 滚动历史（用于菜单栏折线图）
    @Published public var cpuHistory: [Double] = []
    @Published public var memHistory: [Double] = []
    @Published public var gpuHistory: [Double] = []
    @Published public var netDownHistory: [Double] = []
    @Published public var netUpHistory: [Double] = []
    @Published public var diskReadHistory: [Double] = []
    @Published public var diskWriteHistory: [Double] = []
    // 菜单栏详情面板的进程榜
    @Published public var topByCPU: [ProcessUsage] = []
    @Published public var topByMemory: [ProcessUsage] = []
    // CPU 频率（性能核 / 能效核，MHz）——阻塞 ~90ms，后台隔次采样。
    @Published public var cpuFreqP: Double?
    @Published public var cpuFreqE: Double?
    // 本次会话网络统计（供 Sensei 式峰值 / 累计芯片）。累计 = 采样速率对时间的积分。
    @Published public var netDownPeak: Double = 0
    @Published public var netUpPeak: Double = 0
    @Published public var sessionDownBytes: Int64 = 0
    @Published public var sessionUpBytes: Int64 = 0
    // 网络接口清单（名称 / 类型 / IP / 速率）——后台隔次采样。
    @Published public var networkInterfaces: [NetworkInterfaceInfo] = []
    // 温度传感器 / 风扇 / 磁盘卷（菜单栏温度、磁盘专属面板的数据源）——后台隔次采样。
    @Published public var sensorTemps: [TempReading] = []
    @Published public var fans: [FanInfo] = []
    @Published public var storageVolumes: [StorageHealth] = []
    @Published public var gpuInfo: GPUInfo?
    private let sensorReader = SensorReader()
    private let hardwareProfiler = HardwareProfileService()
    private let processes = ProcessSampler()
    private let historyCap = 60
    /// 详情类采样（CPU 频率 / 网络接口）走后台队列，绝不阻塞菜单栏主线程。
    private let detailQueue = DispatchQueue(label: "app.xico.mb.detail", qos: .utility)
    /// 菜单栏专属网络采样器：与硬件页/监视页各自独立，避免共享实例互相污染接口速率基线。
    private let mbNetwork = NetworkInfoService()
    private var detailTick = 0
    private var lastMetricsAt: Date?
    // 阈值告警与历史落盘（随菜单栏采样一直运行，与 iStat 一致）
    @Published public var alertRules: [AlertRule] = []
    private let alertEvaluator = AlertEvaluator()
    private var historyFlushCounter = 0
    @Published public var appearance: AppAppearance = .system {
        didSet { UserDefaults.standard.set(appearance.rawValue, forKey: "xico.appearance") }
    }
    /// 当前主题 ID（极光/深海/暖阳/终端/品红/石墨）。切换即时应用到全局配色。
    @Published public var themeID: String = XTheme.aurora.id {
        didSet {
            XThemeStore.current = XTheme.byID(themeID)
            UserDefaults.standard.set(themeID, forKey: "xico.themeID")
        }
    }
    /// 界面语言（跟随系统 / 简体中文 / English / 日本語）。切换即时全局生效。
    @Published public var language: XLang = .system {
        didSet { XLocale.current = language }
    }
    @Published public var showOnboarding: Bool = false
    /// 是否展示会员/定价页（sheet）。
    @Published public var showPricing: Bool = false

    private var timer: Timer?

    /// 扫描会话缓存：按模块保留 ViewModel，切换侧栏再回来不丢扫描进度与结果（审计 P1）。
    private var moduleSessions: [ModuleID: ModuleSessionViewModel] = [:]

    /// 取（或创建并缓存）某模块的扫描会话。同一模块跨视图重建复用同一实例，状态得以保留。
    public func moduleSession(moduleID: ModuleID, intent: DeleteIntent, title: String) -> ModuleSessionViewModel {
        if let existing = moduleSessions[moduleID] { return existing }
        let e = env
        let vm = ModuleSessionViewModel(
            env: e, title: title, intent: intent,
            scanProvider: { handler in
                guard let scanner = e.scanner(for: moduleID) else { return [] }
                return [try await scanner.scan(progress: handler)]
            })
        if moduleID == .malware {
            vm.beforeClean = { items in await ThreatRemediation.bootoutUserAgents(items.map(\.url)) }
        }
        moduleSessions[moduleID] = vm
        return vm
    }

    private var smartScanVM: ModuleSessionViewModel?

    /// 智能扫描会话（单独缓存，含聚合协调器与失败汇总）。
    public var smartScanSession: ModuleSessionViewModel {
        if let vm = smartScanVM { return vm }
        let e = env
        let failures = FailureBox()
        let vm = ModuleSessionViewModel(
            env: e, title: xLoc("智能扫描"), intent: .trash,
            scanProvider: { handler in
                failures.reset()
                return try await e.smartScanCoordinator().scanAll(
                    progress: handler, onModuleFailure: { failures.add($0) })
            })
        vm.postScanWarning = { failures.summary() }
        smartScanVM = vm
        return vm
    }

    public init(env: XicoEnvironment = .live()) {
        self.env = env
        if let raw = UserDefaults.standard.string(forKey: "xico.appearance"),
           let a = AppAppearance(rawValue: raw) {
            appearance = a
        }
        if let tid = UserDefaults.standard.string(forKey: "xico.themeID") {
            themeID = tid
        }
        XThemeStore.current = XTheme.byID(themeID)   // 启动即应用已保存主题
        XLocale.load()                               // 载入已保存语言
        language = XLocale.current
        alertRules = env.alertRuleStore.load()
        permissionBannerDismissed = UserDefaults.standard.bool(forKey: "xico.fdaDismissed")
        showOnboarding = !UserDefaults.standard.bool(forKey: "xico.onboarded")
        if CommandLine.arguments.contains("--onboarding") { showOnboarding = true }
        if CommandLine.arguments.contains(where: { $0.hasPrefix("--open=") }) { showOnboarding = false }
        if let arg = CommandLine.arguments.first(where: { $0.hasPrefix("--open=") }) {
            selection = ModuleID(String(arg.dropFirst("--open=".count)))
        }
        if let arg = CommandLine.arguments.first(where: { $0.hasPrefix("--appearance=") }),
           let a = AppAppearance(rawValue: String(arg.dropFirst("--appearance=".count))) {
            appearance = a
        }
        refreshPermissions()
        refreshLicense()
        revalidateLicenseOnline()
        refreshMetrics()
        NotificationCenter.default.addObserver(forName: .xicoDidClean, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refreshMetrics() }
        }
        // 用户去系统设置授予「完全磁盘访问」/ 批准助手 / 导入许可证后回到 App，
        // 必须重新读状态——否则横幅一直挂到重启（审计 C1）。
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                self?.refreshPermissions()
                self?.refreshLicense()
            }
        }
    }

    public func refreshPermissions() {
        hasFullDiskAccess = env.permissions.hasFullDiskAccess()
    }

    public func refreshMetrics() {
        let s = env.liveMetrics.sample()
        liveSnapshot = s
        capacity = env.fs.volumeCapacity(for: FileManager.default.homeDirectoryForCurrentUser)
        if macInfo == nil { macInfo = env.liveMetrics.macInfo() }
        push(&cpuHistory, s.cpuUsage)
        push(&memHistory, s.memoryUsedFraction)
        push(&gpuHistory, s.gpuUsage ?? 0)
        push(&netDownHistory, s.netDownBytesPerSec)
        push(&netUpHistory, s.netUpBytesPerSec)
        push(&diskReadHistory, s.diskReadBytesPerSec)
        push(&diskWriteHistory, s.diskWriteBytesPerSec)
        // 本次会话峰值 / 累计（累计 = 速率 × 实测时间间隔的积分，来自真实采样，非编造）。
        let now0 = Date()
        netDownPeak = max(netDownPeak, s.netDownBytesPerSec)
        netUpPeak = max(netUpPeak, s.netUpBytesPerSec)
        if let last = lastMetricsAt {
            let dt = now0.timeIntervalSince(last)
            if dt > 0, dt < 30 {   // 跳过首帧与长睡眠后的异常间隔
                sessionDownBytes += Int64(s.netDownBytesPerSec * dt)
                sessionUpBytes += Int64(s.netUpBytesPerSec * dt)
            }
        }
        lastMetricsAt = now0
        let top = processes.sample(top: 4)
        topByCPU = top.byCPU
        topByMemory = top.byMemory

        // CPU 频率（阻塞 ~90ms）与网络接口清单：后台隔次采样，回主线程发布。
        detailTick &+= 1
        if detailTick % 3 == 1 {
            let sampler = env.liveMetrics
            let netInfo = mbNetwork
            let sensors = sensorReader
            let hw = hardwareProfiler
            detailQueue.async { [weak self] in
                let freq = sampler.cpuFrequency()
                let ifaces = netInfo.interfaces()
                // 温度/风扇/磁盘卷：温度与磁盘专属面板的数据源（首个 storageHealth 会触发一次
                // system_profiler，之后走缓存，稳定在毫秒级）。
                let temps = sensors.temperatures()
                let fanList = sensors.fans()
                let volumes = hw.storageHealth()
                let gpu = hw.gpu()
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if let f = freq { self.cpuFreqP = f.performance; self.cpuFreqE = f.efficiency }
                    self.networkInterfaces = ifaces
                    self.sensorTemps = temps
                    self.fans = fanList
                    self.storageVolumes = volumes
                    self.gpuInfo = gpu
                }
            }
        }

        // 历史落盘（1 分钟粒度）+ 阈值告警评估——随菜单栏采样常驻运行
        let now = Date()
        env.metricsHistory.record(MetricsHistoryPoint(
            t: now.timeIntervalSince1970, cpu: s.cpuUsage, mem: s.memoryUsedFraction,
            gpu: s.gpuUsage ?? 0, netDown: s.netDownBytesPerSec, netUp: s.netUpBytesPerSec), now: now)
        historyFlushCounter += 1
        if historyFlushCounter % 30 == 0 { env.metricsHistory.flush() }
        alertEvaluator.evaluate(rules: alertRules, now: now) { metric in
            switch metric {
            case .cpu: return s.cpuUsage
            case .memory: return s.memoryUsedFraction
            case .disk: return s.diskUsedFraction
            case .gpu: return s.gpuUsage
            case .battery: return s.batteryPercent.map { Double($0) / 100 }
            case .cpuTemp: return s.cpuTemp
            }
        }
    }

    public func saveAlertRules() { env.alertRuleStore.save(alertRules) }

    public func refreshLicense() {
        licenseStatus = env.license.status()
        if licenseStatus?.state.allowsCommercialUse == true {
            licenseBannerDismissed = false
        }
    }

    private static let lastOnlineCheckKey = "xico.license.lastOnlineCheck"
    /// 复验节流：3 天问一次服务器就够了。
    private static let onlineCheckInterval: TimeInterval = 72 * 3600

    /// 在线复验（吊销即失效）：已授权时每 ≥72h 向官网确认许可证状态。
    /// 「疑罪从无」——只有服务器明确回答 revoked/refunded 才清除本地许可；
    /// 断网/超时/服务器错误一律保持现状，离线用户永不受影响。
    public func revalidateLicenseOnline(force: Bool = false) {
        guard case .licensed = licenseStatus?.state ?? env.license.status().state,
              let licenseID = env.license.status().licenseID else { return }
        let defaults = UserDefaults.standard
        if !force,
           let last = defaults.object(forKey: Self.lastOnlineCheckKey) as? Date,
           Date().timeIntervalSince(last) < Self.onlineCheckInterval {
            return
        }
        Task { [weak self] in
            guard let self else { return }
            let verdict = await self.activationClient.validate(
                licenseId: licenseID,
                deviceId: DeviceIdentity.current(),
            )
            await MainActor.run {
                switch verdict {
                case .valid:
                    UserDefaults.standard.set(Date(), forKey: Self.lastOnlineCheckKey)
                case .revoked:
                    UserDefaults.standard.set(Date(), forKey: Self.lastOnlineCheckKey)
                    self.env.license.clearLicense()
                    self.refreshLicense()
                case .inconclusive:
                    break // 下次启动再试，不更新时间戳
                }
            }
        }
    }

    /// 在线激活：把激活码 + 本机标识发往官网校验，成功则安装返回的签名许可并解锁。
    /// 全流程走现有 Ed25519 信任根与门控，无需逐功能改动。
    @discardableResult
    public func activateLicense(key: String) async -> Result<Void, Error> {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return .failure(LicenseActivationError.invalidKey)
        }
        activating = true
        defer { activating = false }
        do {
            let data = try await activationClient.activate(
                key: trimmed,
                deviceId: DeviceIdentity.current(),
                deviceName: Host.current().localizedName,
            )
            _ = try env.license.installLicense(fromEnvelopeData: data)
            refreshLicense()
            return .success(())
        } catch {
            return .failure(error)
        }
    }

    private func push(_ arr: inout [Double], _ v: Double) {
        arr.append(v)
        if arr.count > historyCap { arr.removeFirst(arr.count - historyCap) }
    }

    public func startMetricsTimer() {
        timer?.invalidate()
        let stored = UserDefaults.standard.double(forKey: "xico.mb.interval")
        let interval = stored > 0 ? stored : 2.0   // 默认标准 2 秒
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshMetrics() }
        }
    }

    /// 应用新的刷新频率（设置页「更新频率」），立即重启菜单栏采样定时器。
    public func applyRefreshInterval(_ seconds: Double) {
        UserDefaults.standard.set(seconds, forKey: "xico.mb.interval")
        if timer != nil { startMetricsTimer() }
    }

    public func openFullDiskAccessSettings() {
        env.permissions.openFullDiskAccessSettings()
    }

    public func completeOnboarding() {
        UserDefaults.standard.set(true, forKey: "xico.onboarded")
        withAnimation(.spring(response: 0.45, dampingFraction: 0.85)) { showOnboarding = false }
        refreshPermissions()
    }

    var showPermissionBanner: Bool { !hasFullDiskAccess && !permissionBannerDismissed }
    var showLicenseBanner: Bool {
        guard let licenseStatus else { return false }
        return !licenseStatus.state.allowsCommercialUse && !licenseBannerDismissed
    }
}
