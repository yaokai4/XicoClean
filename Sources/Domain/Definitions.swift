import Foundation

/// Rule DSL 2.0 的结构化谓词。所有谓词均为 AND；无法证明满足时从严跳过该项。
public struct CleanupConstraints: Codable, Sendable, Hashable {
    public let minimumAgeDays: Int?
    public let minimumSizeBytes: Int64?
    public let maximumSizeBytes: Int64?
    public let fileExtensions: [String]
    public let minimumOSMajor: Int?
    public let maximumOSMajor: Int?
    public let recommendationConfidence: Double?
    public let recovery: RecoveryMethod?
    public let regenerationCost: RegenerationCost?

    public init(minimumAgeDays: Int? = nil, minimumSizeBytes: Int64? = nil,
                maximumSizeBytes: Int64? = nil, fileExtensions: [String] = [],
                minimumOSMajor: Int? = nil, maximumOSMajor: Int? = nil,
                recommendationConfidence: Double? = nil,
                recovery: RecoveryMethod? = nil,
                regenerationCost: RegenerationCost? = nil) {
        self.minimumAgeDays = minimumAgeDays
        self.minimumSizeBytes = minimumSizeBytes
        self.maximumSizeBytes = maximumSizeBytes
        self.fileExtensions = fileExtensions
        self.minimumOSMajor = minimumOSMajor
        self.maximumOSMajor = maximumOSMajor
        self.recommendationConfidence = recommendationConfidence
        self.recovery = recovery
        self.regenerationCost = regenerationCost
    }

    private enum CodingKeys: String, CodingKey {
        case minimumAgeDays, minimumSizeBytes, maximumSizeBytes, fileExtensions
        case minimumOSMajor, maximumOSMajor, recommendationConfidence, recovery, regenerationCost
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        minimumAgeDays = try c.decodeIfPresent(Int.self, forKey: .minimumAgeDays)
        minimumSizeBytes = try c.decodeIfPresent(Int64.self, forKey: .minimumSizeBytes)
        maximumSizeBytes = try c.decodeIfPresent(Int64.self, forKey: .maximumSizeBytes)
        fileExtensions = try c.decodeIfPresent([String].self, forKey: .fileExtensions) ?? []
        minimumOSMajor = try c.decodeIfPresent(Int.self, forKey: .minimumOSMajor)
        maximumOSMajor = try c.decodeIfPresent(Int.self, forKey: .maximumOSMajor)
        recommendationConfidence = try c.decodeIfPresent(Double.self, forKey: .recommendationConfidence)
        recovery = try c.decodeIfPresent(RecoveryMethod.self, forKey: .recovery)
        regenerationCost = try c.decodeIfPresent(RegenerationCost.self, forKey: .regenerationCost)
    }
}

/// 一条数据驱动的清理定义（对应一类垃圾）
public struct CleanupDefinition: Codable, Sendable, Identifiable {
    public let id: String
    public let category: String
    public let title: String
    public let description: String
    /// 待清理路径模式，支持 "~" 前缀与结尾 "/*"（表示该目录下的直接子项）
    public let paths: [String]
    /// 反例保护：命中这些前缀的子项不清理
    public let exclude: [String]
    public let safety: SafetyLevel
    public let requiresHelper: Bool
    public let systemImage: String
    /// 「为什么可删」（P5 安全库）：本条规则的专项解释；缺省回落类目模板（`resolvedExplanation`）。
    public let explanation: String?
    /// 结构化匹配条件；nil 表示沿用路径规则。在线规则可逐步迁移，不破坏旧库。
    public let constraints: CleanupConstraints?

    public init(id: String, category: String, title: String, description: String,
                paths: [String], exclude: [String] = [], safety: SafetyLevel = .safe,
                requiresHelper: Bool = false, systemImage: String = "trash",
                explanation: String? = nil, constraints: CleanupConstraints? = nil) {
        self.id = id
        self.category = category
        self.title = title
        self.description = description
        self.paths = paths
        self.exclude = exclude
        self.safety = safety
        self.requiresHelper = requiresHelper
        self.systemImage = systemImage
        self.explanation = explanation
        self.constraints = constraints
    }

    private enum CodingKeys: String, CodingKey {
        case id, category, title, description, paths, exclude, safety, requiresHelper, systemImage,
             explanation, constraints
    }

    /// 容错解码：可选字段缺省时用默认值（便于精简 JSON 与未来在线更新）
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        category = try c.decode(String.self, forKey: .category)
        title = try c.decode(String.self, forKey: .title)
        description = try c.decode(String.self, forKey: .description)
        paths = try c.decode([String].self, forKey: .paths)
        exclude = try c.decodeIfPresent([String].self, forKey: .exclude) ?? []
        safety = try c.decodeIfPresent(SafetyLevel.self, forKey: .safety) ?? .safe
        requiresHelper = try c.decodeIfPresent(Bool.self, forKey: .requiresHelper) ?? false
        systemImage = try c.decodeIfPresent(String.self, forKey: .systemImage) ?? "trash"
        explanation = try c.decodeIfPresent(String.self, forKey: .explanation)
        constraints = try c.decodeIfPresent(CleanupConstraints.self, forKey: .constraints)
    }

    /// 专项解释，缺省回落类目模板——每条结果都答得出「为什么可删」（P5）。
    /// 中文字面量即 i18n key，显示层 xLoc 本地化。
    public var resolvedExplanation: String {
        if let explanation, !explanation.isEmpty { return explanation }
        switch category {
        case "system-junk":
            return "系统或应用自动生成的数据，删除后会按需自动重建，不影响你的文档与设置。"
        case "developer-junk":
            return "开发工具的派生数据（编译产物、索引、模拟器缓存），重新构建时会自动重新生成。"
        case "ios":
            return "iOS 设备的本地备份/固件安装包，可随时重新备份或重新下载。删除前请确认不再需要。"
        case "privacy":
            return "浏览器缓存数据，删除后浏览器会自动重建；不影响书签、密码与登录状态以外的数据请逐项确认。"
        default:
            return "由 Xico 安全库规则判定为可再生数据；删除默认移入废纸篓，可随时撤销。"
        }
    }
}

/// 清理定义库（可在线更新，内置离线兜底）
public struct DefinitionsLibrary: Codable, Sendable {
    public let version: Int
    public let definitions: [CleanupDefinition]
    /// 远程规则运营元数据。旧内置库可为空；新库可用有效期与应用版本边界防止过时规则长期生效。
    public let issuedAt: Date?
    public let expiresAt: Date?
    public let minimumAppVersion: String?
    public let maximumAppVersion: String?
    /// 紧急 kill switch：保留规则历史但立即停止执行指定 id。
    public let disabledDefinitionIDs: [String]
    /// 已吊销的许可证 ID（经签名规则库通道下发，实现最低成本的退款吊销）。
    public let revokedLicenseIDs: [String]
    /// 威胁特征（已知广告软件/PUP 标识子串，小写）——经签名通道下发，免发版即可更新病毒库。
    public let threatSignatures: [String]

    public init(version: Int, definitions: [CleanupDefinition],
                revokedLicenseIDs: [String] = [], threatSignatures: [String] = [],
                issuedAt: Date? = nil, expiresAt: Date? = nil,
                minimumAppVersion: String? = nil, maximumAppVersion: String? = nil,
                disabledDefinitionIDs: [String] = []) {
        self.version = version
        self.definitions = definitions
        self.revokedLicenseIDs = revokedLicenseIDs
        self.threatSignatures = threatSignatures
        self.issuedAt = issuedAt
        self.expiresAt = expiresAt
        self.minimumAppVersion = minimumAppVersion
        self.maximumAppVersion = maximumAppVersion
        self.disabledDefinitionIDs = disabledDefinitionIDs
    }

    public var activeDefinitions: [CleanupDefinition] {
        let disabled = Set(disabledDefinitionIDs)
        return definitions.filter { !disabled.contains($0.id) }
    }

    // 旧版/精简 JSON 无新增字段——容错默认空。
    private enum CodingKeys: String, CodingKey {
        case version, definitions, revokedLicenseIDs, threatSignatures
        case issuedAt, expiresAt, minimumAppVersion, maximumAppVersion, disabledDefinitionIDs
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decode(Int.self, forKey: .version)
        definitions = try c.decode([CleanupDefinition].self, forKey: .definitions)
        revokedLicenseIDs = try c.decodeIfPresent([String].self, forKey: .revokedLicenseIDs) ?? []
        threatSignatures = try c.decodeIfPresent([String].self, forKey: .threatSignatures) ?? []
        issuedAt = try c.decodeIfPresent(Date.self, forKey: .issuedAt)
        expiresAt = try c.decodeIfPresent(Date.self, forKey: .expiresAt)
        minimumAppVersion = try c.decodeIfPresent(String.self, forKey: .minimumAppVersion)
        maximumAppVersion = try c.decodeIfPresent(String.self, forKey: .maximumAppVersion)
        disabledDefinitionIDs = try c.decodeIfPresent([String].self, forKey: .disabledDefinitionIDs) ?? []
    }

    /// 从打包资源加载内置定义库
    public static func bundled() -> DefinitionsLibrary {
        guard let url = Bundle.module.url(forResource: "definitions", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let lib = try? JSONDecoder().decode(DefinitionsLibrary.self, from: data) else {
            return DefinitionsLibrary(version: 0, definitions: [])
        }
        return lib
    }
}
