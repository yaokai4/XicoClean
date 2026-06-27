import XCTest
import Domain
@testable import Infrastructure

/// 端到端集成测试：真实文件系统上的「扫描 → 清理 → 撤销」闭环，以及安全闸门。
final class CleaningRoundTripTests: XCTestCase {

    let fs = LocalFileSystemService()
    lazy var safety = DefaultSafetyEngine()
    lazy var engine = CleaningEngine(safety: safety, fs: fs)

    /// 在一个安全可清理的位置（~/Library/Caches）造测试数据
    func makeSandbox() throws -> URL {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/XicoIntegrationTest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func testTrashThenUndoRoundTrip() async throws {
        let dir = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: dir) }

        let file = dir.appendingPathComponent("junk.dat")
        let payload = Data(repeating: 0xAB, count: 256 * 1024)
        try payload.write(to: file)

        XCTAssertTrue(fs.exists(file))

        let item = CleanableItem(url: file, displayName: "junk.dat", size: Int64(payload.count))
        let report = await engine.execute(CleaningPlan(items: [item], intent: .trash))

        // 已移入废纸篓
        XCTAssertEqual(report.removedCount, 1)
        XCTAssertEqual(report.failures.count, 0)
        XCTAssertFalse(fs.exists(file), "清理后原位置应不存在")
        XCTAssertEqual(report.restorable.count, 1)

        // 撤销 → 回到原位
        let restored = await engine.undo(report)
        XCTAssertEqual(restored, 1)
        XCTAssertTrue(fs.exists(file), "撤销后文件应被还原")
    }

    func testCleaningRefusesProtectedPath() async throws {
        // 试图清理受保护路径，必须被安全闸门拦截、计入失败、绝不删除
        let protectedItem = CleanableItem(
            url: URL(fileURLWithPath: "/System/Library/Xico-should-never-touch"),
            displayName: "protected", size: 1024, safety: .risky, isSelected: true)

        let report = await engine.execute(CleaningPlan(items: [protectedItem], intent: .trash))
        XCTAssertEqual(report.removedCount, 0, "受保护路径绝不能被删除")
        XCTAssertEqual(report.failures.count, 1)
    }

    func testSystemJunkScannerRunsAgainstRealFS() async throws {
        let scanner = SystemJunkScanner(
            definitions: DefinitionsLibrary.bundled().definitions, fs: fs, safety: safety)
        let result = try await scanner.scan { _ in }
        XCTAssertGreaterThanOrEqual(result.totalReclaimable, 0)
        print("ℹ️ 系统垃圾扫描：发现 \(result.groups.count) 组，可清理 \(result.totalReclaimable.formattedBytes)")
        for group in result.groups.prefix(8) {
            print("   · \(group.title): \(group.totalSize.formattedBytes)（\(group.items.count) 项）")
        }
    }

    func testDiskTreeScannerProducesTree() async throws {
        let scanner = DiskTreeScanner(fs: fs)
        let root = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches")
        let tree = await scanner.scan(root)
        XCTAssertEqual(tree.url.lastPathComponent, "Caches")
        XCTAssertGreaterThanOrEqual(tree.size, 0)
        print("ℹ️ 空间透镜：\(tree.name) = \(tree.size.formattedBytes)，\(tree.children.count) 个子块")
    }
}
