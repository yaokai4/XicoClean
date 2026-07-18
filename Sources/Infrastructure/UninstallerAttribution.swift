import Foundation
import Domain
import Security
#if canImport(Darwin)
import Darwin
#endif

/// A syntactically safe reverse-DNS identifier suitable for constructing exact
/// per-application Library paths. Parsing is deliberately lossless: identifiers are
/// neither trimmed nor case-folded.
public struct BundleIdentifier: RawRepresentable, Hashable, Sendable {
    public let rawValue: String

    public init?(rawValue: String) {
        let bytes = Array(rawValue.utf8)
        guard !bytes.isEmpty, bytes.count <= 255,
              !rawValue.contains("/"), !rawValue.contains("\\") else { return nil }

        let components = rawValue.split(separator: ".", omittingEmptySubsequences: false)
        guard components.count >= 2 else { return nil }
        for component in components {
            let componentBytes = Array(component.utf8)
            guard !componentBytes.isEmpty, componentBytes.count <= 63,
                  componentBytes.first != UInt8(ascii: "-"),
                  componentBytes.last != UInt8(ascii: "-") else { return nil }
            guard componentBytes.allSatisfy({ byte in
                (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(byte)
                    || (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains(byte)
                    || (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
                    || byte == UInt8(ascii: "-")
            }) else { return nil }
        }
        self.rawValue = rawValue
    }
}

/// Rich uninstaller ownership evidence. This Infrastructure vocabulary controls
/// candidate selection and maps one-to-one to Domain attribution when a plan is built.
public enum OwnershipEvidence: String, Sendable, Equatable {
    case verifiedAppBody
    case exactBundleIDPath
    case signedApplicationGroup
    case launchAgentProgramInsideBundle
    case displayNameHeuristic
    case unverified

    var domainValue: Domain.AttributionEvidence {
        switch self {
        case .verifiedAppBody: return .verifiedAppBody
        case .exactBundleIDPath: return .exactBundleIDPath
        case .signedApplicationGroup: return .signedApplicationGroup
        case .launchAgentProgramInsideBundle: return .launchAgentProgramInsideBundle
        case .displayNameHeuristic: return .displayNameHeuristic
        case .unverified: return .unverified
        }
    }
}

public enum SelectionPolicy: String, Sendable, Equatable {
    case required
    case recommended
    case manualOnly
    case blocked

    var defaultSelected: Bool { self == .required || self == .recommended }
    var isSelectable: Bool { self != .required && self != .blocked }
}

public enum UninstallMode: String, Sendable, Equatable {
    case uninstallApp
    case cleanLeftovers
}

public enum UninstallerAttributionError: Error, Sendable, Equatable {
    case appStillPresent
    case appBodyNotAdmitted
    case foreignApp
    case appIdentityChanged
    case appMetadataChanged
}

public enum UninstallPlanError: Error, Sendable, Equatable {
    case foreignBatch
    case foreignCandidate
    case requiredAppBodyMissing
    case modeInvariantViolation
    case invalidSelectedCandidate
    case emptySelection
    case authorizationUnavailable
    case missingTargetIdentity
    case appIdentityChanged
    case appMetadataChanged
    case batchExpired
    case batchAlreadyConsumed
    case entitlementAttestationChanged
    case launchAgentAttestationChanged
}

public struct SignedEntitlementAttestation: Sendable, Equatable {
    public let groups: [String]
    public let codeIdentifier: String
    public let uniqueCode: Data
    public let sourceIdentity: LocalFileIdentity

    public init(groups: [String], codeIdentifier: String, uniqueCode: Data,
                sourceIdentity: LocalFileIdentity) {
        self.groups = groups
        self.codeIdentifier = codeIdentifier
        self.uniqueCode = uniqueCode
        self.sourceIdentity = sourceIdentity
    }

    var isWithinBounds: Bool {
        Self.groupsAreWithinBounds(groups)
            && !codeIdentifier.isEmpty
            && !uniqueCode.isEmpty
    }

    static func groupsAreWithinBounds(_ groups: [String]) -> Bool {
        guard groups.count <= SecurityEntitlementReader.maximumGroupCount else { return false }
        var totalBytes = 0
        for group in groups {
            let (next, overflow) = totalBytes.addingReportingOverflow(group.utf8.count)
            guard !overflow,
                  next <= SecurityEntitlementReader.maximumGroupUTF8Bytes else { return false }
            totalBytes = next
        }
        return true
    }
}

public struct SecurityCodeInspection: Sendable, Equatable {
    public let groups: [String]
    public let codeIdentifier: String
    public let uniqueCode: Data

    public init(groups: [String], codeIdentifier: String, uniqueCode: Data) {
        self.groups = groups
        self.codeIdentifier = codeIdentifier
        self.uniqueCode = uniqueCode
    }
}

public protocol SecurityCodeInspecting: Sendable {
    func inspect(appURL: URL) -> SecurityCodeInspection?
}

public struct SecurityFrameworkCodeInspector: SecurityCodeInspecting {
    public init() {}

    public func inspect(appURL: URL) -> SecurityCodeInspection? {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(appURL as CFURL, [], &staticCode) == errSecSuccess,
              let staticCode else { return nil }
        let validityFlags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures
                                      | kSecCSCheckNestedCode
                                      | kSecCSStrictValidate)
        guard SecStaticCodeCheckValidity(staticCode, validityFlags, nil) == errSecSuccess else {
            return nil
        }
        var signingInformation: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode,
                                            SecCSFlags(rawValue: kSecCSSigningInformation),
                                            &signingInformation) == errSecSuccess,
              let dictionary = signingInformation as? [String: Any],
              let codeIdentifier = dictionary[kSecCodeInfoIdentifier as String] as? String,
              let uniqueCode = dictionary[kSecCodeInfoUnique as String] as? Data else { return nil }
        let entitlements = dictionary[kSecCodeInfoEntitlementsDict as String] as? [String: Any]
        let groups = entitlements?["com.apple.security.application-groups"] as? [String] ?? []
        return SecurityCodeInspection(groups: groups, codeIdentifier: codeIdentifier,
                                      uniqueCode: uniqueCode)
    }
}

/// Injected boundary for a bounded signature-validated application-group attestation.
/// `nil` means the signature, identity, or payload bounds could not be verified.
public protocol EntitlementReader: Sendable {
    func attestation(for appURL: URL) -> SignedEntitlementAttestation?
}

public struct SecurityEntitlementReader: EntitlementReader {
    public static let maximumGroupCount = 128
    public static let maximumGroupUTF8Bytes = 16 * 1024

    private let inspector: any SecurityCodeInspecting
    private let identitySampler: any IdentitySampler

    public init(inspector: any SecurityCodeInspecting = SecurityFrameworkCodeInspector(),
                identitySampler: any IdentitySampler = LocalFileIdentitySampler()) {
        self.inspector = inspector
        self.identitySampler = identitySampler
    }

    public func attestation(for appURL: URL) -> SignedEntitlementAttestation? {
        let canonicalPath = appURL.standardizedFileURL.path
        guard let before = identitySampler.sample(canonicalPath),
              let inspection = inspector.inspect(appURL: appURL),
              SignedEntitlementAttestation.groupsAreWithinBounds(inspection.groups),
              let after = identitySampler.sample(canonicalPath),
              before == after else { return nil }
        let attestation = SignedEntitlementAttestation(
            groups: inspection.groups.sorted(),
            codeIdentifier: inspection.codeIdentifier,
            uniqueCode: inspection.uniqueCode,
            sourceIdentity: before)
        return attestation.isWithinBounds ? attestation : nil
    }
}

public struct LaunchAgentRecord: Sendable, Equatable {
    public let label: String?
    public let program: String?
    public let programArguments: [String]

    public init(label: String?, program: String?, programArguments: [String]) {
        self.label = label
        self.program = program
        self.programArguments = programArguments
    }

    var executablePath: String? {
        program ?? programArguments.first
    }
}

public struct LaunchAgentAttestation: Sendable, Equatable {
    public let record: LaunchAgentRecord
    public let plistIdentity: LocalFileIdentity
    public let resolvedProgramPath: String?
    public let programIdentity: LocalFileIdentity?

    public init(record: LaunchAgentRecord,
                plistIdentity: LocalFileIdentity,
                resolvedProgramPath: String?,
                programIdentity: LocalFileIdentity?) {
        self.record = record
        self.plistIdentity = plistIdentity
        self.resolvedProgramPath = resolvedProgramPath
        self.programIdentity = programIdentity
    }

    static func capture(record: LaunchAgentRecord, plistURL: URL) -> LaunchAgentAttestation? {
        guard let plistIdentity = LocalFileIdentitySampler().sample(plistURL.path) else { return nil }
        return capture(record: record, plistIdentity: plistIdentity)
    }

    static func capture(record: LaunchAgentRecord,
                        plistIdentity: LocalFileIdentity) -> LaunchAgentAttestation {
        guard let executable = record.executablePath, executable.hasPrefix("/") else {
            return LaunchAgentAttestation(record: record, plistIdentity: plistIdentity,
                                          resolvedProgramPath: nil, programIdentity: nil)
        }
        let unresolved = URL(fileURLWithPath: executable)
        let resolvedBefore = unresolved.resolvingSymlinksInPath().standardizedFileURL
        let sampler = LocalFileIdentitySampler()
        guard let before = sampler.sample(resolvedBefore.path),
              Self.isRegular(before) else {
            return LaunchAgentAttestation(record: record, plistIdentity: plistIdentity,
                                          resolvedProgramPath: nil, programIdentity: nil)
        }
        let resolvedAfter = unresolved.resolvingSymlinksInPath().standardizedFileURL
        guard resolvedBefore.path == resolvedAfter.path,
              sampler.sample(resolvedAfter.path) == before else {
            return LaunchAgentAttestation(record: record, plistIdentity: plistIdentity,
                                          resolvedProgramPath: nil, programIdentity: nil)
        }
        return LaunchAgentAttestation(record: record, plistIdentity: plistIdentity,
                                      resolvedProgramPath: resolvedBefore.path,
                                      programIdentity: before)
    }

    private static func isRegular(_ identity: LocalFileIdentity) -> Bool {
        #if canImport(Darwin)
        return (identity.mode & UInt32(S_IFMT)) == UInt32(S_IFREG)
        #else
        return true
        #endif
    }
}

public protocol LaunchAgentReader: Sendable {
    func attestation(at url: URL) -> LaunchAgentAttestation?
}

public struct PlistLaunchAgentReader: LaunchAgentReader {
    public static let maximumBytes = 1_048_576
    private let afterRead: @Sendable () -> Void

    public init(afterRead: @escaping @Sendable () -> Void = {}) {
        self.afterRead = afterRead
    }

    public func attestation(at url: URL) -> LaunchAgentAttestation? {
        guard let read = BoundedRegularFileReader.read(at: url,
                                                       maximumBytes: Self.maximumBytes,
                                                       afterRead: afterRead),
              let plist = try? PropertyListSerialization.propertyList(from: read.data,
                                                                      options: [], format: nil),
              let dictionary = plist as? [String: Any] else { return nil }
        let record = LaunchAgentRecord(
            label: dictionary["Label"] as? String,
            program: dictionary["Program"] as? String,
            programArguments: dictionary["ProgramArguments"] as? [String] ?? [])
        return LaunchAgentAttestation.capture(record: record, plistIdentity: read.identity)
    }

    public func launchAgent(at url: URL) -> LaunchAgentRecord? {
        attestation(at: url)?.record
    }

}

public enum UninstallCandidateRole: String, Sendable, Equatable {
    case appBody
    case associatedFile
}

enum CandidateEvidenceBinding: Sendable, Equatable {
    case none
    case signedEntitlement(SignedEntitlementAttestation)
    case launchAgent(LaunchAgentAttestation)
}

public struct UninstallCandidate: Identifiable, Sendable {
    public private(set) var item: CleanableItem
    public let evidence: OwnershipEvidence
    public let selectionPolicy: SelectionPolicy
    public let role: UninstallCandidateRole
    public let recoveryHint: String
    let batchID: UUID
    let evidenceBinding: CandidateEvidenceBinding

    init(item: CleanableItem,
         evidence: OwnershipEvidence,
         selectionPolicy: SelectionPolicy,
         role: UninstallCandidateRole,
         batchID: UUID,
         evidenceBinding: CandidateEvidenceBinding = .none,
         recoveryHint: String = "Moved to Trash; restore it from Finder Trash if needed.") {
        var item = item
        item.isSelected = selectionPolicy.defaultSelected
        self.item = item
        self.evidence = evidence
        self.selectionPolicy = selectionPolicy
        self.role = role
        self.batchID = batchID
        self.evidenceBinding = evidenceBinding
        self.recoveryHint = recoveryHint
    }

    public var id: UUID { item.id }
    public var url: URL { item.url }
    public var isSelected: Bool { item.isSelected }
    public var isSelectable: Bool { selectionPolicy.isSelectable }

    mutating func setSelected(_ selected: Bool) {
        switch selectionPolicy {
        case .required:
            item.isSelected = true
        case .recommended, .manualOnly:
            item.isSelected = selected
        case .blocked:
            item.isSelected = false
        }
    }

    var targetRequest: TargetRequest {
        TargetRequest(canonicalPath: url.standardizedFileURL.path,
                      recoverability: .trashRestorable,
                      riskLevel: .low,
                      attribution: evidence.domainValue)
    }
}

/// Service-issued, app/mode-bound candidate inventory. Its initializer and candidate mutation are
/// module-internal so Features can only alter selection through the policy-aware methods below.
public struct UninstallBatch: Sendable {
    public static let timeToLive: TimeInterval = 5 * 60

    let issuanceID: UUID
    let batchID: UUID
    public let app: InstalledApp
    public let mode: UninstallMode
    public let createdAt: Date
    public let expiresAt: Date
    let entitlementAttestation: SignedEntitlementAttestation?
    public private(set) var candidates: [UninstallCandidate]

    init(issuanceID: UUID,
         batchID: UUID,
         app: InstalledApp,
         mode: UninstallMode,
         candidates: [UninstallCandidate],
         createdAt: Date = Date(),
         expiresAt: Date? = nil,
         entitlementAttestation: SignedEntitlementAttestation? = nil) {
        self.issuanceID = issuanceID
        self.batchID = batchID
        self.app = app
        self.mode = mode
        self.candidates = candidates
        self.createdAt = createdAt
        self.expiresAt = expiresAt ?? createdAt.addingTimeInterval(Self.timeToLive)
        self.entitlementAttestation = entitlementAttestation
    }

    public mutating func toggle(_ id: UUID) {
        guard let index = candidates.firstIndex(where: { $0.id == id }) else { return }
        candidates[index].setSelected(!candidates[index].isSelected)
    }

    public mutating func setAll(_ selected: Bool) {
        for index in candidates.indices {
            let policy = candidates[index].selectionPolicy
            candidates[index].setSelected(selected
                                          && (policy == .required || policy == .recommended))
        }
    }

    public mutating func selectAll() { setAll(true) }

    public var allPolicySelected: Bool {
        !candidates.isEmpty && candidates.allSatisfy { candidate in
            switch candidate.selectionPolicy {
            case .required, .recommended: return candidate.isSelected
            case .manualOnly, .blocked: return !candidate.isSelected
            }
        }
    }

    var selectedItems: [CleanableItem] {
        candidates.filter(\.isSelected).map(\.item)
    }

    public var selectedCount: Int { candidates.filter(\.isSelected).count }
    public var selectedSize: Int64 {
        candidates.filter(\.isSelected).reduce(0) { $0 + $1.item.size }
    }
}
