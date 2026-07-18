import Foundation
import CryptoKit
import Domain
#if canImport(Darwin)
import Darwin
#endif

/// Immutable proof that a target was reached from the configured home directory by opening each
/// `Library/...` component with no-follow semantics. The ordered identities include home,
/// Library, category, every parent, and the target leaf.
struct PhysicalPathAttestation: Sendable, Equatable, Hashable {
    let canonicalPath: String
    let componentNames: [String]
    let componentIdentities: [LocalFileIdentity]

    var homeRootIdentity: LocalFileIdentity { componentIdentities[0] }
    var libraryRootIdentity: LocalFileIdentity { componentIdentities[1] }
    var categoryIdentity: LocalFileIdentity { componentIdentities[2] }
    var targetParentIdentity: LocalFileIdentity {
        componentIdentities[componentIdentities.count - 2]
    }
    var targetIdentity: LocalFileIdentity { componentIdentities[componentIdentities.count - 1] }
}

struct BoundedFileAttestation: Sendable, Equatable, Hashable {
    let identity: LocalFileIdentity
    let exactLength: Int
    let contentDigest: EvidenceFingerprint
}

package struct AnchoredRegularFileRead: Sendable {
    let data: Data
    let pathAttestation: PhysicalPathAttestation
    let fileAttestation: BoundedFileAttestation
}

protocol LibraryPathAttesting: Sendable {
    func attest(_ url: URL) -> PhysicalPathAttestation?
    func readRegularFile(_ url: URL, maximumBytes: Int) -> AnchoredRegularFileRead?
}

/// Read-only POSIX attestor. It never receives the write-capable shredder syscall interface and
/// exposes no mutation operation.
struct FDAnchoredLibraryPathAttestor: LibraryPathAttesting {
    private static let allowedCategories: Set<String> = [
        "Application Support", "Caches", "Preferences", "Containers",
        "Saved Application State", "Logs", "HTTPStorages", "WebKit",
        "Group Containers", "LaunchAgents"
    ]

    let home: URL

    init(home: URL) { self.home = home }

    func attest(_ url: URL) -> PhysicalPathAttestation? {
        capture(url, maximumBytes: nil)?.path
    }

    func readRegularFile(_ url: URL, maximumBytes: Int) -> AnchoredRegularFileRead? {
        guard let result = capture(url, maximumBytes: maximumBytes),
              let data = result.data,
              let file = result.file else { return nil }
        return AnchoredRegularFileRead(data: data, pathAttestation: result.path,
                                       fileAttestation: file)
    }

    private struct OpenedNode {
        let nameFromParent: String?
        let descriptor: Int32
        let identity: LocalFileIdentity
    }

    private struct CaptureResult {
        let path: PhysicalPathAttestation
        let data: Data?
        let file: BoundedFileAttestation?
    }

    private func capture(_ url: URL, maximumBytes: Int?) -> CaptureResult? {
        #if canImport(Darwin)
        guard let relative = relativeComponents(for: url),
              relative.count >= 2,
              Self.allowedCategories.contains(relative[0]),
              relative.allSatisfy(Self.isValidComponent) else { return nil }

        var opened: [OpenedNode] = []
        defer { for node in opened.reversed() { close(node.descriptor) } }

        guard let homeBefore = Self.lstatIdentity(home.path),
              Self.isDirectory(homeBefore) else { return nil }
        let homeFD = open(home.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard homeFD >= 0,
              Self.fstatIdentity(homeFD) == homeBefore else {
            if homeFD >= 0 { close(homeFD) }
            return nil
        }
        opened.append(OpenedNode(nameFromParent: nil, descriptor: homeFD,
                                 identity: homeBefore))

        let names = ["Library"] + relative
        for (index, name) in names.enumerated() {
            let parent = opened[opened.count - 1]
            guard let before = Self.fstatatIdentity(parent.descriptor, name),
                  index == names.count - 1
                    ? (Self.isDirectory(before) || Self.isRegular(before))
                    : Self.isDirectory(before) else { return nil }
            let flags = index == names.count - 1 && Self.isRegular(before)
                ? O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC
                : O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
            let descriptor = openat(parent.descriptor, name, flags)
            guard descriptor >= 0,
                  Self.fstatIdentity(descriptor) == before else {
                if descriptor >= 0 { close(descriptor) }
                return nil
            }
            opened.append(OpenedNode(nameFromParent: name, descriptor: descriptor,
                                     identity: before))
        }

        let objectIDs = opened.map { ObjectID($0.identity) }
        guard Set(objectIDs).count == objectIDs.count else { return nil }

        var data: Data?
        var fileAttestation: BoundedFileAttestation?
        if let maximumBytes {
            let leaf = opened[opened.count - 1]
            guard Self.isRegular(leaf.identity), leaf.identity.size >= 0,
                  leaf.identity.size <= Int64(maximumBytes),
                  leaf.identity.size <= Int64(Int.max) else { return nil }
            var bytes = Data()
            bytes.reserveCapacity(Int(leaf.identity.size))
            var buffer = [UInt8](repeating: 0, count: 32 * 1024)
            while true {
                let count = buffer.withUnsafeMutableBytes {
                    Darwin.read(leaf.descriptor, $0.baseAddress, $0.count)
                }
                if count == 0 { break }
                if count < 0 {
                    if errno == EINTR { continue }
                    return nil
                }
                let (nextCount, overflow) = bytes.count.addingReportingOverflow(count)
                guard !overflow, nextCount <= maximumBytes else { return nil }
                bytes.append(contentsOf: buffer.prefix(count))
            }
            guard bytes.count == Int(leaf.identity.size),
                  let digest = EvidenceFingerprint(
                    sha256: Array(SHA256.hash(data: bytes))) else { return nil }
            data = bytes
            fileAttestation = BoundedFileAttestation(identity: leaf.identity,
                                                      exactLength: bytes.count,
                                                      contentDigest: digest)
        }

        // Recheck every opened object and every parent->child directory edge in reverse order.
        for node in opened.reversed() {
            guard Self.fstatIdentity(node.descriptor) == node.identity else { return nil }
        }
        if opened.count > 1 {
            for index in stride(from: opened.count - 1, through: 1, by: -1) {
                let child = opened[index]
                let parent = opened[index - 1]
                guard let name = child.nameFromParent,
                      Self.fstatatIdentity(parent.descriptor, name) == child.identity else {
                    return nil
                }
            }
        }

        let attestation = PhysicalPathAttestation(
            canonicalPath: url.path,
            componentNames: names,
            componentIdentities: opened.map(\.identity))
        return CaptureResult(path: attestation, data: data, file: fileAttestation)
        #else
        return nil
        #endif
    }

    private func relativeComponents(for url: URL) -> [String]? {
        let homeComponents = home.pathComponents
        let targetComponents = url.pathComponents
        let prefix = homeComponents + ["Library"]
        guard targetComponents.count > prefix.count,
              targetComponents.prefix(prefix.count).elementsEqual(prefix) else { return nil }
        return Array(targetComponents.dropFirst(prefix.count))
    }

    private static func isValidComponent(_ value: String) -> Bool {
        let bytes = value.utf8
        return !value.isEmpty && value != "." && value != ".." && bytes.count <= 255
            && !value.contains("/") && !value.contains("\\") && !value.contains("\0")
    }

    private struct ObjectID: Hashable {
        let device: UInt64
        let inode: UInt64
        init(_ identity: LocalFileIdentity) {
            device = identity.device
            inode = identity.inode
        }
    }

    #if canImport(Darwin)
    private static func lstatIdentity(_ path: String) -> LocalFileIdentity? {
        var value = stat()
        return lstat(path, &value) == 0 ? identity(value) : nil
    }

    private static func fstatIdentity(_ descriptor: Int32) -> LocalFileIdentity? {
        var value = stat()
        return fstat(descriptor, &value) == 0 ? identity(value) : nil
    }

    private static func fstatatIdentity(_ parent: Int32, _ name: String) -> LocalFileIdentity? {
        var value = stat()
        return fstatat(parent, name, &value, AT_SYMLINK_NOFOLLOW) == 0 ? identity(value) : nil
    }

    private static func identity(_ value: stat) -> LocalFileIdentity? {
        guard let mtime = nanoseconds(value.st_mtimespec),
              let ctime = nanoseconds(value.st_ctimespec) else { return nil }
        return LocalFileIdentity(device: UInt64(value.st_dev), inode: UInt64(value.st_ino),
                                 mode: UInt32(value.st_mode), size: Int64(value.st_size),
                                 mtimeNanoseconds: mtime, changeTimeNanoseconds: ctime,
                                 hardLinkCount: UInt64(value.st_nlink))
    }

    private static func nanoseconds(_ value: timespec) -> Int64? {
        let (scaled, overflow) = Int64(value.tv_sec)
            .multipliedReportingOverflow(by: 1_000_000_000)
        guard !overflow else { return nil }
        let (result, additionOverflow) = scaled.addingReportingOverflow(Int64(value.tv_nsec))
        return additionOverflow ? nil : result
    }

    private static func isDirectory(_ identity: LocalFileIdentity) -> Bool {
        (identity.mode & UInt32(S_IFMT)) == UInt32(S_IFDIR)
    }

    private static func isRegular(_ identity: LocalFileIdentity) -> Bool {
        (identity.mode & UInt32(S_IFMT)) == UInt32(S_IFREG)
    }
    #endif
}
