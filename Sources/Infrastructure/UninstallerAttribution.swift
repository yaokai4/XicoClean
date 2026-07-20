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
    case trustedClockUnavailable
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
    case batchNotYetValid
    case batchAlreadyConsumed
    case entitlementAttestationChanged
    case launchAgentAttestationChanged
    case physicalPathAttestationChanged
    case duplicateTarget
    case evidenceFingerprintUnavailable
    case preparedTargetMismatch
    case preparationSealUnavailable
}

public struct SignedEntitlementAttestation: Sendable, Equatable {
    public let groups: [String]
    public let codeIdentifier: String
    public let uniqueCode: Data
    public let sourceIdentity: LocalFileIdentity
    let sourceSeal: AppBundleSourceSeal?

    package init(groups: [String], codeIdentifier: String, uniqueCode: Data,
                 sourceIdentity: LocalFileIdentity) {
        self.groups = groups
        self.codeIdentifier = codeIdentifier
        self.uniqueCode = uniqueCode
        self.sourceIdentity = sourceIdentity
        self.sourceSeal = nil
    }

    init(groups: [String], codeIdentifier: String, uniqueCode: Data,
         sourceIdentity: LocalFileIdentity,
         sourceSeal: AppBundleSourceSeal) {
        self.groups = groups
        self.codeIdentifier = codeIdentifier
        self.uniqueCode = uniqueCode
        self.sourceIdentity = sourceIdentity
        self.sourceSeal = sourceSeal
    }

    var isWithinBounds: Bool {
        guard let validated = BoundedSecuritySigningFields.validating(
            RawSecuritySigningFields(
                groups: groups, codeIdentifier: codeIdentifier, uniqueCode: uniqueCode,
                mainExecutableURL: URL(fileURLWithPath: "/bounded-attestation"))) else {
            return false
        }
        return groups == validated.groups
    }

    static func groupsAreWithinBounds(_ groups: [String]) -> Bool {
        BoundedSecuritySigningFields.validatedGroups(groups) != nil
    }
}

struct RawSecuritySigningFields: Sendable, Equatable {
    let groups: [String]
    let codeIdentifier: String
    let uniqueCode: Data
    let mainExecutableURL: URL
}

struct BoundedSecuritySigningFields: Sendable, Equatable {
    static let maximumUniqueCodeBytes = 64
    static let maximumExecutablePathBytes = 16 * 1024

    let groups: [String]
    let codeIdentifier: BundleIdentifier
    let uniqueCode: Data
    let mainExecutableCanonicalPath: String

    static func validating(_ raw: RawSecuritySigningFields) -> Self? {
        guard let codeIdentifier = BundleIdentifier(rawValue: raw.codeIdentifier),
              raw.mainExecutableURL.isFileURL,
              raw.mainExecutableURL.path.hasPrefix("/"),
              raw.mainExecutableURL.path.utf8.count <= maximumExecutablePathBytes,
              (1...maximumUniqueCodeBytes).contains(raw.uniqueCode.count),
              let groups = validatedGroups(raw.groups) else { return nil }
        return Self(groups: groups, codeIdentifier: codeIdentifier,
                    uniqueCode: raw.uniqueCode,
                    mainExecutableCanonicalPath: raw.mainExecutableURL.standardizedFileURL.path)
    }

    static func validatedGroups(_ rawGroups: [String]) -> [String]? {
        guard rawGroups.count <= SecurityEntitlementReader.maximumGroupCount,
              Set(rawGroups).count == rawGroups.count else { return nil }
        var aggregateBytes = 0
        for group in rawGroups {
            let byteCount = group.utf8.count
            let (next, overflow) = aggregateBytes.addingReportingOverflow(byteCount)
            guard Self.isValidGroup(group), !overflow,
                  next <= SecurityEntitlementReader.maximumGroupUTF8Bytes else { return nil }
            aggregateBytes = next
        }
        return rawGroups.sorted { lhs, rhs in
            lhs.utf8.lexicographicallyPrecedes(rhs.utf8)
        }
    }

    private static func isValidGroup(_ group: String) -> Bool {
        let byteCount = group.utf8.count
        guard !group.isEmpty, group != ".", group != "..", byteCount <= 255,
              !group.contains("/"), !group.contains("\\"), !group.contains("\0") else {
            return false
        }
        return !group.unicodeScalars.contains { scalar in
            scalar.value < 0x20 || scalar.value == 0x7f
        }
    }
}

enum StaticCodeValidationPolicy: Sendable, Equatable {
    case strictAllArchitecturesAndNestedCode
}

enum SigningInformationPolicy: Sendable, Equatable {
    case entitlementsAndGenericIdentity
}

protocol SecurityFrameworkSession: AnyObject, Sendable {
    func checkValidity(_ policy: StaticCodeValidationPolicy) -> Bool
    func copySigningFields(_ policy: SigningInformationPolicy) -> RawSecuritySigningFields?
}

protocol SecurityFrameworkSessionFactory: Sendable {
    func open(appURL: URL) -> (any SecurityFrameworkSession)?
}

protocol SecurityCodeSourceAttesting: Sendable {
    func capture(appURL: URL) -> AppBundleSourceSeal?
}

struct SystemSecurityCodeSourceAttestor: SecurityCodeSourceAttesting {
    func capture(appURL: URL) -> AppBundleSourceSeal? {
        FDAnchoredAppBundlePathAttestor(appURL: appURL).captureSourceSeal()
    }
}

struct SystemSecurityFrameworkSessionFactory: SecurityFrameworkSessionFactory {
    func open(appURL: URL) -> (any SecurityFrameworkSession)? {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(appURL as CFURL, [], &staticCode) == errSecSuccess,
              let staticCode else { return nil }
        return SystemSecurityFrameworkSession(staticCode: staticCode)
    }
}

private final class SystemSecurityFrameworkSession: @unchecked Sendable,
                                                    SecurityFrameworkSession {
    private let staticCode: SecStaticCode

    init(staticCode: SecStaticCode) { self.staticCode = staticCode }

    func checkValidity(_ policy: StaticCodeValidationPolicy) -> Bool {
        let flags: SecCSFlags
        switch policy {
        case .strictAllArchitecturesAndNestedCode:
            flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures
                               | kSecCSCheckNestedCode
                               | kSecCSStrictValidate)
        }
        return SecStaticCodeCheckValidity(staticCode, flags, nil) == errSecSuccess
    }

    func copySigningFields(_ policy: SigningInformationPolicy) -> RawSecuritySigningFields? {
        guard policy == .entitlementsAndGenericIdentity else { return nil }
        var signingInformation: CFDictionary?
        guard SecCodeCopySigningInformation(
                staticCode, SecCSFlags(rawValue: kSecCSSigningInformation),
                &signingInformation) == errSecSuccess,
              let signingInformation else { return nil }
        return SecuritySigningFieldsParser.parse(signingInformation)
    }
}

/// Bounds CoreFoundation values before bridging them into Swift-owned strings, arrays, or Data.
/// This prevents a malicious signature dictionary from forcing an unbounded temporary copy merely
/// to be rejected by accepted-value validation afterward.
enum SecuritySigningFieldsParser {
    static func parse(_ dictionary: CFDictionary) -> RawSecuritySigningFields? {
        guard let identifierValue = value(in: dictionary, key: kSecCodeInfoIdentifier),
              CFGetTypeID(identifierValue) == CFStringGetTypeID(),
              utf8Length(unsafeDowncast(identifierValue, to: CFString.self),
                         maximum: 255) != nil,
              let uniqueValue = value(in: dictionary, key: kSecCodeInfoUnique),
              CFGetTypeID(uniqueValue) == CFDataGetTypeID(),
              (1...BoundedSecuritySigningFields.maximumUniqueCodeBytes)
                .contains(CFDataGetLength(unsafeDowncast(uniqueValue, to: CFData.self))),
              let executableValue = value(in: dictionary, key: kSecCodeInfoMainExecutable),
              CFGetTypeID(executableValue) == CFURLGetTypeID() else { return nil }
        let identifier = unsafeDowncast(identifierValue, to: CFString.self)
        let unique = unsafeDowncast(uniqueValue, to: CFData.self)
        let executable = unsafeDowncast(executableValue, to: CFURL.self)
        guard utf8Length(CFURLGetString(executable),
                         maximum: BoundedSecuritySigningFields.maximumExecutablePathBytes)
                != nil else { return nil }

        let groups: [String]
        if let entitlementsValue = value(in: dictionary, key: kSecCodeInfoEntitlementsDict) {
            guard CFGetTypeID(entitlementsValue) == CFDictionaryGetTypeID(),
                  let parsed = boundedGroups(
                    in: unsafeDowncast(entitlementsValue, to: CFDictionary.self)) else {
                return nil
            }
            groups = parsed
        } else {
            groups = []
        }

        let mainExecutableURL = executable as URL
        guard mainExecutableURL.isFileURL, mainExecutableURL.path.hasPrefix("/") else { return nil }
        return RawSecuritySigningFields(
            groups: groups,
            codeIdentifier: identifier as String,
            uniqueCode: unique as Data,
            mainExecutableURL: mainExecutableURL)
    }

    private static func boundedGroups(in entitlements: CFDictionary) -> [String]? {
        let groupsKey = "com.apple.security.application-groups" as CFString
        guard let groupsValue = value(in: entitlements, key: groupsKey) else { return [] }
        guard CFGetTypeID(groupsValue) == CFArrayGetTypeID() else { return nil }
        let array = unsafeDowncast(groupsValue, to: CFArray.self)
        let count = CFArrayGetCount(array)
        guard count <= SecurityEntitlementReader.maximumGroupCount else { return nil }

        var aggregate = 0
        var groups: [String] = []
        groups.reserveCapacity(count)
        for index in 0..<count {
            guard let raw = CFArrayGetValueAtIndex(array, index) else { return nil }
            let value = Unmanaged<CFTypeRef>.fromOpaque(raw).takeUnretainedValue()
            guard CFGetTypeID(value) == CFStringGetTypeID(),
                  let bytes = utf8Length(unsafeDowncast(value, to: CFString.self),
                                         maximum: 255) else { return nil }
            let string = unsafeDowncast(value, to: CFString.self)
            let (next, overflow) = aggregate.addingReportingOverflow(bytes)
            guard !overflow, next <= SecurityEntitlementReader.maximumGroupUTF8Bytes else {
                return nil
            }
            aggregate = next
            groups.append(string as String)
        }
        return groups
    }

    private static func value(in dictionary: CFDictionary,
                              key: CFString) -> CFTypeRef? {
        let keyPointer = Unmanaged.passUnretained(key).toOpaque()
        guard let raw = CFDictionaryGetValue(dictionary, keyPointer) else { return nil }
        return Unmanaged<CFTypeRef>.fromOpaque(raw).takeUnretainedValue()
    }

    private static func utf8Length(_ string: CFString, maximum: Int) -> Int? {
        let scalarLength = CFStringGetLength(string)
        guard scalarLength <= maximum else { return nil }
        var usedBytes = 0
        let converted = CFStringGetBytes(
            string, CFRange(location: 0, length: scalarLength),
            CFStringBuiltInEncodings.UTF8.rawValue, 0, false,
            nil, 0, &usedBytes)
        guard converted == scalarLength, usedBytes <= maximum else { return nil }
        return usedBytes
    }
}

struct StableSecurityCodeSnapshot: Sendable, Equatable {
    let signing: BoundedSecuritySigningFields
    let source: AppBundleSourceSeal
}

/// Injected boundary for a bounded signature-validated application-group attestation.
/// `nil` means the signature, identity, or payload bounds could not be verified.
public protocol EntitlementReader: Sendable {
    func attestation(for appURL: URL) -> SignedEntitlementAttestation?
}

public struct SecurityEntitlementReader: EntitlementReader {
    public static let maximumGroupCount = 128
    public static let maximumGroupUTF8Bytes = 16 * 1024

    private let sessionFactory: any SecurityFrameworkSessionFactory
    private let sourceAttestor: any SecurityCodeSourceAttesting

    public init() {
        sessionFactory = SystemSecurityFrameworkSessionFactory()
        sourceAttestor = SystemSecurityCodeSourceAttestor()
    }

    init(sessionFactory: any SecurityFrameworkSessionFactory,
         sourceAttestor: any SecurityCodeSourceAttesting) {
        self.sessionFactory = sessionFactory
        self.sourceAttestor = sourceAttestor
    }

    public func attestation(for appURL: URL) -> SignedEntitlementAttestation? {
        guard let first = onePhase(appURL: appURL, sessionFactory: sessionFactory,
                                   sourceAttestor: sourceAttestor),
              let second = onePhase(appURL: appURL, sessionFactory: sessionFactory,
                                    sourceAttestor: sourceAttestor),
              first == second else { return nil }
        let signing = second.signing
        return SignedEntitlementAttestation(
            groups: signing.groups,
            codeIdentifier: signing.codeIdentifier.rawValue,
            uniqueCode: signing.uniqueCode,
            sourceIdentity: second.source.appRoot,
            sourceSeal: second.source)
    }

    private func onePhase(
        appURL: URL,
        sessionFactory: any SecurityFrameworkSessionFactory,
        sourceAttestor: any SecurityCodeSourceAttesting
    ) -> StableSecurityCodeSnapshot? {
        guard let sourceBefore = sourceAttestor.capture(appURL: appURL),
              let session = sessionFactory.open(appURL: appURL),
              session.checkValidity(.strictAllArchitecturesAndNestedCode),
              let raw = session.copySigningFields(.entitlementsAndGenericIdentity),
              let signing = BoundedSecuritySigningFields.validating(raw),
              signing.mainExecutableCanonicalPath == sourceBefore.mainExecutableCanonicalPath,
              session.checkValidity(.strictAllArchitecturesAndNestedCode),
              let sourceAfter = sourceAttestor.capture(appURL: appURL),
              sourceAfter == sourceBefore else { return nil }
        return StableSecurityCodeSnapshot(signing: signing, source: sourceAfter)
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
    public let plistExactLength: Int
    public let plistContentDigest: EvidenceFingerprint
    public let resolvedProgramPath: String?
    public let programIdentity: LocalFileIdentity?
    let programChangeToken: ProgramChangeToken?

    package init(record: LaunchAgentRecord,
                 plistIdentity: LocalFileIdentity,
                 plistExactLength: Int = 0,
                 plistContentDigest: EvidenceFingerprint = .none,
                 resolvedProgramPath: String?,
                 programIdentity: LocalFileIdentity?) {
        self.init(record: record, plistIdentity: plistIdentity,
                  plistExactLength: plistExactLength,
                  plistContentDigest: plistContentDigest,
                  resolvedProgramPath: resolvedProgramPath,
                  programIdentity: programIdentity,
                  programChangeToken: nil)
    }

    private init(record: LaunchAgentRecord,
                 plistIdentity: LocalFileIdentity,
                 plistExactLength: Int,
                 plistContentDigest: EvidenceFingerprint,
                 resolvedProgramPath: String?,
                 programIdentity: LocalFileIdentity?,
                 programChangeToken: ProgramChangeToken?) {
        self.record = record
        self.plistIdentity = plistIdentity
        self.plistExactLength = plistExactLength
        self.plistContentDigest = plistContentDigest
        self.resolvedProgramPath = resolvedProgramPath
        self.programIdentity = programIdentity
        self.programChangeToken = programChangeToken
    }

    static func capture(record: LaunchAgentRecord, plistURL: URL) -> LaunchAgentAttestation? {
        guard let read = BoundedRegularFileReader.read(
            at: plistURL, maximumBytes: PlistLaunchAgentReader.maximumBytes) else { return nil }
        return capture(record: record,
                       plistFile: BoundedFileAttestation(
                        identity: read.identity, exactLength: read.exactLength,
                        contentDigest: read.contentDigest))
    }

    static func capture(record: LaunchAgentRecord,
                        plistIdentity: LocalFileIdentity) -> LaunchAgentAttestation {
        capture(record: record,
                plistFile: BoundedFileAttestation(identity: plistIdentity, exactLength: 0,
                                                  contentDigest: .none))
    }

    static func capture(record: LaunchAgentRecord,
                        plistFile: BoundedFileAttestation) -> LaunchAgentAttestation {
        return LaunchAgentAttestation(record: record, plistIdentity: plistFile.identity,
                                      plistExactLength: plistFile.exactLength,
                                      plistContentDigest: plistFile.contentDigest,
                                      resolvedProgramPath: nil,
                                      programIdentity: nil)
    }

    func bindingProgram(to appURL: URL) -> LaunchAgentAttestation {
        guard let executable = record.executablePath, executable.hasPrefix("/"),
              let token = FDAnchoredAppBundlePathAttestor(appURL: appURL).programToken(
                absoluteURL: URL(fileURLWithPath: executable),
                maximumDigestBytes: 16 * 1_048_576) else {
            return LaunchAgentAttestation(
                record: record, plistIdentity: plistIdentity,
                plistExactLength: plistExactLength,
                plistContentDigest: plistContentDigest,
                resolvedProgramPath: nil, programIdentity: nil,
                programChangeToken: nil)
        }
        return LaunchAgentAttestation(
            record: record, plistIdentity: plistIdentity,
            plistExactLength: plistExactLength,
            plistContentDigest: plistContentDigest,
            resolvedProgramPath: token.canonicalPath,
            programIdentity: token.executable,
            programChangeToken: token)
    }

}

package protocol LaunchAgentReader: Sendable {
    func attestation(at url: URL,
                     anchoredRead: AnchoredRegularFileRead) -> LaunchAgentAttestation?
}

public struct PlistLaunchAgentReader: LaunchAgentReader {
    public static let maximumBytes = 1_048_576
    private let afterRead: @Sendable () -> Void

    public init(afterRead: @escaping @Sendable () -> Void = {}) {
        self.afterRead = afterRead
    }

    package func attestation(at url: URL,
                             anchoredRead: AnchoredRegularFileRead) -> LaunchAgentAttestation? {
        afterRead()
        return parse(data: anchoredRead.data, file: anchoredRead.fileAttestation)
    }

    public func attestation(at url: URL) -> LaunchAgentAttestation? {
        guard let read = BoundedRegularFileReader.read(at: url,
                                                       maximumBytes: Self.maximumBytes,
                                                       afterRead: afterRead) else { return nil }
        return parse(data: read.data,
                     file: BoundedFileAttestation(identity: read.identity,
                                                  exactLength: read.exactLength,
                                                  contentDigest: read.contentDigest))
    }

    private func parse(data: Data,
                       file: BoundedFileAttestation) -> LaunchAgentAttestation? {
        guard let plist = try? PropertyListSerialization.propertyList(from: data,
                                                                      options: [], format: nil),
              let dictionary = plist as? [String: Any] else { return nil }
        let record = LaunchAgentRecord(
            label: dictionary["Label"] as? String,
            program: dictionary["Program"] as? String,
            programArguments: dictionary["ProgramArguments"] as? [String] ?? [])
        return LaunchAgentAttestation.capture(record: record, plistFile: file)
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
    case physicalPath(PhysicalPathAttestation)
    case signedEntitlement(SignedEntitlementAttestation, PhysicalPathAttestation)
    case launchAgent(LaunchAgentAttestation, PhysicalPathAttestation)

    var physicalPath: PhysicalPathAttestation? {
        switch self {
        case .none: return nil
        case .physicalPath(let path): return path
        case .signedEntitlement(_, let path): return path
        case .launchAgent(_, let path): return path
        }
    }
}

enum CandidateEvidenceSource: Sendable {
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

    var targetRequest: TargetRequest { targetRequest(with: .none) }

    func targetRequest(with evidenceFingerprint: EvidenceFingerprint) -> TargetRequest {
        TargetRequest(canonicalPath: url.standardizedFileURL.path,
                      recoverability: .trashRestorable,
                      riskLevel: .low,
                      attribution: evidence.domainValue,
                      evidenceFingerprint: evidenceFingerprint)
    }
}

/// Service-issued, app/mode-bound candidate inventory. Its initializer and candidate mutation are
/// module-internal so Features can only alter selection through the policy-aware methods below.
public struct UninstallBatch: Sendable {
    public static let timeToLive: TimeInterval = 5 * 60
    static let timeToLiveNanoseconds: UInt64 = 300_000_000_000

    let issuanceID: UUID
    let batchID: UUID
    public let app: InstalledApp
    public let mode: UninstallMode
    public let createdAt: Date
    public let expiresAt: Date
    let entitlementAttestation: SignedEntitlementAttestation?
    let claimToken: UninstallBatchClaimToken
    public private(set) var candidates: [UninstallCandidate]

    init(issuanceID: UUID,
         batchID: UUID,
         app: InstalledApp,
         mode: UninstallMode,
         candidates: [UninstallCandidate],
         createdAt: Date = Date(),
         expiresAt: Date? = nil,
         entitlementAttestation: SignedEntitlementAttestation? = nil,
         claimToken: UninstallBatchClaimToken? = nil) {
        self.issuanceID = issuanceID
        self.batchID = batchID
        self.app = app
        self.mode = mode
        self.candidates = candidates
        self.createdAt = createdAt
        self.expiresAt = expiresAt ?? createdAt.addingTimeInterval(Self.timeToLive)
        self.entitlementAttestation = entitlementAttestation
        if let claimToken {
            self.claimToken = claimToken
        } else {
            let clock = SystemUninstallTrustedClock()
            self.claimToken = UninstallBatchClaimToken.make(
                clock: clock,
                issuedAtNanoseconds: clock.monotonicNowNanoseconds(),
                lifetimeNanoseconds: Self.timeToLiveNanoseconds)
                ?? UninstallBatchClaimToken.failClosedExpired(clock: clock)
        }
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

    /// Applies a trusted occurrence transition produced by Infrastructure's execution terminal.
    /// Feature code cannot choose indices because this mutator is module-internal.
    mutating func removeCandidates(atOriginalIndices removed: Set<Int>) {
        candidates = candidates.enumerated().compactMap { index, candidate in
            removed.contains(index) ? nil : candidate
        }
    }

    public var allPolicySelected: Bool {
        !candidates.isEmpty && candidates.allSatisfy { candidate in
            switch candidate.selectionPolicy {
            case .required, .recommended: return candidate.isSelected
            case .manualOnly, .blocked: return !candidate.isSelected
            }
        }
    }

    public var selectedCount: Int { candidates.filter(\.isSelected).count }
    public var selectedSize: Int64 {
        candidates.filter(\.isSelected).reduce(0) { $0 + $1.item.size }
    }
}
