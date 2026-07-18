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
    case verifiedAppBody
    case exactBundleIDPath
    case signedApplicationGroup
    case launchAgentProgramInsideBundle
    case displayNameHeuristic
    case unverified
}

/// A stat-backed identity snapshot. Local deletion rechecks at least device/inode/type
/// (`mode`); shred additionally rechecks `hardLinkCount` (doc 19 §6.2).
public struct LocalFileIdentity: Equatable, Hashable, Sendable {
    public let device: UInt64
    public let inode: UInt64
    public let mode: UInt32
    public let size: Int64
    public let mtimeNanoseconds: Int64
    public let changeTimeNanoseconds: Int64
    public let hardLinkCount: UInt64

    public init(device: UInt64,
                inode: UInt64,
                mode: UInt32,
                size: Int64,
                mtimeNanoseconds: Int64,
                changeTimeNanoseconds: Int64 = 0,
                hardLinkCount: UInt64) {
        self.device = device
        self.inode = inode
        self.mode = mode
        self.size = size
        self.mtimeNanoseconds = mtimeNanoseconds
        self.changeTimeNanoseconds = changeTimeNanoseconds
        self.hardLinkCount = hardLinkCount
    }
}

/// Rich ownership evidence is represented in a plan by either an explicit absence tag or one
/// fixed SHA-256 value. The fingerprint alone grants no authority; Infrastructure must still
/// produce a sealed uninstall preparation before authorization.
public struct EvidenceFingerprint: Equatable, Hashable, Sendable {
    public static let none = EvidenceFingerprint(bytes: [])
    public let bytes: [UInt8]

    private init(bytes: [UInt8]) { self.bytes = bytes }

    package init?(sha256 bytes: [UInt8]) {
        guard bytes.count == 32 else { return nil }
        self.bytes = bytes
    }
}

/// Caller-supplied request that `prepare` turns into a `PlannedTarget` by sampling
/// identity. The caller never mints identities or digests.
public struct TargetRequest: Sendable, Equatable {
    public let canonicalPath: String
    public let recoverability: Recoverability
    public let riskLevel: RiskLevel
    public let attribution: AttributionEvidence
    public let evidenceFingerprint: EvidenceFingerprint

    public init(canonicalPath: String,
                recoverability: Recoverability,
                riskLevel: RiskLevel,
                attribution: AttributionEvidence,
                evidenceFingerprint: EvidenceFingerprint = .none) {
        self.canonicalPath = canonicalPath
        self.recoverability = recoverability
        self.riskLevel = riskLevel
        self.attribution = attribution
        self.evidenceFingerprint = evidenceFingerprint
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
    public let evidenceFingerprint: EvidenceFingerprint

    public init(canonicalPath: String,
                identity: LocalFileIdentity?,
                recoverability: Recoverability,
                riskLevel: RiskLevel,
                attribution: AttributionEvidence,
                evidenceFingerprint: EvidenceFingerprint = .none) {
        self.canonicalPath = canonicalPath
        self.identity = identity
        self.recoverability = recoverability
        self.riskLevel = riskLevel
        self.attribution = attribution
        self.evidenceFingerprint = evidenceFingerprint
    }
}

/// A SHA-256 over a schema-versioned, deterministic canonical encoding of the plan's
/// kind and targets. The encoding fixes field order, sorts targets by path bytes, uses
/// big-endian fixed-length integers and length-prefixed UTF-8, and never depends on
/// dictionary order, locale or `String(describing:)`.
public struct PlanDigest: Equatable, Sendable {
    public let bytes: [UInt8]

    init(bytes: [UInt8]) { self.bytes = bytes }

    static let schemaVersion: UInt8 = 2

    package static func compute(kind: DestructiveKind,
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
                appendBE(UInt64(bitPattern: id.changeTimeNanoseconds), to: &buf)
                appendBE(id.hardLinkCount, to: &buf)
            } else {
                buf.append(0)                      // identity-absent sentinel
            }
            appendString(target.recoverability.rawValue, to: &buf)
            appendString(target.riskLevel.rawValue, to: &buf)
            appendString(target.attribution.rawValue, to: &buf)
            if target.evidenceFingerprint.bytes.isEmpty {
                buf.append(0)
            } else {
                buf.append(1)
                buf.append(contentsOf: target.evidenceFingerprint.bytes)
            }
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
    package init(planID: UUID,
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

    package var hasValidCanonicalDigest: Bool {
        digest == PlanDigest.compute(kind: kind, targets: targets)
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
