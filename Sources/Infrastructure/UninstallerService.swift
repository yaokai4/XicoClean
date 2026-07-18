import Foundation
import Domain

public struct InstalledApp: Identifiable, Sendable, Hashable {
    public let id: String
    public let name: String
    public let bundleID: String
    public let url: URL
    public let size: Int64
    let provenanceID: UUID
    let sourceIdentity: LocalFileIdentity
    let metadataIdentity: LocalFileIdentity

    init(id: String, name: String, bundleID: String, url: URL, size: Int64,
         provenanceID: UUID, sourceIdentity: LocalFileIdentity,
         metadataIdentity: LocalFileIdentity) {
        self.id = id
        self.name = name
        self.bundleID = bundleID
        self.url = url
        self.size = size
        self.provenanceID = provenanceID
        self.sourceIdentity = sourceIdentity
        self.metadataIdentity = metadataIdentity
    }

    func withSize(_ size: Int64) -> InstalledApp {
        InstalledApp(id: id, name: name, bundleID: bundleID, url: url, size: size,
                     provenanceID: provenanceID, sourceIdentity: sourceIdentity,
                     metadataIdentity: metadataIdentity)
    }
}

/// 卸载器：枚举已安装应用，定位其关联文件，生成可预览的卸载计划。
public struct UninstallerService: Sendable {
    private let fs: FileSystemService
    private let safety: SafetyEngine
    private let home: URL
    private let entitlementReader: any EntitlementReader
    private let launchAgentReader: any LaunchAgentReader
    private let issuanceID: UUID
    private let identitySampler: any IdentitySampler

    public init(fs: FileSystemService, safety: SafetyEngine,
                home: URL = FileManager.default.homeDirectoryForCurrentUser,
                entitlementReader: any EntitlementReader = SecurityEntitlementReader(),
                launchAgentReader: any LaunchAgentReader = PlistLaunchAgentReader(),
                identitySampler: any IdentitySampler = LocalFileIdentitySampler()) {
        self.init(fs: fs, safety: safety, home: home,
                  entitlementReader: entitlementReader,
                  launchAgentReader: launchAgentReader,
                  identitySampler: identitySampler,
                  issuanceID: UUID())
    }

    init(fs: FileSystemService, safety: SafetyEngine,
         home: URL,
         entitlementReader: any EntitlementReader,
         launchAgentReader: any LaunchAgentReader,
         identitySampler: any IdentitySampler,
         issuanceID: UUID) {
        self.fs = fs
        self.safety = safety
        self.home = home
        self.entitlementReader = entitlementReader
        self.launchAgentReader = launchAgentReader
        self.identitySampler = identitySampler
        self.issuanceID = issuanceID
    }

    /// 快速列出应用（不计算体积，便于秒级出列表）；体积随后由 fillSize 异步补齐。
    public func listApps() -> [InstalledApp] {
        let dirs = [
            URL(fileURLWithPath: "/Applications"),
            URL(fileURLWithPath: "/Applications/Utilities"),
            home.appendingPathComponent("Applications")
        ]
        var apps: [InstalledApp] = []
        var seen = Set<String>()
        for dir in dirs {
            for url in fs.contentsOfDirectory(dir) where url.pathExtension == "app" {
                guard !seen.contains(url.path) else { continue }
                seen.insert(url.path)
                guard let identity = identitySampler.sample(url.standardizedFileURL.path),
                      Self.isDirectory(identity),
                      let metadata = Self.bundleMetadata(at: url) else { continue }
                // A missing identifier proves no ownership. Never turn the app's URL path into
                // an attribution token: doing so can construct unrelated Library targets.
                apps.append(InstalledApp(id: url.path, name: metadata.name,
                                         bundleID: metadata.bundleID, url: url, size: 0,
                                         provenanceID: issuanceID, sourceIdentity: identity,
                                         metadataIdentity: metadata.identity))
            }
        }
        return apps.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// 计算单个应用本体的实际占用
    public func appSize(_ app: InstalledApp) -> Int64 {
        fs.allocatedSize(of: app.url)
    }

    /// Preserves the opaque service provenance and issuance identity while the UI fills size.
    public func appByFillingSize(_ app: InstalledApp) -> InstalledApp? {
        guard app.provenanceID == issuanceID else { return nil }
        return app.withSize(appSize(app))
    }

    /// 关联文件定位所用的标识片段是否可安全用于拼接路径。
    /// 拒绝空 / 过短 / 含路径分隔符 / 相对分量的值——畸形 Info.plist 的空
    /// CFBundleDisplayName 曾可拼出 `~/Library/Application Support`（整个应用数据根）作为删除目标。
    static func isValidPathToken(_ token: String) -> Bool {
        let t = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.count >= 2 else { return false }              // 单字符/空一律拒绝
        if t == "." || t == ".." { return false }
        if t.contains("/") || t.contains("\\") { return false }
        if t.hasPrefix(".") { return false }                  // 隐藏/相对起头
        return true
    }

    /// Builds attributed, policy-bearing candidates without mutating the filesystem.
    public func uninstallTargets(for app: InstalledApp,
                                 mode: UninstallMode,
                                 now: Date = Date()) throws -> UninstallBatch {
        guard app.provenanceID == issuanceID else {
            throw UninstallerAttributionError.foreignApp
        }
        if mode == .cleanLeftovers, fs.exists(app.url) {
            throw UninstallerAttributionError.appStillPresent
        }
        if mode == .uninstallApp {
            try validateCurrentApp(app, planBoundary: false)
        }

        let batchID = UUID()
        var items: [UninstallCandidate] = []
        var seen = Set<String>()
        var signedEntitlementAttestation: SignedEntitlementAttestation?

        func add(_ url: URL,
                 safety level: SafetyLevel,
                 evidence: OwnershipEvidence,
                 policy: SelectionPolicy,
                 role: UninstallCandidateRole = .associatedFile,
                 evidenceBinding: CandidateEvidenceBinding = .none) {
            // 深度断言：关联文件至少要落在 `~/Library/<类别>/<具体项>`（≥6 分量）之下，
            // 绝不允许目标是 `~/Library/<类别>` 这一级本身（红线亦会拦，此为第一道闸）。
            let underLibrary = url.path.hasPrefix(home.appendingPathComponent("Library").path + "/")
            if underLibrary && url.pathComponents.count < 6 { return }
            guard !seen.contains(url.path), fs.exists(url),
                  safety.verify(url, intent: .trash).isAllowed else { return }
            seen.insert(url.path)
            let size = fs.allocatedSize(of: url)
            let cleanable = CleanableItem(url: url, displayName: url.lastPathComponent,
                                          detail: url.path, size: size, safety: level,
                                          isSelected: policy.defaultSelected)
            items.append(UninstallCandidate(item: cleanable, evidence: evidence,
                                            selectionPolicy: policy, role: role,
                                            batchID: batchID,
                                            evidenceBinding: evidenceBinding))
        }

        let parsedBundleID = BundleIdentifier(rawValue: app.bundleID)

        // App body is mandatory only for a normal uninstall. A missing/malformed bundle ID is
        // not inferred from a Library path; the direct app selection makes it required while
        // avoiding a false exact-path attribution claim.
        if mode == .uninstallApp {
            add(app.url, safety: .safe, evidence: .verifiedAppBody, policy: .required,
                role: .appBody)
        }

        let lib = home.appendingPathComponent("Library")
        let name = app.name
        let nameOK = Self.isValidPathToken(name)

        // The eight exact bundle-ID locations are the only bundle-derived recommended paths.
        if let parsedBundleID {
            let bid = parsedBundleID.rawValue
            let byBID: [URL] = [
                lib.appendingPathComponent("Application Support/\(bid)"),
                lib.appendingPathComponent("Caches/\(bid)"),
                lib.appendingPathComponent("Preferences/\(bid).plist"),
                lib.appendingPathComponent("Containers/\(bid)"),
                lib.appendingPathComponent("Saved Application State/\(bid).savedState"),
                lib.appendingPathComponent("Logs/\(bid)"),
                lib.appendingPathComponent("HTTPStorages/\(bid)"),
                lib.appendingPathComponent("WebKit/\(bid)")
            ]
            for url in byBID {
                add(url, safety: .caution, evidence: .exactBundleIDPath, policy: .recommended)
            }

            // Group containers are ownership candidates only when their exact directory names
            // occur in the signed app's application-groups entitlement. Substring matching is
            // forbidden because it can attribute another app's shared container.
            if let attestation = entitlementReader.attestation(for: app.url),
               attestation.isWithinBounds,
               attestation.sourceIdentity == app.sourceIdentity,
               attestation.codeIdentifier == parsedBundleID.rawValue {
                signedEntitlementAttestation = attestation
                let entitledGroups = Set(attestation.groups.filter(Self.isValidPathComponent))
                let groupDirectory = lib.appendingPathComponent("Group Containers")
                for url in fs.contentsOfDirectory(groupDirectory)
                where entitledGroups.contains(url.lastPathComponent) {
                    add(url, safety: .caution, evidence: .signedApplicationGroup,
                        policy: .manualOnly,
                        evidenceBinding: .signedEntitlement(attestation))
                }
            }

            // Launch-agent ownership requires both an exact Label and an executable whose
            // standardized path is strictly inside this app bundle. Exact-label agents with an
            // external program remain visible but blocked; containing labels prove nothing.
            let launchAgentsDirectory = lib.appendingPathComponent("LaunchAgents")
            for url in fs.contentsOfDirectory(launchAgentsDirectory) {
                guard let attestation = launchAgentReader.attestation(at: url),
                      attestation.record.label == bid else { continue }
                if Self.isProgram(attestation, inside: app.url) {
                    add(url, safety: .caution, evidence: .launchAgentProgramInsideBundle,
                        policy: .recommended,
                        evidenceBinding: .launchAgent(attestation))
                } else {
                    add(url, safety: .caution, evidence: .unverified, policy: .blocked)
                }
            }
        }

        // 按显示名定位（易与共享 vendor 目录碰撞，如 Firefox 含书签/密码）——默认**不勾选**，
        // 需用户主动确认，避免"卸载 App A 顺手删掉同厂商 App B 的数据"。
        if nameOK {
            add(lib.appendingPathComponent("Application Support/\(name)"), safety: .caution,
                evidence: .displayNameHeuristic, policy: .manualOnly)
        }

        if mode == .uninstallApp {
            let admittedBodies = items.filter {
                $0.role == .appBody && $0.url.standardizedFileURL.path
                    == app.url.standardizedFileURL.path
                    && $0.selectionPolicy == .required && $0.isSelected
                    && $0.evidence == .verifiedAppBody
            }
            guard admittedBodies.count == 1 else {
                throw UninstallerAttributionError.appBodyNotAdmitted
            }
        }

        return UninstallBatch(issuanceID: issuanceID, batchID: batchID, app: app,
                              mode: mode, candidates: items, createdAt: now,
                              entitlementAttestation: signedEntitlementAttestation)
    }

    /// Hands selected Task 4 candidates to Task 1's immutable capability preparation boundary.
    /// Authorization and execution are deliberately not part of this task.
    public func prepareUninstallPlan(from batch: UninstallBatch,
                                     using issuer: DestructiveOperationIssuer,
                                     now: Date = Date()) throws -> DestructivePlan {
        guard batch.issuanceID == issuanceID else { throw UninstallPlanError.foreignBatch }
        guard now < batch.expiresAt else { throw UninstallPlanError.batchExpired }
        guard batch.candidates.allSatisfy({ $0.batchID == batch.batchID }) else {
            throw UninstallPlanError.foreignCandidate
        }
        let bodies = batch.candidates.filter(\.role.isAppBody)
        switch batch.mode {
        case .uninstallApp:
            try validateCurrentApp(batch.app, planBoundary: true)
            guard bodies.count == 1,
                  let body = bodies.first,
                  body.url.standardizedFileURL.path == batch.app.url.standardizedFileURL.path,
                  body.selectionPolicy == .required,
                  body.isSelected,
                  body.evidence == .verifiedAppBody else {
                throw UninstallPlanError.requiredAppBodyMissing
            }
        case .cleanLeftovers:
            guard bodies.isEmpty, !fs.exists(batch.app.url) else {
                throw UninstallPlanError.modeInvariantViolation
            }
        }
        try validateEntitlementAttestation(in: batch)
        try validateLaunchAgentAttestations(in: batch)

        let selected = batch.candidates.filter(\.isSelected)
        guard !selected.isEmpty else { throw UninstallPlanError.emptySelection }
        guard selected.allSatisfy({ candidate in
            candidate.selectionPolicy != .blocked && candidate.evidence != .unverified
        }) else { throw UninstallPlanError.invalidSelectedCandidate }

        let plan = issuer.prepare(kind: .uninstall,
                                  targets: selected.map(\.targetRequest),
                                  now: now)
        guard plan.targets.allSatisfy({ $0.identity != nil }) else {
            throw UninstallPlanError.missingTargetIdentity
        }
        return plan
    }

    private func validateEntitlementAttestation(in batch: UninstallBatch) throws {
        let boundCandidates = batch.candidates.filter { $0.evidence == .signedApplicationGroup }
        guard let stored = batch.entitlementAttestation else {
            guard boundCandidates.isEmpty else {
                throw UninstallPlanError.entitlementAttestationChanged
            }
            return
        }
        guard stored.isWithinBounds,
              stored.sourceIdentity == batch.app.sourceIdentity,
              boundCandidates.allSatisfy({
                  $0.evidenceBinding == .signedEntitlement(stored)
              }),
              entitlementReader.attestation(for: batch.app.url) == stored else {
            throw UninstallPlanError.entitlementAttestationChanged
        }
    }

    private func validateLaunchAgentAttestations(in batch: UninstallBatch) throws {
        for candidate in batch.candidates
        where candidate.evidence == .launchAgentProgramInsideBundle {
            guard case let .launchAgent(stored) = candidate.evidenceBinding,
                  let current = launchAgentReader.attestation(at: candidate.url),
                  current == stored,
                  current.record.label == batch.app.bundleID,
                  Self.isProgram(current, inside: batch.app.url) else {
                throw UninstallPlanError.launchAgentAttestationChanged
            }
        }
    }

    private func validateCurrentApp(_ app: InstalledApp, planBoundary: Bool) throws {
        guard app.provenanceID == issuanceID else {
            if planBoundary { throw UninstallPlanError.foreignBatch }
            throw UninstallerAttributionError.foreignApp
        }
        guard fs.exists(app.url), safety.verify(app.url, intent: .trash).isAllowed else {
            if planBoundary { throw UninstallPlanError.requiredAppBodyMissing }
            throw UninstallerAttributionError.appBodyNotAdmitted
        }
        guard let currentIdentity = identitySampler.sample(app.url.standardizedFileURL.path),
              currentIdentity == app.sourceIdentity else {
            if planBoundary { throw UninstallPlanError.appIdentityChanged }
            throw UninstallerAttributionError.appIdentityChanged
        }
        guard app.id == app.url.path,
              app.url.pathExtension == "app",
              let metadata = Self.bundleMetadata(at: app.url),
              metadata.bundleID == app.bundleID,
              metadata.identity == app.metadataIdentity else {
            if planBoundary { throw UninstallPlanError.appMetadataChanged }
            throw UninstallerAttributionError.appMetadataChanged
        }
    }

    private struct BundleMetadata {
        let name: String
        let bundleID: String
        let identity: LocalFileIdentity
    }

    private static func bundleMetadata(at appURL: URL) -> BundleMetadata? {
        let infoURL = appURL.appendingPathComponent("Contents/Info.plist")
        guard let read = BoundedRegularFileReader.read(
                at: infoURL, maximumBytes: PlistLaunchAgentReader.maximumBytes),
              let plist = try? PropertyListSerialization.propertyList(from: read.data,
                                                                      options: [], format: nil),
              let dictionary = plist as? [String: Any] else { return nil }
        let bundleID = dictionary["CFBundleIdentifier"] as? String ?? ""
        let name = (dictionary["CFBundleDisplayName"] as? String)
            ?? (dictionary["CFBundleName"] as? String)
            ?? appURL.deletingPathExtension().lastPathComponent
        return BundleMetadata(name: name, bundleID: bundleID, identity: read.identity)
    }

    private static func isDirectory(_ identity: LocalFileIdentity) -> Bool {
        #if canImport(Darwin)
        return (identity.mode & UInt32(S_IFMT)) == UInt32(S_IFDIR)
        #else
        return true
        #endif
    }

    private static func isValidPathComponent(_ value: String) -> Bool {
        !value.isEmpty && value != "." && value != ".."
            && !value.contains("/") && !value.contains("\\")
    }

    private static func isProgram(_ attestation: LaunchAgentAttestation,
                                  inside appURL: URL) -> Bool {
        guard let path = attestation.resolvedProgramPath,
              let identity = attestation.programIdentity else { return false }
        let resolvedBundle = appURL.resolvingSymlinksInPath().standardizedFileURL
        guard let bundleValues = try? resolvedBundle.resourceValues(forKeys: [.isDirectoryKey]),
              bundleValues.isDirectory == true,
              let currentIdentity = LocalFileIdentitySampler().sample(path),
              currentIdentity == identity else { return false }

        let programComponents = canonicalComparisonPath(path)
            .split(separator: "/", omittingEmptySubsequences: true)
        let bundleComponents = canonicalComparisonPath(resolvedBundle.path)
            .split(separator: "/", omittingEmptySubsequences: true)
        guard programComponents.count > bundleComponents.count else { return false }
        return programComponents.prefix(bundleComponents.count).elementsEqual(bundleComponents)
    }

    private static func canonicalComparisonPath(_ path: String) -> String {
        let standardized = (path as NSString).standardizingPath
        // macOS exposes /var through the /private/var symlink. Foundation may preserve either
        // spelling across URL APIs; normalize that system alias before the component boundary test.
        return standardized.hasPrefix("/private/var/")
            ? String(standardized.dropFirst("/private".count))
            : standardized
    }
}

private extension UninstallCandidateRole {
    var isAppBody: Bool { self == .appBody }
}
