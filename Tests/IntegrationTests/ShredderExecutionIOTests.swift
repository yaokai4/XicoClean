import XCTest
import Domain
@testable import Infrastructure
#if canImport(Darwin)
import Darwin
#endif

/// Task 3: shredder execution I/O, cancellation and honest failure marking (SHR-09..15).
/// Driven by an in-memory fake `FileSyscalls` so short writes / EINTR / ENOSPC / EIO /
/// fsync failures and identity drift are deterministic — no real files are touched.
final class ShredderExecutionIOTests: XCTestCase {

    private struct AllowAllSafety: SafetyEngine {
        func verify(_ url: URL, intent: DeleteIntent) -> SafetyVerdict { .allow }
    }

    /// Programmable fake: read-only calls return canned values; `pwrite`/`fsync` are
    /// scripted; `statChild`/`statOpen` are queues so classification, C1 recheck and the
    /// pre-unlink recheck can each return distinct identities.
    private final class FakeSyscalls: FileSyscalls, @unchecked Sendable {
        private let lock = NSLock()
        var openDirFD: Int32 = 100
        var openChildDirFD: Int32 = 101
        var openRegularFD: Int32 = 200
        var childrenResult: [String]? = []
        var statChildQueue: [FileStat?] = []
        var statOpenQueue: [FileStat?] = []
        var pwriteQueue: [WriteResult] = []
        var fsyncResult: Int32 = 0

        private var _writes = 0
        private var _writtenBytes = 0
        private var _fsyncs = 0
        private var _unlinks: [(name: String, dir: Bool)] = []

        var writes: Int { lock.lock(); defer { lock.unlock() }; return _writes }
        var writtenBytes: Int { lock.lock(); defer { lock.unlock() }; return _writtenBytes }
        var fsyncs: Int { lock.lock(); defer { lock.unlock() }; return _fsyncs }
        var unlinkNames: [String] { lock.lock(); defer { lock.unlock() }; return _unlinks.map { $0.name } }

        func openDirectory(path: String) -> Int32 { openDirFD }
        func openChildDirectory(parentFD: Int32, name: String) -> Int32 { openChildDirFD }
        func openRegularForWrite(parentFD: Int32, name: String) -> Int32 { openRegularFD }
        func listChildren(dirFD: Int32) -> [String]? { childrenResult }
        func statChild(parentFD: Int32, name: String) -> FileStat? {
            lock.lock(); defer { lock.unlock() }
            return statChildQueue.isEmpty ? nil : statChildQueue.removeFirst()
        }
        func statOpen(fd: Int32) -> FileStat? {
            lock.lock(); defer { lock.unlock() }
            return statOpenQueue.isEmpty ? nil : statOpenQueue.removeFirst()
        }
        func pwrite(fd: Int32, bytes: UnsafeRawBufferPointer, offset: Int64) -> WriteResult {
            lock.lock(); defer { lock.unlock() }
            _writes += 1
            let r: WriteResult = pwriteQueue.isEmpty ? .wrote(bytes.count) : pwriteQueue.removeFirst()
            if case .wrote(let w) = r, w > 0 { _writtenBytes += w }
            return r
        }
        func fsync(fd: Int32) -> Int32 { lock.lock(); _fsyncs += 1; lock.unlock(); return fsyncResult }
        func ftruncate(fd: Int32, length: Int64) -> Int32 { 0 }
        func unlinkChild(parentFD: Int32, name: String, removeDir: Bool) -> Int32 {
            lock.lock(); _unlinks.append((name, removeDir)); lock.unlock(); return 0
        }
        func closeDescriptor(_ fd: Int32) {}
    }

    private func stat(inode: UInt64, nlink: UInt64 = 1, size: Int64 = 1_024, dir: Bool = false) -> FileStat {
        let mode = UInt32(dir ? S_IFDIR : S_IFREG) | 0o644
        return FileStat(device: 1, inode: inode, mode: mode, size: size, mtimeNanoseconds: 0, hardLinkCount: nlink)
    }
    private let mb = 1 << 20

    private func service(_ fake: FakeSyscalls, passes: Int = 1) -> ShredderService {
        ShredderService(safety: AllowAllSafety(), passes: passes, syscalls: fake)
    }
    private let target = URL(fileURLWithPath: "/tmp/xico/target")

    private func first(_ payload: ShredderPayload) -> ShredderItemResult { payload.items[0] }
    private func isSucceeded(_ d: OperationDisposition) -> Bool { if case .succeeded = d { return true }; return false }
    private func isFailed(_ d: OperationDisposition) -> Bool { if case .failed = d { return true }; return false }
    private func isSkipped(_ d: OperationDisposition) -> Bool { if case .skipped = d { return true }; return false }
    private func isCancelled(_ d: OperationDisposition) -> Bool { if case .cancelled = d { return true }; return false }

    // MARK: - SHR-09 precise pwrite loop

    func testPwriteLoopAdvancesOffsetByActualBytesOnShortWrite() async throws {
        let fake = FakeSyscalls()
        fake.statChildQueue = [stat(inode: 7, size: Int64(2 * mb)), stat(inode: 7, size: Int64(2 * mb))]
        fake.statOpenQueue = [stat(inode: 7, size: Int64(2 * mb))]
        // chunk0 = two short writes (512K + 512K), chunk1 = one full write (1M).
        fake.pwriteQueue = [.wrote(mb / 2), .wrote(mb / 2), .wrote(mb)]
        let payload = await service(fake).execute([target])
        XCTAssertTrue(isSucceeded(first(payload).disposition))
        XCTAssertEqual(fake.writtenBytes, 2 * mb)   // exactly the file size, no double count
        XCTAssertEqual(fake.writes, 3)
        XCTAssertEqual(fake.unlinkNames, ["target"])
    }

    func testPwriteRetriesOnEINTRWithoutDoubleCountingBytes() async throws {
        let fake = FakeSyscalls()
        fake.statChildQueue = [stat(inode: 7, size: Int64(2 * mb)), stat(inode: 7, size: Int64(2 * mb))]
        fake.statOpenQueue = [stat(inode: 7, size: Int64(2 * mb))]
        fake.pwriteQueue = [.failed(errno: EINTR), .wrote(mb), .wrote(mb)]
        let payload = await service(fake).execute([target])
        XCTAssertTrue(isSucceeded(first(payload).disposition))
        XCTAssertEqual(fake.writtenBytes, 2 * mb)   // EINTR retried, not counted
    }

    // MARK: - SHR-10 per-pass fsync

    func testEachPassMustFullyWriteAndSuccessfullyFsyncBeforeNextPass() async throws {
        let fake = FakeSyscalls()
        fake.statChildQueue = [stat(inode: 7, size: Int64(mb)), stat(inode: 7, size: Int64(mb))]
        fake.statOpenQueue = [stat(inode: 7, size: Int64(mb))]
        let payload = await service(fake, passes: 2).execute([target])
        XCTAssertTrue(isSucceeded(first(payload).disposition))
        XCTAssertEqual(fake.fsyncs, 2)   // one fsync per pass
        XCTAssertEqual(fake.writes, 2)
    }

    func testFsyncFailureBlocksUnlinkAndMarksFailedPossiblyModified() async throws {
        let fake = FakeSyscalls()
        fake.statChildQueue = [stat(inode: 7, size: Int64(mb))]
        fake.statOpenQueue = [stat(inode: 7, size: Int64(mb))]
        fake.fsyncResult = -1
        let result = first(await service(fake).execute([target]))
        XCTAssertTrue(isFailed(result.disposition))
        XCTAssertEqual(result.mutation, .possiblyChanged)
        XCTAssertTrue(fake.unlinkNames.isEmpty, "fsync failure must not unlink")
    }

    // MARK: - SHR-13 I/O failure never unlinks

    func testENOSPCDuringOverwriteNeverUnlinksAndMarksFailedPossiblyModified() async throws {
        let fake = FakeSyscalls()
        fake.statChildQueue = [stat(inode: 7, size: Int64(mb))]
        fake.statOpenQueue = [stat(inode: 7, size: Int64(mb))]
        fake.pwriteQueue = [.failed(errno: ENOSPC)]
        let result = first(await service(fake).execute([target]))
        XCTAssertTrue(isFailed(result.disposition))
        XCTAssertEqual(result.mutation, .possiblyChanged)
        XCTAssertTrue(fake.unlinkNames.isEmpty)
    }

    func testEIODuringOverwriteNeverUnlinksAndMarksFailedPossiblyModified() async throws {
        let fake = FakeSyscalls()
        fake.statChildQueue = [stat(inode: 7, size: Int64(mb))]
        fake.statOpenQueue = [stat(inode: 7, size: Int64(mb))]
        fake.pwriteQueue = [.failed(errno: EIO)]
        let result = first(await service(fake).execute([target]))
        XCTAssertTrue(isFailed(result.disposition))
        XCTAssertEqual(result.mutation, .possiblyChanged)
        XCTAssertTrue(fake.unlinkNames.isEmpty)
    }

    // MARK: - SHR-11 unlink gate & identity recheck

    func testUnlinkOnlyAfterAllPassesTrulySucceededAndIdentityRecheckPasses() async throws {
        let fake = FakeSyscalls()
        fake.statChildQueue = [stat(inode: 7, size: Int64(mb)), stat(inode: 7, size: Int64(mb))]
        fake.statOpenQueue = [stat(inode: 7, size: Int64(mb))]
        let result = first(await service(fake, passes: 3).execute([target]))
        XCTAssertTrue(isSucceeded(result.disposition))
        XCTAssertEqual(result.mutation, .changed)
        XCTAssertEqual(result.freedBytes, Int64(mb))
        XCTAssertEqual(fake.unlinkNames, ["target"])
        XCTAssertEqual(fake.writes, 3)   // one write per pass
    }

    func testIdentityChangedBeforeUnlinkFailsClosedAndDoesNotDelete() async throws {
        let fake = FakeSyscalls()
        // classification inode 7, opened inode 7, but the pre-unlink recheck returns 99.
        fake.statChildQueue = [stat(inode: 7, size: Int64(mb)), stat(inode: 99, size: Int64(mb))]
        fake.statOpenQueue = [stat(inode: 7, size: Int64(mb))]
        let result = first(await service(fake).execute([target]))
        XCTAssertTrue(isFailed(result.disposition))
        XCTAssertTrue(fake.unlinkNames.isEmpty, "identity drift before unlink must not delete")
    }

    // MARK: - Amendment C1: recheck identity + st_nlink==1 BEFORE first overwrite

    func testHardLinkCreatedBetweenPrepareAndExecuteIsRecheckedBeforeOverwriteAndSkipped() async throws {
        let fake = FakeSyscalls()
        fake.statChildQueue = [stat(inode: 7, nlink: 2, size: Int64(mb))]   // classification
        fake.statOpenQueue = [stat(inode: 7, nlink: 2, size: Int64(mb))]    // opened: now hard-linked
        let result = first(await service(fake).execute([target]))
        XCTAssertTrue(isSkipped(result.disposition))
        XCTAssertEqual(result.mutation, .none)
        XCTAssertEqual(fake.writes, 0, "must not write a single byte to a hard-linked target")
        XCTAssertTrue(fake.unlinkNames.isEmpty)
    }

    func testIdentityDriftBeforeFirstOverwritePassFailsClosedWithoutWriting() async throws {
        let fake = FakeSyscalls()
        fake.statChildQueue = [stat(inode: 7, size: Int64(mb))]   // classification inode 7
        fake.statOpenQueue = [stat(inode: 9, size: Int64(mb))]    // opened is a different inode
        let result = first(await service(fake).execute([target]))
        XCTAssertTrue(isSkipped(result.disposition))
        XCTAssertEqual(fake.writes, 0)
        XCTAssertTrue(fake.unlinkNames.isEmpty)
    }

    // MARK: - SHR-12 cancellation

    func testCancellationCheckedBetweenBoundedChunksNotOnlyPerPass() async throws {
        let fake = FakeSyscalls()
        fake.statChildQueue = [stat(inode: 7, size: Int64(3 * mb))]   // 3 chunks
        fake.statOpenQueue = [stat(inode: 7, size: Int64(3 * mb))]
        let result = first(await service(fake).execute([target], cancelled: { fake.writes >= 1 }))
        XCTAssertTrue(isCancelled(result.disposition))
        XCTAssertEqual(fake.writes, 1, "cancel is checked between chunks, so it stops mid-pass")
    }

    func testCancelDuringOverwriteStopsImmediatelyAndNeverUnlinks() async throws {
        let fake = FakeSyscalls()
        fake.statChildQueue = [stat(inode: 7, size: Int64(3 * mb))]
        fake.statOpenQueue = [stat(inode: 7, size: Int64(3 * mb))]
        let result = first(await service(fake).execute([target], cancelled: { fake.writes >= 1 }))
        XCTAssertTrue(isCancelled(result.disposition))
        XCTAssertTrue(fake.unlinkNames.isEmpty)
    }

    func testCancelAfterPartialOverwriteMarksCancelledPossiblyModified() async throws {
        let fake = FakeSyscalls()
        fake.statChildQueue = [stat(inode: 7, size: Int64(3 * mb))]
        fake.statOpenQueue = [stat(inode: 7, size: Int64(3 * mb))]
        let result = first(await service(fake).execute([target], cancelled: { fake.writes >= 1 }))
        XCTAssertTrue(isCancelled(result.disposition))
        XCTAssertEqual(result.mutation, .possiblyChanged)
    }

    // MARK: - SHR-14 per-item facts (directory is not a transaction)

    func testDirectoryPartialSuccessProducesPerItemDispositions() async throws {
        let fake = FakeSyscalls()
        fake.childrenResult = ["a", "b"]
        // dir classification, then a: classify+recheck, then b: classify.
        fake.statChildQueue = [
            stat(inode: 1, dir: true),
            stat(inode: 10, size: 100), stat(inode: 10, size: 100),   // a: classify, recheck
            stat(inode: 11, size: 100),                               // b: classify
        ]
        fake.statOpenQueue = [stat(inode: 10, size: 100), stat(inode: 11, size: 100)]  // a opened, b opened
        fake.pwriteQueue = [.wrote(100), .failed(errno: EIO)]   // a ok, b fails
        let payload = await service(fake).execute([URL(fileURLWithPath: "/tmp/xico/dir")])
        XCTAssertEqual(payload.items.count, 3)   // a, b, dir
        XCTAssertTrue(isSucceeded(payload.items[0].disposition), "a succeeded")
        XCTAssertTrue(isFailed(payload.items[1].disposition), "b failed")
        XCTAssertTrue(isSkipped(payload.items[2].disposition), "dir not removed when a child failed")
        XCTAssertEqual(fake.unlinkNames, ["a"], "only the succeeded child was unlinked")
    }

    func testShredderProducesShredderPayloadNotAggregateOnlyResult() async throws {
        let fake = FakeSyscalls()
        fake.statChildQueue = [stat(inode: 7, size: Int64(mb)), stat(inode: 7, size: Int64(mb))]
        fake.statOpenQueue = [stat(inode: 7, size: Int64(mb))]
        let payload = await service(fake).execute([target])
        XCTAssertEqual(payload.items.count, 1)
        XCTAssertEqual(payload.items[0].url, target)
        XCTAssertEqual(payload.freedBytes, Int64(mb))
    }

    // MARK: - SHR-15 no celebration for a full-success shred

    func testFullSuccessProducesNonCelebratoryNeutralTerminal() async throws {
        let fake = FakeSyscalls()
        fake.statChildQueue = [stat(inode: 7, size: Int64(mb)), stat(inode: 7, size: Int64(mb))]
        fake.statOpenQueue = [stat(inode: 7, size: Int64(mb))]
        let payload = await service(fake).execute([target])
        XCTAssertTrue(payload.items.allSatisfy { isSucceeded($0.disposition) })
        // The neutral (never celebratory) profile for a shred is registry-owned; a full
        // success must not flip it. (UI suppression lands in outcome-workflows Task 7.)
        XCTAssertEqual(OutcomeOperationRegistry.semantics(for: .shred)?.profile, .neutral)
    }
}
