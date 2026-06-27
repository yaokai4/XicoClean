import XCTest
import CoreGraphics
import Domain
@testable import Features

/// 空间透镜 treemap 布局回归测试 —— 钉死之前的栈溢出崩溃。
/// 这些用例若触发无限递归会让测试卡死/崩溃；能正常返回即证明已修复。
final class TreemapTests: XCTestCase {

    let rect = CGRect(x: 0, y: 0, width: 800, height: 600)
    func node(_ size: Int64) -> DiskNode {
        DiskNode(url: URL(fileURLWithPath: "/x"), name: "n", isDirectory: false, size: size)
    }

    /// 之前导致崩溃的退化用例：累积大小只在最后一项越过半数
    func testDegenerateCaseDoesNotRecurseInfinitely() {
        let items = [node(1), node(1), node(1_000_000)]
        let result = TreemapView.squarify(items, in: rect)
        XCTAssertEqual(result.count, items.count)
    }

    /// 另一个退化用例：第一项就占绝大多数
    func testFirstItemDominates() {
        let items = [node(1_000_000), node(1), node(1)]
        let result = TreemapView.squarify(items, in: rect)
        XCTAssertEqual(result.count, items.count)
    }

    /// 模糊测试：500 组随机大小，必须全部正常返回（不卡死、不崩溃）
    func testFuzzAlwaysTerminates() {
        for _ in 0..<500 {
            let n = Int.random(in: 1...40)
            let items = (0..<n).map { _ in node(Int64.random(in: 1...10_000_000)) }
            let result = TreemapView.squarify(items, in: rect)
            // 全非零时应一一对应
            XCTAssertEqual(result.count, items.count)
            // 矩形不应出现非法尺寸
            for (_, r) in result {
                XCTAssertGreaterThanOrEqual(r.width, 0)
                XCTAssertGreaterThanOrEqual(r.height, 0)
            }
        }
    }

    /// 含 0 大小项 / 全 0：不崩即可
    func testZeroSizesDoNotCrash() {
        _ = TreemapView.squarify([node(0), node(0), node(0)], in: rect)
        let mixed = TreemapView.squarify([node(0), node(100), node(0), node(50)], in: rect)
        XCTAssertLessThanOrEqual(mixed.count, 4)
    }

    /// 单元素 / 极小矩形边界
    func testEdgeCases() {
        XCTAssertEqual(TreemapView.squarify([node(5)], in: rect).count, 1)
        XCTAssertEqual(TreemapView.squarify([], in: rect).count, 0)
        XCTAssertEqual(TreemapView.squarify([node(5), node(5)], in: CGRect(x: 0, y: 0, width: 0, height: 0)).count, 0)
    }
}
