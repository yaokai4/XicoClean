import Foundation
import Domain
#if canImport(Darwin)
import Darwin
#endif

struct BoundedRegularFileRead: Sendable {
    let data: Data
    let identity: LocalFileIdentity
}

enum BoundedRegularFileReader {
    static func read(at url: URL,
                     maximumBytes: Int,
                     afterRead: @Sendable () -> Void = {}) -> BoundedRegularFileRead? {
        #if canImport(Darwin)
        var pathStat = stat()
        guard lstat(url.path, &pathStat) == 0,
              (pathStat.st_mode & S_IFMT) == S_IFREG,
              pathStat.st_size >= 0,
              pathStat.st_size <= maximumBytes else { return nil }

        let descriptor = open(url.path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }

        var openedStat = stat()
        guard fstat(descriptor, &openedStat) == 0,
              (openedStat.st_mode & S_IFMT) == S_IFREG,
              openedStat.st_dev == pathStat.st_dev,
              openedStat.st_ino == pathStat.st_ino,
              openedStat.st_size >= 0,
              openedStat.st_size <= maximumBytes,
              let openedIdentity = identity(from: openedStat) else { return nil }

        var data = Data()
        data.reserveCapacity(Int(openedStat.st_size))
        var buffer = [UInt8](repeating: 0, count: 32 * 1024)
        while true {
            let count = buffer.withUnsafeMutableBytes {
                Darwin.read(descriptor, $0.baseAddress, $0.count)
            }
            if count == 0 { break }
            if count < 0 {
                if errno == EINTR { continue }
                return nil
            }
            guard data.count + count <= maximumBytes else { return nil }
            data.append(contentsOf: buffer.prefix(count))
        }

        afterRead()
        var finalOpenedStat = stat()
        var finalPathStat = stat()
        guard fstat(descriptor, &finalOpenedStat) == 0,
              lstat(url.path, &finalPathStat) == 0,
              (finalOpenedStat.st_mode & S_IFMT) == S_IFREG,
              (finalPathStat.st_mode & S_IFMT) == S_IFREG,
              finalOpenedStat.st_dev == openedStat.st_dev,
              finalOpenedStat.st_ino == openedStat.st_ino,
              finalOpenedStat.st_size == openedStat.st_size,
              finalPathStat.st_dev == openedStat.st_dev,
              finalPathStat.st_ino == openedStat.st_ino,
              identity(from: finalOpenedStat) == openedIdentity,
              identity(from: finalPathStat) == openedIdentity else { return nil }
        return BoundedRegularFileRead(data: data, identity: openedIdentity)
        #else
        return nil
        #endif
    }

    #if canImport(Darwin)
    private static func identity(from value: stat) -> LocalFileIdentity? {
        let seconds = Int64(value.st_mtimespec.tv_sec)
        let nanoseconds = Int64(value.st_mtimespec.tv_nsec)
        let (scaled, overflow) = seconds.multipliedReportingOverflow(by: 1_000_000_000)
        guard !overflow else { return nil }
        let (mtime, additionOverflow) = scaled.addingReportingOverflow(nanoseconds)
        guard !additionOverflow else { return nil }
        return LocalFileIdentity(device: UInt64(value.st_dev), inode: UInt64(value.st_ino),
                                 mode: UInt32(value.st_mode), size: Int64(value.st_size),
                                 mtimeNanoseconds: mtime,
                                 hardLinkCount: UInt64(value.st_nlink))
    }
    #endif
}
