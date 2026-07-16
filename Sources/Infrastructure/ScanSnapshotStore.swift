import Foundation
import Domain

/// 共享文件索引中的最小条目。只保存扫描决策需要的元数据，不持有文件内容。
public struct ScanIndexEntry: Sendable, Hashable {
    public let url: URL
    public let logicalBytes: Int64
    public let allocatedBytes: Int64
    public let privateBytes: Int64?
    public let fileID: UInt64
    public let linkCount: UInt32
    public let cloneID: UInt64

    public var estimatedReclaimableBytes: Int64 {
        max(0, privateBytes ?? allocatedBytes)
    }

    public var isAPFSClone: Bool { cloneID != 0 }

    public func isHidden(relativeTo root: URL) -> Bool {
        let rootCount = root.standardizedFileURL.pathComponents.count
        let components = url.standardizedFileURL.pathComponents.dropFirst(rootCount)
        return components.contains { $0.hasPrefix(".") }
    }

    public func isInsideRebuildableDirectory(relativeTo root: URL) -> Bool {
        let rootCount = root.standardizedFileURL.pathComponents.count
        let components = Set(url.standardizedFileURL.pathComponents.dropFirst(rootCount))
        return !components.isDisjoint(with: ["node_modules", "Pods", "Carthage",
                                             "__pycache__", "DerivedData", ".build"])
    }
}

/// 一次只读目录快照。多个扫描器可以查询同一份 entries，避免各自重复遍历磁盘。
public struct ScanSnapshot: Sendable {
    public let root: URL
    public let entries: [ScanIndexEntry]
    public let coverage: ScanCoverage

    public init(root: URL, entries: [ScanIndexEntry], coverage: ScanCoverage) {
        self.root = root
        self.entries = entries
        self.coverage = coverage
    }
}

public struct ScanIndexDiagnostics: Sendable, Equatable {
    public let buildsStarted: Int
    public let cacheHits: Int
    public let sharedJobHits: Int
}

/// 智能扫描会话级共享索引。
///
/// - 同一根目录只有一个构建任务；重复文件、相似图片和大文件共享结果。
/// - 子目录请求会复用已存在的上级快照并在内存中过滤。
/// - `invalidate` 会取消旧任务，保证用户点击“重新扫描”看到新鲜文件系统状态。
public final class ScanSnapshotStore: @unchecked Sendable {
    private struct CachedSnapshot {
        let snapshot: ScanSnapshot
        let expiresAt: Date
    }

    private enum Selection {
        case cached(key: String, snapshot: ScanSnapshot)
        case job(key: String, task: Task<ScanSnapshot, Never>)
    }

    private let lock = NSLock()
    private let cacheTTL: TimeInterval
    private var cache: [String: CachedSnapshot] = [:]
    private var jobs: [String: Task<ScanSnapshot, Never>] = [:]
    private var observers: [String: [UUID: ProgressHandler]] = [:]
    private var buildsStarted = 0
    private var cacheHits = 0
    private var sharedJobHits = 0

    public init(cacheTTL: TimeInterval = 30) {
        self.cacheTTL = max(0, cacheTTL)
    }

    /// 提前安装根扫描任务。调用本身不阻塞，随后所有子目录扫描都会挂到同一个任务上。
    public func prewarm(_ root: URL) {
        let canonical = Self.canonical(root)
        lock.lock()
        purgeExpiredLocked(now: Date())
        guard bestAncestorLocked(of: canonical.path) == nil else {
            lock.unlock()
            return
        }
        _ = installJobLocked(root: canonical)
        lock.unlock()
    }

    public func snapshot(for root: URL,
                         progress: @escaping ProgressHandler = { _ in }) async -> ScanSnapshot {
        let canonical = Self.canonical(root)
        let observerID = UUID()
        let selection: Selection

        selection = lock.withLock {
            purgeExpiredLocked(now: Date())
            if let match = bestAncestorLocked(of: canonical.path) {
                switch match {
                case let .cached(key, snapshot):
                    cacheHits += 1
                    return .cached(key: key, snapshot: snapshot)
                case let .job(key, task):
                    sharedJobHits += 1
                    observers[key, default: [:]][observerID] = progress
                    return .job(key: key, task: task)
                }
            }
            let task = installJobLocked(root: canonical)
            observers[canonical.path, default: [:]][observerID] = progress
            return .job(key: canonical.path, task: task)
        }

        let source: ScanSnapshot
        let sourceKey: String
        switch selection {
        case let .cached(key, snapshot):
            sourceKey = key
            source = snapshot
        case let .job(key, task):
            sourceKey = key
            source = await task.value
            finish(key: key, snapshot: source)
            removeObserver(observerID, key: key)
        }

        if sourceKey == canonical.path { return source }
        return Self.subsnapshot(source, rootedAt: canonical)
    }

    /// 取消未完成的索引并清空短期缓存。清理完成或手动重扫后必须调用。
    public func invalidate() {
        lock.lock()
        let pending = Array(jobs.values)
        jobs.removeAll()
        observers.removeAll()
        cache.removeAll()
        lock.unlock()
        pending.forEach { $0.cancel() }
    }

    public func diagnostics() -> ScanIndexDiagnostics {
        lock.lock()
        defer { lock.unlock() }
        return ScanIndexDiagnostics(buildsStarted: buildsStarted,
                                    cacheHits: cacheHits,
                                    sharedJobHits: sharedJobHits)
    }

    private func installJobLocked(root: URL) -> Task<ScanSnapshot, Never> {
        let key = root.path
        buildsStarted += 1
        let task = Task.detached(priority: .utility) { [self] in
            ScanSnapshotBuilder.build(root: root) { progress in
                self.emit(progress, key: key)
            }
        }
        jobs[key] = task
        return task
    }

    private func emit(_ progress: ScanProgress, key: String) {
        lock.lock()
        let callbacks = observers[key].map { Array($0.values) } ?? []
        lock.unlock()
        for callback in callbacks { callback(progress) }
    }

    private func finish(key: String, snapshot: ScanSnapshot) {
        lock.lock()
        if jobs[key] != nil {
            jobs[key] = nil
            observers[key] = nil
            if !snapshot.coverage.cancelled {
                cache[key] = CachedSnapshot(snapshot: snapshot,
                                            expiresAt: Date().addingTimeInterval(cacheTTL))
            }
        }
        lock.unlock()
    }

    private func removeObserver(_ id: UUID, key: String) {
        lock.lock()
        observers[key]?[id] = nil
        lock.unlock()
    }

    private func purgeExpiredLocked(now: Date) {
        cache = cache.filter { $0.value.expiresAt > now }
    }

    private func bestAncestorLocked(of requestedPath: String) -> Selection? {
        let keys = Set(cache.keys).union(jobs.keys)
        guard let key = keys.filter({ Self.isSameOrAncestor($0, of: requestedPath) })
            .max(by: { $0.count < $1.count }) else { return nil }
        if let hit = cache[key] { return .cached(key: key, snapshot: hit.snapshot) }
        if let task = jobs[key] { return .job(key: key, task: task) }
        return nil
    }

    private static func canonical(_ url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath()
    }

    private static func isSameOrAncestor(_ ancestor: String, of path: String) -> Bool {
        if ancestor == path { return true }
        let prefix = ancestor == "/" ? "/" : ancestor + "/"
        return path.hasPrefix(prefix)
    }

    private static func subsnapshot(_ source: ScanSnapshot, rootedAt root: URL) -> ScanSnapshot {
        let files = source.entries.filter { isSameOrAncestor(root.path, of: $0.url.path) }
        let parentDirs = Set(files.map { $0.url.deletingLastPathComponent().path })
        let inheritedLimitations = source.coverage.limitations
        let coverage = ScanCoverage(
            roots: [root.path],
            filesVisited: files.count,
            directoriesVisited: max(parentDirs.count, files.isEmpty ? 0 : 1),
            bytesInspected: files.reduce(0) { $0 + $1.logicalBytes },
            deniedDirectories: source.coverage.deniedDirectories,
            skippedMounts: source.coverage.skippedMounts,
            skippedSymlinks: source.coverage.skippedSymlinks,
            cloudPlaceholdersSkipped: source.coverage.cloudPlaceholdersSkipped,
            excludedByPolicy: source.coverage.excludedByPolicy,
            hiddenFilesIncluded: source.coverage.hiddenFilesIncluded,
            cancelled: source.coverage.cancelled,
            elapsedSeconds: source.coverage.elapsedSeconds,
            limitations: inheritedLimitations
        )
        return ScanSnapshot(root: root, entries: files, coverage: coverage)
    }
}

/// 哈希、图片指纹等重工作业的跨模块并发预算，避免两个扫描器各开 4 路后把 CPU/SSD 同时打满。
public actor ScanWorkLimiter {
    private var available: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public init(limit: Int = min(4, max(2, ProcessInfo.processInfo.activeProcessorCount / 2))) {
        available = max(1, limit)
    }

    public func withPermit<T: Sendable>(_ operation: @Sendable () async -> T) async -> T {
        await acquire()
        let result = await operation()
        release()
        return result
    }

    private func acquire() async {
        if available > 0 {
            available -= 1
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    private func release() {
        if let waiter = waiters.first {
            waiters.removeFirst()
            waiter.resume()
        } else {
            available += 1
        }
    }
}

private enum ScanSnapshotBuilder {
    static func build(root: URL,
                      emit: @escaping @Sendable (ScanProgress) -> Void) -> ScanSnapshot {
        let started = Date()
        let rootPath = root.path
        let isDirectory = (try? root.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
        guard isDirectory else {
            return ScanSnapshot(root: root, entries: [], coverage: ScanCoverage(
                roots: [rootPath], elapsedSeconds: Date().timeIntervalSince(started),
                limitations: ["扫描根目录不存在或不可读取"]
            ))
        }

        var stack = [root]
        var files: [ScanIndexEntry] = []
        var seenHardLinks = Set<UInt64>()
        var directoriesVisited = 0
        var bytesInspected: Int64 = 0
        var deniedDirectories = 0
        var skippedMounts = 0
        var skippedSymlinks = 0
        var cloudSkipped = 0
        var excludedByPolicy = 0
        var processedSinceYield = 0

        while let directory = stack.popLast() {
            if Task.isCancelled { break }
            directoriesVisited += 1
            let entries = BulkDirectoryReader.read(
                directory.path,
                onDenied: { deniedDirectories += 1 },
                onCloudPlaceholder: { cloudSkipped += 1 }
            )
            for entry in entries {
                if Task.isCancelled { break }
                let child = resolvedChildURL(of: entry, in: directory,
                                             isDirectory: entry.kind == .directory)
                switch entry.kind {
                case .directory:
                    if entry.isMountPoint {
                        skippedMounts += 1
                    } else if shouldExcludePackage(entry.name) {
                        excludedByPolicy += 1
                    } else {
                        stack.append(child)
                    }
                case .symlink:
                    skippedSymlinks += 1
                case .file:
                    if entry.linkCount > 1, entry.fileID != 0,
                       !seenHardLinks.insert(entry.fileID).inserted { continue }
                    let logical = entry.logicalBytes > 0 ? entry.logicalBytes : entry.allocatedBytes
                    files.append(ScanIndexEntry(
                        url: child,
                        logicalBytes: logical,
                        allocatedBytes: entry.allocatedBytes,
                        privateBytes: entry.privateBytes,
                        fileID: entry.fileID,
                        linkCount: entry.linkCount,
                        cloneID: entry.cloneID
                    ))
                    bytesInspected += logical
                case .other:
                    break
                }
                processedSinceYield += 1
                if processedSinceYield >= 512 {
                    processedSinceYield = 0
                    emit(ScanProgress(
                        message: directory.lastPathComponent,
                        bytesFound: bytesInspected,
                        filesVisited: files.count,
                        directoriesVisited: directoriesVisited,
                        deniedDirectories: deniedDirectories,
                        elapsedSeconds: Date().timeIntervalSince(started)
                    ))
                }
            }
        }

        let cancelled = Task.isCancelled
        let limitations: [String] = deniedDirectories > 0
            ? ["有 \(deniedDirectories) 个目录因权限不足未读取"] : []
        let coverage = ScanCoverage(
            roots: [rootPath],
            filesVisited: files.count,
            directoriesVisited: directoriesVisited,
            bytesInspected: bytesInspected,
            deniedDirectories: deniedDirectories,
            skippedMounts: skippedMounts,
            skippedSymlinks: skippedSymlinks,
            cloudPlaceholdersSkipped: cloudSkipped,
            excludedByPolicy: excludedByPolicy,
            hiddenFilesIncluded: true,
            cancelled: cancelled,
            elapsedSeconds: Date().timeIntervalSince(started),
            limitations: limitations
        )
        emit(ScanProgress(fraction: cancelled ? nil : 1,
                          message: cancelled ? "扫描已取消" : "文件索引已完成",
                          bytesFound: bytesInspected,
                          filesVisited: files.count,
                          directoriesVisited: directoriesVisited,
                          deniedDirectories: deniedDirectories,
                          elapsedSeconds: coverage.elapsedSeconds))
        return ScanSnapshot(root: root, entries: files, coverage: coverage)
    }

    private static func resolvedChildURL(of entry: BulkDirEntry, in parent: URL,
                                         isDirectory: Bool) -> URL {
        if let raw = entry.rawName {
            return raw.withUnsafeBufferPointer {
                URL(fileURLWithFileSystemRepresentation: $0.baseAddress!,
                    isDirectory: isDirectory, relativeTo: parent)
            }
        }
        return parent.appendingPathComponent(entry.name, isDirectory: isDirectory)
    }

    /// 个人文件扫描不深入应用/图库/插件包。它们由卸载器或 Photos.framework 管理，直接枚举内部文件
    /// 既会制造危险结果，也会把一次家目录索引拖成数分钟。
    private static func shouldExcludePackage(_ name: String) -> Bool {
        let ext = URL(fileURLWithPath: name).pathExtension.lowercased()
        return ["app", "photoslibrary", "photolibrary", "aplibrary",
                "migratedaperturelibrary", "bundle", "framework", "plugin"].contains(ext)
    }
}
