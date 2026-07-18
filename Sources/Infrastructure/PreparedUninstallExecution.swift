import CryptoKit
import Domain
import Foundation

struct PreparedUninstallTarget: Sendable {
    let ordinal: UInt32
    let candidate: UninstallCandidate
    let canonicalPath: String
    let expectedIdentity: LocalFileIdentity
    let evidenceFingerprint: EvidenceFingerprint
    let ownershipAttestation: CandidateEvidenceBinding
}

struct PreparedUninstallExecution: Sendable {
    let plan: DestructivePlan
    let orderedTargets: [PreparedUninstallTarget]
    let batchSnapshot: UninstallBatch
    let batchID: UUID
    let issuanceID: UUID
    let preparationSeal: Data

    func validateIntegrity() -> Bool {
        guard plan.kind == .uninstall,
              plan.hasValidCanonicalDigest,
              plan.createdAt.timeIntervalSince1970.isFinite,
              plan.expiresAt.timeIntervalSince1970.isFinite,
              plan.expiresAt >= plan.createdAt,
              plan.expiresAt.timeIntervalSince(plan.createdAt)
                == DestructiveOperationIssuer.localTimeToLive,
              batchID == batchSnapshot.batchID,
              issuanceID == batchSnapshot.issuanceID else { return false }
        let selected = UninstallEvidenceSeal.orderedSelectedCandidates(in: batchSnapshot)
        guard !selected.isEmpty,
              selected.count == orderedTargets.count,
              plan.targets.count == orderedTargets.count else { return false }

        for (index, tuple) in zip(selected.indices, zip(selected, orderedTargets)) {
            let (candidate, sealed) = tuple
            guard let ordinal = UInt32(exactly: index),
                  sealed.ordinal == ordinal,
                  UninstallEvidenceSeal.sameCandidate(sealed.candidate, candidate),
                  sealed.canonicalPath == candidate.url.standardizedFileURL.path,
                  sealed.candidate.item.url.standardizedFileURL.path == sealed.canonicalPath,
                  sealed.candidate.item.isSelected,
                  sealed.ownershipAttestation == candidate.evidenceBinding,
                  sealed.expectedIdentity
                    == UninstallEvidenceSeal.expectedIdentity(for: candidate,
                                                               in: batchSnapshot),
                  let recomputed = UninstallEvidenceSeal.fingerprint(
                    batch: batchSnapshot, candidate: candidate, ordinal: ordinal,
                    expectedIdentity: sealed.expectedIdentity),
                  recomputed == sealed.evidenceFingerprint,
                  recomputed != .none else { return false }

            let planned = plan.targets[index]
            let request = candidate.targetRequest(with: recomputed)
            guard planned.canonicalPath == sealed.canonicalPath,
                  planned.identity == sealed.expectedIdentity,
                  planned.evidenceFingerprint == recomputed,
                  planned.recoverability == request.recoverability,
                  planned.riskLevel == request.riskLevel,
                  planned.attribution == request.attribution else { return false }
        }
        return UninstallEvidenceSeal.preparationSeal(
            plan: plan, batch: batchSnapshot, targets: orderedTargets) == preparationSeal
    }

    var selectedItems: [CleanableItem]? {
        guard validateIntegrity() else { return nil }
        return orderedTargets.map(\.candidate.item)
    }
}

struct UninstallPreparationHooks: Sendable {
    static let none = UninstallPreparationHooks()
    let beforeIssuerPrepare: @Sendable () -> Void
    let afterIssuerPrepare: @Sendable (DestructivePlan) -> DestructivePlan
    let afterPreparation: @Sendable (PreparedUninstallExecution)
        -> PreparedUninstallExecution

    init(beforeIssuerPrepare: @escaping @Sendable () -> Void = {},
         afterIssuerPrepare: @escaping @Sendable (DestructivePlan) -> DestructivePlan = { $0 },
         afterPreparation: @escaping @Sendable (PreparedUninstallExecution)
            -> PreparedUninstallExecution = { $0 }) {
        self.beforeIssuerPrepare = beforeIssuerPrepare
        self.afterIssuerPrepare = afterIssuerPrepare
        self.afterPreparation = afterPreparation
    }
}

enum UninstallEvidenceSeal {
    static func orderedSelectedCandidates(in batch: UninstallBatch) -> [UninstallCandidate] {
        batch.candidates.filter(\.isSelected).sorted { lhs, rhs in
            if lhs.role != rhs.role { return lhs.role == .appBody }
            return lhs.url.standardizedFileURL.path.utf8.lexicographicallyPrecedes(
                rhs.url.standardizedFileURL.path.utf8)
        }
    }

    static func expectedIdentity(for candidate: UninstallCandidate,
                                 in batch: UninstallBatch) -> LocalFileIdentity? {
        switch candidate.role {
        case .appBody:
            return candidate.url.standardizedFileURL.path
                == batch.app.url.standardizedFileURL.path ? batch.app.sourceIdentity : nil
        case .associatedFile:
            return candidate.evidenceBinding.physicalPath?.targetIdentity
        }
    }

    static func sameCandidate(_ lhs: UninstallCandidate,
                              _ rhs: UninstallCandidate) -> Bool {
        lhs.id == rhs.id
            && lhs.item == rhs.item
            && lhs.evidence == rhs.evidence
            && lhs.selectionPolicy == rhs.selectionPolicy
            && lhs.role == rhs.role
            && lhs.recoveryHint == rhs.recoveryHint
            && lhs.batchID == rhs.batchID
            && lhs.evidenceBinding == rhs.evidenceBinding
    }

    static func fingerprint(batch: UninstallBatch,
                            candidate: UninstallCandidate,
                            ordinal: UInt32,
                            expectedIdentity: LocalFileIdentity) -> EvidenceFingerprint? {
        var encoder = CanonicalEncoder(version: 1)
        encoder.uuid(batch.issuanceID)
        encoder.uuid(batch.batchID)
        encoder.string(batch.mode.rawValue)
        encoder.double(batch.createdAt.timeIntervalSince1970)
        encoder.double(batch.expiresAt.timeIntervalSince1970)
        encode(batch.app, to: &encoder)
        encoder.uuid(candidate.id)
        encoder.uint(ordinal)
        encoder.string(candidate.role.rawValue)
        encoder.string(candidate.selectionPolicy.rawValue)
        encoder.string(candidate.evidence.rawValue)
        encode(candidate.item, to: &encoder)
        encoder.string(candidate.recoveryHint)
        encode(expectedIdentity, to: &encoder)
        encode(candidate.evidenceBinding, to: &encoder)
        guard encoder.isValid else { return nil }
        return EvidenceFingerprint(sha256: Array(SHA256.hash(data: encoder.data)))
    }

    static func preparationSeal(plan: DestructivePlan,
                                batch: UninstallBatch,
                                targets: [PreparedUninstallTarget]) -> Data? {
        var encoder = CanonicalEncoder(version: 1)
        encoder.uuid(batch.issuanceID)
        encoder.uuid(batch.batchID)
        encoder.uuid(plan.planID)
        encoder.string(plan.kind.rawValue)
        encoder.double(plan.createdAt.timeIntervalSince1970)
        encoder.double(plan.expiresAt.timeIntervalSince1970)
        encoder.bytes(plan.digest.bytes)
        encoder.count(targets.count)
        for target in targets {
            encoder.uint(target.ordinal)
            encoder.string(target.canonicalPath)
            encode(target.expectedIdentity, to: &encoder)
            encoder.bytes(target.evidenceFingerprint.bytes)
        }
        guard encoder.isValid else { return nil }
        return Data(SHA256.hash(data: encoder.data))
    }

    private static func encode(_ app: InstalledApp, to encoder: inout CanonicalEncoder) {
        encoder.string(app.id)
        encoder.string(app.name)
        encoder.string(app.bundleID)
        encoder.string(app.url.standardizedFileURL.path)
        encoder.int(app.size)
        encoder.uuid(app.provenanceID)
        encode(app.sourceIdentity, to: &encoder)
        encode(app.appPathProof, to: &encoder)
        encode(app.metadataAttestation, to: &encoder)
    }

    private static func encode(_ item: CleanableItem, to encoder: inout CanonicalEncoder) {
        encoder.uuid(item.id)
        encoder.string(item.url.standardizedFileURL.path)
        encoder.string(item.displayName)
        encoder.string(item.detail)
        encoder.int(item.size)
        encoder.string(item.safety.rawValue)
        encoder.bool(item.isSelected)
        encoder.bool(item.requiresHelper)
        encoder.optionalString(item.note)
        encoder.bool(item.isInformational)
        encode(item.assessment, to: &encoder)
    }

    private static func encode(_ assessment: FindingAssessment,
                               to encoder: inout CanonicalEncoder) {
        encoder.optionalString(assessment.ruleID)
        encoder.double(assessment.confidence)
        encoder.count(assessment.evidence.count)
        for evidence in assessment.evidence {
            encoder.string(evidence.code)
            encoder.string(evidence.kind.rawValue)
            encoder.string(evidence.title)
            encoder.string(evidence.detail)
            encoder.double(evidence.strength)
        }
        encoder.optionalString(assessment.ownerBundleID)
        encoder.int(assessment.reclaimableBytes)
        encoder.string(assessment.recovery.rawValue)
        encoder.string(assessment.regenerationCost.rawValue)
        encoder.optionalString(assessment.impact)
        encoder.string(assessment.provenance)
    }

    private static func encode(_ binding: CandidateEvidenceBinding,
                               to encoder: inout CanonicalEncoder) {
        switch binding {
        case .none:
            encoder.byte(0)
        case .physicalPath(let path):
            encoder.byte(1)
            encode(path, to: &encoder)
        case .signedEntitlement(let entitlement, let path):
            encoder.byte(2)
            encode(entitlement, to: &encoder)
            encode(path, to: &encoder)
        case .launchAgent(let launchAgent, let path):
            encoder.byte(3)
            encode(launchAgent, to: &encoder)
            encode(path, to: &encoder)
        }
    }

    private static func encode(_ proof: PhysicalPathAttestation,
                               to encoder: inout CanonicalEncoder) {
        encoder.string(proof.canonicalPath)
        encoder.strings(proof.componentNames)
        encoder.count(proof.componentIdentities.count)
        proof.componentIdentities.forEach { encode($0, to: &encoder) }
    }

    private static func encode(_ proof: AppBundlePathProof,
                               to encoder: inout CanonicalEncoder) {
        encoder.string(proof.canonicalPath)
        encoder.strings(proof.rootRelativeComponents)
        encoder.count(proof.componentIdentities.count)
        proof.componentIdentities.forEach { encode($0, to: &encoder) }
        encoder.bytes(proof.chainFingerprint.bytes)
    }

    private static func encode(_ content: AppBundleBoundedContentAttestation,
                               to encoder: inout CanonicalEncoder) {
        encoder.strings(content.relativeComponentsInsideApp)
        encode(content.identity, to: &encoder)
        encoder.int(Int64(content.exactLength))
        encoder.bytes(content.contentDigest.bytes)
        encoder.bytes(content.pathChainFingerprint.bytes)
    }

    private static func encode(_ token: ProgramChangeToken,
                               to encoder: inout CanonicalEncoder) {
        encoder.string(token.canonicalPath)
        encoder.strings(token.relativeComponentsInsideApp)
        encoder.count(token.directoryChain.count)
        token.directoryChain.forEach { encode($0, to: &encoder) }
        encode(token.executable, to: &encoder)
        encoder.bytes(token.chainFingerprint.bytes)
        encoder.optionalInt(token.boundedExactLength.map(Int64.init))
        encoder.optionalBytes(token.boundedContentDigest?.bytes)
    }

    private static func encode(_ seal: AppBundleSourceSeal,
                               to encoder: inout CanonicalEncoder) {
        encode(seal.appRoot, to: &encoder)
        encoder.bytes(seal.appChainFingerprint.bytes)
        encode(seal.infoPlist, to: &encoder)
        encode(seal.mainExecutable, to: &encoder)
        encoder.string(seal.mainExecutableCanonicalPath)
        encode(seal.codeResources, to: &encoder)
        encoder.bytes(seal.nestedRosterFingerprint.bytes)
    }

    private static func encode(_ entitlement: SignedEntitlementAttestation,
                               to encoder: inout CanonicalEncoder) {
        encoder.strings(entitlement.groups)
        encoder.string(entitlement.codeIdentifier)
        encoder.bytes(entitlement.uniqueCode)
        encode(entitlement.sourceIdentity, to: &encoder)
        if let sourceSeal = entitlement.sourceSeal {
            encoder.byte(1)
            encode(sourceSeal, to: &encoder)
        } else {
            encoder.byte(0)
        }
    }

    private static func encode(_ launchAgent: LaunchAgentAttestation,
                               to encoder: inout CanonicalEncoder) {
        encoder.optionalString(launchAgent.record.label)
        encoder.optionalString(launchAgent.record.program)
        encoder.strings(launchAgent.record.programArguments)
        encode(launchAgent.plistIdentity, to: &encoder)
        encoder.int(Int64(launchAgent.plistExactLength))
        encoder.bytes(launchAgent.plistContentDigest.bytes)
        encoder.optionalString(launchAgent.resolvedProgramPath)
        encoder.optionalIdentity(launchAgent.programIdentity)
        if let token = launchAgent.programChangeToken {
            encoder.byte(1)
            encode(token, to: &encoder)
        } else {
            encoder.byte(0)
        }
    }

    private static func encode(_ identity: LocalFileIdentity,
                               to encoder: inout CanonicalEncoder) {
        encoder.uint(identity.device)
        encoder.uint(identity.inode)
        encoder.uint(identity.mode)
        encoder.int(identity.size)
        encoder.int(identity.mtimeNanoseconds)
        encoder.int(identity.changeTimeNanoseconds)
        encoder.uint(identity.hardLinkCount)
    }

    private struct CanonicalEncoder {
        private(set) var data = Data()
        private(set) var isValid = true

        init(version: UInt8) { byte(version) }

        mutating func byte(_ value: UInt8) { data.append(value) }
        mutating func bool(_ value: Bool) { byte(value ? 1 : 0) }
        mutating func uint<T: FixedWidthInteger>(_ value: T) {
            var bigEndian = value.bigEndian
            withUnsafeBytes(of: &bigEndian) { data.append(contentsOf: $0) }
        }
        mutating func int<T: FixedWidthInteger>(_ value: T) { uint(value) }
        mutating func double(_ value: Double) {
            guard value.isFinite else { isValid = false; return }
            uint(value.bitPattern)
        }
        mutating func count(_ value: Int) {
            guard let exact = UInt32(exactly: value) else {
                isValid = false
                return
            }
            uint(exact)
        }
        mutating func uuid(_ value: UUID) {
            var raw = value.uuid
            withUnsafeBytes(of: &raw) { data.append(contentsOf: $0) }
        }
        mutating func string(_ value: String) {
            bytes(Array(value.utf8))
        }
        mutating func strings(_ values: [String]) {
            guard let count = UInt32(exactly: values.count) else {
                isValid = false
                return
            }
            uint(count)
            values.forEach { string($0) }
        }
        mutating func bytes<C: Collection>(_ value: C) where C.Element == UInt8 {
            guard let count = UInt32(exactly: value.count) else {
                isValid = false
                return
            }
            uint(count)
            data.append(contentsOf: value)
        }
        mutating func optionalString(_ value: String?) {
            guard let value else { byte(0); return }
            byte(1); string(value)
        }
        mutating func optionalBytes(_ value: [UInt8]?) {
            guard let value else { byte(0); return }
            byte(1); bytes(value)
        }
        mutating func optionalInt(_ value: Int64?) {
            guard let value else { byte(0); return }
            byte(1); int(value)
        }
        mutating func optionalIdentity(_ value: LocalFileIdentity?) {
            guard let value else { byte(0); return }
            byte(1); UninstallEvidenceSeal.encode(value, to: &self)
        }
    }
}
