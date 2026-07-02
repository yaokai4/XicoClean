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

    public func isImplemented(_ id: ModuleID) -> Bool {
        let extra: Set<ModuleID> = [.smartScan, .spaceLens, .duplicates, .similarImages,
                                    .uninstaller, .appUpdater, .shredder, .optimization, .maintenance, .monitor]
        return scanner(for: id) != nil || extra.contains(id)
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

    /// 智能扫描聚合：系统垃圾 + 隐私（均为定义驱动、快速）。
    /// 不含全盘大文件（耗时长，单列为模块）与废纸篓（彻底删除需单独确认）。
    public func smartScanCoordinator() -> ScanCoordinator {
        let modules = [scanner(for: .systemJunk), scanner(for: .privacy)].compactMap { $0 }
        return ScanCoordinator(modules: modules)
    }
}

/// 侧边栏模块目录（含尚未实现的占位模块）
public enum ModuleCatalog {
    public static let all: [ModuleMetadata] = [
        ModuleMetadata(id: .smartScan, title: "智能扫描", subtitle: "一键体检与清理", systemImage: "sparkles", category: .cleanup),
        ModuleMetadata(id: .systemJunk, title: "系统垃圾", subtitle: "缓存 / 日志 / 开发者残余", systemImage: "trash", category: .cleanup),
        ModuleMetadata(id: .trash, title: "废纸篓", subtitle: "清空释放空间", systemImage: "trash.circle", category: .cleanup),

        ModuleMetadata(id: .spaceLens, title: "空间透镜", subtitle: "可视化磁盘占用", systemImage: "circle.hexagongrid.fill", category: .filesSpace),
        ModuleMetadata(id: .largeFiles, title: "大文件与旧文件", subtitle: "找出大块头", systemImage: "doc.viewfinder", category: .filesSpace),
        ModuleMetadata(id: .duplicates, title: "重复文件", subtitle: "内容级查重", systemImage: "doc.on.doc", category: .filesSpace),
        ModuleMetadata(id: .similarImages, title: "相似图片", subtitle: "感知查重 · 保留最佳", systemImage: "photo.on.rectangle.angled", category: .filesSpace),

        ModuleMetadata(id: .uninstaller, title: "卸载器", subtitle: "彻底卸载含残留", systemImage: "xmark.bin", category: .applications),
        ModuleMetadata(id: .appUpdater, title: "应用更新", subtitle: "检查可更新的应用", systemImage: "arrow.triangle.2.circlepath", category: .applications),
        ModuleMetadata(id: .shredder, title: "文件粉碎", subtitle: "覆写后彻底删除", systemImage: "flame", category: .filesSpace),

        ModuleMetadata(id: .optimization, title: "优化", subtitle: "登录项 / 高耗进程", systemImage: "speedometer", category: .performance),
        ModuleMetadata(id: .maintenance, title: "维护", subtitle: "缓存 / 索引 / 重启", systemImage: "wrench.and.screwdriver", category: .performance),
        ModuleMetadata(id: .malware, title: "威胁防护", subtitle: "广告软件 / 可疑启动项", systemImage: "shield.lefthalf.filled", category: .performance),
        ModuleMetadata(id: .monitor, title: "系统监视", subtitle: "CPU / 内存 / 网络实时", systemImage: "waveform.path.ecg", category: .performance),
        ModuleMetadata(id: .privacy, title: "隐私", subtitle: "浏览器数据清理", systemImage: "hand.raised", category: .performance)
    ]

    public static func grouped() -> [(ModuleCategory, [ModuleMetadata])] {
        ModuleCategory.allCases.map { cat in
            (cat, all.filter { $0.category == cat })
        }
    }
}
