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
        isInformational: Bool = false
    ) {
        self.id = id
        self.url = url
        self.displayName = displayName
        self.detail = detail.isEmpty ? url.path : detail
        self.size = size
        self.safety = safety
        self.requiresHelper = requiresHelper
        self.isInformational = isInformational
        self.isSelected = isInformational ? false : (isSelected ?? (requiresHelper ? false : safety.defaultSelected))
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
    public var selectedSize: Int64 { items.filter(\.isSelected).reduce(0) { $0 + $1.size } }
    /// 真正可清理的字节（剔除「仅提示」项）：头条「可清理 X GB」与进度环分母必须用这个口径——
    /// 引擎永不删的字节计入「可清理」即是行业虚标（2026-07 终审 P1）。组卡自身仍显示 totalSize
    ///（该组的事实体量，配「仅提示」徽标是诚实的）。
    public var reclaimableSize: Int64 { items.filter { !$0.isInformational }.reduce(0) { $0 + $1.size } }
}

/// 一个模块扫描后的完整结果
public struct ScanResult: Sendable {
    public let moduleID: ModuleID
    public var groups: [ScanResultGroup]

    public init(moduleID: ModuleID, groups: [ScanResultGroup]) {
        self.moduleID = moduleID
        self.groups = groups
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
