import Foundation
import CryptoKit

// MARK: - Destructive operation capability core (prepare → authorize → execute)
//
// Every operation that permanently destroys file content (Shredder) or removes an
// app and its data (Uninstaller), plus Space Lens's Trash / local-snapshot delete
// channels, must pass through this boundary:
//   1. `prepare`   builds an immutable `DestructivePlan` with a per-target identity
//                  snapshot, a recoverability/risk classification and a versioned,
//                  deterministic canonical digest.
//   2. `authorize` mints a one-time `Authorization` bound to
//                  planID + digest + nonce + expiresAt + kind. Its initializer is
//                  fileprivate, so nothing outside this file — not even a
//                  `@testable` test — can forge a capability object.
//   3. `execute`   validates planID/kind/digest/expiry, then atomically consumes the
//                  nonce through `AuthorizationLedger` BEFORE invoking the executor
//                  closure. Any mismatch, expiry or replay fails closed and the
//                  executor closure is never called.
//
// Fail-closed is the rule. Nothing here touches the filesystem; identity sampling is
// injected so the whole capability is deterministically testable without real files.

public enum DestructiveKind: String, Sendable, Equatable, CaseIterable {
    case shred
    case uninstall
    case spaceTrash
    case snapshotDelete

    /// Bridges to the already-registered `OperationKind` vocabulary; no new kinds.
    public var operationKind: OperationKind {
        switch self {
        case .shred: return .shred
        case .uninstall: return .uninstall
        case .spaceTrash: return .spaceTrash
        case .snapshotDelete: return .snapshotDelete
        }
    }
}

/// Reversibility class of a planned target. `trashRestorable` can be recovered from
/// the Trash; `irreversible` cannot (shred, snapshot); `neutral` has no user-visible
/// data effect.
public enum Recoverability: String, Sendable, Equatable {
    case trashRestorable
    case irreversible
    case neutral
}

/// Coarse risk gradation carried alongside recoverability (doc 19 §6.1 lists both).
/// `low` = reversible (Trash); `medium` = irreversible but system-managed
/// (APFS local snapshot); `high` = irreversible destruction of user content (shred).
public enum RiskLevel: String, Sendable, Equatable {
    case low
    case medium
    case high
}

/// Why a target is attributed to this operation. Shred targets are always
/// `.userSelected`; the uninstaller's richer ownership evidence (Task 4) reuses the
/// remaining cases.
public enum AttributionEvidence: String, Sendable, Equatable {
    case userSelected
    case exactBundleIDPath
    case signedApplicationGroup
    case launchAgentProgramInsideBundle
    case displayNameHeuristic
    case unverified
}

/// A stat-backed identity snapshot. Local deletion rechecks at least device/inode/type
/// (`mode`); shred additionally rechecks `hardLinkCount` (doc 19 §6.2).
public struct LocalFileIdentity: Equatable, Sendable {
    public let device: UInt64
    public let inode: UInt64
    public let mode: UInt32
    public let size: Int64
    public let mtimeNanoseconds: Int64
    public let hardLinkCount: UInt64

    public init(device: UInt64,
                inode: UInt64,
                mode: UInt32,
                size: Int64,
                mtimeNanoseconds: Int64,
                hardLinkCount: UInt64) {
        self.device = device
        self.inode = inode
        self.mode = mode
        self.size = size
        self.mtimeNanoseconds = mtimeNanoseconds
        self.hardLinkCount = hardLinkCount
    }
}

/// Caller-supplied request that `prepare` turns into a `PlannedTarget` by sampling
/// identity. The caller never mints identities or digests.
public struct TargetRequest: Sendable, Equatable {
    public let canonicalPath: String
    public let recoverability: Recoverability
    public let riskLevel: RiskLevel
    public let attribution: AttributionEvidence

    public init(canonicalPath: String,
                recoverability: Recoverability,
                riskLevel: RiskLevel,
                attribution: AttributionEvidence) {
        self.canonicalPath = canonicalPath
        self.recoverability = recoverability
        self.riskLevel = riskLevel
        self.attribution = attribution
    }
}

public struct PlannedTarget: Sendable, Equatable {
    public let canonicalPath: String
    /// `nil` for targets without a file identity (e.g. a snapshot handle); encoded
    /// with an explicit sentinel in the digest so a nil never collides with a value.
    public let identity: LocalFileIdentity?
    public let recoverability: Recoverability
    public let riskLevel: RiskLevel
    public let attribution: AttributionEvidence

    public init(canonicalPath: String,
                identity: LocalFileIdentity?,
                recoverability: Recoverability,
                riskLevel: RiskLevel,
                attribution: AttributionEvidence) {
        self.canonicalPath = canonicalPath
        self.identity = identity
        self.recoverability = recoverability
        self.riskLevel = riskLevel
        self.attribution = attribution
    }
}

/// A SHA-256 over a schema-versioned, deterministic canonical encoding of the plan's
/// kind and targets. The encoding fixes field order, sorts targets by path bytes, uses
/// big-endian fixed-length integers and length-prefixed UTF-8, and never depends on
/// dictionary order, locale or `String(describing:)`.
public struct PlanDigest: Equatable, Sendable {
    public let bytes: [UInt8]

    init(bytes: [UInt8]) { self.bytes = bytes }

    static let schemaVersion: UInt8 = 1

    static func compute(kind: DestructiveKind,
                        targets: [PlannedTarget],
                        version: UInt8 = schemaVersion) -> PlanDigest {
        let encoded = canonicalBytes(kind: kind, targets: targets, version: version)
        return PlanDigest(bytes: Array(SHA256.hash(data: Data(encoded))))
    }

    static func canonicalBytes(kind: DestructiveKind,
                               targets: [PlannedTarget],
                               version: UInt8 = schemaVersion) -> [UInt8] {
        var buf: [UInt8] = []
        buf.append(version)                        // schema version is the first byte
        appendString(kind.rawValue, to: &buf)
        let sorted = targets.sorted {
            $0.canonicalPath.utf8.lexicographicallyPrecedes($1.canonicalPath.utf8)
        }
        appendBE(UInt32(sorted.count), to: &buf)
        for target in sorted {
            appendString(target.canonicalPath, to: &buf)
            if let id = target.identity {
                buf.append(1)                      // identity-present tag
                appendBE(id.device, to: &buf)
                appendBE(id.inode, to: &buf)
                appendBE(id.mode, to: &buf)
                appendBE(UInt64(bitPattern: id.size), to: &buf)
                appendBE(UInt64(bitPattern: id.mtimeNanoseconds), to: &buf)
                appendBE(id.hardLinkCount, to: &buf)
            } else {
                buf.append(0)                      // identity-absent sentinel
            }
            appendString(target.recoverability.rawValue, to: &buf)
            appendString(target.riskLevel.rawValue, to: &buf)
            appendString(target.attribution.rawValue, to: &buf)
        }
        return buf
    }
}

private func appendBE<T: FixedWidthInteger>(_ value: T, to buf: inout [UInt8]) {
    var be = value.bigEndian
    withUnsafeBytes(of: &be) { buf.append(contentsOf: $0) }
}

private func appendString(_ string: String, to buf: inout [UInt8]) {
    let bytes = Array(string.utf8)
    appendBE(UInt32(bytes.count), to: &buf)
    buf.append(contentsOf: bytes)
}

public struct DestructivePlan: Sendable, Equatable {
    public let planID: UUID
    public let kind: DestructiveKind
    public let createdAt: Date
    public let expiresAt: Date
    public let targets: [PlannedTarget]
    public let digest: PlanDigest

    /// Internal so the issuer (and `@testable` tamper fixtures) can build plans, but
    /// production code outside `Domain` cannot fabricate one.
    init(planID: UUID,
         kind: DestructiveKind,
         createdAt: Date,
         expiresAt: Date,
         targets: [PlannedTarget],
         digest: PlanDigest) {
        self.planID = planID
        self.kind = kind
        self.createdAt = createdAt
        self.expiresAt = expiresAt
        self.targets = targets
        self.digest = digest
    }
}

/// One-time capability object. Every stored binding is internal and the initializer is
/// **fileprivate** — only `DestructiveOperationIssuer` (in this file) can mint one.
public struct Authorization: Sendable, Equatable {
    public let planID: UUID
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

public enum DestructiveAuthorizationFailure: String, Sendable, Equatable {
    case planMismatch
    case kindMismatch
    case digestMismatch
    case expired
    case nonceAlreadyConsumed
}

public enum DestructiveExecutionResult<R: Sendable>: Sendable {
    case executed(R)
    case failedClosed(DestructiveAuthorizationFailure)
}

/// Samples a `LocalFileIdentity` for a canonical path. Injected so the capability is
/// testable without real files; production supplies a stat-backed implementation.
public protocol IdentitySampler: Sendable {
    func sample(_ canonicalPath: String) -> LocalFileIdentity?
}

public struct DestructiveOperationIssuer: Sendable {
    /// Local shred / uninstall / snapshot authorizations live 5 minutes (doc 19 §6.1).
    public static let localTimeToLive: TimeInterval = 5 * 60

    private let sampler: IdentitySampler
    private let ledger: AuthorizationLedger

    public init(sampler: IdentitySampler, ledger: AuthorizationLedger) {
        self.sampler = sampler
        self.ledger = ledger
    }

    /// Builds an immutable plan: one identity snapshot per target, a 5-minute expiry
    /// and the canonical digest. Never touches the filesystem itself.
    public func prepare(kind: DestructiveKind,
                        targets: [TargetRequest],
                        now: Date = Date()) -> DestructivePlan {
        let planned = targets.map { request in
            PlannedTarget(canonicalPath: request.canonicalPath,
                          identity: sampler.sample(request.canonicalPath),
                          recoverability: request.recoverability,
                          riskLevel: request.riskLevel,
                          attribution: request.attribution)
        }
        let digest = PlanDigest.compute(kind: kind, targets: planned)
        return DestructivePlan(planID: UUID(),
                               kind: kind,
                               createdAt: now,
                               expiresAt: now.addingTimeInterval(Self.localTimeToLive),
                               targets: planned,
                               digest: digest)
    }

    /// Mints a one-time authorization bound to the plan. Returns `nil` (fail closed) if
    /// the plan has already expired; an expired plan is never re-confirmable.
    public func authorize(_ plan: DestructivePlan, now: Date = Date()) -> Authorization? {
        guard now < plan.expiresAt else { return nil }
        return Authorization(planID: plan.planID,
                             digest: plan.digest,
                             nonce: UUID(),
                             expiresAt: plan.expiresAt,
                             kind: plan.kind)
    }

    /// Validates the authorization against the plan, then atomically consumes the nonce
    /// BEFORE invoking `body`. The executor closure runs only on the single successful
    /// consumption; every mismatch, expiry or replay returns fail-closed without calling
    /// `body`. Once a terminal result is produced a replay cannot rewrite it.
    public func execute<R: Sendable>(_ plan: DestructivePlan,
                                     authorization: Authorization,
                                     now: Date = Date(),
                                     _ body: () async -> R) async -> DestructiveExecutionResult<R> {
        guard authorization.planID == plan.planID else { return .failedClosed(.planMismatch) }
        guard authorization.kind == plan.kind else { return .failedClosed(.kindMismatch) }
        guard authorization.digest == plan.digest else { return .failedClosed(.digestMismatch) }
        guard now < authorization.expiresAt else { return .failedClosed(.expired) }
        guard await ledger.consume(authorization.nonce) else {
            return .failedClosed(.nonceAlreadyConsumed)
        }
        return .executed(await body())
    }
}
