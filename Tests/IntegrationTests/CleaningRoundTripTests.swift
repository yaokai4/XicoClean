import XCTest
import Domain
@testable import Infrastructure

/// 端到端集成测试：真实文件系统上的「扫描 → 清理 → 撤销」闭环，以及安全闸门。
final class CleaningRoundTripTests: XCTestCase {

    let fs = LocalFileSystemService()
    lazy var safety = DefaultSafetyEngine()
    lazy var engine = CleaningEngine(safety: safety, fs: fs)

    private var runLocalSmokeTests: Bool {
        ProcessInfo.processInfo.environment["XICO_RUN_LOCAL_SMOKE_TESTS"] == "1"
    }

    /// 在临时目录里构造一个形似用户缓存的位置，避免默认测试污染真实 ~/Library/Caches。
    func makeSandbox() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("XicoIntegration-\(UUID().uuidString)")
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
        let undo = await engine.undo(report)
        XCTAssertEqual(undo.restored, 1)
        XCTAssertTrue(undo.allSucceeded)
        XCTAssertTrue(undo.failed.isEmpty)
        XCTAssertTrue(fs.exists(file), "撤销后文件应被还原")
    }

    // MARK: 撤销边界（2026-07 审计：撤销失败此前被静默吞掉）

    /// 废纸篓项在撤销前已消失（等价于用户清空了废纸篓）→ undo 必须报告失败清单，不假装成功
    func testUndoReportsFailureWhenTrashedItemGone() async throws {
        let dir = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("junk.dat")
        try Data(repeating: 0xCD, count: 4096).write(to: file)

        let item = CleanableItem(url: file, displayName: "junk.dat", size: 4096)
        let report = await engine.execute(CleaningPlan(items: [item], intent: .trash))
        XCTAssertEqual(report.restorable.count, 1)

        // 模拟「废纸篓被清空」：删掉废纸篓中的项
        let trashed = report.restorable[0].trashedURL
        try? FileManager.default.removeItem(at: trashed)

        let undo = await engine.undo(report)
        XCTAssertEqual(undo.restored, 0)
        XCTAssertFalse(undo.allSucceeded, "废纸篓已空时 undo 不能假装成功")
        XCTAssertEqual(undo.failed.count, 1)
    }

    /// 原位已存在同名项 → 恢复到不冲突的新名字，绝不覆盖用户既有文件
    func testUndoRestoresToUniqueNameOnCollision() async throws {
        let dir = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("dup.txt")
        try "original".data(using: .utf8)!.write(to: file)

        let item = CleanableItem(url: file, displayName: "dup.txt", size: 8)
        let report = await engine.execute(CleaningPlan(items: [item], intent: .trash))
        XCTAssertFalse(fs.exists(file))

        // 原位又出现了一个同名文件（用户新建）
        try "newer".data(using: .utf8)!.write(to: file)

        let undo = await engine.undo(report)
        XCTAssertEqual(undo.restored, 1)
        XCTAssertTrue(undo.allSucceeded)
        // 原文件未被覆盖
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "newer")
        // 恢复项以「(恢复 N)」命名存在
        let restoredCopies = (try FileManager.default.contentsOfDirectory(atPath: dir.path))
            .filter { $0.contains("恢复") }
        XCTAssertEqual(restoredCopies.count, 1, "冲突时应生成一个不覆盖的恢复副本")
    }

    /// 双重撤销：第二次 undo 应把（已经放回的）项判为失败，而不是崩溃或重复
    func testDoubleUndoIsSafe() async throws {
        let dir = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("junk.dat")
        try Data(repeating: 0x11, count: 4096).write(to: file)

        let item = CleanableItem(url: file, displayName: "junk.dat", size: 4096)
        let report = await engine.execute(CleaningPlan(items: [item], intent: .trash))

        let first = await engine.undo(report)
        XCTAssertTrue(first.allSucceeded)
        // 第二次撤销：废纸篓项已被移回，trashedURL 不再存在 → 记为失败，不崩溃
        let second = await engine.undo(report)
        XCTAssertEqual(second.restored, 0)
        XCTAssertEqual(second.failed.count, 1)
        XCTAssertTrue(fs.exists(file), "文件仍在原位（第一次已恢复）")
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
        guard runLocalSmokeTests else {
            throw XCTSkip("Set XICO_RUN_LOCAL_SMOKE_TESTS=1 to scan the local machine.")
        }
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
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("XicoDiskTree-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("A"), withIntermediateDirectories: true)
        try Data(repeating: 1, count: 128 * 1024).write(to: root.appendingPathComponent("A/file.bin"))

        let scanner = DiskTreeScanner(fs: fs)
        let tree = await scanner.scan(root)
        XCTAssertEqual(tree.url.lastPathComponent, root.lastPathComponent)
        XCTAssertGreaterThan(tree.size, 0)
        print("ℹ️ 空间透镜：\(tree.name) = \(tree.size.formattedBytes)，\(tree.children.count) 个子块")
    }
}
