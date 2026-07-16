import XCTest
import CryptoKit
import Domain
@testable import Infrastructure

final class DefinitionsUpdateServiceTests: XCTestCase {
    private var tmpDir: URL!

    override func setUpWithError() throws {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("xico-definitions-update-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmpDir)
    }

    func testRefreshAcceptsSignedNewerLibraryAndCachesIt() async throws {
        let key = Curve25519.Signing.PrivateKey()
        let old = library(version: 1)
        let remote = library(version: 2)
        let envelopeURL = try writeEnvelope(library: remote, key: key, keyID: "release")
        let service = DefinitionsUpdateService(
            bundled: old,
            endpoint: envelopeURL,
            trustedPublicKeys: ["release": key.publicKey.rawRepresentation],
            cacheDirectory: tmpDir
        )

        let refreshed = try await service.refresh()

        XCTAssertEqual(refreshed.version, 2)
        XCTAssertEqual(service.cachedLibrary()?.version, 2)
        XCTAssertEqual(service.currentLibrary().version, 2)
    }

    func testRefreshRejectsTamperedSignature() async throws {
        let trusted = Curve25519.Signing.PrivateKey()
        let attacker = Curve25519.Signing.PrivateKey()
        let envelopeURL = try writeEnvelope(library: library(version: 2), key: attacker, keyID: "release")
        let service = DefinitionsUpdateService(
            bundled: library(version: 1),
            endpoint: envelopeURL,
            trustedPublicKeys: ["release": trusted.publicKey.rawRepresentation],
            cacheDirectory: tmpDir
        )

        do {
            _ = try await service.refresh()
            XCTFail("篡改签名必须被拒绝")
        } catch DefinitionsUpdateError.invalidSignature {
            XCTAssertNil(service.cachedLibrary())
        }
    }

    func testRefreshRejectsStaleLibrary() async throws {
        let key = Curve25519.Signing.PrivateKey()
        let envelopeURL = try writeEnvelope(library: library(version: 1), key: key, keyID: "release")
        let service = DefinitionsUpdateService(
            bundled: library(version: 2),
            endpoint: envelopeURL,
            trustedPublicKeys: ["release": key.publicKey.rawRepresentation],
            cacheDirectory: tmpDir
        )

        do {
            _ = try await service.refresh()
            XCTFail("旧版本规则库不能覆盖当前规则库")
        } catch DefinitionsUpdateError.staleVersion(let remote, let current) {
            XCTAssertEqual(remote, 1)
            XCTAssertEqual(current, 2)
        }
    }

    func testValidationRejectsUnsafeRuleDSLBounds() throws {
        let definition = CleanupDefinition(
            id: "bad-constraints",
            category: "system-junk",
            title: "Bad",
            description: "test",
            paths: ["~/Library/Caches/Test"],
            constraints: CleanupConstraints(
                minimumAgeDays: -1,
                minimumSizeBytes: 100,
                maximumSizeBytes: 10,
                recommendationConfidence: 1.5
            )
        )
        let service = DefinitionsUpdateService(
            bundled: library(version: 1), endpoint: nil,
            trustedPublicKeys: [:], cacheDirectory: tmpDir
        )
        XCTAssertThrowsError(try service.validate(
            DefinitionsLibrary(version: 2, definitions: [definition])))
    }

    func testValidationRejectsExpiredAndUnknownKillSwitchRules() throws {
        let base = library(version: 2)
        let service = DefinitionsUpdateService(
            bundled: library(version: 1), endpoint: nil,
            trustedPublicKeys: [:], cacheDirectory: tmpDir
        )
        XCTAssertThrowsError(try service.validate(DefinitionsLibrary(
            version: 2,
            definitions: base.definitions,
            issuedAt: Date().addingTimeInterval(-10 * 86_400),
            expiresAt: Date().addingTimeInterval(-1)
        )))
        XCTAssertThrowsError(try service.validate(DefinitionsLibrary(
            version: 3,
            definitions: base.definitions,
            disabledDefinitionIDs: ["not-present"]
        )))
    }

    func testValidationRejectsEmptyThreatSignature() throws {
        let base = library(version: 2)
        let service = DefinitionsUpdateService(
            bundled: library(version: 1), endpoint: nil,
            trustedPublicKeys: [:], cacheDirectory: tmpDir
        )

        XCTAssertThrowsError(try service.validate(DefinitionsLibrary(
            version: 2,
            definitions: base.definitions,
            threatSignatures: [""]
        )))
    }

    private func library(version: Int) -> DefinitionsLibrary {
        DefinitionsLibrary(version: version, definitions: [
            CleanupDefinition(
                id: "cache-\(version)",
                category: "system-junk",
                title: "Cache \(version)",
                description: "test",
                paths: ["~/Library/Caches/Test\(version)"],
                safety: .safe
            )
        ])
    }

    private func writeEnvelope(
        library: DefinitionsLibrary,
        key: Curve25519.Signing.PrivateKey,
        keyID: String
    ) throws -> URL {
        let payload = try JSONEncoder().encode(library)
        let signature = try key.signature(for: payload)
        let envelope = DefinitionsUpdateEnvelope(
            keyID: keyID,
            payloadBase64: payload.base64EncodedString(),
            signatureBase64: signature.base64EncodedString()
        )
        let data = try JSONEncoder().encode(envelope)
        let url = tmpDir.appendingPathComponent("definitions-\(library.version).signed.json")
        try data.write(to: url)
        return url
    }
}
