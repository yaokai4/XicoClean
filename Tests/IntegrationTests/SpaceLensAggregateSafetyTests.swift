import XCTest
import Foundation
@testable import Infrastructure
import Domain

/// 审计 P0 回归：空间透镜的合成聚合桶（「其他」/「其他文件」）复用父目录 URL，
/// 若可被删除会误移整个当前文件夹入废纸篓。此测试锁定「桶被标记 isAggregate 且复用父 URL」，
/// 从而保证 UI 隐藏其删除入口、`SpaceLensModel.trash` 兜底拒绝的前提成立。
final class SpaceLensAggregateSafetyTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("xico-spacelens-agg-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // 20 个远小于 minFileNodeBytes(8MB) 的小文件 → 必被聚合进「其他文件」桶。
        for i in 0..<20 {
            let data = Data(count: 4096)
            try data.write(to: dir.appendingPathComponent("small-\(i).bin"))
        }
    }

    override func tearDownWithError() throws {
        if let dir { try? FileManager.default.removeItem(at: dir) }
    }

    func testAggregateBucketIsFlaggedAndReusesParentURL() async throws {
        let tree = await DiskTreeScanner(fs: LocalFileSystemService()).scan(dir)

        // 根目录是真实目录，绝不能被误标为聚合桶。
        XCTAssertFalse(tree.isAggregate, "根目录不应被标记为聚合桶")

        let buckets = tree.children.filter { $0.isAggregate }
        XCTAssertFalse(buckets.isEmpty, "大量小文件应被聚合为「其他」桶")
        for bucket in buckets {
            XCTAssertTrue(bucket.isAggregate)
            // 危险点固化：桶复用父目录 URL——正因如此绝不可删，必须靠 isAggregate 拦截（审计 P0）。
            // 与树根 URL 比对而非传入的 dir：扫描器用 realpath 解析根路径（/var → /private/var），
            // 拼写可能变化，但「桶 URL == 父节点 URL」这一危险性质不变。
            XCTAssertEqual(bucket.url, tree.url,
                           "聚合桶复用父目录 URL；若允许删除即误删整个文件夹")
            XCTAssertEqual(bucket.url.resolvingSymlinksInPath().path, dir.resolvingSymlinksInPath().path)
            XCTAssertTrue(bucket.name == "其他文件" || bucket.name == "其他")
        }
    }
}
