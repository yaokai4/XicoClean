import Foundation
import XCTest
import Domain
@testable import Infrastructure

/// 端到端集成测试：真实文件移动的「扫描 → 清理 → 撤销」闭环，以及安全闸门。
/// 删除收据始终落在每个测试独占的临时 sandbox trash，绝不访问用户废纸篓。
final class CleaningRoundTripTests: XCTestCase {
    private let localFS = LocalFileSystemService()
    private let safety = DefaultSafetyEngine()

    private var runLocalSmokeTests: Bool {
        ProcessInfo.processInfo.environment["XICO_RUN_LOCAL_SMOKE_TESTS"] == "1"
    }

    private struct Fixture {
        let root: URL
        let content: URL
        let trash: URL
        let fs: SandboxedFileSystemService
        let engine: CleaningEngine
    }

    /// 构造独占临时根及其 sandbox trash；所有测试删除和恢复都限制在该根内。
    private func makeFixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("XicoIntegration-\(UUID().uuidString)")
        let content = root
            .appendingPathComponent("Library/Caches/XicoIntegrationTest-\(UUID().uuidString)")
        let trash = root.appendingPathComponent("SandboxTrash")
        try FileManager.default.createDirectory(at: content, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        let fs = SandboxedFileSystemService(allowedRoot: root, trashRoot: trash)
        return Fixture(root: root,
                       content: content,
                       trash: trash,
                       fs: fs,
                       engine: CleaningEngine(safety: safety, fs: fs))
    }

    func testTrashThenUndoRoundTrip() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let file = fixture.content.appendingPathComponent("junk.dat")
        let payload = Data(repeating: 0xAB, count: 256 * 1024)
        try payload.write(to: file)

        XCTAssertTrue(fixture.fs.exists(file))

        let item = CleanableItem(url: file, displayName: "junk.dat", size: Int64(payload.count))
        let report = await fixture.engine.execute(CleaningPlan(items: [item], intent: .trash))

        XCTAssertEqual(report.operation.status, .success)
        XCTAssertEqual(report.operation.counts.succeeded, 1)
        XCTAssertEqual(report.items.single?.itemID, item.id)
        XCTAssertEqual(report.items.single?.url, file)
        XCTAssertEqual(report.items.single?.disposition, .succeeded)
        XCTAssertEqual(report.items.single?.restorable?.originalURL, file)
        let receipt = try XCTUnwrap(report.items.single?.restorable?.trashedURL)
        XCTAssertTrue(receipt.standardizedFileURL.path.hasPrefix(
            fixture.trash.standardizedFileURL.path + "/"))
        XCTAssertFalse(fixture.fs.exists(file), "清理后原位置应不存在")

        let undo = await fixture.engine.undo(
            report.restorable,
            parentID: report.operation.id)
        XCTAssertEqual(undo.outcome.parentID, report.operation.id)
        XCTAssertEqual(undo.payload.restoredCount, 1)
        XCTAssertTrue(undo.payload.remaining.isEmpty)
        XCTAssertEqual(undo.payload.items.single?.restoredURL, file)
        XCTAssertTrue(fixture.fs.exists(file), "撤销后文件应被还原")
    }

    // MARK: 撤销边界（2026-07 审计：撤销失败此前被静默吞掉）

    /// sandbox trash 项在撤销前已消失 → undo 必须报告失败清单，不假装成功。
    func testUndoReportsFailureWhenTrashedItemGone() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let file = fixture.content.appendingPathComponent("junk.dat")
        try Data(repeating: 0xCD, count: 4096).write(to: file)

        let item = CleanableItem(url: file, displayName: "junk.dat", size: 4096)
        let report = await fixture.engine.execute(CleaningPlan(items: [item], intent: .trash))
        let receipt = try XCTUnwrap(report.items.single?.restorable)
        XCTAssertTrue(receipt.trashedURL.standardizedFileURL.path.hasPrefix(
            fixture.trash.standardizedFileURL.path + "/"))

        try FileManager.default.removeItem(at: receipt.trashedURL)

        let undo = await fixture.engine.undo(
            report.restorable,
            parentID: report.operation.id)
        XCTAssertEqual(undo.payload.restoredCount, 0)
        XCTAssertEqual(undo.outcome.status, .failure,
                       "sandbox trash 已空时 undo 不能假装成功")
        XCTAssertEqual(undo.payload.remaining.count, 1)
        XCTAssertNil(undo.payload.items.single?.restoredURL)
    }

    /// 原位已存在同名项 → 恢复到不冲突的新名字，绝不覆盖用户既有文件。
    func testUndoRestoresToUniqueNameOnCollision() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let file = fixture.content.appendingPathComponent("dup.txt")
        try Data("original".utf8).write(to: file)

        let item = CleanableItem(url: file, displayName: "dup.txt", size: 8)
        let report = await fixture.engine.execute(CleaningPlan(items: [item], intent: .trash))
        XCTAssertEqual(report.items.single?.disposition, .succeeded)
        XCTAssertFalse(fixture.fs.exists(file))

        try Data("newer".utf8).write(to: file)

        let undo = await fixture.engine.undo(
            report.restorable,
            parentID: report.operation.id)
        XCTAssertEqual(undo.payload.restoredCount, 1)
        XCTAssertTrue(undo.payload.remaining.isEmpty)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "newer")
        let restoredCopies = (try FileManager.default.contentsOfDirectory(atPath: fixture.content.path))
            .filter { $0.contains("恢复") }
        XCTAssertEqual(restoredCopies.count, 1, "冲突时应生成一个不覆盖的恢复副本")
        let expectedRestoredURL = fixture.content.appendingPathComponent("dup (恢复 1).txt")
        XCTAssertEqual(undo.payload.items.single?.restoredURL, expectedRestoredURL)
        XCTAssertTrue(fixture.fs.exists(expectedRestoredURL))
    }

    /// The production filesystem adapter must report the destination it actually selected rather
    /// than silently collapsing a collision restore back to the stale original receipt path.
    func testLocalFileSystemRestoreReturnsActualUniqueURLOnCollision() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("XicoLocalRestore-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let content = root.appendingPathComponent("Content")
        let trash = root.appendingPathComponent("SandboxTrash")
        try FileManager.default.createDirectory(at: content, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        let original = content.appendingPathComponent("dup.txt")
        let trashed = trash.appendingPathComponent("dup.txt")
        try Data("newer".utf8).write(to: original)
        try Data("original".utf8).write(to: trashed)
        let expected = content.appendingPathComponent("dup (恢复 1).txt")

        let actual = try localFS.restore(RestorableItem(
            originalURL: original,
            trashedURL: trashed))

        XCTAssertEqual(actual, expected)
        XCTAssertEqual(try String(contentsOf: original, encoding: .utf8), "newer")
        XCTAssertEqual(try String(contentsOf: actual, encoding: .utf8), "original")
        XCTAssertFalse(FileManager.default.fileExists(atPath: trashed.path))
    }

    /// 双重撤销：第二次 undo 应把（已经放回的）项判为失败，而不是崩溃或重复。
    func testDoubleUndoIsSafe() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let file = fixture.content.appendingPathComponent("junk.dat")
        try Data(repeating: 0x11, count: 4096).write(to: file)

        let item = CleanableItem(url: file, displayName: "junk.dat", size: 4096)
        let report = await fixture.engine.execute(CleaningPlan(items: [item], intent: .trash))

        let first = await fixture.engine.undo(
            report.restorable,
            parentID: report.operation.id)
        XCTAssertTrue(first.payload.remaining.isEmpty)
        let second = await fixture.engine.undo(
            report.restorable,
            parentID: report.operation.id)
        XCTAssertEqual(second.payload.restoredCount, 0)
        XCTAssertEqual(second.payload.remaining.count, 1)
        XCTAssertTrue(fixture.fs.exists(file), "文件仍在原位（第一次已恢复）")
    }

    func testCleaningRefusesProtectedPath() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let protectedItem = CleanableItem(
            url: URL(fileURLWithPath: "/System/Library/Xico-should-never-touch"),
            displayName: "protected", size: 1024, safety: .risky, isSelected: true)

        let report = await fixture.engine.execute(
            CleaningPlan(items: [protectedItem], intent: .trash))
        XCTAssertEqual(report.operation.status, .failure)
        XCTAssertEqual(report.operation.counts.skipped, 1)
        XCTAssertEqual(report.items.count, 1)
        if case let .skipped(issue) = report.items.single?.disposition {
            XCTAssertEqual(issue.code, "cleaning.safety.denied")
            XCTAssertEqual(issue.subjectID, report.items.single?.requestID.uuidString)
        } else {
            XCTFail("受保护路径应产生 skipped item fact")
        }
        XCTAssertTrue(fixture.fs.mutatedPaths.isEmpty)
    }

    func testSystemJunkScannerRunsAgainstRealFS() async throws {
        guard runLocalSmokeTests else {
            throw XCTSkip("Set XICO_RUN_LOCAL_SMOKE_TESTS=1 to scan the local machine.")
        }
        let scanner = SystemJunkScanner(
            definitions: DefinitionsLibrary.bundled().definitions,
            fs: localFS,
            safety: safety)
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
        try FileManager.default.createDirectory(at: root.appendingPathComponent("A"),
                                                withIntermediateDirectories: true)
        try Data(repeating: 1, count: 128 * 1024)
            .write(to: root.appendingPathComponent("A/file.bin"))

        let scanner = DiskTreeScanner(fs: localFS)
        let tree = await scanner.scan(root)
        XCTAssertEqual(tree.url.lastPathComponent, root.lastPathComponent)
        XCTAssertGreaterThan(tree.size, 0)
        print("ℹ️ 空间透镜：\(tree.name) = \(tree.size.formattedBytes)，\(tree.children.count) 个子块")
    }
}

private extension Array {
    var single: Element? { count == 1 ? first : nil }
}

private enum SandboxedFileSystemError: Error {
    case outsideAllowedRoot
    case receiptOutsideTrashRoot
}

private final class SandboxedFileSystemService: @unchecked Sendable, FileSystemService {
    private struct State {
        var attemptedPaths: [String] = []
        var mutatedPaths: [String] = []
        var receiptCounter = 0
    }

    private let local = LocalFileSystemService()
    private let allowedRoot: URL
    private let trashRoot: URL
    private let lock = NSLock()
    private var state = State()

    init(allowedRoot: URL, trashRoot: URL) {
        self.allowedRoot = allowedRoot.standardizedFileURL
        self.trashRoot = trashRoot.standardizedFileURL
    }

    func exists(_ url: URL) -> Bool {
        recordAttempt(url)
        return local.exists(url)
    }

    func contentsOfDirectory(_ url: URL) -> [URL] {
        recordAttempt(url)
        return local.contentsOfDirectory(url)
    }

    func allocatedSize(of url: URL) -> Int64 {
        recordAttempt(url)
        return local.allocatedSize(of: url)
    }

    func entry(for url: URL) -> FileEntry? {
        recordAttempt(url)
        return local.entry(for: url)
    }

    func trash(_ url: URL) throws -> URL {
        try requireInsideAllowedRoot(url)
        let counter = recordMutationAndNextCounter(url)
        let destination = trashRoot.appendingPathComponent(
            "\(counter)-\(UUID().uuidString)-\(url.lastPathComponent)")
        try requireInsideTrashRoot(destination)
        try FileManager.default.moveItem(at: url, to: destination)
        return destination
    }

    func remove(_ url: URL) throws {
        try requireInsideAllowedRoot(url)
        recordMutation(url)
        try FileManager.default.removeItem(at: url)
    }

    func restore(_ item: RestorableItem) throws -> URL {
        try requireInsideAllowedRoot(item.originalURL)
        try requireInsideTrashRoot(item.trashedURL)
        recordMutation(item.originalURL)
        let parent = item.originalURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        var destination = item.originalURL
        if FileManager.default.fileExists(atPath: destination.path) {
            let base = item.originalURL.deletingPathExtension().lastPathComponent
            let ext = item.originalURL.pathExtension
            var suffix = 1
            repeat {
                let name = ext.isEmpty
                    ? "\(base) (恢复 \(suffix))"
                    : "\(base) (恢复 \(suffix)).\(ext)"
                destination = parent.appendingPathComponent(name)
                suffix += 1
            } while FileManager.default.fileExists(atPath: destination.path)
        }
        try FileManager.default.moveItem(at: item.trashedURL, to: destination)
        return destination
    }

    func volumeCapacity(for url: URL) -> VolumeCapacity? {
        recordAttempt(url)
        return local.volumeCapacity(for: url)
    }

    func deepEnumerate(_ url: URL, includeFiles: Bool) -> AsyncStream<FileEntry> {
        recordAttempt(url)
        return local.deepEnumerate(url, includeFiles: includeFiles)
    }

    var mutatedPaths: [String] {
        synchronized { $0.mutatedPaths }
    }

    private func requireInsideAllowedRoot(_ url: URL) throws {
        guard Self.isDescendant(url.standardizedFileURL, of: allowedRoot) else {
            throw SandboxedFileSystemError.outsideAllowedRoot
        }
    }

    private func requireInsideTrashRoot(_ url: URL) throws {
        guard Self.isDescendant(url.standardizedFileURL, of: trashRoot) else {
            throw SandboxedFileSystemError.receiptOutsideTrashRoot
        }
    }

    private static func isDescendant(_ url: URL, of root: URL) -> Bool {
        let path = url.standardizedFileURL.path
        let rootPath = root.standardizedFileURL.path
        return path == rootPath || path.hasPrefix(rootPath + "/")
    }

    private func recordAttempt(_ url: URL) {
        synchronized { $0.attemptedPaths.append(url.standardizedFileURL.path) }
    }

    private func recordMutation(_ url: URL) {
        synchronized {
            let path = url.standardizedFileURL.path
            $0.attemptedPaths.append(path)
            $0.mutatedPaths.append(path)
        }
    }

    private func recordMutationAndNextCounter(_ url: URL) -> Int {
        synchronized {
            let path = url.standardizedFileURL.path
            $0.attemptedPaths.append(path)
            $0.mutatedPaths.append(path)
            $0.receiptCounter += 1
            return $0.receiptCounter
        }
    }

    private func synchronized<T>(_ body: (inout State) -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body(&state)
    }
}
