import Foundation
import Domain

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
    case exactBundleIDPath
    case signedApplicationGroup
    case launchAgentProgramInsideBundle
    case displayNameHeuristic
    case unverified

    var domainValue: Domain.AttributionEvidence {
        switch self {
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
}

/// Injected boundary for reading the signed application's application-group entitlement.
/// `nil` means the signature/entitlement could not be verified and therefore proves no ownership.
public protocol EntitlementReader: Sendable {
    func applicationGroups(for appURL: URL) -> [String]?
}

public struct CodesignEntitlementReader: EntitlementReader {
    public init() {}

    public func applicationGroups(for appURL: URL) -> [String]? {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        process.arguments = ["--display", "--entitlements", ":-", appURL.path]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        // Drain while codesign is running so an unusually large entitlement plist cannot fill
        // the pipe and deadlock a wait-before-read sequence.
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        guard let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let dictionary = plist as? [String: Any],
              let groups = dictionary["com.apple.security.application-groups"] as? [String] else {
            return nil
        }
        return groups
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
    public init() {}

    public func launchAgent(at url: URL) -> LaunchAgentRecord? {
        guard let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let dictionary = plist as? [String: Any] else { return nil }
        return LaunchAgentRecord(
            label: dictionary["Label"] as? String,
            program: dictionary["Program"] as? String,
            programArguments: dictionary["ProgramArguments"] as? [String] ?? [])
    }
}

public struct UninstallCandidate: Identifiable, Sendable {
    public private(set) var item: CleanableItem
    public let evidence: OwnershipEvidence
    public let selectionPolicy: SelectionPolicy
    public let recoveryHint: String

    public init(item: CleanableItem,
                evidence: OwnershipEvidence,
                selectionPolicy: SelectionPolicy,
                recoveryHint: String = "Moved to Trash; restore it from Finder Trash if needed.") {
        var item = item
        item.isSelected = selectionPolicy.defaultSelected
        self.item = item
        self.evidence = evidence
        self.selectionPolicy = selectionPolicy
        self.recoveryHint = recoveryHint
    }

    public var id: UUID { item.id }
    public var url: URL { item.url }
    public var isSelected: Bool { item.isSelected }
    public var isSelectable: Bool { selectionPolicy.isSelectable }

    public mutating func setSelected(_ selected: Bool) {
        switch selectionPolicy {
        case .required:
            item.isSelected = true
        case .recommended, .manualOnly:
            item.isSelected = selected
        case .blocked:
            item.isSelected = false
        }
    }

    public static func selectAll(_ candidates: [UninstallCandidate]) -> [UninstallCandidate] {
        candidates.map { candidate in
            var candidate = candidate
            candidate.setSelected(candidate.selectionPolicy == .required
                                  || candidate.selectionPolicy == .recommended)
            return candidate
        }
    }

    public var targetRequest: TargetRequest {
        TargetRequest(canonicalPath: url.standardizedFileURL.path,
                      recoverability: .trashRestorable,
                      riskLevel: .low,
                      attribution: evidence.domainValue)
    }
}
