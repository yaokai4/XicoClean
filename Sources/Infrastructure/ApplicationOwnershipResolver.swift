import Foundation
import Shared

public struct ApplicationMetadata: Sendable, Equatable {
    public let bundleIdentifier: String?
    public let displayName: String?

    public init(bundleIdentifier: String?, displayName: String?) {
        self.bundleIdentifier = bundleIdentifier
        self.displayName = displayName
    }
}

public protocol ApplicationMetadataProviding: Sendable {
    func metadata(forApplicationAt path: String) -> ApplicationMetadata
}

public struct BundleApplicationMetadataProvider: ApplicationMetadataProviding {
    public init() {}

    public func metadata(forApplicationAt path: String) -> ApplicationMetadata {
        guard let bundle = Bundle(url: URL(fileURLWithPath: path)) else {
            return ApplicationMetadata(bundleIdentifier: nil, displayName: nil)
        }
        let displayName = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? bundle.object(forInfoDictionaryKey: "CFBundleName") as? String
        return ApplicationMetadata(bundleIdentifier: bundle.bundleIdentifier, displayName: displayName)
    }
}

public struct ResolvedApplicationOwnership: Sendable, Equatable {
    public let identity: ApplicationIdentity
    public let displayName: String
    public let bundleIdentifier: String?
    public let bundlePath: String?
}

public struct ApplicationOwnershipResolver: Sendable {
    private let metadataProvider: any ApplicationMetadataProviding

    public init(metadataProvider: any ApplicationMetadataProviding = BundleApplicationMetadataProvider()) {
        self.metadataProvider = metadataProvider
    }

    public static func outermostApplicationPath(in executablePath: String) -> String? {
        let components = (executablePath as NSString).pathComponents
        guard let applicationIndex = components.firstIndex(where: { $0.hasSuffix(".app") }) else {
            return nil
        }
        return NSString.path(withComponents: Array(components[...applicationIndex]))
    }

    public func resolve(
        _ records: [ProcessResourceRecord]
    ) -> [ProcessIdentity: ResolvedApplicationOwnership] {
        let byPID = Dictionary(uniqueKeysWithValues: records.map { ($0.pid, $0) })
        var resolved: [ProcessIdentity: ResolvedApplicationOwnership] = [:]
        var visiting: Set<ProcessIdentity> = []

        func ownership(for record: ProcessResourceRecord) -> ResolvedApplicationOwnership {
            let process = ProcessIdentity(
                pid: record.pid,
                startTimeNanoseconds: record.startTimeNanoseconds
            )
            if let existing = resolved[process] { return existing }

            if let path = record.executablePath,
               let applicationPath = Self.outermostApplicationPath(in: path) {
                let metadata = metadataProvider.metadata(forApplicationAt: applicationPath)
                let fallbackName = ((applicationPath as NSString).lastPathComponent as NSString)
                    .deletingPathExtension
                let result = ResolvedApplicationOwnership(
                    identity: ApplicationIdentity(
                        rawValue: metadata.bundleIdentifier.map { "bundle:\($0)" }
                            ?? "app:\(applicationPath)"
                    ),
                    displayName: metadata.displayName ?? fallbackName,
                    bundleIdentifier: metadata.bundleIdentifier,
                    bundlePath: applicationPath
                )
                resolved[process] = result
                return result
            }

            if visiting.insert(process).inserted {
                if let parent = byPID[record.parentPID] {
                    let parentIdentity = ProcessIdentity(
                        pid: parent.pid,
                        startTimeNanoseconds: parent.startTimeNanoseconds
                    )
                    if !visiting.contains(parentIdentity) {
                        let result = ownership(for: parent)
                        resolved[process] = result
                        visiting.remove(process)
                        return result
                    }
                }
                visiting.remove(process)
            }

            let result: ResolvedApplicationOwnership
            if let path = record.executablePath {
                result = ResolvedApplicationOwnership(
                    identity: ApplicationIdentity(rawValue: "exec:\(path)"),
                    displayName: record.name,
                    bundleIdentifier: nil,
                    bundlePath: nil
                )
            } else {
                result = ResolvedApplicationOwnership(
                    identity: ApplicationIdentity(rawValue: "name:\(record.name)"),
                    displayName: record.name,
                    bundleIdentifier: nil,
                    bundlePath: nil
                )
            }
            resolved[process] = result
            return result
        }

        for record in records {
            _ = ownership(for: record)
        }
        return resolved
    }
}
