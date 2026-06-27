import XCTest
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
}
