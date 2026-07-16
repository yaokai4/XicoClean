import CryptoKit
import Darwin
import Foundation

enum HistoryRevision: Equatable, Sendable {
    case missing
    case sha256(Data)

    static func digest(of data: Data) -> HistoryRevision {
        .sha256(Data(SHA256.hash(data: data)))
    }

    var isWellFormed: Bool {
        switch self {
        case .missing:
            true
        case let .sha256(digest):
            digest.count == SHA256.byteCount
        }
    }
}

struct HistoryPersistenceSnapshot: Sendable {
    let data: Data
    let revision: HistoryRevision
}

enum HistoryLoadResult: Sendable {
    case missing
    case loaded(HistoryPersistenceSnapshot)
    case failed(code: String)
}

enum HistoryCommitResult: Sendable {
    case committed(newRevision: HistoryRevision)
    case conflict(latest: HistoryLoadResult)
    case indeterminate(latest: HistoryLoadResult?, code: String)
    case failed(code: String)
}

protocol HistoryPersistence: Sendable {
    func load() -> HistoryLoadResult
    func commit(_ data: Data, expectedRevision: HistoryRevision) -> HistoryCommitResult
}

enum HistoryPersistenceFileRole: Hashable, Sendable {
    case archive
    case lock
    case staging
    case parentDirectory
}

struct HistoryProcessMutexRegistrySnapshot: Equatable, Sendable {
    let storedEntries: Int
    let liveEntries: Int
}

private func historySystemFlock(_ descriptor: Int32, _ operation: Int32) -> Int32 {
    flock(descriptor, operation)
}

struct HistoryPersistenceHooks: Sendable {
    let stagingName: @Sendable () -> String
    let didOpen: @Sendable (HistoryPersistenceFileRole, Int32) -> Void
    let read: @Sendable (Int32, UnsafeMutableRawPointer?, Int) -> Int
    let write: @Sendable (Int32, UnsafeRawPointer?, Int) -> Int
    let fsync: @Sendable (Int32, HistoryPersistenceFileRole) -> Int32
    let rename: @Sendable (Int32, String, String) -> Int32
    let flock: @Sendable (Int32, Int32) -> Int32
    let didClose: @Sendable (HistoryPersistenceFileRole, Int32) -> Void
    let didResolveProcessMutex:
        @Sendable (AnyObject, HistoryProcessMutexRegistrySnapshot) -> Void

    init(
        stagingName: @escaping @Sendable () -> String = {
            ".history.json.staging.\(UUID().uuidString)"
        },
        didOpen: @escaping @Sendable (HistoryPersistenceFileRole, Int32) -> Void = { _, _ in },
        read: @escaping @Sendable (Int32, UnsafeMutableRawPointer?, Int) -> Int = {
            Darwin.read($0, $1, $2)
        },
        write: @escaping @Sendable (Int32, UnsafeRawPointer?, Int) -> Int = {
            Darwin.write($0, $1, $2)
        },
        fsync: @escaping @Sendable (Int32, HistoryPersistenceFileRole) -> Int32 = {
            descriptor, _ in Darwin.fsync(descriptor)
        },
        rename: @escaping @Sendable (Int32, String, String) -> Int32 = {
            descriptor, source, destination in
            source.withCString { sourcePath in
                destination.withCString { destinationPath in
                    Darwin.renameat(descriptor, sourcePath, descriptor, destinationPath)
                }
            }
        },
        flock: @escaping @Sendable (Int32, Int32) -> Int32 = historySystemFlock,
        didClose: @escaping @Sendable (HistoryPersistenceFileRole, Int32) -> Void = { _, _ in },
        didResolveProcessMutex:
            @escaping @Sendable (AnyObject, HistoryProcessMutexRegistrySnapshot) -> Void = {
                _, _ in
            }
    ) {
        self.stagingName = stagingName
        self.didOpen = didOpen
        self.read = read
        self.write = write
        self.fsync = fsync
        self.rename = rename
        self.flock = flock
        self.didClose = didClose
        self.didResolveProcessMutex = didResolveProcessMutex
    }
}

private final class HistoryProcessMutex: @unchecked Sendable {
    let lock = NSLock()
}

private final class WeakHistoryProcessMutex {
    weak var value: HistoryProcessMutex?

    init(_ value: HistoryProcessMutex) {
        self.value = value
    }
}

private final class HistoryProcessMutexRegistry: @unchecked Sendable {
    static let shared = HistoryProcessMutexRegistry()

    private let lock = NSLock()
    private var entries: [String: WeakHistoryProcessMutex] = [:]

    func resolve(
        canonicalArchiveKey: String
    ) -> (token: HistoryProcessMutex, snapshot: HistoryProcessMutexRegistrySnapshot) {
        lock.lock()
        defer { lock.unlock() }

        entries = entries.filter { $0.value.value != nil }
        let token: HistoryProcessMutex
        if let existing = entries[canonicalArchiveKey]?.value {
            token = existing
        } else {
            token = HistoryProcessMutex()
            entries[canonicalArchiveKey] = WeakHistoryProcessMutex(token)
        }
        let liveEntries = entries.values.reduce(into: 0) { count, entry in
            if entry.value != nil { count += 1 }
        }
        return (
            token,
            HistoryProcessMutexRegistrySnapshot(
                storedEntries: entries.count,
                liveEntries: liveEntries))
    }
}

private struct HistoryFileIdentity: Equatable, Sendable {
    let device: dev_t
    let inode: ino_t

    init(_ information: stat) {
        device = information.st_dev
        inode = information.st_ino
    }
}

private struct HistoryFileFingerprint: Equatable, Sendable {
    let identity: HistoryFileIdentity
    let byteCount: Int64
    let modificationSeconds: Int64
    let modificationNanoseconds: Int64
    let statusChangeSeconds: Int64
    let statusChangeNanoseconds: Int64

    init(_ information: stat) {
        identity = HistoryFileIdentity(information)
        byteCount = Int64(information.st_size)
        modificationSeconds = Int64(information.st_mtimespec.tv_sec)
        modificationNanoseconds = Int64(information.st_mtimespec.tv_nsec)
        statusChangeSeconds = Int64(information.st_ctimespec.tv_sec)
        statusChangeNanoseconds = Int64(information.st_ctimespec.tv_nsec)
    }
}

private struct HistoryPersistenceReadyState {
    let directoryDescriptor: Int32
    let directoryIdentity: HistoryFileIdentity
    let canonicalDirectoryPath: String
    let canonicalArchiveKey: String
    let processMutex: HistoryProcessMutex
    let registrySnapshot: HistoryProcessMutexRegistrySnapshot
}

private enum HistoryPersistenceSetupState {
    case ready(HistoryPersistenceReadyState)
    case failed(code: String)
}

private enum HistoryCanonicalPathResult {
    case path(String)
    case failed(errno: Int32)
}

private enum HistoryCoordinationResult<Value> {
    case value(Value)
    case failed(code: String)
}

private struct HistoryArchiveProbe {
    let result: HistoryLoadResult
    let identity: HistoryFileIdentity?
    let fingerprint: HistoryFileFingerprint?
}

private enum HistoryDataReadResult {
    case data(Data)
    case failed(code: String)
}

private struct HistoryOpenedStaging {
    let name: String
    let descriptor: Int32
    let identity: HistoryFileIdentity
}

private enum HistoryStagingOpenResult {
    case opened(HistoryOpenedStaging)
    case failed(code: String)
}

final class LiveHistoryPersistence: HistoryPersistence, @unchecked Sendable {
    private static let archiveName = "history.json"
    private static let lockName = "history.lock"
    private static let privateDirectoryMode: mode_t = 0o700
    private static let privateFileMode: mode_t = 0o600
    private static let permissionMask: mode_t = 0o777
    // Keep one byte beyond the schema archive limit observable so HistoryStore can
    // distinguish the exact boundary from its one-over rejection without allowing
    // an unbounded persistence allocation.
    private static let maximumReadBytes = HistoryArchiveLimits.maximumArchiveBytes + 1

    private let hooks: HistoryPersistenceHooks
    private let setup: HistoryPersistenceSetupState

    init(directory: URL, hooks: HistoryPersistenceHooks = HistoryPersistenceHooks()) {
        self.hooks = hooks
        setup = Self.prepare(directory: directory, hooks: hooks)
        if case let .ready(ready) = setup {
            hooks.didResolveProcessMutex(ready.processMutex, ready.registrySnapshot)
        }
    }

    deinit {
        if case let .ready(ready) = setup {
            _ = Darwin.close(ready.directoryDescriptor)
            hooks.didClose(.parentDirectory, ready.directoryDescriptor)
        }
    }

    func load() -> HistoryLoadResult {
        guard case let .ready(ready) = setup else {
            if case let .failed(code) = setup { return .failed(code: code) }
            return .failed(code: "history.persistence.unsafeDirectory")
        }
        switch withExclusiveCoordination(ready: ready, body: { loadLocked(ready: ready) }) {
        case let .value(probe):
            return probe.result
        case let .failed(code):
            return .failed(code: code)
        }
    }

    func commit(_ data: Data, expectedRevision: HistoryRevision) -> HistoryCommitResult {
        guard case let .ready(ready) = setup else {
            let code: String
            if case let .failed(setupCode) = setup {
                code = setupCode
            } else {
                code = "history.persistence.unsafeDirectory"
            }
            return .conflict(latest: .failed(code: code))
        }
        switch withExclusiveCoordination(
            ready: ready,
            body: { commitLocked(data, expectedRevision: expectedRevision, ready: ready) }
        ) {
        case let .value(result):
            return result
        case let .failed(code):
            return .conflict(latest: .failed(code: code))
        }
    }

    private static func prepare(
        directory: URL,
        hooks: HistoryPersistenceHooks
    ) -> HistoryPersistenceSetupState {
        guard directory.isFileURL else {
            return .failed(code: "history.persistence.unsafeDirectory")
        }

        var canonical = canonicalPath(for: directory)
        if case let .failed(code) = canonical, code == ENOENT {
            do {
                try FileManager.default.createDirectory(
                    at: directory,
                    withIntermediateDirectories: true,
                    attributes: [.posixPermissions: NSNumber(value: privateDirectoryMode)])
            } catch {
                return .failed(code: "history.persistence.directoryCreateFailed")
            }
            canonical = canonicalPath(for: directory)
        }
        guard case let .path(canonicalPath) = canonical else {
            return .failed(code: "history.persistence.unsafeDirectory")
        }

        var namedDirectory = stat()
        guard retryingLstat(path: canonicalPath, information: &namedDirectory),
              (namedDirectory.st_mode & S_IFMT) == S_IFDIR else {
            return .failed(code: "history.persistence.unsafeDirectory")
        }
        let preopenIdentity = HistoryFileIdentity(namedDirectory)

        let descriptor = retryingDescriptor {
            canonicalPath.withCString {
                Darwin.open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            }
        }
        guard descriptor >= 0 else {
            return .failed(code: "history.persistence.unsafeDirectory")
        }
        var shouldClose = true
        defer {
            if shouldClose {
                _ = Darwin.close(descriptor)
            }
        }

        var information = stat()
        guard retryingZero({ Darwin.fstat(descriptor, &information) }),
              (information.st_mode & S_IFMT) == S_IFDIR,
              HistoryFileIdentity(information) == preopenIdentity,
              retryingZero({ Darwin.fchmod(descriptor, privateDirectoryMode) }),
              retryingZero({ Darwin.fstat(descriptor, &information) }),
              (information.st_mode & permissionMask) == privateDirectoryMode,
              retryingLstat(path: canonicalPath, information: &namedDirectory),
              HistoryFileIdentity(namedDirectory) == HistoryFileIdentity(information) else {
            return .failed(code: "history.persistence.unsafeDirectory")
        }

        let canonicalArchiveKey = URL(
            fileURLWithPath: canonicalPath,
            isDirectory: true
        ).appendingPathComponent(archiveName).path
        let resolution = HistoryProcessMutexRegistry.shared.resolve(
            canonicalArchiveKey: canonicalArchiveKey)
        shouldClose = false
        hooks.didOpen(.parentDirectory, descriptor)
        return .ready(HistoryPersistenceReadyState(
            directoryDescriptor: descriptor,
            directoryIdentity: HistoryFileIdentity(information),
            canonicalDirectoryPath: canonicalPath,
            canonicalArchiveKey: canonicalArchiveKey,
            processMutex: resolution.token,
            registrySnapshot: resolution.snapshot))
    }

    private static func canonicalPath(for directory: URL) -> HistoryCanonicalPathResult {
        directory.withUnsafeFileSystemRepresentation { path in
            guard let path else { return .failed(errno: EINVAL) }
            guard let resolved = Darwin.realpath(path, nil) else {
                return .failed(errno: errno)
            }
            defer { Darwin.free(resolved) }
            return .path(String(cString: resolved))
        }
    }

    private static func retryingDescriptor(_ operation: () -> Int32) -> Int32 {
        while true {
            let result = operation()
            if result >= 0 || errno != EINTR { return result }
        }
    }

    private static func retryingZero(_ operation: () -> Int32) -> Bool {
        while true {
            let result = operation()
            if result == 0 { return true }
            if errno != EINTR { return false }
        }
    }

    private static func retryingLstat(path: String, information: inout stat) -> Bool {
        while true {
            let result = path.withCString { Darwin.lstat($0, &information) }
            if result == 0 { return true }
            if errno != EINTR { return false }
        }
    }

    private func withExclusiveCoordination<Value>(
        ready: HistoryPersistenceReadyState,
        body: () -> Value
    ) -> HistoryCoordinationResult<Value> {
        ready.processMutex.lock.lock()
        defer { ready.processMutex.lock.unlock() }

        guard ensurePrivateDirectory(ready) else {
            return .failed(code: "history.persistence.unsafeDirectory")
        }
        let lockResult = openCoordinationFile(ready)
        guard case let .value(lockDescriptor) = lockResult else {
            if case let .failed(code) = lockResult { return .failed(code: code) }
            return .failed(code: "history.persistence.unsafeLock")
        }
        defer { closeTracked(lockDescriptor, role: .lock) }

        while true {
            let result = hooks.flock(lockDescriptor, LOCK_EX)
            if result == 0 { break }
            if errno == EINTR { continue }
            return .failed(code: "history.persistence.lockAcquireFailed")
        }
        defer {
            while hooks.flock(lockDescriptor, LOCK_UN) != 0, errno == EINTR {}
        }
        guard namedIdentity(
            ready: ready,
            name: Self.lockName,
            expected: identity(of: lockDescriptor)) else {
            return .failed(code: "history.persistence.unsafeLock")
        }
        return .value(body())
    }

    private func ensurePrivateDirectory(_ ready: HistoryPersistenceReadyState) -> Bool {
        var information = stat()
        guard Self.retryingZero({ Darwin.fstat(ready.directoryDescriptor, &information) }),
              (information.st_mode & S_IFMT) == S_IFDIR,
              HistoryFileIdentity(information) == ready.directoryIdentity else {
            return false
        }
        var named = stat()
        return Self.retryingLstat(
            path: ready.canonicalDirectoryPath,
            information: &named)
            && (named.st_mode & S_IFMT) == S_IFDIR
            && HistoryFileIdentity(named) == ready.directoryIdentity
            && Self.retryingZero({
                Darwin.fchmod(ready.directoryDescriptor, Self.privateDirectoryMode)
            })
            && Self.retryingZero({ Darwin.fstat(ready.directoryDescriptor, &information) })
            && (information.st_mode & Self.permissionMask) == Self.privateDirectoryMode
    }

    private func openCoordinationFile(
        _ ready: HistoryPersistenceReadyState
    ) -> HistoryCoordinationResult<Int32> {
        for _ in 0..<3 {
            var named = stat()
            let status = inspectNamed(
                ready: ready,
                name: Self.lockName,
                information: &named)
            let descriptor: Int32
            let preopenIdentity: HistoryFileIdentity?
            if status == 0 {
                guard (named.st_mode & S_IFMT) == S_IFREG else {
                    return .failed(code: "history.persistence.unsafeLock")
                }
                preopenIdentity = HistoryFileIdentity(named)
                descriptor = Self.retryingDescriptor {
                    Self.lockName.withCString {
                        Darwin.openat(
                            ready.directoryDescriptor,
                            $0,
                            O_RDWR | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
                    }
                }
            } else if errno == ENOENT {
                descriptor = Self.retryingDescriptor {
                    Self.lockName.withCString {
                        Darwin.openat(
                            ready.directoryDescriptor,
                            $0,
                            O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK,
                            Self.privateFileMode)
                    }
                }
                if descriptor < 0, errno == EEXIST { continue }
                preopenIdentity = nil
            } else {
                return .failed(code: "history.persistence.unsafeLock")
            }
            guard descriptor >= 0 else {
                return .failed(code: "history.persistence.lockOpenFailed")
            }

            var information = stat()
            guard Self.retryingZero({ Darwin.fstat(descriptor, &information) }),
                  (information.st_mode & S_IFMT) == S_IFREG,
                  preopenIdentity.map({ $0 == HistoryFileIdentity(information) }) ?? true,
                  Self.retryingZero({ Darwin.fchmod(descriptor, Self.privateFileMode) }),
                  Self.retryingZero({ Darwin.fstat(descriptor, &information) }),
                  (information.st_mode & Self.permissionMask) == Self.privateFileMode,
                  namedIdentity(
                    ready: ready,
                    name: Self.lockName,
                    expected: HistoryFileIdentity(information)) else {
                _ = Darwin.close(descriptor)
                return .failed(code: "history.persistence.unsafeLock")
            }
            hooks.didOpen(.lock, descriptor)
            return .value(descriptor)
        }
        return .failed(code: "history.persistence.unsafeLock")
    }

    private func loadLocked(ready: HistoryPersistenceReadyState) -> HistoryArchiveProbe {
        var named = stat()
        let namedStatus = inspectNamed(
            ready: ready,
            name: Self.archiveName,
            information: &named)
        if namedStatus != 0 {
            if errno == ENOENT {
                return HistoryArchiveProbe(
                    result: .missing,
                    identity: nil,
                    fingerprint: nil)
            }
            return failedArchiveProbe("history.persistence.archiveOpenFailed")
        }
        guard (named.st_mode & S_IFMT) == S_IFREG else {
            return failedArchiveProbe("history.persistence.unsafeArchive")
        }
        let preopenIdentity = HistoryFileIdentity(named)

        let descriptor = Self.retryingDescriptor {
            Self.archiveName.withCString {
                Darwin.openat(
                    ready.directoryDescriptor,
                    $0,
                    O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
            }
        }
        guard descriptor >= 0 else {
            return failedArchiveProbe("history.persistence.archiveOpenFailed")
        }
        var tracked = false
        defer {
            if tracked {
                closeTracked(descriptor, role: .archive)
            } else {
                _ = Darwin.close(descriptor)
            }
        }

        var before = stat()
        guard Self.retryingZero({ Darwin.fstat(descriptor, &before) }),
              (before.st_mode & S_IFMT) == S_IFREG,
              HistoryFileIdentity(before) == preopenIdentity,
              Self.retryingZero({ Darwin.fchmod(descriptor, Self.privateFileMode) }),
              Self.retryingZero({ Darwin.fstat(descriptor, &before) }),
              (before.st_mode & Self.permissionMask) == Self.privateFileMode else {
            return failedArchiveProbe("history.persistence.unsafeArchive")
        }
        let openedIdentity = HistoryFileIdentity(before)
        guard namedIdentity(
            ready: ready,
            name: Self.archiveName,
            expected: openedIdentity) else {
            return failedArchiveProbe("history.persistence.unsafeArchive")
        }
        guard before.st_size >= 0,
              let byteCount = Int(exactly: before.st_size),
              byteCount <= Self.maximumReadBytes else {
            return failedArchiveProbe("history.archive.limitExceeded")
        }

        hooks.didOpen(.archive, descriptor)
        tracked = true
        let readResult = readAll(descriptor: descriptor, byteCount: byteCount)
        guard case let .data(data) = readResult else {
            if case let .failed(code) = readResult { return failedArchiveProbe(code) }
            return failedArchiveProbe("history.persistence.archiveReadFailed")
        }

        var after = stat()
        guard Self.retryingZero({ Darwin.fstat(descriptor, &after) }),
              HistoryFileIdentity(after) == openedIdentity,
              after.st_size == before.st_size,
              after.st_mtimespec.tv_sec == before.st_mtimespec.tv_sec,
              after.st_mtimespec.tv_nsec == before.st_mtimespec.tv_nsec,
              after.st_ctimespec.tv_sec == before.st_ctimespec.tv_sec,
              after.st_ctimespec.tv_nsec == before.st_ctimespec.tv_nsec,
              namedIdentity(
                ready: ready,
                name: Self.archiveName,
                expected: openedIdentity) else {
            return failedArchiveProbe("history.persistence.archiveChangedDuringRead")
        }
        let revision = HistoryRevision.digest(of: data)
        return HistoryArchiveProbe(
            result: .loaded(HistoryPersistenceSnapshot(data: data, revision: revision)),
            identity: openedIdentity,
            fingerprint: HistoryFileFingerprint(after))
    }

    private func commitLocked(
        _ data: Data,
        expectedRevision: HistoryRevision,
        ready: HistoryPersistenceReadyState
    ) -> HistoryCommitResult {
        guard expectedRevision.isWellFormed else {
            return .conflict(latest: .failed(
                code: "history.persistence.invalidExpectedRevision"))
        }
        let current = loadLocked(ready: ready)
        let currentRevision: HistoryRevision
        switch current.result {
        case .missing:
            currentRevision = .missing
        case let .loaded(snapshot):
            let actualRevision = HistoryRevision.digest(of: snapshot.data)
            guard snapshot.revision.isWellFormed,
                  snapshot.revision == actualRevision else {
                return .conflict(latest: .failed(
                    code: "history.persistence.invalidObservedRevision"))
            }
            currentRevision = snapshot.revision
        case let .failed(code):
            return .conflict(latest: .failed(code: code))
        }
        guard currentRevision == expectedRevision else {
            return .conflict(latest: current.result)
        }

        let stagingResult = openStaging(ready: ready)
        guard case let .opened(staging) = stagingResult else {
            if case let .failed(code) = stagingResult { return .failed(code: code) }
            return .failed(code: "history.persistence.stagingCreateFailed")
        }
        var renamed = false
        defer {
            if !renamed {
                cleanupOwnedStaging(staging, ready: ready)
            }
            closeTracked(staging.descriptor, role: .staging)
        }

        guard namedIdentity(
            ready: ready,
            name: staging.name,
            expected: staging.identity) else {
            return .failed(code: "history.persistence.stagingIdentityChanged")
        }
        guard writeAll(data, descriptor: staging.descriptor) else {
            return .failed(code: "history.persistence.stagingWriteFailed")
        }
        guard sync(descriptor: staging.descriptor, role: .staging) else {
            return .failed(code: "history.persistence.stagingFsyncFailed")
        }
        guard namedIdentity(
            ready: ready,
            name: staging.name,
            expected: staging.identity) else {
            return .failed(code: "history.persistence.stagingIdentityChanged")
        }
        guard archiveStillMatches(current, ready: ready) else {
            return .conflict(latest: .failed(code: "history.persistence.unsafeArchive"))
        }

        let renameResult = hooks.rename(
            ready.directoryDescriptor,
            staging.name,
            Self.archiveName)
        guard renameResult == 0 else {
            return .failed(code: "history.persistence.renameFailed")
        }
        renamed = true

        guard sync(descriptor: ready.directoryDescriptor, role: .parentDirectory) else {
            return .indeterminate(
                latest: loadLocked(ready: ready).result,
                code: "history.persistence.parentFsyncFailed")
        }
        guard namedIdentity(
            ready: ready,
            name: Self.archiveName,
            expected: staging.identity) else {
            return .indeterminate(
                latest: loadLocked(ready: ready).result,
                code: "history.persistence.archiveIdentityChanged")
        }
        return .committed(newRevision: HistoryRevision.digest(of: data))
    }

    private func openStaging(
        ready: HistoryPersistenceReadyState
    ) -> HistoryStagingOpenResult {
        let name = hooks.stagingName()
        guard isSafeStagingName(name) else {
            return .failed(code: "history.persistence.unsafeStaging")
        }
        var existing = stat()
        let existingStatus = inspectNamed(
            ready: ready,
            name: name,
            information: &existing)
        if existingStatus == 0 {
            return .failed(code: "history.persistence.unsafeStaging")
        }
        guard errno == ENOENT else {
            return .failed(code: "history.persistence.stagingCreateFailed")
        }

        let descriptor = Self.retryingDescriptor {
            name.withCString {
                Darwin.openat(
                    ready.directoryDescriptor,
                    $0,
                    O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK,
                    Self.privateFileMode)
            }
        }
        guard descriptor >= 0 else {
            return .failed(code: errno == EEXIST
                ? "history.persistence.unsafeStaging"
                : "history.persistence.stagingCreateFailed")
        }

        var information = stat()
        guard Self.retryingZero({ Darwin.fstat(descriptor, &information) }),
              (information.st_mode & S_IFMT) == S_IFREG else {
            _ = Darwin.close(descriptor)
            return .failed(code: "history.persistence.unsafeStaging")
        }
        var opened = HistoryOpenedStaging(
            name: name,
            descriptor: descriptor,
            identity: HistoryFileIdentity(information))
        guard Self.retryingZero({ Darwin.fchmod(descriptor, Self.privateFileMode) }),
              Self.retryingZero({ Darwin.fstat(descriptor, &information) }),
              (information.st_mode & Self.permissionMask) == Self.privateFileMode,
              HistoryFileIdentity(information) == opened.identity else {
            cleanupOwnedStaging(opened, ready: ready)
            _ = Darwin.close(descriptor)
            return .failed(code: "history.persistence.unsafeStaging")
        }
        opened = HistoryOpenedStaging(
            name: name,
            descriptor: descriptor,
            identity: HistoryFileIdentity(information))
        guard namedIdentity(
            ready: ready,
            name: name,
            expected: opened.identity) else {
            cleanupOwnedStaging(opened, ready: ready)
            _ = Darwin.close(descriptor)
            return .failed(code: "history.persistence.stagingIdentityChanged")
        }
        hooks.didOpen(.staging, descriptor)
        return .opened(opened)
    }

    private func isSafeStagingName(_ name: String) -> Bool {
        !name.isEmpty
            && name != "."
            && name != ".."
            && name != Self.archiveName
            && name != Self.lockName
            && !name.contains("/")
            && name.utf8.count <= 255
    }

    private func writeAll(_ data: Data, descriptor: Int32) -> Bool {
        data.withUnsafeBytes { buffer in
            guard !data.isEmpty else { return true }
            guard let baseAddress = buffer.baseAddress else { return false }
            var offset = 0
            while offset < data.count {
                let amount = hooks.write(
                    descriptor,
                    baseAddress.advanced(by: offset),
                    data.count - offset)
                if amount > 0, amount <= data.count - offset {
                    offset += amount
                } else if amount == 0 {
                    return false
                } else if errno != EINTR {
                    return false
                }
            }
            return true
        }
    }

    private func sync(
        descriptor: Int32,
        role: HistoryPersistenceFileRole
    ) -> Bool {
        while true {
            let result = hooks.fsync(descriptor, role)
            if result == 0 { return true }
            if errno != EINTR { return false }
        }
    }

    private func archiveStillMatches(
        _ probe: HistoryArchiveProbe,
        ready: HistoryPersistenceReadyState
    ) -> Bool {
        switch probe.result {
        case .missing:
            var information = stat()
            let result = inspectNamed(
                ready: ready,
                name: Self.archiveName,
                information: &information)
            return result != 0 && errno == ENOENT
        case .loaded:
            guard let expected = probe.fingerprint else { return false }
            var information = stat()
            return inspectNamed(
                ready: ready,
                name: Self.archiveName,
                information: &information) == 0
                && (information.st_mode & S_IFMT) == S_IFREG
                && HistoryFileFingerprint(information) == expected
        case .failed:
            return false
        }
    }

    private func cleanupOwnedStaging(
        _ staging: HistoryOpenedStaging,
        ready: HistoryPersistenceReadyState
    ) {
        guard namedIdentity(
            ready: ready,
            name: staging.name,
            expected: staging.identity) else { return }
        while true {
            let result = staging.name.withCString {
                Darwin.unlinkat(ready.directoryDescriptor, $0, 0)
            }
            if result == 0 || errno == ENOENT { return }
            if errno != EINTR { return }
        }
    }

    private func readAll(descriptor: Int32, byteCount: Int) -> HistoryDataReadResult {
        var data = Data(count: byteCount)
        let code: String? = data.withUnsafeMutableBytes { buffer in
            guard byteCount > 0 else { return nil }
            guard let baseAddress = buffer.baseAddress else {
                return "history.persistence.archiveReadFailed"
            }
            var offset = 0
            while offset < byteCount {
                let amount = hooks.read(
                    descriptor,
                    baseAddress.advanced(by: offset),
                    byteCount - offset)
                if amount > 0, amount <= byteCount - offset {
                    offset += amount
                } else if amount == 0 {
                    return "history.persistence.archiveReadFailed"
                } else if errno != EINTR {
                    return "history.persistence.archiveReadFailed"
                }
            }
            return nil
        }
        return code.map(HistoryDataReadResult.failed) ?? .data(data)
    }

    private func identity(of descriptor: Int32) -> HistoryFileIdentity? {
        var information = stat()
        guard Self.retryingZero({ Darwin.fstat(descriptor, &information) }) else {
            return nil
        }
        return HistoryFileIdentity(information)
    }

    private func namedIdentity(
        ready: HistoryPersistenceReadyState,
        name: String,
        expected: HistoryFileIdentity?
    ) -> Bool {
        guard let expected else { return false }
        var information = stat()
        let result = inspectNamed(
            ready: ready,
            name: name,
            information: &information)
        return result == 0
            && (information.st_mode & S_IFMT) == S_IFREG
            && HistoryFileIdentity(information) == expected
    }

    private func inspectNamed(
        ready: HistoryPersistenceReadyState,
        name: String,
        information: inout stat
    ) -> Int32 {
        while true {
            let result = name.withCString {
                Darwin.fstatat(
                    ready.directoryDescriptor,
                    $0,
                    &information,
                    AT_SYMLINK_NOFOLLOW)
            }
            if result == 0 || errno != EINTR { return result }
        }
    }

    private func closeTracked(_ descriptor: Int32, role: HistoryPersistenceFileRole) {
        _ = Darwin.close(descriptor)
        hooks.didClose(role, descriptor)
    }

    private func failedArchiveProbe(_ code: String) -> HistoryArchiveProbe {
        HistoryArchiveProbe(
            result: .failed(code: code),
            identity: nil,
            fingerprint: nil)
    }
}
