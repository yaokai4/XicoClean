import Foundation
import Dispatch
import XCTest
@_spi(XicoUninstallExecution) import Domain

final class UninstallExecutionTests: XCTestCase {
    private final class Permit: UninstallExecutionPermit, @unchecked Sendable {}

    private struct AllowAllSafety: SafetyEngine {
        func verify(_ url: URL, intent: DeleteIntent) -> SafetyVerdict { .allow }
    }

    private final class RecordingFileSystem: @unchecked Sendable, FileSystemService {
        private let lock = NSLock()
        private var trashCalls: [String] = []
        private let returnsOriginalReceipt: Bool
        private let onTrash: @Sendable () -> Void

        init(returnsOriginalReceipt: Bool = false,
             onTrash: @escaping @Sendable () -> Void = {}) {
            self.returnsOriginalReceipt = returnsOriginalReceipt
            self.onTrash = onTrash
        }

        var trashedPaths: [String] {
            lock.lock()
            defer { lock.unlock() }
            return trashCalls
        }

        func exists(_ url: URL) -> Bool { true }
        func contentsOfDirectory(_ url: URL) -> [URL] { [] }
        func allocatedSize(of url: URL) -> Int64 { 0 }
        func entry(for url: URL) -> FileEntry? { nil }
        func trash(_ url: URL) throws -> URL {
            onTrash()
            lock.lock()
            trashCalls.append(url.standardizedFileURL.path)
            lock.unlock()
            if returnsOriginalReceipt { return url }
            return URL(fileURLWithPath: "/Trash")
                .appendingPathComponent(url.lastPathComponent)
        }
        func remove(_ url: URL) throws {
            XCTFail("Uninstall execution must never use permanent removal")
        }
        func restore(_ item: RestorableItem) throws -> URL { item.originalURL }
        func volumeCapacity(for url: URL) -> VolumeCapacity? { nil }
        func deepEnumerate(_ url: URL, includeFiles: Bool) -> AsyncStream<FileEntry> {
            AsyncStream { $0.finish() }
        }
    }

    private static let associatedURL = URL(fileURLWithPath: "/tmp/xico-task5-associated")
    private static let bodyURL = URL(fileURLWithPath: "/Applications/XicoTask5.app")
    private static let associatedIdentity = identity(inode: 11, type: 0o040000)
    private static let bodyIdentity = identity(inode: 22, type: 0o040000)

    func testUninstallRouteProducesUninstallKindAndAssociatedTargetsBeforeBody() async throws {
        let fs = RecordingFileSystem()
        let permit = Permit()
        let engine = Self.engine(fs: fs, permit: permit)
        let requests = [
            Self.request(url: Self.associatedURL,
                         identity: Self.associatedIdentity,
                         role: .associatedFile,
                         attribution: .exactBundleIDPath),
            Self.request(url: Self.bodyURL,
                         identity: Self.bodyIdentity,
                         role: .requiredAppBody,
                         attribution: .verifiedAppBody)
        ]

        let report = await engine.executeUninstall(
            requests,
            mode: .uninstallApp,
            permit: permit,
            identitySampler: { path in
                path == Self.bodyURL.path ? Self.bodyIdentity : Self.associatedIdentity
            },
            initialAdmission: { true },
            finalAdmission: { true },
            afterActorAdmission: {})

        let unwrapped = try XCTUnwrap(report)
        XCTAssertEqual(unwrapped.operation.kind, .uninstall)
        XCTAssertEqual(unwrapped.operation.status, .success)
        XCTAssertTrue(unwrapped.isReducerBacked)
        XCTAssertEqual(fs.trashedPaths, [Self.associatedURL.path, Self.bodyURL.path])
        XCTAssertEqual(unwrapped.items.map { $0.url.standardizedFileURL.path },
                       fs.trashedPaths)
        XCTAssertTrue(unwrapped.items.allSatisfy {
            $0.intent == .trash && $0.disposition == .succeeded
                && $0.mutation == .changed && $0.restorable != nil
                && $0.retryAuthorization == nil
        })
    }

    func testExecutionRechecksOwnershipEvidenceAndIdentityBeforeDelete() async throws {
        let fs = RecordingFileSystem()
        let permit = Permit()
        let engine = Self.engine(fs: fs, permit: permit)
        let ownershipChecks = LockedCounter()
        let request = Self.request(
            url: Self.associatedURL,
            identity: Self.associatedIdentity,
            role: .associatedFile,
            attribution: .exactBundleIDPath,
            evidenceAdmission: {
                ownershipChecks.increment()
                return false
            })

        let report = await engine.executeUninstall(
            [request],
            mode: .cleanLeftovers,
            permit: permit,
            identitySampler: { _ in Self.associatedIdentity },
            initialAdmission: { true },
            finalAdmission: { true },
            afterActorAdmission: {})

        let item = try XCTUnwrap(report?.items.first)
        XCTAssertEqual(item.mutation, .none)
        XCTAssertEqual(Self.issue(from: item.disposition)?.code,
                       "uninstall.evidence.changed")
        XCTAssertEqual(Self.issue(from: item.disposition)?.category, .identityChanged)
        XCTAssertTrue(fs.trashedPaths.isEmpty)
        XCTAssertEqual(ownershipChecks.value, 1)
    }

    func testIdentityChangedSinceScanSkipsCandidateAndDoesNotDelete() async throws {
        let fs = RecordingFileSystem()
        let permit = Permit()
        let engine = Self.engine(fs: fs, permit: permit)
        let replacement = Self.identity(inode: 999, type: 0o040000)
        let request = Self.request(url: Self.associatedURL,
                                   identity: Self.associatedIdentity,
                                   role: .associatedFile,
                                   attribution: .exactBundleIDPath)

        let report = await engine.executeUninstall(
            [request], mode: .cleanLeftovers, permit: permit,
            identitySampler: { _ in replacement },
            initialAdmission: { true }, finalAdmission: { true },
            afterActorAdmission: {})

        let item = try XCTUnwrap(report?.items.first)
        XCTAssertEqual(item.mutation, .none)
        XCTAssertEqual(Self.issue(from: item.disposition)?.code,
                       "uninstall.identity.changed")
        XCTAssertEqual(Self.issue(from: item.disposition)?.category, .identityChanged)
        XCTAssertTrue(fs.trashedPaths.isEmpty)
    }

    func testIdentityTypeChangedSinceScanFailsClosedWithoutDelete() async throws {
        let fs = RecordingFileSystem()
        let permit = Permit()
        let engine = Self.engine(fs: fs, permit: permit)
        let replacement = Self.identity(inode: Self.associatedIdentity.inode,
                                        type: 0o120000)
        let request = Self.request(url: Self.associatedURL,
                                   identity: Self.associatedIdentity,
                                   role: .associatedFile,
                                   attribution: .exactBundleIDPath)

        let report = await engine.executeUninstall(
            [request], mode: .cleanLeftovers, permit: permit,
            identitySampler: { _ in replacement },
            initialAdmission: { true }, finalAdmission: { true },
            afterActorAdmission: {})

        let item = try XCTUnwrap(report?.items.first)
        XCTAssertEqual(item.mutation, .none)
        XCTAssertEqual(Self.issue(from: item.disposition)?.code,
                       "uninstall.identity.changed")
        XCTAssertTrue(fs.trashedPaths.isEmpty)
    }

    func testRequiredBodyDisappearanceIsIdentityFailureNotUnchanged() async throws {
        let fs = RecordingFileSystem()
        let permit = Permit()
        let engine = Self.engine(fs: fs, permit: permit)
        let request = Self.request(url: Self.bodyURL,
                                   identity: Self.bodyIdentity,
                                   role: .requiredAppBody,
                                   attribution: .verifiedAppBody)

        let report = await engine.executeUninstall(
            [request], mode: .uninstallApp, permit: permit,
            identitySampler: { _ in nil },
            initialAdmission: { true }, finalAdmission: { true },
            afterActorAdmission: {})

        let item = try XCTUnwrap(report?.items.first)
        XCTAssertNotEqual(item.disposition, .unchanged)
        XCTAssertEqual(item.mutation, .none)
        XCTAssertEqual(Self.issue(from: item.disposition)?.code,
                       "uninstall.identity.changed")
        XCTAssertEqual(report?.operation.status, .failure)
        XCTAssertTrue(fs.trashedPaths.isEmpty)
    }

    func testFinalLifetimeAdmissionIsCheckedForEverySideEffect() async throws {
        let fs = RecordingFileSystem()
        let permit = Permit()
        let engine = Self.engine(fs: fs, permit: permit)
        let admissions = LockedCounter()
        let request = Self.request(url: Self.associatedURL,
                                   identity: Self.associatedIdentity,
                                   role: .associatedFile,
                                   attribution: .exactBundleIDPath)

        let report = await engine.executeUninstall(
            [request], mode: .cleanLeftovers, permit: permit,
            identitySampler: { _ in Self.associatedIdentity },
            initialAdmission: { true },
            finalAdmission: {
                admissions.increment()
                return false
            },
            afterActorAdmission: {})

        let item = try XCTUnwrap(report?.items.first)
        XCTAssertEqual(Self.issue(from: item.disposition)?.code,
                       "uninstall.execution.expired")
        XCTAssertEqual(item.mutation, .none)
        XCTAssertEqual(admissions.value, 1)
        XCTAssertTrue(fs.trashedPaths.isEmpty)
    }

    func testExpiryAfterFirstAssociatedStopsRemainingTargetsAndBody() async throws {
        let fs = RecordingFileSystem()
        let permit = Permit()
        let engine = Self.engine(fs: fs, permit: permit)
        let admissions = LockedCounter()
        let requests = [
            Self.request(url: Self.associatedURL,
                         identity: Self.associatedIdentity,
                         role: .associatedFile,
                         attribution: .exactBundleIDPath),
            Self.request(url: Self.bodyURL,
                         identity: Self.bodyIdentity,
                         role: .requiredAppBody,
                         attribution: .verifiedAppBody)
        ]

        let report = await engine.executeUninstall(
            requests, mode: .uninstallApp, permit: permit,
            identitySampler: { path in
                path == Self.bodyURL.path ? Self.bodyIdentity : Self.associatedIdentity
            },
            initialAdmission: { true },
            finalAdmission: {
                admissions.increment()
                return admissions.value == 1
            },
            afterActorAdmission: {})

        let unwrapped = try XCTUnwrap(report)
        XCTAssertEqual(fs.trashedPaths, [Self.associatedURL.path])
        XCTAssertEqual(unwrapped.operation.status, .partial)
        XCTAssertEqual(Self.issue(from: unwrapped.items.last!.disposition)?.code,
                       "uninstall.execution.expired")
        XCTAssertEqual(unwrapped.items.last?.mutation, OperationMutationFact.none)
    }

    func testInvalidSamePathTrashReceiptIsPossiblyChangedNotSuccess() async throws {
        let fs = RecordingFileSystem(returnsOriginalReceipt: true)
        let permit = Permit()
        let engine = Self.engine(fs: fs, permit: permit)
        let request = Self.request(url: Self.associatedURL,
                                   identity: Self.associatedIdentity,
                                   role: .associatedFile,
                                   attribution: .exactBundleIDPath)

        let report = await engine.executeUninstall(
            [request], mode: .cleanLeftovers, permit: permit,
            identitySampler: { _ in Self.associatedIdentity },
            initialAdmission: { true }, finalAdmission: { true },
            afterActorAdmission: {})

        let item = try XCTUnwrap(report?.items.first)
        XCTAssertEqual(item.mutation, .possiblyChanged)
        XCTAssertNil(item.restorable)
        XCTAssertEqual(item.reclaimedBytes, 0)
        XCTAssertEqual(Self.issue(from: item.disposition)?.code,
                       "uninstall.trash.invalidReceipt")
        XCTAssertEqual(report?.operation.status, .failure)
    }

    func testFinalGateOrderIsEvidenceThenIdentityThenLifetimeThenTrash() async throws {
        let events = LockedEvents()
        let fs = RecordingFileSystem(onTrash: { events.append("trash") })
        let permit = Permit()
        let engine = Self.engine(fs: fs, permit: permit)
        let request = Self.request(
            url: Self.associatedURL,
            identity: Self.associatedIdentity,
            role: .associatedFile,
            attribution: .exactBundleIDPath,
            evidenceAdmission: {
                events.append("evidence")
                return true
            })

        _ = await engine.executeUninstall(
            [request], mode: .cleanLeftovers, permit: permit,
            identitySampler: { _ in
                events.append("identity")
                return Self.associatedIdentity
            },
            initialAdmission: { true },
            finalAdmission: {
                events.append("lifetime")
                return true
            },
            afterActorAdmission: {})

        XCTAssertEqual(events.values, ["evidence", "identity", "lifetime", "trash"])
    }

    func testCancellationAfterAssociatedTargetLeavesRequiredBodyUnmutated() async throws {
        let enteredTrash = LockedCounter()
        let releaseTrash = DispatchSemaphore(value: 0)
        let fs = RecordingFileSystem(onTrash: {
            enteredTrash.increment()
            _ = releaseTrash.wait(timeout: .now() + 2)
        })
        let permit = Permit()
        let engine = Self.engine(fs: fs, permit: permit)
        let requests = [
            Self.request(url: Self.associatedURL,
                         identity: Self.associatedIdentity,
                         role: .associatedFile,
                         attribution: .exactBundleIDPath),
            Self.request(url: Self.bodyURL,
                         identity: Self.bodyIdentity,
                         role: .requiredAppBody,
                         attribution: .verifiedAppBody)
        ]
        let identitySampler: @Sendable (String) -> LocalFileIdentity? = { path in
            path == Self.bodyURL.path ? Self.bodyIdentity : Self.associatedIdentity
        }
        let initialAdmission: @Sendable () async -> Bool = { true }
        let finalAdmission: @Sendable () -> Bool = { true }
        let afterActorAdmission: @Sendable () async -> Void = {}

        let execution: Task<CleaningReport?, Never> = Task.detached {
            await engine.executeUninstall(
                requests, mode: .uninstallApp, permit: permit,
                identitySampler: identitySampler,
                initialAdmission: initialAdmission,
                finalAdmission: finalAdmission,
                afterActorAdmission: afterActorAdmission)
        }
        for _ in 0..<2_000 where enteredTrash.value == 0 {
            try await Task.sleep(for: .milliseconds(1))
        }
        XCTAssertEqual(enteredTrash.value, 1,
                       "associated target must enter the non-mutating Trash fake")
        execution.cancel()
        releaseTrash.signal()
        let executionValue = await execution.value
        let report = try XCTUnwrap(executionValue)

        XCTAssertEqual(fs.trashedPaths, [Self.associatedURL.path])
        XCTAssertEqual(report.operation.status, .cancelled)
        let body = try XCTUnwrap(report.items.last)
        if case .cancelled = body.disposition {
            XCTAssertEqual(body.mutation, .none)
        } else {
            XCTFail("the required body must be cancelled without mutation")
        }
    }

    func testRequiredAppBodyCannotBeExecutedAsDeselected() async {
        let fs = RecordingFileSystem()
        let permit = Permit()
        let engine = Self.engine(fs: fs, permit: permit)
        let request = Self.request(url: Self.bodyURL,
                                   identity: Self.bodyIdentity,
                                   role: .requiredAppBody,
                                   attribution: .verifiedAppBody,
                                   isSelected: false)

        let report = await engine.executeUninstall(
            [request], mode: .uninstallApp, permit: permit,
            identitySampler: { _ in Self.bodyIdentity },
            initialAdmission: { true }, finalAdmission: { true },
            afterActorAdmission: {})

        XCTAssertNil(report)
        XCTAssertTrue(fs.trashedPaths.isEmpty)
    }

    func testUninstallPermitIsBoundToTheExactCleaningEngineInstance() async {
        let fs = RecordingFileSystem()
        let boundPermit = Permit()
        let foreignPermit = Permit()
        let engine = Self.engine(fs: fs, permit: boundPermit)
        let samplerCalls = LockedCounter()
        let evidenceCalls = LockedCounter()
        let request = Self.request(
            url: Self.associatedURL,
            identity: Self.associatedIdentity,
            role: .associatedFile,
            attribution: .exactBundleIDPath,
            evidenceAdmission: {
                evidenceCalls.increment()
                return true
            })

        let report = await engine.executeUninstall(
            [request], mode: .cleanLeftovers, permit: foreignPermit,
            identitySampler: { _ in
                samplerCalls.increment()
                return Self.associatedIdentity
            },
            initialAdmission: { true }, finalAdmission: { true },
            afterActorAdmission: {})

        XCTAssertNil(report)
        XCTAssertEqual(evidenceCalls.value, 0)
        XCTAssertEqual(samplerCalls.value, 0)
        XCTAssertTrue(fs.trashedPaths.isEmpty)
    }

    func testPublicCleaningEngineHasNoUninstallCapability() async {
        let fs = RecordingFileSystem()
        let permit = Permit()
        let engine = CleaningEngine(safety: AllowAllSafety(), fs: fs)
        let admissionCalls = LockedCounter()
        let request = Self.request(url: Self.associatedURL,
                                   identity: Self.associatedIdentity,
                                   role: .associatedFile,
                                   attribution: .exactBundleIDPath)

        let report = await engine.executeUninstall(
            [request], mode: .cleanLeftovers, permit: permit,
            identitySampler: { _ in Self.associatedIdentity },
            initialAdmission: {
                admissionCalls.increment()
                return true
            },
            finalAdmission: { true },
            afterActorAdmission: {})

        XCTAssertNil(report)
        XCTAssertEqual(admissionCalls.value, 0)
        XCTAssertTrue(fs.trashedPaths.isEmpty)
    }

    func testPayloadOrderCountAndDuplicateSubstitutionFailClosed() async {
        let cases: [[UninstallExecutionRequest]] = [
            [Self.request(url: Self.bodyURL,
                          identity: Self.bodyIdentity,
                          role: .requiredAppBody,
                          attribution: .verifiedAppBody),
             Self.request(url: Self.associatedURL,
                          identity: Self.associatedIdentity,
                          role: .associatedFile,
                          attribution: .exactBundleIDPath)],
            [Self.request(url: Self.associatedURL,
                          identity: Self.associatedIdentity,
                          role: .associatedFile,
                          attribution: .exactBundleIDPath)],
            {
                let id = UUID()
                return [Self.request(requestID: id,
                                     url: Self.associatedURL,
                                     identity: Self.associatedIdentity,
                                     role: .associatedFile,
                                     attribution: .exactBundleIDPath),
                        Self.request(requestID: id,
                                     url: Self.bodyURL,
                                     identity: Self.bodyIdentity,
                                     role: .requiredAppBody,
                                     attribution: .verifiedAppBody)]
            }()
        ]

        for requests in cases {
            let fs = RecordingFileSystem()
            let permit = Permit()
            let engine = Self.engine(fs: fs, permit: permit)
            let report = await engine.executeUninstall(
                requests, mode: .uninstallApp, permit: permit,
                identitySampler: { path in
                    path == Self.bodyURL.path ? Self.bodyIdentity : Self.associatedIdentity
                },
                initialAdmission: { true }, finalAdmission: { true },
                afterActorAdmission: {})
            XCTAssertNil(report)
            XCTAssertTrue(fs.trashedPaths.isEmpty)
        }
    }

    private static func request(
        requestID: UUID = UUID(),
        url: URL,
        identity: LocalFileIdentity,
        role: UninstallExecutionRole,
        attribution: AttributionEvidence,
        isSelected: Bool = true,
        evidenceAdmission: @escaping @Sendable () -> Bool = { true }
    ) -> UninstallExecutionRequest {
        let fingerprint = EvidenceFingerprint(
            sha256: Array(repeating: UInt8(identity.inode & 0xff), count: 32))!
        let item = CleanableItem(
            url: url,
            displayName: url.lastPathComponent,
            size: 100,
            safety: .safe,
            isSelected: isSelected)
        let target = PlannedTarget(
            canonicalPath: url.standardizedFileURL.path,
            identity: identity,
            recoverability: .trashRestorable,
            riskLevel: .low,
            attribution: attribution,
            evidenceFingerprint: fingerprint)
        return UninstallExecutionRequest(
            requestID: requestID,
            item: item,
            plannedTarget: target,
            role: role,
            evidenceAdmission: evidenceAdmission)
    }

    private static func engine(
        fs: FileSystemService,
        permit: any UninstallExecutionPermit
    ) -> CleaningEngine {
        CleaningEngine(
            safety: AllowAllSafety(),
            fs: fs,
            uninstallExecutionPermit: permit)
    }

    private static func identity(inode: UInt64, type: UInt32) -> LocalFileIdentity {
        LocalFileIdentity(device: 7,
                          inode: inode,
                          mode: type | 0o755,
                          size: 100,
                          mtimeNanoseconds: 1,
                          changeTimeNanoseconds: 1,
                          hardLinkCount: 1)
    }

    private static func issue(from disposition: OperationDisposition) -> OperationIssue? {
        switch disposition {
        case .failed(let issue), .skipped(let issue): return issue
        case .cancelled(let issue): return issue
        case .succeeded, .unchanged: return nil
        }
    }
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0

    func increment() {
        lock.lock()
        storage += 1
        lock.unlock()
    }

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

private final class LockedEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    func append(_ value: String) {
        lock.lock()
        storage.append(value)
        lock.unlock()
    }

    var values: [String] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}
