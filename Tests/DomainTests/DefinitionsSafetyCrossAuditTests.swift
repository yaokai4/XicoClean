import XCTest
import Darwin
@testable import Domain
import Shared

/// 交叉审计：内置规则库里的**每一条清理路径**都必须落在安全红线放行区内。
/// 防止「一条写错的规则带着 safe 标签出厂」——例如误加 `~/Library/Mail/*`，
/// 填入具体分量后会被红线拒绝，本测试即失败，规则库无法手滑上线。
final class DefinitionsSafetyCrossAuditTests: XCTestCase {

    private let testHome = "/Users/tester"

    /// 用测试 home 展开 `~`，并把每个 glob 段填成一个样本分量。
    private func concretePaths(for pattern: String) -> [String] {
        var p = pattern
        if p.hasPrefix("~") {
            p = testHome + p.dropFirst()
        }
        // 把每个 `*` 替换成样本分量 "Sample"（多段通配也逐个替换）
        let filled = p.split(separator: "/").map { seg -> String in
            seg == "*" ? "Sample" : seg.replacingOccurrences(of: "*", with: "Sample")
        }.joined(separator: "/")
        return ["/" + filled]
    }

    func testEveryBundledDefinitionPathIsDeletable() {
        let rules = XicoSafetyRules(home: URL(fileURLWithPath: testHome))
        let lib = DefinitionsLibrary.bundled()
        XCTAssertFalse(lib.definitions.isEmpty)

        for def in lib.definitions {
            for pattern in def.paths {
                for concrete in concretePaths(for: pattern) {
                    let url = URL(fileURLWithPath: concrete)
                    if let reason = rules.denyReason(for: url) {
                        XCTFail("规则 \"\(def.id)\" 的路径 \"\(pattern)\" 填充后 \(concrete) 命中安全红线：\(reason)。"
                              + "清理规则绝不能指向受保护区域。")
                    }
                }
            }
        }
    }

    /// 规则路径不得相互重叠（防止同一文件被两条规则各计一次 → 可清理总量虚高）。
    /// 用 fnmatch 做 glob 交集判定：把每个模式的每个 `*` 替成固定样本分量得到一条具体路径，
    /// 若模式 A 能匹配到 B 的样本路径（或反之），则二者可命中同一批文件 = 重叠。
    func testNoOverlappingRulePaths() {
        let lib = DefinitionsLibrary.bundled()
        func expand(_ pattern: String) -> String {
            var p = pattern
            if p.hasPrefix("~") { p = "/Users/tester" + p.dropFirst() }
            return p
        }
        func sample(_ pattern: String) -> String {
            // 每个通配段替成唯一样本分量（用不同占位避免把 A、B 的 * 巧合对齐）
            expand(pattern).split(separator: "/").map { $0 == "*" ? "SAMPLE" : $0.replacingOccurrences(of: "*", with: "SAMPLE") }.joined(separator: "/")
        }
        func matches(_ pattern: String, _ path: String) -> Bool {
            expand(pattern).withCString { pat in
                path.withCString { str in fnmatch(pat, str, FNM_PATHNAME) == 0 }
            }
        }
        var entries: [(id: String, pattern: String)] = []
        for def in lib.definitions { for p in def.paths { entries.append((def.id, p)) } }
        for a in entries {
            for b in entries where a.id != b.id {
                if matches(a.pattern, sample(b.pattern)) || matches(b.pattern, sample(a.pattern)) {
                    XCTFail("规则 \(a.id)（\(a.pattern)）与 \(b.id)（\(b.pattern)）路径重叠，可能重复计入")
                }
            }
        }
    }

    /// 反向自检：确保交叉审计确实能抓到坏路径（否则测试形同虚设）
    func testCrossAuditCatchesDangerousPattern() {
        let rules = XicoSafetyRules(home: URL(fileURLWithPath: testHome))
        // 一条"如果有人手滑加进去"的危险规则
        let dangerous = "~/Library/Mail/*"
        let concrete = concretePaths(for: dangerous)[0]  // /Users/tester/Library/Mail/Sample
        XCTAssertNotNil(rules.denyReason(for: URL(fileURLWithPath: concrete)),
                        "红线必须拒绝邮件目录，交叉审计才有意义")
    }
}
