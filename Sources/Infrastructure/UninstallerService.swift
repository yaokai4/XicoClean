import Foundation
import Domain

/// Stable security identity for one installed-App workflow. Display name and measured size are
/// deliberately excluded because they may refresh without replacing the App; provenance,
/// physical identity and sealed metadata are included so a new App at the same path cannot inherit
/// an older uninstall ledger or recovery receipt.
package struct UninstallAppWorkflowIdentity: Sendable, Hashable {
    package let appID: String
    package let bundleID: String
    package let canonicalPath: String
    package let provenanceID: UUID
    package let sourceIdentity: LocalFileIdentity
    package let appChainFingerprint: EvidenceFingerprint
    package let metadataIdentity: LocalFileIdentity
    package let metadataExactLength: Int
    package let metadataContentDigest: EvidenceFingerprint
    package let metadataPathChainFingerprint: EvidenceFingerprint
}

public struct InstalledApp: Identifiable, Sendable, Hashable {
    public let id: String
    public let name: String
    public let bundleID: String
    public let url: URL
    public let size: Int64
    let provenanceID: UUID
    let sourceIdentity: LocalFileIdentity
    let appPathProof: AppBundlePathProof
    let metadataAttestation: AppBundleBoundedContentAttestation
    var metadataIdentity: LocalFileIdentity { metadataAttestation.identity }
    var metadataExactLength: Int { metadataAttestation.exactLength }
    var metadataContentDigest: EvidenceFingerprint { metadataAttestation.contentDigest }
    package var uninstallWorkflowIdentity: UninstallAppWorkflowIdentity {
        UninstallAppWorkflowIdentity(
            appID: id,
            bundleID: bundleID,
            canonicalPath: url.standardizedFileURL.path,
            provenanceID: provenanceID,
            sourceIdentity: sourceIdentity,
            appChainFingerprint: appPathProof.chainFingerprint,
            metadataIdentity: metadataAttestation.identity,
            metadataExactLength: metadataAttestation.exactLength,
            metadataContentDigest: metadataAttestation.contentDigest,
            metadataPathChainFingerprint: metadataAttestation.pathChainFingerprint)
    }

    init(id: String, name: String, bundleID: String, url: URL, size: Int64,
         provenanceID: UUID, sourceIdentity: LocalFileIdentity,
         appPathProof: AppBundlePathProof,
         metadataAttestation: AppBundleBoundedContentAttestation) {
        self.id = id
        self.name = name
        self.bundleID = bundleID
        self.url = url
        self.size = size
        self.provenanceID = provenanceID
        self.sourceIdentity = sourceIdentity
        self.appPathProof = appPathProof
        self.metadataAttestation = metadataAttestation
    }

    func withSize(_ size: Int64) -> InstalledApp {
        InstalledApp(id: id, name: name, bundleID: bundleID, url: url, size: size,
                     provenanceID: provenanceID, sourceIdentity: sourceIdentity,
                     appPathProof: appPathProof,
                     metadataAttestation: metadataAttestation)
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
    private let pathAttestor: any LibraryPathAttesting
    private let preparationHooks: UninstallPreparationHooks
    private let clock: any UninstallTrustedClock

    public init(fs: FileSystemService, safety: SafetyEngine,
                home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.init(fs: fs, safety: safety, home: home,
                  entitlementReader: SecurityEntitlementReader(),
                  launchAgentReader: PlistLaunchAgentReader(),
                  pathAttestor: nil,
                  preparationHooks: .none,
                  clock: SystemUninstallTrustedClock(),
                  issuanceID: UUID())
    }

    init(fs: FileSystemService, safety: SafetyEngine,
         home: URL,
         entitlementReader: any EntitlementReader,
         launchAgentReader: any LaunchAgentReader,
         pathAttestor: (any LibraryPathAttesting)? = nil,
         preparationHooks: UninstallPreparationHooks = .none,
         clock: (any UninstallTrustedClock)? = nil,
         issuanceID: UUID = UUID()) {
        self.fs = fs
        self.safety = safety
        self.home = home
        self.entitlementReader = entitlementReader
        self.launchAgentReader = launchAgentReader
        self.pathAttestor = pathAttestor ?? FDAnchoredLibraryPathAttestor(home: home)
        self.preparationHooks = preparationHooks
        self.clock = clock ?? SystemUninstallTrustedClock()
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
                let appAttestor = FDAnchoredAppBundlePathAttestor(appURL: url)
                guard let appProof = appAttestor.attestApp(),
                      Self.isDirectory(appProof.appRootIdentity),
                      let metadata = Self.bundleMetadata(at: url, attestor: appAttestor) else {
                    continue
                }
                // A missing identifier proves no ownership. Never turn the app's URL path into
                // an attribution token: doing so can construct unrelated Library targets.
                apps.append(InstalledApp(id: url.path, name: metadata.name,
                                         bundleID: metadata.bundleID, url: url, size: 0,
                                         provenanceID: issuanceID,
                                         sourceIdentity: appProof.appRootIdentity,
                                         appPathProof: appProof,
                                         metadataAttestation: metadata.attestation))
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
                                 mode: UninstallMode) throws -> UninstallBatch {
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
                 evidenceSource: CandidateEvidenceSource = .none,
                 knownPhysicalPath: PhysicalPathAttestation? = nil) {
            let evidenceBinding: CandidateEvidenceBinding
            if role == .appBody {
                guard case .none = evidenceSource else { return }
                evidenceBinding = .none
            } else {
                guard let path = knownPhysicalPath ?? pathAttestor.attest(url) else { return }
                switch evidenceSource {
                case .none:
                    evidenceBinding = .physicalPath(path)
                case .signedEntitlement(let attestation):
                    evidenceBinding = .signedEntitlement(attestation, path)
                case .launchAgent(let attestation):
                    evidenceBinding = .launchAgent(attestation, path)
                }
            }
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
                        evidenceSource: .signedEntitlement(attestation))
                }
            }

            // Launch-agent ownership requires both an exact Label and an executable whose
            // standardized path is strictly inside this app bundle. Exact-label agents with an
            // external program remain visible but blocked; containing labels prove nothing.
            let launchAgentsDirectory = lib.appendingPathComponent("LaunchAgents")
            for url in fs.contentsOfDirectory(launchAgentsDirectory) {
                guard let anchoredRead = pathAttestor.readRegularFile(
                        url, maximumBytes: PlistLaunchAgentReader.maximumBytes),
                      let parsed = launchAgentReader.attestation(
                        at: url, anchoredRead: anchoredRead) else { continue }
                let attestation = parsed.bindingProgram(to: app.url)
                guard
                      attestation.record.label == bid else { continue }
                if Self.isProgram(attestation, inside: app.url) {
                    add(url, safety: .caution, evidence: .launchAgentProgramInsideBundle,
                        policy: .recommended,
                        evidenceSource: .launchAgent(attestation),
                        knownPhysicalPath: anchoredRead.pathAttestation)
                } else {
                    add(url, safety: .caution, evidence: .unverified, policy: .blocked,
                        knownPhysicalPath: anchoredRead.pathAttestation)
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

        let createdAt = clock.wallNow()
        let expiresAt = createdAt.addingTimeInterval(UninstallBatch.timeToLive)
        let monotonicIssuedAt = clock.monotonicNowNanoseconds()
        guard createdAt.timeIntervalSince1970.isFinite,
              expiresAt.timeIntervalSince1970.isFinite,
              expiresAt > createdAt,
              expiresAt.timeIntervalSince(createdAt) == UninstallBatch.timeToLive,
              let claimToken = UninstallBatchClaimToken.make(
                clock: clock, issuedAtNanoseconds: monotonicIssuedAt,
                lifetimeNanoseconds: UninstallBatch.timeToLiveNanoseconds) else {
            throw UninstallerAttributionError.trustedClockUnavailable
        }
        return UninstallBatch(issuanceID: issuanceID, batchID: batchID, app: app,
                              mode: mode, candidates: items, createdAt: createdAt,
                              expiresAt: expiresAt,
                              entitlementAttestation: signedEntitlementAttestation,
                              claimToken: claimToken)
    }

    func prepareUninstallExecution(from batch: UninstallBatch,
                                   using issuer: DestructiveOperationIssuer) throws
        -> PreparedUninstallExecution {
        // Reject forged structure and policy before consulting mutable filesystem evidence.
        // This keeps failures deterministic while the full fail-closed attestation pass below
        // still runs for every structurally admissible batch.
        guard batch.issuanceID == issuanceID else { throw UninstallPlanError.foreignBatch }
        guard batch.candidates.allSatisfy({ $0.batchID == batch.batchID }) else {
            throw UninstallPlanError.foreignCandidate
        }
        if batch.mode == .uninstallApp {
            let bodies = batch.candidates.filter(\.role.isAppBody)
            guard bodies.count == 1,
                  let body = bodies.first,
                  body.url.standardizedFileURL.path
                    == batch.app.url.standardizedFileURL.path,
                  body.selectionPolicy == .required,
                  body.isSelected,
                  body.evidence == .verifiedAppBody else {
                throw UninstallPlanError.requiredAppBodyMissing
            }
        }
        let selected = UninstallEvidenceSeal.orderedSelectedCandidates(in: batch)
        guard !selected.isEmpty else { throw UninstallPlanError.emptySelection }
        guard selected.allSatisfy({ candidate in
            candidate.selectionPolicy != .blocked && candidate.evidence != .unverified
        }) else { throw UninstallPlanError.invalidSelectedCandidate }

        try validateBatchForPreparation(batch)

        let paths = selected.map { $0.url.standardizedFileURL.path }
        guard Set(paths).count == paths.count else { throw UninstallPlanError.duplicateTarget }
        var physicalObjects = Set<PhysicalObjectID>()
        var orderedTargets: [PreparedUninstallTarget] = []
        orderedTargets.reserveCapacity(selected.count)
        for (index, candidate) in selected.enumerated() {
            guard let ordinal = UInt32(exactly: index),
                  let batchIndex = batch.candidates.indices.first(where: {
                      UninstallEvidenceSeal.sameCandidate(batch.candidates[$0], candidate)
                  }),
                  batch.candidates.indices.filter({
                      UninstallEvidenceSeal.sameCandidate(batch.candidates[$0], candidate)
                  }).count == 1,
                  let batchCandidateIndex = UInt32(exactly: batchIndex),
                  let identity = UninstallEvidenceSeal.expectedIdentity(
                    for: candidate, in: batch) else {
                throw UninstallPlanError.missingTargetIdentity
            }
            guard physicalObjects.insert(PhysicalObjectID(identity)).inserted else {
                throw UninstallPlanError.duplicateTarget
            }
            guard let fingerprint = UninstallEvidenceSeal.fingerprint(
                    batch: batch, candidate: candidate, ordinal: ordinal,
                    batchCandidateIndex: batchCandidateIndex,
                    expectedIdentity: identity),
                  fingerprint != .none else {
                throw UninstallPlanError.evidenceFingerprintUnavailable
            }
            orderedTargets.append(PreparedUninstallTarget(
                ordinal: ordinal, batchCandidateIndex: batchCandidateIndex,
                candidate: candidate,
                canonicalPath: candidate.url.standardizedFileURL.path,
                expectedIdentity: identity, evidenceFingerprint: fingerprint,
                ownershipAttestation: candidate.evidenceBinding))
        }

        preparationHooks.beforeIssuerPrepare()
        let issuedPlan = issuer.prepare(
            kind: .uninstall,
            targets: orderedTargets.map {
                $0.candidate.targetRequest(with: $0.evidenceFingerprint)
            })
        let plan = preparationHooks.afterIssuerPrepare(issuedPlan)
        guard plan.targets.allSatisfy({ $0.identity != nil }) else {
            throw UninstallPlanError.missingTargetIdentity
        }
        guard plan.planID == issuedPlan.planID,
              plan.kind == issuedPlan.kind,
              plan.createdAt == issuedPlan.createdAt,
              plan.expiresAt == issuedPlan.expiresAt,
              plan.digest == issuedPlan.digest else {
            throw UninstallPlanError.preparedTargetMismatch
        }

        // Revalidate all rich evidence after Task 1 samples the target paths. This prevents an
        // app metadata or attestation A→B change that leaves the app-directory inode unchanged.
        try validateBatchForPreparation(batch)
        guard plan.targets.count == orderedTargets.count else {
            throw UninstallPlanError.preparedTargetMismatch
        }
        for (planned, sealed) in zip(plan.targets, orderedTargets) {
            guard planned.canonicalPath == sealed.canonicalPath,
                  planned.identity == sealed.expectedIdentity,
                  planned.evidenceFingerprint == sealed.evidenceFingerprint,
                  planned.evidenceFingerprint != .none,
                  planned.recoverability == sealed.candidate.targetRequest.recoverability,
                  planned.riskLevel == sealed.candidate.targetRequest.riskLevel,
                  planned.attribution == sealed.candidate.targetRequest.attribution else {
                throw UninstallPlanError.preparedTargetMismatch
            }
        }
        guard let preparationSeal = UninstallEvidenceSeal.preparationSeal(
                plan: plan, batch: batch, targets: orderedTargets),
              preparationSeal.count == 32 else {
            throw UninstallPlanError.preparationSealUnavailable
        }
        let prepared = preparationHooks.afterPreparation(PreparedUninstallExecution(
            plan: plan, orderedTargets: orderedTargets, batchSnapshot: batch,
            batchID: batch.batchID, issuanceID: batch.issuanceID,
            preparationSeal: preparationSeal))
        guard prepared.validateIntegrity() else {
            throw UninstallPlanError.preparedTargetMismatch
        }
        return prepared
    }

    /// Reopens the exact Task 4 ownership proof for one sealed occurrence. This method is called
    /// synchronously from the engine-owned mutation loop while the App body is still present for
    /// normal uninstall mode; it never mutates the filesystem.
    func revalidateExecutionTarget(
        _ target: PreparedUninstallTarget,
        in batch: UninstallBatch
    ) -> Bool {
        do {
            guard batch.issuanceID == issuanceID,
                  batch.batchID == target.candidate.batchID,
                  batch.candidates.indices.contains(Int(target.batchCandidateIndex)),
                  UninstallEvidenceSeal.sameCandidate(
                    batch.candidates[Int(target.batchCandidateIndex)], target.candidate),
                  target.candidate.isSelected,
                  target.canonicalPath
                    == target.candidate.url.standardizedFileURL.path,
                  target.expectedIdentity
                    == UninstallEvidenceSeal.expectedIdentity(
                        for: target.candidate, in: batch),
                  let fingerprint = UninstallEvidenceSeal.fingerprint(
                    batch: batch,
                    candidate: target.candidate,
                    ordinal: target.ordinal,
                    batchCandidateIndex: target.batchCandidateIndex,
                    expectedIdentity: target.expectedIdentity),
                  fingerprint == target.evidenceFingerprint,
                  fingerprint != .none else { return false }

            switch batch.mode {
            case .uninstallApp:
                try validateCurrentApp(batch.app, planBoundary: true)
            case .cleanLeftovers:
                guard target.candidate.role == .associatedFile,
                      !fs.exists(batch.app.url) else { return false }
            }

            try validateEvidenceCrossBinding(target.candidate, in: batch)
            switch target.candidate.evidenceBinding {
            case .none:
                guard target.candidate.role == .appBody,
                      target.candidate.evidence == .verifiedAppBody else { return false }
            case .physicalPath(let stored):
                guard let current = pathAttestor.attest(target.candidate.url),
                      Self.sameStablePhysicalPath(current, stored) else { return false }
            case .signedEntitlement:
                try validateEntitlementAttestation(in: batch)
                guard let stored = target.candidate.evidenceBinding.physicalPath,
                      let current = pathAttestor.attest(target.candidate.url),
                      Self.sameStablePhysicalPath(current, stored) else { return false }
            case .launchAgent:
                try validateLaunchAgentAttestation(
                    target.candidate, in: batch, allowStablePathMetadataDrift: true)
            }
            return true
        } catch {
            return false
        }
    }

    private func validateBatchForPreparation(_ batch: UninstallBatch) throws {
        guard batch.issuanceID == issuanceID else { throw UninstallPlanError.foreignBatch }
        let now = clock.wallNow()
        guard batch.createdAt <= now else { throw UninstallPlanError.batchNotYetValid }
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
        try validatePhysicalPathAttestations(in: batch)
        try validateEvidenceCrossBindings(in: batch)
    }

    private func validateEvidenceCrossBindings(in batch: UninstallBatch) throws {
        for candidate in batch.candidates {
            try validateEvidenceCrossBinding(candidate, in: batch)
        }
    }

    private func validateEvidenceCrossBinding(
        _ candidate: UninstallCandidate,
        in batch: UninstallBatch
    ) throws {
        switch candidate.evidenceBinding {
        case .none:
            guard candidate.role == .appBody else {
                throw UninstallPlanError.preparedTargetMismatch
            }
        case .physicalPath(let path):
            guard candidate.role == .associatedFile,
                  path.canonicalPath == candidate.url.path else {
                throw UninstallPlanError.preparedTargetMismatch
            }
        case .signedEntitlement(let entitlement, let path):
            guard candidate.role == .associatedFile,
                  path.canonicalPath == candidate.url.path,
                  let source = entitlement.sourceSeal,
                  source.appRoot == batch.app.sourceIdentity,
                  source.appChainFingerprint == batch.app.appPathProof.chainFingerprint,
                  source.infoPlist == batch.app.metadataAttestation else {
                throw UninstallPlanError.entitlementAttestationChanged
            }
        case .launchAgent(let launch, let path):
            guard candidate.role == .associatedFile,
                  path.canonicalPath == candidate.url.path,
                  path.targetIdentity == launch.plistIdentity,
                  launch.plistExactLength > 0,
                  launch.plistContentDigest != .none,
                  let token = launch.programChangeToken,
                  launch.resolvedProgramPath == token.canonicalPath,
                  launch.programIdentity == token.executable else {
                throw UninstallPlanError.launchAgentAttestationChanged
            }
        }
    }

    private struct PhysicalObjectID: Hashable {
        let device: UInt64
        let inode: UInt64
        init(_ identity: LocalFileIdentity) {
            device = identity.device
            inode = identity.inode
        }
    }

    private func validatePhysicalPathAttestations(in batch: UninstallBatch) throws {
        for candidate in batch.candidates where candidate.role == .associatedFile {
            guard let stored = candidate.evidenceBinding.physicalPath,
                  pathAttestor.attest(candidate.url) == stored else {
                throw UninstallPlanError.physicalPathAttestationChanged
            }
        }
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
                  if case let .signedEntitlement(attestation, _) = $0.evidenceBinding {
                      return attestation == stored
                  }
                  return false
              }),
              entitlementReader.attestation(for: batch.app.url) == stored else {
            throw UninstallPlanError.entitlementAttestationChanged
        }
    }

    private func validateLaunchAgentAttestations(in batch: UninstallBatch) throws {
        for candidate in batch.candidates
        where candidate.evidence == .launchAgentProgramInsideBundle {
            try validateLaunchAgentAttestation(candidate, in: batch)
        }
    }

    private func validateLaunchAgentAttestation(
        _ candidate: UninstallCandidate,
        in batch: UninstallBatch,
        allowStablePathMetadataDrift: Bool = false
    ) throws {
        guard case let .launchAgent(stored, storedPath) = candidate.evidenceBinding,
              let anchoredRead = pathAttestor.readRegularFile(
                        candidate.url, maximumBytes: PlistLaunchAgentReader.maximumBytes) else {
            throw UninstallPlanError.launchAgentAttestationChanged
        }
        let pathMatches = allowStablePathMetadataDrift
            ? Self.sameStablePhysicalPath(anchoredRead.pathAttestation, storedPath)
            : anchoredRead.pathAttestation == storedPath
        guard pathMatches,
              let parsed = launchAgentReader.attestation(
                        at: candidate.url, anchoredRead: anchoredRead) else {
            throw UninstallPlanError.launchAgentAttestationChanged
        }
        let current = parsed.bindingProgram(to: batch.app.url)
        guard current == stored,
              current.record.label == batch.app.bundleID,
              Self.isProgram(current, inside: batch.app.url) else {
            throw UninstallPlanError.launchAgentAttestationChanged
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
        let appAttestor = FDAnchoredAppBundlePathAttestor(appURL: app.url)
        guard let currentProof = appAttestor.attestApp(),
              Self.sameStableAppPath(currentProof, app.appPathProof),
              currentProof.appRootIdentity == app.sourceIdentity else {
            if planBoundary { throw UninstallPlanError.appIdentityChanged }
            throw UninstallerAttributionError.appIdentityChanged
        }
        guard app.id == app.url.path,
              app.url.pathExtension == "app",
              let metadata = Self.bundleMetadata(at: app.url, attestor: appAttestor),
              metadata.bundleID == app.bundleID,
              Self.sameStableMetadata(metadata.attestation,
                                      app.metadataAttestation) else {
            if planBoundary { throw UninstallPlanError.appMetadataChanged }
            throw UninstallerAttributionError.appMetadataChanged
        }
    }

    private struct BundleMetadata {
        let name: String
        let bundleID: String
        let attestation: AppBundleBoundedContentAttestation
    }

    private static func bundleMetadata(at appURL: URL,
                                       attestor: any AppBundlePathAttesting) -> BundleMetadata? {
        guard let read = attestor.readRegularFile(
                relativeComponents: ["Contents", "Info.plist"],
                maximumBytes: PlistLaunchAgentReader.maximumBytes),
              let plist = try? PropertyListSerialization.propertyList(from: read.data,
                                                                      options: [], format: nil),
              let dictionary = plist as? [String: Any] else { return nil }
        let bundleID = dictionary["CFBundleIdentifier"] as? String ?? ""
        let name = (dictionary["CFBundleDisplayName"] as? String)
            ?? (dictionary["CFBundleName"] as? String)
            ?? appURL.deletingPathExtension().lastPathComponent
        return BundleMetadata(name: name, bundleID: bundleID,
                              attestation: read.attestation)
    }

    private static func isDirectory(_ identity: LocalFileIdentity) -> Bool {
        #if canImport(Darwin)
        return (identity.mode & UInt32(S_IFMT)) == UInt32(S_IFDIR)
        #else
        return true
        #endif
    }

    /// The no-follow attestor proves that every component is the same physical object. Size and
    /// timestamps are intentionally excluded at the final mutation boundary: moving an earlier
    /// sibling to Trash legitimately changes its parent directory metadata. The target's exact
    /// device/inode/type is independently rechecked by the engine immediately before `trash`.
    private static func sameStablePhysicalPath(
        _ current: PhysicalPathAttestation,
        _ stored: PhysicalPathAttestation
    ) -> Bool {
        guard current.canonicalPath == stored.canonicalPath,
              current.componentNames == stored.componentNames,
              current.componentIdentities.count == stored.componentIdentities.count else {
            return false
        }
        let fileTypeMask: UInt32 = 0o170000
        return zip(current.componentIdentities, stored.componentIdentities).allSatisfy {
            $0.device == $1.device
                && $0.inode == $1.inode
                && ($0.mode & fileTypeMask) == ($1.mode & fileTypeMask)
        }
    }

    /// Creating or removing a sibling legitimately changes ancestor directory timestamps. Keep
    /// the no-follow physical chain exact by device/inode/type, while the separate leaf equality
    /// in `validateCurrentApp` still requires the App directory's complete scan-time identity.
    private static func sameStableAppPath(
        _ current: AppBundlePathProof,
        _ stored: AppBundlePathProof
    ) -> Bool {
        guard current.canonicalPath == stored.canonicalPath,
              current.rootRelativeComponents == stored.rootRelativeComponents,
              current.componentIdentities.count == stored.componentIdentities.count else {
            return false
        }
        let fileTypeMask: UInt32 = 0o170000
        return zip(current.componentIdentities, stored.componentIdentities).allSatisfy {
            $0.device == $1.device
                && $0.inode == $1.inode
                && ($0.mode & fileTypeMask) == ($1.mode & fileTypeMask)
        }
    }

    /// The current no-follow App proof already revalidates the physical ancestor chain. Compare
    /// the Info.plist leaf itself exactly (identity including ctime, length and digest) without
    /// requiring the volatile ancestor-metadata fingerprint to remain byte-identical.
    private static func sameStableMetadata(
        _ current: AppBundleBoundedContentAttestation,
        _ stored: AppBundleBoundedContentAttestation
    ) -> Bool {
        current.relativeComponentsInsideApp == stored.relativeComponentsInsideApp
            && current.identity == stored.identity
            && current.exactLength == stored.exactLength
            && current.contentDigest == stored.contentDigest
    }

    private static func isValidPathComponent(_ value: String) -> Bool {
        !value.isEmpty && value != "." && value != ".."
            && !value.contains("/") && !value.contains("\\")
    }

    private static func isProgram(_ attestation: LaunchAgentAttestation,
                                  inside appURL: URL) -> Bool {
        guard let token = attestation.programChangeToken,
              attestation.resolvedProgramPath == token.canonicalPath,
              attestation.programIdentity == token.executable else { return false }
        return FDAnchoredAppBundlePathAttestor(appURL: appURL).programToken(
            absoluteURL: URL(fileURLWithPath: token.canonicalPath),
            maximumDigestBytes: 16 * 1_048_576) == token
    }
}

private extension UninstallCandidateRole {
    var isAppBody: Bool { self == .appBody }
}
