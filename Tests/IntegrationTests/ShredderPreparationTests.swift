import XCTest
import Domain
@testable import Infrastructure
#if canImport(Darwin)
import Darwin
#endif

/// Task 2: shredder read-only preparation phase (SHR-01…06). All fixtures live in a
/// task-specific temporary directory (safe, disposable); no real user data is touched.
final class ShredderPreparationTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("xico-shredprep-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    // MARK: - Fakes

    private struct DenyingSafety: SafetyEngine {
        let deniedSuffix: String
        func verify(_ url: URL, intent: DeleteIntent) -> SafetyVerdict {
            url.path.hasSuffix(deniedSuffix) ? .deny(reason: "test-denied") : .allow
        }
    }

    private final class PathRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var paths: [String] = []
        func record(_ p: String) { lock.lock(); paths.append(p); lock.unlock() }
        func all() -> [String] { lock.lock(); defer { lock.unlock() }; return paths }
    }
    private struct RecordingSafety: SafetyEngine {
        let recorder: PathRecorder
        func verify(_ url: URL, intent: DeleteIntent) -> SafetyVerdict {
            recorder.record(url.standardizedFileURL.path); return .allow
        }
    }

    private final class MutationFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        func flag() { lock.lock(); value = true; lock.unlock() }
        var mutated: Bool { lock.lock(); defer { lock.unlock() }; return value }
    }
    /// Delegates read-only calls to the real syscalls; flags any mutating call so a
    /// test can assert the preparation phase performs no writes or unlinks.
    private struct SpySyscalls: FileSyscalls {
        let backing = SystemFileSyscalls()
        let mutation: MutationFlag
        func openDirectory(path: String) -> Int32 { backing.openDirectory(path: path) }
        func openChildDirectory(parentFD: Int32, name: String) -> Int32 { backing.openChildDirectory(parentFD: parentFD, name: name) }
        func listChildren(dirFD: Int32) -> [String]? { backing.listChildren(dirFD: dirFD) }
        func statChild(parentFD: Int32, name: String) -> FileStat? { backing.statChild(parentFD: parentFD, name: name) }
        func statOpen(fd: Int32) -> FileStat? { backing.statOpen(fd: fd) }
        func closeDescriptor(_ fd: Int32) { backing.closeDescriptor(fd) }
        func openRegularForWrite(parentFD: Int32, name: String) -> Int32 { mutation.flag(); return -1 }
        func pwrite(fd: Int32, bytes: UnsafeRawBufferPointer, offset: Int64) -> WriteResult { mutation.flag(); return .failed(errno: 0) }
        func fsync(fd: Int32) -> Int32 { mutation.flag(); return -1 }
        func ftruncate(fd: Int32, length: Int64) -> Int32 { mutation.flag(); return -1 }
        func unlinkChild(parentFD: Int32, name: String, removeDir: Bool) -> Int32 { mutation.flag(); return -1 }
    }

    // MARK: - Fixture helpers

    @discardableResult
    private func file(_ name: String, in parent: URL, bytes: Int = 64) throws -> URL {
        let url = parent.appendingPathComponent(name)
        try Data(repeating: 0x41, count: bytes).write(to: url)
        return url
    }
    @discardableResult
    private func subdir(_ name: String, in parent: URL) throws -> URL {
        let url = parent.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    private func fifo(_ name: String, in parent: URL) throws -> URL {
        let url = parent.appendingPathComponent(name)
        guard mkfifo(url.path, 0o644) == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        return url
    }
    private func hardLink(to target: URL, named name: String, in parent: URL) throws -> URL {
        let url = parent.appendingPathComponent(name)
        guard link(target.path, url.path) == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        return url
    }

    private func manifest(_ d: ShredRootDisposition) -> [ShredManifestEntry]? {
        if case .accepted(let m) = d { return m }; return nil
    }
    private func rejection(_ d: ShredRootDisposition) -> ShredRejectionReason? {
        if case .rejected(let r) = d { return r }; return nil
    }

    // MARK: - Tests

    func testPrepareBuildsBoundedIdentityManifestForDirectoryTree() throws {   // SHR-05
        let root = try subdir("root", in: dir)
        try file("a.txt", in: root)
        let sub = try subdir("sub", in: root)
        try file("b.txt", in: sub)

        let svc = ShredderService(safety: DefaultSafetyEngine())
        let result = svc.prepare([root])[0]
        let m = try XCTUnwrap(manifest(result.disposition))
        let paths = Set(m.map { ($0.canonicalPath as NSString).lastPathComponent })
        XCTAssertEqual(paths, ["a.txt", "b.txt", "sub", "root"])
        // The directory entries record after their children (children removed first).
        XCTAssertGreaterThan(m.firstIndex { $0.canonicalPath.hasSuffix("/root") }!,
                             m.firstIndex { $0.canonicalPath.hasSuffix("/a.txt") }!)
        XCTAssertTrue(m.contains { $0.canonicalPath.hasSuffix("/sub") && $0.isDirectory })
    }

    func testPrepareRejectsRootWhoseChildIsRedLinedProtected() throws {   // SHR-06
        let root = try subdir("root", in: dir)
        try file("good.txt", in: root)
        try file("bad.txt", in: root)
        let svc = ShredderService(safety: DenyingSafety(deniedSuffix: "/bad.txt"))
        let result = svc.prepare([root])[0]
        XCTAssertEqual(rejection(result.disposition), .safetyDenied)
    }

    func testPrepareRejectsRootWhoseChildIsUnrecognizedType() throws {   // SHR-06 / SHR-03
        let root = try subdir("root", in: dir)
        try file("ok.txt", in: root)
        _ = try fifo("pipe", in: root)
        let svc = ShredderService(safety: DefaultSafetyEngine())
        let result = svc.prepare([root])[0]
        XCTAssertEqual(rejection(result.disposition), .unrecognizedType)
    }

    func testPrepareRefusesRegularFileWithMultipleHardLinks() throws {   // SHR-04
        let original = try file("data.bin", in: dir)
        _ = try hardLink(to: original, named: "data.link", in: dir)   // st_nlink == 2
        let svc = ShredderService(safety: DefaultSafetyEngine())
        let result = svc.prepare([original])[0]
        XCTAssertEqual(rejection(result.disposition), .hardLinked)
    }

    func testPrepareRefusesFifoSocketAndDeviceEntries() throws {   // SHR-03
        let pipe = try fifo("solo-pipe", in: dir)
        let svc = ShredderService(safety: DefaultSafetyEngine())
        let result = svc.prepare([pipe])[0]
        XCTAssertEqual(rejection(result.disposition), .unrecognizedType)
    }

    func testPrepareDoesNotFollowSymlinksAndManifestsLinkItself() throws {   // SHR-02
        let precious = try subdir("precious", in: dir)
        try file("keep.txt", in: precious)
        let linkURL = dir.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: linkURL, withDestinationURL: precious)

        let svc = ShredderService(safety: DefaultSafetyEngine())
        let m = try XCTUnwrap(manifest(svc.prepare([linkURL])[0].disposition))
        XCTAssertEqual(m.count, 1)
        XCTAssertTrue(m[0].canonicalPath.hasSuffix("/link"))
        XCTAssertFalse(m[0].isDirectory)
        // The symlink target's contents were never enumerated.
        XCTAssertFalse(m.contains { $0.canonicalPath.hasSuffix("keep.txt") })
    }

    func testPrepareRunsSafetyEngineOnEveryTopLevelAndChild() throws {   // SHR-01
        let root = try subdir("root", in: dir)
        try file("a.txt", in: root)
        let sub = try subdir("sub", in: root)
        try file("b.txt", in: sub)
        let recorder = PathRecorder()

        let svc = ShredderService(safety: RecordingSafety(recorder: recorder))
        _ = svc.prepare([root])

        let verified = Set(recorder.all().map { ($0 as NSString).lastPathComponent })
        XCTAssertTrue(verified.isSuperset(of: ["root", "a.txt", "sub", "b.txt"]),
                      "every top-level and child must pass SafetyEngine; got \(verified)")
    }

    func testPrepareExceedingEntryBudgetRequiresSplitAndDoesNotExecute() throws {   // SHR-05
        let root = try subdir("root", in: dir)
        for i in 0..<6 { try file("f\(i).txt", in: root) }
        let mutation = MutationFlag()
        let svc = ShredderService(safety: DefaultSafetyEngine(),
                                  syscalls: SpySyscalls(mutation: mutation),
                                  maxManifestEntries: 2)
        let result = svc.prepare([root])[0]
        guard case .requiresSplit = result.disposition else {
            return XCTFail("expected requiresSplit, got \(result.disposition)")
        }
        XCTAssertFalse(mutation.mutated, "preparation must not execute (no writes/unlinks)")
    }

    func testPreparePerformsNoWritesOrUnlinks() throws {
        let root = try subdir("root", in: dir)
        try file("a.txt", in: root)
        try file("b.txt", in: try subdir("sub", in: root))
        let mutation = MutationFlag()
        let svc = ShredderService(safety: DefaultSafetyEngine(), syscalls: SpySyscalls(mutation: mutation))
        _ = svc.prepare([root])
        XCTAssertFalse(mutation.mutated)
        // Fixtures are still intact after preparation.
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("a.txt").path))
    }

    func testPreparedManifestCarriesPerTargetLocalFileIdentityWithHardLinkCount() throws {
        let f = try file("secret.txt", in: dir, bytes: 4_096)
        let svc = ShredderService(safety: DefaultSafetyEngine())
        let m = try XCTUnwrap(manifest(svc.prepare([f])[0].disposition))
        let entry = try XCTUnwrap(m.first)
        XCTAssertEqual(entry.identity.hardLinkCount, 1)
        XCTAssertEqual(entry.identity.size, 4_096)
        XCTAssertTrue(entry.identity.inode != 0)
    }
}
