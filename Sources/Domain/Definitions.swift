import Foundation

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

    public init(id: String, category: String, title: String, description: String,
                paths: [String], exclude: [String] = [], safety: SafetyLevel = .safe,
                requiresHelper: Bool = false, systemImage: String = "trash") {
        self.id = id
        self.category = category
        self.title = title
        self.description = description
        self.paths = paths
        self.exclude = exclude
        self.safety = safety
        self.requiresHelper = requiresHelper
        self.systemImage = systemImage
    }

    private enum CodingKeys: String, CodingKey {
        case id, category, title, description, paths, exclude, safety, requiresHelper, systemImage
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
    }
}

/// 清理定义库（可在线更新，内置离线兜底）
public struct DefinitionsLibrary: Codable, Sendable {
    public let version: Int
    public let definitions: [CleanupDefinition]

    public init(version: Int, definitions: [CleanupDefinition]) {
        self.version = version
        self.definitions = definitions
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
