import Foundation
import Domain

/// 应用环境：组装所有依赖（依赖注入的根）。
public final class XicoEnvironment: @unchecked Sendable {
    public let fs: FileSystemService
    public let safety: SafetyEngine
    public let definitions: DefinitionsLibrary
    public let definitionsUpdater: DefinitionsUpdateService
    public let cleaningEngine: CleaningEngine
    public let metrics: MetricsSampler
    public let permissions: PermissionsManager
    public let diskTreeScanner: DiskTreeScanner
    public let uninstaller: UninstallerService
    public let optimization: OptimizationService
    public let maintenanceRunner: MaintenanceRunner
    public let liveMetrics: LiveMetricsSampler
    public let helper: HelperProxy
    public let history: HistoryStore
    public let license: LicenseService
    public let ignoreList: IgnoreListStore
    public let hardware: HardwareProfileService
    public let sensors: SensorReader
    public let network: NetworkInfoService
    public let metricsHistory: MetricsHistoryStore
    public let alertRuleStore: AlertRuleStore
    /// 统一实时指标引擎（监视页/硬件页共享，避免各自采样丢失差分状态）。
    @MainActor public private(set) lazy var metricsEngine = MetricsEngine()

    private let scanners: [ModuleID: ScannerModule]

    public init(
        fs: FileSystemService,
        safety: SafetyEngine,
        definitions: DefinitionsLibrary,
        definitionsUpdater: DefinitionsUpdateService? = nil,
        license: LicenseService? = nil
    ) {
        self.fs = fs
        self.safety = safety
        self.definitions = definitions
        self.definitionsUpdater = definitionsUpdater ?? DefinitionsUpdateService(
            bundled: definitions,
            endpoint: nil,
            trustedPublicKeys: [:]
        )
        let helper = HelperProxy()
        self.helper = helper
        self.cleaningEngine = CleaningEngine(safety: safety, fs: fs, privileged: helper)
        self.metrics = MetricsSampler(fs: fs)
        self.permissions = PermissionsManager()
        self.diskTreeScanner = DiskTreeScanner(fs: fs)
        self.uninstaller = UninstallerService(fs: fs, safety: safety)
        self.optimization = OptimizationService()
        self.maintenanceRunner = MaintenanceRunner()
        self.liveMetrics = LiveMetricsSampler(fs: fs)
        self.history = HistoryStore()
        self.license = license ?? LicenseService.live()
        self.ignoreList = IgnoreListStore()
        self.hardware = HardwareProfileService()
        self.sensors = SensorReader()
        self.network = NetworkInfoService()
        self.metricsHistory = MetricsHistoryStore()
        self.alertRuleStore = AlertRuleStore()

        var map: [ModuleID: ScannerModule] = [:]
        map[.largeFiles] = LargeFilesScanner(fs: fs, safety: safety)
        map[.trash] = TrashScanner(fs: fs)
        self.scanners = map   // 非定义驱动的扫描器（无需随规则库更新而变）
    }

    /// 当前生效的清理定义（优先已签名缓存，否则内置）——每次取，规则库在线更新后免重启即生效。
    private func currentDefinitions() -> [CleanupDefinition] {
        definitionsUpdater.currentLibrary().definitions
    }

    /// 默认线上环境
    public static func live() -> XicoEnvironment {
        let bundled = DefinitionsLibrary.bundled()
        let updater = DefinitionsUpdateService.live(bundled: bundled)
        let library = updater.currentLibrary()
        // 吊销名单随签名规则库下发（退款/盗版吊销的最低成本通道）
        let license = LicenseService.live(revokedLicenseIDs: Set(library.revokedLicenseIDs))
        return XicoEnvironment(
            fs: LocalFileSystemService(),
            safety: DefaultSafetyEngine(),
            definitions: library,
            definitionsUpdater: updater,
            license: license
        )
    }

    public func scanner(for id: ModuleID) -> ScannerModule? {
        // 定义驱动的扫描器每次从当前规则库现构建（构造成本极低），使在线更新免重启生效。
        switch id {
        case .systemJunk: return SystemJunkScanner(definitions: currentDefinitions(), fs: fs, safety: safety)
        case .privacy:    return PrivacyScanner(definitions: currentDefinitions(), fs: fs, safety: safety)
        case .malware:    return ThreatScanner(fs: fs, safety: safety,
                                               extraSignatures: definitionsUpdater.currentLibrary().threatSignatures)
        default:          return scanners[id]
        }
    }

    public func duplicatesScanner(root: URL) -> DuplicatesScanner {
        DuplicatesScanner(fs: fs, safety: safety, root: root)
    }

    public func similarImagesScanner() -> SimilarImagesScanner {
        SimilarImagesScanner(fs: fs, safety: safety)
    }

    public func appUpdateService() -> AppUpdateService {
        AppUpdateService(uninstaller: uninstaller)
    }

    public func shredderService() -> ShredderService {
        ShredderService(safety: safety)
    }

    /// 智能扫描聚合：系统垃圾 + 隐私 + 深度全盘走查——覆盖用户期望「一次扫全」的常见垃圾源。
    /// 均为定义/位置驱动或逐文件走查、递归精确计尺寸。仍不含全盘大文件（遍历整盘耗时长，单列为
    /// 独立模块，避免把「清理垃圾」拖成「全盘体检」）。
    ///
    /// **刻意排除废纸篓（对抗复核 P1 修复）**：废纸篓里的文件已被移入废纸篓，其占用是「已在回收站、
    /// 等待清空」的状态。若智能扫描把它计入可释放并以 `.trash` intent「清理」，只会把已在废纸篓的
    /// 文件再移动一次（无法真正清空、也不释放空间），却把这部分字节虚计入「已释放」总量。清空废纸篓
    /// 释放空间是独立「废纸篓」模块的职责——其正确地走 `.permanent`。故此处**不**聚合 TrashScanner，
    /// 智能扫描的可释放总量因此不再包含废纸篓字节。
    public func smartScanCoordinator() -> ScanCoordinator {
        // 定点规则（系统垃圾/隐私）+ 深度全盘走查（逐文件检测残留安装包与中断下载）
        // + 孤儿残留引擎（P4：五路径 bundle-id 比对、按原 App 分组）——
        // 智能扫描既有「知道去哪找」的精准，也有「每个文件都看过」的全面。废纸篓不在此列（见上）。
        // 系统垃圾扫描器关掉内联浅扫残留（includeLeftovers: false），残留全权交给 OrphanScanner，
        // 避免同一路径在两个分组里打架；独立「系统垃圾」页仍保留浅扫（scanner(for:) 默认 true）。
        var modules: [ScannerModule] = [
            SystemJunkScanner(definitions: currentDefinitions(), fs: fs, safety: safety, includeLeftovers: false),
        ]
        if let privacy = scanner(for: .privacy) { modules.append(privacy) }
        modules.append(DeepScanner(fs: fs, safety: safety))
        modules.append(OrphanScanner(fs: fs, safety: safety))
        return ScanCoordinator(modules: modules)
    }
}

/// 侧边栏模块目录（含尚未实现的占位模块）
public enum ModuleCatalog {
    public static let all: [ModuleMetadata] = [
        // —— 清理：只留两个入口，其余清理面全部并入智能扫描中枢（docs/14 P0）。
        ModuleMetadata(id: .smartScan, title: "智能扫描", subtitle: "一键体检与清理", systemImage: "sparkles", category: .cleanup),
        ModuleMetadata(id: .systemJunk, title: "系统垃圾", subtitle: "缓存 / 日志 / 开发者残余", systemImage: "trash", category: .cleanup),

        // —— 应用：空间透镜迁入（用户拍板，docs/14 §3.1）。
        ModuleMetadata(id: .uninstaller, title: "卸载器", subtitle: "彻底卸载含残留", systemImage: "xmark.bin", category: .applications),
        ModuleMetadata(id: .appUpdater, title: "应用更新", subtitle: "检查可更新的应用", systemImage: "arrow.triangle.2.circlepath", category: .applications),
        ModuleMetadata(id: .spaceLens, title: "空间透镜", subtitle: "可视化磁盘占用", systemImage: "circle.hexagongrid.fill", category: .applications),

        // —— 性能与安全：状态栏（原设置页菜单栏卡）置顶。
        ModuleMetadata(id: .menuBar, title: "状态栏", subtitle: "菜单栏样式、排序与刷新", systemImage: "menubar.rectangle", category: .performance),
        ModuleMetadata(id: .optimization, title: "优化", subtitle: "登录项 / 高耗进程", systemImage: "speedometer", category: .performance),
        ModuleMetadata(id: .maintenance, title: "维护", subtitle: "缓存 / 索引 / 重启", systemImage: "wrench.and.screwdriver", category: .performance),
        ModuleMetadata(id: .diskSpeed, title: "磁盘测速", subtitle: "顺序读写基准", systemImage: "gauge.with.needle", category: .performance),
        ModuleMetadata(id: .hardware, title: "硬件", subtitle: "档案 · 健康 · 温度", systemImage: "cpu", category: .performance),
        ModuleMetadata(id: .monitor, title: "系统监视", subtitle: "CPU / 内存 / 网络 / GPU 实时", systemImage: "waveform.path.ecg", category: .performance),

        // —— 隐藏模块：并入智能扫描中枢，侧边栏不展示（sidebar: false）。
        // 路由（RootView DetailView）与 --open= 直达保留——与 .privacy 先例一致；
        // 元数据保留供 ModuleScanView / 中枢下钻按 ID 查询 title/icon。
        ModuleMetadata(id: .trash, title: "废纸篓", subtitle: "清空释放空间", systemImage: "trash.circle", category: .cleanup, sidebar: false),
        ModuleMetadata(id: .largeFiles, title: "大文件与旧文件", subtitle: "找出大块头", systemImage: "doc.viewfinder", category: .filesSpace, sidebar: false),
        ModuleMetadata(id: .duplicates, title: "重复文件", subtitle: "内容级查重", systemImage: "doc.on.doc", category: .filesSpace, sidebar: false),
        ModuleMetadata(id: .similarImages, title: "相似图片", subtitle: "感知查重 · 保留最佳", systemImage: "photo.on.rectangle.angled", category: .filesSpace, sidebar: false),
        ModuleMetadata(id: .shredder, title: "文件粉碎", subtitle: "覆写后彻底删除", systemImage: "flame", category: .filesSpace, sidebar: false),
        ModuleMetadata(id: .malware, title: "威胁防护", subtitle: "签名校验 / 可疑启动项", systemImage: "shield.lefthalf.filled", category: .performance, sidebar: false)
        // 隐私（浏览器数据）已并入智能扫描一键流程，不再单列侧边栏入口。
    ]

    public static func grouped() -> [(ModuleCategory, [ModuleMetadata])] {
        // 只分组侧边栏可见模块；空分组整组丢弃（否则渲染出无子项的孤儿组头——文件与空间已撤组）。
        ModuleCategory.allCases
            .map { cat in (cat, all.filter { $0.category == cat && $0.sidebar }) }
            .filter { !$0.1.isEmpty }
    }
}
