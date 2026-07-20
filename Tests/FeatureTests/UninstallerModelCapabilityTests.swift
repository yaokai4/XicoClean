import Foundation
import XCTest
@testable import Domain
@testable import Features
@testable import Infrastructure

@MainActor
final class UninstallerModelCapabilityTests: XCTestCase {
    private enum TerminalFact: Equatable {
        case succeeded
        case failedNone
        case failedPossiblyChanged
        case cancelled
    }
    private struct AllowAllSafety: SafetyEngine {
        func verify(_ url: URL, intent: DeleteIntent) -> SafetyVerdict { .allow }
    }

    private struct EmptyEntitlements: EntitlementReader {
        func attestation(for appURL: URL) -> SignedEntitlementAttestation? { nil }
    }

    private struct EmptyLaunchAgents: LaunchAgentReader {
        func attestation(at url: URL,
                         anchoredRead: AnchoredRegularFileRead) -> LaunchAgentAttestation? { nil }
    }

    private final class RecordingFileSystem: @unchecked Sendable, FileSystemService {
        private let local = LocalFileSystemService()
        private let lock = NSLock()
        private var trashPaths: [String] = []
        private var restoredItems: [RestorableItem] = []
        private var failingRestorePaths: Set<String> = []

        var trashed: [String] { lock.withLock { trashPaths } }
        var restored: [RestorableItem] { lock.withLock { restoredItems } }
        func failRestore(of item: RestorableItem) {
            _ = lock.withLock {
                failingRestorePaths.insert(item.originalURL.standardizedFileURL.path)
            }
        }

        func exists(_ url: URL) -> Bool { local.exists(url) }
        func contentsOfDirectory(_ url: URL) -> [URL] { local.contentsOfDirectory(url) }
        func allocatedSize(of url: URL) -> Int64 { local.allocatedSize(of: url) }
        func entry(for url: URL) -> FileEntry? { local.entry(for: url) }
        func trash(_ url: URL) throws -> URL {
            lock.withLock { trashPaths.append(url.path) }
            return url
        }
        func remove(_ url: URL) throws { lock.withLock { trashPaths.append(url.path) } }
        func restore(_ item: RestorableItem) throws -> URL {
            let fails = lock.withLock { () -> Bool in
                restoredItems.append(item)
                return failingRestorePaths.contains(
                    item.originalURL.standardizedFileURL.path)
            }
            if fails { throw CocoaError(.fileWriteUnknown) }
            return item.originalURL
        }
        func volumeCapacity(for url: URL) -> VolumeCapacity? { nil }
        func deepEnumerate(_ url: URL, includeFiles: Bool) -> AsyncStream<FileEntry> {
            local.deepEnumerate(url, includeFiles: includeFiles)
        }
    }

    private final class RecordingSampler: @unchecked Sendable, IdentitySampler {
        private let lock = NSLock()
        private var sampledPaths: [String] = []
        var paths: [String] { lock.withLock { sampledPaths } }

        func sample(_ canonicalPath: String) -> LocalFileIdentity? {
            lock.withLock { sampledPaths.append(canonicalPath) }
            return LocalFileIdentity(device: 1,
                                     inode: UInt64(bitPattern: Int64(canonicalPath.hashValue)),
                                     mode: 0, size: 0, mtimeNanoseconds: 0,
                                     hardLinkCount: 1)
        }
    }

    private final class ControlledTargetScanner: @unchecked Sendable {
        private struct PendingRequest {
            let app: InstalledApp
            let mode: UninstallMode
            var continuation: CheckedContinuation<UninstallBatch?, Never>?
        }

        private let lock = NSLock()
        private var requests: [PendingRequest] = []
        private var completed = 0

        var requestCount: Int { lock.withLock { requests.count } }
        var completedCount: Int { lock.withLock { completed } }
        var requestedApps: [InstalledApp] { lock.withLock { requests.map(\.app) } }
        var requestedModes: [UninstallMode] { lock.withLock { requests.map(\.mode) } }

        func scan(_ app: InstalledApp, mode: UninstallMode) async -> UninstallBatch? {
            let result = await withCheckedContinuation { continuation in
                lock.withLock {
                    requests.append(PendingRequest(
                        app: app, mode: mode, continuation: continuation))
                }
            }
            lock.withLock { completed += 1 }
            return result
        }

        func resolve(_ index: Int, with batch: UninstallBatch?) {
            let continuation = lock.withLock { () -> CheckedContinuation<UninstallBatch?, Never>? in
                guard requests.indices.contains(index),
                      let continuation = requests[index].continuation else { return nil }
                requests[index].continuation = nil
                return continuation
            }
            continuation?.resume(returning: batch)
        }
    }

    private final class ControllableCapabilityRouter: @unchecked Sendable,
                                                       UninstallCapabilityRouting {
        private let lock = NSLock()
        private let suspended: Bool
        private var capturedBatches: [UninstallBatch] = []
        private var capturedConfirmations: [UninstallConfirmation] = []
        private var issuingService: UninstallerService?
        private var continuations: [CheckedContinuation<
            DestructiveExecutionResult<UninstallExecution>, Never>?] = []

        init(suspended: Bool = false) { self.suspended = suspended }

        func bind(service: UninstallerService) {
            lock.withLock { issuingService = service }
        }

        var calls: Int { lock.withLock { capturedConfirmations.count } }
        var beginCalls: Int { lock.withLock { capturedBatches.count } }
        var batches: [UninstallBatch] { lock.withLock { capturedBatches } }
        var confirmations: [UninstallConfirmation] {
            lock.withLock { capturedConfirmations }
        }

        func beginConfirmation(for batch: UninstallBatch) -> UninstallConfirmation {
            let service = lock.withLock { () -> UninstallerService in
                capturedBatches.append(batch)
                return issuingService!
            }
            return UninstallConfirmation(batch: batch, service: service)
        }

        func execute(confirmation: UninstallConfirmation) async throws
            -> DestructiveExecutionResult<UninstallExecution> {
            if !suspended {
                lock.withLock { capturedConfirmations.append(confirmation) }
                return .failedClosed(.expired)
            }
            return await withCheckedContinuation { continuation in
                lock.withLock {
                    capturedConfirmations.append(confirmation)
                    continuations.append(continuation)
                }
            }
        }

        func resume(_ index: Int,
                    with result: DestructiveExecutionResult<UninstallExecution>) {
            let continuation = lock.withLock { () -> CheckedContinuation<
                DestructiveExecutionResult<UninstallExecution>, Never>? in
                guard continuations.indices.contains(index),
                      let continuation = continuations[index] else { return nil }
                continuations[index] = nil
                return continuation
            }
            continuation?.resume(returning: result)
        }
    }

    private struct Fixture {
        let root: URL
        let home: URL
        let app: InstalledApp
        let heuristic: URL
        let fs: RecordingFileSystem
        let router: ControllableCapabilityRouter
        let service: UninstallerService
        let model: UninstallerModel

        @MainActor
        init(router suppliedRouter: ControllableCapabilityRouter? = nil,
             targetScanner: (@Sendable (InstalledApp, UninstallMode) async
                -> UninstallBatch?)? = nil) throws {
            let unresolvedRoot = FileManager.default.temporaryDirectory
                .appendingPathComponent("xico-uninstaller-model-\(UUID().uuidString)")
            root = unresolvedRoot.path.hasPrefix("/var/")
                ? URL(fileURLWithPath: "/private" + unresolvedRoot.path)
                : unresolvedRoot.resolvingSymlinksInPath()
            home = root.appendingPathComponent("home")
            let appURL = root.appendingPathComponent("Applications/Test.app")
            try FileManager.default.createDirectory(at: appURL, withIntermediateDirectories: true)
            let issuanceID = UUID()
            let contents = appURL.appendingPathComponent("Contents")
            try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(
                at: home.appendingPathComponent("Library"), withIntermediateDirectories: true)
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent("license"), withIntermediateDirectories: true)
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent("history"), withIntermediateDirectories: true)
            let infoData = try PropertyListSerialization.data(
                fromPropertyList: ["CFBundleIdentifier": "com.example.test",
                                   "CFBundleName": "Test App"],
                format: .xml, options: 0)
            try infoData.write(to: contents.appendingPathComponent("Info.plist"))
            let appIdentity = try XCTUnwrap(LocalFileIdentitySampler().sample(appURL.path))
            let appAttestor = FDAnchoredAppBundlePathAttestor(appURL: appURL)
            let appProof = try XCTUnwrap(appAttestor.attestApp())
            let metadata = try XCTUnwrap(appAttestor.readRegularFile(
                relativeComponents: ["Contents", "Info.plist"], maximumBytes: 1_048_576))
            app = InstalledApp(id: appURL.path, name: "Test App",
                               bundleID: "com.example.test", url: appURL, size: 0,
                               provenanceID: issuanceID, sourceIdentity: appIdentity,
                               appPathProof: appProof,
                               metadataAttestation: metadata.attestation)
            let cache = home.appendingPathComponent("Library/Caches/com.example.test")
            heuristic = home.appendingPathComponent("Library/Application Support/Test App")
            try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: heuristic, withIntermediateDirectories: true)

            fs = RecordingFileSystem()
            router = suppliedRouter ?? ControllableCapabilityRouter()
            service = UninstallerService(fs: fs, safety: AllowAllSafety(), home: home,
                                         entitlementReader: EmptyEntitlements(),
                                         launchAgentReader: EmptyLaunchAgents(),
                                         preparationHooks: .none,
                                         issuanceID: issuanceID)
            router.bind(service: service)
            let defaultsName = "xico-uninstaller-model-license-\(UUID().uuidString)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsName))
            defaults.removePersistentDomain(forName: defaultsName)
            let license = LicenseService(trustedPublicKeys: [:],
                                         licenseDirectory: root.appendingPathComponent("license"),
                                         defaults: defaults, anchor: InMemoryAnchorStore())
            let environment = XicoEnvironment(
                fs: fs,
                safety: AllowAllSafety(),
                definitions: DefinitionsLibrary(version: 1, definitions: []),
                license: license,
                history: HistoryStore(directory: root.appendingPathComponent("history")),
                uninstaller: service,
                uninstallCapability: router)
            model = UninstallerModel(env: environment, targetScanner: targetScanner)
        }

        func batch(for app: InstalledApp) throws -> UninstallBatch {
            try service.uninstallTargets(for: app, mode: .uninstallApp)
        }

        func remove() { try? FileManager.default.removeItem(at: root) }
    }

    func testModelRetainsPolicyAndRequiredBodyAcrossToggleAndSelectAll() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        fixture.model.select(fixture.app)
        try await waitUntil { !fixture.model.targets.isEmpty }

        let body = try XCTUnwrap(fixture.model.targets.first { $0.role == .appBody })
        fixture.model.toggle(body.id)
        XCTAssertTrue(try XCTUnwrap(fixture.model.targets.first { $0.id == body.id }).isSelected)

        let heuristic = try XCTUnwrap(fixture.model.targets.first {
            $0.url.path == fixture.heuristic.path
        })
        fixture.model.toggle(heuristic.id)
        XCTAssertTrue(try XCTUnwrap(fixture.model.targets.first { $0.id == heuristic.id }).isSelected)

        fixture.model.toggleAllTargets(true)
        XCTAssertTrue(try XCTUnwrap(fixture.model.targets.first { $0.id == body.id }).isSelected)
        XCTAssertFalse(try XCTUnwrap(fixture.model.targets.first { $0.id == heuristic.id }).isSelected)
    }

    func testA1B_A2A1OutOfOrderScanCannotOverwriteFreshExactA1Batch() async throws {
        let scanner = ControlledTargetScanner()
        let fixture = try Fixture(targetScanner: { app, mode in
            await scanner.scan(app, mode: mode)
        })
        defer { fixture.remove() }
        let a1 = fixture.app.withSize(1)
        let b = fixture.app.withSize(2)
        let a2 = fixture.app.withSize(3)
        let oldA1Batch = try fixture.batch(for: a1)
        let freshA1Batch = try fixture.batch(for: a1)

        fixture.model.select(a1)
        try await waitUntil { scanner.requestCount == 1 }
        fixture.model.select(b)
        try await waitUntil { scanner.requestCount == 2 }
        fixture.model.select(a2)
        try await waitUntil { scanner.requestCount == 3 }
        fixture.model.select(a1)
        try await waitUntil { scanner.requestCount == 4 }

        scanner.resolve(3, with: freshA1Batch)
        try await waitUntil {
            fixture.model.batch?.batchID == freshA1Batch.batchID
                && !fixture.model.scanningTargets
        }
        scanner.resolve(0, with: oldA1Batch)
        scanner.resolve(1, with: nil)
        scanner.resolve(2, with: nil)
        try await waitUntil { scanner.completedCount == 4 }
        await Task.yield()

        XCTAssertEqual(fixture.model.selected, a1)
        XCTAssertEqual(fixture.model.batch?.batchID, freshA1Batch.batchID,
                       "the first A1 result must not overwrite the fourth selection's exact batch")
        XCTAssertEqual(scanner.requestedApps, [a1, b, a2, a1])
    }

    func testCurrentGenerationRejectsBatchBoundToSameIDButDifferentProvenance() async throws {
        let scanner = ControlledTargetScanner()
        let fixture = try Fixture(targetScanner: { app, mode in
            await scanner.scan(app, mode: mode)
        })
        defer { fixture.remove() }
        let originalBatch = try fixture.batch(for: fixture.app)
        let foreignProvenance = InstalledApp(
            id: fixture.app.id,
            name: fixture.app.name,
            bundleID: fixture.app.bundleID,
            url: fixture.app.url,
            size: fixture.app.size,
            provenanceID: UUID(),
            sourceIdentity: fixture.app.sourceIdentity,
            appPathProof: fixture.app.appPathProof,
            metadataAttestation: fixture.app.metadataAttestation)

        fixture.model.select(foreignProvenance)
        try await waitUntil { scanner.requestCount == 1 }
        scanner.resolve(0, with: originalBatch)
        try await waitUntil { !fixture.model.scanningTargets }

        XCTAssertEqual(fixture.model.selected, foreignProvenance)
        XCTAssertNil(fixture.model.batch,
                     "matching id/path is insufficient when opaque provenance differs")
    }

    func testModelRoutesConfirmationThroughCapabilityBeforeCleaningEngine() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        fixture.model.select(fixture.app)
        try await waitUntil { !fixture.model.targets.isEmpty }

        _ = try XCTUnwrap(fixture.model.beginConfirmation())
        fixture.model.uninstallConfirmed()
        try await waitUntil {
            fixture.router.calls == 1
                && !fixture.model.working
                && !fixture.model.scanningTargets
        }

        XCTAssertEqual(fixture.router.calls, 1)
        XCTAssertEqual(fixture.router.beginCalls, 1)
        XCTAssertTrue(fixture.fs.trashed.isEmpty,
                      "failed-closed capability must prevent the CleaningEngine closure")
    }

    func testModelIgnoresRepeatedConfirmationWhileUninstallIsWorking() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        fixture.model.select(fixture.app)
        try await waitUntil { !fixture.model.targets.isEmpty }

        let generation = try XCTUnwrap(fixture.model.beginConfirmation())
        XCTAssertEqual(fixture.model.beginConfirmation(), generation)
        fixture.model.uninstallConfirmed()
        fixture.model.uninstallConfirmed()
        try await waitUntil { !fixture.model.working && !fixture.model.scanningTargets }

        XCTAssertEqual(fixture.router.calls, 1)
        XCTAssertEqual(fixture.router.beginCalls, 1)
    }

    func testConfirmationSealsExactBatchAndFreezesSelectionAndBatchMutation() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        fixture.model.select(fixture.app)
        try await waitUntil { !fixture.model.targets.isEmpty }
        let heuristic = try XCTUnwrap(fixture.model.targets.first {
            $0.url.path == fixture.heuristic.path
        })
        fixture.model.toggle(heuristic.id)
        let reviewedBatch = try XCTUnwrap(fixture.model.batch)
        let reviewedSelectedIDs = Set(reviewedBatch.candidates.filter(\.isSelected).map(\.id))
        fixture.model.apps = [fixture.app]
        _ = try XCTUnwrap(fixture.model.beginConfirmation())
        let opaqueConfirmationID = try XCTUnwrap(fixture.model.confirmationID)

        XCTAssertTrue(fixture.model.isInteractionFrozen)
        XCTAssertEqual(fixture.model.confirmationAppName, reviewedBatch.app.name)
        XCTAssertEqual(fixture.model.confirmationSelectedCount, reviewedBatch.selectedCount)
        XCTAssertEqual(fixture.model.confirmationSelectedSize, reviewedBatch.selectedSize)
        fixture.model.toggle(heuristic.id)
        fixture.model.toggleAllTargets(false)
        fixture.model.select(fixture.app.withSize(999))
        fixture.model.load()
        XCTAssertEqual(fixture.model.selected, fixture.app)
        XCTAssertEqual(fixture.model.apps, [fixture.app],
                       "load must be frozen while exact confirmation is visible")
        XCTAssertFalse(fixture.model.loading)
        XCTAssertEqual(fixture.model.batch?.batchID, reviewedBatch.batchID)
        XCTAssertEqual(Set(fixture.model.targets.filter(\.isSelected).map(\.id)),
                       reviewedSelectedIDs)

        fixture.model.uninstallConfirmed()
        try await waitUntil {
            fixture.router.calls == 1
                && !fixture.model.working
                && !fixture.model.scanningTargets
        }
        let sealed = try XCTUnwrap(fixture.router.batches.first)
        XCTAssertEqual(sealed.batchID, reviewedBatch.batchID)
        XCTAssertEqual(Set(sealed.candidates.filter(\.isSelected).map(\.id)),
                       reviewedSelectedIDs)
        XCTAssertEqual(fixture.router.confirmations.first?.id, opaqueConfirmationID)
        XCTAssertEqual(fixture.router.beginCalls, 1)
        fixture.model.uninstallConfirmed()
        await Task.yield()
        XCTAssertEqual(fixture.router.calls, 1)
    }

    func testCancelReleasesOnlyOwnedConfirmationToken() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        fixture.model.select(fixture.app)
        try await waitUntil { !fixture.model.targets.isEmpty }
        let generation1 = try XCTUnwrap(fixture.model.beginConfirmation())
        fixture.model.cancelConfirmation(generation: generation1)
        XCTAssertNil(fixture.model.confirmationID)

        let generation2 = try XCTUnwrap(fixture.model.beginConfirmation())
        let confirmation2 = fixture.model.confirmationID
        fixture.model.cancelConfirmation(generation: generation1)
        XCTAssertEqual(fixture.model.confirmationID, confirmation2,
                       "a stale dialog dismissal must not cancel a newer confirmation")
        XCTAssertTrue(fixture.model.isInteractionFrozen)

        fixture.model.cancelConfirmation(generation: generation2)
        XCTAssertNil(fixture.model.confirmationID)
        XCTAssertFalse(fixture.model.isInteractionFrozen)
    }

    func testWorkingPhaseFreezesMutationsAndStaleTerminalCannotClearNewerExecution() async throws {
        let router = ControllableCapabilityRouter(suspended: true)
        let fixture = try Fixture(router: router)
        defer { fixture.remove() }
        fixture.model.select(fixture.app)
        try await waitUntil { !fixture.model.targets.isEmpty }
        let firstBatchID = try XCTUnwrap(fixture.model.batch?.batchID)
        _ = try XCTUnwrap(fixture.model.beginConfirmation())
        fixture.model.uninstallConfirmed()
        try await waitUntil { router.calls == 1 && fixture.model.working }
        let generation1 = try XCTUnwrap(fixture.model.activeExecutionGeneration)
        router.resume(0, with: .failedClosed(.expired))
        try await waitUntil {
            !fixture.model.working
                && fixture.model.batch?.batchID != firstBatchID
                && !fixture.model.targets.isEmpty
        }
        let newerBatch = try XCTUnwrap(fixture.model.batch)
        fixture.model.apps = [fixture.app]
        _ = try XCTUnwrap(fixture.model.beginConfirmation())
        fixture.model.uninstallConfirmed()
        try await waitUntil { router.calls == 2 && fixture.model.working }
        let generation2 = try XCTUnwrap(fixture.model.activeExecutionGeneration)
        XCTAssertNotEqual(generation1, generation2)

        let selectedBefore = fixture.model.selected
        let selectedIDsBefore = Set(fixture.model.targets.filter(\.isSelected).map(\.id))
        fixture.model.select(fixture.app.withSize(777))
        if let mutable = fixture.model.targets.first(where: { $0.isSelectable }) {
            fixture.model.toggle(mutable.id)
        }
        fixture.model.toggleAllTargets(false)
        fixture.model.load()
        XCTAssertNil(fixture.model.beginConfirmation())
        XCTAssertEqual(fixture.model.selected, selectedBefore)
        XCTAssertEqual(fixture.model.apps, [fixture.app],
                       "load must be frozen while an execution owns the model")
        XCTAssertEqual(fixture.model.batch?.batchID, newerBatch.batchID)
        XCTAssertEqual(Set(fixture.model.targets.filter(\.isSelected).map(\.id)),
                       selectedIDsBefore)

        fixture.model.finishExecution(
            generation: generation1,
            result: .failedClosed(.expired))
        XCTAssertTrue(fixture.model.working)
        XCTAssertEqual(fixture.model.activeExecutionGeneration, generation2)
        XCTAssertEqual(fixture.model.selected, selectedBefore)
        XCTAssertEqual(fixture.model.batch?.batchID, newerBatch.batchID)
        XCTAssertNil(fixture.model.lastFreed)

        router.resume(1, with: .failedClosed(.expired))
        try await waitUntil {
            !fixture.model.working
                && fixture.model.batch?.batchID != newerBatch.batchID
                && !fixture.model.targets.isEmpty
        }
        XCTAssertEqual(fixture.model.selected, selectedBefore)
        XCTAssertNotEqual(fixture.model.batch?.batchID, newerBatch.batchID)
    }

    func testTerminalForDifferentAppFailsClosedWithoutClearingExpectedContext()
        async throws {
        let router = ControllableCapabilityRouter(suspended: true)
        let fixture = try Fixture(router: router)
        let foreign = try Fixture()
        defer {
            fixture.remove()
            foreign.remove()
        }
        fixture.model.select(fixture.app)
        try await waitUntil { fixture.model.batch != nil && !fixture.model.scanningTargets }
        let foreignBatch = try foreign.batch(for: foreign.app)
        let foreignTerminal = try makeTerminal(
            fixture: foreign, batch: foreignBatch, fact: { _ in .succeeded })

        _ = fixture.model.beginConfirmation()
        fixture.model.uninstallConfirmed()
        try await waitUntil { router.calls == 1 }
        router.resume(0, with: .executed(foreignTerminal))
        try await waitUntil { !fixture.model.working }

        XCTAssertEqual(fixture.model.selected, fixture.app)
        XCTAssertNil(fixture.model.batch)
        XCTAssertNil(fixture.model.lastFreed)
        XCTAssertNil(fixture.model.lastUninstallReport)
        XCTAssertEqual(fixture.model.uninstallCompletion, .uncertain)
        XCTAssertTrue(fixture.model.requiresFreshScanBeforeRetry)
        XCTAssertTrue(fixture.model.unresolvedOccurrenceLedgerOverflow)
        XCTAssertTrue(fixture.model.canRescanForRetry)
    }

    func testConsumesPerItemCleaningReportAndRetainsFailuresAndRestorable() async throws {
        let router = ControllableCapabilityRouter(suspended: true)
        let fixture = try Fixture(router: router)
        defer { fixture.remove() }
        fixture.model.select(fixture.app)
        try await waitUntil { !fixture.model.scanningTargets && fixture.model.batch != nil }
        let batch = try XCTUnwrap(fixture.model.batch)
        let terminal = try makeTerminal(fixture: fixture, batch: batch) { target in
            target.candidate.role == .appBody ? .failedNone : .succeeded
        }

        _ = try XCTUnwrap(fixture.model.beginConfirmation())
        fixture.model.uninstallConfirmed()
        try await waitUntil { router.calls == 1 && fixture.model.working }
        router.resume(0, with: .executed(terminal))
        try await waitUntil { !fixture.model.working }

        XCTAssertEqual(fixture.model.lastUninstallReport?.operation.kind, .uninstall)
        XCTAssertEqual(fixture.model.lastUninstallReport?.operation.status, .partial)
        XCTAssertEqual(fixture.model.uninstallCompletion,
                       .dataMovedButAppNotUninstalled)
        XCTAssertEqual(fixture.model.remainingUndoReceipts.count,
                       batch.candidates.filter {
                           $0.isSelected && $0.role == .associatedFile
                       }.count)
        XCTAssertEqual(fixture.model.selected, fixture.app)
        XCTAssertNil(fixture.model.lastFreed)
        XCTAssertTrue(fixture.model.requiresFreshScanBeforeRetry)
    }

    func testSwitchingAwayAndBackPreservesExactPartialWorkflowAndReceiptOwners()
        async throws {
        let scanner = ControlledTargetScanner()
        let router = ControllableCapabilityRouter(suspended: true)
        let fixture = try Fixture(router: router, targetScanner: { app, mode in
            await scanner.scan(app, mode: mode)
        })
        defer { fixture.remove() }
        let original = try fixture.batch(for: fixture.app)
        let other = InstalledApp(
            id: fixture.root.appendingPathComponent("Applications/Other.app").path,
            name: "Other App",
            bundleID: "com.example.other",
            url: fixture.root.appendingPathComponent("Applications/Other.app"),
            size: 0,
            provenanceID: fixture.app.provenanceID,
            sourceIdentity: fixture.app.sourceIdentity,
            appPathProof: fixture.app.appPathProof,
            metadataAttestation: fixture.app.metadataAttestation)

        fixture.model.select(fixture.app)
        try await waitUntil { scanner.requestCount == 1 }
        scanner.resolve(0, with: original)
        try await waitUntil { fixture.model.batch?.batchID == original.batchID }
        let terminal = try makeTerminal(fixture: fixture, batch: original) { target in
            target.candidate.role == .appBody ? .failedNone : .succeeded
        }
        _ = fixture.model.beginConfirmation()
        fixture.model.uninstallConfirmed()
        try await waitUntil { router.calls == 1 }
        router.resume(0, with: .executed(terminal))
        try await waitUntil { !fixture.model.working }
        let exactReceipts = fixture.model.remainingUndoReceipts
        let exactRequestIDs = Set(
            fixture.model.unresolvedUninstallOccurrences.map(\.requestID))
        XCTAssertFalse(exactReceipts.isEmpty)

        fixture.model.select(other)
        try await waitUntil { scanner.requestCount == 2 }
        scanner.resolve(1, with: nil)
        try await waitUntil { !fixture.model.scanningTargets }
        fixture.model.select(fixture.app)
        await Task.yield()

        XCTAssertEqual(scanner.requestCount, 2,
                       "returning to a pending workflow must not start the wrong mode")
        XCTAssertEqual(fixture.model.selected, fixture.app)
        XCTAssertEqual(fixture.model.remainingUndoReceipts, exactReceipts)
        XCTAssertEqual(fixture.model.undoReceiptOwnerOperationIDs,
                       Set([terminal.report.operation.id]))
        XCTAssertEqual(Set(fixture.model.unresolvedUninstallOccurrences.map(\.requestID)),
                       exactRequestIDs)
        XCTAssertEqual(fixture.model.uninstallCompletion,
                       .dataMovedButAppNotUninstalled)
        XCTAssertTrue(fixture.model.canRescanForRetry)
    }

    func testFreshRetryBatchSurvivesSwitchAwayAndSameAppReselection() async throws {
        let scanner = ControlledTargetScanner()
        let router = ControllableCapabilityRouter(suspended: true)
        let fixture = try Fixture(router: router, targetScanner: { app, mode in
            await scanner.scan(app, mode: mode)
        })
        defer { fixture.remove() }
        let original = try fixture.batch(for: fixture.app)
        fixture.model.select(fixture.app)
        try await waitUntil { scanner.requestCount == 1 }
        scanner.resolve(0, with: original)
        try await waitUntil { fixture.model.batch?.batchID == original.batchID }
        let partial = try makeTerminal(fixture: fixture, batch: original) { target in
            target.candidate.role == .appBody ? .failedNone : .succeeded
        }
        _ = fixture.model.beginConfirmation()
        fixture.model.uninstallConfirmed()
        try await waitUntil { router.calls == 1 }
        router.resume(0, with: .executed(partial))
        try await waitUntil { !fixture.model.working }

        fixture.model.rescanForRetry()
        try await waitUntil { scanner.requestCount == 2 }
        let fresh = try fixture.batch(for: fixture.app)
        scanner.resolve(1, with: fresh)
        try await waitUntil { fixture.model.batch?.batchID == fresh.batchID }
        XCTAssertFalse(fixture.model.requiresFreshScanBeforeRetry)

        let other = InstalledApp(
            id: fixture.root.appendingPathComponent("Applications/Other.app").path,
            name: "Other App",
            bundleID: "com.example.other",
            url: fixture.root.appendingPathComponent("Applications/Other.app"),
            size: 0,
            provenanceID: fixture.app.provenanceID,
            sourceIdentity: fixture.app.sourceIdentity,
            appPathProof: fixture.app.appPathProof,
            metadataAttestation: fixture.app.metadataAttestation)
        fixture.model.select(other)
        try await waitUntil { scanner.requestCount == 3 }
        scanner.resolve(2, with: nil)
        try await waitUntil { !fixture.model.scanningTargets }
        fixture.model.select(fixture.app)
        await Task.yield()

        XCTAssertEqual(scanner.requestCount, 3)
        XCTAssertEqual(fixture.model.batch?.batchID, fresh.batchID,
                       "a reviewed fresh retry batch must remain actionable after returning")
        fixture.model.select(fixture.app)
        await Task.yield()
        XCTAssertEqual(scanner.requestCount, 3,
                       "reselecting the same pending app must not discard its fresh batch")
        XCTAssertEqual(fixture.model.batch?.batchID, fresh.batchID)
        XCTAssertNotNil(fixture.model.beginConfirmation())
    }

    func testSamePathReplacementAppCannotInheritPriorWorkflowFactsOrReceipts() async throws {
        let scanner = ControlledTargetScanner()
        let router = ControllableCapabilityRouter(suspended: true)
        let fixture = try Fixture(router: router, targetScanner: { app, mode in
            await scanner.scan(app, mode: mode)
        })
        defer { fixture.remove() }
        let original = try fixture.batch(for: fixture.app)
        fixture.model.select(fixture.app)
        try await waitUntil { scanner.requestCount == 1 }
        scanner.resolve(0, with: original)
        try await waitUntil { fixture.model.batch?.batchID == original.batchID }
        let partial = try makeTerminal(fixture: fixture, batch: original) { target in
            target.candidate.role == .appBody ? .failedNone : .succeeded
        }
        _ = fixture.model.beginConfirmation()
        fixture.model.uninstallConfirmed()
        try await waitUntil { router.calls == 1 }
        router.resume(0, with: .executed(partial))
        try await waitUntil { !fixture.model.working }
        XCTAssertFalse(fixture.model.remainingUndoReceipts.isEmpty)

        let replacement = InstalledApp(
            id: fixture.app.id,
            name: "Replacement App",
            bundleID: "com.example.replacement",
            url: fixture.app.url,
            size: fixture.app.size,
            provenanceID: UUID(),
            sourceIdentity: fixture.app.sourceIdentity,
            appPathProof: fixture.app.appPathProof,
            metadataAttestation: fixture.app.metadataAttestation)
        fixture.model.select(replacement)
        try await waitUntil { scanner.requestCount == 2 }

        XCTAssertEqual(fixture.model.selected, replacement)
        XCTAssertTrue(fixture.model.remainingUndoReceipts.isEmpty)
        XCTAssertTrue(fixture.model.unresolvedUninstallOccurrences.isEmpty)
        XCTAssertNil(fixture.model.uninstallCompletion)
        XCTAssertNil(fixture.model.lastUninstallReport)
        scanner.resolve(1, with: nil)
        try await waitUntil { !fixture.model.scanningTargets }
    }

    func testFreshEmptyLeftoversScanReconcilesNoneFactsWithoutDeadEnd() async throws {
        let scanner = ControlledTargetScanner()
        let router = ControllableCapabilityRouter(suspended: true)
        let fixture = try Fixture(router: router, targetScanner: { app, mode in
            await scanner.scan(app, mode: mode)
        })
        defer { fixture.remove() }
        let original = try fixture.batch(for: fixture.app)
        fixture.model.select(fixture.app)
        try await waitUntil { scanner.requestCount == 1 }
        scanner.resolve(0, with: original)
        try await waitUntil { fixture.model.batch?.batchID == original.batchID }
        let terminal = try makeTerminal(fixture: fixture, batch: original) { target in
            target.candidate.role == .appBody ? .succeeded : .failedNone
        }
        _ = fixture.model.beginConfirmation()
        fixture.model.uninstallConfirmed()
        try await waitUntil { router.calls == 1 }
        router.resume(0, with: .executed(terminal))
        try await waitUntil { !fixture.model.working }

        fixture.model.rescanForRetry()
        try await waitUntil { scanner.requestCount == 2 }
        let empty = UninstallBatch(
            issuanceID: original.issuanceID,
            batchID: UUID(),
            app: fixture.app,
            mode: .cleanLeftovers,
            candidates: [])
        scanner.resolve(1, with: empty)
        try await waitUntil { !fixture.model.scanningTargets }

        XCTAssertTrue(fixture.model.unresolvedUninstallOccurrences.isEmpty)
        XCTAssertEqual(fixture.model.uninstallCompletion, .fullSuccess)
        XCTAssertNil(fixture.model.selected)
        XCTAssertNil(fixture.model.batch)
        XCTAssertNotNil(fixture.model.lastFreed)
        XCTAssertFalse(fixture.model.requiresFreshScanBeforeRetry)
        XCTAssertFalse(fixture.model.canRescanForRetry)
    }

    func testFreshEmptyScanCannotErasePossiblyChangedFactsOrDisableReconciliation()
        async throws {
        let scanner = ControlledTargetScanner()
        let router = ControllableCapabilityRouter(suspended: true)
        let fixture = try Fixture(router: router, targetScanner: { app, mode in
            await scanner.scan(app, mode: mode)
        })
        defer { fixture.remove() }
        let original = try fixture.batch(for: fixture.app)
        fixture.model.select(fixture.app)
        try await waitUntil { scanner.requestCount == 1 }
        scanner.resolve(0, with: original)
        try await waitUntil { fixture.model.batch?.batchID == original.batchID }
        let terminal = try makeTerminal(fixture: fixture, batch: original) { target in
            target.candidate.role == .appBody ? .succeeded : .failedPossiblyChanged
        }
        _ = fixture.model.beginConfirmation()
        fixture.model.uninstallConfirmed()
        try await waitUntil { router.calls == 1 }
        router.resume(0, with: .executed(terminal))
        try await waitUntil { !fixture.model.working }
        let uncertainIDs = Set(
            fixture.model.unresolvedUninstallOccurrences.map(\.requestID))

        fixture.model.rescanForRetry()
        try await waitUntil { scanner.requestCount == 2 }
        let empty = UninstallBatch(
            issuanceID: original.issuanceID,
            batchID: UUID(),
            app: fixture.app,
            mode: .cleanLeftovers,
            candidates: [])
        scanner.resolve(1, with: empty)
        try await waitUntil { !fixture.model.scanningTargets }

        XCTAssertEqual(Set(fixture.model.unresolvedUninstallOccurrences.map(\.requestID)),
                       uncertainIDs)
        XCTAssertEqual(fixture.model.uninstallCompletion, .uncertain)
        XCTAssertNotNil(fixture.model.selected)
        XCTAssertTrue(fixture.model.requiresFreshScanBeforeRetry)
        XCTAssertTrue(fixture.model.canRescanForRetry)
        XCTAssertNil(fixture.model.lastFreed)
    }

    func testOnlySuccessfulCandidatesRemovedFailedRetainedForRetry() async throws {
        let router = ControllableCapabilityRouter(suspended: true)
        let fixture = try Fixture(router: router)
        defer { fixture.remove() }
        fixture.model.select(fixture.app)
        try await waitUntil { !fixture.model.scanningTargets && fixture.model.batch != nil }
        let original = try XCTUnwrap(fixture.model.batch)
        let successfulPaths = Set(original.candidates.filter {
            $0.isSelected && $0.role == .associatedFile
        }.map { $0.url.standardizedFileURL.path })
        let terminal = try makeTerminal(fixture: fixture, batch: original) { target in
            target.candidate.role == .appBody ? .failedNone : .succeeded
        }

        _ = fixture.model.beginConfirmation()
        fixture.model.uninstallConfirmed()
        try await waitUntil { router.calls == 1 }
        router.resume(0, with: .executed(terminal))
        try await waitUntil { !fixture.model.working }

        let retained = try XCTUnwrap(fixture.model.batch)
        XCTAssertTrue(retained.candidates.contains { $0.role == .appBody && $0.isSelected })
        XCTAssertTrue(retained.candidates.allSatisfy {
            !successfulPaths.contains($0.url.standardizedFileURL.path)
        })
        XCTAssertNil(fixture.model.beginConfirmation(),
                     "a consumed partial batch must never be replayed")
        fixture.model.rescanForRetry()
        try await waitUntil {
            !fixture.model.scanningTargets
                && fixture.model.batch?.batchID != original.batchID
        }
        XCTAssertNotNil(fixture.model.beginConfirmation(),
                        "retry must use a freshly scanned batch and confirmation")
    }

    func testAppBodyFailureWithPartialDataSuccessIsExplicitlyExplained() async throws {
        let router = ControllableCapabilityRouter(suspended: true)
        let fixture = try Fixture(router: router)
        defer { fixture.remove() }
        fixture.model.select(fixture.app)
        try await waitUntil { !fixture.model.scanningTargets && fixture.model.batch != nil }
        let batch = try XCTUnwrap(fixture.model.batch)
        let terminal = try makeTerminal(fixture: fixture, batch: batch) { target in
            target.candidate.role == .appBody ? .failedNone : .succeeded
        }

        _ = fixture.model.beginConfirmation()
        fixture.model.uninstallConfirmed()
        try await waitUntil { router.calls == 1 }
        router.resume(0, with: .executed(terminal))
        try await waitUntil { !fixture.model.working }

        XCTAssertEqual(fixture.model.uninstallCompletion,
                       .dataMovedButAppNotUninstalled)
        XCTAssertNotNil(fixture.model.selected)
        XCTAssertNil(fixture.model.lastFreed,
                     "partial mutation must never enter the old completion presentation")
    }

    func testPartialUninstallCanUndoAlreadyTrashedItems() async throws {
        let router = ControllableCapabilityRouter(suspended: true)
        let fixture = try Fixture(router: router)
        defer { fixture.remove() }
        fixture.model.select(fixture.app)
        try await waitUntil { !fixture.model.scanningTargets && fixture.model.batch != nil }
        let heuristic = try XCTUnwrap(fixture.model.targets.first {
            $0.role == .associatedFile && $0.selectionPolicy == .manualOnly
        })
        fixture.model.toggle(heuristic.id)
        let batch = try XCTUnwrap(fixture.model.batch)
        let terminal = try makeTerminal(fixture: fixture, batch: batch) { target in
            target.candidate.role == .appBody ? .failedNone : .succeeded
        }

        _ = fixture.model.beginConfirmation()
        fixture.model.uninstallConfirmed()
        try await waitUntil { router.calls == 1 }
        router.resume(0, with: .executed(terminal))
        try await waitUntil { !fixture.model.working }
        XCTAssertGreaterThanOrEqual(fixture.model.remainingUndoReceipts.count, 2)
        let failedReceipt = try XCTUnwrap(fixture.model.remainingUndoReceipts.first)
        fixture.fs.failRestore(of: failedReceipt)

        let requested = Set(fixture.model.remainingUndoReceipts.map {
            $0.originalURL.standardizedFileURL.path
        })
        fixture.model.undoPartialUninstall()
        try await waitUntil { !fixture.model.undoing }

        XCTAssertEqual(Set(fixture.fs.restored.map {
            $0.originalURL.standardizedFileURL.path
        }), requested)
        XCTAssertEqual(fixture.model.remainingUndoReceipts, [failedReceipt],
                       "UndoReport.remaining must remain retryable verbatim")
        XCTAssertNotNil(fixture.model.selected)
        XCTAssertTrue(fixture.model.requiresFreshScanBeforeRetry)
    }

    func testCrossOperationReceiptEndpointCollisionDisablesUndoWithoutRestoringAnything()
        async throws {
        let scanner = ControlledTargetScanner()
        let router = ControllableCapabilityRouter(suspended: true)
        let fixture = try Fixture(router: router, targetScanner: { app, mode in
            await scanner.scan(app, mode: mode)
        })
        defer { fixture.remove() }

        let firstBatch = try fixture.batch(for: fixture.app)
        let bodyPath = try XCTUnwrap(firstBatch.candidates.first {
            $0.role == .appBody
        }).url.standardizedFileURL
        fixture.model.select(fixture.app)
        try await waitUntil { scanner.requestCount == 1 }
        scanner.resolve(0, with: firstBatch)
        try await waitUntil { fixture.model.batch?.batchID == firstBatch.batchID }

        let associatedFirst = try makeTerminal(
            fixture: fixture,
            batch: firstBatch,
            trashURL: { target, requestID in
                if target.candidate.role == .associatedFile { return bodyPath }
                return URL(fileURLWithPath: "/private/tmp/xico-test-trash")
                    .appendingPathComponent(requestID.uuidString)
            },
            fact: { target in
                target.candidate.role == .associatedFile ? .succeeded : .failedNone
            })
        _ = fixture.model.beginConfirmation()
        fixture.model.uninstallConfirmed()
        try await waitUntil { router.calls == 1 }
        router.resume(0, with: .executed(associatedFirst))
        try await waitUntil { !fixture.model.working }
        XCTAssertEqual(fixture.model.remainingUndoReceipts.count, 1)

        fixture.model.rescanForRetry()
        try await waitUntil { scanner.requestCount == 2 }
        let secondBatch = try fixture.batch(for: fixture.app)
        scanner.resolve(1, with: secondBatch)
        try await waitUntil { fixture.model.batch?.batchID == secondBatch.batchID }
        let bodySecond = try makeTerminal(
            fixture: fixture,
            batch: secondBatch,
            fact: { target in
                target.candidate.role == .appBody ? .succeeded : .failedNone
            })
        _ = fixture.model.beginConfirmation()
        fixture.model.uninstallConfirmed()
        try await waitUntil { router.calls == 2 }
        router.resume(1, with: .executed(bodySecond))
        try await waitUntil { !fixture.model.working }

        XCTAssertEqual(fixture.model.remainingUndoReceipts.count, 2,
                       "conflicting recovery facts must be retained for manual reconciliation")
        XCTAssertFalse(fixture.model.canUndoPartialUninstall,
                       "one path is both an earlier Trash destination and a later original")
        XCTAssertTrue(fixture.model.unresolvedOccurrenceLedgerOverflow)
        XCTAssertEqual(fixture.model.uninstallCompletion, .uncertain)

        fixture.model.undoPartialUninstall()
        await Task.yield()
        XCTAssertTrue(fixture.fs.restored.isEmpty,
                      "an endpoint collision must block every restore across all owners")
    }

    func testOnlyFullSuccessClearsContextAndEntersSuccessPresentation() async throws {
        let router = ControllableCapabilityRouter(suspended: true)
        let fixture = try Fixture(router: router)
        defer { fixture.remove() }
        fixture.model.select(fixture.app)
        try await waitUntil { !fixture.model.scanningTargets && fixture.model.batch != nil }
        let batch = try XCTUnwrap(fixture.model.batch)
        let terminal = try makeTerminal(
            fixture: fixture, batch: batch, fact: { _ in .succeeded })

        _ = fixture.model.beginConfirmation()
        fixture.model.uninstallConfirmed()
        try await waitUntil { router.calls == 1 }
        router.resume(0, with: .executed(terminal))
        try await waitUntil { !fixture.model.working }

        XCTAssertNil(fixture.model.selected)
        XCTAssertNil(fixture.model.batch)
        XCTAssertEqual(fixture.model.uninstallCompletion, .fullSuccess)
        XCTAssertEqual(fixture.model.lastFreed, terminal.report.reclaimedBytes)
        XCTAssertEqual(fixture.model.lastRemovedCount, terminal.report.removedCount)
        XCTAssertFalse(fixture.model.requiresFreshScanBeforeRetry)
    }

    func testRequiredAppBodyCannotBeExecutedAsDeselected() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        fixture.model.select(fixture.app)
        try await waitUntil { !fixture.model.scanningTargets && fixture.model.batch != nil }
        let body = try XCTUnwrap(fixture.model.targets.first { $0.role == .appBody })
        fixture.model.toggle(body.id)

        XCTAssertTrue(try XCTUnwrap(fixture.model.targets.first {
            $0.id == body.id
        }).isSelected)
        XCTAssertNotNil(fixture.model.beginConfirmation())
    }

    func testBodySuccessRetriesOnlyThroughFreshCleanLeftoversScan() async throws {
        let scanner = ControlledTargetScanner()
        let router = ControllableCapabilityRouter(suspended: true)
        let fixture = try Fixture(router: router, targetScanner: { app, mode in
            await scanner.scan(app, mode: mode)
        })
        defer { fixture.remove() }
        let original = try fixture.batch(for: fixture.app)

        fixture.model.select(fixture.app)
        try await waitUntil { scanner.requestCount == 1 }
        scanner.resolve(0, with: original)
        try await waitUntil { fixture.model.batch?.batchID == original.batchID }
        let terminal = try makeTerminal(fixture: fixture, batch: original) { target in
            target.candidate.role == .appBody ? .succeeded : .failedNone
        }

        _ = fixture.model.beginConfirmation()
        fixture.model.uninstallConfirmed()
        try await waitUntil { router.calls == 1 }
        router.resume(0, with: .executed(terminal))
        try await waitUntil { !fixture.model.working }

        XCTAssertEqual(fixture.model.uninstallCompletion,
                       .appMovedButSomeDataRetained)
        XCTAssertNil(fixture.model.beginConfirmation(),
                     "the consumed batch must not be replayed")
        fixture.model.rescanForRetry()
        try await waitUntil { scanner.requestCount == 2 }
        XCTAssertEqual(scanner.requestedModes, [.uninstallApp, .cleanLeftovers])
        XCTAssertNil(fixture.model.beginConfirmation(),
                     "a new confirmation requires the fresh scan result")
        scanner.resolve(1, with: nil)
        try await waitUntil { scanner.completedCount == 2 }
    }

    func testCumulativePossiblyChangedFactPreventsLaterFalseFullSuccess() async throws {
        let router = ControllableCapabilityRouter(suspended: true)
        let fixture = try Fixture(router: router)
        defer { fixture.remove() }
        fixture.model.select(fixture.app)
        try await waitUntil { fixture.model.batch != nil && !fixture.model.scanningTargets }
        let original = try XCTUnwrap(fixture.model.batch)
        let uncertain = try makeTerminal(fixture: fixture, batch: original) { target in
            target.candidate.role == .appBody ? .failedNone : .failedPossiblyChanged
        }

        _ = fixture.model.beginConfirmation()
        fixture.model.uninstallConfirmed()
        try await waitUntil { router.calls == 1 }
        router.resume(0, with: .executed(uncertain))
        try await waitUntil { !fixture.model.working }
        XCTAssertTrue(fixture.model.hasUnresolvedPossiblyChangedFacts)
        let firstUnresolved = fixture.model.unresolvedUninstallOccurrences
        let initiallyPossiblyChangedRequestIDs = Set(firstUnresolved.compactMap {
            $0.mutation == .possiblyChanged ? $0.requestID : nil
        })
        XCTAssertFalse(initiallyPossiblyChangedRequestIDs.isEmpty)
        XCTAssertEqual(Set(firstUnresolved.map(\.operationID)),
                       Set([uncertain.report.operation.id]))
        XCTAssertEqual(Set(firstUnresolved.map(\.requestID)),
                       Set(uncertain.report.items.map(\.requestID)))
        XCTAssertEqual(Set(firstUnresolved.map(\.subject.canonicalPath)),
                       Set(uncertain.report.items.map {
                           $0.url.standardizedFileURL.path
                       }))

        fixture.model.rescanForRetry()
        try await waitUntil {
            !fixture.model.scanningTargets
                && fixture.model.batch?.batchID != original.batchID
        }
        let fresh = try XCTUnwrap(fixture.model.batch)
        let laterSuccess = try makeTerminal(
            fixture: fixture, batch: fresh, fact: { _ in .succeeded })
        _ = fixture.model.beginConfirmation()
        fixture.model.uninstallConfirmed()
        try await waitUntil { router.calls == 2 }
        router.resume(1, with: .executed(laterSuccess))
        try await waitUntil { !fixture.model.working }

        XCTAssertEqual(fixture.model.lastUninstallReport?.operation.status, .success)
        XCTAssertTrue(fixture.model.hasUnresolvedPossiblyChangedFacts)
        XCTAssertEqual(fixture.model.uninstallCompletion, .uncertain)
        XCTAssertNotNil(fixture.model.selected)
        XCTAssertNil(fixture.model.lastFreed)
        XCTAssertTrue(fixture.model.requiresFreshScanBeforeRetry)
        XCTAssertTrue(fixture.model.canRescanForRetry)
        XCTAssertEqual(Set(fixture.model.unresolvedUninstallOccurrences.map(\.requestID)),
                       initiallyPossiblyChangedRequestIDs,
                       "a later success may reconcile `.none`, but not uncertain facts")
    }

    func testLaterExactSuccessReconcilesPriorNoneFactsAndAllowsCompletion() async throws {
        let router = ControllableCapabilityRouter(suspended: true)
        let fixture = try Fixture(router: router)
        defer { fixture.remove() }
        fixture.model.select(fixture.app)
        try await waitUntil { fixture.model.batch != nil && !fixture.model.scanningTargets }
        let original = try XCTUnwrap(fixture.model.batch)
        let failed = try makeTerminal(
            fixture: fixture, batch: original, fact: { _ in .failedNone })

        _ = fixture.model.beginConfirmation()
        fixture.model.uninstallConfirmed()
        try await waitUntil { router.calls == 1 }
        router.resume(0, with: .executed(failed))
        try await waitUntil { !fixture.model.working }
        XCTAssertEqual(fixture.model.unresolvedUninstallOccurrences.count,
                       failed.report.items.count)

        fixture.model.rescanForRetry()
        try await waitUntil {
            !fixture.model.scanningTargets
                && fixture.model.batch?.batchID != original.batchID
        }
        let fresh = try XCTUnwrap(fixture.model.batch)
        let success = try makeTerminal(
            fixture: fixture, batch: fresh, fact: { _ in .succeeded })
        _ = fixture.model.beginConfirmation()
        fixture.model.uninstallConfirmed()
        try await waitUntil { router.calls == 2 }
        router.resume(1, with: .executed(success))
        try await waitUntil { !fixture.model.working }

        XCTAssertTrue(fixture.model.unresolvedUninstallOccurrences.isEmpty)
        XCTAssertFalse(fixture.model.unresolvedOccurrenceLedgerOverflow)
        XCTAssertFalse(fixture.model.hasUnresolvedPossiblyChangedFacts)
        XCTAssertEqual(fixture.model.uninstallCompletion, .fullSuccess)
        XCTAssertNil(fixture.model.selected)
        XCTAssertNotNil(fixture.model.lastFreed)
    }

    func testReselectingSameAppPreservesExactUnresolvedOccurrenceLedger() async throws {
        let router = ControllableCapabilityRouter(suspended: true)
        let fixture = try Fixture(router: router)
        defer { fixture.remove() }
        fixture.model.select(fixture.app)
        try await waitUntil { fixture.model.batch != nil && !fixture.model.scanningTargets }
        let original = try XCTUnwrap(fixture.model.batch)
        let uncertain = try makeTerminal(
            fixture: fixture, batch: original, fact: { _ in .failedPossiblyChanged })

        _ = fixture.model.beginConfirmation()
        fixture.model.uninstallConfirmed()
        try await waitUntil { router.calls == 1 }
        router.resume(0, with: .executed(uncertain))
        try await waitUntil { !fixture.model.working }
        let exactRequestIDs = Set(
            fixture.model.unresolvedUninstallOccurrences.map(\.requestID))

        fixture.model.select(fixture.app)
        try await waitUntil { !fixture.model.scanningTargets }

        XCTAssertEqual(Set(fixture.model.unresolvedUninstallOccurrences.map(\.requestID)),
                       exactRequestIDs)
        XCTAssertTrue(fixture.model.hasUnresolvedPossiblyChangedFacts)
    }

    private func makeTerminal(
        fixture: Fixture,
        batch: UninstallBatch,
        trashURL: ((PreparedUninstallTarget, UUID) -> URL)? = nil,
        fact: (PreparedUninstallTarget) -> TerminalFact
    ) throws -> UninstallExecution {
        let prepared = try fixture.service.prepareUninstallExecution(
            from: batch,
            using: DestructiveOperationIssuer(
                sampler: LocalFileIdentitySampler(), ledger: AuthorizationLedger()))
        let bindings = prepared.orderedTargets.map {
            UninstallPayloadOccurrenceBinding(requestID: UUID(), target: $0)
        }
        let results = bindings.map { binding -> CleaningItemResult in
            let selectedFact = fact(binding.target)
            switch selectedFact {
            case .succeeded:
                let receipt = RestorableItem(
                    originalURL: binding.target.candidate.url,
                    trashedURL: trashURL?(binding.target, binding.requestID)
                        ?? URL(fileURLWithPath: "/private/tmp/xico-test-trash")
                            .appendingPathComponent(binding.requestID.uuidString))
                return CleaningItemResult(
                    requestID: binding.requestID,
                    itemID: binding.target.candidate.item.id,
                    url: binding.target.candidate.url,
                    intent: .trash,
                    disposition: .succeeded,
                    mutation: .changed,
                    reclaimedBytes:
                        binding.target.candidate.item.estimatedReclaimableBytes,
                    restorable: receipt)
            case .failedNone, .failedPossiblyChanged:
                let issue = OperationIssue(
                    code: selectedFact == .failedNone
                        ? "uninstall.identity.changed"
                        : "uninstall.filesystem.operationFailed",
                    category: selectedFact == .failedNone ? .identityChanged : .io,
                    subjectID: binding.requestID.uuidString,
                    recovery: .retry,
                    retryable: true)
                return CleaningItemResult(
                    requestID: binding.requestID,
                    itemID: binding.target.candidate.item.id,
                    url: binding.target.candidate.url,
                    intent: .trash,
                    disposition: .failed(issue),
                    mutation: selectedFact == .failedNone ? .none : .possiblyChanged,
                    reclaimedBytes: 0,
                    restorable: nil)
            case .cancelled:
                return CleaningItemResult(
                    requestID: binding.requestID,
                    itemID: binding.target.candidate.item.id,
                    url: binding.target.candidate.url,
                    intent: .trash,
                    disposition: .cancelled(nil),
                    mutation: .none,
                    reclaimedBytes: 0,
                    restorable: nil)
            }
        }
        let now = Date()
        let outcome = try OperationOutcomeReducer.reduce(
            kind: .uninstall,
            requestedSubjectIDs: bindings.map { $0.requestID.uuidString },
            itemOutcomes: results.map {
                OperationItemOutcome(
                    subjectID: $0.requestID.uuidString,
                    disposition: $0.disposition,
                    mutation: $0.mutation,
                    affectedBytes: $0.reclaimedBytes)
            },
            cancellationAccepted: results.contains {
                if case .cancelled = $0.disposition { return true }
                return false
            },
            startedAt: now,
            finishedAt: now)
        let payload = UninstallPayloadExecution(
            report: CleaningReport(operation: outcome, items: results),
            occurrences: bindings)
        return try XCTUnwrap(UninstallExecution(payload: payload, prepared: prepared))
    }

    private func waitUntil(_ predicate: @escaping @MainActor () -> Bool) async throws {
        for _ in 0..<200 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Timed out waiting for model state")
    }
}
