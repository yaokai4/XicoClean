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
    static let similarImages = ModuleID("similar-images")
    static let appUpdater = ModuleID("app-updater")
    static let shredder = ModuleID("shredder")
    static let settings = ModuleID("settings")
}

/// 模块分类（决定侧边栏分组）
public enum ModuleCategory: String, Sendable, CaseIterable, Codable {
    case cleanup        // 清理
    case applications   // 应用
    case filesSpace     // 文件与空间
    case performance    // 性能与安全

    public var title: String {
        switch self {
        case .cleanup: return "清理"
        case .applications: return "应用"
        case .filesSpace: return "文件与空间"
        case .performance: return "性能与安全"
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

    public init(id: ModuleID, title: String, subtitle: String, systemImage: String, category: ModuleCategory) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.systemImage = systemImage
        self.category = category
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

    public init(
        id: UUID = UUID(),
        url: URL,
        displayName: String,
        detail: String = "",
        size: Int64,
        safety: SafetyLevel = .safe,
        isSelected: Bool? = nil,
        requiresHelper: Bool = false,
        note: String? = nil
    ) {
        self.id = id
        self.url = url
        self.displayName = displayName
        self.detail = detail.isEmpty ? url.path : detail
        self.size = size
        self.safety = safety
        self.requiresHelper = requiresHelper
        self.isSelected = isSelected ?? (requiresHelper ? false : safety.defaultSelected)
        self.note = note
    }
}

/// 一组可清理项（一条清理规则 / 一类垃圾）
public struct ScanResultGroup: Identifiable, Sendable {
    public let id: String
    public let title: String
    public let description: String
    public let systemImage: String
    public let safety: SafetyLevel
    public var items: [CleanableItem]

    public init(id: String, title: String, description: String = "", systemImage: String = "folder", safety: SafetyLevel = .safe, items: [CleanableItem]) {
        self.id = id
        self.title = title
        self.description = description
        self.systemImage = systemImage
        self.safety = safety
        self.items = items
    }

    public var totalSize: Int64 { items.reduce(0) { $0 + $1.size } }
    public var selectedSize: Int64 { items.filter(\.isSelected).reduce(0) { $0 + $1.size } }
}

/// 一个模块扫描后的完整结果
public struct ScanResult: Sendable {
    public let moduleID: ModuleID
    public var groups: [ScanResultGroup]

    public init(moduleID: ModuleID, groups: [ScanResultGroup]) {
        self.moduleID = moduleID
        self.groups = groups
    }

    public var totalReclaimable: Int64 { groups.reduce(0) { $0 + $1.totalSize } }
    public var selectedReclaimable: Int64 { groups.reduce(0) { $0 + $1.selectedSize } }
    public var itemCount: Int { groups.reduce(0) { $0 + $1.items.count } }
}

// MARK: - 进度

public struct ScanProgress: Sendable {
    public var fraction: Double?      // 0...1，未知时为 nil
    public var message: String
    public var bytesFound: Int64

    public init(fraction: Double? = nil, message: String = "", bytesFound: Int64 = 0) {
        self.fraction = fraction
        self.message = message
        self.bytesFound = bytesFound
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

    public var totalSize: Int64 { items.reduce(0) { $0 + $1.size } }
}

public struct CleaningFailure: Sendable {
    public let url: URL
    public let reason: String
    public init(url: URL, reason: String) {
        self.url = url
        self.reason = reason
    }
}

public struct CleaningReport: Sendable {
    public let removedCount: Int
    public let reclaimedBytes: Int64
    public let failures: [CleaningFailure]
    /// 已移入废纸篓的项：原路径 -> 废纸篓中的新路径（用于撤销）
    public let restorable: [RestorableItem]

    public init(removedCount: Int, reclaimedBytes: Int64, failures: [CleaningFailure], restorable: [RestorableItem]) {
        self.removedCount = removedCount
        self.reclaimedBytes = reclaimedBytes
        self.failures = failures
        self.restorable = restorable
    }
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

public extension Int64 {
    /// 友好的容量字符串，如 "1.2 GB"（0 显示为 "0 B"，不出现 "Zero bytes"）
    var formattedBytes: String {
        if self <= 0 { return "0 B" }
        let f = ByteCountFormatter()
        f.countStyle = .file
        f.allowsNonnumericFormatting = false
        f.allowedUnits = [.useBytes, .useKB, .useMB, .useGB, .useTB]
        return f.string(fromByteCount: self)
    }
}
