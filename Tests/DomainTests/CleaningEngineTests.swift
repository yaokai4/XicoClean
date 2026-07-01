import XCTest
@testable import Domain

final class CleaningEngineTests: XCTestCase {
    private struct AllowAllSafety: SafetyEngine {
        func verify(_ url: URL, intent: DeleteIntent) -> SafetyVerdict { .allow }
    }

    private struct MemoryFS: FileSystemService {
        let existing: Set<String>

        func exists(_ url: URL) -> Bool { existing.contains(url.path) }
        func contentsOfDirectory(_ url: URL) -> [URL] { [] }
        func allocatedSize(of url: URL) -> Int64 { 0 }
        func entry(for url: URL) -> FileEntry? { nil }
        func trash(_ url: URL) throws -> URL { url }
        func remove(_ url: URL) throws {}
        func restore(_ item: RestorableItem) throws {}
        func volumeCapacity(for url: URL) -> VolumeCapacity? { nil }
        func deepEnumerate(_ url: URL, includeFiles: Bool) -> AsyncStream<FileEntry> {
            AsyncStream { $0.finish() }
        }
    }

    private actor FakePrivileged: PrivilegedCleaningService {
        private(set) var removed: [URL] = []

        func removeProtected(_ urls: [URL]) async -> PrivilegedRemovalReport {
            removed.append(contentsOf: urls)
            return PrivilegedRemovalReport(freedBytes: 123, failures: [])
        }

        func snapshot() -> [URL] { removed }
    }

    func testPrivilegedItemsRequireHelper() async {
        let url = URL(fileURLWithPath: "/Library/Caches/XicoTest")
        let fs = MemoryFS(existing: [url.path])
        let engine = CleaningEngine(safety: AllowAllSafety(), fs: fs)
        let item = CleanableItem(url: url, displayName: "XicoTest", size: 10, requiresHelper: true)

        let report = await engine.execute(CleaningPlan(items: [item], intent: .permanent))

        XCTAssertEqual(report.removedCount, 0)
        XCTAssertEqual(report.failures.map(\.url), [url])
    }

    func testPrivilegedItemsUseInjectedHelperForPermanentDelete() async {
        let url = URL(fileURLWithPath: "/Library/Caches/XicoTest")
        let fs = MemoryFS(existing: [url.path])
        let helper = FakePrivileged()
        let engine = CleaningEngine(safety: AllowAllSafety(), fs: fs, privileged: helper)
        let item = CleanableItem(url: url, displayName: "XicoTest", size: 10, requiresHelper: true)

        let report = await engine.execute(CleaningPlan(items: [item], intent: .permanent))

        XCTAssertEqual(report.removedCount, 1)
        XCTAssertEqual(report.reclaimedBytes, 123)
        let removed = await helper.snapshot()
        XCTAssertEqual(removed, [url])
    }

    func testPrivilegedItemsDoNotPretendToBeTrashable() async {
        let url = URL(fileURLWithPath: "/Library/Caches/XicoTest")
        let fs = MemoryFS(existing: [url.path])
        let helper = FakePrivileged()
        let engine = CleaningEngine(safety: AllowAllSafety(), fs: fs, privileged: helper)
        let item = CleanableItem(url: url, displayName: "XicoTest", size: 10, requiresHelper: true)

        let report = await engine.execute(CleaningPlan(items: [item], intent: .trash))

        XCTAssertEqual(report.removedCount, 0)
        let removed = await helper.snapshot()
        XCTAssertTrue(removed.isEmpty)
        XCTAssertEqual(report.failures.map(\.url), [url])
    }
}
