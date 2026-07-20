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

public enum CleaningPrerequisite: Sendable, Equatable {
    case none
    case threatRemediation
}

/// Maximum number of typed D/R facts a cleaning terminal may produce. This is shared by Domain,
/// remediation authorization, and history so an admitted operation cannot mutate successfully and
/// then become unpersistable or advertise a retry token that was evicted from a bounded store.
public enum CleaningOperationLimits {
    public static let maximumFactCount = 256
}

public struct CleaningPlan: Sendable {
    public let items: [CleanableItem]
    public let intent: DeleteIntent
    public let prerequisite: CleaningPrerequisite

    public init(
        items: [CleanableItem],
        intent: DeleteIntent = .trash,
        prerequisite: CleaningPrerequisite = .none
    ) {
        self.items = items
        self.intent = intent
        self.prerequisite = prerequisite
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

/// Opaque, in-memory authorization captured by Domain when the original request inventory is
/// prepared. Retry executes this immutable copy; Feature cannot substitute a different route,
/// size estimate, target or prerequisite.
public struct CleaningRetryAuthorization: Sendable {
    public let item: CleanableItem
    public let intent: DeleteIntent
    public let prerequisite: CleaningPrerequisite

    init(
        item: CleanableItem,
        intent: DeleteIntent,
        prerequisite: CleaningPrerequisite
    ) {
        self.item = item
        self.intent = intent
        self.prerequisite = prerequisite
    }
}

public struct CleaningItemResult: Sendable {
    public let requestID: UUID
    public let itemID: UUID
    public let url: URL
    public let intent: DeleteIntent
    public let prerequisite: CleaningPrerequisite
    public let retryAuthorization: CleaningRetryAuthorization?
    public let disposition: OperationDisposition
    public let mutation: OperationMutationFact
    public let reclaimedBytes: Int64
    public let restorable: RestorableItem?
    init(requestID: UUID, itemID: UUID, url: URL, intent: DeleteIntent,
         prerequisite: CleaningPrerequisite = .none,
         retryAuthorization: CleaningRetryAuthorization? = nil,
         disposition: OperationDisposition, mutation: OperationMutationFact,
         reclaimedBytes: Int64, restorable: RestorableItem?) {
        self.requestID = requestID
        self.itemID = itemID
        self.url = url
        self.intent = intent
        self.prerequisite = prerequisite
        self.retryAuthorization = retryAuthorization
        self.disposition = disposition
        self.mutation = mutation
        self.reclaimedBytes = max(0, reclaimedBytes)
        self.restorable = intent == .trash && disposition == .succeeded ? restorable : nil
    }
}

/// Fixed input for Domain's fail-closed uninstall terminal factory. It is exposed only through
/// the uninstall execution SPI so normal Feature imports cannot mint reducer facts.
@_spi(XicoUninstallExecution)
public struct UninstallMalformedOccurrence: Sendable {
    public let requestID: UUID
    public let item: CleanableItem

    public init(requestID: UUID, item: CleanableItem) {
        self.requestID = requestID
        self.item = item
    }
}

/// Validated launch-agent identity retained only in memory so a later auxiliary-only retry never
/// needs to reopen a plist that the successful deletion already moved or removed.
public struct ThreatRemediationRetryToken: Equatable, Sendable {
    public let validatedLabel: String
    public let rootRelativeIdentity: String

    public init?(validatedLabel: String, rootRelativeIdentity: String) {
        guard !validatedLabel.isEmpty,
              validatedLabel.utf8.count <= 512,
              validatedLabel.utf8.allSatisfy({ byte in
                  (65...90).contains(byte)
                      || (97...122).contains(byte)
                      || (48...57).contains(byte)
                      || byte == 46 || byte == 95 || byte == 45
              }),
              !rootRelativeIdentity.isEmpty,
              rootRelativeIdentity != ".",
              rootRelativeIdentity != "..",
              !rootRelativeIdentity.contains("/"),
              !rootRelativeIdentity.contains("\\"),
              rootRelativeIdentity.utf8.count <= 255,
              URL(fileURLWithPath: rootRelativeIdentity).pathExtension
                .caseInsensitiveCompare("plist") == .orderedSame else {
            return nil
        }
        self.validatedLabel = validatedLabel
        self.rootRelativeIdentity = rootRelativeIdentity
    }
}

public struct ThreatRemediationRequest: Sendable {
    public let requestID: UUID
    public let relatedCleaningRequestID: UUID
    public let url: URL
    public let retryToken: ThreatRemediationRetryToken?

    public init(
        requestID: UUID,
        relatedCleaningRequestID: UUID,
        url: URL,
        retryToken: ThreatRemediationRetryToken? = nil
    ) {
        self.requestID = requestID
        self.relatedCleaningRequestID = relatedCleaningRequestID
        self.url = url
        self.retryToken = retryToken
    }
}

public struct ThreatRemediationItemResult: Sendable {
    public let requestID: UUID
    public let relatedCleaningRequestID: UUID
    public let url: URL
    public let disposition: OperationDisposition
    public let mutation: OperationMutationFact
    public let retryToken: ThreatRemediationRetryToken?

    public init(
        requestID: UUID,
        relatedCleaningRequestID: UUID,
        url: URL,
        disposition: OperationDisposition,
        mutation: OperationMutationFact,
        retryToken: ThreatRemediationRetryToken? = nil
    ) {
        self.requestID = requestID
        self.relatedCleaningRequestID = relatedCleaningRequestID
        self.url = url
        self.disposition = disposition
        self.mutation = mutation
        self.retryToken = retryToken
    }
}

public struct ThreatRemediationReport: Sendable {
    public let items: [ThreatRemediationItemResult]

    public init(items: [ThreatRemediationItemResult]) {
        self.items = items
    }
}

public protocol ThreatRemediationExecuting: Sendable {
    func remediate(
        _ requests: [ThreatRemediationRequest],
        operationID: UUID,
        parentID: UUID
    ) async -> OperationResult<ThreatRemediationReport>
}

public enum CleaningAuxiliaryItemKind: String, Codable, Sendable {
    case threatRemediation
}

public struct CleaningAuxiliaryItemResult: Sendable {
    public let requestID: UUID
    public let relatedCleaningRequestID: UUID
    public let kind: CleaningAuxiliaryItemKind
    public let disposition: OperationDisposition
    public let mutation: OperationMutationFact
    public let retryToken: ThreatRemediationRetryToken?

    public init(
        requestID: UUID,
        relatedCleaningRequestID: UUID,
        kind: CleaningAuxiliaryItemKind,
        disposition: OperationDisposition,
        mutation: OperationMutationFact,
        retryToken: ThreatRemediationRetryToken? = nil
    ) {
        self.requestID = requestID
        self.relatedCleaningRequestID = relatedCleaningRequestID
        self.kind = kind
        self.disposition = disposition
        self.mutation = mutation
        self.retryToken = retryToken
    }
}

public enum CleaningOperationFact: Sendable {
    case deletion(CleaningItemResult)
    case auxiliary(CleaningAuxiliaryItemResult)

    public var requestID: UUID {
        switch self {
        case let .deletion(item): item.requestID
        case let .auxiliary(item): item.requestID
        }
    }

    public var disposition: OperationDisposition {
        switch self {
        case let .deletion(item): item.disposition
        case let .auxiliary(item): item.disposition
        }
    }

    public var mutation: OperationMutationFact {
        switch self {
        case let .deletion(item): item.mutation
        case let .auxiliary(item): item.mutation
        }
    }

    public var affectedBytes: Int64 {
        switch self {
        case let .deletion(item): item.reclaimedBytes
        case .auxiliary: 0
        }
    }
}

public enum CleaningReportMergeFailure: String, Equatable, Sendable {
    case empty
    case purposeMismatch
    case childCorrelationMismatch
    case duplicateRequestID
    case missingOccurrence
    case invalidAuxiliaryLink
    case factMismatch

    var issueCode: String {
        "cleaning.merge.\(rawValue)"
    }
}

/// Domain-owned evidence required to reproduce an unregistered, fail-closed cleaning terminal.
/// It is never inferred from `OperationOutcome.issues`; callers outside Domain cannot mint it.
enum CleaningReportRejectionMetadata: Equatable, Sendable {
    case merge(CleaningReportMergeFailure)
    case unexpectedMerge
    case inventoryLimit(projectedFactCount: Int)
    case uninstallMalformed

    var issueCode: String {
        switch self {
        case let .merge(failure): failure.issueCode
        case .unexpectedMerge: "cleaning.merge.unexpected"
        case .inventoryLimit: "cleaning.request.inventoryLimitExceeded"
        case .uninstallMalformed: "uninstall.terminal.malformed"
        }
    }
}

public struct CleaningReportMergeError: Error, Sendable {
    public let failure: CleaningReportMergeFailure
    public let failClosedReport: CleaningReport

    public var code: String { failure.issueCode }

    init(failure: CleaningReportMergeFailure, failClosedReport: CleaningReport) {
        self.failure = failure
        self.failClosedReport = failClosedReport
    }
}

public struct CleaningReport: Sendable {
    public let operation: OperationOutcome
    public let facts: [CleaningOperationFact]
    private let retryReceiptLedger: [CleaningRetryReceipt]
    let rejectionMetadata: CleaningReportRejectionMetadata?

    init(
        operation: OperationOutcome,
        items: [CleaningItemResult],
        auxiliaryItems: [CleaningAuxiliaryItemResult] = []
    ) {
        self.operation = operation
        self.facts = items.map(CleaningOperationFact.deletion)
            + auxiliaryItems.map(CleaningOperationFact.auxiliary)
        self.retryReceiptLedger = []
        self.rejectionMetadata = nil
    }

    init(
        operation: OperationOutcome,
        facts: [CleaningOperationFact],
        retryReceiptLedger: [CleaningRetryReceipt] = [],
        rejectionMetadata: CleaningReportRejectionMetadata? = nil
    ) {
        self.operation = operation
        self.facts = facts
        self.retryReceiptLedger = retryReceiptLedger
        self.rejectionMetadata = rejectionMetadata
    }

    public var items: [CleaningItemResult] {
        facts.compactMap { fact in
            guard case let .deletion(item) = fact else { return nil }
            return item
        }
    }

    public var auxiliaryItems: [CleaningAuxiliaryItemResult] {
        facts.compactMap { fact in
            guard case let .auxiliary(item) = fact else { return nil }
            return item
        }
    }

    public var removedCount: Int {
        return items.reduce(into: 0) { count, item in
            if item.disposition == .succeeded { count += 1 }
        }
    }
    public var reclaimedBytes: Int64 {
        return items.reduce(0) { total, item in
            guard item.disposition == .succeeded else { return total }
            return saturatedNonnegativeSum(total, item.reclaimedBytes)
        }
    }
    public var failures: [CleaningFailure] {
        return items.compactMap { item in
            switch item.disposition {
            case let .failed(issue), let .skipped(issue):
                return CleaningFailure(url: item.url, reason: issue.code)
            default: return nil
            }
        }
    }
    public var restorable: [RestorableItem] {
        return items.compactMap { $0.disposition == .succeeded ? $0.restorable : nil }
    }

    var retainedRetryReceipts: [CleaningRetryReceipt] { retryReceiptLedger }

    /// True only when the terminal outcome can be reproduced exactly from the stored typed facts.
    public var isReducerBacked: Bool {
        Self.isReducerConsistent(self)
    }

    /// Domain-owned fixed-kind fallback for a malformed payload observed after an uninstall body
    /// may have run. It deliberately cannot express success, unchanged, receipts or a generic
    /// retry authorization; each exact prepared occurrence remains `possiblyChanged`.
    @_spi(XicoUninstallExecution)
    public static func uninstallMalformed(
        operationID: UUID,
        occurrences: [UninstallMalformedOccurrence],
        startedAt: Date,
        finishedAt: Date
    ) -> CleaningReport {
        let results = occurrences.map { occurrence in
            let issue = OperationIssue(
                code: "uninstall.terminal.malformed",
                category: .internalInvariant,
                subjectID: occurrence.requestID.uuidString,
                recovery: .retry,
                retryable: true)
            return CleaningItemResult(
                requestID: occurrence.requestID,
                itemID: occurrence.item.id,
                url: occurrence.item.url,
                intent: .trash,
                disposition: .failed(issue),
                mutation: .possiblyChanged,
                reclaimedBytes: 0,
                restorable: nil)
        }
        let outcome = OperationOutcomeReducer.internalFailure(
            id: operationID,
            kind: .uninstall,
            requestedSubjectIDs: results.map { $0.requestID.uuidString },
            itemOutcomes: results.map {
                OperationItemOutcome(
                    subjectID: $0.requestID.uuidString,
                    disposition: $0.disposition,
                    mutation: $0.mutation)
            },
            code: "uninstall.terminal.malformed",
            startedAt: startedAt,
            finishedAt: finishedAt)
        return CleaningReport(
            operation: outcome,
            facts: results.map(CleaningOperationFact.deletion),
            rejectionMetadata: .uninstallMalformed)
    }

    static func merging(
        _ reports: [CleaningReport],
        supplemental: [OperationResult<ThreatRemediationReport>],
        purpose: CleaningOperationPurpose,
        id: UUID,
        parentID: UUID?,
        occurrenceOrder: [UUID]
    ) throws -> CleaningReport {
        let deletionItems = reports.flatMap(\.items)
        let auxiliaryItems = supplemental.flatMap { result in
            result.payload.items.map {
                CleaningAuxiliaryItemResult(
                    requestID: $0.requestID,
                    relatedCleaningRequestID: $0.relatedCleaningRequestID,
                    kind: .threatRemediation,
                    disposition: $0.disposition,
                    mutation: $0.mutation,
                    retryToken: $0.retryToken)
            }
        }
        let fallbackFacts = orderedFactsFailClosed(
            deletionItems: deletionItems,
            auxiliaryItems: auxiliaryItems,
            occurrenceOrder: occurrenceOrder)

        func reject(_ failure: CleaningReportMergeFailure) throws -> Never {
            throw CleaningReportMergeError(
                failure: failure,
                failClosedReport: failClosed(
                    facts: fallbackFacts,
                    parentID: parentID,
                    failure: failure))
        }

        guard !reports.isEmpty, !deletionItems.isEmpty else {
            try reject(.empty)
        }
        guard reports.allSatisfy({ $0.operation.kind == purpose.operationKind }),
              supplemental.allSatisfy({ $0.outcome.kind == .threatRemediation }) else {
            try reject(.purposeMismatch)
        }
        guard reports.allSatisfy({ $0.operation.parentID == id }),
              supplemental.allSatisfy({ $0.outcome.parentID == id }) else {
            try reject(.childCorrelationMismatch)
        }
        guard reports.allSatisfy(isReducerConsistent),
              supplemental.allSatisfy(isReducerConsistent) else {
            try reject(.factMismatch)
        }

        let deletionIDs = deletionItems.map(\.requestID)
        guard occurrenceOrder.count == deletionIDs.count,
              Set(occurrenceOrder) == Set(deletionIDs) else {
            try reject(.missingOccurrence)
        }
        let allIDs = deletionIDs + auxiliaryItems.map(\.requestID)
        guard Set(allIDs).count == allIDs.count else {
            try reject(.duplicateRequestID)
        }

        let deletionSet = Set(deletionIDs)
        var related = Set<UUID>()
        for auxiliary in auxiliaryItems {
            guard deletionSet.contains(auxiliary.relatedCleaningRequestID),
                  related.insert(auxiliary.relatedCleaningRequestID).inserted else {
                try reject(.invalidAuxiliaryLink)
            }
        }

        let deletionByID = Dictionary(uniqueKeysWithValues: deletionItems.map {
            ($0.requestID, $0)
        })
        let auxiliaryByRelated = Dictionary(uniqueKeysWithValues: auxiliaryItems.map {
            ($0.relatedCleaningRequestID, $0)
        })
        var orderedFacts: [CleaningOperationFact] = []
        orderedFacts.reserveCapacity(allIDs.count)
        for requestID in occurrenceOrder {
            guard let deletion = deletionByID[requestID] else {
                try reject(.missingOccurrence)
            }
            orderedFacts.append(.deletion(deletion))
            if let auxiliary = auxiliaryByRelated[requestID] {
                orderedFacts.append(.auxiliary(auxiliary))
            }
        }

        let childOutcomes = reports.map(\.operation) + supplemental.map(\.outcome)
        guard let startedAt = childOutcomes.map(\.startedAt).min(),
              let finishedAt = childOutcomes.map(\.finishedAt).max() else {
            try reject(.empty)
        }
        let operation: OperationOutcome
        do {
            operation = try OperationOutcomeReducer.reduce(
                id: id,
                parentID: parentID,
                kind: purpose.operationKind,
                requestedSubjectIDs: orderedFacts.map { $0.requestID.uuidString },
                itemOutcomes: orderedFacts.map(\.operationItemOutcome),
                cancellationAccepted: childOutcomes.contains { $0.status == .cancelled },
                startedAt: startedAt,
                finishedAt: finishedAt)
        } catch {
            try reject(.factMismatch)
        }
        return CleaningReport(operation: operation, facts: orderedFacts)
    }

    private static func isReducerConsistent(_ report: CleaningReport) -> Bool {
        if let rejection = report.rejectionMetadata {
            if case let .inventoryLimit(projectedFactCount) = rejection {
                guard report.facts.isEmpty,
                      projectedFactCount > CleaningOperationLimits.maximumFactCount else {
                    return false
                }
                let reproduced = OperationOutcomeReducer.admissionFailure(
                    id: report.operation.id,
                    parentID: report.operation.parentID,
                    kind: report.operation.kind,
                    requestedCount: projectedFactCount,
                    code: rejection.issueCode,
                    startedAt: report.operation.startedAt,
                    finishedAt: report.operation.finishedAt)
                return outcomesMatch(reproduced, report.operation)
            }
            if case .uninstallMalformed = rejection {
                guard !report.facts.isEmpty,
                      report.operation.kind == .uninstall else { return false }
                let reproduced = OperationOutcomeReducer.internalFailure(
                    id: report.operation.id,
                    parentID: report.operation.parentID,
                    kind: .uninstall,
                    requestedSubjectIDs: report.facts.map {
                        $0.requestID.uuidString
                    },
                    itemOutcomes: report.facts.map(\.operationItemOutcome),
                    cancellationAccepted: false,
                    code: rejection.issueCode,
                    startedAt: report.operation.startedAt,
                    finishedAt: report.operation.finishedAt)
                return outcomesMatch(reproduced, report.operation)
            }
            guard !report.facts.isEmpty else { return false }
            guard report.operation.kind == OperationKind("cleaning.merge.rejected") else {
                return false
            }
            let reproduced = OperationOutcomeReducer.internalFailure(
                id: report.operation.id,
                parentID: report.operation.parentID,
                kind: report.operation.kind,
                requestedSubjectIDs: report.facts.map { $0.requestID.uuidString },
                itemOutcomes: report.facts.map(\.operationItemOutcome),
                cancellationAccepted: false,
                code: rejection.issueCode,
                startedAt: report.operation.startedAt,
                finishedAt: report.operation.finishedAt)
            return outcomesMatch(reproduced, report.operation)
        }
        guard !report.facts.isEmpty else { return false }
        return outcomeMatchesFacts(
            report.operation,
            facts: report.facts)
    }

    static func isReducerConsistent(
        _ result: OperationResult<ThreatRemediationReport>
    ) -> Bool {
        let facts = result.payload.items.map {
            OperationItemOutcome(
                subjectID: $0.requestID.uuidString,
                disposition: $0.disposition,
                mutation: $0.mutation)
        }
        return outcomeMatchesFacts(
            result.outcome,
            requestedSubjectIDs: result.payload.items.map { $0.requestID.uuidString },
            itemOutcomes: facts)
    }

    private static func outcomeMatchesFacts(
        _ outcome: OperationOutcome,
        facts: [CleaningOperationFact]
    ) -> Bool {
        outcomeMatchesFacts(
            outcome,
            requestedSubjectIDs: facts.map { $0.requestID.uuidString },
            itemOutcomes: facts.map(\.operationItemOutcome))
    }

    private static func outcomeMatchesFacts(
        _ outcome: OperationOutcome,
        requestedSubjectIDs: [String],
        itemOutcomes: [OperationItemOutcome]
    ) -> Bool {
        let reduced: OperationOutcome
        do {
            reduced = try OperationOutcomeReducer.reduce(
                id: outcome.id,
                parentID: outcome.parentID,
                kind: outcome.kind,
                requestedSubjectIDs: requestedSubjectIDs,
                itemOutcomes: itemOutcomes,
                cancellationAccepted: outcome.status == .cancelled,
                startedAt: outcome.startedAt,
                finishedAt: outcome.finishedAt)
        } catch {
            return false
        }
        return outcomesMatch(reduced, outcome)
    }

    private static func outcomesMatch(
        _ lhs: OperationOutcome,
        _ rhs: OperationOutcome
    ) -> Bool {
        lhs.id == rhs.id
            && lhs.parentID == rhs.parentID
            && lhs.kind == rhs.kind
            && lhs.status == rhs.status
            && lhs.counts == rhs.counts
            && lhs.startedAt == rhs.startedAt
            && lhs.finishedAt == rhs.finishedAt
            && lhs.issues == rhs.issues
            && lhs.mutation == rhs.mutation
    }

    private static func orderedFactsFailClosed(
        deletionItems: [CleaningItemResult],
        auxiliaryItems: [CleaningAuxiliaryItemResult],
        occurrenceOrder: [UUID]
    ) -> [CleaningOperationFact] {
        var remainingDeletions = deletionItems
        var remainingAuxiliary = auxiliaryItems
        var result: [CleaningOperationFact] = []
        for requestID in occurrenceOrder {
            if let index = remainingDeletions.firstIndex(where: {
                $0.requestID == requestID
            }) {
                result.append(.deletion(remainingDeletions.remove(at: index)))
            }
            while let index = remainingAuxiliary.firstIndex(where: {
                $0.relatedCleaningRequestID == requestID
            }) {
                result.append(.auxiliary(remainingAuxiliary.remove(at: index)))
            }
        }
        result.append(contentsOf: remainingDeletions.map(CleaningOperationFact.deletion))
        result.append(contentsOf: remainingAuxiliary.map(CleaningOperationFact.auxiliary))
        return result
    }

    private static func failClosed(
        facts: [CleaningOperationFact],
        parentID: UUID?,
        failure: CleaningReportMergeFailure
    ) -> CleaningReport {
        let now = Date()
        let operation = OperationOutcomeReducer.internalFailure(
            parentID: parentID,
            kind: OperationKind("cleaning.merge.rejected"),
            requestedSubjectIDs: facts.map { $0.requestID.uuidString },
            itemOutcomes: facts.map(\.operationItemOutcome),
            code: failure.issueCode,
            startedAt: now,
            finishedAt: now)
        return CleaningReport(
            operation: operation,
            facts: facts,
            rejectionMetadata: .merge(failure))
    }
}

/// Domain-owned correlation between a retry's new deletion/context fact and the exact deletion
/// occurrence in the prior terminal. Feature consumers must use this mapping instead of paths or
/// caller item IDs; repeated caller IDs are intentionally valid.
public struct CleaningRetryOccurrenceExecution: Sendable {
    public let priorDeletionOccurrenceIndex: Int
    public let deletionRequestID: UUID
    public let performedDeletion: Bool

    init(
        priorDeletionOccurrenceIndex: Int,
        deletionRequestID: UUID,
        performedDeletion: Bool
    ) {
        self.priorDeletionOccurrenceIndex = priorDeletionOccurrenceIndex
        self.deletionRequestID = deletionRequestID
        self.performedDeletion = performedDeletion
    }
}

/// Receipt ownership is retained across retry generations without adding old deletion facts to a
/// new terminal or inflating that retry's removal metrics/history notification count.
public struct CleaningRetryReceipt: Equatable, Sendable {
    public let ownerOperationID: UUID
    public let deletionRequestID: UUID
    public let item: RestorableItem

    init(
        ownerOperationID: UUID,
        deletionRequestID: UUID,
        item: RestorableItem
    ) {
        self.ownerOperationID = ownerOperationID
        self.deletionRequestID = deletionRequestID
        self.item = item
    }
}

/// Typed retry terminal plus its verified occurrence correlation.
public struct CleaningRetryExecution: Sendable {
    public let report: CleaningReport
    public let occurrences: [CleaningRetryOccurrenceExecution]
    public let retainedReceipts: [CleaningRetryReceipt]

    init(
        report: CleaningReport,
        occurrences: [CleaningRetryOccurrenceExecution],
        retainedReceipts: [CleaningRetryReceipt]
    ) {
        self.report = report
        self.occurrences = occurrences
        self.retainedReceipts = retainedReceipts
    }
}

private extension CleaningOperationFact {
    var operationItemOutcome: OperationItemOutcome {
        OperationItemOutcome(
            subjectID: requestID.uuidString,
            disposition: disposition,
            mutation: mutation,
            affectedBytes: affectedBytes)
    }
}

func saturatedNonnegativeSum(_ lhs: Int64, _ rhs: Int64) -> Int64 {
    let (sum, overflow) = max(0, lhs).addingReportingOverflow(max(0, rhs))
    return overflow ? .max : sum
}

public struct RestorableItem: Sendable, Codable, Equatable {
    public let originalURL: URL
    public let trashedURL: URL
    public init(originalURL: URL, trashedURL: URL) {
        self.originalURL = originalURL
        self.trashedURL = trashedURL
    }
}

public struct UndoItemResult: Sendable {
    public let requestID: UUID
    public let item: RestorableItem
    public let disposition: OperationDisposition
    public let mutation: OperationMutationFact
    /// Exact destination reported and validated after a successful restore. Non-success facts
    /// cannot expose a destination because the filesystem state is not trusted in those cases.
    public let restoredURL: URL?

    init(
        requestID: UUID,
        item: RestorableItem,
        disposition: OperationDisposition,
        mutation: OperationMutationFact,
        restoredURL: URL? = nil
    ) {
        if disposition == .succeeded {
            precondition(restoredURL != nil,
                         "A succeeded undo fact requires its exact restored URL")
        }
        self.requestID = requestID
        self.item = item
        self.disposition = disposition
        self.mutation = mutation
        self.restoredURL = disposition == .succeeded ? restoredURL : nil
    }
}

/// Reducer-backed undo payload. Failed, skipped and cancelled receipts remain available verbatim
/// for a later retry; callers never need to manufacture a replacement cleaning report.
public struct UndoReport: Sendable {
    public let items: [UndoItemResult]
    public let remaining: [RestorableItem]

    init(items: [UndoItemResult]) {
        self.items = items
        self.remaining = items.compactMap { item in
            switch item.disposition {
            case .succeeded, .unchanged:
                return nil
            case .skipped, .failed, .cancelled:
                return item.item
            }
        }
    }

    public var restoredCount: Int {
        items.reduce(into: 0) { count, item in
            if item.disposition == .succeeded { count += 1 }
        }
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
