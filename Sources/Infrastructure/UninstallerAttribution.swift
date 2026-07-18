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
}

public enum UninstallPlanError: Error, Sendable, Equatable {
    case foreignBatch
    case foreignCandidate
    case requiredAppBodyMissing
    case modeInvariantViolation
    case invalidSelectedCandidate
    case emptySelection
    case authorizationUnavailable
}

/// Injected boundary for reading the signed application's application-group entitlement.
/// `nil` means the signature/entitlement could not be verified and therefore proves no ownership.
public protocol EntitlementReader: Sendable {
    func applicationGroups(for appURL: URL) -> [String]?
}

public struct SecurityEntitlementReader: EntitlementReader {
    public init() {}

    public func applicationGroups(for appURL: URL) -> [String]? {
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
              let entitlements = dictionary[kSecCodeInfoEntitlementsDict as String]
                as? [String: Any] else { return nil }
        return entitlements["com.apple.security.application-groups"] as? [String]
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

public protocol LaunchAgentReader: Sendable {
    func launchAgent(at url: URL) -> LaunchAgentRecord?
}

public struct PlistLaunchAgentReader: LaunchAgentReader {
    public static let maximumBytes = 1_048_576

    public init() {}

    public func launchAgent(at url: URL) -> LaunchAgentRecord? {
        guard let data = Self.readBoundedRegularFile(at: url),
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let dictionary = plist as? [String: Any] else { return nil }
        return LaunchAgentRecord(
            label: dictionary["Label"] as? String,
            program: dictionary["Program"] as? String,
            programArguments: dictionary["ProgramArguments"] as? [String] ?? [])
    }

    private static func readBoundedRegularFile(at url: URL) -> Data? {
        #if canImport(Darwin)
        var pathStat = stat()
        guard lstat(url.path, &pathStat) == 0,
              (pathStat.st_mode & S_IFMT) == S_IFREG,
              pathStat.st_size >= 0,
              pathStat.st_size <= maximumBytes else { return nil }

        let descriptor = open(url.path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }

        var openedStat = stat()
        guard fstat(descriptor, &openedStat) == 0,
              (openedStat.st_mode & S_IFMT) == S_IFREG,
              openedStat.st_dev == pathStat.st_dev,
              openedStat.st_ino == pathStat.st_ino,
              openedStat.st_size >= 0,
              openedStat.st_size <= maximumBytes else { return nil }

        var data = Data()
        data.reserveCapacity(Int(openedStat.st_size))
        var buffer = [UInt8](repeating: 0, count: 32 * 1024)
        while true {
            let count = read(descriptor, &buffer, buffer.count)
            if count == 0 { return data }
            if count < 0 {
                if errno == EINTR { continue }
                return nil
            }
            guard data.count + count <= maximumBytes else { return nil }
            data.append(contentsOf: buffer.prefix(count))
        }
        #else
        return nil
        #endif
    }
}

public enum UninstallCandidateRole: String, Sendable, Equatable {
    case appBody
    case associatedFile
}

public struct UninstallCandidate: Identifiable, Sendable {
    public private(set) var item: CleanableItem
    public let evidence: OwnershipEvidence
    public let selectionPolicy: SelectionPolicy
    public let role: UninstallCandidateRole
    public let recoveryHint: String
    let batchID: UUID

    init(item: CleanableItem,
         evidence: OwnershipEvidence,
         selectionPolicy: SelectionPolicy,
         role: UninstallCandidateRole,
         batchID: UUID,
         recoveryHint: String = "Moved to Trash; restore it from Finder Trash if needed.") {
        var item = item
        item.isSelected = selectionPolicy.defaultSelected
        self.item = item
        self.evidence = evidence
        self.selectionPolicy = selectionPolicy
        self.role = role
        self.batchID = batchID
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
    let issuanceID: UUID
    let batchID: UUID
    public let app: InstalledApp
    public let mode: UninstallMode
    public private(set) var candidates: [UninstallCandidate]

    init(issuanceID: UUID,
         batchID: UUID,
         app: InstalledApp,
         mode: UninstallMode,
         candidates: [UninstallCandidate]) {
        self.issuanceID = issuanceID
        self.batchID = batchID
        self.app = app
        self.mode = mode
        self.candidates = candidates
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
