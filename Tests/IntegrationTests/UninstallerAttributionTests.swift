import Foundation
import XCTest
@testable import Domain
@testable import Infrastructure
#if canImport(Darwin)
import Darwin
#endif

final class UninstallerAttributionTests: XCTestCase {
    private struct AllowAllSafety: SafetyEngine {
        func verify(_ url: URL, intent: DeleteIntent) -> SafetyVerdict { .allow }
    }

    private struct DenyURLSafety: SafetyEngine {
        let deniedPath: String
        func verify(_ url: URL, intent: DeleteIntent) -> SafetyVerdict {
            url.path == deniedPath ? .deny(reason: "fixture denial") : .allow
        }
    }

    private struct FakeEntitlementReader: EntitlementReader {
        let groups: [String]?
        func applicationGroups(for appURL: URL) -> [String]? { groups }
    }

    private struct FakeLaunchAgentReader: LaunchAgentReader {
        let records: [String: LaunchAgentRecord]
        func launchAgent(at url: URL) -> LaunchAgentRecord? { records[url.path] }
    }

    private struct NilIdentitySampler: IdentitySampler {
        func sample(_ canonicalPath: String) -> LocalFileIdentity? { nil }
    }

    private struct Fixture {
        let root: URL
        let home: URL
        let appURL: URL
        let app: InstalledApp

        init(bundleID: String = "com.example.product", displayName: String = "Example Product") throws {
            let unresolvedRoot = FileManager.default.temporaryDirectory
                .appendingPathComponent("xico-uninstaller-attribution-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: unresolvedRoot, withIntermediateDirectories: true)
            root = unresolvedRoot.path.hasPrefix("/var/")
                ? URL(fileURLWithPath: "/private" + unresolvedRoot.path)
                : unresolvedRoot.resolvingSymlinksInPath()
            home = root.appendingPathComponent("home")
            appURL = root.appendingPathComponent("Applications/Example Product.app")
            try FileManager.default.createDirectory(at: appURL, withIntermediateDirectories: true)
            app = InstalledApp(id: appURL.path, name: displayName, bundleID: bundleID,
                               url: appURL, size: 0)
        }

        func createLibraryItem(_ relativePath: String, directory: Bool = true) throws -> URL {
            let url = home.appendingPathComponent("Library").appendingPathComponent(relativePath)
            if directory {
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            } else {
                try FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data("fixture".utf8).write(to: url)
            }
            return url
        }

        func createAppExecutable(_ relativePath: String = "Contents/MacOS/helper") throws -> URL {
            let url = appURL.appendingPathComponent(relativePath)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try Data("executable".utf8).write(to: url)
            return url
        }

        func createLaunchAgentPlist(_ relativePath: String,
                                    dictionary: [String: Any]) throws -> URL {
            let url = home.appendingPathComponent("Library/LaunchAgents")
                .appendingPathComponent(relativePath)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            let data = try PropertyListSerialization.data(fromPropertyList: dictionary,
                                                          format: .xml, options: 0)
            try data.write(to: url)
            return url
        }

        func service(safety: any SafetyEngine = AllowAllSafety(),
                     entitlements: [String]? = [],
                     launchAgents: [String: LaunchAgentRecord] = [:]) -> UninstallerService {
            UninstallerService(
                fs: LocalFileSystemService(),
                safety: safety,
                home: home,
                entitlementReader: FakeEntitlementReader(groups: entitlements),
                launchAgentReader: FakeLaunchAgentReader(records: launchAgents))
        }

        func remove() { try? FileManager.default.removeItem(at: root) }
    }

    func testStrictReverseDNSParserRejectsEmptySegments() throws { // UNI-01
        XCTAssertNil(BundleIdentifier(rawValue: "com..example"))
        XCTAssertNil(BundleIdentifier(rawValue: ".com.example"))
        XCTAssertNil(BundleIdentifier(rawValue: "com.example."))
        XCTAssertNotNil(BundleIdentifier(rawValue: "com.example.product"))
    }

    func testStrictReverseDNSParserRejectsPathAndIllegalCharacters() throws { // UNI-01
        for value in [".", "..", "com/example.app", "com\\example.app", "com.example_app",
                      "com.example app", "com.-example", "com.example-"] {
            XCTAssertNil(BundleIdentifier(rawValue: value), value)
        }
        XCTAssertNil(BundleIdentifier(rawValue: "com.éxample.product"))
        XCTAssertNotNil(BundleIdentifier(rawValue: "com.example-2.product9"))
    }

    func testStrictReverseDNSParserRejectsWeakShortTokenAndOverlongComponents() throws { // UNI-01
        XCTAssertNil(BundleIdentifier(rawValue: "x"))
        XCTAssertNil(BundleIdentifier(rawValue: "product"))
        XCTAssertNil(BundleIdentifier(rawValue: "com.\(String(repeating: "a", count: 64))"))
        let tooLong = ["com", "example"] + Array(repeating: String(repeating: "a", count: 60), count: 5)
        XCTAssertNil(BundleIdentifier(rawValue: tooLong.joined(separator: ".")))
    }

    func testMissingBundleIDDoesNotFallBackToURLPathForAttribution() throws { // UNI-01
        let fixture = try Fixture(bundleID: "")
        defer { fixture.remove() }
        let pathFallbackTarget = try fixture.createLibraryItem("Caches/\(fixture.appURL.path)")

        let candidates = try fixture.service().uninstallTargets(for: fixture.app, mode: .uninstallApp).candidates

        XCTAssertFalse(candidates.contains { $0.url.path == pathFallbackTarget.path })
        let appBody = try XCTUnwrap(candidates.first { $0.url.path == fixture.appURL.path })
        XCTAssertEqual(appBody.evidence, .verifiedAppBody)
        XCTAssertEqual(appBody.selectionPolicy, .required)
    }

    func testExactBundleIDPathsGetRecommendedSelectionPolicy() throws { // UNI-04
        let fixture = try Fixture()
        defer { fixture.remove() }
        let bid = fixture.app.bundleID
        let paths = [
            "Application Support/\(bid)", "Caches/\(bid)", "Preferences/\(bid).plist",
            "Containers/\(bid)", "Saved Application State/\(bid).savedState", "Logs/\(bid)",
            "HTTPStorages/\(bid)", "WebKit/\(bid)"
        ]
        let urls = try paths.map { try fixture.createLibraryItem($0, directory: !$0.hasSuffix(".plist")) }

        let candidates = try fixture.service().uninstallTargets(for: fixture.app, mode: .uninstallApp).candidates

        for url in urls {
            let candidate = try XCTUnwrap(candidates.first { $0.url.path == url.path },
                                          "missing \(url.path); got \(candidates.map { $0.url.path })")
            XCTAssertEqual(candidate.evidence, .exactBundleIDPath)
            XCTAssertEqual(candidate.selectionPolicy, .recommended)
            XCTAssertTrue(candidate.isSelected)
        }
    }

    func testAppGroupsReadFromSignedEntitlementsAreMarkedManualOnly() throws { // UNI-06
        let fixture = try Fixture()
        defer { fixture.remove() }
        let group = "group.com.example.shared"
        let url = try fixture.createLibraryItem("Group Containers/\(group)")

        let candidates = try fixture.service(entitlements: [group])
            .uninstallTargets(for: fixture.app, mode: .uninstallApp).candidates

        let candidate = try XCTUnwrap(candidates.first { $0.url.path == url.path })
        XCTAssertEqual(candidate.evidence, .signedApplicationGroup)
        XCTAssertEqual(candidate.selectionPolicy, .manualOnly)
        XCTAssertFalse(candidate.isSelected)
    }

    func testUnsignedOrMismatchedAppGroupIsNotRecommended() throws { // UNI-06
        let fixture = try Fixture()
        defer { fixture.remove() }
        let url = try fixture.createLibraryItem("Group Containers/group.com.example.shared")

        for entitlements in [Optional<[String]>.none, ["group.com.other.shared"]] {
            let candidates = try fixture.service(entitlements: entitlements)
                .uninstallTargets(for: fixture.app, mode: .uninstallApp).candidates
            XCTAssertFalse(candidates.contains {
                $0.url.path == url.path && ($0.evidence == .signedApplicationGroup || $0.selectionPolicy == .recommended)
            })
        }
    }

    func testSecurityEntitlementReaderRejectsUnsignedTemporaryBundle() throws { // UNI-06
        let fixture = try Fixture()
        defer { fixture.remove() }

        XCTAssertNil(SecurityEntitlementReader().applicationGroups(for: fixture.appURL))
    }

    func testLaunchAgentRecommendedOnlyWhenLabelExactAndProgramInsideBundle() throws { // UNI-07
        let fixture = try Fixture()
        defer { fixture.remove() }
        let plist = try fixture.createLibraryItem("LaunchAgents/\(fixture.app.bundleID).plist", directory: false)
        let executable = try fixture.createAppExecutable()
        let record = LaunchAgentRecord(label: fixture.app.bundleID,
                                       program: executable.path,
                                       programArguments: [])

        let candidates = try fixture.service(launchAgents: [plist.path: record])
            .uninstallTargets(for: fixture.app, mode: .uninstallApp).candidates

        let candidate = try XCTUnwrap(candidates.first { $0.url.path == plist.path })
        XCTAssertEqual(candidate.evidence, .launchAgentProgramInsideBundle)
        XCTAssertEqual(candidate.selectionPolicy, .recommended)
        XCTAssertTrue(candidate.isSelected)
    }

    func testLaunchAgentProgramArgumentsFirstExecutableInsideBundleIsRecommended() throws { // UNI-07
        let fixture = try Fixture()
        defer { fixture.remove() }
        let plist = try fixture.createLibraryItem("LaunchAgents/\(fixture.app.bundleID).plist", directory: false)
        let executable = try fixture.createAppExecutable()
        let record = LaunchAgentRecord(label: fixture.app.bundleID, program: nil,
                                       programArguments: [executable.path, "--background"])

        let candidates = try fixture.service(launchAgents: [plist.path: record])
            .uninstallTargets(for: fixture.app, mode: .uninstallApp).candidates

        let candidate = try XCTUnwrap(candidates.first { $0.url.path == plist.path })
        XCTAssertEqual(candidate.evidence, .launchAgentProgramInsideBundle)
        XCTAssertEqual(candidate.selectionPolicy, .recommended)
    }

    func testLaunchAgentMissingProgramInsideBundleIsNotRecommended() throws { // UNI-07
        let fixture = try Fixture()
        defer { fixture.remove() }
        let plist = try fixture.createLibraryItem("LaunchAgents/\(fixture.app.bundleID).plist", directory: false)
        let missing = fixture.appURL.appendingPathComponent("Contents/MacOS/missing")
        let record = LaunchAgentRecord(label: fixture.app.bundleID, program: missing.path,
                                       programArguments: [])

        let candidates = try fixture.service(launchAgents: [plist.path: record])
            .uninstallTargets(for: fixture.app, mode: .uninstallApp).candidates

        XCTAssertFalse(candidates.contains {
            $0.url.path == plist.path && $0.selectionPolicy == .recommended
        })
    }

    func testLaunchAgentSymlinkEscapeOutsideBundleIsNotRecommended() throws { // UNI-07
        let fixture = try Fixture()
        defer { fixture.remove() }
        let plist = try fixture.createLibraryItem("LaunchAgents/\(fixture.app.bundleID).plist", directory: false)
        let outside = fixture.root.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let outsideProgram = outside.appendingPathComponent("helper")
        try Data("outside".utf8).write(to: outsideProgram)
        let contents = fixture.appURL.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let linkedDirectory = contents.appendingPathComponent("LinkedHelpers")
        try FileManager.default.createSymbolicLink(at: linkedDirectory, withDestinationURL: outside)
        let apparentProgram = linkedDirectory.appendingPathComponent("helper")
        let record = LaunchAgentRecord(label: fixture.app.bundleID, program: apparentProgram.path,
                                       programArguments: [])

        let candidates = try fixture.service(launchAgents: [plist.path: record])
            .uninstallTargets(for: fixture.app, mode: .uninstallApp).candidates

        XCTAssertFalse(candidates.contains {
            $0.url.path == plist.path && $0.selectionPolicy == .recommended
        })
    }

    func testPlistLaunchAgentReaderRejectsSymlink() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let target = try fixture.createLaunchAgentPlist("real.plist", dictionary: [
            "Label": fixture.app.bundleID,
            "Program": "/bin/true"
        ])
        let link = target.deletingLastPathComponent().appendingPathComponent("link.plist")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        XCTAssertNil(PlistLaunchAgentReader().launchAgent(at: link))
    }

    func testPlistLaunchAgentReaderRejectsPlistOverOneMiB() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let plist = try fixture.createLaunchAgentPlist("oversized.plist", dictionary: [
            "Label": fixture.app.bundleID,
            "Program": "/bin/true",
            "Padding": String(repeating: "x", count: 1_048_576)
        ])

        XCTAssertNil(PlistLaunchAgentReader().launchAgent(at: plist))
    }

    func testPlistLaunchAgentReaderRejectsFIFOWithoutBlocking() throws {
        #if canImport(Darwin)
        let fixture = try Fixture()
        defer { fixture.remove() }
        let fifo = fixture.home.appendingPathComponent("Library/LaunchAgents/agent.fifo")
        try FileManager.default.createDirectory(at: fifo.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        XCTAssertEqual(mkfifo(fifo.path, 0o600), 0)

        let started = Date()
        XCTAssertNil(PlistLaunchAgentReader().launchAgent(at: fifo))
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.5)
        #endif
    }

    func testLaunchAgentWithProgramOutsideBundleIsNotRecommended() throws { // UNI-07
        let fixture = try Fixture()
        defer { fixture.remove() }
        let plist = try fixture.createLibraryItem("LaunchAgents/\(fixture.app.bundleID).plist", directory: false)
        let record = LaunchAgentRecord(label: fixture.app.bundleID, program: "/usr/local/bin/shared-helper",
                                       programArguments: [])

        let candidates = try fixture.service(launchAgents: [plist.path: record])
            .uninstallTargets(for: fixture.app, mode: .uninstallApp).candidates

        XCTAssertFalse(candidates.contains {
            $0.url.path == plist.path && ($0.evidence == .launchAgentProgramInsideBundle || $0.selectionPolicy == .recommended)
        })
    }

    func testDisplayNameDirectoryIsHeuristicDefaultUnselected() throws { // UNI-08
        let fixture = try Fixture()
        defer { fixture.remove() }
        let url = try fixture.createLibraryItem("Application Support/\(fixture.app.name)")

        let candidates = try fixture.service().uninstallTargets(for: fixture.app, mode: .uninstallApp).candidates

        let candidate = try XCTUnwrap(candidates.first { $0.url.path == url.path })
        XCTAssertEqual(candidate.evidence, .displayNameHeuristic)
        XCTAssertEqual(candidate.selectionPolicy, .manualOnly)
        XCTAssertFalse(candidate.isSelected)
    }

    func testSelectAllExcludesManualOnlyAndHeuristicCandidates() throws { // UNI-08
        let fixture = try Fixture()
        defer { fixture.remove() }
        let exact = try fixture.createLibraryItem("Caches/\(fixture.app.bundleID)")
        let heuristic = try fixture.createLibraryItem("Application Support/\(fixture.app.name)")
        let group = "group.com.example.shared"
        let groupURL = try fixture.createLibraryItem("Group Containers/\(group)")
        var batch = try fixture.service(entitlements: [group])
            .uninstallTargets(for: fixture.app, mode: .uninstallApp)

        batch.selectAll()
        let selected = batch.candidates

        XCTAssertTrue(try XCTUnwrap(selected.first { $0.url.path == fixture.appURL.path }).isSelected)
        XCTAssertTrue(try XCTUnwrap(selected.first { $0.url.path == exact.path }).isSelected)
        XCTAssertFalse(try XCTUnwrap(selected.first { $0.url.path == heuristic.path }).isSelected)
        XCTAssertFalse(try XCTUnwrap(selected.first { $0.url.path == groupURL.path }).isSelected)
    }

    func testUninstallAppModeMarksAppBodyRequiredNonDeselectable() throws { // UNI-02
        let fixture = try Fixture()
        defer { fixture.remove() }
        let candidates = try fixture.service().uninstallTargets(for: fixture.app, mode: .uninstallApp).candidates

        var appBody = try XCTUnwrap(candidates.first { $0.url.path == fixture.appURL.path })
        XCTAssertEqual(appBody.selectionPolicy, .required)
        XCTAssertFalse(appBody.isSelectable)
        appBody.setSelected(false)
        XCTAssertTrue(appBody.isSelected)
    }

    func testUninstallAppBatchCarriesVerifiedAppBodyRoleAndEvidence() throws { // UNI-02
        let fixture = try Fixture()
        defer { fixture.remove() }

        let batch = try fixture.service().uninstallTargets(for: fixture.app, mode: .uninstallApp)

        let appBody = try XCTUnwrap(batch.candidates.first { $0.url.path == fixture.appURL.path })
        XCTAssertEqual(appBody.role, .appBody)
        XCTAssertEqual(appBody.evidence, .verifiedAppBody)
        XCTAssertEqual(appBody.selectionPolicy, .required)
    }

    func testUninstallAppModeFailsClosedWhenAppBodyIsMissing() throws { // UNI-02
        let fixture = try Fixture()
        defer { fixture.remove() }
        try FileManager.default.removeItem(at: fixture.appURL)

        XCTAssertThrowsError(
            try fixture.service().uninstallTargets(for: fixture.app, mode: .uninstallApp)
        ) { error in
            XCTAssertEqual(error as? UninstallerAttributionError, .appBodyNotAdmitted)
        }
    }

    func testUninstallAppModeFailsClosedWhenSafetyDeniesAppBody() throws { // UNI-02
        let fixture = try Fixture()
        defer { fixture.remove() }
        let safety = DenyURLSafety(deniedPath: fixture.appURL.path)

        XCTAssertThrowsError(
            try fixture.service(safety: safety)
                .uninstallTargets(for: fixture.app, mode: .uninstallApp)
        ) { error in
            XCTAssertEqual(error as? UninstallerAttributionError, .appBodyNotAdmitted)
        }
    }

    func testCleanLeftoversModeRequiresAppAbsent() throws { // UNI-03
        let fixture = try Fixture()
        defer { fixture.remove() }
        XCTAssertThrowsError(
            try fixture.service().uninstallTargets(for: fixture.app, mode: .cleanLeftovers)
        ) { error in
            XCTAssertEqual(error as? UninstallerAttributionError, .appStillPresent)
        }

        try FileManager.default.removeItem(at: fixture.appURL)
        let candidates = try fixture.service().uninstallTargets(for: fixture.app, mode: .cleanLeftovers).candidates
        XCTAssertFalse(candidates.contains { $0.url.path == fixture.appURL.path })
    }

    func testEveryCandidateCarriesOwnershipEvidenceAndRecoveryHint() throws { // UNI-09
        let fixture = try Fixture()
        defer { fixture.remove() }
        _ = try fixture.createLibraryItem("Caches/\(fixture.app.bundleID)")
        _ = try fixture.createLibraryItem("Application Support/\(fixture.app.name)")

        let candidates = try fixture.service().uninstallTargets(for: fixture.app, mode: .uninstallApp).candidates

        XCTAssertFalse(candidates.isEmpty)
        XCTAssertTrue(candidates.allSatisfy { !$0.recoveryHint.isEmpty })
        XCTAssertTrue(candidates.allSatisfy { $0.targetRequest.recoverability == .trashRestorable })
    }

    func testSelectedCandidatesPrepareAnUninstallPlanWithMappedEvidence() throws { // UNI-09 / Task 1
        let fixture = try Fixture()
        defer { fixture.remove() }
        let exact = try fixture.createLibraryItem("Caches/\(fixture.app.bundleID)")
        let service = fixture.service()
        let batch = try service.uninstallTargets(for: fixture.app, mode: .uninstallApp)
        let candidates = batch.candidates
        let issuer = DestructiveOperationIssuer(sampler: NilIdentitySampler(),
                                                ledger: AuthorizationLedger())

        let plan = try service.prepareUninstallPlan(from: batch, using: issuer,
                                                now: Date(timeIntervalSince1970: 100))

        XCTAssertEqual(plan.kind, .uninstall)
        let exactCandidate = try XCTUnwrap(candidates.first { $0.url.path == exact.path })
        let target = try XCTUnwrap(plan.targets.first {
            $0.canonicalPath == exactCandidate.targetRequest.canonicalPath
        })
        XCTAssertEqual(target.attribution, Domain.AttributionEvidence.exactBundleIDPath)
        XCTAssertEqual(target.recoverability, .trashRestorable)
        let body = try XCTUnwrap(plan.targets.first {
            $0.canonicalPath == batch.candidates.first(where: { $0.role == .appBody })?
                .targetRequest.canonicalPath
        })
        XCTAssertEqual(body.attribution, Domain.AttributionEvidence.verifiedAppBody)
    }

    func testCapabilityControllerPreparesAndAuthorizesBeforeInvokingOperation() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        _ = try fixture.createLibraryItem("Caches/\(fixture.app.bundleID)")
        let service = fixture.service()
        let batch = try service.uninstallTargets(for: fixture.app, mode: .uninstallApp)
        let issuer = DestructiveOperationIssuer(sampler: NilIdentitySampler(),
                                                ledger: AuthorizationLedger())
        let controller = UninstallCapabilityController(issuer: issuer)
        let engine = CleaningEngine(safety: AllowAllSafety(), fs: LocalFileSystemService())

        let result = try await controller.execute(batch: batch, service: service) { items in
            XCTAssertEqual(items.count, batch.selectedCount)
            return await engine.execute(CleaningPlan(items: [], intent: .trash))
        }

        guard case .executed = result else {
            return XCTFail("valid service-issued batch must pass the Task 1 capability")
        }
    }

    func testPrepareUninstallPlanRejectsBatchIssuedByAnotherService() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let issuingService = fixture.service()
        let otherService = fixture.service()
        let batch = try issuingService.uninstallTargets(for: fixture.app, mode: .uninstallApp)
        let issuer = DestructiveOperationIssuer(sampler: NilIdentitySampler(),
                                                ledger: AuthorizationLedger())

        XCTAssertThrowsError(try otherService.prepareUninstallPlan(from: batch, using: issuer)) {
            XCTAssertEqual($0 as? UninstallPlanError, .foreignBatch)
        }
    }

    func testPrepareUninstallPlanRejectsForgedBatchWithoutRequiredBody() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let service = fixture.service()
        let batch = try service.uninstallTargets(for: fixture.app, mode: .uninstallApp)
        let forged = UninstallBatch(issuanceID: batch.issuanceID,
                                    batchID: batch.batchID,
                                    app: batch.app,
                                    mode: batch.mode,
                                    candidates: batch.candidates.filter { $0.role != .appBody })
        let issuer = DestructiveOperationIssuer(sampler: NilIdentitySampler(),
                                                ledger: AuthorizationLedger())

        XCTAssertThrowsError(try service.prepareUninstallPlan(from: forged, using: issuer)) {
            XCTAssertEqual($0 as? UninstallPlanError, .requiredAppBodyMissing)
        }
    }

    func testPrepareUninstallPlanRejectsMixedBatchCandidateBindings() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        _ = try fixture.createLibraryItem("Caches/\(fixture.app.bundleID)")
        let service = fixture.service()
        let first = try service.uninstallTargets(for: fixture.app, mode: .uninstallApp)
        let second = try service.uninstallTargets(for: fixture.app, mode: .uninstallApp)
        let foreignCandidate = try XCTUnwrap(second.candidates.first { $0.role != .appBody })
        let forged = UninstallBatch(issuanceID: first.issuanceID,
                                    batchID: first.batchID,
                                    app: first.app,
                                    mode: first.mode,
                                    candidates: first.candidates + [foreignCandidate])
        let issuer = DestructiveOperationIssuer(sampler: NilIdentitySampler(),
                                                ledger: AuthorizationLedger())

        XCTAssertThrowsError(try service.prepareUninstallPlan(from: forged, using: issuer)) {
            XCTAssertEqual($0 as? UninstallPlanError, .foreignCandidate)
        }
    }

    func testPrepareUninstallPlanRejectsSelectedUnverifiedCandidate() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let service = fixture.service()
        let batch = try service.uninstallTargets(for: fixture.app, mode: .uninstallApp)
        let item = CleanableItem(url: fixture.home.appendingPathComponent("Library/Caches/forged"),
                                 displayName: "forged", size: 1)
        let forgedCandidate = UninstallCandidate(item: item,
                                                 evidence: .unverified,
                                                 selectionPolicy: .recommended,
                                                 role: .associatedFile,
                                                 batchID: batch.batchID)
        let forged = UninstallBatch(issuanceID: batch.issuanceID,
                                    batchID: batch.batchID,
                                    app: batch.app,
                                    mode: batch.mode,
                                    candidates: batch.candidates + [forgedCandidate])
        let issuer = DestructiveOperationIssuer(sampler: NilIdentitySampler(),
                                                ledger: AuthorizationLedger())

        XCTAssertThrowsError(try service.prepareUninstallPlan(from: forged, using: issuer)) {
            XCTAssertEqual($0 as? UninstallPlanError, .invalidSelectedCandidate)
        }
    }

    func testGroupContainerMerelyContainingBundleIDSubstringIsNotAttributed() throws { // C2
        let fixture = try Fixture()
        defer { fixture.remove() }
        let misleading = "group.\(fixture.app.bundleID).other-product"
        let url = try fixture.createLibraryItem("Group Containers/\(misleading)")

        let candidates = try fixture.service(entitlements: ["group.com.example.real-shared"])
            .uninstallTargets(for: fixture.app, mode: .uninstallApp).candidates

        XCTAssertFalse(candidates.contains {
            $0.url.path == url.path && ($0.evidence == .signedApplicationGroup || $0.selectionPolicy == .recommended)
        })
    }

    func testLaunchAgentLabelContainingButNotEqualBundleIDIsNotRecommended() throws { // C2
        let fixture = try Fixture()
        defer { fixture.remove() }
        let plist = try fixture.createLibraryItem("LaunchAgents/\(fixture.app.bundleID).helper.plist", directory: false)
        let record = LaunchAgentRecord(label: "\(fixture.app.bundleID).helper",
                                       program: fixture.appURL.appendingPathComponent("Contents/MacOS/helper").path,
                                       programArguments: [])

        let candidates = try fixture.service(launchAgents: [plist.path: record])
            .uninstallTargets(for: fixture.app, mode: .uninstallApp).candidates

        XCTAssertFalse(candidates.contains {
            $0.url.path == plist.path && ($0.evidence == .launchAgentProgramInsideBundle || $0.selectionPolicy == .recommended)
        })
    }

    func testOrphanScannerExcludesGroupContainerContainingBundleIDSubstring() throws { // C2
        let fixture = try Fixture()
        defer { fixture.remove() }
        let misleading = try fixture.createLibraryItem(
            "Group Containers/group.\(fixture.app.bundleID).shared")

        let urls = OrphanScanner.artifactURLs(for: fixture.app.bundleID,
                                              home: fixture.home,
                                              fs: LocalFileSystemService())

        XCTAssertFalse(urls.contains { $0.path == misleading.path })
    }

    func testOrphanScannerExcludesLaunchAgentContainingBundleIDSubstring() throws { // C2
        let fixture = try Fixture()
        defer { fixture.remove() }
        let misleading = try fixture.createLibraryItem(
            "LaunchAgents/\(fixture.app.bundleID).helper.plist", directory: false)

        let urls = OrphanScanner.artifactURLs(for: fixture.app.bundleID,
                                              home: fixture.home,
                                              fs: LocalFileSystemService())

        XCTAssertFalse(urls.contains { $0.path == misleading.path })
    }
}
