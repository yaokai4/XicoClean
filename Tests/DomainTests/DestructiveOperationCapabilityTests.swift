import XCTest
@testable import Domain

final class DestructiveOperationCapabilityTests: XCTestCase {

    // MARK: - Fixtures

    private struct FakeSampler: IdentitySampler {
        var table: [String: LocalFileIdentity]
        func sample(_ canonicalPath: String) -> LocalFileIdentity? { table[canonicalPath] }
    }

    private actor Counter {
        private(set) var value = 0
        func increment() { value += 1 }
        func snapshot() -> Int { value }
    }

    private func identity(inode: UInt64 = 100,
                          hardLinkCount: UInt64 = 1,
                          size: Int64 = 4_096,
                          mtime: Int64 = 111) -> LocalFileIdentity {
        LocalFileIdentity(device: 1,
                          inode: inode,
                          mode: 0o100_644,
                          size: size,
                          mtimeNanoseconds: mtime,
                          hardLinkCount: hardLinkCount)
    }

    private func request(_ path: String,
                         recoverability: Recoverability = .irreversible,
                         riskLevel: RiskLevel = .high,
                         attribution: AttributionEvidence = .userSelected) -> TargetRequest {
        TargetRequest(canonicalPath: path,
                      recoverability: recoverability,
                      riskLevel: riskLevel,
                      attribution: attribution)
    }

    private func issuer(_ table: [String: LocalFileIdentity],
                        ledger: AuthorizationLedger = AuthorizationLedger()) -> DestructiveOperationIssuer {
        DestructiveOperationIssuer(sampler: FakeSampler(table: table), ledger: ledger)
    }

    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    // MARK: - Plan / identity / expiry

    func testPrepareProducesImmutablePlanWithIdentitySnapshotAndExpiry() throws {
        let id = identity(inode: 42, hardLinkCount: 1)
        let sut = issuer(["/a": id])
        let plan = sut.prepare(kind: .shred, targets: [request("/a")], now: t0)

        XCTAssertEqual(plan.kind, .shred)
        XCTAssertEqual(plan.createdAt, t0)
        XCTAssertEqual(plan.targets.count, 1)
        XCTAssertEqual(plan.targets[0].canonicalPath, "/a")
        XCTAssertEqual(plan.targets[0].identity, id)
        XCTAssertEqual(plan.expiresAt, t0.addingTimeInterval(300))
        XCTAssertFalse(plan.digest.bytes.isEmpty)
    }

    func testLocalAuthorizationExpiresAtFiveMinutes() throws {
        let sut = issuer(["/a": identity()])
        let plan = sut.prepare(kind: .uninstall, targets: [request("/a")], now: t0)
        XCTAssertEqual(plan.expiresAt.timeIntervalSince(plan.createdAt), 300, accuracy: 0.0001)
        XCTAssertEqual(DestructiveOperationIssuer.localTimeToLive, 300)
    }

    func testPlanCarriesRiskLevelAndRecoverability() throws {
        let sut = issuer(["/a": identity()])
        let plan = sut.prepare(
            kind: .spaceTrash,
            targets: [request("/a", recoverability: .trashRestorable, riskLevel: .low)],
            now: t0)
        XCTAssertEqual(plan.targets[0].recoverability, .trashRestorable)
        XCTAssertEqual(plan.targets[0].riskLevel, .low)
    }

    func testLocalFileIdentityIncludesHardLinkCountForShredKind() throws {
        let id = identity(inode: 7, hardLinkCount: 3)
        XCTAssertEqual(id.hardLinkCount, 3)
        let sut = issuer(["/hl": id])
        let plan = sut.prepare(kind: .shred, targets: [request("/hl")], now: t0)
        XCTAssertEqual(plan.targets[0].identity?.hardLinkCount, 3)
    }

    // MARK: - Canonical digest

    func testCanonicalDigestIsDeterministicAcrossDictionaryOrderAndLocale() throws {
        let table = ["/a": identity(inode: 1), "/b": identity(inode: 2)]
        let sut = issuer(table)
        let planForward = sut.prepare(kind: .shred, targets: [request("/a"), request("/b")], now: t0)
        let planReversed = sut.prepare(kind: .shred, targets: [request("/b"), request("/a")], now: t0)
        XCTAssertEqual(planForward.digest, planReversed.digest)
    }

    func testCanonicalDigestIsVersionedAndChangesWhenSchemaVersionChanges() throws {
        let targets = [PlannedTarget(canonicalPath: "/a",
                                     identity: identity(),
                                     recoverability: .irreversible,
                                     riskLevel: .high,
                                     attribution: .userSelected)]
        let encoded = PlanDigest.canonicalBytes(kind: .shred, targets: targets)
        XCTAssertEqual(encoded.first, PlanDigest.schemaVersion)

        let v1 = PlanDigest.compute(kind: .shred, targets: targets, version: 1)
        let v2 = PlanDigest.compute(kind: .shred, targets: targets, version: 2)
        XCTAssertNotEqual(v1, v2)
    }

    func testDigestChangesWhenAnyTargetIdentityOrPathChanges() throws {
        let base = [PlannedTarget(canonicalPath: "/a", identity: identity(inode: 1),
                                  recoverability: .irreversible, riskLevel: .high, attribution: .userSelected)]
        let changedPath = [PlannedTarget(canonicalPath: "/b", identity: identity(inode: 1),
                                         recoverability: .irreversible, riskLevel: .high, attribution: .userSelected)]
        let changedIdentity = [PlannedTarget(canonicalPath: "/a", identity: identity(inode: 999),
                                             recoverability: .irreversible, riskLevel: .high, attribution: .userSelected)]
        let baseDigest = PlanDigest.compute(kind: .shred, targets: base)
        XCTAssertNotEqual(baseDigest, PlanDigest.compute(kind: .shred, targets: changedPath))
        XCTAssertNotEqual(baseDigest, PlanDigest.compute(kind: .shred, targets: changedIdentity))
    }

    // MARK: - Authorization binding

    func testAuthorizationBindsPlanIDDigestNonceExpiryAndKind() throws {
        let sut = issuer(["/a": identity()])
        let plan = sut.prepare(kind: .shred, targets: [request("/a")], now: t0)
        let auth = try XCTUnwrap(sut.authorize(plan, now: t0))
        XCTAssertEqual(auth.planID, plan.planID)
        XCTAssertEqual(auth.digest, plan.digest)
        XCTAssertEqual(auth.kind, plan.kind)
        XCTAssertEqual(auth.expiresAt, plan.expiresAt)
    }

    func testAuthorizationInitializerIsNotReachableOutsideIssuer() throws {
        // The `Authorization` initializer is `fileprivate`, so even this `@testable`
        // module cannot fabricate one — the only path to a capability object is
        // `issuer.authorize(...)`. This asserts that single legitimate path works.
        let sut = issuer(["/a": identity()])
        let plan = sut.prepare(kind: .shred, targets: [request("/a")], now: t0)
        XCTAssertNotNil(sut.authorize(plan, now: t0))
    }

    // MARK: - Nonce lifecycle

    func testNonceIsConsumedExactlyOnceAndReplayFailsClosed() async throws {
        let sut = issuer(["/a": identity()])
        let plan = sut.prepare(kind: .shred, targets: [request("/a")], now: t0)
        let auth = try XCTUnwrap(sut.authorize(plan, now: t0))

        let first = await sut.execute(plan, authorization: auth, now: t0) { true }
        let second = await sut.execute(plan, authorization: auth, now: t0) { true }

        XCTAssertEqual(executedValue(first), true)
        XCTAssertEqual(failure(second), .nonceAlreadyConsumed)
    }

    func testConcurrentExecuteConsumesNonceExactlyOnceOthersFailClosed() async throws {
        let sut = issuer(["/a": identity()])
        let plan = sut.prepare(kind: .shred, targets: [request("/a")], now: t0)
        let auth = try XCTUnwrap(sut.authorize(plan, now: t0))
        let counter = Counter()
        let now = t0

        let results = await withTaskGroup(of: DestructiveExecutionResult<Bool>.self) { group in
            for _ in 0..<24 {
                group.addTask {
                    await sut.execute(plan, authorization: auth, now: now) {
                        await counter.increment()
                        return true
                    }
                }
            }
            var all: [DestructiveExecutionResult<Bool>] = []
            for await r in group { all.append(r) }
            return all
        }

        let executed = results.filter { if case .executed = $0 { return true } else { return false } }
        let rejected = results.filter { failure($0) == .nonceAlreadyConsumed }
        XCTAssertEqual(executed.count, 1)
        XCTAssertEqual(rejected.count, 23)
        let bodyRuns = await counter.snapshot()
        XCTAssertEqual(bodyRuns, 1)
    }

    func testExecuteInvokesSideEffectClosureOnlyAfterNonceConsumed() async throws {
        let sut = issuer(["/a": identity()])
        let plan = sut.prepare(kind: .shred, targets: [request("/a")], now: t0)
        let auth = try XCTUnwrap(sut.authorize(plan, now: t0))
        let counter = Counter()

        let ok = await sut.execute(plan, authorization: auth, now: t0) {
            await counter.increment(); return true
        }
        XCTAssertEqual(executedValue(ok), true)
        // Replay: nonce already consumed, closure must not run again.
        _ = await sut.execute(plan, authorization: auth, now: t0) {
            await counter.increment(); return true
        }
        let sideEffects = await counter.snapshot()
        XCTAssertEqual(sideEffects, 1)
    }

    func testLateCancelAfterTerminalDoesNotRewriteOutcome() async throws {
        let sut = issuer(["/a": identity()])
        let plan = sut.prepare(kind: .shred, targets: [request("/a")], now: t0)
        let auth = try XCTUnwrap(sut.authorize(plan, now: t0))
        let counter = Counter()

        let terminal = await sut.execute(plan, authorization: auth, now: t0) {
            await counter.increment(); return "done"
        }
        XCTAssertEqual(executedValue(terminal), "done")
        // A later attempt (e.g. a late cancel/retry re-driving execute) cannot rewrite
        // the terminal: the nonce is spent and the body never re-runs.
        let late = await sut.execute(plan, authorization: auth, now: t0) {
            await counter.increment(); return "rewritten"
        }
        XCTAssertEqual(failure(late), .nonceAlreadyConsumed)
        let sideEffects = await counter.snapshot()
        XCTAssertEqual(sideEffects, 1)
    }

    // MARK: - Fail-closed validation

    func testExpiredAuthorizationFailsClosedBeforeAnySideEffect() async throws {
        let sut = issuer(["/a": identity()])
        let plan = sut.prepare(kind: .shred, targets: [request("/a")], now: t0)
        let auth = try XCTUnwrap(sut.authorize(plan, now: t0))
        let counter = Counter()

        let result = await sut.execute(plan, authorization: auth, now: t0.addingTimeInterval(301)) {
            await counter.increment(); return true
        }
        XCTAssertEqual(failure(result), .expired)
        let sideEffects = await counter.snapshot()
        XCTAssertEqual(sideEffects, 0)
    }

    func testDigestMismatchFailsClosed() async throws {
        let sut = issuer(["/a": identity()])
        let plan = sut.prepare(kind: .shred, targets: [request("/a")], now: t0)
        let auth = try XCTUnwrap(sut.authorize(plan, now: t0))
        let counter = Counter()

        // A tampered plan: same id/kind, but different targets ⇒ different digest.
        let tamperedDigest = PlanDigest.compute(kind: .shred, targets: [
            PlannedTarget(canonicalPath: "/evil", identity: identity(inode: 5),
                          recoverability: .irreversible, riskLevel: .high, attribution: .userSelected)
        ])
        let tampered = DestructivePlan(planID: plan.planID, kind: plan.kind,
                                       createdAt: plan.createdAt, expiresAt: plan.expiresAt,
                                       targets: plan.targets, digest: tamperedDigest)

        let result = await sut.execute(tampered, authorization: auth, now: t0) {
            await counter.increment(); return true
        }
        XCTAssertEqual(failure(result), .digestMismatch)
        let sideEffects = await counter.snapshot()
        XCTAssertEqual(sideEffects, 0)
    }

    func testKindMismatchBetweenPlanAndAuthorizationFailsClosed() async throws {
        let sut = issuer(["/a": identity()])
        let plan = sut.prepare(kind: .shred, targets: [request("/a")], now: t0)
        let auth = try XCTUnwrap(sut.authorize(plan, now: t0))
        let counter = Counter()

        // A tampered plan with the authorization's id and digest but a different kind.
        let tampered = DestructivePlan(planID: plan.planID, kind: .uninstall,
                                       createdAt: plan.createdAt, expiresAt: plan.expiresAt,
                                       targets: plan.targets, digest: plan.digest)

        let result = await sut.execute(tampered, authorization: auth, now: t0) {
            await counter.increment(); return true
        }
        XCTAssertEqual(failure(result), .kindMismatch)
        let sideEffects = await counter.snapshot()
        XCTAssertEqual(sideEffects, 0)
    }

    // MARK: - Result helpers

    private func failure<R>(_ result: DestructiveExecutionResult<R>) -> DestructiveAuthorizationFailure? {
        if case .failedClosed(let f) = result { return f }
        return nil
    }

    private func executedValue<R>(_ result: DestructiveExecutionResult<R>) -> R? {
        if case .executed(let value) = result { return value }
        return nil
    }
}
