import XCTest
import Foundation

/// 回归测试（round-3 P2，RootView:199）：本工作流负责的六个视图文件已把散落的
/// `.font(.system(size: N …))` 一次性字号全部收编进 XFont 令牌（含新增的
/// monoMini/monoMid/heroUnit/titleRounded 及 xNavLabel/xNavIcon 修饰符）。
///
/// 断言这些文件里不再出现裸 `.font(.system(size:` 字面量——字号只能来自 DesignSystem 的
/// 令牌，切换字阶/适配 Dynamic Type 才有单一事实源。范围只限本工作流拥有的文件，
/// 不误伤其它工作流尚未迁移的视图。
final class TypeScaleTokenGuardTests: XCTestCase {

    /// 包根目录：Tests/FeatureTests/<thisFile> → 上跳三级到包根。
    private func packageRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Tests/FeatureTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // 包根
    }

    /// 本工作流拥有、已完成字阶迁移的视图文件（相对包根）。
    private static let ownedViewFiles = [
        "Sources/Features/RootView.swift",
        "Sources/Features/MenuPanels.swift",
        "Sources/Features/MonitorView.swift",
        "Sources/Features/SettingsView.swift",
        "Sources/Features/HardwareView.swift",
        "Sources/Features/ScanViews.swift",
    ]

    /// 禁用的裸字号写法——一律改走 XFont 令牌。
    private static let forbidden = ".font(.system(size:"

    func testOwnedViewsUseTypeScaleTokensOnly() throws {
        let root = packageRoot()
        var offenders: [String] = []
        for rel in Self.ownedViewFiles {
            let url = root.appendingPathComponent(rel, isDirectory: false)
            let source = try String(contentsOf: url, encoding: .utf8)
            for (idx, line) in source.split(separator: "\n", omittingEmptySubsequences: false).enumerated()
            where line.contains(Self.forbidden) {
                offenders.append("\(rel):\(idx + 1)  \(line.trimmingCharacters(in: .whitespaces))")
            }
        }
        XCTAssertTrue(
            offenders.isEmpty,
            "以下位置仍在用裸 .font(.system(size:))，应改用 XFont 令牌：\n" + offenders.joined(separator: "\n"))
    }
}
