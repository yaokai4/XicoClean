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
    private let preferredLanguages: @Sendable () -> [String]

    public init(
        preferredLanguages: @escaping @Sendable () -> [String] = {
            Locale.preferredLanguages
        }
    ) {
        self.preferredLanguages = preferredLanguages
    }

    public func metadata(forApplicationAt path: String) -> ApplicationMetadata {
        let applicationURL = URL(fileURLWithPath: path, isDirectory: true)
        let contentsURL = applicationURL.appendingPathComponent("Contents", isDirectory: true)
        let infoURL = contentsURL.appendingPathComponent("Info.plist", isDirectory: false)
        guard let data = try? Data(contentsOf: infoURL, options: .mappedIfSafe),
              let dictionary = try? PropertyListSerialization.propertyList(
                from: data,
                options: [],
                format: nil
              ) as? [String: Any] else {
            return ApplicationMetadata(bundleIdentifier: nil, displayName: nil)
        }
        let resourcesURL = contentsURL.appendingPathComponent("Resources", isDirectory: true)
        let localizations = dictionary["CFBundleLocalizations"] as? [String] ?? []
        let preferences = preferredLanguages()
        var localizationCandidates = localizations.isEmpty
            ? []
            : Bundle.preferredLocalizations(
                from: localizations,
                forPreferences: preferences
            )
        // Without an explicit localization inventory, only the highest-priority
        // user language can be selected faithfully. Try its exact/script/language
        // fallbacks, then the bundle development region below; probing every user
        // language multiplies failed filesystem opens for each running app.
        for preference in preferences.prefix(1) {
            let normalized = preference.replacingOccurrences(of: "_", with: "-")
            let components = normalized.split(separator: "-").map(String.init)
            let candidates: [String]
            if components.count >= 2, components[1].count == 4 {
                candidates = [normalized, "\(components[0])-\(components[1])", components[0]]
            } else {
                candidates = [normalized, components.first ?? normalized]
            }
            for candidate in candidates where !localizationCandidates.contains(candidate) {
                localizationCandidates.append(candidate)
            }
        }
        if let developmentRegion = dictionary["CFBundleDevelopmentRegion"] as? String,
           !localizationCandidates.contains(developmentRegion) {
            localizationCandidates.append(developmentRegion)
        }
        if localizations.contains("Base"), !localizationCandidates.contains("Base") {
            localizationCandidates.append("Base")
        }
        if !localizationCandidates.contains("Base") { localizationCandidates.append("Base") }
        if !localizationCandidates.contains("en") { localizationCandidates.append("en") }
        var localizedDictionary: [String: Any] = [:]
        for localization in localizationCandidates {
            let stringsURL = resourcesURL
                .appendingPathComponent("\(localization).lproj", isDirectory: true)
                .appendingPathComponent("InfoPlist.strings", isDirectory: false)
            guard let stringsData = try? Data(contentsOf: stringsURL, options: .mappedIfSafe),
                  let strings = try? PropertyListSerialization.propertyList(
                      from: stringsData,
                      options: [],
                      format: nil
                  ) as? [String: Any] else {
                continue
            }
            localizedDictionary = strings
            break
        }
        let displayName = localizedDictionary["CFBundleDisplayName"] as? String
            ?? localizedDictionary["CFBundleName"] as? String
            ?? dictionary["CFBundleDisplayName"] as? String
            ?? dictionary["CFBundleName"] as? String
        return ApplicationMetadata(
            bundleIdentifier: dictionary["CFBundleIdentifier"] as? String,
            displayName: displayName
        )
    }
}

public struct ResolvedApplicationOwnership: Sendable, Equatable {
    public let identity: ApplicationIdentity
    public let displayName: String
    public let bundleIdentifier: String?
    public let bundlePath: String?
}

private final class ApplicationMetadataCache: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: ApplicationMetadata] = [:]

    func metadata(
        forApplicationAt path: String,
        load: () -> ApplicationMetadata
    ) -> ApplicationMetadata {
        if let cached = lock.withLock({ values[path] }) { return cached }
        let loaded = load()
        return lock.withLock {
            if let cached = values[path] { return cached }
            values[path] = loaded
            return loaded
        }
    }
}

private final class ApplicationOwnershipCache: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [ProcessIdentity: ResolvedApplicationOwnership] = [:]
    private var lastActiveIdentities: Set<ProcessIdentity>?
    private var lastResolved: [ProcessIdentity: ResolvedApplicationOwnership] = [:]
    private var misses = 0

    var cacheMissCount: Int { lock.withLock { misses } }

    func exact(
        for activeIdentities: Set<ProcessIdentity>
    ) -> [ProcessIdentity: ResolvedApplicationOwnership]? {
        lock.withLock {
            guard lastActiveIdentities == activeIdentities else {
                misses += 1
                return nil
            }
            return lastResolved
        }
    }

    func retained(
        for activeIdentities: Set<ProcessIdentity>
    ) -> [ProcessIdentity: ResolvedApplicationOwnership] {
        lock.withLock {
            var retained: [ProcessIdentity: ResolvedApplicationOwnership] = [:]
            retained.reserveCapacity(activeIdentities.count)
            for identity in activeIdentities {
                if let ownership = values[identity] {
                    retained[identity] = ownership
                }
            }
            return retained
        }
    }

    func storeOwnerships(
        _ ownerships: [ProcessIdentity: ResolvedApplicationOwnership],
        cacheableIdentities: Set<ProcessIdentity>,
        activeIdentities: Set<ProcessIdentity>
    ) {
        lock.withLock {
            if values.count > 4_096 {
                values = values.filter { activeIdentities.contains($0.key) }
            }
            for identity in cacheableIdentities {
                if let ownership = ownerships[identity] {
                    values[identity] = ownership
                }
            }
            lastActiveIdentities = activeIdentities
            lastResolved = ownerships
        }
    }
}

public struct ApplicationOwnershipResolver: Sendable {
    private let metadataProvider: any ApplicationMetadataProviding
    private let metadataCache: ApplicationMetadataCache
    private let ownershipCache: ApplicationOwnershipCache
    private let applicationPathResolver: @Sendable (String) -> String?

    var cacheMissCount: Int { ownershipCache.cacheMissCount }

    public init(
        metadataProvider: any ApplicationMetadataProviding = BundleApplicationMetadataProvider(),
        applicationPathResolver: @escaping @Sendable (String) -> String? = {
            ApplicationOwnershipResolver.outermostApplicationPath(in: $0)
        }
    ) {
        self.metadataProvider = metadataProvider
        self.metadataCache = ApplicationMetadataCache()
        self.ownershipCache = ApplicationOwnershipCache()
        self.applicationPathResolver = applicationPathResolver
    }

    public static func outermostApplicationPath(in executablePath: String) -> String? {
        if executablePath.hasSuffix(".app") { return executablePath }
        guard let marker = executablePath.range(of: ".app/") else { return nil }
        return String(executablePath[..<marker.lowerBound]) + ".app"
    }

    public func resolve(
        _ records: [ProcessResourceRecord]
    ) -> [ProcessIdentity: ResolvedApplicationOwnership] {
        let activeIdentities = Set(records.map {
            ProcessIdentity(pid: $0.pid, startTimeNanoseconds: $0.startTimeNanoseconds)
        })
        if let exact = ownershipCache.exact(for: activeIdentities) {
            return exact
        }
        let byPID = Dictionary(uniqueKeysWithValues: records.map { ($0.pid, $0) })
        var resolved = ownershipCache.retained(for: activeIdentities)
        var cacheableIdentities = Set(resolved.keys)
        var applicationPathByProcess: [ProcessIdentity: String] = [:]
        applicationPathByProcess.reserveCapacity(records.count)
        for record in records {
            let identity = ProcessIdentity(
                pid: record.pid,
                startTimeNanoseconds: record.startTimeNanoseconds
            )
            guard resolved[identity] == nil,
                  let executablePath = record.executablePath,
                  let applicationPath = applicationPathResolver(executablePath) else {
                continue
            }
            applicationPathByProcess[identity] = applicationPath
        }
        let applicationPaths = Array(Set(applicationPathByProcess.values)).sorted()
        let workerCount = min(8, applicationPaths.count)
        if workerCount > 0 {
            let provider = metadataProvider
            let cache = metadataCache
            DispatchQueue.concurrentPerform(iterations: workerCount) { worker in
                for index in stride(from: worker, to: applicationPaths.count, by: workerCount) {
                    let path = applicationPaths[index]
                    _ = cache.metadata(forApplicationAt: path) {
                        provider.metadata(forApplicationAt: path)
                    }
                }
            }
        }
        var visiting: Set<ProcessIdentity> = []

        func ownership(for record: ProcessResourceRecord) -> ResolvedApplicationOwnership {
            let process = ProcessIdentity(
                pid: record.pid,
                startTimeNanoseconds: record.startTimeNanoseconds
            )
            if let existing = resolved[process] { return existing }

            if let applicationPath = applicationPathByProcess[process] {
                let metadata = metadataCache.metadata(forApplicationAt: applicationPath) {
                    metadataProvider.metadata(forApplicationAt: applicationPath)
                }
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
                cacheableIdentities.insert(process)
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
                        if cacheableIdentities.contains(parentIdentity) {
                            cacheableIdentities.insert(process)
                        }
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
            if record.parentPID == 0 || record.parentPID == 1 {
                cacheableIdentities.insert(process)
            }
            return result
        }

        for record in records {
            _ = ownership(for: record)
        }
        ownershipCache.storeOwnerships(
            resolved,
            cacheableIdentities: cacheableIdentities,
            activeIdentities: activeIdentities
        )
        return resolved
    }
}
