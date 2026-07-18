import CryptoKit
import Foundation
import XCTest
@testable import Domain
@testable import Infrastructure
#if canImport(Darwin)
import Darwin
#endif

final class AppBundlePathAttestorTests: XCTestCase {
    private var root: URL!
    private var appURL: URL!
    private var infoURL: URL!
    private var executableURL: URL!
    private var codeResourcesURL: URL!

    override func setUpWithError() throws {
        let unresolved = FileManager.default.temporaryDirectory
            .appendingPathComponent("xico-app-attestor-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: unresolved, withIntermediateDirectories: true)
        root = unresolved.path.hasPrefix("/var/")
            ? URL(fileURLWithPath: "/private" + unresolved.path, isDirectory: true)
            : unresolved.resolvingSymlinksInPath()
        appURL = root.appendingPathComponent("Applications/Example.app", isDirectory: true)
        let contents = appURL.appendingPathComponent("Contents", isDirectory: true)
        let macOS = contents.appendingPathComponent("MacOS", isDirectory: true)
        let signature = contents.appendingPathComponent("_CodeSignature", isDirectory: true)
        let frameworks = contents.appendingPathComponent("Frameworks", isDirectory: true)
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: signature, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: frameworks, withIntermediateDirectories: true)

        infoURL = contents.appendingPathComponent("Info.plist")
        let info = try PropertyListSerialization.data(
            fromPropertyList: [
                "CFBundleIdentifier": "com.example.attestor",
                "CFBundleExecutable": "ExampleExecutable"
            ],
            format: .xml,
            options: 0)
        try info.write(to: infoURL)

        executableURL = macOS.appendingPathComponent("ExampleExecutable")
        try Data("0123456789abcdef".utf8).write(to: executableURL)
        codeResourcesURL = signature.appendingPathComponent("CodeResources")
        try Data("sealed-resources".utf8).write(to: codeResourcesURL)
        try Data("nested-code".utf8)
            .write(to: frameworks.appendingPathComponent("NestedBinary"))
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    func testAttestsFromFilesystemRootAndCapturesCompleteSourceSeal() throws {
        let attestor = FDAnchoredAppBundlePathAttestor(appURL: appURL)

        let appProof = try XCTUnwrap(attestor.attestApp())
        let expectedAppIdentity = try XCTUnwrap(LocalFileIdentitySampler().sample(appURL.path))
        XCTAssertEqual(appProof.appRootIdentity, expectedAppIdentity)
        XCTAssertEqual(appProof.canonicalPath, appURL.path)
        XCTAssertEqual(appProof.rootRelativeComponents.last, "Example.app")
        XCTAssertGreaterThan(appProof.componentIdentities.count, 3)
        XCTAssertNotEqual(appProof.chainFingerprint, .none)

        let info = try XCTUnwrap(attestor.readRegularFile(
            relativeComponents: ["Contents", "Info.plist"], maximumBytes: 1_048_576))
        XCTAssertEqual(info.data, try Data(contentsOf: infoURL))
        XCTAssertEqual(info.attestation.exactLength, info.data.count)
        XCTAssertEqual(info.attestation.identity.changeTimeNanoseconds,
                       LocalFileIdentitySampler().sample(infoURL.path)?.changeTimeNanoseconds)
        XCTAssertEqual(info.attestation.contentDigest,
                       EvidenceFingerprint(sha256: Array(SHA256.hash(data: info.data))))

        let program = try XCTUnwrap(attestor.programToken(
            absoluteURL: executableURL, maximumDigestBytes: 1_048_576))
        XCTAssertEqual(program.canonicalPath, executableURL.path)
        XCTAssertEqual(program.relativeComponentsInsideApp,
                       ["Contents", "MacOS", "ExampleExecutable"])
        XCTAssertEqual(program.directoryChain.first, expectedAppIdentity)
        XCTAssertEqual(program.boundedExactLength, 16)
        XCTAssertNotNil(program.boundedContentDigest)
        XCTAssertNotEqual(program.chainFingerprint, .none)

        let source = try XCTUnwrap(attestor.captureSourceSeal())
        XCTAssertEqual(source.appRoot, expectedAppIdentity)
        XCTAssertEqual(source.appChainFingerprint, appProof.chainFingerprint)
        XCTAssertEqual(source.infoPlist, info.attestation)
        XCTAssertEqual(source.mainExecutable, program)
        XCTAssertEqual(source.mainExecutableCanonicalPath, executableURL.path)
        XCTAssertEqual(source.codeResources.exactLength, 16)
        XCTAssertNotEqual(source.nestedRosterFingerprint, .none)
    }

    func testRejectsSymlinkedAppAncestorAndSymlinkedAppLeaf() throws {
        let realParent = root.appendingPathComponent("real-parent", isDirectory: true)
        let realApp = realParent.appendingPathComponent("Real.app", isDirectory: true)
        try FileManager.default.createDirectory(at: realApp, withIntermediateDirectories: true)

        let aliasParent = root.appendingPathComponent("alias-parent", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: aliasParent, withDestinationURL: realParent)
        XCTAssertNil(FDAnchoredAppBundlePathAttestor(
            appURL: aliasParent.appendingPathComponent("Real.app")).attestApp())

        let aliasApp = root.appendingPathComponent("Alias.app", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: aliasApp, withDestinationURL: realApp)
        XCTAssertNil(FDAnchoredAppBundlePathAttestor(appURL: aliasApp).attestApp())
    }

    func testRejectsSymlinkedRequiredFileAndProgramIntermediate() throws {
        let outsideInfo = root.appendingPathComponent("outside-info.plist")
        try Data("outside".utf8).write(to: outsideInfo)
        try FileManager.default.removeItem(at: infoURL)
        try FileManager.default.createSymbolicLink(at: infoURL, withDestinationURL: outsideInfo)
        let attestor = FDAnchoredAppBundlePathAttestor(appURL: appURL)
        XCTAssertNil(attestor.readRegularFile(
            relativeComponents: ["Contents", "Info.plist"], maximumBytes: 1_048_576))

        let macOS = appURL.appendingPathComponent("Contents/MacOS", isDirectory: true)
        let outsidePrograms = root.appendingPathComponent("outside-programs", isDirectory: true)
        try FileManager.default.createDirectory(at: outsidePrograms, withIntermediateDirectories: true)
        let outsideProgram = outsidePrograms.appendingPathComponent("ExampleExecutable")
        try Data("outside-program".utf8).write(to: outsideProgram)
        try FileManager.default.removeItem(at: macOS)
        try FileManager.default.createSymbolicLink(at: macOS, withDestinationURL: outsidePrograms)
        XCTAssertNil(attestor.programToken(
            absoluteURL: macOS.appendingPathComponent("ExampleExecutable"),
            maximumDigestBytes: 1_048_576))
    }

    func testBoundedReadRejectsOversizeAndInvalidRelativeComponents() throws {
        let attestor = FDAnchoredAppBundlePathAttestor(appURL: appURL)
        XCTAssertNil(attestor.readRegularFile(
            relativeComponents: ["Contents", "Info.plist"], maximumBytes: 8))
        XCTAssertNil(attestor.readRegularFile(
            relativeComponents: ["Contents", "..", "Info.plist"], maximumBytes: 1_048_576))
        XCTAssertNil(attestor.readRegularFile(
            relativeComponents: ["Contents/Info.plist"], maximumBytes: 1_048_576))
        XCTAssertNil(attestor.readRegularFile(
            relativeComponents: [String(repeating: "a", count: 256)], maximumBytes: 1_048_576))
    }

    func testBoundedReadRejectsEqualLengthRewriteWithRestoredMTime() throws {
        let infoURL = try XCTUnwrap(infoURL)
        let mutation = OneShotMutation {
            Self.rewriteSameLengthAndRestoreMTime(infoURL, replacementByte: 0x5A)
        }
        let hooks = AppBundleAttestationHooks { stage in
            if stage == .relativeLeafOpened("Contents/Info.plist") { mutation.run() }
        }
        let attestor = FDAnchoredAppBundlePathAttestor(appURL: appURL, hooks: hooks)

        XCTAssertNil(attestor.readRegularFile(
            relativeComponents: ["Contents", "Info.plist"], maximumBytes: 1_048_576))
        XCTAssertTrue(mutation.didRun)
    }

    func testBoundedReadRejectsShortEOFRelativeToOpenedSize() throws {
        let infoURL = try XCTUnwrap(infoURL)
        let mutation = OneShotMutation { Self.truncate(infoURL, to: 1) }
        let hooks = AppBundleAttestationHooks { stage in
            if stage == .relativeLeafOpened("Contents/Info.plist") { mutation.run() }
        }
        let attestor = FDAnchoredAppBundlePathAttestor(appURL: appURL, hooks: hooks)

        XCTAssertNil(attestor.readRegularFile(
            relativeComponents: ["Contents", "Info.plist"], maximumBytes: 1_048_576))
        XCTAssertTrue(mutation.didRun)
    }

    func testProgramTokenRejectsOutsidePathAndSameInodeRewrite() throws {
        let outside = root.appendingPathComponent("outside-program")
        try Data("outside".utf8).write(to: outside)
        XCTAssertNil(FDAnchoredAppBundlePathAttestor(appURL: appURL).programToken(
            absoluteURL: outside, maximumDigestBytes: 1_048_576))

        let executableURL = try XCTUnwrap(executableURL)
        let mutation = OneShotMutation {
            Self.rewriteSameLengthAndRestoreMTime(executableURL, replacementByte: 0x58)
        }
        let hooks = AppBundleAttestationHooks { stage in
            if stage == .programOpened("Contents/MacOS/ExampleExecutable") { mutation.run() }
        }
        XCTAssertNil(FDAnchoredAppBundlePathAttestor(appURL: appURL, hooks: hooks).programToken(
            absoluteURL: executableURL, maximumDigestBytes: 1_048_576))
        XCTAssertTrue(mutation.didRun)
    }

    func testAppAttestationRejectsParentEdgeReplacementAfterOpen() throws {
        let appURL = try XCTUnwrap(appURL)
        let mutation = OneShotMutation {
            let moved = appURL.deletingLastPathComponent()
                .appendingPathComponent("moved-Example.app", isDirectory: true)
            try? FileManager.default.moveItem(at: appURL, to: moved)
            try? FileManager.default.createDirectory(at: appURL,
                                                     withIntermediateDirectories: true)
        }
        let hooks = AppBundleAttestationHooks { stage in
            if stage == .appChainOpened { mutation.run() }
        }

        XCTAssertNil(FDAnchoredAppBundlePathAttestor(appURL: appURL, hooks: hooks).attestApp())
        XCTAssertTrue(mutation.didRun)
    }

    func testSourceSealRejectsNestedRosterChangeBetweenPasses() throws {
        let nested = appURL.appendingPathComponent("Contents/Frameworks/AddedAfterPass")
        let mutation = OneShotMutation { try? Data("new".utf8).write(to: nested) }
        let hooks = AppBundleAttestationHooks { stage in
            if stage == .sourcePassCompleted(1) { mutation.run() }
        }

        XCTAssertNil(FDAnchoredAppBundlePathAttestor(
            appURL: appURL, hooks: hooks).captureSourceSeal())
        XCTAssertTrue(mutation.didRun)
    }

    func testSourceSealRejectsDuplicateNestedObjectAndSpecialNode() throws {
        #if canImport(Darwin)
        let frameworks = appURL.appendingPathComponent("Contents/Frameworks", isDirectory: true)
        let first = frameworks.appendingPathComponent("first")
        let second = frameworks.appendingPathComponent("second")
        try Data("hard-linked".utf8).write(to: first)
        XCTAssertEqual(link(first.path, second.path), 0)
        XCTAssertNil(FDAnchoredAppBundlePathAttestor(appURL: appURL).captureSourceSeal())
        try FileManager.default.removeItem(at: first)
        try FileManager.default.removeItem(at: second)

        let pipe = frameworks.appendingPathComponent("pipe")
        XCTAssertEqual(mkfifo(pipe.path, 0o600), 0)
        XCTAssertNil(FDAnchoredAppBundlePathAttestor(appURL: appURL).captureSourceSeal())
        #endif
    }

    func testRejectsAppChainBeyondExplicitComponentBudget() throws {
        var deepParent = root.appendingPathComponent("deep", isDirectory: true)
        for index in 0..<130 {
            deepParent.appendPathComponent("d\(index)", isDirectory: true)
        }
        let deepApp = deepParent.appendingPathComponent("TooDeep.app", isDirectory: true)
        try FileManager.default.createDirectory(at: deepApp, withIntermediateDirectories: true)

        XCTAssertNil(FDAnchoredAppBundlePathAttestor(appURL: deepApp).attestApp())
    }

    func testRosterEnumerationStopsAtRemainingEntryBudgetPlusOne() throws {
        let frameworks = appURL.appendingPathComponent("Contents/Frameworks", isDirectory: true)
        for index in 0..<4_100 {
            let path = frameworks.appendingPathComponent("entry-\(index)").path
            guard FileManager.default.createFile(atPath: path, contents: Data()) else {
                throw CocoaError(.fileWriteUnknown)
            }
        }
        let observations = DirectoryEntryObservations()
        let hooks = AppBundleAttestationHooks { stage in
            if case .rosterDirectoryEntryObserved(let directory, let count) = stage {
                observations.record(directory: directory, count: count)
            }
        }

        XCTAssertNil(FDAnchoredAppBundlePathAttestor(
            appURL: appURL, hooks: hooks).captureSourceSeal())
        XCTAssertEqual(observations.maximum(for: "Contents/Frameworks"), 4_096,
                       "retain no more than the remaining 4,095 names; observe only the failing +1")
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

    private final class DirectoryEntryObservations: @unchecked Sendable {
        private let lock = NSLock()
        private var maxima: [String: Int] = [:]

        func record(directory: String, count: Int) {
            lock.withLock { maxima[directory] = max(maxima[directory] ?? 0, count) }
        }

        func maximum(for directory: String) -> Int {
            lock.withLock { maxima[directory] ?? 0 }
        }
    }

    private static func truncate(_ url: URL, to length: off_t) {
        #if canImport(Darwin)
        _ = Darwin.truncate(url.path, length)
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
