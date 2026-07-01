import XCTest
import Domain
@testable import Infrastructure

final class HistoryStoreTests: XCTestCase {

    /// 注入临时目录，绝不触碰用户真实的 Application Support/Xico/history.json
    private var tmpDir: URL!
    override func setUpWithError() throws {
        tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent("xico-history-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: tmpDir) }

    func testRecordsAccumulateAndPersist() throws {
        let store = HistoryStore(directory: tmpDir)
        XCTAssertEqual(store.totalCleanups, 0)

        store.record(module: "系统垃圾", reclaimedBytes: 1_000, removedCount: 3)
        store.record(module: "废纸篓", reclaimedBytes: 2_000, removedCount: 1)

        XCTAssertEqual(store.totalCleanups, 2)
        XCTAssertEqual(store.totalReclaimedAllTime, 3_000)
        XCTAssertEqual(store.recent(1).first?.module, "废纸篓", "最近记录应排在最前")

        // 同目录重建应从磁盘加载（持久化）
        XCTAssertEqual(HistoryStore(directory: tmpDir).totalReclaimedAllTime, 3_000)
    }

    func testIgnoresEmptyRecords() {
        let store = HistoryStore(directory: tmpDir)
        store.record(module: "x", reclaimedBytes: 0, removedCount: 0)
        XCTAssertEqual(store.totalCleanups, 0, "零释放零删除不应记录")
    }

    /// 撤销回滚：remove(id:) 后累计释放不应仍计入（修复「撤销后累计释放虚高」）
    func testRemoveRollsBackTotal() throws {
        let store = HistoryStore(directory: tmpDir)
        let id = store.record(module: "系统垃圾", reclaimedBytes: 5_000, removedCount: 2)
        XCTAssertEqual(store.totalReclaimedAllTime, 5_000)
        XCTAssertNotNil(id)
        store.remove(id: id!)
        XCTAssertEqual(store.totalReclaimedAllTime, 0, "撤销后累计释放应回滚")
        XCTAssertEqual(store.totalCleanups, 0)
    }

    /// 持久化 restorable 映射，并支持跨会话读取用于历史页撤销
    func testRestorablePersistsAndClears() throws {
        let store = HistoryStore(directory: tmpDir)
        let items = [RestorableItem(originalURL: URL(fileURLWithPath: "/tmp/a"),
                                    trashedURL: URL(fileURLWithPath: "/tmp/.Trash/a"))]
        let id = try XCTUnwrap(store.record(module: "系统垃圾", reclaimedBytes: 100,
                                            removedCount: 1, restorable: items))
        // 跨会话重建后仍能读到 restorable
        let reloaded = HistoryStore(directory: tmpDir)
        let rec = try XCTUnwrap(reloaded.recent(1).first)
        XCTAssertTrue(rec.canUndo)
        XCTAssertEqual(rec.restorable.count, 1)
        // 撤销后清除 restorable，但保留统计
        reloaded.clearRestorable(id: id)
        let after = try XCTUnwrap(reloaded.recent(1).first)
        XCTAssertFalse(after.canUndo)
        XCTAssertEqual(reloaded.totalReclaimedAllTime, 100, "clearRestorable 不应影响累计统计")
    }

    /// 旧版 history.json（无 restorable 字段）必须能被容错解码
    func testDecodesLegacyRecordsWithoutRestorable() throws {
        let legacy = """
        [{"id":"\(UUID().uuidString)","date":0,"module":"旧记录","reclaimedBytes":42,"removedCount":1}]
        """
        try legacy.data(using: .utf8)!.write(to: tmpDir.appendingPathComponent("history.json"))
        let store = HistoryStore(directory: tmpDir)
        XCTAssertEqual(store.totalCleanups, 1)
        XCTAssertEqual(store.recent(1).first?.reclaimedBytes, 42)
        XCTAssertFalse(store.recent(1).first!.canUndo, "旧记录无 restorable，不可撤销")
    }
}
