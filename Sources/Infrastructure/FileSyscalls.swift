import Foundation
import Domain
#if canImport(Darwin)
import Darwin
#endif

/// A stat result reduced to the fields destructive operations reason about. Mirrors
/// `LocalFileIdentity` plus the raw `st_mode` type bits, so callers can classify the
/// entry (regular / dir / symlink / other) and recheck identity without re-`stat`ing by
/// path (TOCTOU-safe when driven from an anchored fd).
public struct FileStat: Equatable, Sendable {
    public let device: UInt64
    public let inode: UInt64
    public let mode: UInt32
    public let size: Int64
    public let mtimeNanoseconds: Int64
    public let changeTimeNanoseconds: Int64
    public let hardLinkCount: UInt64

    public init(device: UInt64, inode: UInt64, mode: UInt32, size: Int64,
                mtimeNanoseconds: Int64, changeTimeNanoseconds: Int64 = 0,
                hardLinkCount: UInt64) {
        self.device = device
        self.inode = inode
        self.mode = mode
        self.size = size
        self.mtimeNanoseconds = mtimeNanoseconds
        self.changeTimeNanoseconds = changeTimeNanoseconds
        self.hardLinkCount = hardLinkCount
    }

    /// The `S_IFMT` type bits, e.g. `S_IFREG` / `S_IFDIR` / `S_IFLNK`.
    public var typeBits: UInt32 { mode & UInt32(S_IFMT) }
    public var isRegularFile: Bool { typeBits == UInt32(S_IFREG) }
    public var isDirectory: Bool { typeBits == UInt32(S_IFDIR) }
    public var isSymlink: Bool { typeBits == UInt32(S_IFLNK) }

    /// Projects to the domain identity used in destructive plans.
    public var localIdentity: LocalFileIdentity {
        LocalFileIdentity(device: device, inode: inode, mode: mode, size: size,
                          mtimeNanoseconds: mtimeNanoseconds,
                          changeTimeNanoseconds: changeTimeNanoseconds,
                          hardLinkCount: hardLinkCount)
    }
}

/// A result of `pwrite`: either a byte count actually written, or a POSIX errno. The
/// shredder decrements `remaining` only by real bytes written (SHR-09).
public enum WriteResult: Equatable, Sendable {
    case wrote(Int)
    case failed(errno: Int32)
}

/// Injectable POSIX seam for the destructive engines, following the
/// `POSIXLaunchctlProcessDriver` precedent. Every call is fd-relative or fd-based so a
/// fake can drive short writes / `EINTR` / `ENOSPC` / `EIO` / `fsync` failures
/// deterministically, and the preparation phase can be exercised without real files.
public protocol FileSyscalls: Sendable {
    /// `open(path, O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC)`. Returns -1 on failure.
    func openDirectory(path: String) -> Int32
    /// `openat(parentFD, name, O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC)`. -1 on failure.
    func openChildDirectory(parentFD: Int32, name: String) -> Int32
    /// `openat(parentFD, name, O_WRONLY|O_NOFOLLOW|O_CLOEXEC)`. -1 on failure.
    func openRegularForWrite(parentFD: Int32, name: String) -> Int32
    /// Drains the directory entries (excluding `.`/`..`) via a duplicated fd, snapshot
    /// style. Returns nil on failure.
    func listChildren(dirFD: Int32) -> [String]?
    /// `fstatat(parentFD, name, AT_SYMLINK_NOFOLLOW)`. Never follows a final symlink.
    func statChild(parentFD: Int32, name: String) -> FileStat?
    /// `fstat(fd)`.
    func statOpen(fd: Int32) -> FileStat?
    /// `pwrite(fd, bytes, offset)`.
    func pwrite(fd: Int32, bytes: UnsafeRawBufferPointer, offset: Int64) -> WriteResult
    /// `fsync(fd)`. Returns 0 on success, -1 on failure.
    func fsync(fd: Int32) -> Int32
    /// `ftruncate(fd, length)`. Returns 0 on success.
    func ftruncate(fd: Int32, length: Int64) -> Int32
    /// `unlinkat(parentFD, name, removeDir ? AT_REMOVEDIR : 0)`. Returns 0 on success.
    func unlinkChild(parentFD: Int32, name: String, removeDir: Bool) -> Int32
    /// `close(fd)`.
    func closeDescriptor(_ fd: Int32)
}

#if canImport(Darwin)
/// Production implementation over Darwin POSIX. Preserves the shredder's SHR-07 base:
/// fd-relative, `O_NOFOLLOW`, `F_DUPFD_CLOEXEC`, snapshot drain.
public struct SystemFileSyscalls: FileSyscalls {
    public init() {}

    public func openDirectory(path: String) -> Int32 {
        open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    }

    public func openChildDirectory(parentFD: Int32, name: String) -> Int32 {
        openat(parentFD, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    }

    public func openRegularForWrite(parentFD: Int32, name: String) -> Int32 {
        openat(parentFD, name, O_WRONLY | O_NOFOLLOW | O_CLOEXEC)
    }

    public func listChildren(dirFD: Int32) -> [String]? {
        let streamFD = fcntl(dirFD, F_DUPFD_CLOEXEC, 0)
        guard streamFD >= 0, let dir = fdopendir(streamFD) else {
            if streamFD >= 0 { close(streamFD) }
            return nil
        }
        var names: [String] = []
        while let ent = readdir(dir) {
            let name = withUnsafeBytes(of: ent.pointee.d_name) { raw -> String in
                String(cString: raw.baseAddress!.assumingMemoryBound(to: CChar.self))
            }
            if name == "." || name == ".." { continue }
            names.append(name)
        }
        closedir(dir)   // closes the duplicated stream fd; caller keeps dirFD as anchor
        return names
    }

    public func statChild(parentFD: Int32, name: String) -> FileStat? {
        var st = stat()
        guard fstatat(parentFD, name, &st, AT_SYMLINK_NOFOLLOW) == 0 else { return nil }
        return Self.map(st)
    }

    public func statOpen(fd: Int32) -> FileStat? {
        var st = stat()
        guard fstat(fd, &st) == 0 else { return nil }
        return Self.map(st)
    }

    public func pwrite(fd: Int32, bytes: UnsafeRawBufferPointer, offset: Int64) -> WriteResult {
        let n = Darwin.pwrite(fd, bytes.baseAddress, bytes.count, off_t(offset))
        if n < 0 { return .failed(errno: errno) }
        return .wrote(n)
    }

    public func fsync(fd: Int32) -> Int32 { Darwin.fsync(fd) }
    public func ftruncate(fd: Int32, length: Int64) -> Int32 { Darwin.ftruncate(fd, off_t(length)) }

    public func unlinkChild(parentFD: Int32, name: String, removeDir: Bool) -> Int32 {
        unlinkat(parentFD, name, removeDir ? AT_REMOVEDIR : 0)
    }

    public func closeDescriptor(_ fd: Int32) { close(fd) }

    private static func map(_ st: stat) -> FileStat? {
        guard let mtimeNanos = nanoseconds(st.st_mtimespec),
              let ctimeNanos = nanoseconds(st.st_ctimespec) else { return nil }
        return FileStat(device: UInt64(bitPattern: Int64(st.st_dev)),
                        inode: st.st_ino,
                        mode: UInt32(st.st_mode),
                        size: Int64(st.st_size),
                        mtimeNanoseconds: mtimeNanos,
                        changeTimeNanoseconds: ctimeNanos,
                        hardLinkCount: UInt64(st.st_nlink))
    }

    private static func nanoseconds(_ value: timespec) -> Int64? {
        let (scaled, overflow) = Int64(value.tv_sec)
            .multipliedReportingOverflow(by: 1_000_000_000)
        guard !overflow else { return nil }
        let (result, additionOverflow) = scaled.addingReportingOverflow(Int64(value.tv_nsec))
        return additionOverflow ? nil : result
    }
}
#endif
