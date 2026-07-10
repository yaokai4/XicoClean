import XCTest
@testable import Infrastructure
import Domain

/// 无限钻取（嫁接机制）回归：首扫在 maxDepth 处收口成叶子目录节点，
/// 钻取时现场子扫描 + adoptChildren 嫁接明细、adjustSize 沿祖先链回填——
/// 每一个文件夹最终都能看到（DaisyDisk 口径），且各层「children 之和 ≤ size」不破。
final class SpaceLensDeepDrillTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("xico-deepdrill-\(UUID().uuidString)")
        // 12 层深的链，底部放一个 3MB 文件：远超首扫 maxDepth(6)。
        var dir = tempDir!
        for i in 0..<12 {
            dir = dir.appendingPathComponent("d\(i)")
        }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var payload = Data(capacity: 3 << 20)
        var rng = SystemRandomNumberGenerator()
        while payload.count < 3 << 20 {
            payload.append(contentsOf: withUnsafeBytes(of: rng.next()) { Array($0) })
        }
        try payload.write(to: dir.appendingPathComponent("leaf.bin"))
    }

    override func tearDownWithError() throws {
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
    }

    @MainActor
    func testAdoptChildrenExpandsGranularityBoundary() async throws {
        let fs = LocalFileSystemService()
        let tree = await DiskTreeScanner(fs: fs).scan(tempDir)

        // 找到首扫的粒度边界：isDirectory 且无子节点的目录（尺寸已精确、明细待钻取）。
        func findBoundary(_ n: DiskNode) -> DiskNode? {
            if n.isDirectory && !n.isAggregate && n.children.isEmpty && n.size > 0 { return n }
            for c in n.children { if let hit = findBoundary(c) { return hit } }
            return nil
        }
        let boundary = try XCTUnwrap(findBoundary(tree), "深链首扫应产生粒度边界节点")
        XCTAssertGreaterThanOrEqual(boundary.size, 3 << 20, "边界节点的尺寸必须已含全部深层内容")

        // 现场子扫描（细粒度）+ 嫁接：明细出现、尺寸一致性保持。
        let detail = DiskTreeScanner(fs: fs, maxChildrenPerNode: 64,
                                     minVisibleFraction: 1.0 / 360.0,
                                     minFileNodeBytes: 256 * 1024)
        let fresh = await detail.scan(boundary.url)
        XCTAssertFalse(fresh.children.isEmpty, "子扫描应展开出下层明细")

        let before = boundary.size
        let delta = boundary.adoptChildren(from: fresh)
        XCTAssertEqual(boundary.size, before + delta)
        XCTAssertFalse(boundary.children.isEmpty, "嫁接后边界节点应有可钻取的明细")
        let childSum = boundary.children.reduce(Int64(0)) { $0 + $1.size }
        XCTAssertLessThanOrEqual(childSum, boundary.size, "嫁接后 children 之和不得超过节点尺寸")
    }
}
