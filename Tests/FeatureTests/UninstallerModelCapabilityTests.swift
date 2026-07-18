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
        func applicationGroups(for appURL: URL) -> [String]? { [] }
    }

    private struct EmptyLaunchAgents: LaunchAgentReader {
        func launchAgent(at url: URL) -> LaunchAgentRecord? { nil }
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

    private final class DenyingCapabilityRouter: @unchecked Sendable, UninstallCapabilityRouting {
        private let lock = NSLock()
        private var callCount = 0
        var calls: Int { lock.withLock { callCount } }

        func execute(
            batch: UninstallBatch,
            service: UninstallerService,
            operation: @escaping @Sendable ([CleanableItem]) async -> CleaningReport
        ) async throws -> DestructiveExecutionResult<CleaningReport> {
            lock.withLock { callCount += 1 }
            return .failedClosed(.expired)
        }
    }

    private struct Fixture {
        let root: URL
        let home: URL
        let app: InstalledApp
        let heuristic: URL
        let fs: RecordingFileSystem
        let router: DenyingCapabilityRouter
        let model: UninstallerModel

        @MainActor
        init() throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("xico-uninstaller-model-\(UUID().uuidString)")
            home = root.appendingPathComponent("home")
            let appURL = root.appendingPathComponent("Applications/Test.app")
            try FileManager.default.createDirectory(at: appURL, withIntermediateDirectories: true)
            app = InstalledApp(id: appURL.path, name: "Test App",
                               bundleID: "com.example.test", url: appURL, size: 0)
            let cache = home.appendingPathComponent("Library/Caches/com.example.test")
            heuristic = home.appendingPathComponent("Library/Application Support/Test App")
            try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: heuristic, withIntermediateDirectories: true)

            fs = RecordingFileSystem()
            router = DenyingCapabilityRouter()
            let service = UninstallerService(fs: fs, safety: AllowAllSafety(), home: home,
                                             entitlementReader: EmptyEntitlements(),
                                             launchAgentReader: EmptyLaunchAgents())
            let sampler = RecordingSampler()
            let capability = UninstallCapabilityController(
                issuer: DestructiveOperationIssuer(sampler: sampler,
                                                    ledger: AuthorizationLedger()))
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
            _ = capability // compile-level coverage for the production Task 1 adapter
            model = UninstallerModel(env: environment)
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

    func testModelRoutesConfirmationThroughCapabilityBeforeCleaningEngine() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        fixture.model.select(fixture.app)
        try await waitUntil { !fixture.model.targets.isEmpty }

        fixture.model.uninstall()
        try await waitUntil { fixture.router.calls == 1 && !fixture.model.working }

        XCTAssertEqual(fixture.router.calls, 1)
        XCTAssertTrue(fixture.fs.trashed.isEmpty,
                      "failed-closed capability must prevent the CleaningEngine closure")
    }

    private func waitUntil(_ predicate: @escaping @MainActor () -> Bool) async throws {
        for _ in 0..<200 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Timed out waiting for model state")
    }
}
