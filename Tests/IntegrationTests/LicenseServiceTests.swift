import XCTest
import CryptoKit
@testable import Infrastructure

final class LicenseServiceTests: XCTestCase {
    private var tmpDir: URL!
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUpWithError() throws {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("xico-license-service-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        suiteName = "xico-license-tests-\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: tmpDir)
    }

    func testInstallAcceptsTrustedSignedLicense() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let key = Curve25519.Signing.PrivateKey()
        let service = makeService(key: key)
        let data = try envelopeData(
            licenseID: "license-001",
            customerName: "Acme Studio",
            expiresAt: now.addingTimeInterval(30 * 86_400),
            key: key
        )

        let status = try service.installLicense(fromEnvelopeData: data, now: now)

        XCTAssertEqual(status.licenseID, "license-001")
        XCTAssertEqual(status.state, .licensed(customerName: "Acme Studio", expiresAt: now.addingTimeInterval(30 * 86_400)))
        XCTAssertTrue(FileManager.default.fileExists(atPath: status.licenseURL.path))
    }

    func testInstallRejectsTamperedSignature() throws {
        let trusted = Curve25519.Signing.PrivateKey()
        let attacker = Curve25519.Signing.PrivateKey()
        let service = makeService(key: trusted)
        let data = try envelopeData(licenseID: "license-evil", customerName: "Mallory", key: attacker)

        do {
            _ = try service.installLicense(fromEnvelopeData: data)
            XCTFail("被其他私钥签名的许可证必须被拒绝")
        } catch LicenseError.invalidSignature {
            XCTAssertFalse(FileManager.default.fileExists(atPath: tmpDir.appendingPathComponent("license.xico-license").path))
        }
    }

    func testInstallRejectsExpiredLicense() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let key = Curve25519.Signing.PrivateKey()
        let service = makeService(key: key)
        let data = try envelopeData(
            licenseID: "license-old",
            customerName: "Expired Co",
            expiresAt: now.addingTimeInterval(-86_400),
            key: key
        )

        do {
            _ = try service.installLicense(fromEnvelopeData: data, now: now)
            XCTFail("过期许可证必须被拒绝")
        } catch LicenseError.expired {
            XCTAssertFalse(FileManager.default.fileExists(atPath: tmpDir.appendingPathComponent("license.xico-license").path))
        }
    }

    func testTrialStartsOnceAndExpiresAfterWindow() throws {
        let service = LicenseService(
            trustedPublicKeys: [:],
            licenseDirectory: tmpDir,
            defaults: defaults,
            trialDays: 14
        )
        let start = Date(timeIntervalSince1970: 1_700_000_000)

        XCTAssertEqual(service.status(now: start).state, .trial(daysRemaining: 14))
        XCTAssertEqual(service.status(now: start.addingTimeInterval(13 * 86_400)).state, .trial(daysRemaining: 1))
        XCTAssertEqual(service.status(now: start.addingTimeInterval(14 * 86_400)).state, .expired)
    }

    private func makeService(key: Curve25519.Signing.PrivateKey) -> LicenseService {
        LicenseService(
            trustedPublicKeys: ["release": key.publicKey.rawRepresentation],
            licenseDirectory: tmpDir,
            defaults: defaults
        )
    }

    private func envelopeData(
        licenseID: String,
        customerName: String,
        expiresAt: Date? = nil,
        key: Curve25519.Signing.PrivateKey
    ) throws -> Data {
        let payload = LicensePayload(
            licenseID: licenseID,
            productID: "com.xico.app",
            customerName: customerName,
            issuedAt: Date(timeIntervalSince1970: 1_700_000_000),
            expiresAt: expiresAt,
            maxMajorVersion: 1
        )
        let payloadData = try JSONEncoder().encode(payload)
        let signature = try key.signature(for: payloadData)
        let envelope = LicenseEnvelope(
            keyID: "release",
            payloadBase64: payloadData.base64EncodedString(),
            signatureBase64: signature.base64EncodedString()
        )
        return try JSONEncoder().encode(envelope)
    }
}
