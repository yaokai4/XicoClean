import Domain
import Foundation

/// Records consumed one-time authorization nonces. Module-internal so Features cannot mint a
/// parallel ledger and bypass Infrastructure's sealed uninstall preparation and shared claim.
actor AuthorizationLedger {
    private var consumed: Set<UUID> = []
    private let onConsume: @Sendable () -> Void

    init(onConsume: @escaping @Sendable () -> Void = {}) {
        self.onConsume = onConsume
    }

    func consume(_ nonce: UUID) -> Bool {
        let inserted = consumed.insert(nonce).inserted
        if inserted { onConsume() }
        return inserted
    }
}

/// One-time capability minted only by the module-internal issuer.
struct Authorization: Sendable, Equatable {
    let planID: UUID
    let digest: PlanDigest
    let nonce: UUID
    let expiresAt: Date
    let kind: DestructiveKind

    fileprivate init(planID: UUID,
                     digest: PlanDigest,
                     nonce: UUID,
                     expiresAt: Date,
                     kind: DestructiveKind) {
        self.planID = planID
        self.digest = digest
        self.nonce = nonce
        self.expiresAt = expiresAt
        self.kind = kind
    }
}

/// Samples a local identity for a canonical path. Kept module-internal with the issuer so a
/// Features-package client cannot assemble its own destructive capability pipeline.
protocol IdentitySampler: Sendable {
    func sample(_ canonicalPath: String) -> LocalFileIdentity?
}

struct DestructiveOperationIssuer: Sendable {
    static let localTimeToLive: TimeInterval = 5 * 60

    private let sampler: IdentitySampler
    private let ledger: AuthorizationLedger
    private let wallNow: @Sendable () -> Date

    init(sampler: IdentitySampler,
         ledger: AuthorizationLedger,
         wallNow: @escaping @Sendable () -> Date = { Date() }) {
        self.sampler = sampler
        self.ledger = ledger
        self.wallNow = wallNow
    }

    func prepare(kind: DestructiveKind,
                 targets: [TargetRequest]) -> DestructivePlan {
        prepare(kind: kind, targets: targets, at: wallNow())
    }

    func prepare(kind: DestructiveKind,
                 targets: [TargetRequest],
                 now: Date) -> DestructivePlan {
        prepare(kind: kind, targets: targets, at: now)
    }

    private func prepare(kind: DestructiveKind,
                         targets: [TargetRequest],
                         at now: Date) -> DestructivePlan {
        let planned = targets.map { request in
            PlannedTarget(canonicalPath: request.canonicalPath,
                          identity: sampler.sample(request.canonicalPath),
                          recoverability: request.recoverability,
                          riskLevel: request.riskLevel,
                          attribution: request.attribution,
                          evidenceFingerprint: request.evidenceFingerprint)
        }
        let digest = PlanDigest.compute(kind: kind, targets: planned)
        return DestructivePlan(planID: UUID(),
                               kind: kind,
                               createdAt: now,
                               expiresAt: now.addingTimeInterval(Self.localTimeToLive),
                               targets: planned,
                               digest: digest)
    }

    func authorize(_ plan: DestructivePlan) -> Authorization? {
        authorize(plan, at: wallNow())
    }

    func authorize(_ plan: DestructivePlan, now: Date) -> Authorization? {
        authorize(plan, at: now)
    }

    private func authorize(_ plan: DestructivePlan, at now: Date) -> Authorization? {
        guard plan.hasValidCanonicalDigest,
              plan.createdAt <= now,
              now < plan.expiresAt else { return nil }
        if plan.kind == .uninstall {
            guard !plan.targets.isEmpty,
                  plan.targets.allSatisfy({ target in
                      target.identity != nil && target.evidenceFingerprint != .none
                  }) else {
                return nil
            }
        }
        return Authorization(planID: plan.planID,
                             digest: plan.digest,
                             nonce: UUID(),
                             expiresAt: plan.expiresAt,
                             kind: plan.kind)
    }

    func execute<R: Sendable>(
        _ plan: DestructivePlan,
        authorization: Authorization,
        _ body: () async -> R
    ) async -> DestructiveExecutionResult<R> {
        await execute(plan, authorization: authorization, clock: wallNow, body)
    }

    func execute<R: Sendable>(_ plan: DestructivePlan,
                              authorization: Authorization,
                              now: Date,
                              _ body: () async -> R) async -> DestructiveExecutionResult<R> {
        await execute(plan, authorization: authorization, clock: { now }, body)
    }

    private func execute<R: Sendable>(
        _ plan: DestructivePlan,
        authorization: Authorization,
        clock: @Sendable () -> Date,
        _ body: () async -> R
    ) async -> DestructiveExecutionResult<R> {
        guard authorization.planID == plan.planID else { return .failedClosed(.planMismatch) }
        guard authorization.kind == plan.kind else { return .failedClosed(.kindMismatch) }
        guard authorization.digest == plan.digest else { return .failedClosed(.digestMismatch) }
        guard authorization.expiresAt == plan.expiresAt else {
            return .failedClosed(.planMismatch)
        }
        guard plan.hasValidCanonicalDigest else { return .failedClosed(.digestMismatch) }
        let beforeLedger = clock()
        guard plan.createdAt <= beforeLedger,
              beforeLedger < authorization.expiresAt else { return .failedClosed(.expired) }
        guard await ledger.consume(authorization.nonce) else {
            return .failedClosed(.nonceAlreadyConsumed)
        }
        let beforeBody = clock()
        guard plan.createdAt <= beforeBody,
              beforeBody < authorization.expiresAt else { return .failedClosed(.expired) }
        return .executed(await body())
    }
}
