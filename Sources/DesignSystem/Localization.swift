import Foundation
import SwiftUI

/// 国际化：中 / 日 / 英三语，支持 App 内实时切换（不依赖系统语言、无需重启）。
///
/// 机制：源语言为中文（key 即中文）。`xLoc` 按 `XLocale.current` 选定语言的 `.lproj`
/// 子包查表；切换语言时更新此值并让根视图 `.id` 重建即可全局即时换语言。

public enum XLang: String, CaseIterable, Sendable, Identifiable {
    case system
    case zhHans = "zh-Hans"
    case en
    case ja

    public var id: String { rawValue }

    /// 用「该语言自己的写法」显示语言名（本地人视角）。
    public var nativeName: String {
        switch self {
        case .system: return xLoc("跟随系统")
        case .zhHans: return "简体中文"
        case .en:     return "English"
        case .ja:     return "日本語"
        }
    }
}

public enum XLocale {
    /// 当前语言。仅主线程读写（SwiftUI 渲染读、设置页切换写），故 nonisolated(unsafe)。
    nonisolated(unsafe) public static var current: XLang = .system {
        didSet { UserDefaults.standard.set(current.rawValue, forKey: Self.key) }
    }
    private static let key = "xico.lang"

    /// 启动时载入已保存语言。
    public static func load() {
        if let s = UserDefaults.standard.string(forKey: key), let l = XLang(rawValue: s) { current = l }
    }

    nonisolated(unsafe) private static var cache: [String: Bundle] = [:]

    /// 当前语言对应的 SwiftUI Locale——让 .relative 日期、数字等系统格式化也跟随 App 语言。
    public static var swiftUILocale: Locale {
        switch current {
        case .system: return Locale.autoupdatingCurrent
        case .zhHans: return Locale(identifier: "zh_Hans")
        case .en:     return Locale(identifier: "en")
        case .ja:     return Locale(identifier: "ja")
        }
    }

    /// 当前语言对应的资源包（system → 默认按系统解析）。
    static func activeBundle() -> Bundle {
        let lang = current
        guard lang != .system else { return .module }
        if let b = cache[lang.rawValue] { return b }
        guard let path = Bundle.module.path(forResource: lang.rawValue, ofType: "lproj"),
              let b = Bundle(path: path) else { return .module }
        cache[lang.rawValue] = b
        return b
    }
}

/// 本地化查表：按当前 App 内语言取字符串，缺失回落到 key（中文源）。
public func xLoc(_ key: String) -> String {
    XLocale.activeBundle().localizedString(forKey: key, value: key, table: nil)
}

public extension Text {
    /// 本地化文案的便捷构造：`Text(localized: "智能扫描")`
    init(localized key: String) { self.init(xLoc(key)) }
}

/// 带参数的本地化：key 是含占位符（%d / %@）的中文格式串，按当前语言取模板后填充。
public func xLocF(_ key: String, _ args: CVarArg...) -> String {
    String(format: xLoc(key), arguments: args)
}
