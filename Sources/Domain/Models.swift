import Foundation

// MARK: - 模块标识与元数据

/// 功能模块的唯一标识
public struct ModuleID: Hashable, Sendable, RawRepresentable, Codable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ raw: String) { self.rawValue = raw }
}

public extension ModuleID {
    static let smartScan = ModuleID("smart-scan")
    static let systemJunk = ModuleID("system-junk")
    static let largeFiles = ModuleID("large-files")
    static let trash = ModuleID("trash")
    static let spaceLens = ModuleID("space-lens")
    static let duplicates = ModuleID("duplicates")
    static let uninstaller = ModuleID("uninstaller")
    static let privacy = ModuleID("privacy")
    static let optimization = ModuleID("optimization")
    static let maintenance = ModuleID("maintenance")
    static let malware = ModuleID("malware")
    static let monitor = ModuleID("monitor")
    static let hardware = ModuleID("hardware")
    static let similarImages = ModuleID("similar-images")
    static let appUpdater = ModuleID("app-updater")
    static let shredder = ModuleID("shredder")
    static let diskSpeed = ModuleID("disk-speed")
    static let deepScan = ModuleID("deep-scan")
    static let orphans = ModuleID("orphans")
    static let menuBar = ModuleID("menu-bar")
    static let settings = ModuleID("settings")
    // —— 工具（远程与下载）：反超 ServerCat / Downie 的新入口。
    static let servers = ModuleID("servers")
    static let downloader = ModuleID("downloader")
}

/// 模块分类（决定侧边栏分组）
public enum ModuleCategory: String, Sendable, CaseIterable, Codable {
    case cleanup        // 清理
    case applications   // 应用
    case filesSpace     // 文件与空间
    case performance    // 性能与安全
    case tools          // 工具（远程服务器 / 下载器）

    public var title: String {
        switch self {
        case .cleanup: return "清理"
        case .applications: return "应用"
        case .filesSpace: return "文件与空间"
        case .performance: return "性能与安全"
        case .tools: return "工具"
        }
    }
}

/// 模块的展示信息
public struct ModuleMetadata: Sendable, Identifiable {
    public let id: ModuleID
    public let title: String
    public let subtitle: String
    public let systemImage: String
    public let category: ModuleCategory
    /// 是否出现在侧边栏。false = 已并入智能扫描等中枢的隐藏模块——路由与 --open= 直达保留，
    /// 元数据仍供 ModuleScanView 等按 ID 查询（与删除目录行不同，隐藏不破坏任何查找）。
    public let sidebar: Bool

    public init(id: ModuleID, title: String, subtitle: String, systemImage: String, category: ModuleCategory, sidebar: Bool = true) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.systemImage = systemImage
        self.category = category
        self.sidebar = sidebar
    }
}

// MARK: - 安全级别

/// 清理项的安全级别，决定默认勾选与告警强度
public enum SafetyLevel: String, Sendable, Codable, CaseIterable {
    case safe       // 删除安全，默认勾选
    case caution    // 有一定风险，默认不勾，提示
    case risky      // 高风险，默认不勾，强警告

    public var defaultSelected: Bool { self == .safe }

    public var label: String {
        switch self {
        case .safe: return "安全"
        case .caution: return "谨慎"
        case .risky: return "高风险"
        }
    }
}

// MARK: - 扫描结果模型

/// 扫描结论所依据的事实类型。删除资格仍由 SafetyEngine 决定；证据只负责解释与推荐排序。
public enum ScanEvidenceKind: String, Sendable, Codable, Hashable {
    case signedRule
    case pathOwnership
    case regenerable
    case age
    case size
    case exactContent
    case visualSimilarity
    case applicationState
    case codeSignature
    case userLocation
    case safetyPolicy
}

/// 一条可审计的命中证据。`strength` 是 0...1 的证据强度，不是删除授权。
public struct ScanEvidence: Sendable, Codable, Hashable, Identifiable {
    public let code: String
    public let kind: ScanEvidenceKind
    public let title: String
    public let detail: String
    public let strength: Double

    public var id: String { code }

    public init(code: String, kind: ScanEvidenceKind, title: String,
                detail: String = "", strength: Double = 1) {
        self.code = code
        self.kind = kind
        self.title = title
        self.detail = detail
        self.strength = min(max(strength, 0), 1)
    }
}

public enum RecoveryMethod: String, Sendable, Codable, Hashable {
    case trash
    case regenerate
    case redownload
    case appManaged
    case none

    public var label: String {
        switch self {
        case .trash: return "可从废纸篓恢复"
        case .regenerate: return "应用可自动重建"
        case .redownload: return "需要时可重新下载"
        case .appManaged: return "请使用所属应用管理"
        case .none: return "不可自动恢复"
        }
    }
}

public enum RegenerationCost: String, Sendable, Codable, Hashable {
    case negligible
    case low
    case medium
    case high
    case unknown
}

/// 扫描器对单项给出的可解释判断。置信度影响默认推荐，但不能绕过删除期安全闸门。
public struct FindingAssessment: Sendable, Codable, Hashable {
    public let ruleID: String?
    public let confidence: Double
    public let evidence: [ScanEvidence]
    public let ownerBundleID: String?
    public let reclaimableBytes: Int64
    public let recovery: RecoveryMethod
    public let regenerationCost: RegenerationCost
    public let impact: String?
    public let provenance: String

    public init(ruleID: String? = nil, confidence: Double, evidence: [ScanEvidence],
                ownerBundleID: String? = nil, reclaimableBytes: Int64,
                recovery: RecoveryMethod = .trash,
                regenerationCost: RegenerationCost = .unknown,
                impact: String? = nil, provenance: String = "local") {
        self.ruleID = ruleID
        self.confidence = min(max(confidence, 0), 1)
        self.evidence = evidence
        self.ownerBundleID = ownerBundleID
        self.reclaimableBytes = max(0, reclaimableBytes)
        self.recovery = recovery
        self.regenerationCost = regenerationCost
        self.impact = impact
        self.provenance = provenance
    }

    /// 旧扫描器的兼容判断。它仍明确标注为本地安全策略证据，避免出现没有任何理由的结果项。
    public static func compatible(safety: SafetyLevel, size: Int64) -> FindingAssessment {
        FindingAssessment(
            confidence: safety == .safe ? 0.98 : (safety == .caution ? 0.75 : 0.45),
            evidence: [ScanEvidence(
                code: "safety-policy",
                kind: .safetyPolicy,
                title: "通过 Xico 删除安全策略",
                strength: safety == .safe ? 0.98 : 0.7
            )],
            reclaimableBytes: size,
            recovery: safety == .safe ? .regenerate : .trash,
            regenerationCost: safety == .safe ? .low : .unknown,
            provenance: "compatibility"
        )
    }

    /// 只有高置信、至少两类独立证据的安全项才允许扫描器默认推荐。
    public var qualifiesForAutomaticSelection: Bool {
        confidence >= 0.95 && Set(evidence.map(\.kind)).count >= 2
    }
}

/// 扫描覆盖报告：让“很干净”同时说明扫到了哪里、哪些地方没有读取。
public struct ScanCoverage: Sendable, Codable, Hashable {
    public let roots: [String]
    public let filesVisited: Int
    public let directoriesVisited: Int
    public let bytesInspected: Int64
    public let deniedDirectories: Int
    public let skippedMounts: Int
    public let skippedSymlinks: Int
    public let cloudPlaceholdersSkipped: Int
    public let excludedByPolicy: Int
    public let hiddenFilesIncluded: Bool
    public let cancelled: Bool
    public let elapsedSeconds: Double
    public let limitations: [String]

    public init(roots: [String], filesVisited: Int = 0, directoriesVisited: Int = 0,
                bytesInspected: Int64 = 0, deniedDirectories: Int = 0,
                skippedMounts: Int = 0, skippedSymlinks: Int = 0,
                cloudPlaceholdersSkipped: Int = 0, excludedByPolicy: Int = 0,
                hiddenFilesIncluded: Bool = false,
                cancelled: Bool = false, elapsedSeconds: Double = 0,
                limitations: [String] = []) {
        self.roots = roots
        self.filesVisited = max(0, filesVisited)
        self.directoriesVisited = max(0, directoriesVisited)
        self.bytesInspected = max(0, bytesInspected)
        self.deniedDirectories = max(0, deniedDirectories)
        self.skippedMounts = max(0, skippedMounts)
        self.skippedSymlinks = max(0, skippedSymlinks)
        self.cloudPlaceholdersSkipped = max(0, cloudPlaceholdersSkipped)
        self.excludedByPolicy = max(0, excludedByPolicy)
        self.hiddenFilesIncluded = hiddenFilesIncluded
        self.cancelled = cancelled
        self.elapsedSeconds = max(0, elapsedSeconds)
        self.limitations = limitations
    }

    public var isComplete: Bool {
        !cancelled && deniedDirectories == 0 && limitations.isEmpty
    }

    public static func merged(_ reports: [ScanCoverage]) -> ScanCoverage? {
        guard !reports.isEmpty else { return nil }
        // 同一份共享快照会被多个扫描器引用。按值去重后再汇总，避免把同一轮家目录
        // 遍历的文件数、权限缺口和字节数重复计算三次。
        let reports = Array(Set(reports))
        return ScanCoverage(
            roots: Array(Set(reports.flatMap(\.roots))).sorted(),
            filesVisited: reports.reduce(0) { $0 + $1.filesVisited },
            directoriesVisited: reports.reduce(0) { $0 + $1.directoriesVisited },
            bytesInspected: reports.reduce(0) { $0 + $1.bytesInspected },
            deniedDirectories: reports.reduce(0) { $0 + $1.deniedDirectories },
            skippedMounts: reports.reduce(0) { $0 + $1.skippedMounts },
            skippedSymlinks: reports.reduce(0) { $0 + $1.skippedSymlinks },
            cloudPlaceholdersSkipped: reports.reduce(0) { $0 + $1.cloudPlaceholdersSkipped },
            excludedByPolicy: reports.reduce(0) { $0 + $1.excludedByPolicy },
            hiddenFilesIncluded: reports.allSatisfy(\.hiddenFilesIncluded),
            cancelled: reports.contains(where: \.cancelled),
            elapsedSeconds: reports.map(\.elapsedSeconds).max() ?? 0,
            limitations: Array(Set(reports.flatMap(\.limitations))).sorted()
        )
    }
}

/// 单个可清理项
public struct CleanableItem: Identifiable, Sendable, Hashable {
    public let id: UUID
    public let url: URL
    public let displayName: String
    public let detail: String
    public let size: Int64
    public let safety: SafetyLevel
    public var isSelected: Bool
    /// 是否需要特权助手执行。此类项目默认不勾选，且不承诺废纸篓撤销。
    public let requiresHelper: Bool
    /// 附注（如"正在运行"/"已卸载残留"），用于在结果里给用户上下文提示
    public let note: String?
    /// 「仅提示」项（Docker 虚拟磁盘 / 模拟器设备 / Go 模块缓存 / 休眠镜像等）：只陈述体量与
    /// 正确的处置方式，**任何路径都不得执行删除**——组全选跳过、UI 不给勾选框、引擎拒删三层闸。
    /// 此前仅靠 isSelected:false 初始态兜底，组勾选框一勾就会被卷入删除（2026-07 审计缺口）。
    public let isInformational: Bool
    /// 可解释判断：证据、置信度、归属、真实可回收量与恢复方式。
    public let assessment: FindingAssessment

    public init(
        id: UUID = UUID(),
        url: URL,
        displayName: String,
        detail: String = "",
        size: Int64,
        safety: SafetyLevel = .safe,
        isSelected: Bool? = nil,
        requiresHelper: Bool = false,
        note: String? = nil,
        isInformational: Bool = false,
        assessment: FindingAssessment? = nil
    ) {
        self.id = id
        self.url = url
        self.displayName = displayName
        self.detail = detail.isEmpty ? url.path : detail
        self.size = size
        self.safety = safety
        self.requiresHelper = requiresHelper
        self.isInformational = isInformational
        self.assessment = assessment ?? .compatible(safety: safety, size: size)
        // 未迁移的旧扫描器维持原选择行为；一旦显式提供 assessment，就必须满足高置信双证据门槛。
        let automatic = safety.defaultSelected && (assessment?.qualifiesForAutomaticSelection ?? true)
        self.isSelected = isInformational ? false : (isSelected ?? (requiresHelper ? false : automatic))
        self.note = note
    }

    public var estimatedReclaimableBytes: Int64 {
        isInformational ? 0 : assessment.reclaimableBytes
    }
}

/// 一组可清理项（一条清理规则 / 一类垃圾）
public struct ScanResultGroup: Identifiable, Sendable {
    public let id: String
    public let title: String
    public let description: String
    public let systemImage: String
    public let safety: SafetyLevel
    /// 「为什么可删」（P5 安全库）：这条规则判定可删的依据，基于 macOS 事实的一句话解释。
    /// nil = 无专项解释（信息浮层只显示 description 与安全级别通用解释）。中文字面量即 i18n key。
    public let explanation: String?
    public var items: [CleanableItem]

    public init(id: String, title: String, description: String = "", systemImage: String = "folder",
                safety: SafetyLevel = .safe, explanation: String? = nil, items: [CleanableItem]) {
        self.id = id
        self.title = title
        self.description = description
        self.systemImage = systemImage
        self.safety = safety
        self.explanation = explanation
        self.items = items
    }

    public var totalSize: Int64 { items.reduce(0) { $0 + $1.size } }
    public var selectedSize: Int64 { items.filter(\.isSelected).reduce(0) { $0 + $1.estimatedReclaimableBytes } }
    /// 真正可清理的字节（剔除「仅提示」项）：头条「可清理 X GB」与进度环分母必须用这个口径——
    /// 引擎永不删的字节计入「可清理」即是行业虚标（2026-07 终审 P1）。组卡自身仍显示 totalSize
    ///（该组的事实体量，配「仅提示」徽标是诚实的）。
    public var reclaimableSize: Int64 { items.reduce(0) { $0 + $1.estimatedReclaimableBytes } }
}

/// 一个模块扫描后的完整结果
public struct ScanResult: Sendable {
    public let moduleID: ModuleID
    public var groups: [ScanResultGroup]
    public let coverage: ScanCoverage?

    public init(moduleID: ModuleID, groups: [ScanResultGroup], coverage: ScanCoverage? = nil) {
        self.moduleID = moduleID
        self.groups = groups
        self.coverage = coverage
    }

    public var totalReclaimable: Int64 { groups.reduce(0) { $0 + $1.reclaimableSize } }
    public var selectedReclaimable: Int64 { groups.reduce(0) { $0 + $1.selectedSize } }
    public var itemCount: Int { groups.reduce(0) { $0 + $1.items.count } }
}

// MARK: - 进度

public struct ScanProgress: Sendable {
    public var fraction: Double?      // 0...1，未知时为 nil
    public var message: String
    public var bytesFound: Int64
    public var filesVisited: Int
    public var directoriesVisited: Int
    public var deniedDirectories: Int
    public var elapsedSeconds: Double

    public init(fraction: Double? = nil, message: String = "", bytesFound: Int64 = 0,
                filesVisited: Int = 0, directoriesVisited: Int = 0,
                deniedDirectories: Int = 0, elapsedSeconds: Double = 0) {
        self.fraction = fraction
        self.message = message
        self.bytesFound = bytesFound
        self.filesVisited = max(0, filesVisited)
        self.directoriesVisited = max(0, directoriesVisited)
        self.deniedDirectories = max(0, deniedDirectories)
        self.elapsedSeconds = max(0, elapsedSeconds)
    }
}

/// 进度回调（线程安全）
public typealias ProgressHandler = @Sendable (ScanProgress) -> Void

// MARK: - 清理计划与报告

public enum DeleteIntent: Sendable, Equatable {
    case trash      // 移入废纸篓（可恢复，默认）
    case permanent  // 彻底删除（需显式确认）
}

public struct CleaningPlan: Sendable {
    public let items: [CleanableItem]
    public let intent: DeleteIntent

    public init(items: [CleanableItem], intent: DeleteIntent = .trash) {
        self.items = items
        self.intent = intent
    }

    public var totalSize: Int64 { items.reduce(0) { $0 + $1.estimatedReclaimableBytes } }
}

public struct CleaningFailure: Sendable {
    public let url: URL
    public let reason: String
    public init(url: URL, reason: String) {
        self.url = url
        self.reason = reason
    }
}

public struct CleaningItemResult: Sendable {
    public let requestID: UUID
    public let itemID: UUID
    public let url: URL
    public let disposition: OperationDisposition
    public let reclaimedBytes: Int64
    public let restorable: RestorableItem?
    public init(requestID: UUID, itemID: UUID, url: URL, disposition: OperationDisposition,
                reclaimedBytes: Int64, restorable: RestorableItem?) {
        self.requestID = requestID
        self.itemID = itemID
        self.url = url
        self.disposition = disposition
        self.reclaimedBytes = max(0, reclaimedBytes)
        self.restorable = restorable
    }
}

public struct CleaningReport: Sendable {
    public let operation: OperationOutcome
    public let items: [CleaningItemResult]
    private let legacy: LegacyCleaningCompatibility?

    public init(operation: OperationOutcome, items: [CleaningItemResult]) {
        self.operation = operation
        self.items = items
        self.legacy = nil
    }

    public var removedCount: Int { legacy?.removedCount ?? operation.counts.succeeded }
    public var reclaimedBytes: Int64 {
        if let legacy { return legacy.reclaimedBytes }
        return items.reduce(0) { $0 + ($1.disposition == .succeeded ? $1.reclaimedBytes : 0) }
    }
    public var failures: [CleaningFailure] {
        if let legacy { return legacy.failures }
        return items.compactMap { item in
            switch item.disposition {
            case let .failed(issue), let .skipped(issue):
                return CleaningFailure(url: item.url, reason: issue.code)
            default: return nil
            }
        }
    }
    public var restorable: [RestorableItem] {
        if let legacy { return legacy.restorable }
        return items.compactMap { $0.disposition == .succeeded ? $0.restorable : nil }
    }

    // Transitional only; remove in Task 5 after every production constructor is migrated.
    public init(removedCount: Int, reclaimedBytes: Int64,
                failures: [CleaningFailure], restorable: [RestorableItem]) {
        let startedAt = Date()
        let countFromFacts = max(max(0, removedCount) + failures.count, restorable.count)
        let requested = max(countFromFacts, reclaimedBytes > 0 ? 1 : 0)
        let subjectIDs = (0..<requested).map { "legacy-\($0)" }
        self.operation = OperationOutcomeReducer.internalFailure(
            kind: OperationKind("cleaning.legacyAggregate"),
            requestedSubjectIDs: subjectIDs,
            code: "operation.legacy.unknown",
            startedAt: startedAt,
            finishedAt: startedAt)
        self.items = []
        self.legacy = LegacyCleaningCompatibility(
            removedCount: max(0, removedCount),
            reclaimedBytes: max(0, reclaimedBytes),
            failures: failures,
            restorable: restorable)
    }
}

private struct LegacyCleaningCompatibility: Sendable {
    let removedCount: Int
    let reclaimedBytes: Int64
    let failures: [CleaningFailure]
    let restorable: [RestorableItem]
}

public struct RestorableItem: Sendable, Codable, Equatable {
    public let originalURL: URL
    public let trashedURL: URL
    public init(originalURL: URL, trashedURL: URL) {
        self.originalURL = originalURL
        self.trashedURL = trashedURL
    }
}

/// 撤销结果：区分「已恢复」与「未能恢复」，让 UI 能如实反馈而非假装全成功。
public struct UndoResult: Sendable {
    public let restored: Int
    public let failed: [RestorableItem]
    public init(restored: Int, failed: [RestorableItem]) {
        self.restored = restored
        self.failed = failed
    }
    public var allSucceeded: Bool { failed.isEmpty }
}

// MARK: - 文件系统模型

public struct FileEntry: Sendable, Hashable {
    public let url: URL
    public let size: Int64
    public let isDirectory: Bool
    public let modificationDate: Date?
    public let accessDate: Date?

    public init(url: URL, size: Int64, isDirectory: Bool, modificationDate: Date? = nil, accessDate: Date? = nil) {
        self.url = url
        self.size = size
        self.isDirectory = isDirectory
        self.modificationDate = modificationDate
        self.accessDate = accessDate
    }
}

public struct VolumeCapacity: Sendable {
    public let total: Int64
    public let available: Int64        // 重要用途可用（APFS 口径）
    public let used: Int64

    public init(total: Int64, available: Int64) {
        self.total = total
        self.available = available
        self.used = max(0, total - available)
    }

    public var usedFraction: Double { total > 0 ? Double(used) / Double(total) : 0 }
}

// MARK: - 字节格式化

public enum MemoryUnitStyle: String, CaseIterable, Sendable {
    case decimal
    case binary
}

public extension Int64 {
    /// 友好的容量字符串，如 "1.2 GB"（0 显示为 "0 B"，不出现 "Zero bytes"）。
    /// 磁盘/文件用十进制口径（对齐 Finder）。
    var formattedBytes: String {
        if self <= 0 { return "0 B" }
        let f = ByteCountFormatter()
        f.countStyle = .file
        f.allowsNonnumericFormatting = false
        f.allowedUnits = [.useBytes, .useKB, .useMB, .useGB, .useTB]
        return f.string(fromByteCount: self)
    }

    /// 内存容量字符串（二进制口径，对齐活动监视器：16 GiB → "16 GB"）。
    var formattedMemory: String {
        if self <= 0 { return "0 B" }
        let f = ByteCountFormatter()
        f.countStyle = .memory   // 1024 基
        f.allowsNonnumericFormatting = false
        f.allowedUnits = [.useMB, .useGB]
        return f.string(fromByteCount: self)
    }

    func formattedMemory(style: MemoryUnitStyle) -> String {
        guard self > 0 else { return "0 B" }
        let base = style == .decimal ? 1_000.0 : 1_024.0
        let gigabyte = base * base * base
        let value: Double
        let unit: String
        if Double(self) >= gigabyte {
            value = Double(self) / gigabyte
            unit = style == .decimal ? "GB" : "GiB"
        } else {
            value = Double(self) / (base * base)
            unit = style == .decimal ? "MB" : "MiB"
        }
        return String(format: "%.2f %@", value, unit)
    }
}
