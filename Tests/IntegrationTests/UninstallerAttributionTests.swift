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

    private final class MutableSafety: @unchecked Sendable, SafetyEngine {
        private let lock = NSLock()
        private var allowed = true
        func deny() { lock.withLock { allowed = false } }
        func verify(_ url: URL, intent: DeleteIntent) -> SafetyVerdict {
            lock.withLock { allowed } ? .allow : .deny(reason: "changed fixture verdict")
        }
    }

    private struct FakeEntitlementReader: EntitlementReader {
        let groups: [String]?
        func attestation(for appURL: URL) -> SignedEntitlementAttestation? {
            guard let groups,
                  let identity = LocalFileIdentitySampler().sample(appURL.path) else { return nil }
            let bundleID = Bundle(url: appURL)?.bundleIdentifier ?? ""
            return SignedEntitlementAttestation(groups: groups.sorted(),
                                                codeIdentifier: bundleID,
                                                uniqueCode: Data([1]),
                                                sourceIdentity: identity)
        }
    }

    private struct FakeLaunchAgentReader: LaunchAgentReader {
        let records: [String: LaunchAgentRecord]
        func attestation(at url: URL) -> LaunchAgentAttestation? {
            guard let record = records[url.path] else { return nil }
            return LaunchAgentAttestation.capture(record: record, plistURL: url)
        }
    }

    private struct NilIdentitySampler: IdentitySampler {
        func sample(_ canonicalPath: String) -> LocalFileIdentity? { nil }
    }

    private final class SequenceIdentitySampler: @unchecked Sendable, IdentitySampler {
        private let lock = NSLock()
        private var values: [LocalFileIdentity?]

        init(_ values: [LocalFileIdentity?]) { self.values = values }

        func sample(_ canonicalPath: String) -> LocalFileIdentity? {
            lock.withLock {
                if values.count > 1 { return values.removeFirst() }
                return values.first ?? nil
            }
        }
    }

    private struct FakeSecurityCodeInspector: SecurityCodeInspecting {
        let inspection: SecurityCodeInspection?
        func inspect(appURL: URL) -> SecurityCodeInspection? { inspection }
    }

    private final class MutableEntitlementAttestationReader: @unchecked Sendable, EntitlementReader {
        private let lock = NSLock()
        private var stored: SignedEntitlementAttestation?

        init(_ attestation: SignedEntitlementAttestation?) { stored = attestation }
        func set(_ attestation: SignedEntitlementAttestation?) {
            lock.withLock { stored = attestation }
        }
        func attestation(for appURL: URL) -> SignedEntitlementAttestation? {
            lock.withLock { stored }
        }
    }

    private final class InvocationCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        var count: Int { lock.withLock { value } }
        func increment() { lock.withLock { value += 1 } }
    }

    private struct Fixture {
        let root: URL
        let home: URL
        let appURL: URL
        let app: InstalledApp
        let issuanceID: UUID

        init(bundleID: String = "com.example.product", displayName: String = "Example Product") throws {
            let unresolvedRoot = FileManager.default.temporaryDirectory
                .appendingPathComponent("xico-uninstaller-attribution-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: unresolvedRoot, withIntermediateDirectories: true)
            root = unresolvedRoot.path.hasPrefix("/var/")
                ? URL(fileURLWithPath: "/private" + unresolvedRoot.path)
                : unresolvedRoot.resolvingSymlinksInPath()
            home = root.appendingPathComponent("home")
            issuanceID = UUID()
            appURL = home.appendingPathComponent("Applications/Example Product.app")
            try FileManager.default.createDirectory(at: appURL, withIntermediateDirectories: true)
            let contents = appURL.appendingPathComponent("Contents")
            try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
            var info: [String: Any] = ["CFBundleName": displayName]
            if !bundleID.isEmpty { info["CFBundleIdentifier"] = bundleID }
            let infoData = try PropertyListSerialization.data(fromPropertyList: info,
                                                              format: .xml, options: 0)
            try infoData.write(to: contents.appendingPathComponent("Info.plist"))
            let identity = try XCTUnwrap(LocalFileIdentitySampler().sample(appURL.path))
            let metadataIdentity = try XCTUnwrap(LocalFileIdentitySampler().sample(
                contents.appendingPathComponent("Info.plist").path))
            app = InstalledApp(id: appURL.path, name: displayName, bundleID: bundleID,
                               url: appURL, size: 0, provenanceID: issuanceID,
                               sourceIdentity: identity, metadataIdentity: metadataIdentity)
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
                launchAgentReader: FakeLaunchAgentReader(records: launchAgents),
                identitySampler: LocalFileIdentitySampler(),
                issuanceID: issuanceID)
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

        XCTAssertNil(SecurityEntitlementReader().attestation(for: fixture.appURL))
    }

    func testSecurityEntitlementReaderRejectsChangedPrePostSourceIdentity() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let before = try XCTUnwrap(LocalFileIdentitySampler().sample(fixture.appURL.path))
        let after = LocalFileIdentity(device: before.device, inode: before.inode + 1,
                                      mode: before.mode, size: before.size,
                                      mtimeNanoseconds: before.mtimeNanoseconds,
                                      hardLinkCount: before.hardLinkCount)
        let inspector = FakeSecurityCodeInspector(inspection: SecurityCodeInspection(
            groups: ["group.com.example.shared"], codeIdentifier: fixture.app.bundleID,
            uniqueCode: Data([1, 2, 3])))
        let reader = SecurityEntitlementReader(
            inspector: inspector,
            identitySampler: SequenceIdentitySampler([before, after]))

        XCTAssertNil(reader.attestation(for: fixture.appURL))
    }

    func testSecurityEntitlementReaderRejectsExcessiveGroupCount() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let identity = try XCTUnwrap(LocalFileIdentitySampler().sample(fixture.appURL.path))
        let groups = (0...SecurityEntitlementReader.maximumGroupCount).map {
            "group.com.example.\($0)"
        }
        let reader = SecurityEntitlementReader(
            inspector: FakeSecurityCodeInspector(inspection: SecurityCodeInspection(
                groups: groups, codeIdentifier: fixture.app.bundleID,
                uniqueCode: Data([1]))),
            identitySampler: SequenceIdentitySampler([identity, identity]))

        XCTAssertNil(reader.attestation(for: fixture.appURL))
    }

    func testSecurityEntitlementReaderRejectsExcessiveAggregateGroupBytes() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let identity = try XCTUnwrap(LocalFileIdentitySampler().sample(fixture.appURL.path))
        let oversized = "group." + String(
            repeating: "a", count: SecurityEntitlementReader.maximumGroupUTF8Bytes)
        let reader = SecurityEntitlementReader(
            inspector: FakeSecurityCodeInspector(inspection: SecurityCodeInspection(
                groups: [oversized], codeIdentifier: fixture.app.bundleID,
                uniqueCode: Data([1]))),
            identitySampler: SequenceIdentitySampler([identity, identity]))

        XCTAssertNil(reader.attestation(for: fixture.appURL))
    }

    func testPrepareUninstallPlanRejectsChangedSignedEntitlementAttestation() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let group = "group.com.example.shared"
        _ = try fixture.createLibraryItem("Group Containers/\(group)")
        let original = SignedEntitlementAttestation(
            groups: [group], codeIdentifier: fixture.app.bundleID,
            uniqueCode: Data([1, 2, 3]), sourceIdentity: fixture.app.sourceIdentity)
        let reader = MutableEntitlementAttestationReader(original)
        let service = UninstallerService(
            fs: LocalFileSystemService(), safety: AllowAllSafety(), home: fixture.home,
            entitlementReader: reader, launchAgentReader: FakeLaunchAgentReader(records: [:]),
            identitySampler: LocalFileIdentitySampler(), issuanceID: fixture.issuanceID)
        let batch = try service.uninstallTargets(for: fixture.app, mode: .uninstallApp)
        reader.set(SignedEntitlementAttestation(
            groups: [group], codeIdentifier: fixture.app.bundleID,
            uniqueCode: Data([9, 9, 9]), sourceIdentity: fixture.app.sourceIdentity))
        let issuer = DestructiveOperationIssuer(sampler: LocalFileIdentitySampler(),
                                                ledger: AuthorizationLedger())

        XCTAssertThrowsError(try service.prepareUninstallPlan(from: batch, using: issuer)) {
            XCTAssertEqual($0 as? UninstallPlanError, .entitlementAttestationChanged)
        }
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

    func testPlistLaunchAgentReaderReturnsPlistAndResolvedProgramIdentities() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let executable = try fixture.createAppExecutable()
        let plist = try fixture.createLaunchAgentPlist(
            "\(fixture.app.bundleID).plist",
            dictionary: ["Label": fixture.app.bundleID, "Program": executable.path])

        let attestation = try XCTUnwrap(PlistLaunchAgentReader().attestation(at: plist))

        XCTAssertEqual(attestation.record.label, fixture.app.bundleID)
        XCTAssertEqual(attestation.plistIdentity,
                       LocalFileIdentitySampler().sample(plist.path))
        XCTAssertEqual(attestation.resolvedProgramPath,
                       executable.resolvingSymlinksInPath().standardizedFileURL.path)
        XCTAssertEqual(attestation.programIdentity,
                       LocalFileIdentitySampler().sample(executable.path))
    }

    func testPlistLaunchAgentReaderRejectsPathReplacementDuringRead() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let executable = try fixture.createAppExecutable()
        let plist = try fixture.createLaunchAgentPlist(
            "\(fixture.app.bundleID).plist",
            dictionary: ["Label": fixture.app.bundleID, "Program": executable.path])
        let replacement = try fixture.createLaunchAgentPlist(
            "replacement.plist",
            dictionary: ["Label": fixture.app.bundleID, "Program": executable.path])
        let reader = PlistLaunchAgentReader(afterRead: {
            try? FileManager.default.removeItem(at: plist)
            try? FileManager.default.moveItem(at: replacement, to: plist)
        })

        XCTAssertNil(reader.attestation(at: plist))
    }

    func testPrepareUninstallPlanRejectsLaunchPlistReplacement() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let executable = try fixture.createAppExecutable()
        let plist = try fixture.createLaunchAgentPlist(
            "\(fixture.app.bundleID).plist",
            dictionary: ["Label": fixture.app.bundleID, "Program": executable.path])
        let service = UninstallerService(
            fs: LocalFileSystemService(), safety: AllowAllSafety(), home: fixture.home,
            entitlementReader: FakeEntitlementReader(groups: []),
            launchAgentReader: PlistLaunchAgentReader(),
            identitySampler: LocalFileIdentitySampler(), issuanceID: fixture.issuanceID)
        let batch = try service.uninstallTargets(for: fixture.app, mode: .uninstallApp)
        let replacement = try fixture.createLaunchAgentPlist(
            "replacement.plist",
            dictionary: ["Label": fixture.app.bundleID, "Program": executable.path])
        try FileManager.default.removeItem(at: plist)
        try FileManager.default.moveItem(at: replacement, to: plist)
        let issuer = DestructiveOperationIssuer(sampler: LocalFileIdentitySampler(),
                                                ledger: AuthorizationLedger())

        XCTAssertThrowsError(try service.prepareUninstallPlan(from: batch, using: issuer)) {
            XCTAssertEqual($0 as? UninstallPlanError, .launchAgentAttestationChanged)
        }
    }

    func testPrepareUninstallPlanRejectsLaunchProgramSamePathReplacement() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let executable = try fixture.createAppExecutable()
        _ = try fixture.createLaunchAgentPlist(
            "\(fixture.app.bundleID).plist",
            dictionary: ["Label": fixture.app.bundleID, "Program": executable.path])
        let service = UninstallerService(
            fs: LocalFileSystemService(), safety: AllowAllSafety(), home: fixture.home,
            entitlementReader: FakeEntitlementReader(groups: []),
            launchAgentReader: PlistLaunchAgentReader(),
            identitySampler: LocalFileIdentitySampler(), issuanceID: fixture.issuanceID)
        let batch = try service.uninstallTargets(for: fixture.app, mode: .uninstallApp)
        try FileManager.default.removeItem(at: executable)
        try Data("replacement executable".utf8).write(to: executable)
        let issuer = DestructiveOperationIssuer(sampler: LocalFileIdentitySampler(),
                                                ledger: AuthorizationLedger())

        XCTAssertThrowsError(try service.prepareUninstallPlan(from: batch, using: issuer)) {
            XCTAssertEqual($0 as? UninstallPlanError, .launchAgentAttestationChanged)
        }
    }

    func testPrepareUninstallPlanRejectsLaunchProgramSymlinkRetarget() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let first = try fixture.createAppExecutable("Contents/MacOS/first")
        let second = try fixture.createAppExecutable("Contents/MacOS/second")
        let link = fixture.appURL.appendingPathComponent("Contents/MacOS/current")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: first)
        _ = try fixture.createLaunchAgentPlist(
            "\(fixture.app.bundleID).plist",
            dictionary: ["Label": fixture.app.bundleID, "Program": link.path])
        let service = UninstallerService(
            fs: LocalFileSystemService(), safety: AllowAllSafety(), home: fixture.home,
            entitlementReader: FakeEntitlementReader(groups: []),
            launchAgentReader: PlistLaunchAgentReader(),
            identitySampler: LocalFileIdentitySampler(), issuanceID: fixture.issuanceID)
        let batch = try service.uninstallTargets(for: fixture.app, mode: .uninstallApp)
        try FileManager.default.removeItem(at: link)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: second)
        let issuer = DestructiveOperationIssuer(sampler: LocalFileIdentitySampler(),
                                                ledger: AuthorizationLedger())

        XCTAssertThrowsError(try service.prepareUninstallPlan(from: batch, using: issuer)) {
            XCTAssertEqual($0 as? UninstallPlanError, .launchAgentAttestationChanged)
        }
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
        let issuer = DestructiveOperationIssuer(sampler: LocalFileIdentitySampler(),
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

    func testCapabilityControllerRejectsNilTargetIdentityWithoutInvokingOperation() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        _ = try fixture.createLibraryItem("Caches/\(fixture.app.bundleID)")
        let service = fixture.service()
        let batch = try service.uninstallTargets(for: fixture.app, mode: .uninstallApp)
        let issuer = DestructiveOperationIssuer(sampler: NilIdentitySampler(),
                                                ledger: AuthorizationLedger())
        let controller = UninstallCapabilityController(issuer: issuer)
        let engine = CleaningEngine(safety: AllowAllSafety(), fs: LocalFileSystemService())
        let counter = InvocationCounter()

        do {
            _ = try await controller.execute(batch: batch, service: service) { _ in
                counter.increment()
                return await engine.execute(CleaningPlan(items: [], intent: .trash))
            }
            XCTFail("nil identity must fail closed")
        } catch {
            XCTAssertEqual(error as? UninstallPlanError, .missingTargetIdentity)
        }

        XCTAssertEqual(counter.count, 0)
    }

    func testCapabilityControllerExecutesWhenEverySelectedIdentityExists() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        _ = try fixture.createLibraryItem("Caches/\(fixture.app.bundleID)")
        let service = fixture.service()
        let batch = try service.uninstallTargets(for: fixture.app, mode: .uninstallApp)
        let issuer = DestructiveOperationIssuer(sampler: LocalFileIdentitySampler(),
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

    func testCapabilityControllerConsumesBatchExactlyOnceSequentially() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let service = fixture.service()
        let batch = try service.uninstallTargets(for: fixture.app, mode: .uninstallApp)
        let controller = UninstallCapabilityController(
            issuer: DestructiveOperationIssuer(sampler: LocalFileIdentitySampler(),
                                                ledger: AuthorizationLedger()))
        let engine = CleaningEngine(safety: AllowAllSafety(), fs: LocalFileSystemService())
        let counter = InvocationCounter()

        _ = try await controller.execute(batch: batch, service: service) { _ in
            counter.increment()
            return await engine.execute(CleaningPlan(items: [], intent: .trash))
        }
        do {
            _ = try await controller.execute(batch: batch, service: service) { _ in
                counter.increment()
                return await engine.execute(CleaningPlan(items: [], intent: .trash))
            }
            XCTFail("batch replay must fail closed")
        } catch {
            XCTAssertEqual(error as? UninstallPlanError, .batchAlreadyConsumed)
        }
        XCTAssertEqual(counter.count, 1)
    }

    func testCapabilityControllerConsumesBatchExactlyOnceConcurrently() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let service = fixture.service()
        let batch = try service.uninstallTargets(for: fixture.app, mode: .uninstallApp)
        let controller = UninstallCapabilityController(
            issuer: DestructiveOperationIssuer(sampler: LocalFileIdentitySampler(),
                                                ledger: AuthorizationLedger()))
        let engine = CleaningEngine(safety: AllowAllSafety(), fs: LocalFileSystemService())
        let counter = InvocationCounter()

        let executed = await withTaskGroup(of: Bool.self, returning: Int.self) { group in
            for _ in 0..<12 {
                group.addTask {
                    do {
                        let result = try await controller.execute(batch: batch, service: service) { _ in
                            counter.increment()
                            return await engine.execute(CleaningPlan(items: [], intent: .trash))
                        }
                        if case .executed = result { return true }
                    } catch {}
                    return false
                }
            }
            var count = 0
            for await value in group where value { count += 1 }
            return count
        }

        XCTAssertEqual(executed, 1)
        XCTAssertEqual(counter.count, 1)
    }

    func testCapabilityControllerRejectsExpiredBatchBeforeOperation() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let service = fixture.service()
        let createdAt = Date(timeIntervalSince1970: 100)
        let issued = try service.uninstallTargets(for: fixture.app, mode: .uninstallApp)
        let batch = UninstallBatch(issuanceID: issued.issuanceID,
                                   batchID: issued.batchID,
                                   app: issued.app,
                                   mode: issued.mode,
                                   candidates: issued.candidates,
                                   createdAt: createdAt,
                                   expiresAt: createdAt.addingTimeInterval(300))
        let controller = UninstallCapabilityController(
            issuer: DestructiveOperationIssuer(sampler: LocalFileIdentitySampler(),
                                                ledger: AuthorizationLedger()),
            now: { Date(timeIntervalSince1970: 401) })
        let engine = CleaningEngine(safety: AllowAllSafety(), fs: LocalFileSystemService())
        let counter = InvocationCounter()

        do {
            _ = try await controller.execute(batch: batch, service: service) { _ in
                counter.increment()
                return await engine.execute(CleaningPlan(items: [], intent: .trash))
            }
            XCTFail("expired batch must fail closed")
        } catch {
            XCTAssertEqual(error as? UninstallPlanError, .batchExpired)
        }
        XCTAssertEqual(counter.count, 0)
    }

    func testUninstallTargetsRejectsAppIssuedByAnotherService() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let issuingService = fixture.service()
        let otherService = UninstallerService(
            fs: LocalFileSystemService(), safety: AllowAllSafety(), home: fixture.home,
            entitlementReader: FakeEntitlementReader(groups: []),
            launchAgentReader: FakeLaunchAgentReader(records: [:]))
        let issuedApp = try XCTUnwrap(issuingService.listApps().first {
            $0.url.standardizedFileURL.path == fixture.appURL.standardizedFileURL.path
        })

        XCTAssertThrowsError(
            try otherService.uninstallTargets(for: issuedApp, mode: .uninstallApp)
        ) { error in
            XCTAssertEqual(error as? UninstallerAttributionError, .foreignApp)
        }
    }

    func testPrepareUninstallPlanRejectsSamePathAppBodyReplacement() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let service = fixture.service()
        let batch = try service.uninstallTargets(for: fixture.app, mode: .uninstallApp)
        try FileManager.default.removeItem(at: fixture.appURL)
        try FileManager.default.createDirectory(at: fixture.appURL.appendingPathComponent("Contents"),
                                                withIntermediateDirectories: true)
        let replacementInfo = try PropertyListSerialization.data(
            fromPropertyList: ["CFBundleIdentifier": fixture.app.bundleID,
                               "CFBundleName": fixture.app.name],
            format: .xml, options: 0)
        try replacementInfo.write(to: fixture.appURL.appendingPathComponent("Contents/Info.plist"))
        let issuer = DestructiveOperationIssuer(sampler: LocalFileIdentitySampler(),
                                                ledger: AuthorizationLedger())

        XCTAssertThrowsError(try service.prepareUninstallPlan(from: batch, using: issuer)) {
            XCTAssertEqual($0 as? UninstallPlanError, .appIdentityChanged)
        }
    }

    func testPrepareUninstallPlanRechecksRequiredBodySafety() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let safety = MutableSafety()
        let service = fixture.service(safety: safety)
        let batch = try service.uninstallTargets(for: fixture.app, mode: .uninstallApp)
        safety.deny()
        let issuer = DestructiveOperationIssuer(sampler: LocalFileIdentitySampler(),
                                                ledger: AuthorizationLedger())

        XCTAssertThrowsError(try service.prepareUninstallPlan(from: batch, using: issuer)) {
            XCTAssertEqual($0 as? UninstallPlanError, .requiredAppBodyMissing)
        }
    }

    func testPrepareUninstallPlanRejectsSameContentInfoPlistReplacement() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let service = fixture.service()
        let batch = try service.uninstallTargets(for: fixture.app, mode: .uninstallApp)
        let infoURL = fixture.appURL.appendingPathComponent("Contents/Info.plist")
        let originalData = try Data(contentsOf: infoURL)
        try FileManager.default.removeItem(at: infoURL)
        try originalData.write(to: infoURL)
        let issuer = DestructiveOperationIssuer(sampler: LocalFileIdentitySampler(),
                                                ledger: AuthorizationLedger())

        XCTAssertThrowsError(try service.prepareUninstallPlan(from: batch, using: issuer)) {
            XCTAssertEqual($0 as? UninstallPlanError, .appMetadataChanged)
        }
    }

    func testPrepareUninstallPlanRejectsBatchIssuedByAnotherService() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let issuingService = UninstallerService(
            fs: LocalFileSystemService(), safety: AllowAllSafety(), home: fixture.home,
            entitlementReader: FakeEntitlementReader(groups: []),
            launchAgentReader: FakeLaunchAgentReader(records: [:]))
        let otherService = UninstallerService(
            fs: LocalFileSystemService(), safety: AllowAllSafety(), home: fixture.home,
            entitlementReader: FakeEntitlementReader(groups: []),
            launchAgentReader: FakeLaunchAgentReader(records: [:]))
        let issuedApp = try XCTUnwrap(issuingService.listApps().first {
            $0.url.standardizedFileURL.path == fixture.appURL.standardizedFileURL.path
        })
        let batch = try issuingService.uninstallTargets(for: issuedApp, mode: .uninstallApp)
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
