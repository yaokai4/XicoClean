import SwiftUI
import AppKit
import Domain
import Infrastructure
import DesignSystem

public extension Notification.Name {
    /// 清理完成后广播，便于各处刷新磁盘占用
    static let xicoDidClean = Notification.Name("xicoDidClean")
    /// 授权状态变化后广播（激活/移除/在线复验/刷新）：各会话据此重算「购买后清理」闸门缓存，
    /// 避免刚激活的用户仍被卡在「购买后清理」CTA（审计 P2 ModuleSessionViewModel:109）。
    static let xicoLicenseChanged = Notification.Name("xicoLicenseChanged")
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
    /// 无障碍标签（图标按钮无文字，VoiceOver 需可读名）。
    public var label: String {
        switch self {
        case .system: return "跟随系统"
        case .light: return "浅色"
        case .dark: return "深色"
        }
    }
}

/// 高频实时指标源（菜单栏折线图 / 详情面板专用）。
///
/// 从 AppModel 拆出的独立 ObservableObject：每秒采样只触发本对象的 objectWillChange，
/// 而侧栏 / 主壳只观察 AppModel、不观察本对象，因此高频采样不再让整棵视图树每 tick 失效
/// （审计 P2「35 个 @Published 每 tick 全量刷新」）。AppModel 仍以转发计算属性对外暴露这些字段，
/// 兼容既有读写方（如离屏图标渲染），无需改动非本工作流文件。
@MainActor
public final class MetricsFeed: ObservableObject {
    // 滚动历史（用于菜单栏折线图）
    @Published public var cpuHistory: [Double] = []
    // 用户/系统拆分历史（P8：CPU 面板堆叠条的数据源，与 cpuHistory 同节拍同容量）
    @Published public var cpuUserHistory: [Double] = []
    @Published public var cpuSysHistory: [Double] = []
    @Published public var memHistory: [Double] = []
    @Published public var gpuHistory: [Double] = []
    @Published public var netDownHistory: [Double] = []
    @Published public var netUpHistory: [Double] = []
    @Published public var diskReadHistory: [Double] = []
    @Published public var diskWriteHistory: [Double] = []
    // 菜单栏详情面板的进程榜
    @Published public var topByCPU: [ProcessUsage] = []
    @Published public var topByMemory: [ProcessUsage] = []
    // CPU 频率（性能核 / 能效核，MHz）
    @Published public var cpuFreqP: Double?
    @Published public var cpuFreqE: Double?
    // 本次会话网络统计
    @Published public var netDownPeak: Double = 0
    @Published public var netUpPeak: Double = 0
    @Published public var sessionDownBytes: Int64 = 0
    @Published public var sessionUpBytes: Int64 = 0
    // 网络接口清单
    @Published public var networkInterfaces: [NetworkInterfaceInfo] = []
    // 温度传感器 / 风扇
    @Published public var sensorTemps: [TempReading] = []
    @Published public var fans: [FanInfo] = []
    @Published public var gpuInfo: GPUInfo?
    // 每 tick 变动的整机快照 / 磁盘容量 / 磁盘卷。归入本对象后，高频采样只触发本 feed 的
    // objectWillChange，AppModel 不再每 2s 全量失效（审计 P2「MetricsFeed 拆分未止住 AppModel 每 tick 重发布」）。
    // 菜单栏图标绘制订阅本对象的 $liveSnapshot；主壳/侧栏只观察 AppModel，故不再随采样重排。
    @Published public var liveSnapshot: SystemSnapshot?
    @Published public var capacity: VolumeCapacity?
    @Published public var storageVolumes: [StorageHealth] = []
    /// 分层历史（实时 / 10s 桶 / 60s 桶）——菜单栏面板折线的三挡时间窗数据源（P3·M4）。
    @Published public var rings = MetricRings()

    public init() {}
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
    @Published public var macInfo: MacInfo?
    @Published public var licenseStatus: LicenseStatus?
    @Published public var licenseBannerDismissed: Bool = false
    /// 在线激活进行中（供输入框/按钮显示「激活中…」并禁用重复点击）。
    @Published public var activating: Bool = false
    private let activationClient = LicenseActivationClient()

    /// 高频指标源（滚动历史 / 进程榜 / 频率 / 会话统计 / 接口 / 传感器）。
    /// 这些字段每 tick 变动，独立成对象后不再牵动 AppModel 的 objectWillChange（审计 P2）。
    public let liveMetricsFeed = MetricsFeed()
    // 以下转发计算属性把 feed 字段以旧路径对外暴露，兼容既有读写方（如离屏图标渲染 IconRender、
    // 菜单栏图标绘制 MenuBarController），无需改动非本工作流文件。
    // 注意：`$liveSnapshot` 投影发布者现改由 feed 暴露——菜单栏订阅方须改订阅
    // `model.liveMetricsFeed.$liveSnapshot`（见 cross_file_notes）。这里的普通读取转发保持源码兼容。
    public var liveSnapshot: SystemSnapshot? { get { liveMetricsFeed.liveSnapshot } set { liveMetricsFeed.liveSnapshot = newValue } }
    public var capacity: VolumeCapacity? { get { liveMetricsFeed.capacity } set { liveMetricsFeed.capacity = newValue } }
    public var storageVolumes: [StorageHealth] { get { liveMetricsFeed.storageVolumes } set { liveMetricsFeed.storageVolumes = newValue } }
    public var cpuHistory: [Double] { get { liveMetricsFeed.cpuHistory } set { liveMetricsFeed.cpuHistory = newValue } }
    public var memHistory: [Double] { get { liveMetricsFeed.memHistory } set { liveMetricsFeed.memHistory = newValue } }
    public var gpuHistory: [Double] { get { liveMetricsFeed.gpuHistory } set { liveMetricsFeed.gpuHistory = newValue } }
    public var netDownHistory: [Double] { get { liveMetricsFeed.netDownHistory } set { liveMetricsFeed.netDownHistory = newValue } }
    public var netUpHistory: [Double] { get { liveMetricsFeed.netUpHistory } set { liveMetricsFeed.netUpHistory = newValue } }
    public var diskReadHistory: [Double] { get { liveMetricsFeed.diskReadHistory } set { liveMetricsFeed.diskReadHistory = newValue } }
    public var diskWriteHistory: [Double] { get { liveMetricsFeed.diskWriteHistory } set { liveMetricsFeed.diskWriteHistory = newValue } }
    public var topByCPU: [ProcessUsage] { get { liveMetricsFeed.topByCPU } set { liveMetricsFeed.topByCPU = newValue } }
    public var topByMemory: [ProcessUsage] { get { liveMetricsFeed.topByMemory } set { liveMetricsFeed.topByMemory = newValue } }
    public var cpuFreqP: Double? { get { liveMetricsFeed.cpuFreqP } set { liveMetricsFeed.cpuFreqP = newValue } }
    public var cpuFreqE: Double? { get { liveMetricsFeed.cpuFreqE } set { liveMetricsFeed.cpuFreqE = newValue } }
    public var netDownPeak: Double { get { liveMetricsFeed.netDownPeak } set { liveMetricsFeed.netDownPeak = newValue } }
    public var netUpPeak: Double { get { liveMetricsFeed.netUpPeak } set { liveMetricsFeed.netUpPeak = newValue } }
    public var sessionDownBytes: Int64 { get { liveMetricsFeed.sessionDownBytes } set { liveMetricsFeed.sessionDownBytes = newValue } }
    public var sessionUpBytes: Int64 { get { liveMetricsFeed.sessionUpBytes } set { liveMetricsFeed.sessionUpBytes = newValue } }
    public var networkInterfaces: [NetworkInterfaceInfo] { get { liveMetricsFeed.networkInterfaces } set { liveMetricsFeed.networkInterfaces = newValue } }
    public var sensorTemps: [TempReading] { get { liveMetricsFeed.sensorTemps } set { liveMetricsFeed.sensorTemps = newValue } }
    public var fans: [FanInfo] { get { liveMetricsFeed.fans } set { liveMetricsFeed.fans = newValue } }
    public var gpuInfo: GPUInfo? { get { liveMetricsFeed.gpuInfo } set { liveMetricsFeed.gpuInfo = newValue } }
    private let sensorReader = SensorReader()
    private let hardwareProfiler = HardwareProfileService()
    private let processes = ProcessSampler()
    private let historyCap = 60
    /// 菜单栏采样统一走后台队列，绝不在主线程做全系统 + 全进程 rusage 采样（审计 P1）。
    private let sampleQueue = DispatchQueue(label: "app.xico.mb.sample", qos: .utility)
    /// 单飞门闩：上一帧采样未回主线程前不再排下一帧，避免长睡眠唤醒后堆积。
    private var isSampling = false
    /// 是否有「详情消费者」可见——菜单栏弹窗/详情面板已打开。由 MenuBarController 在 popover
    /// 打开/关闭时置位（见 cross_file_notes）。仅菜单栏图标常驻、无弹窗时为 false，届时跳过
    /// 全进程枚举 + 传感器/风扇/磁盘健康/频率等重采样，只采图标折线所需的 cpu/mem/net/gpu（审计 P2 常驻满载）。
    public var metricsDetailConsumerVisible: Bool = false
    /// 综合可见性：详情弹窗打开，或主窗口在前台可见（监视/详情页需要完整采样，不回归体验）。
    private var hasVisibleMetricsConsumer: Bool {
        Self.detailConsumerVisible(
            consumerVisible: metricsDetailConsumerVisible,
            hasVisibleMainWindow: NSApp.windows.contains {
                $0.isVisible && $0.canBecomeMain && $0.occlusionState.contains(.visible)
            })
    }

    /// 详情采样可见性的纯判定（无副作用，供回归测试直接调用，无需构造整个 AppModel）。
    /// 判据：菜单栏详情弹窗已打开(`consumerVisible`，由 MenuBarController 在 show/close 置位) **或** 主窗口前台可见。
    /// 回归点（审计 P1）：弹窗打开时即便无可见主窗口也必须为 true，否则温度/风扇/GPU 等详情停采。
    nonisolated static func detailConsumerVisible(consumerVisible: Bool, hasVisibleMainWindow: Bool) -> Bool {
        consumerVisible || hasVisibleMainWindow
    }
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
            XThemeStore.shared.current = XTheme.byID(themeID)
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

    // MARK: 清理器会话缓存（切换侧栏再回来不丢结果，与 moduleSession 同策略；审计 P2 RootView:249）

    /// 「重复文件」扫描位置（DuplicatesView 可更换文件夹）——缓存于此，跨 tab 保留所选目录与扫描结果。
    /// 内部可见即可（仅 Features 内的 DuplicatesView 消费；PathBox 为模块内部类型，不能对外 public）。
    let duplicatesFolderBox = PathBox(
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads"))
    private var duplicatesVM: ModuleSessionViewModel?
    /// 缓存的「重复文件」扫描会话：scanProvider 读取当前 duplicatesFolderBox.url，换文件夹后再扫即用新目录。
    var duplicatesSession: ModuleSessionViewModel {
        if let vm = duplicatesVM { return vm }
        let e = env
        let box = duplicatesFolderBox
        let vm = ModuleSessionViewModel(
            env: e, title: xLoc("重复文件"), intent: .trash,
            scanProvider: { handler in
                let result = await e.duplicatesScanner(root: box.url).scan(progress: handler)
                return [result]
            })
        duplicatesVM = vm
        return vm
    }

    private var spaceLensVM: SpaceLensModel?
    /// 缓存的「空间透镜」全盘扫描模型（一次全盘深扫可达数分钟，切走再回来必须保留结果）。
    var spaceLensModel: SpaceLensModel {
        if let m = spaceLensVM { return m }
        let m = SpaceLensModel(env: env)
        spaceLensVM = m
        return m
    }

    private var uninstallerVM: UninstallerModel?
    /// 缓存的「卸载器」模型（已加载的应用清单与所选残留项跨 tab 保留）。
    var uninstallerModel: UninstallerModel {
        if let m = uninstallerVM { return m }
        let m = UninstallerModel(env: env)
        uninstallerVM = m
        return m
    }

    private var similarImagesVM: ModuleSessionViewModel?
    /// 缓存的「相似图片」扫描会话（Vision 感知比对较慢，切走再回来必须保留结果；审计 P2，与其它扫描模块一致）。
    var similarImagesSession: ModuleSessionViewModel {
        if let vm = similarImagesVM { return vm }
        let e = env
        let vm = ModuleSessionViewModel(
            env: e, title: xLoc("相似图片"), intent: .trash,
            scanProvider: { handler in
                let result = await e.similarImagesScanner().scan(progress: handler)
                return [result]
            })
        similarImagesVM = vm
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
        XThemeStore.shared.current = XTheme.byID(themeID)   // 启动即应用已保存主题
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
        // 菜单栏长驻进程可能数周不重启——每 6h 唤醒一次复验入口
        // （内部仍按 72h 节流，绝大多数唤醒直接返回，不产生网络请求）。
        Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.revalidateLicenseOnline() }
        }
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
                self?.revalidateLicenseOnline()
            }
        }
    }

    public func refreshPermissions() {
        hasFullDiskAccess = env.permissions.hasFullDiskAccess()
    }

    /// 菜单栏采样入口。全系统 + 全进程 rusage 采样在后台队列执行，仅回主线程发布快照（审计 P1）。
    public func refreshMetrics() {
        guard !isSampling else { return }   // 单飞：上一帧未落地前不排下一帧
        // 冷启动首帧不再同步跑重快照（会阻塞主线程做全传感器/IORegistry/sysctl 采样，审计 P3）——
        // 首帧交给下方后台队列异步填充，界面短暂显示占位（XSpinner）后即刷新。
        isSampling = true
        detailTick &+= 1
        // 菜单栏图标常驻但无弹窗/主窗口时（steady state）：只采图标折线所需的 cpu/mem/net/gpu 快照，
        // 跳过全进程枚举 + 传感器/风扇/磁盘健康/频率等昂贵详情采样（审计 P2）。有消费者可见时全量采样。
        let consumer = hasVisibleMetricsConsumer
        // P3·M9：有消费者时详情**每 tick 都采**（此前 %3 → 面板打开后温度/风扇 ~6s 才刷一轮，
        // 实时感明显弱于 iStat）。~90ms 频率阻塞发生在后台 sampleQueue，主线程零成本；
        // 无消费者时依旧完全跳过（稳态省电路径不变）。
        let wantDetail = consumer
        let needMacInfo = (macInfo == nil)
        let env = self.env
        let procSampler = processes
        let netInfo = mbNetwork
        let sensors = sensorReader
        let hw = hardwareProfiler
        let home = FileManager.default.homeDirectoryForCurrentUser
        sampleQueue.async {
            // steady state（无弹窗/主窗口 → consumer=false）：跳过 GPU/温度/风扇/电池等昂贵详情读取，
            // 只采图标折线所需的 cpu/mem/net。此前漏传该标志导致优化形同虚设、常驻空耗电（审计 P1）。
            let snap = env.liveMetrics.sample(consumerVisible: consumer)
            let cap = env.fs.volumeCapacity(for: home)
            let info = needMacInfo ? env.liveMetrics.macInfo() : nil
            // 进程榜仅在有可见消费者时才做全进程 rusage 枚举（proc_listallpids）；否则保留上帧不刷新。
            let top = consumer ? procSampler.sample(top: 4) : nil
            var detail: MetricsDetail?
            if wantDetail {
                // 温度/风扇/磁盘卷：温度与磁盘专属面板的数据源（首个 storageHealth 会触发一次
                // system_profiler，之后走缓存，稳定在毫秒级）。
                detail = MetricsDetail(
                    freq: env.liveMetrics.cpuFrequency(),
                    interfaces: netInfo.interfaces(),
                    temps: sensors.temperatures(),
                    fans: sensors.fans(),
                    volumes: hw.storageHealth(),
                    gpu: hw.gpu())
            }
            let sample = MetricsSample(snapshot: snap, capacity: cap, macInfo: info,
                                       topByCPU: top?.byCPU, topByMemory: top?.byMemory, detail: detail)
            Task { @MainActor [weak self] in self?.applyMetrics(sample) }
        }
    }

    /// 回主线程发布采样结果：只在此处写 @Published，保证主线程无采样开销。
    private func applyMetrics(_ sample: MetricsSample) {
        defer { isSampling = false }
        let s = sample.snapshot
        let feed = liveMetricsFeed
        feed.liveSnapshot = s
        feed.capacity = sample.capacity
        if let info = sample.macInfo { macInfo = info }
        push(&feed.cpuHistory, s.cpuUsage)
        push(&feed.cpuUserHistory, s.cpuUser)
        push(&feed.cpuSysHistory, s.cpuSystem)
        push(&feed.memHistory, s.memoryUsedFraction)
        push(&feed.gpuHistory, s.gpuUsage ?? 0)
        push(&feed.netDownHistory, s.netDownBytesPerSec)
        push(&feed.netUpHistory, s.netUpBytesPerSec)
        push(&feed.diskReadHistory, s.diskReadBytesPerSec)
        push(&feed.diskWriteHistory, s.diskWriteBytesPerSec)
        // 分层历史（实时/15 分/1 时 三挡时间窗，P3·M4）——面板折线的数据源。
        feed.rings.push(cpu: s.cpuUsage, memory: s.memoryUsedFraction, gpu: s.gpuUsage ?? 0,
                        netDown: s.netDownBytesPerSec, netUp: s.netUpBytesPerSec)
        // 本次会话峰值 / 累计（累计 = 速率 × 实测时间间隔的积分，来自真实采样，非编造）。
        let now0 = Date()
        feed.netDownPeak = max(feed.netDownPeak, s.netDownBytesPerSec)
        feed.netUpPeak = max(feed.netUpPeak, s.netUpBytesPerSec)
        if let last = lastMetricsAt {
            let dt = now0.timeIntervalSince(last)
            if dt > 0, dt < 30 {   // 跳过首帧与长睡眠后的异常间隔
                feed.sessionDownBytes += Int64(s.netDownBytesPerSec * dt)
                feed.sessionUpBytes += Int64(s.netUpBytesPerSec * dt)
            }
        }
        lastMetricsAt = now0
        // 进程榜仅在有消费者时采到（否则为 nil）——保留上帧，避免弹窗打开瞬间空表。
        if let byCPU = sample.topByCPU { feed.topByCPU = byCPU }
        if let byMemory = sample.topByMemory { feed.topByMemory = byMemory }
        if let d = sample.detail {
            if let f = d.freq { feed.cpuFreqP = f.performance; feed.cpuFreqE = f.efficiency }
            feed.networkInterfaces = d.interfaces
            feed.sensorTemps = d.temps
            feed.fans = d.fans
            feed.storageVolumes = d.volumes
            feed.gpuInfo = d.gpu
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
        // 广播授权变化：各会话重算购买闸门缓存（刚激活即可清理，无需切页重建）。
        NotificationCenter.default.post(name: .xicoLicenseChanged, object: nil)
    }

    private static let lastOnlineCheckKey = "xico.license.lastOnlineCheck"
    /// 复验节流：每半个月（15 天）向官网同步一次授权状态即可——足够及时收敛吊销/退款，
    /// 又不打扰离线用户。断网/超时一律保持现状，绝不因为一次联网失败影响正版。
    private static let onlineCheckInterval: TimeInterval = 15 * 86_400

    /// 在线复验（吊销即失效）：已授权 **或复验逾期(lapsed)** 时每 ≥72h 向官网确认许可证状态。
    /// 「疑罪从无」——只有服务器明确回答 revoked/refunded 才清除本地许可；
    /// 断网/超时/服务器错误一律保持现状，离线用户永不受影响。
    ///
    /// 自愈（审计 P2「flagged→lapsed 死胡同」）：曾被服务器标记(flagged)、离线超过宽限期而被
    /// 降级为受限(.invalid) 的许可，其 `status().licenseID` 仍非空。放行让本方法在 lapsed 态也能联网复验；
    /// 一次签名 active 回执会由 LicenseActivationClient 清除本地 flag，随后 refreshLicense() 即恢复 .licensed。
    public func revalidateLicenseOnline(force: Bool = false) {
        // 有 licenseID ⟺ 本地存在一份可解出 licenseID 的许可（.licensed 或复验逾期的受限态）；
        // 试用/过期/信封损坏等场景 licenseID 为 nil，直接跳过。故此判据同时覆盖「已授权」与「lapsed」两种可复验状态。
        guard let licenseID = env.license.status().licenseID else { return }
        let defaults = UserDefaults.standard
        if !force, let last = defaults.object(forKey: Self.lastOnlineCheckKey) as? Date {
            let now = Date()
            // 时钟回拨保护（审计 P3）：now < last 说明系统时钟被往回调，不能借此把复验无限期后延——强制复验。
            if now >= last, now.timeIntervalSince(last) < Self.onlineCheckInterval {
                return
            }
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
                    // 签名 active：flag 已由 validate() 清除，此处刷新状态即自愈回 .licensed（lapsed 解除）。
                    self.refreshLicense()
                case .revoked:
                    UserDefaults.standard.set(Date(), forKey: Self.lastOnlineCheckKey)
                    // 记名吊销：把该许可证 ID 落入本地持久吊销库，重新导入同一份副本也无法复活（审计 P2）。
                    // 契约：LicenseActivationClient 仅在服务器回执带有效 Ed25519 签名时才返回 .revoked（见 cross_file_notes），
                    // 未签名/签名无效一律降级为 .inconclusive，绝不永久 brick 正版许可。
                    self.env.license.recordRevoked(licenseID)
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
                // 不再上送 Host.current().localizedName（常含机主真名）——改送中性设备标签（审计 P3 隐私）。
                deviceName: Self.neutralDeviceLabel(),
            )
            let installed = try env.license.installLicense(fromEnvelopeData: data)
            // 导入即复核吊销库：一份被吊销/退款的副本即便通过签名，也拒绝解锁（审计 P2）。
            if let id = installed.licenseID, env.license.isRevoked(id) {
                env.license.clearLicense()
                return .failure(LicenseActivationError.revoked)
            }
            refreshLicense()
            return .success(())
        } catch {
            return .failure(error)
        }
    }

    /// 中性设备标签：机型标识 + 设备标识的确定性短哈希。不含机主姓名等 PII，仅便于后台辨识台数。
    static func neutralDeviceLabel() -> String {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        var model = "Mac"
        if size > 0 {
            var buf = [CChar](repeating: 0, count: size)
            if sysctlbyname("hw.model", &buf, &size, nil, 0) == 0 { model = String(cString: buf) }
        }
        // FNV-1a：确定性（同机每次一致），不可逆，仅取低 24 位作短后缀。
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in DeviceIdentity.current().utf8 { hash = (hash ^ UInt64(byte)) &* 0x00000100000001B3 }
        return String(format: "%@-%06x", model, UInt32(truncatingIfNeeded: hash) & 0xFFFFFF)
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
        withAnimation(XMotion.settle) { showOnboarding = false }
        refreshPermissions()
    }

    var showPermissionBanner: Bool { !hasFullDiskAccess && !permissionBannerDismissed }
    var showLicenseBanner: Bool {
        guard let licenseStatus else { return false }
        return !licenseStatus.state.allowsCommercialUse && !licenseBannerDismissed
    }
}

/// 后台采样一帧的结果（Sendable，跨队列/actor 边界安全）。仅在主线程的 applyMetrics 里发布。
private struct MetricsSample: Sendable {
    let snapshot: SystemSnapshot
    let capacity: VolumeCapacity?
    let macInfo: MacInfo?
    /// nil = 本帧无可见消费者，未做全进程枚举（保留上帧进程榜）。
    let topByCPU: [ProcessUsage]?
    let topByMemory: [ProcessUsage]?
    let detail: MetricsDetail?
}

/// 详情类采样（隔次进行）：频率 / 接口 / 传感器 / 磁盘卷 / GPU。
private struct MetricsDetail: Sendable {
    let freq: (performance: Double, efficiency: Double)?
    let interfaces: [NetworkInterfaceInfo]
    let temps: [TempReading]
    let fans: [FanInfo]
    let volumes: [StorageHealth]
    let gpu: GPUInfo?
}
