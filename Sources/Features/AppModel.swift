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

    // 滚动历史（用于菜单栏折线图）
    @Published public var cpuHistory: [Double] = []
    @Published public var memHistory: [Double] = []
    @Published public var netDownHistory: [Double] = []
    @Published public var netUpHistory: [Double] = []
    // 菜单栏详情面板的进程榜
    @Published public var topByCPU: [ProcessUsage] = []
    @Published public var topByMemory: [ProcessUsage] = []
    private let processes = ProcessSampler()
    private let historyCap = 60
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
        push(&netDownHistory, s.netDownBytesPerSec)
        push(&netUpHistory, s.netUpBytesPerSec)
        let top = processes.sample(top: 4)
        topByCPU = top.byCPU
        topByMemory = top.byMemory

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
