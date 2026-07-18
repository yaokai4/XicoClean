import Foundation
import Domain
import Dispatch
#if canImport(Darwin)
import Darwin
#endif

package protocol UninstallTrustedClock: Sendable {
    func wallNow() -> Date
    func monotonicNowNanoseconds() -> UInt64
}

package struct SystemUninstallTrustedClock: UninstallTrustedClock, Sendable {
    package init() {}
    package func wallNow() -> Date { Date() }
    package func monotonicNowNanoseconds() -> UInt64 {
        DispatchTime.now().uptimeNanoseconds
    }
}

enum UninstallBatchClaimOutcome: Sendable, Equatable {
    case claimed
    case alreadyClaimed
    case notYetValid
    case expired
}

private struct UninstallBatchLifetimeWindow: Sendable {
    let clock: any UninstallTrustedClock
    let issuedAtNanoseconds: UInt64
    let deadlineNanoseconds: UInt64

    func monotonicFailureFresh() -> UninstallBatchClaimOutcome? {
        let now = clock.monotonicNowNanoseconds()
        guard now >= issuedAtNanoseconds else { return .notYetValid }
        guard now < deadlineNanoseconds else { return .expired }
        return nil
    }

    /// Synchronous final gate used only after the CleaningEngine actor has been reacquired.
    /// Wall time is checked first and the authoritative monotonic deadline is read last, so
    /// neither actor reentrancy nor a wall-clock rollback can reuse a stale admission result.
    func executionFailureFresh(createdAt: Date,
                               expiresAt: Date) -> UninstallBatchClaimOutcome? {
        let wall = clock.wallNow()
        guard createdAt <= wall else { return .notYetValid }
        guard wall < expiresAt else { return .expired }
        return monotonicFailureFresh()
    }
}

actor UninstallBatchClaimToken {
    nonisolated private let lifetimeWindow: UninstallBatchLifetimeWindow
    private var claimed = false

    static func make(clock: any UninstallTrustedClock,
                     issuedAtNanoseconds: UInt64,
                     lifetimeNanoseconds: UInt64) -> UninstallBatchClaimToken? {
        let (deadline, overflow) = issuedAtNanoseconds.addingReportingOverflow(
            lifetimeNanoseconds)
        guard !overflow else { return nil }
        return UninstallBatchClaimToken(lifetimeWindow: UninstallBatchLifetimeWindow(
            clock: clock,
            issuedAtNanoseconds: issuedAtNanoseconds,
            deadlineNanoseconds: deadline))
    }

    static func failClosedExpired(clock: any UninstallTrustedClock) -> UninstallBatchClaimToken {
        UninstallBatchClaimToken(lifetimeWindow: UninstallBatchLifetimeWindow(
            clock: clock, issuedAtNanoseconds: 0, deadlineNanoseconds: 0))
    }

    private init(lifetimeWindow: UninstallBatchLifetimeWindow) {
        self.lifetimeWindow = lifetimeWindow
    }

    func lifetimeFresh() -> UninstallBatchClaimOutcome {
        if let failure = lifetimeWindow.monotonicFailureFresh() { return failure }
        return claimed ? .alreadyClaimed : .claimed
    }

    func lifetimeFailureFresh() -> UninstallBatchClaimOutcome? {
        lifetimeWindow.monotonicFailureFresh()
    }

    func isClaimedAndExecutionFresh(createdAt: Date, expiresAt: Date) -> Bool {
        claimed && lifetimeWindow.executionFailureFresh(
            createdAt: createdAt, expiresAt: expiresAt) == nil
    }

    nonisolated func executionLifetimeFailureFreshSynchronously(
        createdAt: Date,
        expiresAt: Date
    ) -> UninstallBatchClaimOutcome? {
        lifetimeWindow.executionFailureFresh(createdAt: createdAt, expiresAt: expiresAt)
    }

    func claimFresh() -> UninstallBatchClaimOutcome {
        switch lifetimeFresh() {
        case .claimed:
            claimed = true
            return .claimed
        case .alreadyClaimed:
            return .alreadyClaimed
        case .notYetValid:
            return .notYetValid
        case .expired:
            return .expired
        }
    }
}

package struct UninstallConfirmationSummary: Sendable, Equatable {
    package let appName: String
    package let selectedCount: Int
    package let selectedSize: Int64
}

/// Opaque, immutable review context. Features can display only the frozen summary and can execute
/// only through the router that reopens the exact batch with its exact issuing service.
package struct UninstallConfirmation: Sendable, Identifiable, Equatable {
    package let id: UUID
    package let summary: UninstallConfirmationSummary
    fileprivate let batch: UninstallBatch
    fileprivate let service: UninstallerService

    package var appName: String { summary.appName }
    package var selectedCount: Int { summary.selectedCount }
    package var selectedSize: Int64 { summary.selectedSize }

    init(batch: UninstallBatch, service: UninstallerService) {
        self.id = UUID()
        self.summary = UninstallConfirmationSummary(
            appName: batch.app.name,
            selectedCount: batch.selectedCount,
            selectedSize: batch.selectedSize)
        self.batch = batch
        self.service = service
    }

    package static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
}

/// The only package bridge from a service-issued uninstall confirmation to the Task 1
/// destructive-operation capability. Infrastructure's fixed payload executor receives the sealed
/// preparation only after one-time authorization; Features never receives or substitutes it.
package protocol UninstallCapabilityRouting: Sendable {
    func beginConfirmation(for batch: UninstallBatch) -> UninstallConfirmation

    func execute(confirmation: UninstallConfirmation) async throws
        -> DestructiveExecutionResult<CleaningReport>
}

/// Internal Task 4→Task 5 handoff. Features never receives the sealed payload and cannot replace
/// its side effect with an unrelated cleaning plan.
protocol UninstallPayloadExecuting: Sendable {
    func execute(
        _ prepared: PreparedUninstallExecution,
        admission: @escaping @Sendable () async -> Bool
    ) async -> CleaningReport?
}

struct CleaningEngineUninstallPayloadExecutor: UninstallPayloadExecuting, Sendable {
    let engine: CleaningEngine
    let beforeActorHop: @Sendable () -> Void
    let afterActorAdmission: @Sendable () async -> Void

    init(engine: CleaningEngine,
         beforeActorHop: @escaping @Sendable () -> Void = {},
         afterActorAdmission: @escaping @Sendable () async -> Void = {}) {
        self.engine = engine
        self.beforeActorHop = beforeActorHop
        self.afterActorAdmission = afterActorAdmission
    }

    func execute(
        _ prepared: PreparedUninstallExecution,
        admission: @escaping @Sendable () async -> Bool
    ) async -> CleaningReport? {
        beforeActorHop()
        return await engine.executeUninstallPayload(
            prepared,
            admission: admission,
            afterActorAdmission: afterActorAdmission)
    }
}

extension CleaningEngine {
    /// Actor-entry admission for Task 4. Because this method is isolated to `CleaningEngine`, the
    /// exact batch lifetime and prepared seal are checked only after queued work acquires the
    /// engine actor. Task 5 will extend the same permit to each individual filesystem mutation.
    func executeUninstallPayload(
        _ prepared: PreparedUninstallExecution,
        admission: @escaping @Sendable () async -> Bool,
        afterActorAdmission: @escaping @Sendable () async -> Void
    ) async -> CleaningReport? {
        guard await admission() else { return nil }
        await afterActorAdmission()
        guard let items = prepared.selectedItems,
              prepared.batchSnapshot.claimToken
                .executionLifetimeFailureFreshSynchronously(
                    createdAt: prepared.batchSnapshot.createdAt,
                    expiresAt: prepared.batchSnapshot.expiresAt) == nil else { return nil }
        return await execute(CleaningPlan(items: items, intent: .trash))
    }
}

struct UninstallCapabilityHooks: Sendable {
    static let none = UninstallCapabilityHooks()
    let afterReadOnlyPreparation: @Sendable () -> Void
    let afterClaim: @Sendable () -> Void
    let afterAuthorization: @Sendable () -> Void

    init(afterReadOnlyPreparation: @escaping @Sendable () -> Void = {},
         afterClaim: @escaping @Sendable () -> Void = {},
         afterAuthorization: @escaping @Sendable () -> Void = {}) {
        self.afterReadOnlyPreparation = afterReadOnlyPreparation
        self.afterClaim = afterClaim
        self.afterAuthorization = afterAuthorization
    }
}

struct UninstallCapabilityController: UninstallCapabilityRouting, Sendable {
    private let service: UninstallerService
    private let payloadExecutor: any UninstallPayloadExecuting
    private let issuer: DestructiveOperationIssuer
    private let clock: any UninstallTrustedClock
    private let hooks: UninstallCapabilityHooks

    init(service: UninstallerService,
         payloadExecutor: any UninstallPayloadExecuting) {
        let clock = SystemUninstallTrustedClock()
        self.init(
            service: service,
            payloadExecutor: payloadExecutor,
            issuer: DestructiveOperationIssuer(
                sampler: LocalFileIdentitySampler(), ledger: AuthorizationLedger(),
                wallNow: { clock.wallNow() }),
            clock: clock)
    }

    init(service: UninstallerService,
         payloadExecutor: any UninstallPayloadExecuting,
         issuer: DestructiveOperationIssuer,
         clock: any UninstallTrustedClock = SystemUninstallTrustedClock(),
         hooks: UninstallCapabilityHooks = .none) {
        self.service = service
        self.payloadExecutor = payloadExecutor
        self.issuer = issuer
        self.clock = clock
        self.hooks = hooks
    }

    func beginConfirmation(for batch: UninstallBatch) -> UninstallConfirmation {
        UninstallConfirmation(batch: batch, service: service)
    }

    func execute(confirmation: UninstallConfirmation) async throws
        -> DestructiveExecutionResult<CleaningReport> {
        let batch = confirmation.batch
        let prepared = try confirmation.service.prepareUninstallExecution(
            from: batch, using: issuer)
        guard prepared.validateIntegrity() else {
            throw UninstallPlanError.preparedTargetMismatch
        }
        hooks.afterReadOnlyPreparation()

        try validateFreshWallLifetime(of: batch)
        try await validateFreshMonotonicLifetime(of: batch)
        try validateFreshWallLifetime(of: batch)
        guard prepared.validateIntegrity() else {
            throw UninstallPlanError.preparedTargetMismatch
        }

        switch await batch.claimToken.claimFresh() {
        case .claimed:
            break
        case .alreadyClaimed:
            throw UninstallPlanError.batchAlreadyConsumed
        case .notYetValid:
            throw UninstallPlanError.batchNotYetValid
        case .expired:
            throw UninstallPlanError.batchExpired
        }
        hooks.afterClaim()

        try validateFreshWallLifetime(of: batch)
        try await validateFreshMonotonicLifetime(of: batch)
        guard prepared.validateIntegrity() else {
            throw UninstallPlanError.preparedTargetMismatch
        }
        guard let authorization = issuer.authorize(prepared.plan) else {
            throw UninstallPlanError.authorizationUnavailable
        }
        hooks.afterAuthorization()
        try validateFreshWallLifetime(of: batch)
        try await validateFreshMonotonicLifetime(of: batch)
        guard prepared.selectedItems != nil else {
            throw UninstallPlanError.preparedTargetMismatch
        }

        let result: DestructiveExecutionResult<CleaningReport?> = await issuer.execute(
            prepared.plan, authorization: authorization
        ) {
            guard await isWithinFreshMonotonicLifetime(batch),
                  isWithinFreshWallLifetime(batch),
                  prepared.validateIntegrity() else { return nil }
            return await payloadExecutor.execute(prepared) {
                guard await batch.claimToken.isClaimedAndExecutionFresh(
                        createdAt: batch.createdAt, expiresAt: batch.expiresAt),
                      prepared.validateIntegrity() else { return false }
                return true
            }
        }
        switch result {
        case .executed(let report):
            guard let report else { throw UninstallPlanError.batchExpired }
            return .executed(report)
        case .failedClosed(let failure):
            return .failedClosed(failure)
        }
    }

    private func validateFreshWallLifetime(of batch: UninstallBatch) throws {
        let now = clock.wallNow()
        guard batch.createdAt <= now else { throw UninstallPlanError.batchNotYetValid }
        guard now < batch.expiresAt else { throw UninstallPlanError.batchExpired }
    }

    private func validateFreshMonotonicLifetime(of batch: UninstallBatch) async throws {
        switch await batch.claimToken.lifetimeFailureFresh() {
        case nil:
            return
        case .notYetValid:
            throw UninstallPlanError.batchNotYetValid
        case .expired:
            throw UninstallPlanError.batchExpired
        case .claimed, .alreadyClaimed:
            assertionFailure("lifetimeFailureFresh returns only lifetime errors")
            throw UninstallPlanError.batchExpired
        }
    }

    private func isWithinFreshWallLifetime(_ batch: UninstallBatch) -> Bool {
        let now = clock.wallNow()
        return batch.createdAt <= now && now < batch.expiresAt
    }

    private func isWithinFreshMonotonicLifetime(_ batch: UninstallBatch) async -> Bool {
        await batch.claimToken.lifetimeFailureFresh() == nil
    }
}

/// Production stat-backed sampler for Task 1 uninstall plan identities.
public struct LocalFileIdentitySampler: IdentitySampler, Sendable {
    public init() {}

    public func sample(_ canonicalPath: String) -> LocalFileIdentity? {
        #if canImport(Darwin)
        var value = stat()
        guard lstat(canonicalPath, &value) == 0 else { return nil }
        guard let mtime = Self.nanoseconds(value.st_mtimespec),
              let ctime = Self.nanoseconds(value.st_ctimespec) else { return nil }
        return LocalFileIdentity(
            device: UInt64(value.st_dev),
            inode: UInt64(value.st_ino),
            mode: UInt32(value.st_mode),
            size: Int64(value.st_size),
            mtimeNanoseconds: mtime,
            changeTimeNanoseconds: ctime,
            hardLinkCount: UInt64(value.st_nlink))
        #else
        return nil
        #endif
    }

    #if canImport(Darwin)
    private static func nanoseconds(_ value: timespec) -> Int64? {
        let seconds = Int64(value.tv_sec)
        let nanos = Int64(value.tv_nsec)
        let (scaled, overflow) = seconds.multipliedReportingOverflow(by: 1_000_000_000)
        guard !overflow else { return nil }
        let (result, additionOverflow) = scaled.addingReportingOverflow(nanos)
        return additionOverflow ? nil : result
    }
    #endif
}
