import XCTest
import Foundation

/// 回归测试（round-3 P1，MenuPanels:80）：防止「代码里 xLoc/xLocF 用到的 key
/// 没写进 .strings 表」再次发生——那会让原始中文泄漏到 10 个非中文语言。
///
/// 做两件事：
/// 1. 扫描 Sources/ 下所有 .swift，抽出本地化调用的字面量参数——既包括直接的
///    `xLoc("…")` / `xLocF("…")` / `Text(localized: "…")`，也包括「把原始中文字面量喂进
///    内部会 xLoc 的 helper」这类间接键：`sectionLabel("…")`（SettingsView，内部 xLoc）与
///    `record(module: "…")`（历史记录的模块名，后续经 moduleLabel→xLoc 显示）。断言每一个都能在
///    基准表 zh-Hans Localizable.strings 里找到（否则列出全部孤儿 key 并失败）。
/// 2. 断言 11 份 Localizable.strings 的 key 集合完全一致（parity）——仅 file-to-file
///    数量相等并不足以防泄漏，故两条同时校验。
final class LocalizationCoverageTests: XCTestCase {

    /// 全部 11 种语言（与 DesignSystem/Resources/*.lproj 一一对应）。
    private static let locales = [
        "en", "zh-Hans", "zh-Hant", "ja", "ko",
        "de", "fr", "es", "it", "pt-BR", "ru",
    ]

    /// 基准语言（源语言）：key 即中文，其余语言都应覆盖它的 key 集合。
    private static let baseLocale = "zh-Hans"

    // MARK: - 路径推导（从 #filePath 逆推包根）

    /// 包根目录：Tests/FeatureTests/<thisFile> → 上跳三级到包根。
    private func packageRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Tests/FeatureTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // 包根
    }

    private func sourcesDir() -> URL {
        packageRoot().appendingPathComponent("Sources", isDirectory: true)
    }

    private func stringsURL(_ locale: String) -> URL {
        sourcesDir()
            .appendingPathComponent("DesignSystem", isDirectory: true)
            .appendingPathComponent("Resources", isDirectory: true)
            .appendingPathComponent("\(locale).lproj", isDirectory: true)
            .appendingPathComponent("Localizable.strings", isDirectory: false)
    }

    // MARK: - 载入 .strings key 集合

    /// 用 PropertyList 解析（`.strings` 即老式 plist），取其 key 集合。
    private func keys(of locale: String) throws -> Set<String> {
        let url = stringsURL(locale)
        let data = try Data(contentsOf: url)
        let obj = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        let dict = try XCTUnwrap(obj as? [String: String],
                                 "\(locale) Localizable.strings 应解析为字符串字典")
        return Set(dict.keys)
    }

    /// 反转义源码字面量里的常见转义序列，使其与 PropertyList 解析出的真实字符 key 对齐。
    static func unescape(_ s: String) -> String {
        var out = ""
        var it = s.makeIterator()
        while let c = it.next() {
            if c == "\\", let n = it.next() {
                switch n {
                case "n": out.append("\n")
                case "t": out.append("\t")
                case "r": out.append("\r")
                case "\"": out.append("\"")
                case "\\": out.append("\\")
                default: out.append(n)
                }
            } else {
                out.append(c)
            }
        }
        return out
    }

    // MARK: - 抽取代码里用到的 key

    /// 遍历 Sources 下所有 .swift，抽取本地化调用里的简单字面量参数
    /// （不含转义引号——与 xLoc key 的实际用法一致）。
    private func usedKeys() throws -> Set<String> {
        // 匹配四类会把字面量当成本地化 key 的调用：
        //   xLoc("…") / xLocF("…")            —— 直接本地化
        //   Text(localized: "…")               —— SwiftUI 直接本地化
        //   sectionLabel("…")                  —— SettingsView 内部 Text(xLoc(title))，喂原始中文字面量
        //   record(module: "…")                —— 历史模块名，后续 moduleLabel→xLoc(module) 显示
        // 注意：旧的 `xSectionLabel("…")` 模式已删——xSectionLabel() 是无参 View 修饰符，
        // 永不接受字符串字面量，该模式恒不命中（死模式，给人「已覆盖」的假象）。
        // 捕获组 1 = 字面量内容。允许转义序列（\n \" \\ 等），否则含 \n 的 key 会整条被漏掉，
        // 造成「测试假绿」——正是这类 key 曾泄漏中文。捕获后再反转义，与 plist 解析出的基准 key 对齐。
        let patterns = [
            #"\bxLocF?\(\s*"((?:[^"\\]|\\.)*)""#,
            #"\bText\(\s*localized:\s*"((?:[^"\\]|\\.)*)""#,
            #"\bsectionLabel\(\s*"((?:[^"\\]|\\.)*)""#,
            #"\brecord\(\s*module:\s*"((?:[^"\\]|\\.)*)""#,
        ]
        let regexes = try patterns.map { try NSRegularExpression(pattern: $0) }

        let root = sourcesDir()
        let fm = FileManager.default
        guard let walker = fm.enumerator(at: root,
                                         includingPropertiesForKeys: nil,
                                         options: [.skipsHiddenFiles]) else {
            XCTFail("无法枚举 Sources 目录：\(root.path)")
            return []
        }

        var used = Set<String>()
        for case let url as URL in walker where url.pathExtension == "swift" {
            let src = try String(contentsOf: url, encoding: .utf8)
            let ns = src as NSString
            let whole = NSRange(location: 0, length: ns.length)
            for regex in regexes {
                regex.enumerateMatches(in: src, options: [], range: whole) { match, _, _ in
                    guard let match, match.numberOfRanges >= 2 else { return }
                    let r = match.range(at: 1)
                    guard r.location != NSNotFound else { return }
                    let raw = ns.substring(with: r)
                    // 跳过含 Swift 字符串插值 \(…) 的字面量：它们是运行时拼接的动态值，不是静态
                    // key（如 record(module: "卸载 · \(appName)")）。按字面量解析会产出伪 key 造成误报。
                    if raw.contains("\\(") { return }
                    used.insert(Self.unescape(raw))
                }
            }
        }
        return used
    }

    // MARK: - 测试

    /// (1) 代码里用到的每个本地化 key 都必须存在于基准 zh-Hans 表。
    func testAllUsedKeysExistInBaseTable() throws {
        let base = try keys(of: Self.baseLocale)
        let used = try usedKeys()
        // 用到的 key 不应为空——否则说明抽取逻辑失效（防止测试假绿）。
        XCTAssertFalse(used.isEmpty, "未从 Sources 抽到任何本地化 key，抽取逻辑可能已失效")

        let orphans = used.subtracting(base).sorted()
        XCTAssertTrue(
            orphans.isEmpty,
            "以下 \(orphans.count) 个 key 在代码中被 xLoc/xLocF/Text(localized:)/sectionLabel/record(module:) 使用，"
                + "但缺失于 \(Self.baseLocale) Localizable.strings（会向非中文语言泄漏原始中文）：\n"
                + orphans.joined(separator: "\n")
        )
    }

    /// (2) 11 份 .strings 的 key 集合必须完全一致（parity）。
    func testAllLocalesShareIdenticalKeySet() throws {
        let base = try keys(of: Self.baseLocale)
        for locale in Self.locales where locale != Self.baseLocale {
            let other = try keys(of: locale)
            let missing = base.subtracting(other).sorted()
            let extra = other.subtracting(base).sorted()
            XCTAssertTrue(
                missing.isEmpty && extra.isEmpty,
                "\(locale) 与 \(Self.baseLocale) 的 key 集合不一致。\n"
                    + "缺失（\(missing.count)）：\(missing.joined(separator: "、"))\n"
                    + "多余（\(extra.count)）：\(extra.joined(separator: "、"))"
            )
        }
    }

    // MARK: - definitions.json 派生 key

    /// definitions.json 的绝对路径（Sources/Domain/Resources/definitions.json）。
    private func definitionsJSONURL() -> URL {
        sourcesDir()
            .appendingPathComponent("Domain", isDirectory: true)
            .appendingPathComponent("Resources", isDirectory: true)
            .appendingPathComponent("definitions.json", isDirectory: false)
    }

    /// 从 definitions.json 抽取每条清理项的 title/description 字面量。这些字符串在 UI 里经
    /// xLoc 显示（本地化在展示层，中文字面量即 key），因此它们本身就是本地化 key——但因为来自
    /// JSON 而非 Swift 字面量，usedKeys() 的源码扫描抓不到它们，需单独校验。
    private func definitionsStrings() throws -> Set<String> {
        let data = try Data(contentsOf: definitionsJSONURL())
        let obj = try JSONSerialization.jsonObject(with: data, options: [])
        let root = try XCTUnwrap(obj as? [String: Any], "definitions.json 应解析为 JSON 对象")
        let defs = try XCTUnwrap(root["definitions"] as? [[String: Any]],
                                 "definitions.json 应含 definitions 数组")
        var out = Set<String>()
        for d in defs {
            if let title = d["title"] as? String { out.insert(title) }
            if let desc = d["description"] as? String { out.insert(desc) }
        }
        return out
    }

    /// (3) definitions.json 里每个 title/description（经 xLoc 显示）都必须存在于基准 zh-Hans 表，
    /// 否则这 ~112 条会向 10 个非中文语言泄漏原始中文。
    func testDefinitionsJSONKeysAreLocalized() throws {
        let base = try keys(of: Self.baseLocale)
        let defKeys = try definitionsStrings()
        // 抽取结果不应为空——否则说明 JSON 结构变化导致抽取失效（防止测试假绿）。
        XCTAssertFalse(defKeys.isEmpty,
                       "未从 definitions.json 抽到任何 title/description，抽取逻辑可能已失效")

        let missing = defKeys.subtracting(base).sorted()
        XCTAssertTrue(
            missing.isEmpty,
            "以下 \(missing.count) 个 definitions.json 的 title/description 在 UI 经 xLoc 显示，"
                + "但缺失于 \(Self.baseLocale) Localizable.strings（会向非中文语言泄漏原始中文）：\n"
                + missing.joined(separator: "\n")
        )
    }
}
