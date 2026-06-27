import XCTest
@testable import Infrastructure

final class HistoryStoreTests: XCTestCase {

    func testRecordsAccumulateAndPersist() throws {
        let store = HistoryStore()
        store.clear()
        XCTAssertEqual(store.totalCleanups, 0)
        XCTAssertEqual(store.totalReclaimedAllTime, 0)

        store.record(module: "系统垃圾", reclaimedBytes: 1_000, removedCount: 3)
        store.record(module: "废纸篓", reclaimedBytes: 2_000, removedCount: 1)

        XCTAssertEqual(store.totalCleanups, 2)
        XCTAssertEqual(store.totalReclaimedAllTime, 3_000)
        XCTAssertEqual(store.recent(1).first?.module, "废纸篓", "最近记录应排在最前")

        // 重新构造应从磁盘加载（持久化）
        let reloaded = HistoryStore()
        XCTAssertGreaterThanOrEqual(reloaded.totalReclaimedAllTime, 3_000)

        store.clear()
        XCTAssertEqual(HistoryStore().totalCleanups, 0, "清空后应持久化为空")
    }

    func testIgnoresEmptyRecords() {
        let store = HistoryStore()
        store.clear()
        store.record(module: "x", reclaimedBytes: 0, removedCount: 0)
        XCTAssertEqual(store.totalCleanups, 0, "零释放零删除不应记录")
        store.clear()
    }
}
