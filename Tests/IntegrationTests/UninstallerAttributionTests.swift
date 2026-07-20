import Foundation
import CryptoKit
import XCTest
@testable import Domain
@testable import Infrastructure
#if canImport(Darwin)
import Darwin
#endif

final class UninstallerAttributionTests: XCTestCase {
    private enum PreparedPlanMutation: String, CaseIterable, Sendable {
        case count
        case order
        case path
        case identity
        case fingerprint
        case planID
        case createdAt
        case expiresAt
        case digest
    }

    private enum PreparedPayloadMutation: String, CaseIterable, Sendable {
        case candidateID
        case itemURL
        case itemSafety
        case role
        case policy
        case evidence
    }

    private struct AllowAllSafety: SafetyEngine {
        func verify(_ url: URL, intent: DeleteIntent) -> SafetyVerdict { .allow }
    }

    private struct DenyURLSafety: SafetyEngine {
        let deniedPath: String
        func verify(_ url: URL, intent: DeleteIntent) -> SafetyVerdict {
            url.path == deniedPath ? .deny(reason: "fixture denial") : .allow
        }
    }

    private final class MutableSafety: @unchecked Sendable, SafetyEngine {
        private let lock = NSLock()
        private var allowed = true
        func deny() { lock.withLock { allowed = false } }
        func allow() { lock.withLock { allowed = true } }
        func verify(_ url: URL, intent: DeleteIntent) -> SafetyVerdict {
            lock.withLock { allowed } ? .allow : .deny(reason: "changed fixture verdict")
        }
    }

    private final class ScriptedUninstallClock: @unchecked Sendable,
                                                 UninstallTrustedClock {
        private let lock = NSLock()
        private var wall: Date
        private var monotonic: UInt64

        init(wall: Date, monotonic: UInt64) {
            self.wall = wall
            self.monotonic = monotonic
        }

        func wallNow() -> Date { lock.withLock { wall } }
        func monotonicNowNanoseconds() -> UInt64 { lock.withLock { monotonic } }
        func set(wall: Date? = nil, monotonic: UInt64? = nil) {
            lock.withLock {
                if let wall { self.wall = wall }
                if let monotonic { self.monotonic = monotonic }
            }
        }
        func advance(wall: TimeInterval = 0, monotonicNanoseconds: UInt64 = 0) {
            lock.withLock {
                self.wall = self.wall.addingTimeInterval(wall)
                self.monotonic = self.monotonic &+ monotonicNanoseconds
            }
        }
    }

    /// Once armed, advances wall time on the second monotonic read. The first armed read is the
    /// controller's post-authorization lifetime check; the second occurs after the final wall
    /// read inside the authorized body, reproducing expiry while that check is suspended.
    private final class ExpiringDuringFinalMonotonicClock: @unchecked Sendable,
                                                            UninstallTrustedClock {
        private let lock = NSLock()
        private var wall: Date
        private let monotonic: UInt64
        private var armed = false
        private var armedReads = 0

        init(wall: Date, monotonic: UInt64) {
            self.wall = wall
            self.monotonic = monotonic
        }

        func arm() {
            lock.withLock {
                armed = true
                armedReads = 0
            }
        }

        func wallNow() -> Date { lock.withLock { wall } }

        func monotonicNowNanoseconds() -> UInt64 {
            lock.withLock {
                if armed {
                    armedReads += 1
                    if armedReads == 2 {
                        wall = wall.addingTimeInterval(UninstallBatch.timeToLive + 1)
                    }
                }
                return monotonic
            }
        }
    }

    private struct FakeEntitlementReader: EntitlementReader {
        let groups: [String]?
        func attestation(for appURL: URL) -> SignedEntitlementAttestation? {
            guard let groups, !groups.isEmpty else { return nil }
            let attestor = FDAnchoredAppBundlePathAttestor(appURL: appURL)
            guard let proof = attestor.attestApp(),
                  let info = attestor.readRegularFile(
                    relativeComponents: ["Contents", "Info.plist"],
                    maximumBytes: 1_048_576) else { return nil }
            let bundleID = Bundle(url: appURL)?.bundleIdentifier ?? ""
            let executablePath = appURL.appendingPathComponent(
                "Contents/MacOS/test-entitlement-fixture").path
            let program = ProgramChangeToken(
                canonicalPath: executablePath,
                relativeComponentsInsideApp: ["Contents", "MacOS",
                                              "test-entitlement-fixture"],
                directoryChain: [proof.appRootIdentity],
                executable: info.attestation.identity,
                chainFingerprint: proof.chainFingerprint,
                boundedExactLength: info.attestation.exactLength,
                boundedContentDigest: info.attestation.contentDigest)
            let source = AppBundleSourceSeal(
                appRoot: proof.appRootIdentity,
                appChainFingerprint: proof.chainFingerprint,
                infoPlist: info.attestation,
                mainExecutable: program,
                mainExecutableCanonicalPath: executablePath,
                codeResources: info.attestation,
                nestedRosterFingerprint: proof.chainFingerprint)
            return SignedEntitlementAttestation(
                groups: groups.sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) },
                codeIdentifier: bundleID, uniqueCode: Data([1]),
                sourceIdentity: proof.appRootIdentity, sourceSeal: source)
        }
    }

    private struct FakeLaunchAgentReader: LaunchAgentReader {
        let records: [String: LaunchAgentRecord]
        func attestation(at url: URL,
                         anchoredRead: AnchoredRegularFileRead) -> LaunchAgentAttestation? {
            guard let record = records[url.path] else { return nil }
            return LaunchAgentAttestation.capture(record: record,
                                                  plistFile: anchoredRead.fileAttestation)
        }
    }

    private struct NilIdentitySampler: IdentitySampler {
        func sample(_ canonicalPath: String) -> LocalFileIdentity? { nil }
    }

    private final class MutableEntitlementAttestationReader: @unchecked Sendable, EntitlementReader {
        private let lock = NSLock()
        private var stored: SignedEntitlementAttestation?

        init(_ attestation: SignedEntitlementAttestation?) { stored = attestation }
        func set(_ attestation: SignedEntitlementAttestation?) {
            lock.withLock { stored = attestation }
        }
        func attestation(for appURL: URL) -> SignedEntitlementAttestation? {
            lock.withLock { stored }
        }
    }

    private final class InvocationCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        var count: Int { lock.withLock { value } }
        func increment() { lock.withLock { value += 1 } }
    }

    private final class RecordingPayloadExecutor: @unchecked Sendable,
                                                  UninstallPayloadExecuting {
        private let lock = NSLock()
        private var counts: [Int] = []
        let counter: InvocationCounter

        init(counter: InvocationCounter = InvocationCounter()) {
            self.counter = counter
        }

        var selectedCounts: [Int] { lock.withLock { counts } }

        func execute(
            _ prepared: PreparedUninstallExecution,
            admission: @escaping @Sendable () async -> Bool,
            finalAdmission: @escaping @Sendable () -> Bool,
            evidenceAdmission: @escaping @Sendable (PreparedUninstallTarget) -> Bool
        ) async -> UninstallPayloadExecution? {
            guard await admission(), finalAdmission(),
                  prepared.validateIntegrity(),
                  prepared.orderedTargets.allSatisfy(evidenceAdmission) else { return nil }
            lock.withLock { counts.append(prepared.orderedTargets.count) }
            counter.increment()
            // Tests must never mutate their fixture. Return a reducer-backed, no-mutation
            // uninstall terminal correlated to every exact prepared occurrence.
            let bindings = prepared.orderedTargets.map {
                UninstallPayloadOccurrenceBinding(requestID: UUID(), target: $0)
            }
            let results = bindings.map { binding in
                let issue = OperationIssue(
                    code: "uninstall.test.noMutation",
                    category: .unavailable,
                    subjectID: binding.requestID.uuidString,
                    recovery: .retry,
                    retryable: true)
                return CleaningItemResult(
                    requestID: binding.requestID,
                    itemID: binding.target.candidate.item.id,
                    url: binding.target.candidate.url,
                    intent: .trash,
                    disposition: .failed(issue),
                    mutation: .none,
                    reclaimedBytes: 0,
                    restorable: nil)
            }
            let now = Date()
            let outcome = try! OperationOutcomeReducer.reduce(
                kind: .uninstall,
                requestedSubjectIDs: bindings.map { $0.requestID.uuidString },
                itemOutcomes: results.map {
                    OperationItemOutcome(
                        subjectID: $0.requestID.uuidString,
                        disposition: $0.disposition,
                        mutation: $0.mutation)
                },
                cancellationAccepted: false,
                startedAt: now,
                finishedAt: now)
            return UninstallPayloadExecution(
                report: CleaningReport(operation: outcome, items: results),
                occurrences: bindings)
        }
    }

    /// Simulates an Infrastructure bug after the mutation body returned: every emitted success
    /// carries an exact reversible receipt, but the report omits the final prepared occurrence.
    /// No real filesystem mutation occurs.
    private struct MalformedPostMutationPayloadExecutor: UninstallPayloadExecuting {
        func execute(
            _ prepared: PreparedUninstallExecution,
            admission: @escaping @Sendable () async -> Bool,
            finalAdmission: @escaping @Sendable () -> Bool,
            evidenceAdmission: @escaping @Sendable (PreparedUninstallTarget) -> Bool
        ) async -> UninstallPayloadExecution? {
            guard await admission(), finalAdmission(), prepared.validateIntegrity(),
                  prepared.orderedTargets.allSatisfy(evidenceAdmission) else { return nil }
            let occurrences = prepared.orderedTargets.map {
                UninstallPayloadOccurrenceBinding(requestID: UUID(), target: $0)
            }
            let retainedOccurrences = Array(occurrences.dropLast())
            let results = retainedOccurrences.map { occurrence in
                CleaningItemResult(
                    requestID: occurrence.requestID,
                    itemID: occurrence.target.candidate.id,
                    url: occurrence.target.candidate.url,
                    intent: .trash,
                    disposition: .succeeded,
                    mutation: .changed,
                    reclaimedBytes:
                        occurrence.target.candidate.item.estimatedReclaimableBytes,
                    restorable: RestorableItem(
                        originalURL: occurrence.target.candidate.url,
                        trashedURL: URL(fileURLWithPath: "/private/tmp/xico-malformed-trash")
                            .appendingPathComponent(occurrence.requestID.uuidString)))
            }
            let now = Date()
            let outcome = try! OperationOutcomeReducer.reduce(
                kind: .uninstall,
                requestedSubjectIDs: results.map { $0.requestID.uuidString },
                itemOutcomes: results.map {
                    OperationItemOutcome(
                        subjectID: $0.requestID.uuidString,
                        disposition: $0.disposition,
                        mutation: $0.mutation,
                        affectedBytes: $0.reclaimedBytes)
                },
                cancellationAccepted: false,
                startedAt: now,
                finishedAt: now)
            return UninstallPayloadExecution(
                report: CleaningReport(operation: outcome, items: results),
                occurrences: occurrences)
        }
    }

    private final class BlockingRecordingFileSystem: @unchecked Sendable,
                                                     FileSystemService {
        private let local = LocalFileSystemService()
        private let lock = NSLock()
        private let entered = DispatchSemaphore(value: 0)
        private let release = DispatchSemaphore(value: 0)
        private var shouldBlockNextTrash = true
        private var recordedTrashPaths: [String] = []

        var trashedPaths: [String] { lock.withLock { recordedTrashPaths } }

        func waitUntilTrashIsBlocked() -> Bool {
            entered.wait(timeout: .now() + 5) == .success
        }

        func releaseBlockedTrash() { release.signal() }

        func exists(_ url: URL) -> Bool { local.exists(url) }
        func contentsOfDirectory(_ url: URL) -> [URL] { local.contentsOfDirectory(url) }
        func allocatedSize(of url: URL) -> Int64 { local.allocatedSize(of: url) }
        func entry(for url: URL) -> FileEntry? { local.entry(for: url) }
        func trash(_ url: URL) throws -> URL {
            let block = lock.withLock { () -> Bool in
                defer { shouldBlockNextTrash = false }
                return shouldBlockNextTrash
            }
            if block {
                entered.signal()
                _ = release.wait(timeout: .now() + 5)
            }
            lock.withLock { recordedTrashPaths.append(url.standardizedFileURL.path) }
            return url
        }
        func remove(_ url: URL) throws {
            lock.withLock { recordedTrashPaths.append(url.standardizedFileURL.path) }
        }
        func restore(_ item: RestorableItem) throws -> URL { item.originalURL }
        func volumeCapacity(for url: URL) -> VolumeCapacity? { local.volumeCapacity(for: url) }
        func deepEnumerate(_ url: URL, includeFiles: Bool) -> AsyncStream<FileEntry> {
            local.deepEnumerate(url, includeFiles: includeFiles)
        }
    }

    private final class NonMutatingTrashFileSystem: @unchecked Sendable,
                                                    FileSystemService {
        private let local = LocalFileSystemService()
        private let lock = NSLock()
        private let onTrash: @Sendable () -> Void
        private var paths: [String] = []

        init(onTrash: @escaping @Sendable () -> Void = {}) {
            self.onTrash = onTrash
        }

        var trashedPaths: [String] { lock.withLock { paths } }
        func exists(_ url: URL) -> Bool { local.exists(url) }
        func contentsOfDirectory(_ url: URL) -> [URL] { local.contentsOfDirectory(url) }
        func allocatedSize(of url: URL) -> Int64 { local.allocatedSize(of: url) }
        func entry(for url: URL) -> FileEntry? { local.entry(for: url) }
        func trash(_ url: URL) throws -> URL {
            lock.withLock { paths.append(url.standardizedFileURL.path) }
            onTrash()
            return URL(fileURLWithPath: "/private/tmp/xico-fake-trash")
                .appendingPathComponent(UUID().uuidString)
        }
        func remove(_ url: URL) throws {
            XCTFail("uninstall must not permanently remove a target")
        }
        func restore(_ item: RestorableItem) throws -> URL { item.originalURL }
        func volumeCapacity(for url: URL) -> VolumeCapacity? {
            local.volumeCapacity(for: url)
        }
        func deepEnumerate(_ url: URL, includeFiles: Bool) -> AsyncStream<FileEntry> {
            local.deepEnumerate(url, includeFiles: includeFiles)
        }
    }

    /// Simulates the parent-directory timestamp changes caused by moving an earlier sibling to
    /// Trash while preserving every component's device/inode/type identity.
    private final class ParentMetadataDriftPathAttestor: @unchecked Sendable,
                                                          LibraryPathAttesting {
        private let base: FDAnchoredLibraryPathAttestor
        private let lock = NSLock()
        private var shouldDrift = false

        init(home: URL) { base = FDAnchoredLibraryPathAttestor(home: home) }
        func beginDrift() { lock.withLock { shouldDrift = true } }

        func attest(_ url: URL) -> PhysicalPathAttestation? {
            guard let proof = base.attest(url) else { return nil }
            guard lock.withLock({ shouldDrift }),
                  proof.componentIdentities.count >= 2 else { return proof }
            var identities = proof.componentIdentities
            let parentIndex = identities.index(identities.endIndex, offsetBy: -2)
            let parent = identities[parentIndex]
            identities[parentIndex] = LocalFileIdentity(
                device: parent.device,
                inode: parent.inode,
                mode: parent.mode,
                size: parent.size,
                mtimeNanoseconds: parent.mtimeNanoseconds &+ 1,
                changeTimeNanoseconds: parent.changeTimeNanoseconds &+ 1,
                hardLinkCount: parent.hardLinkCount)
            return PhysicalPathAttestation(
                canonicalPath: proof.canonicalPath,
                componentNames: proof.componentNames,
                componentIdentities: identities)
        }

        func readRegularFile(_ url: URL, maximumBytes: Int) -> AnchoredRegularFileRead? {
            base.readRegularFile(url, maximumBytes: maximumBytes)
        }
    }

    private struct OverridingIdentitySampler: IdentitySampler {
        let path: String
        let replacement: LocalFileIdentity
        private let local = LocalFileIdentitySampler()

        func sample(_ canonicalPath: String) -> LocalFileIdentity? {
            canonicalPath == path ? replacement : local.sample(canonicalPath)
        }
    }

    private final class AsyncAdmissionGate: @unchecked Sendable {
        private let lock = NSLock()
        private let entered = DispatchSemaphore(value: 0)
        private var continuation: CheckedContinuation<Void, Never>?

        func suspend() async {
            await withCheckedContinuation { continuation in
                lock.withLock { self.continuation = continuation }
                entered.signal()
            }
        }

        func waitUntilSuspended() -> Bool {
            entered.wait(timeout: .now() + 5) == .success
        }

        func resume() {
            let continuation = lock.withLock { () -> CheckedContinuation<Void, Never>? in
                defer { self.continuation = nil }
                return self.continuation
            }
            continuation?.resume()
        }
    }

    private final class HookedIdentitySampler: @unchecked Sendable, IdentitySampler {
        private let lock = NSLock()
        private var substitute = false
        func enableSubstitution() { lock.withLock { substitute = true } }
        func sample(_ canonicalPath: String) -> LocalFileIdentity? {
            guard let actual = LocalFileIdentitySampler().sample(canonicalPath) else { return nil }
            return lock.withLock { substitute }
                ? LocalFileIdentity(device: actual.device, inode: actual.inode &+ 1,
                                    mode: actual.mode, size: actual.size,
                                    mtimeNanoseconds: actual.mtimeNanoseconds,
                                    changeTimeNanoseconds: actual.changeTimeNanoseconds,
                                    hardLinkCount: actual.hardLinkCount)
                : actual
        }
    }

    private static func mutating(_ plan: DestructivePlan,
                                 _ mutation: PreparedPlanMutation) -> DestructivePlan {
        var targets = plan.targets
        switch mutation {
        case .count:
            targets.removeLast()
        case .order:
            targets.reverse()
        case .path:
            let original = targets[0]
            targets[0] = PlannedTarget(
                canonicalPath: original.canonicalPath + ".substituted",
                identity: original.identity,
                recoverability: original.recoverability,
                riskLevel: original.riskLevel,
                attribution: original.attribution,
                evidenceFingerprint: original.evidenceFingerprint)
        case .identity:
            let original = targets[0]
            let identity = original.identity!
            targets[0] = PlannedTarget(
                canonicalPath: original.canonicalPath,
                identity: LocalFileIdentity(
                    device: identity.device, inode: identity.inode &+ 1,
                    mode: identity.mode, size: identity.size,
                    mtimeNanoseconds: identity.mtimeNanoseconds,
                    changeTimeNanoseconds: identity.changeTimeNanoseconds,
                    hardLinkCount: identity.hardLinkCount),
                recoverability: original.recoverability,
                riskLevel: original.riskLevel,
                attribution: original.attribution,
                evidenceFingerprint: original.evidenceFingerprint)
        case .fingerprint:
            let original = targets[0]
            targets[0] = PlannedTarget(
                canonicalPath: original.canonicalPath,
                identity: original.identity,
                recoverability: original.recoverability,
                riskLevel: original.riskLevel,
                attribution: original.attribution,
                evidenceFingerprint: EvidenceFingerprint(
                    sha256: [UInt8](repeating: 0xA5, count: 32))!)
        case .planID, .createdAt, .expiresAt, .digest:
            break
        }
        let planID = mutation == .planID ? UUID() : plan.planID
        let createdAt = mutation == .createdAt
            ? plan.createdAt.addingTimeInterval(1) : plan.createdAt
        let expiresAt = mutation == .expiresAt
            ? plan.expiresAt.addingTimeInterval(1) : plan.expiresAt
        let digest = mutation == .digest
            ? PlanDigest(bytes: plan.digest.bytes.enumerated().map {
                $0.offset == 0 ? $0.element ^ 0xFF : $0.element
            })
            : plan.digest
        return DestructivePlan(
            planID: planID, kind: plan.kind,
            createdAt: createdAt, expiresAt: expiresAt,
            targets: targets, digest: digest)
    }

    private static func mutating(_ prepared: PreparedUninstallExecution,
                                 _ mutation: PreparedPayloadMutation)
        -> PreparedUninstallExecution {
        var targets = prepared.orderedTargets
        let index = mutation == .role
            ? targets.firstIndex(where: { $0.candidate.role != .appBody })!
            : targets.count - 1
        let target = targets[index]
        let original = target.candidate
        let originalItem = original.item
        let item = CleanableItem(
            id: mutation == .candidateID ? UUID() : originalItem.id,
            url: mutation == .itemURL
                ? originalItem.url.appendingPathExtension("substituted") : originalItem.url,
            displayName: originalItem.displayName,
            detail: originalItem.detail,
            size: originalItem.size,
            safety: mutation == .itemSafety ? .risky : originalItem.safety,
            isSelected: originalItem.isSelected,
            requiresHelper: originalItem.requiresHelper,
            note: originalItem.note,
            isInformational: originalItem.isInformational,
            assessment: originalItem.assessment)
        let candidate = UninstallCandidate(
            item: item,
            evidence: mutation == .evidence ? .unverified : original.evidence,
            selectionPolicy: mutation == .policy ? .manualOnly : original.selectionPolicy,
            role: mutation == .role
                ? (original.role == .appBody ? .associatedFile : .appBody)
                : original.role,
            batchID: original.batchID,
            evidenceBinding: original.evidenceBinding,
            recoveryHint: original.recoveryHint)
        targets[index] = PreparedUninstallTarget(
            ordinal: target.ordinal,
            batchCandidateIndex: target.batchCandidateIndex,
            candidate: candidate,
            canonicalPath: target.canonicalPath,
            expectedIdentity: target.expectedIdentity,
            evidenceFingerprint: target.evidenceFingerprint,
            ownershipAttestation: target.ownershipAttestation)
        return PreparedUninstallExecution(
            plan: prepared.plan, orderedTargets: targets,
            batchSnapshot: prepared.batchSnapshot,
            batchID: prepared.batchID, issuanceID: prepared.issuanceID,
            preparationSeal: prepared.preparationSeal)
    }

    private struct DirectoryListingFileSystem: FileSystemService {
        let overriddenDirectoryPath: String
        let listedURLs: [URL]
        private let local = LocalFileSystemService()

        func exists(_ url: URL) -> Bool { local.exists(url) }
        func contentsOfDirectory(_ url: URL) -> [URL] {
            url.path == overriddenDirectoryPath ? listedURLs : local.contentsOfDirectory(url)
        }
        func allocatedSize(of url: URL) -> Int64 { local.allocatedSize(of: url) }
        func entry(for url: URL) -> FileEntry? { local.entry(for: url) }
        func trash(_ url: URL) throws -> URL { throw CocoaError(.fileWriteNoPermission) }
        func remove(_ url: URL) throws { throw CocoaError(.fileWriteNoPermission) }
        func restore(_ item: RestorableItem) throws -> URL {
            throw CocoaError(.fileWriteNoPermission)
        }
        func volumeCapacity(for url: URL) -> VolumeCapacity? { local.volumeCapacity(for: url) }
        func deepEnumerate(_ url: URL, includeFiles: Bool) -> AsyncStream<FileEntry> {
            local.deepEnumerate(url, includeFiles: includeFiles)
        }
    }

    private final class CountingLaunchAgentReader: @unchecked Sendable, LaunchAgentReader {
        private let lock = NSLock()
        private var callCount = 0
        let record: LaunchAgentRecord

        init(record: LaunchAgentRecord) { self.record = record }
        var calls: Int { lock.withLock { callCount } }
        func attestation(at url: URL,
                         anchoredRead: AnchoredRegularFileRead) -> LaunchAgentAttestation? {
            lock.withLock { callCount += 1 }
            return LaunchAgentAttestation.capture(record: record,
                                                  plistFile: anchoredRead.fileAttestation)
        }
    }

    private struct Fixture {
        let root: URL
        let home: URL
        let appURL: URL
        let app: InstalledApp
        let issuanceID: UUID

        init(bundleID: String = "com.example.product", displayName: String = "Example Product") throws {
            let unresolvedRoot = FileManager.default.temporaryDirectory
                .appendingPathComponent("xico-uninstaller-attribution-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: unresolvedRoot, withIntermediateDirectories: true)
            root = unresolvedRoot.path.hasPrefix("/var/")
                ? URL(fileURLWithPath: "/private" + unresolvedRoot.path)
                : unresolvedRoot.resolvingSymlinksInPath()
            home = root.appendingPathComponent("home")
            issuanceID = UUID()
            appURL = home.appendingPathComponent("Applications/Example Product.app")
            try FileManager.default.createDirectory(at: appURL, withIntermediateDirectories: true)
            let contents = appURL.appendingPathComponent("Contents")
            try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(
                at: contents.appendingPathComponent("MacOS"), withIntermediateDirectories: true)
            try FileManager.default.createDirectory(
                at: home.appendingPathComponent("Library"), withIntermediateDirectories: true)
            var info: [String: Any] = ["CFBundleName": displayName]
            if !bundleID.isEmpty { info["CFBundleIdentifier"] = bundleID }
            let infoData = try PropertyListSerialization.data(fromPropertyList: info,
                                                              format: .xml, options: 0)
            try infoData.write(to: contents.appendingPathComponent("Info.plist"))
            let identity = try XCTUnwrap(LocalFileIdentitySampler().sample(appURL.path))
            let appAttestor = FDAnchoredAppBundlePathAttestor(appURL: appURL)
            let appProof = try XCTUnwrap(appAttestor.attestApp())
            let metadata = try XCTUnwrap(appAttestor.readRegularFile(
                relativeComponents: ["Contents", "Info.plist"], maximumBytes: 1_048_576))
            app = InstalledApp(id: appURL.path, name: displayName, bundleID: bundleID,
                               url: appURL, size: 0, provenanceID: issuanceID,
                               sourceIdentity: identity, appPathProof: appProof,
                               metadataAttestation: metadata.attestation)
        }

        func createLibraryItem(_ relativePath: String, directory: Bool = true) throws -> URL {
            let url = home.appendingPathComponent("Library").appendingPathComponent(relativePath)
            if directory {
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            } else {
                try FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data("fixture".utf8).write(to: url)
            }
            return url
        }

        func createAppExecutable(_ relativePath: String = "Contents/MacOS/helper") throws -> URL {
            let url = appURL.appendingPathComponent(relativePath)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try Data("executable".utf8).write(to: url)
            return url
        }

        func createLaunchAgentPlist(_ relativePath: String,
                                    dictionary: [String: Any]) throws -> URL {
            let url = home.appendingPathComponent("Library/LaunchAgents")
                .appendingPathComponent(relativePath)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            let data = try PropertyListSerialization.data(fromPropertyList: dictionary,
                                                          format: .xml, options: 0)
            try data.write(to: url)
            return url
        }

        func service(safety: any SafetyEngine = AllowAllSafety(),
                     entitlements: [String]? = [],
                     launchAgents: [String: LaunchAgentRecord] = [:],
                     clock: (any UninstallTrustedClock)? = nil) -> UninstallerService {
            UninstallerService(
                fs: LocalFileSystemService(),
                safety: safety,
                home: home,
                entitlementReader: FakeEntitlementReader(groups: entitlements),
                launchAgentReader: FakeLaunchAgentReader(records: launchAgents),
                clock: clock,
                issuanceID: issuanceID)
        }

        func remove() { try? FileManager.default.removeItem(at: root) }
    }

    func testStrictReverseDNSParserRejectsEmptySegments() throws { // UNI-01
        XCTAssertNil(BundleIdentifier(rawValue: "com..example"))
        XCTAssertNil(BundleIdentifier(rawValue: ".com.example"))
        XCTAssertNil(BundleIdentifier(rawValue: "com.example."))
        XCTAssertNotNil(BundleIdentifier(rawValue: "com.example.product"))
    }

    func testStrictReverseDNSParserRejectsPathAndIllegalCharacters() throws { // UNI-01
        for value in [".", "..", "com/example.app", "com\\example.app", "com.example_app",
                      "com.example app", "com.-example", "com.example-"] {
            XCTAssertNil(BundleIdentifier(rawValue: value), value)
        }
        XCTAssertNil(BundleIdentifier(rawValue: "com.éxample.product"))
        XCTAssertNotNil(BundleIdentifier(rawValue: "com.example-2.product9"))
    }

    func testStrictReverseDNSParserRejectsWeakShortTokenAndOverlongComponents() throws { // UNI-01
        XCTAssertNil(BundleIdentifier(rawValue: "x"))
        XCTAssertNil(BundleIdentifier(rawValue: "product"))
        XCTAssertNil(BundleIdentifier(rawValue: "com.\(String(repeating: "a", count: 64))"))
        let tooLong = ["com", "example"] + Array(repeating: String(repeating: "a", count: 60), count: 5)
        XCTAssertNil(BundleIdentifier(rawValue: tooLong.joined(separator: ".")))
    }

    func testListAppsRejectsSymlinkedApplicationsAncestor() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("xico-app-ancestor-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("home")
        let outsideApps = root.appendingPathComponent("outside-applications")
        let outsideApp = outsideApps.appendingPathComponent("Escaped.app")
        let contents = outsideApp.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let info = try PropertyListSerialization.data(
            fromPropertyList: ["CFBundleIdentifier": "com.example.escaped",
                               "CFBundleName": "Escaped"],
            format: .xml, options: 0)
        try info.write(to: contents.appendingPathComponent("Info.plist"))
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: home.appendingPathComponent("Applications"), withDestinationURL: outsideApps)
        let logicalApp = home.appendingPathComponent("Applications/Escaped.app")
        let fs = DirectoryListingFileSystem(
            overriddenDirectoryPath: home.appendingPathComponent("Applications").path,
            listedURLs: [logicalApp])
        let service = UninstallerService(fs: fs,
                                         safety: AllowAllSafety(), home: home)

        XCTAssertFalse(service.listApps().contains {
            $0.url.lastPathComponent == "Escaped.app"
        })
    }

    func testMissingBundleIDDoesNotFallBackToURLPathForAttribution() throws { // UNI-01
        let fixture = try Fixture(bundleID: "")
        defer { fixture.remove() }
        let pathFallbackTarget = try fixture.createLibraryItem("Caches/\(fixture.appURL.path)")

        let candidates = try fixture.service().uninstallTargets(for: fixture.app, mode: .uninstallApp).candidates

        XCTAssertFalse(candidates.contains { $0.url.path == pathFallbackTarget.path })
        let appBody = try XCTUnwrap(candidates.first { $0.url.path == fixture.appURL.path })
        XCTAssertEqual(appBody.evidence, .verifiedAppBody)
        XCTAssertEqual(appBody.selectionPolicy, .required)
    }

    func testExactBundleIDPathsGetRecommendedSelectionPolicy() throws { // UNI-04
        let fixture = try Fixture()
        defer { fixture.remove() }
        let bid = fixture.app.bundleID
        let paths = [
            "Application Support/\(bid)", "Caches/\(bid)", "Preferences/\(bid).plist",
            "Containers/\(bid)", "Saved Application State/\(bid).savedState", "Logs/\(bid)",
            "HTTPStorages/\(bid)", "WebKit/\(bid)"
        ]
        let urls = try paths.map { try fixture.createLibraryItem($0, directory: !$0.hasSuffix(".plist")) }

        let candidates = try fixture.service().uninstallTargets(for: fixture.app, mode: .uninstallApp).candidates

        for url in urls {
            let candidate = try XCTUnwrap(candidates.first { $0.url.path == url.path },
                                          "missing \(url.path); got \(candidates.map { $0.url.path })")
            XCTAssertEqual(candidate.evidence, .exactBundleIDPath)
            XCTAssertEqual(candidate.selectionPolicy, .recommended)
            XCTAssertTrue(candidate.isSelected)
        }
    }

    func testAppGroupsReadFromSignedEntitlementsAreMarkedManualOnly() throws { // UNI-06
        let fixture = try Fixture()
        defer { fixture.remove() }
        let group = "group.com.example.shared"
        let url = try fixture.createLibraryItem("Group Containers/\(group)")

        let candidates = try fixture.service(entitlements: [group])
            .uninstallTargets(for: fixture.app, mode: .uninstallApp).candidates

        let candidate = try XCTUnwrap(candidates.first { $0.url.path == url.path })
        XCTAssertEqual(candidate.evidence, .signedApplicationGroup)
        XCTAssertEqual(candidate.selectionPolicy, .manualOnly)
        XCTAssertFalse(candidate.isSelected)
    }

    func testUnsignedOrMismatchedAppGroupIsNotRecommended() throws { // UNI-06
        let fixture = try Fixture()
        defer { fixture.remove() }
        let url = try fixture.createLibraryItem("Group Containers/group.com.example.shared")

        for entitlements in [Optional<[String]>.none, ["group.com.other.shared"]] {
            let candidates = try fixture.service(entitlements: entitlements)
                .uninstallTargets(for: fixture.app, mode: .uninstallApp).candidates
            XCTAssertFalse(candidates.contains {
                $0.url.path == url.path && ($0.evidence == .signedApplicationGroup || $0.selectionPolicy == .recommended)
            })
        }
    }

    func testSecurityEntitlementReaderRejectsUnsignedTemporaryBundle() throws { // UNI-06
        let fixture = try Fixture()
        defer { fixture.remove() }

        XCTAssertNil(SecurityEntitlementReader().attestation(for: fixture.appURL))
    }

    func testPrepareUninstallPlanRejectsChangedSignedEntitlementAttestation() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let group = "group.com.example.shared"
        _ = try fixture.createLibraryItem("Group Containers/\(group)")
        let seeded = try XCTUnwrap(
            FakeEntitlementReader(groups: [group]).attestation(for: fixture.appURL))
        let sourceSeal = try XCTUnwrap(seeded.sourceSeal)
        let original = SignedEntitlementAttestation(
            groups: [group], codeIdentifier: fixture.app.bundleID,
            uniqueCode: Data([1, 2, 3]), sourceIdentity: fixture.app.sourceIdentity,
            sourceSeal: sourceSeal)
        let reader = MutableEntitlementAttestationReader(original)
        let service = UninstallerService(
            fs: LocalFileSystemService(), safety: AllowAllSafety(), home: fixture.home,
            entitlementReader: reader, launchAgentReader: FakeLaunchAgentReader(records: [:]),
            issuanceID: fixture.issuanceID)
        let batch = try service.uninstallTargets(for: fixture.app, mode: .uninstallApp)
        reader.set(SignedEntitlementAttestation(
            groups: [group], codeIdentifier: fixture.app.bundleID,
            uniqueCode: Data([9, 9, 9]), sourceIdentity: fixture.app.sourceIdentity,
            sourceSeal: sourceSeal))
        let issuer = DestructiveOperationIssuer(sampler: LocalFileIdentitySampler(),
                                                ledger: AuthorizationLedger())

        XCTAssertThrowsError(try service.prepareUninstallExecution(from: batch, using: issuer)) {
            XCTAssertEqual($0 as? UninstallPlanError, .entitlementAttestationChanged)
        }
    }

    func testLaunchAgentRecommendedOnlyWhenLabelExactAndProgramInsideBundle() throws { // UNI-07
        let fixture = try Fixture()
        defer { fixture.remove() }
        let plist = try fixture.createLibraryItem("LaunchAgents/\(fixture.app.bundleID).plist", directory: false)
        let executable = try fixture.createAppExecutable()
        let record = LaunchAgentRecord(label: fixture.app.bundleID,
                                       program: executable.path,
                                       programArguments: [])

        let candidates = try fixture.service(launchAgents: [plist.path: record])
            .uninstallTargets(for: fixture.app, mode: .uninstallApp).candidates

        let candidate = try XCTUnwrap(candidates.first { $0.url.path == plist.path })
        XCTAssertEqual(candidate.evidence, .launchAgentProgramInsideBundle)
        XCTAssertEqual(candidate.selectionPolicy, .recommended)
        XCTAssertTrue(candidate.isSelected)
    }

    func testLaunchAgentProgramArgumentsFirstExecutableInsideBundleIsRecommended() throws { // UNI-07
        let fixture = try Fixture()
        defer { fixture.remove() }
        let plist = try fixture.createLibraryItem("LaunchAgents/\(fixture.app.bundleID).plist", directory: false)
        let executable = try fixture.createAppExecutable()
        let record = LaunchAgentRecord(label: fixture.app.bundleID, program: nil,
                                       programArguments: [executable.path, "--background"])

        let candidates = try fixture.service(launchAgents: [plist.path: record])
            .uninstallTargets(for: fixture.app, mode: .uninstallApp).candidates

        let candidate = try XCTUnwrap(candidates.first { $0.url.path == plist.path })
        XCTAssertEqual(candidate.evidence, .launchAgentProgramInsideBundle)
        XCTAssertEqual(candidate.selectionPolicy, .recommended)
    }

    func testLaunchAgentMissingProgramInsideBundleIsNotRecommended() throws { // UNI-07
        let fixture = try Fixture()
        defer { fixture.remove() }
        let plist = try fixture.createLibraryItem("LaunchAgents/\(fixture.app.bundleID).plist", directory: false)
        let missing = fixture.appURL.appendingPathComponent("Contents/MacOS/missing")
        let record = LaunchAgentRecord(label: fixture.app.bundleID, program: missing.path,
                                       programArguments: [])

        let candidates = try fixture.service(launchAgents: [plist.path: record])
            .uninstallTargets(for: fixture.app, mode: .uninstallApp).candidates

        XCTAssertFalse(candidates.contains {
            $0.url.path == plist.path && $0.selectionPolicy == .recommended
        })
    }

    func testLaunchAgentSymlinkEscapeOutsideBundleIsNotRecommended() throws { // UNI-07
        let fixture = try Fixture()
        defer { fixture.remove() }
        let plist = try fixture.createLibraryItem("LaunchAgents/\(fixture.app.bundleID).plist", directory: false)
        // Keep the escape target off the sealed app path's ancestors. Creating a sibling
        // directly under `fixture.root` would correctly invalidate the root-chain ctime proof
        // before this test reaches the program-symlink assertion.
        let outside = fixture.home.appendingPathComponent("Library/outside-program")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let outsideProgram = outside.appendingPathComponent("helper")
        try Data("outside".utf8).write(to: outsideProgram)
        let macOSDirectory = fixture.appURL.appendingPathComponent("Contents/MacOS")
        let linkedDirectory = macOSDirectory.appendingPathComponent("LinkedHelpers")
        try FileManager.default.createSymbolicLink(at: linkedDirectory, withDestinationURL: outside)
        let apparentProgram = linkedDirectory.appendingPathComponent("helper")
        let record = LaunchAgentRecord(label: fixture.app.bundleID, program: apparentProgram.path,
                                       programArguments: [])

        let candidates = try fixture.service(launchAgents: [plist.path: record])
            .uninstallTargets(for: fixture.app, mode: .uninstallApp).candidates

        XCTAssertFalse(candidates.contains {
            $0.url.path == plist.path && $0.selectionPolicy == .recommended
        })
    }

    func testPlistLaunchAgentReaderRejectsSymlink() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let target = try fixture.createLaunchAgentPlist("real.plist", dictionary: [
            "Label": fixture.app.bundleID,
            "Program": "/bin/true"
        ])
        let link = target.deletingLastPathComponent().appendingPathComponent("link.plist")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        XCTAssertNil(PlistLaunchAgentReader().launchAgent(at: link))
    }

    func testPlistLaunchAgentReaderRejectsPlistOverOneMiB() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let plist = try fixture.createLaunchAgentPlist("oversized.plist", dictionary: [
            "Label": fixture.app.bundleID,
            "Program": "/bin/true",
            "Padding": String(repeating: "x", count: 1_048_576)
        ])

        XCTAssertNil(PlistLaunchAgentReader().launchAgent(at: plist))
    }

    func testPlistLaunchAgentReaderRejectsFIFOWithoutBlocking() throws {
        #if canImport(Darwin)
        let fixture = try Fixture()
        defer { fixture.remove() }
        let fifo = fixture.home.appendingPathComponent("Library/LaunchAgents/agent.fifo")
        try FileManager.default.createDirectory(at: fifo.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        XCTAssertEqual(mkfifo(fifo.path, 0o600), 0)

        let started = Date()
        XCTAssertNil(PlistLaunchAgentReader().launchAgent(at: fifo))
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.5)
        #endif
    }

    func testPlistLaunchAgentReaderReturnsOnlyBoundedPlistEvidenceBeforeAppAnchoring() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let executable = try fixture.createAppExecutable()
        let plist = try fixture.createLaunchAgentPlist(
            "\(fixture.app.bundleID).plist",
            dictionary: ["Label": fixture.app.bundleID, "Program": executable.path])

        let attestation = try XCTUnwrap(PlistLaunchAgentReader().attestation(at: plist))

        XCTAssertEqual(attestation.record.label, fixture.app.bundleID)
        XCTAssertEqual(attestation.plistIdentity,
                       LocalFileIdentitySampler().sample(plist.path))
        XCTAssertGreaterThan(attestation.plistExactLength, 0)
        XCTAssertNotEqual(attestation.plistContentDigest, .none)
        XCTAssertNil(attestation.resolvedProgramPath)
        XCTAssertNil(attestation.programIdentity)
    }

    func testPlistLaunchAgentReaderRejectsPathReplacementDuringRead() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let executable = try fixture.createAppExecutable()
        let plist = try fixture.createLaunchAgentPlist(
            "\(fixture.app.bundleID).plist",
            dictionary: ["Label": fixture.app.bundleID, "Program": executable.path])
        let replacement = try fixture.createLaunchAgentPlist(
            "replacement.plist",
            dictionary: ["Label": fixture.app.bundleID, "Program": executable.path])
        let reader = PlistLaunchAgentReader(afterRead: {
            try? FileManager.default.removeItem(at: plist)
            try? FileManager.default.moveItem(at: replacement, to: plist)
        })

        XCTAssertNil(reader.attestation(at: plist))
    }

    func testBoundedReaderRejectsEqualLengthSameInodeRewriteWithRestoredMTime() throws {
        #if canImport(Darwin)
        let fixture = try Fixture()
        defer { fixture.remove() }
        let file = fixture.root.appendingPathComponent("same-inode.plist")
        try Data("AAAA".utf8).write(to: file)
        var originalStat = stat()
        XCTAssertEqual(lstat(file.path, &originalStat), 0)
        let originalAccessTime = originalStat.st_atimespec
        let originalModificationTime = originalStat.st_mtimespec
        let before = try XCTUnwrap(LocalFileIdentitySampler().sample(file.path))

        let read = BoundedRegularFileReader.read(at: file, maximumBytes: 1024) {
            let descriptor = open(file.path, O_WRONLY)
            if descriptor >= 0 {
                _ = Data("BBBB".utf8).withUnsafeBytes {
                    pwrite(descriptor, $0.baseAddress, $0.count, 0)
                }
                close(descriptor)
            }
            var times = [originalAccessTime, originalModificationTime]
            _ = times.withUnsafeMutableBufferPointer {
                utimensat(AT_FDCWD, file.path, $0.baseAddress, 0)
            }
        }

        XCTAssertNil(read)
        let after = try XCTUnwrap(LocalFileIdentitySampler().sample(file.path))
        XCTAssertEqual(after.inode, before.inode)
        XCTAssertEqual(after.size, before.size)
        XCTAssertEqual(after.mtimeNanoseconds, before.mtimeNanoseconds)
        XCTAssertNotEqual(after.changeTimeNanoseconds, before.changeTimeNanoseconds)
        #endif
    }

    func testBoundedReaderReturnsExactLengthDigestAndChangeToken() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let file = fixture.root.appendingPathComponent("digest.plist")
        let bytes = Data("bounded-content".utf8)
        try bytes.write(to: file)

        let read = try XCTUnwrap(BoundedRegularFileReader.read(at: file, maximumBytes: 1024))

        XCTAssertEqual(read.exactLength, bytes.count)
        XCTAssertEqual(read.contentDigest.bytes, Array(SHA256.hash(data: bytes)))
        XCTAssertNotEqual(read.identity.changeTimeNanoseconds, 0)
    }

    func testBoundedReaderRejectsShortEOFComparedWithOpenedSize() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let file = fixture.root.appendingPathComponent("short-read.plist")
        try Data("12345678".utf8).write(to: file)

        let read = BoundedRegularFileReader.read(
            at: file,
            maximumBytes: 1024,
            afterOpen: {
                _ = truncate(file.path, 4)
            })

        XCTAssertNil(read)
    }

    func testPrepareUninstallPlanRejectsLaunchPlistReplacement() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let executable = try fixture.createAppExecutable()
        let plist = try fixture.createLaunchAgentPlist(
            "\(fixture.app.bundleID).plist",
            dictionary: ["Label": fixture.app.bundleID, "Program": executable.path])
        let service = UninstallerService(
            fs: LocalFileSystemService(), safety: AllowAllSafety(), home: fixture.home,
            entitlementReader: FakeEntitlementReader(groups: []),
            launchAgentReader: PlistLaunchAgentReader(),
            issuanceID: fixture.issuanceID)
        let batch = try service.uninstallTargets(for: fixture.app, mode: .uninstallApp)
        let replacement = try fixture.createLaunchAgentPlist(
            "replacement.plist",
            dictionary: ["Label": fixture.app.bundleID, "Program": executable.path])
        try FileManager.default.removeItem(at: plist)
        try FileManager.default.moveItem(at: replacement, to: plist)
        let issuer = DestructiveOperationIssuer(sampler: LocalFileIdentitySampler(),
                                                ledger: AuthorizationLedger())

        XCTAssertThrowsError(try service.prepareUninstallExecution(from: batch, using: issuer)) {
            XCTAssertEqual($0 as? UninstallPlanError, .launchAgentAttestationChanged)
        }
    }

    func testPrepareUninstallPlanRejectsLaunchProgramSamePathReplacement() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let executable = try fixture.createAppExecutable()
        _ = try fixture.createLaunchAgentPlist(
            "\(fixture.app.bundleID).plist",
            dictionary: ["Label": fixture.app.bundleID, "Program": executable.path])
        let service = UninstallerService(
            fs: LocalFileSystemService(), safety: AllowAllSafety(), home: fixture.home,
            entitlementReader: FakeEntitlementReader(groups: []),
            launchAgentReader: PlistLaunchAgentReader(),
            issuanceID: fixture.issuanceID)
        let batch = try service.uninstallTargets(for: fixture.app, mode: .uninstallApp)
        try FileManager.default.removeItem(at: executable)
        try Data("replacement executable".utf8).write(to: executable)
        let issuer = DestructiveOperationIssuer(sampler: LocalFileIdentitySampler(),
                                                ledger: AuthorizationLedger())

        XCTAssertThrowsError(try service.prepareUninstallExecution(from: batch, using: issuer)) {
            XCTAssertEqual($0 as? UninstallPlanError, .launchAgentAttestationChanged)
        }
    }

    func testPrepareRejectsLaunchProgramSameInodeRewriteWithRestoredMTime() throws {
        #if canImport(Darwin)
        let fixture = try Fixture()
        defer { fixture.remove() }
        let executable = try fixture.createAppExecutable()
        _ = try fixture.createLaunchAgentPlist(
            "\(fixture.app.bundleID).plist",
            dictionary: ["Label": fixture.app.bundleID, "Program": executable.path])
        let service = UninstallerService(
            fs: LocalFileSystemService(), safety: AllowAllSafety(), home: fixture.home,
            entitlementReader: FakeEntitlementReader(groups: []),
            launchAgentReader: PlistLaunchAgentReader(),
            issuanceID: fixture.issuanceID)
        let batch = try service.uninstallTargets(for: fixture.app, mode: .uninstallApp)
        var before = stat()
        XCTAssertEqual(lstat(executable.path, &before), 0)
        let descriptor = open(executable.path, O_WRONLY | O_CLOEXEC)
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        var byte: UInt8 = 0x58
        _ = withUnsafeBytes(of: &byte) { pwrite(descriptor, $0.baseAddress, 1, 0) }
        close(descriptor)
        var times = [before.st_atimespec, before.st_mtimespec]
        _ = times.withUnsafeMutableBufferPointer {
            utimensat(AT_FDCWD, executable.path, $0.baseAddress, 0)
        }
        let issuer = DestructiveOperationIssuer(sampler: LocalFileIdentitySampler(),
                                                ledger: AuthorizationLedger())

        XCTAssertThrowsError(try service.prepareUninstallExecution(from: batch, using: issuer)) {
            XCTAssertEqual($0 as? UninstallPlanError, .launchAgentAttestationChanged)
        }
        #endif
    }

    func testLaunchProgramSymlinkInsideBundleIsNeverRecommended() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let first = try fixture.createAppExecutable("Contents/MacOS/first")
        let link = fixture.appURL.appendingPathComponent("Contents/MacOS/current")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: first)
        _ = try fixture.createLaunchAgentPlist(
            "\(fixture.app.bundleID).plist",
            dictionary: ["Label": fixture.app.bundleID, "Program": link.path])
        let service = UninstallerService(
            fs: LocalFileSystemService(), safety: AllowAllSafety(), home: fixture.home,
            entitlementReader: FakeEntitlementReader(groups: []),
            launchAgentReader: PlistLaunchAgentReader(),
            issuanceID: fixture.issuanceID)
        let batch = try service.uninstallTargets(for: fixture.app, mode: .uninstallApp)

        XCTAssertFalse(batch.candidates.contains {
            $0.url.path == fixture.home.appendingPathComponent(
                "Library/LaunchAgents/\(fixture.app.bundleID).plist").path
                && $0.selectionPolicy == .recommended
        })
    }

    func testLaunchAgentWithProgramOutsideBundleIsNotRecommended() throws { // UNI-07
        let fixture = try Fixture()
        defer { fixture.remove() }
        let plist = try fixture.createLibraryItem("LaunchAgents/\(fixture.app.bundleID).plist", directory: false)
        let record = LaunchAgentRecord(label: fixture.app.bundleID, program: "/usr/local/bin/shared-helper",
                                       programArguments: [])

        let candidates = try fixture.service(launchAgents: [plist.path: record])
            .uninstallTargets(for: fixture.app, mode: .uninstallApp).candidates

        XCTAssertFalse(candidates.contains {
            $0.url.path == plist.path && ($0.evidence == .launchAgentProgramInsideBundle || $0.selectionPolicy == .recommended)
        })
    }

    func testDisplayNameDirectoryIsHeuristicDefaultUnselected() throws { // UNI-08
        let fixture = try Fixture()
        defer { fixture.remove() }
        let url = try fixture.createLibraryItem("Application Support/\(fixture.app.name)")

        let candidates = try fixture.service().uninstallTargets(for: fixture.app, mode: .uninstallApp).candidates

        let candidate = try XCTUnwrap(candidates.first { $0.url.path == url.path })
        XCTAssertEqual(candidate.evidence, .displayNameHeuristic)
        XCTAssertEqual(candidate.selectionPolicy, .manualOnly)
        XCTAssertFalse(candidate.isSelected)
    }

    func testSelectAllExcludesManualOnlyAndHeuristicCandidates() throws { // UNI-08
        let fixture = try Fixture()
        defer { fixture.remove() }
        let exact = try fixture.createLibraryItem("Caches/\(fixture.app.bundleID)")
        let heuristic = try fixture.createLibraryItem("Application Support/\(fixture.app.name)")
        let group = "group.com.example.shared"
        let groupURL = try fixture.createLibraryItem("Group Containers/\(group)")
        var batch = try fixture.service(entitlements: [group])
            .uninstallTargets(for: fixture.app, mode: .uninstallApp)

        batch.selectAll()
        let selected = batch.candidates

        XCTAssertTrue(try XCTUnwrap(selected.first { $0.url.path == fixture.appURL.path }).isSelected)
        XCTAssertTrue(try XCTUnwrap(selected.first { $0.url.path == exact.path }).isSelected)
        XCTAssertFalse(try XCTUnwrap(selected.first { $0.url.path == heuristic.path }).isSelected)
        XCTAssertFalse(try XCTUnwrap(selected.first { $0.url.path == groupURL.path }).isSelected)
    }

    func testUninstallAppModeMarksAppBodyRequiredNonDeselectable() throws { // UNI-02
        let fixture = try Fixture()
        defer { fixture.remove() }
        let candidates = try fixture.service().uninstallTargets(for: fixture.app, mode: .uninstallApp).candidates

        var appBody = try XCTUnwrap(candidates.first { $0.url.path == fixture.appURL.path })
        XCTAssertEqual(appBody.selectionPolicy, .required)
        XCTAssertFalse(appBody.isSelectable)
        appBody.setSelected(false)
        XCTAssertTrue(appBody.isSelected)
    }

    func testUninstallAppBatchCarriesVerifiedAppBodyRoleAndEvidence() throws { // UNI-02
        let fixture = try Fixture()
        defer { fixture.remove() }

        let batch = try fixture.service().uninstallTargets(for: fixture.app, mode: .uninstallApp)

        let appBody = try XCTUnwrap(batch.candidates.first { $0.url.path == fixture.appURL.path })
        XCTAssertEqual(appBody.role, .appBody)
        XCTAssertEqual(appBody.evidence, .verifiedAppBody)
        XCTAssertEqual(appBody.selectionPolicy, .required)
    }

    func testUninstallAppModeFailsClosedWhenAppBodyIsMissing() throws { // UNI-02
        let fixture = try Fixture()
        defer { fixture.remove() }
        try FileManager.default.removeItem(at: fixture.appURL)

        XCTAssertThrowsError(
            try fixture.service().uninstallTargets(for: fixture.app, mode: .uninstallApp)
        ) { error in
            XCTAssertEqual(error as? UninstallerAttributionError, .appBodyNotAdmitted)
        }
    }

    func testUninstallAppModeFailsClosedWhenSafetyDeniesAppBody() throws { // UNI-02
        let fixture = try Fixture()
        defer { fixture.remove() }
        let safety = DenyURLSafety(deniedPath: fixture.appURL.path)

        XCTAssertThrowsError(
            try fixture.service(safety: safety)
                .uninstallTargets(for: fixture.app, mode: .uninstallApp)
        ) { error in
            XCTAssertEqual(error as? UninstallerAttributionError, .appBodyNotAdmitted)
        }
    }

    func testCleanLeftoversModeRequiresAppAbsent() throws { // UNI-03
        let fixture = try Fixture()
        defer { fixture.remove() }
        XCTAssertThrowsError(
            try fixture.service().uninstallTargets(for: fixture.app, mode: .cleanLeftovers)
        ) { error in
            XCTAssertEqual(error as? UninstallerAttributionError, .appStillPresent)
        }

        try FileManager.default.removeItem(at: fixture.appURL)
        let candidates = try fixture.service().uninstallTargets(for: fixture.app, mode: .cleanLeftovers).candidates
        XCTAssertFalse(candidates.contains { $0.url.path == fixture.appURL.path })
    }

    func testEveryCandidateCarriesOwnershipEvidenceAndRecoveryHint() throws { // UNI-09
        let fixture = try Fixture()
        defer { fixture.remove() }
        _ = try fixture.createLibraryItem("Caches/\(fixture.app.bundleID)")
        _ = try fixture.createLibraryItem("Application Support/\(fixture.app.name)")

        let candidates = try fixture.service().uninstallTargets(for: fixture.app, mode: .uninstallApp).candidates

        XCTAssertFalse(candidates.isEmpty)
        XCTAssertTrue(candidates.allSatisfy { !$0.recoveryHint.isEmpty })
        XCTAssertTrue(candidates.allSatisfy { $0.targetRequest.recoverability == .trashRestorable })
    }

    func testSelectedCandidatesPrepareAnUninstallPlanWithMappedEvidence() throws { // UNI-09 / Task 1
        let fixture = try Fixture()
        defer { fixture.remove() }
        let exact = try fixture.createLibraryItem("Caches/\(fixture.app.bundleID)")
        let service = fixture.service()
        let batch = try service.uninstallTargets(for: fixture.app, mode: .uninstallApp)
        let candidates = batch.candidates
        let issuer = DestructiveOperationIssuer(sampler: LocalFileIdentitySampler(),
                                                ledger: AuthorizationLedger())

        let plan = try service.prepareUninstallExecution(from: batch, using: issuer).plan

        XCTAssertEqual(plan.kind, .uninstall)
        let exactCandidate = try XCTUnwrap(candidates.first { $0.url.path == exact.path })
        let target = try XCTUnwrap(plan.targets.first {
            $0.canonicalPath == exactCandidate.targetRequest.canonicalPath
        })
        XCTAssertEqual(target.attribution, Domain.AttributionEvidence.exactBundleIDPath)
        XCTAssertEqual(target.recoverability, .trashRestorable)
        let body = try XCTUnwrap(plan.targets.first {
            $0.canonicalPath == batch.candidates.first(where: { $0.role == .appBody })?
                .targetRequest.canonicalPath
        })
        XCTAssertEqual(body.attribution, Domain.AttributionEvidence.verifiedAppBody)
    }

    func testPreparationSealsExactPlanTargetOrderIdentityAndFingerprint() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        _ = try fixture.createLibraryItem("Caches/\(fixture.app.bundleID)")
        _ = try fixture.createLibraryItem("Preferences/\(fixture.app.bundleID).plist",
                                          directory: false)
        let service = fixture.service()
        let batch = try service.uninstallTargets(for: fixture.app, mode: .uninstallApp)
        let issuer = DestructiveOperationIssuer(sampler: LocalFileIdentitySampler(),
                                                ledger: AuthorizationLedger())

        let prepared = try service.prepareUninstallExecution(from: batch, using: issuer)

        XCTAssertEqual(prepared.plan.targets.count, prepared.orderedTargets.count)
        XCTAssertTrue(prepared.orderedTargets.dropLast().allSatisfy {
            $0.candidate.role == .associatedFile
        })
        XCTAssertEqual(prepared.orderedTargets.last?.candidate.role, .appBody)
        for (planTarget, sealedTarget) in zip(prepared.plan.targets,
                                              prepared.orderedTargets) {
            XCTAssertEqual(planTarget.canonicalPath, sealedTarget.canonicalPath)
            XCTAssertEqual(planTarget.identity, sealedTarget.expectedIdentity)
            XCTAssertEqual(planTarget.evidenceFingerprint,
                           sealedTarget.evidenceFingerprint)
            XCTAssertNotEqual(planTarget.evidenceFingerprint, .none)
        }
        XCTAssertEqual(prepared.preparationSeal.count, 32)
    }

    func testPreparationAcceptsSiblingMetadataDriftAlongSameAppPhysicalChain() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let service = fixture.service()
        let batch = try service.uninstallTargets(for: fixture.app, mode: .uninstallApp)
        let sibling = fixture.appURL.deletingLastPathComponent()
            .appendingPathComponent("New Sibling.app")
        try FileManager.default.createDirectory(at: sibling,
                                                withIntermediateDirectories: true)
        let issuer = DestructiveOperationIssuer(
            sampler: LocalFileIdentitySampler(), ledger: AuthorizationLedger())

        let prepared = try service.prepareUninstallExecution(from: batch, using: issuer)

        XCTAssertEqual(prepared.batchSnapshot.app.sourceIdentity,
                       fixture.app.sourceIdentity)
        XCTAssertEqual(prepared.orderedTargets.last?.candidate.role, .appBody)
    }

    func testPreparationRejectsIdentitySubstitutionAfterValidationBeforeIssuerSampling() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let sampler = HookedIdentitySampler()
        let service = UninstallerService(
            fs: LocalFileSystemService(), safety: AllowAllSafety(), home: fixture.home,
            entitlementReader: FakeEntitlementReader(groups: []),
            launchAgentReader: FakeLaunchAgentReader(records: [:]),
            preparationHooks: UninstallPreparationHooks(
                beforeIssuerPrepare: sampler.enableSubstitution),
            issuanceID: fixture.issuanceID)
        let batch = try service.uninstallTargets(for: fixture.app, mode: .uninstallApp)
        let issuer = DestructiveOperationIssuer(sampler: sampler,
                                                ledger: AuthorizationLedger())

        XCTAssertThrowsError(
            try service.prepareUninstallExecution(from: batch, using: issuer)
        ) {
            XCTAssertEqual($0 as? UninstallPlanError, .preparedTargetMismatch)
        }
    }

    func testPreparationRejectsCountOrderPathIdentityAndFingerprintSubstitution() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        _ = try fixture.createLibraryItem("Caches/\(fixture.app.bundleID)")

        for mutation in PreparedPlanMutation.allCases {
            let service = UninstallerService(
                fs: LocalFileSystemService(), safety: AllowAllSafety(), home: fixture.home,
                entitlementReader: FakeEntitlementReader(groups: []),
                launchAgentReader: FakeLaunchAgentReader(records: [:]),
                preparationHooks: UninstallPreparationHooks(
                    beforeIssuerPrepare: {},
                    afterIssuerPrepare: { Self.mutating($0, mutation) }),
                issuanceID: fixture.issuanceID)
            let batch = try service.uninstallTargets(for: fixture.app, mode: .uninstallApp)
            let issuer = DestructiveOperationIssuer(
                sampler: LocalFileIdentitySampler(), ledger: AuthorizationLedger())

            XCTAssertThrowsError(
                try service.prepareUninstallExecution(from: batch, using: issuer),
                "mutation \(mutation.rawValue) must fail closed"
            ) {
                XCTAssertEqual($0 as? UninstallPlanError, .preparedTargetMismatch,
                               "mutation \(mutation.rawValue)")
            }
        }
    }

    func testPreparedCandidateAndItemSubstitutionNeverInvokesOperation() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        _ = try fixture.createLibraryItem("Caches/\(fixture.app.bundleID)")

        for mutation in PreparedPayloadMutation.allCases {
            let service = UninstallerService(
                fs: LocalFileSystemService(), safety: AllowAllSafety(), home: fixture.home,
                entitlementReader: FakeEntitlementReader(groups: []),
                launchAgentReader: FakeLaunchAgentReader(records: [:]),
                preparationHooks: UninstallPreparationHooks(
                    afterPreparation: { Self.mutating($0, mutation) }),
                issuanceID: fixture.issuanceID)
            let batch = try service.uninstallTargets(for: fixture.app, mode: .uninstallApp)
            let counter = InvocationCounter()
            let payloadExecutor = RecordingPayloadExecutor(counter: counter)
            let controller = UninstallCapabilityController(
                service: service,
                payloadExecutor: payloadExecutor,
                issuer: DestructiveOperationIssuer(
                    sampler: LocalFileIdentitySampler(), ledger: AuthorizationLedger()))
            let confirmation = controller.beginConfirmation(for: batch)

            do {
                _ = try await controller.execute(confirmation: confirmation)
                XCTFail("mutation \(mutation.rawValue) must fail closed")
            } catch let error {
                XCTAssertEqual(error as? UninstallPlanError, .preparedTargetMismatch,
                               "mutation \(mutation.rawValue)")
            }
            XCTAssertEqual(counter.count, 0, "mutation \(mutation.rawValue)")
        }
    }

    func testBeforeIssuerHookRealAppReplacementNeverInvokesOperation() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let appURL = fixture.appURL
        let bundleID = fixture.app.bundleID
        let appName = fixture.app.name
        let replacementInfo = try PropertyListSerialization.data(
            fromPropertyList: ["CFBundleIdentifier": bundleID, "CFBundleName": appName],
            format: .xml, options: 0)
        let service = UninstallerService(
            fs: LocalFileSystemService(), safety: AllowAllSafety(), home: fixture.home,
            entitlementReader: FakeEntitlementReader(groups: []),
            launchAgentReader: FakeLaunchAgentReader(records: [:]),
            preparationHooks: UninstallPreparationHooks(beforeIssuerPrepare: {
                try! FileManager.default.removeItem(at: appURL)
                let contents = appURL.appendingPathComponent("Contents")
                try! FileManager.default.createDirectory(
                    at: contents.appendingPathComponent("MacOS"),
                    withIntermediateDirectories: true)
                try! replacementInfo.write(to: contents.appendingPathComponent("Info.plist"))
            }),
            issuanceID: fixture.issuanceID)
        let batch = try service.uninstallTargets(for: fixture.app, mode: .uninstallApp)
        let counter = InvocationCounter()
        let payloadExecutor = RecordingPayloadExecutor(counter: counter)
        let controller = UninstallCapabilityController(
            service: service,
            payloadExecutor: payloadExecutor,
            issuer: DestructiveOperationIssuer(sampler: LocalFileIdentitySampler(),
                                                ledger: AuthorizationLedger()))
        let confirmation = controller.beginConfirmation(for: batch)

        do {
            _ = try await controller.execute(confirmation: confirmation)
            XCTFail("a replaced app body must never reach the operation")
        } catch {
            XCTAssertEqual(error as? UninstallPlanError, .appIdentityChanged)
        }
        XCTAssertEqual(counter.count, 0)
    }

    func testBeforeIssuerHookRealLaunchAgentPlistReplacementNeverInvokesOperation() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let executable = try fixture.createAppExecutable()
        let plist = try fixture.createLaunchAgentPlist(
            "\(fixture.app.bundleID).plist",
            dictionary: ["Label": fixture.app.bundleID, "Program": executable.path])
        let replacementData = try Data(contentsOf: plist)
        let service = UninstallerService(
            fs: LocalFileSystemService(), safety: AllowAllSafety(), home: fixture.home,
            entitlementReader: FakeEntitlementReader(groups: []),
            launchAgentReader: PlistLaunchAgentReader(),
            preparationHooks: UninstallPreparationHooks(beforeIssuerPrepare: {
                try! FileManager.default.removeItem(at: plist)
                try! replacementData.write(to: plist)
            }),
            issuanceID: fixture.issuanceID)
        let batch = try service.uninstallTargets(for: fixture.app, mode: .uninstallApp)
        XCTAssertTrue(batch.candidates.contains {
            $0.url.standardizedFileURL.path == plist.standardizedFileURL.path
                && $0.evidence == .launchAgentProgramInsideBundle
        })
        let counter = InvocationCounter()
        let payloadExecutor = RecordingPayloadExecutor(counter: counter)
        let controller = UninstallCapabilityController(
            service: service,
            payloadExecutor: payloadExecutor,
            issuer: DestructiveOperationIssuer(sampler: LocalFileIdentitySampler(),
                                                ledger: AuthorizationLedger()))
        let confirmation = controller.beginConfirmation(for: batch)

        do {
            _ = try await controller.execute(confirmation: confirmation)
            XCTFail("a replaced LaunchAgent plist must never reach the operation")
        } catch {
            XCTAssertEqual(error as? UninstallPlanError,
                           .launchAgentAttestationChanged)
        }
        XCTAssertEqual(counter.count, 0)
    }

    func testPreparationRejectsDuplicateCanonicalAndPhysicalTarget() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        _ = try fixture.createLibraryItem("Caches/\(fixture.app.bundleID)")
        let service = fixture.service()
        let batch = try service.uninstallTargets(for: fixture.app, mode: .uninstallApp)
        let original = try XCTUnwrap(batch.candidates.first { $0.role == .associatedFile })
        let duplicate = UninstallCandidate(
            item: CleanableItem(url: original.url, displayName: original.item.displayName,
                                size: original.item.size, safety: original.item.safety,
                                isSelected: true),
            evidence: original.evidence,
            selectionPolicy: original.selectionPolicy,
            role: original.role,
            batchID: batch.batchID,
            evidenceBinding: original.evidenceBinding)
        let forged = UninstallBatch(
            issuanceID: batch.issuanceID, batchID: batch.batchID, app: batch.app,
            mode: batch.mode, candidates: batch.candidates + [duplicate],
            entitlementAttestation: batch.entitlementAttestation)
        let issuer = DestructiveOperationIssuer(sampler: LocalFileIdentitySampler(),
                                                ledger: AuthorizationLedger())

        XCTAssertThrowsError(
            try service.prepareUninstallExecution(from: forged, using: issuer)
        ) {
            XCTAssertEqual($0 as? UninstallPlanError, .duplicateTarget)
        }
    }

    func testPreparationRejectsDistinctCanonicalPathsToSameHardLinkedObject() throws {
        #if canImport(Darwin)
        let fixture = try Fixture()
        defer { fixture.remove() }
        let exact = try fixture.createLibraryItem(
            "Preferences/\(fixture.app.bundleID).plist", directory: false)
        let alias = fixture.home.appendingPathComponent(
            "Library/Application Support/\(fixture.app.name)")
        try FileManager.default.createDirectory(
            at: alias.deletingLastPathComponent(), withIntermediateDirectories: true)
        XCTAssertEqual(link(exact.path, alias.path), 0)

        let service = fixture.service()
        var batch = try service.uninstallTargets(for: fixture.app, mode: .uninstallApp)
        let aliasCandidate = try XCTUnwrap(batch.candidates.first {
            $0.url.standardizedFileURL.path == alias.standardizedFileURL.path
        })
        XCTAssertEqual(aliasCandidate.selectionPolicy, .manualOnly)
        batch.toggle(aliasCandidate.id)
        XCTAssertTrue(batch.candidates.first { $0.id == aliasCandidate.id }?.isSelected == true)
        let issuer = DestructiveOperationIssuer(sampler: LocalFileIdentitySampler(),
                                                ledger: AuthorizationLedger())

        XCTAssertThrowsError(
            try service.prepareUninstallExecution(from: batch, using: issuer)
        ) {
            XCTAssertEqual($0 as? UninstallPlanError, .duplicateTarget)
        }
        #endif
    }

    func testCapabilityControllerRejectsNilTargetIdentityWithoutInvokingOperation() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        _ = try fixture.createLibraryItem("Caches/\(fixture.app.bundleID)")
        let service = fixture.service()
        let batch = try service.uninstallTargets(for: fixture.app, mode: .uninstallApp)
        let issuer = DestructiveOperationIssuer(sampler: NilIdentitySampler(),
                                                ledger: AuthorizationLedger())
        let counter = InvocationCounter()
        let controller = UninstallCapabilityController(
            service: service,
            payloadExecutor: RecordingPayloadExecutor(counter: counter),
            issuer: issuer)
        let confirmation = controller.beginConfirmation(for: batch)

        do {
            _ = try await controller.execute(confirmation: confirmation)
            XCTFail("nil identity must fail closed")
        } catch {
            XCTAssertEqual(error as? UninstallPlanError, .missingTargetIdentity)
        }

        XCTAssertEqual(counter.count, 0)
    }

    func testCapabilityControllerExecutesWhenEverySelectedIdentityExists() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        _ = try fixture.createLibraryItem("Caches/\(fixture.app.bundleID)")
        let service = fixture.service()
        let batch = try service.uninstallTargets(for: fixture.app, mode: .uninstallApp)
        let issuer = DestructiveOperationIssuer(sampler: LocalFileIdentitySampler(),
                                                ledger: AuthorizationLedger())
        let payloadExecutor = RecordingPayloadExecutor()
        let controller = UninstallCapabilityController(
            service: service, payloadExecutor: payloadExecutor, issuer: issuer)
        let confirmation = controller.beginConfirmation(for: batch)

        let result = try await controller.execute(confirmation: confirmation)

        guard case .executed = result else {
            return XCTFail("valid service-issued batch must pass the Task 1 capability")
        }
        XCTAssertEqual(payloadExecutor.selectedCounts, [batch.selectedCount])
    }

    func testCapabilityControllerConsumesBatchExactlyOnceSequentially() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let service = fixture.service()
        let batch = try service.uninstallTargets(for: fixture.app, mode: .uninstallApp)
        let counter = InvocationCounter()
        let controller = UninstallCapabilityController(
            service: service,
            payloadExecutor: RecordingPayloadExecutor(counter: counter),
            issuer: DestructiveOperationIssuer(sampler: LocalFileIdentitySampler(),
                                                ledger: AuthorizationLedger()))
        let confirmation = controller.beginConfirmation(for: batch)

        _ = try await controller.execute(confirmation: confirmation)
        do {
            _ = try await controller.execute(confirmation: confirmation)
            XCTFail("batch replay must fail closed")
        } catch {
            XCTAssertEqual(error as? UninstallPlanError, .batchAlreadyConsumed)
        }
        XCTAssertEqual(counter.count, 1)
    }

    func testCopiedBatchCannotReplayAcrossTwoIndependentControllersSequentially() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let service = fixture.service()
        let batch = try service.uninstallTargets(for: fixture.app, mode: .uninstallApp)
        let counter = InvocationCounter()
        let first = UninstallCapabilityController(
            service: service,
            payloadExecutor: RecordingPayloadExecutor(counter: counter),
            issuer: DestructiveOperationIssuer(sampler: LocalFileIdentitySampler(),
                                                ledger: AuthorizationLedger()))
        let second = UninstallCapabilityController(
            service: service,
            payloadExecutor: RecordingPayloadExecutor(counter: counter),
            issuer: DestructiveOperationIssuer(sampler: LocalFileIdentitySampler(),
                                                ledger: AuthorizationLedger()))
        let firstConfirmation = first.beginConfirmation(for: batch)
        let secondConfirmation = second.beginConfirmation(for: batch)

        _ = try await first.execute(confirmation: firstConfirmation)
        do {
            _ = try await second.execute(confirmation: secondConfirmation)
            XCTFail("the batch's shared state must reject a second controller")
        } catch {
            XCTAssertEqual(error as? UninstallPlanError, .batchAlreadyConsumed)
        }
        XCTAssertEqual(counter.count, 1)
    }

    func testCopiedBatchCannotReplayAcrossTwoIndependentControllersConcurrently() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let service = fixture.service()
        let batch = try service.uninstallTargets(for: fixture.app, mode: .uninstallApp)
        let counter = InvocationCounter()
        let first = UninstallCapabilityController(
            service: service,
            payloadExecutor: RecordingPayloadExecutor(counter: counter),
            issuer: DestructiveOperationIssuer(sampler: LocalFileIdentitySampler(),
                                                ledger: AuthorizationLedger()))
        let second = UninstallCapabilityController(
            service: service,
            payloadExecutor: RecordingPayloadExecutor(counter: counter),
            issuer: DestructiveOperationIssuer(sampler: LocalFileIdentitySampler(),
                                                ledger: AuthorizationLedger()))
        let firstConfirmation = first.beginConfirmation(for: batch)
        let secondConfirmation = second.beginConfirmation(for: batch)

        let executed = await withTaskGroup(of: Bool.self, returning: Int.self) { group in
            for index in 0..<12 {
                group.addTask {
                    let controller = index.isMultiple(of: 2) ? first : second
                    let confirmation = index.isMultiple(of: 2)
                        ? firstConfirmation : secondConfirmation
                    do {
                        let result = try await controller.execute(
                            confirmation: confirmation)
                        if case .executed = result { return true }
                    } catch {}
                    return false
                }
            }
            var count = 0
            for await value in group where value { count += 1 }
            return count
        }

        XCTAssertEqual(executed, 1)
        XCTAssertEqual(counter.count, 1)
    }

    func testBatchClaimTokenRejectsOverflowRollbackAndExactDeadline() async throws {
        let clock = ScriptedUninstallClock(
            wall: Date(timeIntervalSince1970: 100), monotonic: 99)
        XCTAssertNil(UninstallBatchClaimToken.make(
            clock: clock, issuedAtNanoseconds: UInt64.max - 1,
            lifetimeNanoseconds: 2))

        let token = try XCTUnwrap(UninstallBatchClaimToken.make(
            clock: clock, issuedAtNanoseconds: 100, lifetimeNanoseconds: 100))
        let rollback = await token.claimFresh()
        XCTAssertEqual(rollback, .notYetValid)
        clock.set(monotonic: 200)
        let exactDeadline = await token.claimFresh()
        XCTAssertEqual(exactDeadline, .expired,
                       "now == deadline must be strictly expired")
    }

    func testUninstallTargetsRejectsWallClockThatCannotRepresentExactFiniteTTL() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let clock = ScriptedUninstallClock(
            wall: Date(timeIntervalSince1970: .greatestFiniteMagnitude), monotonic: 1)
        let service = fixture.service(clock: clock)

        XCTAssertThrowsError(
            try service.uninstallTargets(for: fixture.app, mode: .uninstallApp)
        ) {
            XCTAssertEqual($0 as? UninstallerAttributionError, .trustedClockUnavailable)
        }
    }

    func testFutureCreatedBatchFailsPreclaimThenRetriesAfterWallClockRecovers() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let issuedAt = Date(timeIntervalSince1970: 200)
        let clock = ScriptedUninstallClock(wall: issuedAt, monotonic: 1_000)
        let service = fixture.service(clock: clock)
        let batch = try service.uninstallTargets(for: fixture.app, mode: .uninstallApp)
        let issuer = DestructiveOperationIssuer(
            sampler: LocalFileIdentitySampler(), ledger: AuthorizationLedger(),
            wallNow: { clock.wallNow() })
        let counter = InvocationCounter()
        let controller = UninstallCapabilityController(
            service: service,
            payloadExecutor: RecordingPayloadExecutor(counter: counter),
            issuer: issuer, clock: clock)
        let confirmation = controller.beginConfirmation(for: batch)

        clock.set(wall: issuedAt.addingTimeInterval(-1))
        do {
            _ = try await controller.execute(confirmation: confirmation)
            XCTFail("a future-created wall-clock batch must fail preclaim")
        } catch {
            XCTAssertEqual(error as? UninstallPlanError, .batchNotYetValid)
        }
        XCTAssertEqual(counter.count, 0)

        clock.set(wall: issuedAt)
        let result = try await controller.execute(confirmation: confirmation)
        guard case .executed = result else { return XCTFail("retry must execute") }
        XCTAssertEqual(counter.count, 1, "preclaim rejection must not consume the batch")
    }

    func testReadOnlyValidationFailureDoesNotConsumeAndCanRetry() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let safety = MutableSafety()
        let service = fixture.service(safety: safety)
        let batch = try service.uninstallTargets(for: fixture.app, mode: .uninstallApp)
        let counter = InvocationCounter()
        let controller = UninstallCapabilityController(
            service: service,
            payloadExecutor: RecordingPayloadExecutor(counter: counter),
            issuer: DestructiveOperationIssuer(
                sampler: LocalFileIdentitySampler(), ledger: AuthorizationLedger()))
        let confirmation = controller.beginConfirmation(for: batch)

        safety.deny()
        do {
            _ = try await controller.execute(confirmation: confirmation)
            XCTFail("changed safety must fail read-only preparation")
        } catch {
            XCTAssertEqual(error as? UninstallPlanError, .requiredAppBodyMissing)
        }
        safety.allow()

        let result = try await controller.execute(confirmation: confirmation)
        guard case .executed = result else { return XCTFail("repaired validation must retry") }
        XCTAssertEqual(counter.count, 1)
    }

    func testExpiryImmediatelyAfterClaimInvokesNoBodyAndClaimCannotReopen() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let issuedAt = Date(timeIntervalSince1970: 100)
        let clock = ScriptedUninstallClock(wall: issuedAt, monotonic: 1_000)
        let service = fixture.service(clock: clock)
        let batch = try service.uninstallTargets(for: fixture.app, mode: .uninstallApp)
        let counter = InvocationCounter()
        let controller = UninstallCapabilityController(
            service: service,
            payloadExecutor: RecordingPayloadExecutor(counter: counter),
            issuer: DestructiveOperationIssuer(
                sampler: LocalFileIdentitySampler(), ledger: AuthorizationLedger(),
                wallNow: { clock.wallNow() }),
            clock: clock,
            hooks: UninstallCapabilityHooks(afterClaim: {
                clock.advance(wall: 301)
            }))
        let confirmation = controller.beginConfirmation(for: batch)

        do {
            _ = try await controller.execute(confirmation: confirmation)
            XCTFail("post-claim expiry must fail closed")
        } catch {
            XCTAssertEqual(error as? UninstallPlanError, .batchExpired)
        }
        XCTAssertEqual(counter.count, 0)

        clock.set(wall: issuedAt)
        do {
            _ = try await controller.execute(confirmation: confirmation)
            XCTFail("a claimed batch must never reopen")
        } catch {
            XCTAssertEqual(error as? UninstallPlanError, .batchAlreadyConsumed)
        }
        XCTAssertEqual(counter.count, 0)
    }

    func testExpiryImmediatelyAfterAuthorizationInvokesNoBody() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let issuedAt = Date(timeIntervalSince1970: 100)
        let clock = ScriptedUninstallClock(wall: issuedAt, monotonic: 1_000)
        let service = fixture.service(clock: clock)
        let batch = try service.uninstallTargets(for: fixture.app, mode: .uninstallApp)
        let counter = InvocationCounter()
        let controller = UninstallCapabilityController(
            service: service,
            payloadExecutor: RecordingPayloadExecutor(counter: counter),
            issuer: DestructiveOperationIssuer(
                sampler: LocalFileIdentitySampler(), ledger: AuthorizationLedger(),
                wallNow: { clock.wallNow() }),
            clock: clock,
            hooks: UninstallCapabilityHooks(afterAuthorization: {
                clock.advance(wall: 301)
            }))
        let confirmation = controller.beginConfirmation(for: batch)

        do {
            _ = try await controller.execute(confirmation: confirmation)
            XCTFail("post-authorization expiry must fail closed")
        } catch {
            XCTAssertEqual(error as? UninstallPlanError, .batchExpired)
        }
        XCTAssertEqual(counter.count, 0)
    }

    func testWallExpiryDuringAwaitedFinalMonotonicCheckInvokesNoOperation() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let issuedAt = Date(timeIntervalSince1970: 100)
        let clock = ExpiringDuringFinalMonotonicClock(wall: issuedAt, monotonic: 1_000)
        let service = fixture.service(clock: clock)
        let batch = try service.uninstallTargets(for: fixture.app, mode: .uninstallApp)
        let counter = InvocationCounter()
        let controller = UninstallCapabilityController(
            service: service,
            payloadExecutor: RecordingPayloadExecutor(counter: counter),
            issuer: DestructiveOperationIssuer(
                sampler: LocalFileIdentitySampler(), ledger: AuthorizationLedger(),
                wallNow: { clock.wallNow() }),
            clock: clock,
            hooks: UninstallCapabilityHooks(afterAuthorization: { clock.arm() }))
        let confirmation = controller.beginConfirmation(for: batch)

        do {
            let result = try await controller.execute(confirmation: confirmation)
            if case .executed = result {
                XCTFail("wall expiry during the awaited monotonic check must not execute")
            }
        } catch {
            XCTAssertEqual(error as? UninstallPlanError, .batchExpired)
        }
        XCTAssertEqual(counter.count, 0)
    }

    func testExpiryWhileCleaningEngineActorIsQueuedInvokesNoUninstallSideEffect() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let issuedAt = Date(timeIntervalSince1970: 100)
        let clock = ScriptedUninstallClock(wall: issuedAt, monotonic: 1_000)
        let service = fixture.service(clock: clock)
        let batch = try service.uninstallTargets(for: fixture.app, mode: .uninstallApp)

        let fs = BlockingRecordingFileSystem()
        let permit = UninstallExecutionPermitToken()
        let engine = permit.makeCleaningEngine(safety: AllowAllSafety(), fs: fs)
        // Keep the actor blocker outside the app proof's ancestor chain; creating a sibling in
        // `fixture.root` correctly changes that directory's ctime and would invalidate the app.
        let blockerURL = URL(fileURLWithPath:
            "/private/tmp/xico-actor-queue-" + UUID().uuidString)
        try Data("blocker".utf8).write(to: blockerURL)
        defer { try? FileManager.default.removeItem(at: blockerURL) }
        let blocker = Task {
            await engine.execute(CleaningPlan(
                items: [CleanableItem(url: blockerURL, displayName: "blocker",
                                      size: 7, isSelected: true)],
                intent: .trash))
        }
        XCTAssertTrue(fs.waitUntilTrashIsBlocked(), "fixture must occupy the engine actor")

        let reachedActorHop = DispatchSemaphore(value: 0)
        let allowActorHop = DispatchSemaphore(value: 0)
        let payloadExecutor = CleaningEngineUninstallPayloadExecutor(
            engine: engine,
            permit: permit,
            beforeActorHop: {
                reachedActorHop.signal()
                _ = allowActorHop.wait(timeout: .now() + 5)
            })
        let controller = UninstallCapabilityController(
            service: service,
            payloadExecutor: payloadExecutor,
            issuer: DestructiveOperationIssuer(
                sampler: LocalFileIdentitySampler(), ledger: AuthorizationLedger(),
                wallNow: { clock.wallNow() }),
            clock: clock)
        let confirmation = controller.beginConfirmation(for: batch)
        let uninstall = Task {
            try await controller.execute(confirmation: confirmation)
        }

        XCTAssertEqual(reachedActorHop.wait(timeout: .now() + 5), .success,
                       "authorization must reach the actor hop while still fresh")
        clock.advance(wall: UninstallBatch.timeToLive + 1)
        allowActorHop.signal()
        fs.releaseBlockedTrash()
        _ = await blocker.value

        do {
            let result = try await uninstall.value
            if case .executed = result {
                XCTFail("queued actor work must re-admit the exact batch after dequeue")
            }
        } catch {
            XCTAssertEqual(error as? UninstallPlanError, .batchExpired)
        }
        XCTAssertEqual(fs.trashedPaths, [blockerURL.standardizedFileURL.path],
                       "expired queued uninstall must perform zero filesystem side effects")
    }

    func testActorReentrySynchronouslyRechecksLifetimeAfterAsyncAdmission() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let issuedAt = Date(timeIntervalSince1970: 100)
        let clock = ScriptedUninstallClock(wall: issuedAt, monotonic: 1_000)
        let service = fixture.service(clock: clock)
        let batch = try service.uninstallTargets(for: fixture.app, mode: .uninstallApp)

        let fs = BlockingRecordingFileSystem()
        let permit = UninstallExecutionPermitToken()
        let engine = permit.makeCleaningEngine(safety: AllowAllSafety(), fs: fs)
        let admissionGate = AsyncAdmissionGate()
        let payloadExecutor = CleaningEngineUninstallPayloadExecutor(
            engine: engine,
            permit: permit,
            afterActorAdmission: { await admissionGate.suspend() })
        let controller = UninstallCapabilityController(
            service: service,
            payloadExecutor: payloadExecutor,
            issuer: DestructiveOperationIssuer(
                sampler: LocalFileIdentitySampler(), ledger: AuthorizationLedger(),
                wallNow: { clock.wallNow() }),
            clock: clock)
        let confirmation = controller.beginConfirmation(for: batch)
        let uninstall = Task {
            try await controller.execute(confirmation: confirmation)
        }
        defer {
            admissionGate.resume()
            fs.releaseBlockedTrash()
        }

        XCTAssertTrue(admissionGate.waitUntilSuspended(),
                      "actor admission must pass while the exact batch is still fresh")

        let blockerURL = fixture.root.appendingPathComponent("actor-reentry-blocker")
        try Data("blocker".utf8).write(to: blockerURL)
        let blocker = Task {
            await engine.execute(CleaningPlan(
                items: [CleanableItem(url: blockerURL, displayName: "blocker",
                                      size: 7, isSelected: true)],
                intent: .trash))
        }
        XCTAssertTrue(fs.waitUntilTrashIsBlocked(),
                      "a second task must hold the engine actor before admission resumes")

        admissionGate.resume()
        clock.advance(
            wall: UninstallBatch.timeToLive + 1,
            monotonicNanoseconds: UninstallBatch.timeToLiveNanoseconds + 1)
        fs.releaseBlockedTrash()
        _ = await blocker.value

        do {
            let result = try await uninstall.value
            if case .executed(let terminal) = result {
                XCTAssertFalse(terminal.fullSuccess)
                XCTAssertEqual(terminal.report.operation.status, .failure)
                XCTAssertTrue(terminal.restorable.isEmpty)
                XCTAssertTrue(terminal.report.items.allSatisfy {
                    $0.mutation == .none
                        && $0.disposition != .succeeded
                })
            }
        } catch {
            XCTAssertEqual(error as? UninstallPlanError, .batchExpired)
        }
        XCTAssertEqual(fs.trashedPaths, [blockerURL.standardizedFileURL.path],
                       "the final synchronous lifetime read must precede every uninstall effect")
    }

    func testDedicatedControllerExecutesAssociatedBeforeBodyAndReturnsTrustedTerminal()
        async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let cache = try fixture.createLibraryItem("Caches/\(fixture.app.bundleID)")
        let fs = NonMutatingTrashFileSystem()
        let service = UninstallerService(
            fs: fs, safety: AllowAllSafety(), home: fixture.home,
            entitlementReader: FakeEntitlementReader(groups: []),
            launchAgentReader: FakeLaunchAgentReader(records: [:]),
            issuanceID: fixture.issuanceID)
        let batch = try service.uninstallTargets(for: fixture.app, mode: .uninstallApp)
        let permit = UninstallExecutionPermitToken()
        let engine = permit.makeCleaningEngine(safety: AllowAllSafety(), fs: fs)
        let controller = UninstallCapabilityController(
            service: service,
            payloadExecutor: CleaningEngineUninstallPayloadExecutor(
                engine: engine, permit: permit),
            issuer: DestructiveOperationIssuer(
                sampler: LocalFileIdentitySampler(), ledger: AuthorizationLedger()))

        let result = try await controller.execute(
            confirmation: controller.beginConfirmation(for: batch))
        let terminal: UninstallExecution
        switch result {
        case .executed(let value): terminal = value
        case .failedClosed(let failure):
            return XCTFail("unexpected fail-closed terminal: \(failure)")
        }

        XCTAssertTrue(terminal.fullSuccess)
        XCTAssertEqual(terminal.report.operation.kind, .uninstall)
        XCTAssertTrue(terminal.report.isReducerBacked)
        XCTAssertEqual(fs.trashedPaths,
                       [cache.standardizedFileURL.path,
                        fixture.appURL.standardizedFileURL.path])
        XCTAssertTrue(FileManager.default.fileExists(atPath: cache.path),
                      "the execution fake must not touch Finder Trash")
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.appURL.path))
    }

    func testExecutionAcceptsOwnSiblingParentMetadataDriftForSamePhysicalChain()
        async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let groups = ["group.com.example.alpha", "group.com.example.beta"]
        let groupURLs = try groups.map {
            try fixture.createLibraryItem("Group Containers/\($0)")
        }
        let pathAttestor = ParentMetadataDriftPathAttestor(home: fixture.home)
        let fs = NonMutatingTrashFileSystem(onTrash: pathAttestor.beginDrift)
        let service = UninstallerService(
            fs: fs, safety: AllowAllSafety(), home: fixture.home,
            entitlementReader: FakeEntitlementReader(groups: groups),
            launchAgentReader: FakeLaunchAgentReader(records: [:]),
            pathAttestor: pathAttestor,
            issuanceID: fixture.issuanceID)
        var batch = try service.uninstallTargets(for: fixture.app, mode: .uninstallApp)
        for candidate in batch.candidates
        where candidate.evidence == .signedApplicationGroup {
            batch.toggle(candidate.id)
        }
        XCTAssertEqual(batch.candidates.filter {
            $0.isSelected && $0.evidence == .signedApplicationGroup
        }.count, 2)
        let permit = UninstallExecutionPermitToken()
        let engine = permit.makeCleaningEngine(safety: AllowAllSafety(), fs: fs)
        let controller = UninstallCapabilityController(
            service: service,
            payloadExecutor: CleaningEngineUninstallPayloadExecutor(
                engine: engine, permit: permit),
            issuer: DestructiveOperationIssuer(
                sampler: LocalFileIdentitySampler(), ledger: AuthorizationLedger()))

        let execution = try await controller.execute(
            confirmation: controller.beginConfirmation(for: batch))
        let terminal: UninstallExecution
        switch execution {
        case .executed(let value): terminal = value
        case .failedClosed(let failure):
            return XCTFail("unexpected fail-closed terminal: \(failure)")
        }

        XCTAssertTrue(terminal.fullSuccess)
        XCTAssertEqual(fs.trashedPaths,
                       groupURLs.map { $0.standardizedFileURL.path }.sorted()
                        + [fixture.appURL.standardizedFileURL.path])
        XCTAssertTrue(groupURLs.allSatisfy {
            FileManager.default.fileExists(atPath: $0.path)
        }, "the metadata-drift fake must never touch Finder Trash")
    }

    func testControllerIdentityDriftRetainsCandidateAndNeverTrashesReplacement()
        async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let cache = try fixture.createLibraryItem("Caches/\(fixture.app.bundleID)")
        let expected = try XCTUnwrap(LocalFileIdentitySampler().sample(cache.path))
        let replacement = LocalFileIdentity(
            device: expected.device,
            inode: expected.inode &+ 1,
            mode: expected.mode,
            size: expected.size,
            mtimeNanoseconds: expected.mtimeNanoseconds,
            changeTimeNanoseconds: expected.changeTimeNanoseconds,
            hardLinkCount: expected.hardLinkCount)
        let fs = NonMutatingTrashFileSystem()
        let service = UninstallerService(
            fs: fs, safety: AllowAllSafety(), home: fixture.home,
            entitlementReader: FakeEntitlementReader(groups: []),
            launchAgentReader: FakeLaunchAgentReader(records: [:]),
            issuanceID: fixture.issuanceID)
        let batch = try service.uninstallTargets(for: fixture.app, mode: .uninstallApp)
        let permit = UninstallExecutionPermitToken()
        let engine = permit.makeCleaningEngine(safety: AllowAllSafety(), fs: fs)
        let executor = CleaningEngineUninstallPayloadExecutor(
            engine: engine,
            permit: permit,
            identitySampler: OverridingIdentitySampler(
                path: cache.standardizedFileURL.path,
                replacement: replacement))
        let controller = UninstallCapabilityController(
            service: service,
            payloadExecutor: executor,
            issuer: DestructiveOperationIssuer(
                sampler: LocalFileIdentitySampler(), ledger: AuthorizationLedger()))

        let result = try await controller.execute(
            confirmation: controller.beginConfirmation(for: batch))
        let terminal: UninstallExecution
        switch result {
        case .executed(let value): terminal = value
        case .failedClosed(let failure):
            return XCTFail("unexpected fail-closed terminal: \(failure)")
        }

        XCTAssertFalse(terminal.fullSuccess)
        XCTAssertEqual(terminal.completion, .appMovedButSomeDataRetained)
        XCTAssertEqual(terminal.retryDirective, .cleanLeftovers)
        XCTAssertEqual(fs.trashedPaths, [fixture.appURL.standardizedFileURL.path])
        XCTAssertTrue(terminal.remainingBatch?.candidates.contains {
            $0.url.standardizedFileURL.path == cache.standardizedFileURL.path
        } == true)
        let cacheFact = try XCTUnwrap(terminal.report.items.first {
            $0.url.standardizedFileURL.path == cache.standardizedFileURL.path
        })
        XCTAssertEqual(cacheFact.mutation, .none)
        if case .failed(let issue) = cacheFact.disposition {
            XCTAssertEqual(issue.code, "uninstall.identity.changed")
        } else {
            XCTFail("identity drift must be an explicit failed fact")
        }
    }

    func testTerminalRejectsWrongKindCountOrderDuplicateSubstitutionAndMalformedReceipt()
        throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        _ = try fixture.createLibraryItem("Caches/\(fixture.app.bundleID)")
        let service = fixture.service()
        let batch = try service.uninstallTargets(for: fixture.app, mode: .uninstallApp)
        let prepared = try service.prepareUninstallExecution(
            from: batch,
            using: DestructiveOperationIssuer(
                sampler: LocalFileIdentitySampler(), ledger: AuthorizationLedger()))
        let occurrences = prepared.orderedTargets.map {
            UninstallPayloadOccurrenceBinding(requestID: UUID(), target: $0)
        }

        func result(
            for occurrence: UninstallPayloadOccurrenceBinding,
            itemID: UUID? = nil,
            url: URL? = nil,
            trashedURL: URL? = nil
        ) -> CleaningItemResult {
            let target = occurrence.target
            return CleaningItemResult(
                requestID: occurrence.requestID,
                itemID: itemID ?? target.candidate.item.id,
                url: url ?? target.candidate.url,
                intent: .trash,
                disposition: .succeeded,
                mutation: .changed,
                reclaimedBytes: target.candidate.item.estimatedReclaimableBytes,
                restorable: RestorableItem(
                    originalURL: target.candidate.url,
                    trashedURL: trashedURL
                        ?? URL(fileURLWithPath: "/private/tmp/xico-terminal-trash")
                            .appendingPathComponent(occurrence.requestID.uuidString)))
        }

        func payload(
            kind: OperationKind = .uninstall,
            occurrences payloadOccurrences: [UninstallPayloadOccurrenceBinding] = occurrences,
            results: [CleaningItemResult]
        ) throws -> UninstallPayloadExecution {
            let now = Date()
            let outcome = try OperationOutcomeReducer.reduce(
                kind: kind,
                requestedSubjectIDs: results.map { $0.requestID.uuidString },
                itemOutcomes: results.map {
                    OperationItemOutcome(
                        subjectID: $0.requestID.uuidString,
                        disposition: $0.disposition,
                        mutation: $0.mutation,
                        affectedBytes: $0.reclaimedBytes)
                },
                cancellationAccepted: false,
                startedAt: now,
                finishedAt: now)
            return UninstallPayloadExecution(
                report: CleaningReport(operation: outcome, items: results),
                occurrences: payloadOccurrences)
        }

        let validResults = occurrences.map { result(for: $0) }
        let validTerminal = try XCTUnwrap(UninstallExecution(
            payload: try payload(results: validResults), prepared: prepared))
        XCTAssertEqual(validTerminal.occurrenceFacts.count, occurrences.count)
        for (fact, occurrence) in zip(validTerminal.occurrenceFacts, occurrences) {
            XCTAssertEqual(fact.operationID, validTerminal.report.operation.id)
            XCTAssertEqual(fact.requestID, occurrence.requestID)
            XCTAssertEqual(fact.candidateID, occurrence.target.candidate.id)
            XCTAssertEqual(fact.subject.appID, prepared.batchSnapshot.app.id)
            XCTAssertEqual(fact.subject.canonicalPath, occurrence.target.canonicalPath)
            XCTAssertEqual(fact.subject.role, occurrence.target.candidate.role)
            XCTAssertEqual(fact.subject.evidence, occurrence.target.candidate.evidence)
            XCTAssertEqual(fact.disposition, .succeeded)
            XCTAssertEqual(fact.mutation, .changed)
        }

        var duplicateOccurrences = occurrences
        duplicateOccurrences[1] = UninstallPayloadOccurrenceBinding(
            requestID: duplicateOccurrences[0].requestID,
            target: duplicateOccurrences[1].target)
        var substitutedItem = validResults
        substitutedItem[0] = result(for: occurrences[0], itemID: UUID())
        var substitutedURL = validResults
        substitutedURL[0] = result(
            for: occurrences[0],
            url: occurrences[0].target.candidate.url.appendingPathExtension("replacement"))
        var malformedReceipt = validResults
        malformedReceipt[0] = result(
            for: occurrences[0],
            trashedURL: occurrences[0].target.candidate.url)

        let invalidPayloads = [
            try payload(kind: .cleaningExecute, results: validResults),
            try payload(results: Array(validResults.dropLast())),
            try payload(results: Array(validResults.reversed())),
            try payload(occurrences: duplicateOccurrences, results: validResults),
            try payload(results: substitutedItem),
            try payload(results: substitutedURL),
            try payload(results: malformedReceipt)
        ]
        for invalid in invalidPayloads {
            XCTAssertNil(UninstallExecution(payload: invalid, prepared: prepared))
        }

        var factMismatch = validResults
        factMismatch[0] = CleaningItemResult(
            requestID: factMismatch[0].requestID,
            itemID: factMismatch[0].itemID,
            url: factMismatch[0].url,
            intent: .trash,
            disposition: .failed(OperationIssue(
                code: "uninstall.test.malformed",
                category: .internalInvariant,
                subjectID: factMismatch[0].requestID.uuidString,
                recovery: .none,
                retryable: false)),
            mutation: .none,
            reclaimedBytes: 0,
            restorable: nil)
        let validPayload = try payload(results: validResults)
        let nonReducer = UninstallPayloadExecution(
            report: CleaningReport(operation: validPayload.report.operation,
                                   items: factMismatch),
            occurrences: occurrences)
        XCTAssertFalse(nonReducer.report.isReducerBacked)
        XCTAssertNil(UninstallExecution(payload: nonReducer, prepared: prepared))
    }

    func testTrustedTerminalRejectsIssuesBoundToAnotherOrUnknownOccurrence()
        throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        _ = try fixture.createLibraryItem("Caches/\(fixture.app.bundleID)")
        let service = fixture.service()
        let batch = try service.uninstallTargets(for: fixture.app, mode: .uninstallApp)
        let prepared = try service.prepareUninstallExecution(
            from: batch,
            using: DestructiveOperationIssuer(
                sampler: LocalFileIdentitySampler(), ledger: AuthorizationLedger()))
        let occurrences = prepared.orderedTargets.map {
            UninstallPayloadOccurrenceBinding(requestID: UUID(), target: $0)
        }
        guard occurrences.count >= 2 else {
            XCTFail("fixture must provide another exact occurrence for cross-binding")
            return
        }

        func issue(subjectID: String) -> OperationIssue {
            OperationIssue(
                code: "uninstall.test.issueBinding",
                category: .identityChanged,
                subjectID: subjectID,
                recovery: .retry,
                retryable: true)
        }

        func result(
            for occurrence: UninstallPayloadOccurrenceBinding,
            disposition: OperationDisposition
        ) -> CleaningItemResult {
            CleaningItemResult(
                requestID: occurrence.requestID,
                itemID: occurrence.target.candidate.id,
                url: occurrence.target.candidate.url,
                intent: .trash,
                disposition: disposition,
                mutation: .none,
                reclaimedBytes: 0,
                restorable: nil)
        }

        func payload(firstDisposition: OperationDisposition) throws
            -> UninstallPayloadExecution {
            var results = occurrences.map { occurrence in
                result(
                    for: occurrence,
                    disposition: .failed(issue(
                        subjectID: occurrence.requestID.uuidString)))
            }
            results[0] = result(for: occurrences[0], disposition: firstDisposition)
            let cancellationAccepted = results.contains {
                if case .cancelled = $0.disposition { return true }
                return false
            }
            let now = Date()
            let outcome = try OperationOutcomeReducer.reduce(
                kind: .uninstall,
                requestedSubjectIDs: occurrences.map { $0.requestID.uuidString },
                itemOutcomes: results.map {
                    OperationItemOutcome(
                        subjectID: $0.requestID.uuidString,
                        disposition: $0.disposition,
                        mutation: $0.mutation)
                },
                cancellationAccepted: cancellationAccepted,
                startedAt: now,
                finishedAt: now)
            return UninstallPayloadExecution(
                report: CleaningReport(operation: outcome, items: results),
                occurrences: occurrences)
        }

        let nilIssueCancellation = try payload(firstDisposition: .cancelled(nil))
        XCTAssertTrue(nilIssueCancellation.report.isReducerBacked)
        XCTAssertNotNil(UninstallExecution(
            payload: nilIssueCancellation, prepared: prepared),
            "a cancellation without an issue keeps its existing valid semantics")

        let malformedSubjects = [
            ("another occurrence", occurrences[1].requestID.uuidString),
            ("unknown occurrence", UUID().uuidString)
        ]
        let dispositions: [(String, (OperationIssue) -> OperationDisposition)] = [
            ("failed", { .failed($0) }),
            ("skipped", { .skipped($0) }),
            ("cancelled", { .cancelled($0) })
        ]
        for (dispositionName, makeDisposition) in dispositions {
            for (subjectName, subjectID) in malformedSubjects {
                let malformed = try payload(
                    firstDisposition: makeDisposition(issue(subjectID: subjectID)))
                XCTAssertTrue(
                    malformed.report.isReducerBacked,
                    "\(dispositionName)/\(subjectName) must reach terminal binding validation")
                XCTAssertNil(
                    UninstallExecution(payload: malformed, prepared: prepared),
                    "\(dispositionName) issue bound to \(subjectName) must fail closed")
            }
        }
    }

    func testMalformedFallbackDropsEveryReceiptSharingTrashEndpointButKeepsIndependentReceipts()
        throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        _ = try fixture.createLibraryItem("Application Support/\(fixture.app.bundleID)")
        _ = try fixture.createLibraryItem("Caches/\(fixture.app.bundleID)")
        let service = fixture.service()
        let batch = try service.uninstallTargets(for: fixture.app, mode: .uninstallApp)
        let prepared = try service.prepareUninstallExecution(
            from: batch,
            using: DestructiveOperationIssuer(
                sampler: LocalFileIdentitySampler(), ledger: AuthorizationLedger()))
        guard prepared.orderedTargets.count >= 3 else {
            XCTFail("fixture must provide two conflicting targets and one independent target")
            return
        }
        let sharedTrash = URL(
            fileURLWithPath: "/private/tmp/xico-malformed-shared-trash")
        let generated = try makeSuccessfulUninstallPayload(prepared: prepared) {
            index, occurrence in
            index < 2
                ? sharedTrash
                : URL(fileURLWithPath: "/private/tmp/xico-malformed-independent-trash")
                    .appendingPathComponent(occurrence.requestID.uuidString)
        }

        XCTAssertNil(UninstallExecution(payload: generated.payload, prepared: prepared),
                     "a trusted terminal must reject duplicate receipt endpoints")
        let fallback = UninstallExecution(
            malformedPayload: generated.payload, prepared: prepared)
        let conflictingOriginals = Set(generated.receipts.prefix(2).map {
            $0.originalURL.standardizedFileURL.path
        })

        XCTAssertTrue(fallback.restorable.allSatisfy {
            !conflictingOriginals.contains($0.originalURL.standardizedFileURL.path)
        }, "every receipt in an ambiguous shared-trash collision must be discarded")
        XCTAssertEqual(fallback.restorable, Array(generated.receipts.dropFirst(2)),
                       "independent exact receipts must remain available for undo")
    }

    func testMalformedFallbackDropsEveryReceiptInOriginalTrashCrossCollisionButKeepsIndependentReceipts()
        throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        _ = try fixture.createLibraryItem("Application Support/\(fixture.app.bundleID)")
        _ = try fixture.createLibraryItem("Caches/\(fixture.app.bundleID)")
        let service = fixture.service()
        let batch = try service.uninstallTargets(for: fixture.app, mode: .uninstallApp)
        let prepared = try service.prepareUninstallExecution(
            from: batch,
            using: DestructiveOperationIssuer(
                sampler: LocalFileIdentitySampler(), ledger: AuthorizationLedger()))
        guard prepared.orderedTargets.count >= 3 else {
            XCTFail("fixture must provide two conflicting targets and one independent target")
            return
        }
        let secondOriginal = prepared.orderedTargets[1].candidate.url
        let generated = try makeSuccessfulUninstallPayload(prepared: prepared) {
            index, occurrence in
            index == 0
                ? secondOriginal
                : URL(fileURLWithPath: "/private/tmp/xico-malformed-independent-trash")
                    .appendingPathComponent(occurrence.requestID.uuidString)
        }

        XCTAssertNil(UninstallExecution(payload: generated.payload, prepared: prepared),
                     "a trusted terminal must reject original-to-trash endpoint aliasing")
        let fallback = UninstallExecution(
            malformedPayload: generated.payload, prepared: prepared)
        let conflictingOriginals = Set(generated.receipts.prefix(2).map {
            $0.originalURL.standardizedFileURL.path
        })

        XCTAssertTrue(fallback.restorable.allSatisfy {
            !conflictingOriginals.contains($0.originalURL.standardizedFileURL.path)
        }, "both sides of an original-to-trash collision must be discarded")
        XCTAssertEqual(fallback.restorable, Array(generated.receipts.dropFirst(2)),
                       "independent exact receipts must remain available for undo")
    }

    private func makeSuccessfulUninstallPayload(
        prepared: PreparedUninstallExecution,
        trashedURL: (Int, UninstallPayloadOccurrenceBinding) -> URL
    ) throws -> (payload: UninstallPayloadExecution, receipts: [RestorableItem]) {
        let occurrences = prepared.orderedTargets.map {
            UninstallPayloadOccurrenceBinding(requestID: UUID(), target: $0)
        }
        let receipts = occurrences.enumerated().map { index, occurrence in
            RestorableItem(
                originalURL: occurrence.target.candidate.url,
                trashedURL: trashedURL(index, occurrence))
        }
        let results = zip(occurrences, receipts).map { occurrence, receipt in
            CleaningItemResult(
                requestID: occurrence.requestID,
                itemID: occurrence.target.candidate.id,
                url: occurrence.target.candidate.url,
                intent: .trash,
                disposition: .succeeded,
                mutation: .changed,
                reclaimedBytes:
                    occurrence.target.candidate.item.estimatedReclaimableBytes,
                restorable: receipt)
        }
        let now = Date()
        let outcome = try OperationOutcomeReducer.reduce(
            kind: .uninstall,
            requestedSubjectIDs: occurrences.map { $0.requestID.uuidString },
            itemOutcomes: results.map {
                OperationItemOutcome(
                    subjectID: $0.requestID.uuidString,
                    disposition: $0.disposition,
                    mutation: $0.mutation,
                    affectedBytes: $0.reclaimedBytes)
            },
            cancellationAccepted: false,
            startedAt: now,
            finishedAt: now)
        return (
            UninstallPayloadExecution(
                report: CleaningReport(operation: outcome, items: results),
                occurrences: occurrences),
            receipts)
    }

    func testControllerRetainsExactReceiptsAndReturnsUncertainTerminalForMalformedPayload()
        async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        _ = try fixture.createLibraryItem("Caches/\(fixture.app.bundleID)")
        let service = fixture.service()
        let batch = try service.uninstallTargets(for: fixture.app, mode: .uninstallApp)
        let controller = UninstallCapabilityController(
            service: service,
            payloadExecutor: MalformedPostMutationPayloadExecutor(),
            issuer: DestructiveOperationIssuer(
                sampler: LocalFileIdentitySampler(), ledger: AuthorizationLedger()))
        let confirmation = controller.beginConfirmation(for: batch)

        let result = try await controller.execute(confirmation: confirmation)
        let terminal: UninstallExecution
        switch result {
        case .executed(let value): terminal = value
        case .failedClosed(let failure):
            return XCTFail("unexpected capability failure: \(failure)")
        }

        XCTAssertEqual(terminal.completion, .uncertain)
        XCTAssertFalse(terminal.fullSuccess)
        XCTAssertTrue(terminal.requiresFreshScanForRetry)
        XCTAssertEqual(terminal.retryDirective, .determineFromFreshScan)
        XCTAssertTrue(terminal.report.isReducerBacked)
        XCTAssertEqual(terminal.report.operation.kind, .uninstall)
        XCTAssertEqual(terminal.report.operation.status, .failure)
        XCTAssertTrue(terminal.occurrenceFacts.allSatisfy {
            $0.mutation == .possiblyChanged && $0.disposition != .succeeded
        })
        XCTAssertEqual(terminal.restorable.count, batch.selectedCount - 1,
                       "strictly correlated receipts must survive malformed aggregation")
        XCTAssertEqual(terminal.remainingBatch?.selectedCount, batch.selectedCount)

        do {
            _ = try await controller.execute(confirmation: confirmation)
            XCTFail("the consumed malformed operation must never replay")
        } catch {
            XCTAssertEqual(error as? UninstallPlanError, .batchAlreadyConsumed)
        }
    }

    func testCapabilityControllerConsumesBatchExactlyOnceConcurrently() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let service = fixture.service()
        let batch = try service.uninstallTargets(for: fixture.app, mode: .uninstallApp)
        let counter = InvocationCounter()
        let controller = UninstallCapabilityController(
            service: service,
            payloadExecutor: RecordingPayloadExecutor(counter: counter),
            issuer: DestructiveOperationIssuer(sampler: LocalFileIdentitySampler(),
                                                ledger: AuthorizationLedger()))
        let confirmation = controller.beginConfirmation(for: batch)

        let executed = await withTaskGroup(of: Bool.self, returning: Int.self) { group in
            for _ in 0..<12 {
                group.addTask {
                    do {
                        let result = try await controller.execute(
                            confirmation: confirmation)
                        if case .executed = result { return true }
                    } catch {}
                    return false
                }
            }
            var count = 0
            for await value in group where value { count += 1 }
            return count
        }

        XCTAssertEqual(executed, 1)
        XCTAssertEqual(counter.count, 1)
    }

    func testCapabilityControllerRejectsExpiredBatchBeforeOperation() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let createdAt = Date(timeIntervalSince1970: 100)
        let clock = ScriptedUninstallClock(wall: createdAt, monotonic: 100)
        let service = fixture.service(clock: clock)
        let batch = try service.uninstallTargets(for: fixture.app, mode: .uninstallApp)
        clock.advance(wall: 301, monotonicNanoseconds: 301_000_000_000)
        let counter = InvocationCounter()
        let controller = UninstallCapabilityController(
            service: service,
            payloadExecutor: RecordingPayloadExecutor(counter: counter),
            issuer: DestructiveOperationIssuer(sampler: LocalFileIdentitySampler(),
                                                ledger: AuthorizationLedger(),
                                                wallNow: { clock.wallNow() }),
            clock: clock)
        let confirmation = controller.beginConfirmation(for: batch)

        do {
            _ = try await controller.execute(confirmation: confirmation)
            XCTFail("expired batch must fail closed")
        } catch {
            XCTAssertEqual(error as? UninstallPlanError, .batchExpired)
        }
        XCTAssertEqual(counter.count, 0)
    }

    func testUninstallTargetsRejectsAppIssuedByAnotherService() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let issuingService = fixture.service()
        let otherService = UninstallerService(
            fs: LocalFileSystemService(), safety: AllowAllSafety(), home: fixture.home,
            entitlementReader: FakeEntitlementReader(groups: []),
            launchAgentReader: FakeLaunchAgentReader(records: [:]))
        let issuedApp = try XCTUnwrap(issuingService.listApps().first {
            $0.url.standardizedFileURL.path == fixture.appURL.standardizedFileURL.path
        })

        XCTAssertThrowsError(
            try otherService.uninstallTargets(for: issuedApp, mode: .uninstallApp)
        ) { error in
            XCTAssertEqual(error as? UninstallerAttributionError, .foreignApp)
        }
    }

    func testPrepareUninstallPlanRejectsSamePathAppBodyReplacement() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let service = fixture.service()
        let batch = try service.uninstallTargets(for: fixture.app, mode: .uninstallApp)
        try FileManager.default.removeItem(at: fixture.appURL)
        try FileManager.default.createDirectory(at: fixture.appURL.appendingPathComponent("Contents"),
                                                withIntermediateDirectories: true)
        let replacementInfo = try PropertyListSerialization.data(
            fromPropertyList: ["CFBundleIdentifier": fixture.app.bundleID,
                               "CFBundleName": fixture.app.name],
            format: .xml, options: 0)
        try replacementInfo.write(to: fixture.appURL.appendingPathComponent("Contents/Info.plist"))
        let issuer = DestructiveOperationIssuer(sampler: LocalFileIdentitySampler(),
                                                ledger: AuthorizationLedger())

        XCTAssertThrowsError(try service.prepareUninstallExecution(from: batch, using: issuer)) {
            XCTAssertEqual($0 as? UninstallPlanError, .appIdentityChanged)
        }
    }

    func testPrepareUninstallPlanRechecksRequiredBodySafety() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let safety = MutableSafety()
        let service = fixture.service(safety: safety)
        let batch = try service.uninstallTargets(for: fixture.app, mode: .uninstallApp)
        safety.deny()
        let issuer = DestructiveOperationIssuer(sampler: LocalFileIdentitySampler(),
                                                ledger: AuthorizationLedger())

        XCTAssertThrowsError(try service.prepareUninstallExecution(from: batch, using: issuer)) {
            XCTAssertEqual($0 as? UninstallPlanError, .requiredAppBodyMissing)
        }
    }

    func testPrepareUninstallPlanRejectsSameContentInfoPlistReplacement() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let service = fixture.service()
        let batch = try service.uninstallTargets(for: fixture.app, mode: .uninstallApp)
        let infoURL = fixture.appURL.appendingPathComponent("Contents/Info.plist")
        let originalData = try Data(contentsOf: infoURL)
        try FileManager.default.removeItem(at: infoURL)
        try originalData.write(to: infoURL)
        let issuer = DestructiveOperationIssuer(sampler: LocalFileIdentitySampler(),
                                                ledger: AuthorizationLedger())

        XCTAssertThrowsError(try service.prepareUninstallExecution(from: batch, using: issuer)) {
            XCTAssertEqual($0 as? UninstallPlanError, .appMetadataChanged)
        }
    }

    func testInstalledAppSealsInfoPlistExactLengthDigestAndChangeTime() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let infoURL = fixture.appURL.appendingPathComponent("Contents/Info.plist")
        let data = try Data(contentsOf: infoURL)

        XCTAssertEqual(fixture.app.metadataExactLength, data.count)
        XCTAssertEqual(fixture.app.metadataContentDigest.bytes,
                       Array(SHA256.hash(data: data)))
        XCTAssertNotEqual(fixture.app.metadataIdentity.changeTimeNanoseconds, 0)
    }

    func testPrepareRejectsSameInodeEqualLengthInfoRewriteWithRestoredMTime() throws {
        #if canImport(Darwin)
        let fixture = try Fixture()
        defer { fixture.remove() }
        let service = fixture.service()
        let batch = try service.uninstallTargets(for: fixture.app, mode: .uninstallApp)
        let infoURL = fixture.appURL.appendingPathComponent("Contents/Info.plist")
        var before = stat()
        XCTAssertEqual(lstat(infoURL.path, &before), 0)
        var bytes = try Data(contentsOf: infoURL)
        let whitespace = try XCTUnwrap(bytes.firstIndex(of: 0x09))
        bytes[whitespace] = 0x20
        let descriptor = open(infoURL.path, O_WRONLY | O_TRUNC | O_CLOEXEC)
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        _ = bytes.withUnsafeBytes { write(descriptor, $0.baseAddress, $0.count) }
        close(descriptor)
        var times = [before.st_atimespec, before.st_mtimespec]
        _ = times.withUnsafeMutableBufferPointer {
            utimensat(AT_FDCWD, infoURL.path, $0.baseAddress, 0)
        }
        let issuer = DestructiveOperationIssuer(sampler: LocalFileIdentitySampler(),
                                                ledger: AuthorizationLedger())

        XCTAssertThrowsError(try service.prepareUninstallExecution(from: batch, using: issuer)) {
            XCTAssertEqual($0 as? UninstallPlanError, .appMetadataChanged)
        }
        #endif
    }

    func testPrepareUninstallPlanRejectsBatchIssuedByAnotherService() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let issuingService = UninstallerService(
            fs: LocalFileSystemService(), safety: AllowAllSafety(), home: fixture.home,
            entitlementReader: FakeEntitlementReader(groups: []),
            launchAgentReader: FakeLaunchAgentReader(records: [:]))
        let otherService = UninstallerService(
            fs: LocalFileSystemService(), safety: AllowAllSafety(), home: fixture.home,
            entitlementReader: FakeEntitlementReader(groups: []),
            launchAgentReader: FakeLaunchAgentReader(records: [:]))
        let issuedApp = try XCTUnwrap(issuingService.listApps().first {
            $0.url.standardizedFileURL.path == fixture.appURL.standardizedFileURL.path
        })
        let batch = try issuingService.uninstallTargets(for: issuedApp, mode: .uninstallApp)
        let issuer = DestructiveOperationIssuer(sampler: NilIdentitySampler(),
                                                ledger: AuthorizationLedger())

        XCTAssertThrowsError(try otherService.prepareUninstallExecution(from: batch, using: issuer)) {
            XCTAssertEqual($0 as? UninstallPlanError, .foreignBatch)
        }
    }

    func testPrepareUninstallPlanRejectsForgedBatchWithoutRequiredBody() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let service = fixture.service()
        let batch = try service.uninstallTargets(for: fixture.app, mode: .uninstallApp)
        let forged = UninstallBatch(issuanceID: batch.issuanceID,
                                    batchID: batch.batchID,
                                    app: batch.app,
                                    mode: batch.mode,
                                    candidates: batch.candidates.filter { $0.role != .appBody })
        let issuer = DestructiveOperationIssuer(sampler: NilIdentitySampler(),
                                                ledger: AuthorizationLedger())

        XCTAssertThrowsError(try service.prepareUninstallExecution(from: forged, using: issuer)) {
            XCTAssertEqual($0 as? UninstallPlanError, .requiredAppBodyMissing)
        }
    }

    func testPrepareUninstallPlanRejectsMixedBatchCandidateBindings() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        _ = try fixture.createLibraryItem("Caches/\(fixture.app.bundleID)")
        let service = fixture.service()
        let first = try service.uninstallTargets(for: fixture.app, mode: .uninstallApp)
        let second = try service.uninstallTargets(for: fixture.app, mode: .uninstallApp)
        let foreignCandidate = try XCTUnwrap(second.candidates.first { $0.role != .appBody })
        let forged = UninstallBatch(issuanceID: first.issuanceID,
                                    batchID: first.batchID,
                                    app: first.app,
                                    mode: first.mode,
                                    candidates: first.candidates + [foreignCandidate])
        let issuer = DestructiveOperationIssuer(sampler: NilIdentitySampler(),
                                                ledger: AuthorizationLedger())

        XCTAssertThrowsError(try service.prepareUninstallExecution(from: forged, using: issuer)) {
            XCTAssertEqual($0 as? UninstallPlanError, .foreignCandidate)
        }
    }

    func testPrepareUninstallPlanRejectsSelectedUnverifiedCandidate() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let service = fixture.service()
        let batch = try service.uninstallTargets(for: fixture.app, mode: .uninstallApp)
        let item = CleanableItem(url: fixture.home.appendingPathComponent("Library/Caches/forged"),
                                 displayName: "forged", size: 1)
        let forgedCandidate = UninstallCandidate(item: item,
                                                 evidence: .unverified,
                                                 selectionPolicy: .recommended,
                                                 role: .associatedFile,
                                                 batchID: batch.batchID)
        let forged = UninstallBatch(issuanceID: batch.issuanceID,
                                    batchID: batch.batchID,
                                    app: batch.app,
                                    mode: batch.mode,
                                    candidates: batch.candidates + [forgedCandidate])
        let issuer = DestructiveOperationIssuer(sampler: NilIdentitySampler(),
                                                ledger: AuthorizationLedger())

        XCTAssertThrowsError(try service.prepareUninstallExecution(from: forged, using: issuer)) {
            XCTAssertEqual($0 as? UninstallPlanError, .invalidSelectedCandidate)
        }
    }

    func testGroupContainerMerelyContainingBundleIDSubstringIsNotAttributed() throws { // C2
        let fixture = try Fixture()
        defer { fixture.remove() }
        let misleading = "group.\(fixture.app.bundleID).other-product"
        let url = try fixture.createLibraryItem("Group Containers/\(misleading)")

        let candidates = try fixture.service(entitlements: ["group.com.example.real-shared"])
            .uninstallTargets(for: fixture.app, mode: .uninstallApp).candidates

        XCTAssertFalse(candidates.contains {
            $0.url.path == url.path && ($0.evidence == .signedApplicationGroup || $0.selectionPolicy == .recommended)
        })
    }

    func testCachesAncestorSymlinkEscapeIsNeverAdmitted() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let library = fixture.home.appendingPathComponent("Library")
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        let outsideCategory = library.appendingPathComponent("outside-caches")
        try FileManager.default.createDirectory(
            at: outsideCategory.appendingPathComponent(fixture.app.bundleID),
            withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: library.appendingPathComponent("Caches"), withDestinationURL: outsideCategory)

        let batch = try fixture.service().uninstallTargets(for: fixture.app, mode: .uninstallApp)

        XCTAssertFalse(batch.candidates.contains {
            $0.url.path == library.appendingPathComponent("Caches/\(fixture.app.bundleID)").path
        })
    }

    func testLaunchAgentsAncestorSymlinkEscapeIsNeverAdmitted() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let executable = try fixture.createAppExecutable()
        let library = fixture.home.appendingPathComponent("Library")
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        let outsideCategory = library.appendingPathComponent("outside-agents")
        try FileManager.default.createDirectory(at: outsideCategory, withIntermediateDirectories: true)
        let plist = outsideCategory.appendingPathComponent("\(fixture.app.bundleID).plist")
        let data = try PropertyListSerialization.data(
            fromPropertyList: ["Label": fixture.app.bundleID, "Program": executable.path],
            format: .xml, options: 0)
        try data.write(to: plist)
        try FileManager.default.createSymbolicLink(
            at: library.appendingPathComponent("LaunchAgents"), withDestinationURL: outsideCategory)
        let logicalPlist = library.appendingPathComponent(
            "LaunchAgents/\(fixture.app.bundleID).plist")
        let fs = DirectoryListingFileSystem(
            overriddenDirectoryPath: library.appendingPathComponent("LaunchAgents").path,
            listedURLs: [logicalPlist])
        let reader = CountingLaunchAgentReader(record: LaunchAgentRecord(
            label: fixture.app.bundleID, program: executable.path, programArguments: []))
        let service = UninstallerService(
            fs: fs, safety: AllowAllSafety(), home: fixture.home,
            entitlementReader: FakeEntitlementReader(groups: []),
            launchAgentReader: reader,
            issuanceID: fixture.issuanceID)

        let batch = try service.uninstallTargets(for: fixture.app, mode: .uninstallApp)

        XCTAssertFalse(batch.candidates.contains {
            $0.url.path == library.appendingPathComponent(
                "LaunchAgents/\(fixture.app.bundleID).plist").path
                && $0.selectionPolicy == .recommended
        })
        XCTAssertEqual(reader.calls, 0,
                       "escaped plist must not be read before anchored parent proof")
    }

    func testGroupContainersAncestorSymlinkEscapeIsNeverAdmitted() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let group = "group.com.example.shared"
        let library = fixture.home.appendingPathComponent("Library")
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        let outsideCategory = library.appendingPathComponent("outside-groups")
        try FileManager.default.createDirectory(
            at: outsideCategory.appendingPathComponent(group), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: library.appendingPathComponent("Group Containers"),
            withDestinationURL: outsideCategory)
        let logicalGroup = library.appendingPathComponent("Group Containers/\(group)")
        let fs = DirectoryListingFileSystem(
            overriddenDirectoryPath: library.appendingPathComponent("Group Containers").path,
            listedURLs: [logicalGroup])
        let service = UninstallerService(
            fs: fs, safety: AllowAllSafety(), home: fixture.home,
            entitlementReader: FakeEntitlementReader(groups: [group]),
            launchAgentReader: FakeLaunchAgentReader(records: [:]),
            issuanceID: fixture.issuanceID)
        let batch = try service.uninstallTargets(for: fixture.app, mode: .uninstallApp)

        XCTAssertFalse(batch.candidates.contains {
            $0.url.path == library.appendingPathComponent("Group Containers/\(group)").path
        })
    }

    func testPrepareRejectsLibraryParentReplacementAfterScan() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let cache = try fixture.createLibraryItem("Caches/\(fixture.app.bundleID)")
        let service = fixture.service()
        let batch = try service.uninstallTargets(for: fixture.app, mode: .uninstallApp)
        XCTAssertTrue(batch.candidates.contains { $0.url.path == cache.path })
        let category = cache.deletingLastPathComponent()
        let moved = category.deletingLastPathComponent().appendingPathComponent("Caches-old")
        try FileManager.default.moveItem(at: category, to: moved)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        let issuer = DestructiveOperationIssuer(sampler: LocalFileIdentitySampler(),
                                                ledger: AuthorizationLedger())

        XCTAssertThrowsError(try service.prepareUninstallExecution(from: batch, using: issuer))
    }

    func testLaunchAgentLabelContainingButNotEqualBundleIDIsNotRecommended() throws { // C2
        let fixture = try Fixture()
        defer { fixture.remove() }
        let plist = try fixture.createLibraryItem("LaunchAgents/\(fixture.app.bundleID).helper.plist", directory: false)
        let record = LaunchAgentRecord(label: "\(fixture.app.bundleID).helper",
                                       program: fixture.appURL.appendingPathComponent("Contents/MacOS/helper").path,
                                       programArguments: [])

        let candidates = try fixture.service(launchAgents: [plist.path: record])
            .uninstallTargets(for: fixture.app, mode: .uninstallApp).candidates

        XCTAssertFalse(candidates.contains {
            $0.url.path == plist.path && ($0.evidence == .launchAgentProgramInsideBundle || $0.selectionPolicy == .recommended)
        })
    }

    func testOrphanScannerExcludesGroupContainerContainingBundleIDSubstring() throws { // C2
        let fixture = try Fixture()
        defer { fixture.remove() }
        let misleading = try fixture.createLibraryItem(
            "Group Containers/group.\(fixture.app.bundleID).shared")

        let urls = OrphanScanner.artifactURLs(for: fixture.app.bundleID,
                                              home: fixture.home,
                                              fs: LocalFileSystemService())

        XCTAssertFalse(urls.contains { $0.path == misleading.path })
    }

    func testOrphanScannerExcludesLaunchAgentContainingBundleIDSubstring() throws { // C2
        let fixture = try Fixture()
        defer { fixture.remove() }
        let misleading = try fixture.createLibraryItem(
            "LaunchAgents/\(fixture.app.bundleID).helper.plist", directory: false)

        let urls = OrphanScanner.artifactURLs(for: fixture.app.bundleID,
                                              home: fixture.home,
                                              fs: LocalFileSystemService())

        XCTAssertFalse(urls.contains { $0.path == misleading.path })
    }
}
