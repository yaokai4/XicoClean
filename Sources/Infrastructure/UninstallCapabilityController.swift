import Foundation
import Domain
#if canImport(Darwin)
import Darwin
#endif

/// The only production bridge from a service-issued uninstall batch to the Task 1
/// destructive-operation capability. The cleaning closure receives its selected payload only
/// after the immutable plan has been prepared and its one-time authorization has been consumed.
public protocol UninstallCapabilityRouting: Sendable {
    func execute(
        batch: UninstallBatch,
        service: UninstallerService,
        operation: @escaping @Sendable ([CleanableItem]) async -> CleaningReport
    ) async throws -> DestructiveExecutionResult<CleaningReport>
}

public struct UninstallCapabilityController: UninstallCapabilityRouting, Sendable {
    private let issuer: DestructiveOperationIssuer
    private let consumptionGate: UninstallBatchConsumptionGate
    private let now: @Sendable () -> Date

    public init(issuer: DestructiveOperationIssuer,
                consumptionGate: UninstallBatchConsumptionGate = UninstallBatchConsumptionGate(),
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.issuer = issuer
        self.consumptionGate = consumptionGate
        self.now = now
    }

    public func execute(
        batch: UninstallBatch,
        service: UninstallerService,
        operation: @escaping @Sendable ([CleanableItem]) async -> CleaningReport
    ) async throws -> DestructiveExecutionResult<CleaningReport> {
        let attemptTime = now()
        guard attemptTime < batch.expiresAt else { throw UninstallPlanError.batchExpired }
        guard await consumptionGate.consume(batch.batchID) else {
            throw UninstallPlanError.batchAlreadyConsumed
        }
        let plan = try service.prepareUninstallPlan(from: batch, using: issuer, now: attemptTime)
        guard let authorization = issuer.authorize(plan, now: attemptTime) else {
            throw UninstallPlanError.authorizationUnavailable
        }
        let selectedItems = batch.selectedItems
        return await issuer.execute(plan, authorization: authorization, now: attemptTime) {
            await operation(selectedItems)
        }
    }
}

public actor UninstallBatchConsumptionGate {
    private var consumed: Set<UUID> = []

    public init() {}

    func consume(_ batchID: UUID) -> Bool {
        consumed.insert(batchID).inserted
    }
}

/// Production stat-backed sampler for Task 1 uninstall plan identities.
public struct LocalFileIdentitySampler: IdentitySampler, Sendable {
    public init() {}

    public func sample(_ canonicalPath: String) -> LocalFileIdentity? {
        #if canImport(Darwin)
        var value = stat()
        guard lstat(canonicalPath, &value) == 0 else { return nil }
        let seconds = Int64(value.st_mtimespec.tv_sec)
        let nanoseconds = Int64(value.st_mtimespec.tv_nsec)
        let (scaledSeconds, overflow) = seconds.multipliedReportingOverflow(by: 1_000_000_000)
        guard !overflow else { return nil }
        let (mtime, additionOverflow) = scaledSeconds.addingReportingOverflow(nanoseconds)
        guard !additionOverflow else { return nil }
        return LocalFileIdentity(
            device: UInt64(value.st_dev),
            inode: UInt64(value.st_ino),
            mode: UInt32(value.st_mode),
            size: Int64(value.st_size),
            mtimeNanoseconds: mtime,
            hardLinkCount: UInt64(value.st_nlink))
        #else
        return nil
        #endif
    }
}
