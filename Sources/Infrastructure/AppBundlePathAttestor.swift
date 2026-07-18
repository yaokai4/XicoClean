import CryptoKit
import Domain
import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Full no-follow proof for an admitted app directory. Identities are ordered from `/` through
/// the app leaf, and include ctime so an ordinary caller cannot rewrite and restore the token.
struct AppBundlePathProof: Sendable, Equatable, Hashable {
    let canonicalPath: String
    let rootRelativeComponents: [String]
    let componentIdentities: [LocalFileIdentity]
    let chainFingerprint: EvidenceFingerprint

    var filesystemRootIdentity: LocalFileIdentity { componentIdentities[0] }
    var appRootIdentity: LocalFileIdentity { componentIdentities[componentIdentities.count - 1] }
}

/// Immutable content proof. The bytes travel only in `AnchoredAppBundleFileRead`; source seals
/// retain the bounded length/digest and the exact physical path chain, not a mutable URL read.
struct AppBundleBoundedContentAttestation: Sendable, Equatable, Hashable {
    let relativeComponentsInsideApp: [String]
    let identity: LocalFileIdentity
    let exactLength: Int
    let contentDigest: EvidenceFingerprint
    let pathChainFingerprint: EvidenceFingerprint
}

struct AnchoredAppBundleFileRead: Sendable, Equatable {
    let data: Data
    let attestation: AppBundleBoundedContentAttestation
}

/// Change token for an absolute executable accepted only by traversing downward from the already
/// opened app fd. `boundedContentDigest` is present when the executable fits the caller's bound;
/// ctime and the directory-chain fingerprint remain mandatory for larger regular executables.
struct ProgramChangeToken: Sendable, Equatable, Hashable {
    let canonicalPath: String
    let relativeComponentsInsideApp: [String]
    let directoryChain: [LocalFileIdentity]
    let executable: LocalFileIdentity
    let chainFingerprint: EvidenceFingerprint
    let boundedExactLength: Int?
    let boundedContentDigest: EvidenceFingerprint?
}

/// Complete read-only source seal consumed by the two-session Security.framework inspector.
/// It deliberately contains no validation/session state and grants no deletion authority.
struct AppBundleSourceSeal: Sendable, Equatable, Hashable {
    let appRoot: LocalFileIdentity
    let appChainFingerprint: EvidenceFingerprint
    let infoPlist: AppBundleBoundedContentAttestation
    let mainExecutable: ProgramChangeToken
    let mainExecutableCanonicalPath: String
    let codeResources: AppBundleBoundedContentAttestation
    let nestedRosterFingerprint: EvidenceFingerprint
}

enum AppBundleAttestationStage: Sendable, Equatable {
    case appChainOpened
    case relativeLeafOpened(String)
    case relativeLeafReadBeforeFinalRecheck(String)
    case programOpened(String)
    case programReadBeforeFinalRecheck(String)
    case rosterDirectoryEntryObserved(directory: String, count: Int)
    case rosterEnumeratedBeforeFinalRecheck
    case sourcePassCompleted(Int)
}

struct AppBundleAttestationHooks: Sendable {
    static let none = AppBundleAttestationHooks { _ in }
    let at: @Sendable (AppBundleAttestationStage) -> Void

    init(_ at: @escaping @Sendable (AppBundleAttestationStage) -> Void) { self.at = at }
}

protocol AppBundlePathAttesting: Sendable {
    func attestApp() -> AppBundlePathProof?
    func readRegularFile(relativeComponents: [String],
                         maximumBytes: Int) -> AnchoredAppBundleFileRead?
    func programToken(absoluteURL: URL,
                      maximumDigestBytes: Int?) -> ProgramChangeToken?
    func captureSourceSeal(infoPlistMaximumBytes: Int,
                           codeResourcesMaximumBytes: Int,
                           programDigestMaximumBytes: Int?) -> AppBundleSourceSeal?
}

/// Read-only POSIX app-bundle attestor. It owns no writable syscall seam and never follows a
/// pathname component: every node is `fstatat(AT_SYMLINK_NOFOLLOW)` + `openat(O_NOFOLLOW)`, with
/// all held descriptors and parent-child edges rechecked before a proof is returned.
struct FDAnchoredAppBundlePathAttestor: AppBundlePathAttesting {
    private static let defaultMetadataLimit = 1_048_576
    private static let defaultProgramDigestLimit = 16 * 1_048_576
    private static let maximumAppChainComponents = 128
    private static let maximumAppChainPathBytes = 16 * 1_024
    private static let maximumRosterEntries = 4_096
    private static let maximumRosterDirectories = 128
    private static let maximumRosterDepth = 16
    private static let maximumRosterPathBytes = 256 * 1_024
    private static let maximumSymlinkTargetBytes = 4_096

    let appURL: URL
    let hooks: AppBundleAttestationHooks

    init(appURL: URL, hooks: AppBundleAttestationHooks = .none) {
        self.appURL = appURL
        self.hooks = hooks
    }

    func attestApp() -> AppBundlePathProof? {
        #if canImport(Darwin)
        guard let nodes = openAppChain() else { return nil }
        defer { Self.closeNodes(nodes) }
        guard Self.hasUniqueObjects(nodes.map(\.identity)),
              Self.recheck(nodes: nodes, additionalEdges: []) else { return nil }
        return appProof(nodes: nodes)
        #else
        return nil
        #endif
    }

    func readRegularFile(relativeComponents: [String],
                         maximumBytes: Int) -> AnchoredAppBundleFileRead? {
        #if canImport(Darwin)
        guard maximumBytes >= 0,
              !relativeComponents.isEmpty,
              relativeComponents.allSatisfy(Self.isValidComponent),
              var nodes = openAppChain() else { return nil }
        defer { Self.closeNodes(nodes) }

        guard openRelative(relativeComponents, leafKind: .regular, nodes: &nodes),
              Self.hasUniqueObjects(nodes.map(\.identity)) else { return nil }
        let leaf = nodes[nodes.count - 1]
        let relativePath = relativeComponents.joined(separator: "/")
        hooks.at(.relativeLeafOpened(relativePath))
        guard let exact = Self.readExact(descriptor: leaf.descriptor,
                                         identity: leaf.identity,
                                         maximumBytes: maximumBytes) else { return nil }
        hooks.at(.relativeLeafReadBeforeFinalRecheck(relativePath))
        guard Self.recheck(nodes: nodes, additionalEdges: []) else { return nil }
        let identities = nodes.map(\.identity)
        guard let chainFingerprint = Self.chainFingerprint(
            componentNames: appRootComponents() + relativeComponents,
            identities: identities) else { return nil }
        let attestation = AppBundleBoundedContentAttestation(
            relativeComponentsInsideApp: relativeComponents,
            identity: leaf.identity,
            exactLength: exact.data.count,
            contentDigest: exact.digest,
            pathChainFingerprint: chainFingerprint)
        return AnchoredAppBundleFileRead(data: exact.data, attestation: attestation)
        #else
        return nil
        #endif
    }

    func programToken(absoluteURL: URL,
                      maximumDigestBytes: Int? = nil) -> ProgramChangeToken? {
        #if canImport(Darwin)
        if let maximumDigestBytes, maximumDigestBytes < 0 { return nil }
        guard let relativeComponents = relativeComponentsInsideApp(for: absoluteURL),
              !relativeComponents.isEmpty,
              relativeComponents.allSatisfy(Self.isValidComponent),
              var nodes = openAppChain() else { return nil }
        defer { Self.closeNodes(nodes) }
        let appNodeIndex = nodes.count - 1

        guard openRelative(relativeComponents, leafKind: .regular, nodes: &nodes),
              Self.hasUniqueObjects(nodes.map(\.identity)) else { return nil }
        let leaf = nodes[nodes.count - 1]
        let relativePath = relativeComponents.joined(separator: "/")
        hooks.at(.programOpened(relativePath))

        var boundedLength: Int?
        var boundedDigest: EvidenceFingerprint?
        if let maximumDigestBytes,
           leaf.identity.size >= 0,
           leaf.identity.size <= Int64(maximumDigestBytes) {
            guard let exact = Self.readExact(descriptor: leaf.descriptor,
                                             identity: leaf.identity,
                                             maximumBytes: maximumDigestBytes) else { return nil }
            boundedLength = exact.data.count
            boundedDigest = exact.digest
        }
        hooks.at(.programReadBeforeFinalRecheck(relativePath))
        guard Self.recheck(nodes: nodes, additionalEdges: []) else { return nil }

        let directoryIdentities = nodes[appNodeIndex..<(nodes.count - 1)].map(\.identity)
        guard let fingerprint = Self.chainFingerprint(
            componentNames: appRootComponents() + relativeComponents,
            identities: nodes.map(\.identity)) else { return nil }
        return ProgramChangeToken(
            canonicalPath: absoluteURL.path,
            relativeComponentsInsideApp: relativeComponents,
            directoryChain: Array(directoryIdentities),
            executable: leaf.identity,
            chainFingerprint: fingerprint,
            boundedExactLength: boundedLength,
            boundedContentDigest: boundedDigest)
        #else
        return nil
        #endif
    }

    func captureSourceSeal(
        infoPlistMaximumBytes: Int = Self.defaultMetadataLimit,
        codeResourcesMaximumBytes: Int = Self.defaultMetadataLimit,
        programDigestMaximumBytes: Int? = Self.defaultProgramDigestLimit
    ) -> AppBundleSourceSeal? {
        guard infoPlistMaximumBytes >= 0, codeResourcesMaximumBytes >= 0,
              programDigestMaximumBytes.map({ $0 >= 0 }) ?? true,
              let first = captureSourcePass(
                infoPlistMaximumBytes: infoPlistMaximumBytes,
                codeResourcesMaximumBytes: codeResourcesMaximumBytes,
                programDigestMaximumBytes: programDigestMaximumBytes) else { return nil }
        hooks.at(.sourcePassCompleted(1))
        guard let second = captureSourcePass(
            infoPlistMaximumBytes: infoPlistMaximumBytes,
            codeResourcesMaximumBytes: codeResourcesMaximumBytes,
            programDigestMaximumBytes: programDigestMaximumBytes) else { return nil }
        hooks.at(.sourcePassCompleted(2))
        return first == second ? second : nil
    }

    private func captureSourcePass(infoPlistMaximumBytes: Int,
                                   codeResourcesMaximumBytes: Int,
                                   programDigestMaximumBytes: Int?) -> AppBundleSourceSeal? {
        guard let appBefore = attestApp(),
              let info = readRegularFile(
                relativeComponents: ["Contents", "Info.plist"],
                maximumBytes: infoPlistMaximumBytes),
              let executableName = Self.executableName(from: info.data),
              let codeResources = readRegularFile(
                relativeComponents: ["Contents", "_CodeSignature", "CodeResources"],
                maximumBytes: codeResourcesMaximumBytes) else { return nil }
        let mainExecutableURL = appURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("MacOS", isDirectory: true)
            .appendingPathComponent(executableName, isDirectory: false)
        guard let program = programToken(absoluteURL: mainExecutableURL,
                                         maximumDigestBytes: programDigestMaximumBytes),
              let roster = nestedRosterFingerprint(),
              let appAfter = attestApp(),
              appAfter == appBefore else { return nil }
        return AppBundleSourceSeal(
            appRoot: appBefore.appRootIdentity,
            appChainFingerprint: appBefore.chainFingerprint,
            infoPlist: info.attestation,
            mainExecutable: program,
            mainExecutableCanonicalPath: mainExecutableURL.path,
            codeResources: codeResources.attestation,
            nestedRosterFingerprint: roster)
    }

    private static func executableName(from data: Data) -> String? {
        guard let object = try? PropertyListSerialization.propertyList(
            from: data, options: [], format: nil),
              let dictionary = object as? [String: Any],
              let executable = dictionary["CFBundleExecutable"] as? String,
              isValidComponent(executable) else { return nil }
        return executable
    }

    private func appRootComponents() -> [String] {
        Array(appURL.pathComponents.dropFirst())
    }

    private func relativeComponentsInsideApp(for target: URL) -> [String]? {
        guard target.isFileURL, appURL.isFileURL else { return nil }
        let appComponents = appURL.pathComponents
        let targetComponents = target.pathComponents
        guard targetComponents.count > appComponents.count,
              targetComponents.prefix(appComponents.count).elementsEqual(appComponents) else {
            return nil
        }
        return Array(targetComponents.dropFirst(appComponents.count))
    }

    // MARK: - POSIX traversal

    #if canImport(Darwin)
    private enum RequiredLeafKind { case regular, directory }

    private struct OpenedNode {
        let parentDescriptor: Int32?
        let nameFromParent: String?
        let descriptor: Int32
        let identity: LocalFileIdentity
    }

    private struct CheckedEdge {
        let parentDescriptor: Int32
        let name: String
        let identity: LocalFileIdentity
    }

    private struct ExactRead {
        let data: Data
        let digest: EvidenceFingerprint
    }

    private struct ObjectID: Hashable {
        let device: UInt64
        let inode: UInt64
        init(_ identity: LocalFileIdentity) {
            device = identity.device
            inode = identity.inode
        }
    }

    private func openAppChain() -> [OpenedNode]? {
        guard appURL.isFileURL else { return nil }
        let pathComponents = appURL.pathComponents
        guard pathComponents.first == "/", pathComponents.count > 1 else { return nil }
        let componentNames = Array(pathComponents.dropFirst())
        guard componentNames.count <= Self.maximumAppChainComponents,
              Self.totalComponentBytes(componentNames) <= Self.maximumAppChainPathBytes,
              componentNames.allSatisfy(Self.isValidComponent),
              let rootBefore = Self.lstatIdentity("/"), Self.isDirectory(rootBefore) else {
            return nil
        }
        let rootFD = open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard rootFD >= 0, Self.fstatIdentity(rootFD) == rootBefore else {
            if rootFD >= 0 { Darwin.close(rootFD) }
            return nil
        }
        var nodes = [OpenedNode(parentDescriptor: nil, nameFromParent: nil,
                                descriptor: rootFD, identity: rootBefore)]
        for name in componentNames {
            let parent = nodes[nodes.count - 1]
            guard let before = Self.fstatatIdentity(parent.descriptor, name),
                  Self.isDirectory(before) else {
                Self.closeNodes(nodes)
                return nil
            }
            let descriptor = openat(parent.descriptor, name,
                                    O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard descriptor >= 0, Self.fstatIdentity(descriptor) == before else {
                if descriptor >= 0 { Darwin.close(descriptor) }
                Self.closeNodes(nodes)
                return nil
            }
            nodes.append(OpenedNode(parentDescriptor: parent.descriptor,
                                    nameFromParent: name,
                                    descriptor: descriptor,
                                    identity: before))
        }
        guard Self.hasUniqueObjects(nodes.map(\.identity)) else {
            Self.closeNodes(nodes)
            return nil
        }
        hooks.at(.appChainOpened)
        return nodes
    }

    private func openRelative(_ components: [String],
                              leafKind: RequiredLeafKind,
                              nodes: inout [OpenedNode]) -> Bool {
        for (index, name) in components.enumerated() {
            let parent = nodes[nodes.count - 1]
            let isLeaf = index == components.count - 1
            guard let before = Self.fstatatIdentity(parent.descriptor, name) else { return false }
            let wantsDirectory = !isLeaf || leafKind == .directory
            guard wantsDirectory ? Self.isDirectory(before) : Self.isRegular(before) else {
                return false
            }
            let flags = wantsDirectory
                ? O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
                : O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC
            let descriptor = openat(parent.descriptor, name, flags)
            guard descriptor >= 0, Self.fstatIdentity(descriptor) == before else {
                if descriptor >= 0 { Darwin.close(descriptor) }
                return false
            }
            nodes.append(OpenedNode(parentDescriptor: parent.descriptor,
                                    nameFromParent: name,
                                    descriptor: descriptor,
                                    identity: before))
        }
        return true
    }

    private func appProof(nodes: [OpenedNode]) -> AppBundlePathProof? {
        let names = appRootComponents()
        let identities = nodes.map(\.identity)
        guard let fingerprint = Self.chainFingerprint(componentNames: names,
                                                      identities: identities) else { return nil }
        return AppBundlePathProof(canonicalPath: appURL.path,
                                  rootRelativeComponents: names,
                                  componentIdentities: identities,
                                  chainFingerprint: fingerprint)
    }

    private static func readExact(descriptor: Int32,
                                  identity: LocalFileIdentity,
                                  maximumBytes: Int) -> ExactRead? {
        guard isRegular(identity), identity.size >= 0,
              identity.size <= Int64(maximumBytes),
              identity.size <= Int64(Int.max) else { return nil }
        var data = Data()
        data.reserveCapacity(Int(identity.size))
        var buffer = [UInt8](repeating: 0, count: 32 * 1_024)
        while true {
            let count = buffer.withUnsafeMutableBytes {
                Darwin.read(descriptor, $0.baseAddress, $0.count)
            }
            if count == 0 { break }
            if count < 0 {
                if errno == EINTR { continue }
                return nil
            }
            let (newCount, overflow) = data.count.addingReportingOverflow(count)
            guard !overflow, newCount <= maximumBytes else { return nil }
            data.append(contentsOf: buffer.prefix(count))
        }
        guard data.count == Int(identity.size),
              let digest = EvidenceFingerprint(
                sha256: Array(SHA256.hash(data: data))) else { return nil }
        return ExactRead(data: data, digest: digest)
    }

    private static func recheck(nodes: [OpenedNode],
                                additionalEdges: [CheckedEdge]) -> Bool {
        for node in nodes.reversed() where fstatIdentity(node.descriptor) != node.identity {
            return false
        }
        for node in nodes.reversed() {
            if let parent = node.parentDescriptor, let name = node.nameFromParent,
               fstatatIdentity(parent, name) != node.identity { return false }
        }
        for edge in additionalEdges.reversed()
        where fstatatIdentity(edge.parentDescriptor, edge.name) != edge.identity {
            return false
        }
        return true
    }

    private static func closeNodes(_ nodes: [OpenedNode]) {
        for node in nodes.reversed() { Darwin.close(node.descriptor) }
    }

    // MARK: - Nested source roster

    private enum RosterNodeKind: UInt8 { case directory = 1, regular = 2, symlink = 3 }

    private struct RosterEntry {
        let relativePath: String
        let identity: LocalFileIdentity
        let kind: RosterNodeKind
        let symlinkTarget: [UInt8]?
    }

    private struct RosterBudget {
        var entries = 0
        var directories = 0
        var totalPathBytes = 0

        mutating func consume(path: String, directory: Bool) -> Bool {
            let pathBytes = path.utf8.count
            let (nextEntries, entryOverflow) = entries.addingReportingOverflow(1)
            let (nextPathBytes, pathOverflow) = totalPathBytes.addingReportingOverflow(pathBytes)
            let nextDirectories = directories + (directory ? 1 : 0)
            guard !entryOverflow, !pathOverflow,
                  nextEntries <= FDAnchoredAppBundlePathAttestor.maximumRosterEntries,
                  nextDirectories <= FDAnchoredAppBundlePathAttestor.maximumRosterDirectories,
                  nextPathBytes <= FDAnchoredAppBundlePathAttestor.maximumRosterPathBytes else {
                return false
            }
            entries = nextEntries
            directories = nextDirectories
            totalPathBytes = nextPathBytes
            return true
        }
    }

    private enum ChildLookup {
        case missing
        case found(LocalFileIdentity)
        case failed
    }

    private func nestedRosterFingerprint() -> EvidenceFingerprint? {
        guard var nodes = openAppChain() else { return nil }
        defer { Self.closeNodes(nodes) }
        guard openRelative(["Contents"], leafKind: .directory, nodes: &nodes) else { return nil }
        let contentsFD = nodes[nodes.count - 1].descriptor
        var identities = Set(nodes.map { ObjectID($0.identity) })
        guard identities.count == nodes.count else { return nil }
        var edges: [CheckedEdge] = []
        var entries: [RosterEntry] = []
        var budget = RosterBudget()

        guard let names = directoryNames(contentsFD,
                                         relativeDirectory: "Contents",
                                         budget: budget) else { return nil }
        for name in names.sorted(by: Self.rawUTF8Less) {
            switch Self.lookupChild(parent: contentsFD, name: name) {
            case .missing, .failed:
                return nil
            case .found(let identity):
                guard captureRosterNode(parentFD: contentsFD,
                                        name: name,
                                        relativeComponents: ["Contents", name],
                                        identity: identity,
                                        depth: 1,
                                        nodes: &nodes,
                                        edges: &edges,
                                        identities: &identities,
                                        entries: &entries,
                                        budget: &budget) else { return nil }
            }
        }
        hooks.at(.rosterEnumeratedBeforeFinalRecheck)
        guard Self.recheck(nodes: nodes, additionalEdges: edges) else { return nil }
        return Self.rosterFingerprint(entries)
    }

    private func captureRosterNode(parentFD: Int32,
                                   name: String,
                                   relativeComponents: [String],
                                   identity: LocalFileIdentity,
                                   depth: Int,
                                   nodes: inout [OpenedNode],
                                   edges: inout [CheckedEdge],
                                   identities: inout Set<ObjectID>,
                                   entries: inout [RosterEntry],
                                   budget: inout RosterBudget) -> Bool {
        guard depth <= Self.maximumRosterDepth,
              Self.isValidComponent(name),
              identities.insert(ObjectID(identity)).inserted else { return false }
        let relativePath = relativeComponents.joined(separator: "/")
        let type = identity.mode & UInt32(S_IFMT)

        if type == UInt32(S_IFDIR) {
            guard budget.consume(path: relativePath, directory: true) else { return false }
            let descriptor = openat(parentFD, name,
                                    O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard descriptor >= 0, Self.fstatIdentity(descriptor) == identity else {
                if descriptor >= 0 { Darwin.close(descriptor) }
                return false
            }
            nodes.append(OpenedNode(parentDescriptor: parentFD, nameFromParent: name,
                                    descriptor: descriptor, identity: identity))
            entries.append(RosterEntry(relativePath: relativePath, identity: identity,
                                       kind: .directory, symlinkTarget: nil))
            guard let childNames = directoryNames(descriptor,
                                                  relativeDirectory: relativePath,
                                                  budget: budget) else { return false }
            for childName in childNames.sorted(by: Self.rawUTF8Less) {
                guard Self.isValidComponent(childName) else { return false }
                switch Self.lookupChild(parent: descriptor, name: childName) {
                case .missing, .failed:
                    return false
                case .found(let childIdentity):
                    guard captureRosterNode(parentFD: descriptor,
                                            name: childName,
                                            relativeComponents: relativeComponents + [childName],
                                            identity: childIdentity,
                                            depth: depth + 1,
                                            nodes: &nodes,
                                            edges: &edges,
                                            identities: &identities,
                                            entries: &entries,
                                            budget: &budget) else { return false }
                }
            }
            return true
        }

        if type == UInt32(S_IFREG) {
            guard budget.consume(path: relativePath, directory: false) else { return false }
            let descriptor = openat(parentFD, name,
                                    O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
            guard descriptor >= 0, Self.fstatIdentity(descriptor) == identity else {
                if descriptor >= 0 { Darwin.close(descriptor) }
                return false
            }
            Darwin.close(descriptor)
            edges.append(CheckedEdge(parentDescriptor: parentFD, name: name,
                                     identity: identity))
            entries.append(RosterEntry(relativePath: relativePath, identity: identity,
                                       kind: .regular, symlinkTarget: nil))
            return true
        }

        if type == UInt32(S_IFLNK) {
            guard budget.consume(path: relativePath, directory: false),
                  let target = Self.readLink(parent: parentFD, name: name),
                  Self.fstatatIdentity(parentFD, name) == identity else { return false }
            edges.append(CheckedEdge(parentDescriptor: parentFD, name: name,
                                     identity: identity))
            entries.append(RosterEntry(relativePath: relativePath, identity: identity,
                                       kind: .symlink, symlinkTarget: target))
            return true
        }

        return false
    }

    private static func lookupChild(parent: Int32, name: String) -> ChildLookup {
        var value = stat()
        if fstatat(parent, name, &value, AT_SYMLINK_NOFOLLOW) == 0 {
            guard let identity = identity(value) else { return .failed }
            return .found(identity)
        }
        return errno == ENOENT ? .missing : .failed
    }

    private func directoryNames(_ descriptor: Int32,
                                relativeDirectory: String,
                                budget: RosterBudget) -> [String]? {
        let remainingEntries = Self.maximumRosterEntries - budget.entries
        let remainingPathBytes = Self.maximumRosterPathBytes - budget.totalPathBytes
        guard remainingEntries >= 0, remainingPathBytes >= 0 else { return nil }
        let streamFD = fcntl(descriptor, F_DUPFD_CLOEXEC, 0)
        guard streamFD >= 0, let directory = fdopendir(streamFD) else {
            if streamFD >= 0 { Darwin.close(streamFD) }
            return nil
        }
        defer { closedir(directory) }
        var names: [String] = []
        names.reserveCapacity(min(remainingEntries, 256))
        var retainedPathBytes = 0
        var observedCount = 0
        while true {
            errno = 0
            guard let entry = readdir(directory) else {
                return errno == 0 ? names : nil
            }
            let name: String? = withUnsafeBytes(of: entry.pointee.d_name) { raw in
                guard let base = raw.baseAddress else { return nil }
                return String(validatingCString: base.assumingMemoryBound(to: CChar.self))
            }
            guard let name else { return nil }
            if name == "." || name == ".." { continue }
            observedCount += 1
            hooks.at(.rosterDirectoryEntryObserved(directory: relativeDirectory,
                                                    count: observedCount))
            guard names.count < remainingEntries, Self.isValidComponent(name) else { return nil }
            let childPathBytes = relativeDirectory.utf8.count + 1 + name.utf8.count
            let (nextPathBytes, overflow) = retainedPathBytes
                .addingReportingOverflow(childPathBytes)
            guard !overflow, nextPathBytes <= remainingPathBytes else { return nil }
            retainedPathBytes = nextPathBytes
            names.append(name)
        }
    }

    private static func readLink(parent: Int32, name: String) -> [UInt8]? {
        var bytes = [UInt8](repeating: 0, count: maximumSymlinkTargetBytes + 1)
        let count = bytes.withUnsafeMutableBytes {
            readlinkat(parent, name, $0.baseAddress, $0.count)
        }
        guard count >= 0, count <= maximumSymlinkTargetBytes else { return nil }
        return Array(bytes.prefix(count))
    }

    private static func rosterFingerprint(_ entries: [RosterEntry]) -> EvidenceFingerprint? {
        let sorted = entries.sorted { rawUTF8Less($0.relativePath, $1.relativePath) }
        guard sorted.count <= Int(UInt32.max) else { return nil }
        var bytes: [UInt8] = [1]
        appendBE(UInt32(sorted.count), to: &bytes)
        for entry in sorted {
            guard appendString(entry.relativePath, to: &bytes) else { return nil }
            bytes.append(entry.kind.rawValue)
            appendIdentity(entry.identity, to: &bytes)
            if let target = entry.symlinkTarget {
                bytes.append(1)
                guard target.count <= Int(UInt32.max) else { return nil }
                appendBE(UInt32(target.count), to: &bytes)
                bytes.append(contentsOf: target)
            } else {
                bytes.append(0)
            }
        }
        return EvidenceFingerprint(sha256: Array(SHA256.hash(data: Data(bytes))))
    }

    // MARK: - Identity and canonical encoding

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
        return fstatat(parent, name, &value, AT_SYMLINK_NOFOLLOW) == 0
            ? identity(value) : nil
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

    private static func hasUniqueObjects(_ identities: [LocalFileIdentity]) -> Bool {
        Set(identities.map(ObjectID.init)).count == identities.count
    }

    private static func chainFingerprint(componentNames: [String],
                                         identities: [LocalFileIdentity]) -> EvidenceFingerprint? {
        guard identities.count == componentNames.count + 1,
              componentNames.count <= Int(UInt32.max) else { return nil }
        var bytes: [UInt8] = [1]
        appendIdentity(identities[0], to: &bytes)
        appendBE(UInt32(componentNames.count), to: &bytes)
        for (name, identity) in zip(componentNames, identities.dropFirst()) {
            guard appendString(name, to: &bytes) else { return nil }
            appendIdentity(identity, to: &bytes)
        }
        return EvidenceFingerprint(sha256: Array(SHA256.hash(data: Data(bytes))))
    }

    private static func appendIdentity(_ identity: LocalFileIdentity, to bytes: inout [UInt8]) {
        appendBE(identity.device, to: &bytes)
        appendBE(identity.inode, to: &bytes)
        appendBE(identity.mode, to: &bytes)
        appendBE(UInt64(bitPattern: identity.size), to: &bytes)
        appendBE(UInt64(bitPattern: identity.mtimeNanoseconds), to: &bytes)
        appendBE(UInt64(bitPattern: identity.changeTimeNanoseconds), to: &bytes)
        appendBE(identity.hardLinkCount, to: &bytes)
    }

    private static func appendBE<T: FixedWidthInteger>(_ value: T,
                                                        to bytes: inout [UInt8]) {
        var bigEndian = value.bigEndian
        Swift.withUnsafeBytes(of: &bigEndian) { bytes.append(contentsOf: $0) }
    }

    private static func appendString(_ value: String, to bytes: inout [UInt8]) -> Bool {
        let encoded = Array(value.utf8)
        guard encoded.count <= Int(UInt32.max) else { return false }
        appendBE(UInt32(encoded.count), to: &bytes)
        bytes.append(contentsOf: encoded)
        return true
    }
    #endif

    private static func isValidComponent(_ value: String) -> Bool {
        let utf8 = value.utf8
        return !value.isEmpty && value != "." && value != ".." && utf8.count <= 255
            && !value.contains("/") && !value.contains("\\") && !value.contains("\0")
            && !value.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x7F }
    }

    private static func rawUTF8Less(_ lhs: String, _ rhs: String) -> Bool {
        lhs.utf8.lexicographicallyPrecedes(rhs.utf8)
    }

    private static func totalComponentBytes(_ components: [String]) -> Int {
        var total = 0
        for component in components {
            let (withComponent, componentOverflow) = total
                .addingReportingOverflow(component.utf8.count)
            let (withSeparator, separatorOverflow) = withComponent.addingReportingOverflow(1)
            if componentOverflow || separatorOverflow { return Int.max }
            total = withSeparator
        }
        return total
    }
}
