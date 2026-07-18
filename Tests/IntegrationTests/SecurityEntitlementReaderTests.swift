import Foundation
import Security
import XCTest
#if canImport(Darwin)
import Darwin
#endif
@testable import Domain
@testable import Infrastructure

final class SecurityEntitlementReaderTests: XCTestCase {
    private final class Trace: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [String] = []
        func append(_ value: String) { lock.withLock { values.append(value) } }
        var snapshot: [String] { lock.withLock { values } }
    }

    private final class ScriptedSession: @unchecked Sendable, SecurityFrameworkSession {
        let name: String
        let trace: Trace
        let fields: RawSecuritySigningFields
        private let lock = NSLock()
        private var validity: [Bool]
        private var validityCheckCount = 0
        private let afterSecondValidity: (@Sendable () -> Void)?

        init(name: String, trace: Trace, fields: RawSecuritySigningFields,
             validity: [Bool] = [true, true],
             afterSecondValidity: (@Sendable () -> Void)? = nil) {
            self.name = name
            self.trace = trace
            self.fields = fields
            self.validity = validity
            self.afterSecondValidity = afterSecondValidity
        }

        func checkValidity(_ policy: StaticCodeValidationPolicy) -> Bool {
            trace.append("\(name).strict")
            let (result, isSecond) = lock.withLock {
                validityCheckCount += 1
                return (validity.removeFirst(), validityCheckCount == 2)
            }
            if isSecond { afterSecondValidity?() }
            return result
        }

        func copySigningFields(_ policy: SigningInformationPolicy) -> RawSecuritySigningFields? {
            trace.append("\(name).copy")
            return fields
        }
    }

    private final class ScriptedFactory: @unchecked Sendable, SecurityFrameworkSessionFactory {
        let trace: Trace
        private let lock = NSLock()
        private var sessions: [ScriptedSession]

        init(trace: Trace, sessions: [ScriptedSession]) {
            self.trace = trace
            self.sessions = sessions
        }

        func open(appURL: URL) -> (any SecurityFrameworkSession)? {
            lock.withLock {
                guard !sessions.isEmpty else { return nil }
                let session = sessions.removeFirst()
                trace.append("open.\(session.name)")
                return session
            }
        }
    }

    private final class SequenceSourceAttestor: @unchecked Sendable,
                                                SecurityCodeSourceAttesting {
        let trace: Trace
        private let lock = NSLock()
        private var seals: [AppBundleSourceSeal]

        init(trace: Trace, seals: [AppBundleSourceSeal]) {
            self.trace = trace
            self.seals = seals
        }

        func capture(appURL: URL) -> AppBundleSourceSeal? {
            lock.withLock {
                trace.append("source")
                guard !seals.isEmpty else { return nil }
                return seals.removeFirst()
            }
        }
    }

    private final class OneShotMutation: @unchecked Sendable {
        private let lock = NSLock()
        private var completed = false
        private let action: @Sendable () -> Void

        init(_ action: @escaping @Sendable () -> Void) { self.action = action }

        var didRun: Bool { lock.withLock { completed } }

        func run() {
            let shouldRun = lock.withLock {
                guard !completed else { return false }
                completed = true
                return true
            }
            if shouldRun { action() }
        }
    }

    private let executableURL = URL(fileURLWithPath: "/Applications/Example.app/Contents/MacOS/Example")

    private func raw(groups: [String] = ["group.com.example.shared"],
                     identifier: String = "com.example.product",
                     uniqueCode: Data = Data([1])) -> RawSecuritySigningFields {
        RawSecuritySigningFields(groups: groups, codeIdentifier: identifier,
                                 uniqueCode: uniqueCode,
                                 mainExecutableURL: executableURL)
    }

    private func identity(inode: UInt64) -> Domain.LocalFileIdentity {
        Domain.LocalFileIdentity(device: 1, inode: inode, mode: 0o100_644,
                                 size: 16, mtimeNanoseconds: 10,
                                 changeTimeNanoseconds: 20, hardLinkCount: 1)
    }

    private func fingerprint(_ byte: UInt8) -> Domain.EvidenceFingerprint {
        EvidenceFingerprint(sha256: [UInt8](repeating: byte, count: 32))!
    }

    private func sourceSeal(_ byte: UInt8 = 1) -> AppBundleSourceSeal {
        let executablePath = executableURL.path
        let info = AppBundleBoundedContentAttestation(
            relativeComponentsInsideApp: ["Contents", "Info.plist"],
            identity: identity(inode: 2), exactLength: 16,
            contentDigest: fingerprint(byte), pathChainFingerprint: fingerprint(2))
        let program = ProgramChangeToken(
            canonicalPath: executablePath,
            relativeComponentsInsideApp: ["Contents", "MacOS", "Example"],
            directoryChain: [identity(inode: 1)], executable: identity(inode: 3),
            chainFingerprint: fingerprint(3), boundedExactLength: 16,
            boundedContentDigest: fingerprint(4))
        let resources = AppBundleBoundedContentAttestation(
            relativeComponentsInsideApp: ["Contents", "_CodeSignature", "CodeResources"],
            identity: identity(inode: 4), exactLength: 16,
            contentDigest: fingerprint(5), pathChainFingerprint: fingerprint(6))
        return AppBundleSourceSeal(
            appRoot: identity(inode: 1), appChainFingerprint: fingerprint(7),
            infoPlist: info, mainExecutable: program,
            mainExecutableCanonicalPath: executablePath, codeResources: resources,
            nestedRosterFingerprint: fingerprint(byte))
    }

    func testSecurityEntitlementReaderRequiresTwoFreshStrictSessionsInExactOrder() {
        let trace = Trace()
        let fields = raw()
        let first = ScriptedSession(name: "s1", trace: trace, fields: fields)
        let second = ScriptedSession(name: "s2", trace: trace, fields: fields)
        let seal = sourceSeal()
        let reader = SecurityEntitlementReader(
            sessionFactory: ScriptedFactory(trace: trace, sessions: [first, second]),
            sourceAttestor: SequenceSourceAttestor(
                trace: trace, seals: [seal, seal, seal, seal]))

        XCTAssertNotNil(reader.attestation(
            for: URL(fileURLWithPath: "/Applications/Example.app")))
        XCTAssertEqual(trace.snapshot, [
            "source", "open.s1", "s1.strict", "s1.copy", "s1.strict", "source",
            "source", "open.s2", "s2.strict", "s2.copy", "s2.strict", "source"
        ])
    }

    func testSecurityEntitlementReaderRejectsFailureAtEachStrictCheckPosition() {
        for failingPosition in 0..<4 {
            let trace = Trace()
            let fields = raw()
            var firstValidity = [true, true]
            var secondValidity = [true, true]
            if failingPosition < 2 {
                firstValidity[failingPosition] = false
            } else {
                secondValidity[failingPosition - 2] = false
            }
            let reader = SecurityEntitlementReader(
                sessionFactory: ScriptedFactory(trace: trace, sessions: [
                    ScriptedSession(name: "s1", trace: trace, fields: fields,
                                    validity: firstValidity),
                    ScriptedSession(name: "s2", trace: trace, fields: fields,
                                    validity: secondValidity)
                ]),
                sourceAttestor: SequenceSourceAttestor(
                    trace: trace, seals: Array(repeating: sourceSeal(), count: 4)))
            XCTAssertNil(reader.attestation(
                for: URL(fileURLWithPath: "/Applications/Example.app")),
                "strict position \(failingPosition) must fail closed")
        }
    }

    func testSecurityEntitlementReaderRejectsSigningChangeBetweenFreshSessions() {
        let trace = Trace()
        let firstFields = raw(uniqueCode: Data([1]))
        let secondFields = raw(uniqueCode: Data([2]))
        let seal = sourceSeal()
        let reader = SecurityEntitlementReader(
            sessionFactory: ScriptedFactory(trace: trace, sessions: [
                ScriptedSession(name: "s1", trace: trace, fields: firstFields),
                ScriptedSession(name: "s2", trace: trace, fields: secondFields)
            ]),
            sourceAttestor: SequenceSourceAttestor(
                trace: trace, seals: [seal, seal, seal, seal]))

        XCTAssertNil(reader.attestation(
            for: URL(fileURLWithPath: "/Applications/Example.app")))
    }

    func testSecurityEntitlementReaderRejectsSourceChangeInsideOrBetweenPhases() {
        let appURL = URL(fileURLWithPath: "/Applications/Example.app")
        let a = sourceSeal(1)
        let b = sourceSeal(9)
        for seals in [[a, b, a, a], [a, a, b, b]] {
            let trace = Trace()
            let fields = raw()
            let reader = SecurityEntitlementReader(
                sessionFactory: ScriptedFactory(trace: trace, sessions: [
                    ScriptedSession(name: "s1", trace: trace, fields: fields),
                    ScriptedSession(name: "s2", trace: trace, fields: fields)
                ]),
                sourceAttestor: SequenceSourceAttestor(trace: trace, seals: seals))
            XCTAssertNil(reader.attestation(for: appURL))
        }
    }

    func testSecurityEntitlementReaderRejectsSameInodeResourceRewriteAfterFinalStrictValidity()
        throws {
        #if canImport(Darwin)
        let root = URL(fileURLWithPath:
            "/Users/Shared/xico-security-entitlement-\(UUID().uuidString)",
            isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let appURL = root.appendingPathComponent("Example.app", isDirectory: true)
        let contents = appURL.appendingPathComponent("Contents", isDirectory: true)
        let macOS = contents.appendingPathComponent("MacOS", isDirectory: true)
        let signature = contents.appendingPathComponent("_CodeSignature", isDirectory: true)
        let resources = contents.appendingPathComponent("Resources", isDirectory: true)
        for directory in [macOS, signature, resources] {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
        }
        let infoData = try PropertyListSerialization.data(
            fromPropertyList: ["CFBundleExecutable": "Example"],
            format: .binary, options: 0)
        try infoData.write(to: contents.appendingPathComponent("Info.plist"))
        let executableURL = macOS.appendingPathComponent("Example")
        try Data("executable".utf8).write(to: executableURL)
        try Data("sealed-resources".utf8).write(
            to: signature.appendingPathComponent("CodeResources"))
        let resourceURL = resources.appendingPathComponent("mutable.dat")
        try Data("mutable-resource".utf8).write(to: resourceURL)

        let baselineSource = try XCTUnwrap(
            SystemSecurityCodeSourceAttestor().capture(appURL: appURL),
            "the real fd-anchored source fixture must be admissible before mutation")
        let inodeBefore = try XCTUnwrap(Self.inode(of: resourceURL))
        let mutation = OneShotMutation {
            Self.rewriteSameLengthAndRestoreMTime(resourceURL, replacementByte: 0x5A)
        }
        let trace = Trace()
        let fields = RawSecuritySigningFields(
            groups: ["group.com.example.shared"],
            codeIdentifier: "com.example.product", uniqueCode: Data([1]),
            mainExecutableURL: executableURL)
        let boundedFields = try XCTUnwrap(BoundedSecuritySigningFields.validating(fields))
        XCTAssertEqual(boundedFields.mainExecutableCanonicalPath,
                       baselineSource.mainExecutableCanonicalPath)
        let reader = SecurityEntitlementReader(
            sessionFactory: ScriptedFactory(trace: trace, sessions: [
                ScriptedSession(name: "s1", trace: trace, fields: fields),
                ScriptedSession(name: "s2", trace: trace, fields: fields,
                                afterSecondValidity: { mutation.run() })
            ]),
            sourceAttestor: SystemSecurityCodeSourceAttestor())

        XCTAssertNil(reader.attestation(for: appURL),
                     "the final source capture must cover every regular file in Contents")
        XCTAssertTrue(mutation.didRun)
        XCTAssertEqual(trace.snapshot, [
            "open.s1", "s1.strict", "s1.copy", "s1.strict",
            "open.s2", "s2.strict", "s2.copy", "s2.strict"
        ])
        XCTAssertEqual(Self.inode(of: resourceURL), inodeBefore,
                       "the deterministic rewrite must retain the original inode")
        #endif
    }

    func testSecurityEntitlementReaderRejectsSecurityMainExecutableOutsideSealedPath() {
        let trace = Trace()
        let outside = RawSecuritySigningFields(
            groups: [], codeIdentifier: "com.example.product", uniqueCode: Data([1]),
            mainExecutableURL: URL(fileURLWithPath: "/tmp/outside"))
        let seal = sourceSeal()
        let reader = SecurityEntitlementReader(
            sessionFactory: ScriptedFactory(trace: trace, sessions: [
                ScriptedSession(name: "s1", trace: trace, fields: outside),
                ScriptedSession(name: "s2", trace: trace, fields: outside)
            ]),
            sourceAttestor: SequenceSourceAttestor(
                trace: trace, seals: [seal, seal, seal, seal]))

        XCTAssertNil(reader.attestation(
            for: URL(fileURLWithPath: "/Applications/Example.app")))
    }

    func testSigningFieldsRequireParsedBoundedIdentifier() {
        XCTAssertNotNil(BoundedSecuritySigningFields.validating(raw()))
        XCTAssertNil(BoundedSecuritySigningFields.validating(
            raw(identifier: "com." + String(repeating: "a", count: 252))))
        XCTAssertNil(BoundedSecuritySigningFields.validating(raw(identifier: "invalid")))
    }

    func testSigningFieldsRequireAbsoluteFileMainExecutableURL() {
        let remote = RawSecuritySigningFields(
            groups: [], codeIdentifier: "com.example.product", uniqueCode: Data([1]),
            mainExecutableURL: URL(string: "https://example.com/Example")!)
        XCTAssertNil(BoundedSecuritySigningFields.validating(remote))
        let oversized = RawSecuritySigningFields(
            groups: [], codeIdentifier: "com.example.product", uniqueCode: Data([1]),
            mainExecutableURL: URL(fileURLWithPath: "/" + String(
                repeating: "a", count: BoundedSecuritySigningFields.maximumExecutablePathBytes)))
        XCTAssertNil(BoundedSecuritySigningFields.validating(oversized))
    }

    func testSigningFieldsRequireUniqueCodeBetweenOneAnd64Bytes() {
        XCTAssertNil(BoundedSecuritySigningFields.validating(raw(uniqueCode: Data())))
        XCTAssertNotNil(BoundedSecuritySigningFields.validating(
            raw(uniqueCode: Data(repeating: 1, count: 64))))
        XCTAssertNil(BoundedSecuritySigningFields.validating(
            raw(uniqueCode: Data(repeating: 1, count: 65))))
    }

    func testSigningFieldsRejectDuplicateOrInvalidGroupBeforeSorting() {
        XCTAssertNil(BoundedSecuritySigningFields.validating(
            raw(groups: ["group.com.example.shared", "group.com.example.shared"])))
        for invalid in ["", ".", "..", "group/escape", "group\\escape",
                        "group\0escape", "group\u{0001}escape",
                        String(repeating: "a", count: 256)] {
            XCTAssertNil(BoundedSecuritySigningFields.validating(raw(groups: [invalid])),
                         "unexpectedly admitted group: \(invalid.debugDescription)")
        }
    }

    func testSigningFieldsSortGroupsByRawUTF8AndEnforceAggregateBounds() throws {
        let fields = try XCTUnwrap(BoundedSecuritySigningFields.validating(
            raw(groups: ["group.z", "group.A", "group.a"])))
        XCTAssertEqual(fields.groups, ["group.A", "group.a", "group.z"])

        let tooMany = (0...SecurityEntitlementReader.maximumGroupCount).map {
            "group.com.example.\($0)"
        }
        XCTAssertNil(BoundedSecuritySigningFields.validating(raw(groups: tooMany)))
        XCTAssertNil(BoundedSecuritySigningFields.validating(raw(groups: [
            "group." + String(repeating: "a",
                              count: SecurityEntitlementReader.maximumGroupUTF8Bytes)
        ])))
    }

    func testSystemSigningParserBoundsCFValuesBeforeSwiftOwnership() throws {
        func dictionary(groups: NSArray, uniqueCode: NSData = Data([1]) as NSData)
            -> CFDictionary {
            let entitlements: NSDictionary = [
                "com.apple.security.application-groups": groups
            ]
            let dictionary: NSDictionary = [
                kSecCodeInfoIdentifier as String: "com.example.product" as NSString,
                kSecCodeInfoUnique as String: uniqueCode,
                kSecCodeInfoMainExecutable as String: executableURL as NSURL,
                kSecCodeInfoEntitlementsDict as String: entitlements
            ]
            return unsafeBitCast(dictionary, to: CFDictionary.self)
        }

        XCTAssertNotNil(SecuritySigningFieldsParser.parse(
            dictionary(groups: ["group.com.example.shared"] as NSArray)))
        XCTAssertNil(SecuritySigningFieldsParser.parse(dictionary(
            groups: [String(repeating: "a", count: 256)] as NSArray)))
        XCTAssertNil(SecuritySigningFieldsParser.parse(dictionary(
            groups: [] as NSArray,
            uniqueCode: Data(repeating: 1, count: 65) as NSData)))
    }

    private static func inode(of url: URL) -> UInt64? {
        #if canImport(Darwin)
        var value = stat()
        return lstat(url.path, &value) == 0 ? UInt64(value.st_ino) : nil
        #else
        return nil
        #endif
    }

    private static func rewriteSameLengthAndRestoreMTime(_ url: URL, replacementByte: UInt8) {
        #if canImport(Darwin)
        var before = stat()
        guard lstat(url.path, &before) == 0 else { return }
        let descriptor = open(url.path, O_WRONLY | O_CLOEXEC)
        guard descriptor >= 0 else { return }
        var byte = replacementByte
        _ = withUnsafeBytes(of: &byte) { bytes in
            pwrite(descriptor, bytes.baseAddress, bytes.count, 0)
        }
        close(descriptor)
        var times = [before.st_atimespec, before.st_mtimespec]
        times.withUnsafeMutableBufferPointer { buffer in
            _ = utimensat(AT_FDCWD, url.path, buffer.baseAddress, 0)
        }
        #endif
    }
}
