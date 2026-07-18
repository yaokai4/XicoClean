import Foundation
import XCTest
@testable import Domain
@testable import Features
@testable import Infrastructure

@MainActor
final class UninstallerModelCapabilityTests: XCTestCase {
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

        var trashed: [String] { lock.withLock { trashPaths } }

        func exists(_ url: URL) -> Bool { local.exists(url) }
        func contentsOfDirectory(_ url: URL) -> [URL] { local.contentsOfDirectory(url) }
        func allocatedSize(of url: URL) -> Int64 { local.allocatedSize(of: url) }
        func entry(for url: URL) -> FileEntry? { local.entry(for: url) }
        func trash(_ url: URL) throws -> URL {
            lock.withLock { trashPaths.append(url.path) }
            return url
        }
        func remove(_ url: URL) throws { lock.withLock { trashPaths.append(url.path) } }
        func restore(_ item: RestorableItem) throws {}
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
            var continuation: CheckedContinuation<UninstallBatch?, Never>?
        }

        private let lock = NSLock()
        private var requests: [PendingRequest] = []
        private var completed = 0

        var requestCount: Int { lock.withLock { requests.count } }
        var completedCount: Int { lock.withLock { completed } }
        var requestedApps: [InstalledApp] { lock.withLock { requests.map(\.app) } }

        func scan(_ app: InstalledApp) async -> UninstallBatch? {
            let result = await withCheckedContinuation { continuation in
                lock.withLock {
                    requests.append(PendingRequest(app: app, continuation: continuation))
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
            DestructiveExecutionResult<CleaningReport>, Never>?] = []

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
            -> DestructiveExecutionResult<CleaningReport> {
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
                    with result: DestructiveExecutionResult<CleaningReport>) {
            let continuation = lock.withLock { () -> CheckedContinuation<
                DestructiveExecutionResult<CleaningReport>, Never>? in
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
             targetScanner: (@Sendable (InstalledApp) async -> UninstallBatch?)? = nil) throws {
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
        let fixture = try Fixture(targetScanner: { app in await scanner.scan(app) })
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
        let fixture = try Fixture(targetScanner: { app in await scanner.scan(app) })
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
            result: .executed(Self.staleSuccessReport()))
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

    private static func staleSuccessReport() -> CleaningReport {
        let now = Date()
        let operation = OperationOutcomeReducer.internalFailure(
            kind: .uninstall,
            requestedSubjectIDs: [],
            code: "feature.test.staleTerminal",
            startedAt: now,
            finishedAt: now)
        return CleaningReport(operation: operation, facts: [])
    }

    private func waitUntil(_ predicate: @escaping @MainActor () -> Bool) async throws {
        for _ in 0..<200 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Timed out waiting for model state")
    }
}
