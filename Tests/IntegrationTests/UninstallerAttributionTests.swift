import Foundation
import XCTest
@testable import Domain
@testable import Infrastructure

final class UninstallerAttributionTests: XCTestCase {
    private struct AllowAllSafety: SafetyEngine {
        func verify(_ url: URL, intent: DeleteIntent) -> SafetyVerdict { .allow }
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

        func service(entitlements: [String]? = [],
                     launchAgents: [String: LaunchAgentRecord] = [:]) -> UninstallerService {
            UninstallerService(
                fs: LocalFileSystemService(),
                safety: AllowAllSafety(),
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

        let candidates = try fixture.service().uninstallTargets(for: fixture.app, mode: .uninstallApp)

        XCTAssertFalse(candidates.contains { $0.url.path == pathFallbackTarget.path })
        let appBody = try XCTUnwrap(candidates.first { $0.url.path == fixture.appURL.path })
        XCTAssertEqual(appBody.evidence, .unverified)
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

        let candidates = try fixture.service().uninstallTargets(for: fixture.app, mode: .uninstallApp)

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
            .uninstallTargets(for: fixture.app, mode: .uninstallApp)

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
                .uninstallTargets(for: fixture.app, mode: .uninstallApp)
            XCTAssertFalse(candidates.contains {
                $0.url.path == url.path && ($0.evidence == .signedApplicationGroup || $0.selectionPolicy == .recommended)
            })
        }
    }

    func testLaunchAgentRecommendedOnlyWhenLabelExactAndProgramInsideBundle() throws { // UNI-07
        let fixture = try Fixture()
        defer { fixture.remove() }
        let plist = try fixture.createLibraryItem("LaunchAgents/\(fixture.app.bundleID).plist", directory: false)
        let record = LaunchAgentRecord(label: fixture.app.bundleID,
                                       program: fixture.appURL.appendingPathComponent("Contents/MacOS/helper").path,
                                       programArguments: [])

        let candidates = try fixture.service(launchAgents: [plist.path: record])
            .uninstallTargets(for: fixture.app, mode: .uninstallApp)

        let candidate = try XCTUnwrap(candidates.first { $0.url.path == plist.path })
        XCTAssertEqual(candidate.evidence, .launchAgentProgramInsideBundle)
        XCTAssertEqual(candidate.selectionPolicy, .recommended)
        XCTAssertTrue(candidate.isSelected)
    }

    func testLaunchAgentWithProgramOutsideBundleIsNotRecommended() throws { // UNI-07
        let fixture = try Fixture()
        defer { fixture.remove() }
        let plist = try fixture.createLibraryItem("LaunchAgents/\(fixture.app.bundleID).plist", directory: false)
        let record = LaunchAgentRecord(label: fixture.app.bundleID, program: "/usr/local/bin/shared-helper",
                                       programArguments: [])

        let candidates = try fixture.service(launchAgents: [plist.path: record])
            .uninstallTargets(for: fixture.app, mode: .uninstallApp)

        XCTAssertFalse(candidates.contains {
            $0.url.path == plist.path && ($0.evidence == .launchAgentProgramInsideBundle || $0.selectionPolicy == .recommended)
        })
    }

    func testDisplayNameDirectoryIsHeuristicDefaultUnselected() throws { // UNI-08
        let fixture = try Fixture()
        defer { fixture.remove() }
        let url = try fixture.createLibraryItem("Application Support/\(fixture.app.name)")

        let candidates = try fixture.service().uninstallTargets(for: fixture.app, mode: .uninstallApp)

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
        let candidates = try fixture.service(entitlements: [group])
            .uninstallTargets(for: fixture.app, mode: .uninstallApp)

        let selected = UninstallCandidate.selectAll(candidates)

        XCTAssertTrue(try XCTUnwrap(selected.first { $0.url.path == fixture.appURL.path }).isSelected)
        XCTAssertTrue(try XCTUnwrap(selected.first { $0.url.path == exact.path }).isSelected)
        XCTAssertFalse(try XCTUnwrap(selected.first { $0.url.path == heuristic.path }).isSelected)
        XCTAssertFalse(try XCTUnwrap(selected.first { $0.url.path == groupURL.path }).isSelected)
    }

    func testUninstallAppModeMarksAppBodyRequiredNonDeselectable() throws { // UNI-02
        let fixture = try Fixture()
        defer { fixture.remove() }
        let candidates = try fixture.service().uninstallTargets(for: fixture.app, mode: .uninstallApp)

        var appBody = try XCTUnwrap(candidates.first { $0.url.path == fixture.appURL.path })
        XCTAssertEqual(appBody.selectionPolicy, .required)
        XCTAssertFalse(appBody.isSelectable)
        appBody.setSelected(false)
        XCTAssertTrue(appBody.isSelected)
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
        let candidates = try fixture.service().uninstallTargets(for: fixture.app, mode: .cleanLeftovers)
        XCTAssertFalse(candidates.contains { $0.url.path == fixture.appURL.path })
    }

    func testEveryCandidateCarriesOwnershipEvidenceAndRecoveryHint() throws { // UNI-09
        let fixture = try Fixture()
        defer { fixture.remove() }
        _ = try fixture.createLibraryItem("Caches/\(fixture.app.bundleID)")
        _ = try fixture.createLibraryItem("Application Support/\(fixture.app.name)")

        let candidates = try fixture.service().uninstallTargets(for: fixture.app, mode: .uninstallApp)

        XCTAssertFalse(candidates.isEmpty)
        XCTAssertTrue(candidates.allSatisfy { !$0.recoveryHint.isEmpty })
        XCTAssertTrue(candidates.allSatisfy { $0.targetRequest.recoverability == .trashRestorable })
    }

    func testSelectedCandidatesPrepareAnUninstallPlanWithMappedEvidence() throws { // UNI-09 / Task 1
        let fixture = try Fixture()
        defer { fixture.remove() }
        let exact = try fixture.createLibraryItem("Caches/\(fixture.app.bundleID)")
        let service = fixture.service()
        let candidates = try service.uninstallTargets(for: fixture.app, mode: .uninstallApp)
        let issuer = DestructiveOperationIssuer(sampler: NilIdentitySampler(),
                                                ledger: AuthorizationLedger())

        let plan = service.prepareUninstallPlan(from: candidates, using: issuer,
                                                now: Date(timeIntervalSince1970: 100))

        XCTAssertEqual(plan.kind, .uninstall)
        let exactCandidate = try XCTUnwrap(candidates.first { $0.url.path == exact.path })
        let target = try XCTUnwrap(plan.targets.first {
            $0.canonicalPath == exactCandidate.targetRequest.canonicalPath
        })
        XCTAssertEqual(target.attribution, Domain.AttributionEvidence.exactBundleIDPath)
        XCTAssertEqual(target.recoverability, .trashRestorable)
    }

    func testGroupContainerMerelyContainingBundleIDSubstringIsNotAttributed() throws { // C2
        let fixture = try Fixture()
        defer { fixture.remove() }
        let misleading = "group.\(fixture.app.bundleID).other-product"
        let url = try fixture.createLibraryItem("Group Containers/\(misleading)")

        let candidates = try fixture.service(entitlements: ["group.com.example.real-shared"])
            .uninstallTargets(for: fixture.app, mode: .uninstallApp)

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
            .uninstallTargets(for: fixture.app, mode: .uninstallApp)

        XCTAssertFalse(candidates.contains {
            $0.url.path == plist.path && ($0.evidence == .launchAgentProgramInsideBundle || $0.selectionPolicy == .recommended)
        })
    }
}
