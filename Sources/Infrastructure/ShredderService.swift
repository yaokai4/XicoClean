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
        var shredded = 0
        var failed: [URL] = []
        var freed: Int64 = 0
        let total = urls.count
        for (idx, url) in urls.enumerated() {
            if Task.isCancelled { break }
            progress(ScanProgress(fraction: total > 0 ? Double(idx) / Double(total) : nil,
                                  message: url.lastPathComponent, bytesFound: freed))
            var freedForItem: Int64 = 0
            if overwriteAndRemove(url, freed: &freedForItem) {
                shredded += 1; freed += freedForItem
            } else {
                failed.append(url)
            }
        }
        return Result(shredded: shredded, failed: failed, freedBytes: freed)
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
    private func overwriteAndRemove(_ url: URL, freed: inout Int64) -> Bool {
        // 顶层基础红线：系统/其他用户/云同步/钥匙串/图库包/数据根一律拒（用 .trash 取基础判定）。
        guard safety.verify(url, intent: .trash).isAllowed else {
            XicoLog.clean.error("粉碎被红线拒绝: \(url.path, privacy: .public)")
            return false
        }
        // 从叶子的父目录 fd 锚定进入，整棵子树的遍历/覆写/删除全程 fd 相对，绝不按路径重开子项。
        let parent = url.deletingLastPathComponent()
        let leaf = url.lastPathComponent
        let parentFD = open(parent.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard parentFD >= 0 else {
            XicoLog.clean.error("粉碎打开父目录失败: \(parent.path, privacy: .public)")
            return false
        }
        defer { close(parentFD) }
        return shredEntry(parentFD: parentFD, name: leaf, url: url, freed: &freed, depth: 0)
    }

    /// fd 锚定地粉碎一个条目（不跟随符号链接）：目录递归、常规文件多轮覆写后删、软链只删链接本身。
    /// `url` 仅用于红线策略判定与日志，所有 open/unlink 一律走父 fd 相对，绝不按路径重开。
    private func shredEntry(parentFD: Int32, name: String, url: URL, freed: inout Int64, depth: Int) -> Bool {
        // 病态深度兜底：中止而非继续，宁可漏删也不无界递归耗尽 fd / 爆栈。
        guard depth < Self.maxRecursionDepth else {
            XicoLog.clean.error("粉碎递归超深，中止: \(url.path, privacy: .public)")
            return false
        }
        // 每一层复核红线（子项也要拒系统区/云同步/钥匙串/图库包等）；顶层已在 overwriteAndRemove 校过。
        guard depth == 0 || safety.verify(url, intent: .trash).isAllowed else {
            XicoLog.clean.error("粉碎被红线拒绝: \(url.path, privacy: .public)")
            return false
        }
        // 类型判定用 fstatat(AT_SYMLINK_NOFOLLOW)（不跟随软链，且相对父 fd，无按路径重开）。
        var st = stat()
        guard fstatat(parentFD, name, &st, AT_SYMLINK_NOFOLLOW) == 0 else { return false }
        let type = st.st_mode & S_IFMT
        // 符号链接：只删链接本身，绝不跟随进入目标。
        if type == S_IFLNK { return unlinkat(parentFD, name, 0) == 0 }
        if type == S_IFDIR {
            let dirFD = openat(parentFD, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard dirFD >= 0 else { return false }
            // 用 dirFD 的副本喂 fdopendir 只做枚举；dirFD 本身保留作 unlinkat/递归的锚点 fd。
            // 先整趟读全子项名（drain）、closedir，再在快照上递归/删除——绝不边读边改同一 readdir 流
            // （POSIX 未规定边遍历边修改目录的行为，可能漏项/重复枚举）。
            let streamFD = fcntl(dirFD, F_DUPFD_CLOEXEC, 0)
            guard streamFD >= 0, let dir = fdopendir(streamFD) else {
                if streamFD >= 0 { close(streamFD) }
                close(dirFD)
                return false
            }
            var names: [String] = []
            while let ent = readdir(dir) {
                let n = withUnsafeBytes(of: ent.pointee.d_name) { raw -> String in
                    String(cString: raw.baseAddress!.assumingMemoryBound(to: CChar.self))
                }
                if n == "." || n == ".." { continue }
                names.append(n)
            }
            closedir(dir)   // 关闭枚举用副本；dirFD 仍开着，作后续 unlink/递归的锚点
            var ok = true
            for n in names {
                if !shredEntry(parentFD: dirFD, name: n, url: url.appendingPathComponent(n),
                               freed: &freed, depth: depth + 1) { ok = false }
            }
            close(dirFD)
            return ok && unlinkat(parentFD, name, AT_REMOVEDIR) == 0
        }
        if type == S_IFREG {
            return shredRegularFile(parentFD: parentFD, name: name, url: url, freed: &freed)
        }
        // FIFO/设备/socket 等非常规类型：拒绝覆写（保守），不处理。
        XicoLog.clean.error("粉碎目标非常规文件，拒绝: \(url.path, privacy: .public)")
        return false
    }

    /// TOCTOU 加固的常规文件粉碎：由 shredEntry 传入已锚定的父目录 fd，openat/unlinkat 一律相对该 fd，绝不按路径重开。
    private func shredRegularFile(parentFD: Int32, name: String, url: URL, freed: inout Int64) -> Bool {
        let leaf = name
        // 叶子用 O_WRONLY|O_NOFOLLOW 从父 fd 打开：期间被换成软链 → openat 失败 → 拒（不穿透目标）。
        let fd = openat(parentFD, leaf, O_WRONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else {
            XicoLog.clean.error("粉碎打开目标失败（可能已变为符号链接）: \(url.path, privacy: .public)")
            return false
        }
        var fdClosed = false
        defer { if !fdClosed { close(fd) } }
        // fstat 复核：仍是常规文件才继续（杜绝对 FIFO/设备/软链等做覆写）。
        var st = stat()
        guard fstat(fd, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else {
            XicoLog.clean.error("粉碎目标非常规文件，拒绝: \(url.path, privacy: .public)")
            return false
        }
        let size = Int64(st.st_size)
        overwriteFile(fd: fd, size: size)
        close(fd); fdClosed = true
        // unlinkat 按名从父 fd 删除；删前再 fstatat 复核 inode 未变（防止 open 后名字被重绑到别的文件）。
        var after = stat()
        guard fstatat(parentFD, leaf, &after, AT_SYMLINK_NOFOLLOW) == 0,
              after.st_ino == st.st_ino, after.st_dev == st.st_dev,
              (after.st_mode & S_IFMT) == S_IFREG else {
            XicoLog.clean.error("粉碎删除前 inode 复核失败，拒绝删除: \(url.path, privacy: .public)")
            return false
        }
        guard unlinkat(parentFD, leaf, 0) == 0 else {
            XicoLog.clean.error("粉碎删除失败: \(url.path, privacy: .public)")
            return false
        }
        freed += size
        return true
    }

    /// 经已打开的 fd 多轮随机覆写（不按路径重开，配合 TOCTOU 加固）。
    private func overwriteFile(fd: Int32, size: Int64) {
        guard size > 0 else { return }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        let chunk = 1 << 20   // 1MB 随机块
        // 复用同一缓冲区，每块用一次 SecRandomCopyBytes 批量填充随机字节——
        // 取代逐字节 UInt8.random（多 GB 文件会产生数十亿次 RNG 调用，把本应 I/O 密集的
        // 覆写拖成 CPU 密集）。语义不变：每一轮 pass 仍写整幅随机数据。
        var buffer = [UInt8](repeating: 0, count: chunk)
        for _ in 0..<passes {
            if Task.isCancelled { return }
            try? handle.seek(toOffset: 0)
            var remaining = size
            while remaining > 0 {
                let n = Int(min(Int64(chunk), remaining))
                buffer.withUnsafeMutableBytes { raw in
                    // 失败极罕见；万一失败则退回按 UInt64 字直取，绝不写出可预测的全零。
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
                try? handle.write(contentsOf: Data(buffer[0..<n]))
                remaining -= Int64(n)
            }
            try? handle.synchronize()
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
