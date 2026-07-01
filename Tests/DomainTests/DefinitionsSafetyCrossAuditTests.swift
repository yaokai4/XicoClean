import XCTest
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
