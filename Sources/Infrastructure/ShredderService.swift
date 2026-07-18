import Foundation
import Security
import Domain
#if canImport(Darwin)
import Darwin
#endif

/// 文件粉碎：多次随机覆写后删除，尽量降低被恢复的可能。
///
/// 诚实说明：在 SSD / APFS（写时复制 + 磨损均衡）上，覆写**不保证**原始数据块被真正抹除；
/// 对这类卷，真正可靠的做法是全盘 FileVault 加密。本功能对机械硬盘/外置盘更有意义，
/// UI 会如实告知。每个目标删除前仍过 SafetyEngine 红线。
public struct ShredderService: Sendable {
    private let safety: SafetyEngine
    private let passes: Int
    private let syscalls: FileSyscalls
    /// SHR-05 bounded-manifest budget: a root whose read-only preflight exceeds this
    /// many identity entries returns `requiresSplit` instead of executing with an
    /// unknown blast radius.
    private let maxManifestEntries: Int

    /// 递归深度上限（fail-safe）：正常树远达不到，仅兜住病态深度——超限即中止（返回 false），
    /// 同时把「同时打开的 dirFD 数」封在此上限内，杜绝无界递归耗尽 fd / 爆栈（与 HelperFileRemover 同策）。
    private static let maxRecursionDepth = 256

    public init(safety: SafetyEngine,
                passes: Int = 3,
                syscalls: FileSyscalls = SystemFileSyscalls(),
                maxManifestEntries: Int = 100_000) {
        self.safety = safety
        self.passes = max(1, passes)
        self.syscalls = syscalls
        self.maxManifestEntries = max(1, maxManifestEntries)
    }

    public struct Result: Sendable {
        public let shredded: Int
        public let failed: [URL]
        public let freedBytes: Int64
    }

    public func shred(_ urls: [URL], progress: @escaping ProgressHandler = { _ in }) async -> Result {
        let payload = await execute(urls, progress: progress)
        var shredded = 0
        var failed: [URL] = []
        for item in payload.items {
            if case .succeeded = item.disposition { shredded += 1 } else { failed.append(item.url) }
        }
        return Result(shredded: shredded, failed: failed, freedBytes: payload.freedBytes)
    }

    /// Executes shredding and returns per-item honest facts (SHR-14). A directory is not
    /// a transaction: earlier successes plus a later failure or cancel produce a truthful
    /// per-item partial. Nothing is ever unlinked after a cancelled or failed overwrite.
    public func execute(_ urls: [URL],
                        cancelled: @escaping () -> Bool = { false },
                        progress: @escaping ProgressHandler = { _ in }) async -> ShredderPayload {
        var results: [ShredderItemResult] = []
        let total = urls.count
        for (idx, url) in urls.enumerated() {
            if Task.isCancelled || cancelled() { break }
            progress(ScanProgress(fraction: total > 0 ? Double(idx) / Double(total) : nil,
                                  message: url.lastPathComponent,
                                  bytesFound: results.reduce(Int64(0)) { $0 + $1.freedBytes }))
            for outcome in overwriteAndRemove(url, cancelled: cancelled) {
                results.append(ShredderItemResult(requestID: UUID(),
                                                  url: outcome.url,
                                                  disposition: outcome.disposition,
                                                  mutation: outcome.mutation,
                                                  freedBytes: outcome.freedBytes))
            }
        }
        return ShredderPayload(items: results)
    }

    /// A single per-target outcome accumulated during the fd-anchored execution walk.
    private struct ShredItemOutcome {
        let url: URL
        let disposition: OperationDisposition
        let mutation: OperationMutationFact
        let freedBytes: Int64
    }

    private func item(_ url: URL, _ disposition: OperationDisposition,
                      _ mutation: OperationMutationFact, _ freedBytes: Int64 = 0) -> ShredItemOutcome {
        ShredItemOutcome(url: url, disposition: disposition, mutation: mutation, freedBytes: freedBytes)
    }

    private func shredIssue(_ code: String, _ category: OperationIssueCategory,
                            _ recovery: OperationRecoveryHint, retryable: Bool) -> OperationIssue {
        // subjectID stays nil: the item result already carries the URL; the issue must
        // not persist a raw path.
        OperationIssue(code: code, category: category, subjectID: nil, recovery: recovery, retryable: retryable)
    }

    // MARK: - Preparation phase (SHR-01…06): read-only, zero writes / zero unlinks.

    /// Read-only preflight. For each root, anchors at its parent directory fd and walks
    /// the subtree with the injected `FileSyscalls`, building a bounded identity
    /// manifest. Runs the SafetyEngine red-line on every node (SHR-01), never follows
    /// symlinks (SHR-02), and gates the whole root: any red-lined / unrecognized /
    /// hard-linked descendant rejects the entire root (SHR-03/04/06) rather than
    /// best-effort deleting siblings. Performs no writes and no unlinks; the accepted
    /// manifest feeds the Task 1 capability core to build a `DestructivePlan(.shred)`.
    public func prepare(_ urls: [URL]) -> [ShredRootResult] {
        urls.map { ShredRootResult(rootPath: $0.path, disposition: disposition(for: $0)) }
    }

    private func disposition(for url: URL) -> ShredRootDisposition {
        // SHR-01: top-level red-line (a denied root never enters the manifest).
        guard safety.verify(url, intent: .trash).isAllowed else { return .rejected(.safetyDenied) }
        let parent = url.deletingLastPathComponent()
        let leaf = url.lastPathComponent
        let parentFD = syscalls.openDirectory(path: parent.path)
        guard parentFD >= 0 else { return .rejected(.openFailed) }
        defer { syscalls.closeDescriptor(parentFD) }
        var manifest: [ShredManifestEntry] = []
        switch walk(parentFD: parentFD, name: leaf, url: url, depth: 0, into: &manifest) {
        case .clean: return .accepted(manifest)
        case .rejected(let reason): return .rejected(reason)
        case .budgetExceeded: return .requiresSplit(entryCount: manifest.count)
        }
    }

    private enum WalkOutcome: Equatable { case clean, rejected(ShredRejectionReason), budgetExceeded }

    /// Read-only recursive classification. `depth == 0` is the root (already red-line
    /// checked by the caller); deeper nodes are re-checked here (SHR-01).
    private func walk(parentFD: Int32, name: String, url: URL, depth: Int,
                      into manifest: inout [ShredManifestEntry]) -> WalkOutcome {
        guard depth < Self.maxRecursionDepth else { return .rejected(.openFailed) }
        if depth > 0, !safety.verify(url, intent: .trash).isAllowed { return .rejected(.safetyDenied) }
        guard let st = syscalls.statChild(parentFD: parentFD, name: name) else {
            return .rejected(.openFailed)
        }
        if st.isSymlink {
            // SHR-02: register the link itself; never follow it.
            return append(ShredManifestEntry(canonicalPath: url.path, identity: st.localIdentity, isDirectory: false),
                          to: &manifest)
        }
        if st.isRegularFile {
            if st.hardLinkCount > 1 { return .rejected(.hardLinked) }   // SHR-04
            return append(ShredManifestEntry(canonicalPath: url.path, identity: st.localIdentity, isDirectory: false),
                          to: &manifest)
        }
        if st.isDirectory {
            let dirFD = syscalls.openChildDirectory(parentFD: parentFD, name: name)
            guard dirFD >= 0 else { return .rejected(.openFailed) }
            defer { syscalls.closeDescriptor(dirFD) }
            guard let children = syscalls.listChildren(dirFD: dirFD) else { return .rejected(.openFailed) }
            for child in children {
                let outcome = walk(parentFD: dirFD, name: child,
                                   url: url.appendingPathComponent(child), depth: depth + 1, into: &manifest)
                if case .clean = outcome { continue }
                return outcome   // SHR-06: any bad descendant rejects the whole root
            }
            // Directory recorded after its children so execution removes children first.
            return append(ShredManifestEntry(canonicalPath: url.path, identity: st.localIdentity, isDirectory: true),
                          to: &manifest)
        }
        // SHR-03: FIFO / socket / device / other non-regular types are integrally refused.
        return .rejected(.unrecognizedType)
    }

    private func append(_ entry: ShredManifestEntry,
                        to manifest: inout [ShredManifestEntry]) -> WalkOutcome {
        guard manifest.count < maxManifestEntries else { return .budgetExceeded }   // SHR-05
        manifest.append(entry)
        return .clean
    }

    /// 对单个文件多轮随机覆写后删除；目录则递归。
    /// 关键安全约束（对抗复核发现）：
    /// - **每一层**（包括递归子项）都过红线校验，绝不只校顶层；用 .trash 语义取基础红线
    ///   （系统区/其他用户/云同步/钥匙串/图库包/应用数据根一律拒），但允许用户显式选定并二次确认的
    ///   自有内容文件被粉碎——这正是粉碎功能的用途。
    /// - **绝不跟随符号链接**：遇到软链只删链接本身，绝不进入其目标覆写/删除（否则会穿透删掉受保护目标）。
    /// - **整棵子树全程 fd 锚定，杜绝 check-then-open TOCTOU**（对抗复核 P2/P3）：目录与常规文件
    ///   走同一套 fd 相对遍历——从父目录 fd `openat(O_NOFOLLOW)` 下钻，`fdopendir` 只读枚举（先整趟
    ///   drain 子项名、再在快照上递归/删除，绝不边读边改同一目录流），子项一律经 `unlinkat` 按名删除，
    ///   绝不在遍历中途按路径重开子项（否则祖先被换成软链即穿透删掉类外目标）。与 HelperFileRemover 同构。
    /// fd-anchored execution of one root. Preserves the SHR-07 base (fd-relative,
    /// O_NOFOLLOW, never re-open a child by path) but routes every syscall through the
    /// injected `FileSyscalls` and emits per-item outcomes instead of a single bool.
    private func overwriteAndRemove(_ url: URL, cancelled: () -> Bool) -> [ShredItemOutcome] {
        // 顶层基础红线：系统/其他用户/云同步/钥匙串/图库包/数据根一律拒（用 .trash 取基础判定）。
        guard safety.verify(url, intent: .trash).isAllowed else {
            XicoLog.clean.error("粉碎被红线拒绝: \(url.path, privacy: .public)")
            return [item(url, .skipped(shredIssue("shred.safety.denied", .safetyPolicy, .chooseAnotherTarget, retryable: false)), .none)]
        }
        let parent = url.deletingLastPathComponent()
        let leaf = url.lastPathComponent
        let parentFD = syscalls.openDirectory(path: parent.path)
        guard parentFD >= 0 else {
            XicoLog.clean.error("粉碎打开父目录失败: \(parent.path, privacy: .public)")
            return [item(url, .failed(shredIssue("shred.io.openParentFailed", .io, .retry, retryable: true)), .none)]
        }
        defer { syscalls.closeDescriptor(parentFD) }
        return shredEntry(parentFD: parentFD, name: leaf, url: url, depth: 0, cancelled: cancelled)
    }

    /// fd 锚定地粉碎一个条目（不跟随符号链接）：目录递归、常规文件多轮覆写后删、软链只删链接本身。
    /// `url` 仅用于红线策略判定与日志，所有 open/unlink 一律走父 fd 相对，绝不按路径重开。
    private func shredEntry(parentFD: Int32, name: String, url: URL, depth: Int,
                            cancelled: () -> Bool) -> [ShredItemOutcome] {
        guard depth < Self.maxRecursionDepth else {
            XicoLog.clean.error("粉碎递归超深，中止: \(url.path, privacy: .public)")
            return [item(url, .failed(shredIssue("shred.io.tooDeep", .validation, .manualAction, retryable: false)), .none)]
        }
        if depth > 0, !safety.verify(url, intent: .trash).isAllowed {
            XicoLog.clean.error("粉碎被红线拒绝: \(url.path, privacy: .public)")
            return [item(url, .skipped(shredIssue("shred.safety.denied", .safetyPolicy, .chooseAnotherTarget, retryable: false)), .none)]
        }
        // Type via statChild (fstatat AT_SYMLINK_NOFOLLOW): never follows a final symlink.
        guard let st = syscalls.statChild(parentFD: parentFD, name: name) else {
            return [item(url, .failed(shredIssue("shred.io.statFailed", .io, .retry, retryable: true)), .none)]
        }
        if st.isSymlink {
            // SHR-02: delete the link itself; never follow it.
            let rc = syscalls.unlinkChild(parentFD: parentFD, name: name, removeDir: false)
            return [rc == 0
                    ? item(url, .succeeded, .changed)
                    : item(url, .failed(shredIssue("shred.io.unlinkFailed", .io, .retry, retryable: true)), .none)]
        }
        if st.isRegularFile {
            return [shredRegularFile(parentFD: parentFD, name: name, url: url, classified: st, cancelled: cancelled)]
        }
        if st.isDirectory {
            let dirFD = syscalls.openChildDirectory(parentFD: parentFD, name: name)
            guard dirFD >= 0 else {
                return [item(url, .failed(shredIssue("shred.io.openFailed", .io, .retry, retryable: true)), .none)]
            }
            defer { syscalls.closeDescriptor(dirFD) }
            guard let children = syscalls.listChildren(dirFD: dirFD) else {
                return [item(url, .failed(shredIssue("shred.io.listFailed", .io, .retry, retryable: true)), .none)]
            }
            var outcomes: [ShredItemOutcome] = []
            var allSucceeded = true
            for child in children {
                if Task.isCancelled || cancelled() { allSucceeded = false; break }
                let childOutcomes = shredEntry(parentFD: dirFD, name: child,
                                               url: url.appendingPathComponent(child),
                                               depth: depth + 1, cancelled: cancelled)
                outcomes.append(contentsOf: childOutcomes)
                if childOutcomes.contains(where: { if case .succeeded = $0.disposition { return false } else { return true } }) {
                    allSucceeded = false
                }
            }
            // SHR-14: the directory is not a transaction — remove it only when every
            // child truly succeeded; otherwise keep it and report a per-item skip.
            if allSucceeded {
                let rc = syscalls.unlinkChild(parentFD: parentFD, name: name, removeDir: true)
                outcomes.append(rc == 0
                                ? item(url, .succeeded, .changed)
                                : item(url, .failed(shredIssue("shred.io.rmdirFailed", .io, .retry, retryable: true)), .none))
            } else {
                outcomes.append(item(url, .skipped(shredIssue("shred.io.childrenIncomplete", .io, .retry, retryable: true)), .none))
            }
            return outcomes
        }
        // SHR-03: FIFO / socket / device / other non-regular types are integrally refused.
        XicoLog.clean.error("粉碎目标非常规文件，拒绝: \(url.path, privacy: .public)")
        return [item(url, .skipped(shredIssue("shred.identity.unrecognizedType", .validation, .chooseAnotherTarget, retryable: false)), .none)]
    }

    /// TOCTOU-hardened regular-file shred. Opens `O_WRONLY|O_NOFOLLOW` from the anchored
    /// parent fd; every syscall is fd-relative and routed through the injected seam.
    private func shredRegularFile(parentFD: Int32, name: String, url: URL,
                                  classified: FileStat, cancelled: () -> Bool) -> ShredItemOutcome {
        let fd = syscalls.openRegularForWrite(parentFD: parentFD, name: name)
        guard fd >= 0 else {
            XicoLog.clean.error("粉碎打开目标失败（可能已变为符号链接）: \(url.path, privacy: .public)")
            return item(url, .failed(shredIssue("shred.io.openFailed", .io, .retry, retryable: true)), .none)
        }
        var closed = false
        defer { if !closed { syscalls.closeDescriptor(fd) } }
        guard let opened = syscalls.statOpen(fd: fd), opened.isRegularFile else {
            XicoLog.clean.error("粉碎目标非常规文件，拒绝: \(url.path, privacy: .public)")
            return item(url, .skipped(shredIssue("shred.identity.notRegular", .identityChanged, .chooseAnotherTarget, retryable: false)), .none)
        }
        // Amendment C1: re-verify identity + st_nlink == 1 on the opened fd BEFORE the
        // first overwrite pass. A hard link created in the prepare→execute window (or a
        // same-name swap to a linked / different-inode file) must not have its content
        // clobbered. Fail closed WITHOUT writing a single byte.
        guard opened.hardLinkCount == 1,
              opened.inode == classified.inode, opened.device == classified.device else {
            XicoLog.clean.error("粉碎前身份复核失败（硬链接/身份漂移），拒绝覆写: \(url.path, privacy: .public)")
            return item(url, .skipped(shredIssue("shred.identity.hardLinkedOrDrifted", .identityChanged, .chooseAnotherTarget, retryable: false)), .none)
        }
        let size = opened.size
        let outcome = overwriteFile(fd: fd, size: size, cancelled: cancelled)
        syscalls.closeDescriptor(fd); closed = true
        switch outcome {
        case .cancelled:
            // SHR-12: a cancelled overwrite is never unlinked; content may be partially
            // rewritten → cancelledPossiblyModified.
            return item(url, .cancelled(shredIssue("shred.cancelled.possiblyModified", .io, .manualAction, retryable: true)),
                        size > 0 ? .possiblyChanged : .none)
        case .failed:
            // SHR-13: an I/O failure is never unlinked → failedPossiblyModified.
            return item(url, .failed(shredIssue("shred.io.failedPossiblyModified", .io, .retry, retryable: true)),
                        size > 0 ? .possiblyChanged : .none)
        case .completed:
            // SHR-11: only after every pass truly succeeded, recheck identity by name,
            // then unlink. A rebind to a different inode fails closed and does not delete.
            guard let after = syscalls.statChild(parentFD: parentFD, name: name),
                  after.inode == opened.inode, after.device == opened.device, after.isRegularFile else {
                XicoLog.clean.error("粉碎删除前 inode 复核失败，拒绝删除: \(url.path, privacy: .public)")
                return item(url, .failed(shredIssue("shred.identity.changedBeforeUnlink", .identityChanged, .retry, retryable: true)), .possiblyChanged)
            }
            guard syscalls.unlinkChild(parentFD: parentFD, name: name, removeDir: false) == 0 else {
                XicoLog.clean.error("粉碎删除失败: \(url.path, privacy: .public)")
                return item(url, .failed(shredIssue("shred.io.unlinkFailed", .io, .retry, retryable: true)), .possiblyChanged)
            }
            return item(url, .succeeded, .changed, size)
        }
    }

    private enum OverwriteOutcome: Equatable { case completed, cancelled, failed }

    /// Multi-pass overwrite through the injected syscalls. Precise `pwrite` loop:
    /// `written`/`offset` advance only by REAL bytes written (SHR-09); `EINTR` retries
    /// without double-counting; each pass must fully write and successfully `fsync`
    /// before the next (SHR-10); cancellation is checked between bounded chunks (SHR-12);
    /// any zero/failed write or `fsync` failure returns `.failed` (SHR-13). Never unlinks
    /// — that decision belongs to the caller and only on `.completed`.
    private func overwriteFile(fd: Int32, size: Int64, cancelled: () -> Bool) -> OverwriteOutcome {
        guard size > 0 else { return .completed }
        let chunk = 1 << 20
        var buffer = [UInt8](repeating: 0, count: chunk)
        for _ in 0..<passes {
            var offset: Int64 = 0
            while offset < size {
                if Task.isCancelled || cancelled() { return .cancelled }
                let n = Int(min(Int64(chunk), size - offset))
                fillRandom(&buffer, count: n)
                var written = 0
                while written < n {
                    if Task.isCancelled || cancelled() { return .cancelled }
                    let result: WriteResult = buffer.withUnsafeBytes { raw in
                        syscalls.pwrite(fd: fd,
                                        bytes: UnsafeRawBufferPointer(rebasing: raw[written..<n]),
                                        offset: offset + Int64(written))
                    }
                    switch result {
                    case .wrote(let w):
                        if w <= 0 { return .failed }   // no progress ⇒ fail closed
                        written += w                    // SHR-09: advance by real bytes
                    case .failed(let code):
                        if code == EINTR { continue }   // SHR-09: retry, no double count
                        return .failed                  // SHR-13: ENOSPC / EIO / etc.
                    }
                }
                offset += Int64(n)
            }
            if syscalls.fsync(fd: fd) != 0 { return .failed }   // SHR-10
        }
        return .completed
    }

    /// Fills the first `n` bytes of `buffer` with random data; never writes predictable
    /// zeros even if `SecRandomCopyBytes` fails (SystemRNG fallback).
    private func fillRandom(_ buffer: inout [UInt8], count n: Int) {
        buffer.withUnsafeMutableBytes { raw in
            if SecRandomCopyBytes(kSecRandomDefault, n, raw.baseAddress!) != errSecSuccess {
                var rng = SystemRandomNumberGenerator()
                var off = 0
                while off + 8 <= n {
                    var word = rng.next() as UInt64
                    memcpy(raw.baseAddress!.advanced(by: off), &word, 8)
                    off += 8
                }
                while off < n { raw[off] = UInt8(truncatingIfNeeded: rng.next() as UInt64); off += 1 }
            }
        }
    }
}

/// One entry of a shred preparation manifest: a canonical path and the identity
/// snapshot taken during the read-only preflight. Directories are recorded after their
/// children so execution removes contents before the directory itself.
public struct ShredManifestEntry: Sendable, Equatable {
    public let canonicalPath: String
    public let identity: LocalFileIdentity
    public let isDirectory: Bool

    public init(canonicalPath: String, identity: LocalFileIdentity, isDirectory: Bool) {
        self.canonicalPath = canonicalPath
        self.identity = identity
        self.isDirectory = isDirectory
    }
}

public enum ShredRejectionReason: String, Sendable, Equatable {
    case safetyDenied        // SHR-01 / SHR-06 red-line
    case hardLinked          // SHR-04 st_nlink > 1
    case unrecognizedType    // SHR-03 FIFO / socket / device / other
    case openFailed          // read-only open/stat/list failure, or pathological depth
}

public enum ShredRootDisposition: Sendable, Equatable {
    case accepted([ShredManifestEntry])
    case rejected(ShredRejectionReason)
    case requiresSplit(entryCount: Int)
}

public struct ShredRootResult: Sendable, Equatable {
    public let rootPath: String
    public let disposition: ShredRootDisposition

    public init(rootPath: String, disposition: ShredRootDisposition) {
        self.rootPath = rootPath
        self.disposition = disposition
    }
}
