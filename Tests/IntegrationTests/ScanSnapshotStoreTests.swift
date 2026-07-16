import XCTest
import Domain
@testable import Infrastructure

final class ScanSnapshotStoreTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("xico-index-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testOneParentBuildServicesConcurrentChildRequests() async throws {
        let a = root.appendingPathComponent("A", isDirectory: true)
        let b = root.appendingPathComponent("B", isDirectory: true)
        try FileManager.default.createDirectory(at: a, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: b, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 1_024).write(to: a.appendingPathComponent("a.bin"))
        try Data(repeating: 2, count: 2_048).write(to: b.appendingPathComponent("b.bin"))

        let store = ScanSnapshotStore(cacheTTL: 60)
        store.prewarm(root)
        async let aSnapshot = store.snapshot(for: a)
        async let bSnapshot = store.snapshot(for: b)
        let (left, right) = await (aSnapshot, bSnapshot)

        XCTAssertEqual(left.entries.map(\.url.lastPathComponent), ["a.bin"])
        XCTAssertEqual(right.entries.map(\.url.lastPathComponent), ["b.bin"])
        let diagnostics = store.diagnostics()
        XCTAssertEqual(diagnostics.buildsStarted, 1, "父子请求必须共享同一次目录遍历")
        XCTAssertGreaterThanOrEqual(diagnostics.sharedJobHits + diagnostics.cacheHits, 2)
    }

    func testIndexIncludesHiddenFilesButDoesNotEnterManagedPackages() async throws {
        try Data("hidden".utf8).write(to: root.appendingPathComponent(".hidden.bin"))
        let library = root.appendingPathComponent("Photos Library.photoslibrary", isDirectory: true)
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        try Data("photo".utf8).write(to: library.appendingPathComponent("original.jpg"))

        let snapshot = await ScanSnapshotStore().snapshot(for: root)
        let names = Set(snapshot.entries.map(\.url.lastPathComponent))
        XCTAssertTrue(names.contains(".hidden.bin"), "底层索引应完整覆盖隐藏文件")
        XCTAssertFalse(names.contains("original.jpg"), "不得深入 Photos 管理的图库包")
        XCTAssertTrue(snapshot.coverage.hiddenFilesIncluded)
        XCTAssertEqual(snapshot.coverage.excludedByPolicy, 1)
    }

    func testSparseFilePreservesLogicalAndPhysicalSizeSeparately() async throws {
        let sparse = root.appendingPathComponent("sparse.bin")
        FileManager.default.createFile(atPath: sparse.path, contents: Data([0]))
        let handle = try FileHandle(forWritingTo: sparse)
        try handle.truncate(atOffset: 64 * 1_024 * 1_024)
        try handle.close()

        let snapshot = await ScanSnapshotStore().snapshot(for: root)
        let entry = try XCTUnwrap(snapshot.entries.first { $0.url.lastPathComponent == "sparse.bin" })
        XCTAssertEqual(entry.logicalBytes, 64 * 1_024 * 1_024)
        XCTAssertLessThan(entry.allocatedBytes, entry.logicalBytes)
    }

    func testDuplicateResultCarriesExactEvidenceAndCoverage() async throws {
        let payload = Data(repeating: 0x5a, count: 128 * 1_024)
        try payload.write(to: root.appendingPathComponent("one.bin"))
        try payload.write(to: root.appendingPathComponent("two.bin"))
        let store = ScanSnapshotStore()
        let scanner = DuplicatesScanner(
            fs: LocalFileSystemService(),
            safety: DefaultSafetyEngine(home: root),
            root: root,
            minSizeBytes: 1,
            snapshotStore: store,
            workLimiter: ScanWorkLimiter(limit: 2)
        )

        let result = await scanner.scan { _ in }
        XCTAssertEqual(result.groups.count, 1)
        XCTAssertEqual(result.coverage?.filesVisited, 2)
        let item = try XCTUnwrap(result.groups.first?.items.first)
        XCTAssertEqual(item.assessment.confidence, 1)
        XCTAssertTrue(item.assessment.evidence.contains { $0.kind == .exactContent })
        XCTAssertFalse(item.isSelected, "重复的是用户文件，仍必须人工选择")
    }

    func testThousandFileSnapshotStaysWithinRegressionBudget() async throws {
        for index in 0..<1_000 {
            try Data([UInt8(index & 0xff)]).write(
                to: root.appendingPathComponent("f-\(index).bin"))
        }
        let started = Date()
        let snapshot = await ScanSnapshotStore().snapshot(for: root)
        let elapsed = Date().timeIntervalSince(started)
        XCTAssertEqual(snapshot.coverage.filesVisited, 1_000)
        XCTAssertLessThan(elapsed, 3, "千文件元数据索引不应退化为逐文件高延迟 stat")
    }

    func testDeepScannerConsumesPrewarmedSnapshotWithoutSecondTraversal() async throws {
        let partial = root.appendingPathComponent("abandoned.part")
        try Data(repeating: 0x42, count: 8_192).write(to: partial)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-10 * 86_400)],
            ofItemAtPath: partial.path)

        let store = ScanSnapshotStore(cacheTTL: 60)
        store.prewarm(root)
        let scanner = DeepScanner(
            fs: LocalFileSystemService(),
            safety: DefaultSafetyEngine(home: root),
            home: root,
            snapshotStore: store)

        let result = try await scanner.scan { _ in }

        XCTAssertEqual(store.diagnostics().buildsStarted, 1,
                       "深度扫描必须消费预热快照，不能另起一次全目录遍历")
        XCTAssertEqual(result.coverage?.filesVisited, 1)
        let item = try XCTUnwrap(result.groups.first?.items.first)
        XCTAssertEqual(item.assessment.ruleID, "stale-partial-download")
        XCTAssertTrue(item.assessment.qualifiesForAutomaticSelection)
    }
}
