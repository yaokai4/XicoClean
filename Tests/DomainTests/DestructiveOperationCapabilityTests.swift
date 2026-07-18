import XCTest
@testable import Domain
@testable import Infrastructure

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

    private final class MutableWallClock: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Date
        init(_ value: Date) { self.value = value }
        func now() -> Date { lock.withLock { value } }
        func set(_ value: Date) { lock.withLock { self.value = value } }
        func advance(_ interval: TimeInterval) {
            lock.withLock { value = value.addingTimeInterval(interval) }
        }
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

    func testPrepareCarriesChangeTimeAndFixedSHA256EvidenceFingerprint() throws {
        let changeTime: Int64 = 222
        let sealedIdentity = LocalFileIdentity(
            device: 1, inode: 9, mode: 0o100_644, size: 4_096,
            mtimeNanoseconds: 111, changeTimeNanoseconds: changeTime,
            hardLinkCount: 1)
        let fingerprint = try XCTUnwrap(EvidenceFingerprint(sha256: [UInt8](repeating: 0xA5,
                                                                             count: 32)))
        let sealedRequest = TargetRequest(
            canonicalPath: "/sealed",
            recoverability: .trashRestorable,
            riskLevel: .low,
            attribution: .verifiedAppBody,
            evidenceFingerprint: fingerprint)

        let plan = issuer(["/sealed": sealedIdentity]).prepare(
            kind: .uninstall, targets: [sealedRequest], now: t0)

        XCTAssertEqual(plan.targets.first?.identity?.changeTimeNanoseconds, changeTime)
        XCTAssertEqual(plan.targets.first?.evidenceFingerprint, fingerprint)
        XCTAssertEqual(fingerprint.bytes.count, 32)
    }

    func testDigestChangesWhenOnlyChangeTimeOrEvidenceFingerprintChanges() throws {
        let baseIdentity = LocalFileIdentity(
            device: 1, inode: 9, mode: 0o100_644, size: 4_096,
            mtimeNanoseconds: 111, changeTimeNanoseconds: 222,
            hardLinkCount: 1)
        let changedCTime = LocalFileIdentity(
            device: 1, inode: 9, mode: 0o100_644, size: 4_096,
            mtimeNanoseconds: 111, changeTimeNanoseconds: 333,
            hardLinkCount: 1)
        let fingerprintA = try XCTUnwrap(EvidenceFingerprint(
            sha256: [UInt8](repeating: 0x11, count: 32)))
        let fingerprintB = try XCTUnwrap(EvidenceFingerprint(
            sha256: [UInt8](repeating: 0x22, count: 32)))
        func target(_ identity: LocalFileIdentity,
                    _ fingerprint: EvidenceFingerprint) -> PlannedTarget {
            PlannedTarget(canonicalPath: "/sealed", identity: identity,
                          recoverability: .trashRestorable, riskLevel: .low,
                          attribution: .verifiedAppBody,
                          evidenceFingerprint: fingerprint)
        }

        let base = PlanDigest.compute(kind: .uninstall,
                                      targets: [target(baseIdentity, fingerprintA)])
        XCTAssertNotEqual(base, PlanDigest.compute(
            kind: .uninstall, targets: [target(changedCTime, fingerprintA)]))
        XCTAssertNotEqual(base, PlanDigest.compute(
            kind: .uninstall, targets: [target(baseIdentity, fingerprintB)]))
    }

    func testEvidenceFingerprintRejectsNonSHA256LengthsAndHasExplicitNone() {
        XCTAssertNil(EvidenceFingerprint(sha256: [UInt8](repeating: 1, count: 31)))
        XCTAssertNil(EvidenceFingerprint(sha256: [UInt8](repeating: 1, count: 33)))
        XCTAssertTrue(EvidenceFingerprint.none.bytes.isEmpty)
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

    func testAuthorizeRejectsUnsealedUninstallTargetsDefenseInDepth() throws {
        let fingerprint = try XCTUnwrap(EvidenceFingerprint(
            sha256: [UInt8](repeating: 0x44, count: 32)))
        let validRequest = TargetRequest(
            canonicalPath: "/a", recoverability: .trashRestorable, riskLevel: .low,
            attribution: .verifiedAppBody, evidenceFingerprint: fingerprint)

        let empty = issuer([:]).prepare(kind: .uninstall, targets: [], now: t0)
        let missingEvidence = issuer(["/a": identity()]).prepare(
            kind: .uninstall, targets: [request("/a")], now: t0)
        let missingIdentity = issuer([:]).prepare(
            kind: .uninstall, targets: [validRequest], now: t0)

        XCTAssertNil(issuer([:]).authorize(empty, now: t0))
        XCTAssertNil(issuer(["/a": identity()]).authorize(missingEvidence, now: t0))
        XCTAssertNil(issuer([:]).authorize(missingIdentity, now: t0))
    }

    func testAuthorizeRejectsFutureCreatedPlanAndInvalidCanonicalDigest() throws {
        let clock = MutableWallClock(t0)
        let sut = DestructiveOperationIssuer(
            sampler: FakeSampler(table: ["/a": identity()]),
            ledger: AuthorizationLedger(), wallNow: { clock.now() })
        let plan = sut.prepare(kind: .shred, targets: [request("/a")])

        clock.set(t0.addingTimeInterval(-1))
        XCTAssertNil(sut.authorize(plan), "createdAt > fresh now must fail closed")

        clock.set(t0)
        let substituted = PlannedTarget(
            canonicalPath: "/substituted", identity: identity(inode: 999),
            recoverability: .irreversible, riskLevel: .high,
            attribution: .userSelected)
        let invalidDigest = DestructivePlan(
            planID: plan.planID, kind: plan.kind,
            createdAt: plan.createdAt, expiresAt: plan.expiresAt,
            targets: [substituted], digest: plan.digest)
        XCTAssertNil(sut.authorize(invalidDigest),
                     "digest must be recomputed from current canonical plan fields")
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

    func testFreshWallClockAfterLedgerAwaitBlocksExpiredBodyAndSpendsNonce() async throws {
        let clock = MutableWallClock(t0)
        let ledger = AuthorizationLedger(onConsume: { clock.advance(301) })
        let sut = DestructiveOperationIssuer(
            sampler: FakeSampler(table: ["/a": identity()]), ledger: ledger,
            wallNow: { clock.now() })
        let plan = sut.prepare(kind: .shred, targets: [request("/a")])
        let authorization = try XCTUnwrap(sut.authorize(plan))
        let counter = Counter()

        let expired = await sut.execute(plan, authorization: authorization) {
            await counter.increment()
            return true
        }
        XCTAssertEqual(failure(expired), .expired)
        let expiredBodyRuns = await counter.snapshot()
        XCTAssertEqual(expiredBodyRuns, 0)

        clock.set(t0)
        let replay = await sut.execute(plan, authorization: authorization) {
            await counter.increment()
            return true
        }
        XCTAssertEqual(failure(replay), .nonceAlreadyConsumed)
        let replayBodyRuns = await counter.snapshot()
        XCTAssertEqual(replayBodyRuns, 0)
    }

    func testExecuteRejectsCanonicalTargetTamperingEvenWhenStoredDigestIsUnchanged() async throws {
        let sut = issuer(["/a": identity()])
        let plan = sut.prepare(kind: .shred, targets: [request("/a")], now: t0)
        let authorization = try XCTUnwrap(sut.authorize(plan, now: t0))
        let substituted = PlannedTarget(
            canonicalPath: "/substituted", identity: identity(inode: 999),
            recoverability: .irreversible, riskLevel: .high,
            attribution: .userSelected)
        let tampered = DestructivePlan(
            planID: plan.planID, kind: plan.kind,
            createdAt: plan.createdAt, expiresAt: plan.expiresAt,
            targets: [substituted], digest: plan.digest)
        let counter = Counter()

        let result = await sut.execute(tampered, authorization: authorization, now: t0) {
            await counter.increment()
            return true
        }
        XCTAssertEqual(failure(result), .digestMismatch)
        let bodyRuns = await counter.snapshot()
        XCTAssertEqual(bodyRuns, 0)
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
