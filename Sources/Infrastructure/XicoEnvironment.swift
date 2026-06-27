import Foundation
import Domain

/// 应用环境：组装所有依赖（依赖注入的根）。
public final class XicoEnvironment: @unchecked Sendable {
    public let fs: FileSystemService
    public let safety: SafetyEngine
    public let definitions: DefinitionsLibrary
    public let cleaningEngine: CleaningEngine
    public let metrics: MetricsSampler
    public let permissions: PermissionsManager
    public let diskTreeScanner: DiskTreeScanner
    public let uninstaller: UninstallerService
    public let optimization: OptimizationService
    public let maintenanceRunner: MaintenanceRunner
    public let liveMetrics: LiveMetricsSampler
    public let helper: HelperProxy

    private let scanners: [ModuleID: ScannerModule]

    public init(
        fs: FileSystemService,
        safety: SafetyEngine,
        definitions: DefinitionsLibrary
    ) {
        self.fs = fs
        self.safety = safety
        self.definitions = definitions
        self.cleaningEngine = CleaningEngine(safety: safety, fs: fs)
        self.metrics = MetricsSampler(fs: fs)
        self.permissions = PermissionsManager()
        self.diskTreeScanner = DiskTreeScanner(fs: fs)
        self.uninstaller = UninstallerService(fs: fs, safety: safety)
        self.optimization = OptimizationService()
        self.maintenanceRunner = MaintenanceRunner()
        self.liveMetrics = LiveMetricsSampler(fs: fs)
        self.helper = HelperProxy()

        var map: [ModuleID: ScannerModule] = [:]
        map[.systemJunk] = SystemJunkScanner(definitions: definitions.definitions, fs: fs, safety: safety)
        map[.largeFiles] = LargeFilesScanner(fs: fs, safety: safety)
        map[.trash] = TrashScanner(fs: fs)
        map[.privacy] = PrivacyScanner(definitions: definitions.definitions, fs: fs, safety: safety)
        map[.malware] = ThreatScanner(fs: fs, safety: safety)
        self.scanners = map
    }

    /// 默认线上环境
    public static func live() -> XicoEnvironment {
        XicoEnvironment(
            fs: LocalFileSystemService(),
            safety: DefaultSafetyEngine(),
            definitions: DefinitionsLibrary.bundled()
        )
    }

    public func scanner(for id: ModuleID) -> ScannerModule? {
        scanners[id]
    }

    public func isImplemented(_ id: ModuleID) -> Bool {
        let extra: Set<ModuleID> = [.smartScan, .spaceLens, .duplicates, .uninstaller, .optimization, .maintenance, .monitor]
        return scanners[id] != nil || extra.contains(id)
    }

    public func duplicatesScanner(root: URL) -> DuplicatesScanner {
        DuplicatesScanner(fs: fs, safety: safety, root: root)
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

        ModuleMetadata(id: .uninstaller, title: "卸载器", subtitle: "彻底卸载含残留", systemImage: "xmark.bin", category: .applications),

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
