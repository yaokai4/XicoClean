import XCTest
import CryptoKit
@testable import Infrastructure

final class LicenseServiceTests: XCTestCase {
    private var tmpDir: URL!
    private var defaults: UserDefaults!
    private var suiteName: String!
    private var anchor: InMemoryAnchorStore!

    override func setUpWithError() throws {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("xico-license-service-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        suiteName = "xico-license-tests-\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        anchor = InMemoryAnchorStore()   // 绝不触碰真实钥匙串
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
        let service = trialService()
        let start = Date(timeIntervalSince1970: 1_700_000_000)

        XCTAssertEqual(service.status(now: start).state, .trial(daysRemaining: 14))
        XCTAssertEqual(service.status(now: start.addingTimeInterval(13 * 86_400)).state, .trial(daysRemaining: 1))
        XCTAssertEqual(service.status(now: start.addingTimeInterval(14 * 86_400)).state, .expired)
    }

    // MARK: 防篡改（2026-07 审计：试用可删偏好重置、回拨时钟续命）

    /// 时钟回拨不能让已用掉的试用天数"倒流"
    func testClockRollbackCannotReviveTrial() throws {
        let service = trialService()
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        _ = service.status(now: start)                                    // 记 lastSeen=start
        XCTAssertEqual(service.status(now: start.addingTimeInterval(10 * 86_400)).state,
                       .trial(daysRemaining: 4))                          // lastSeen=+10d
        // 把系统时钟回拨到第 2 天——有效时间仍取历史最晚（+10d），剩余天数不应变多
        XCTAssertEqual(service.status(now: start.addingTimeInterval(2 * 86_400)).state,
                       .trial(daysRemaining: 4))
    }

    /// 时钟回拨不能让已过期的许可证复活
    func testClockRollbackCannotReviveExpiredLicense() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let key = Curve25519.Signing.PrivateKey()
        let service = makeService(key: key)
        let data = try envelopeData(licenseID: "lic", customerName: "Co",
                                    expiresAt: now.addingTimeInterval(30 * 86_400), key: key)
        _ = try service.installLicense(fromEnvelopeData: data, now: now)
        // 到第 40 天：已过期，记 lastSeen=+40d
        if case .licensed = service.status(now: now.addingTimeInterval(40 * 86_400)).state {
            XCTFail("第 40 天应已过期")
        }
        // 回拨到第 20 天：有效时间仍是 +40d，不能复活
        if case .licensed = service.status(now: now.addingTimeInterval(20 * 86_400)).state {
            XCTFail("回拨时钟不应让过期许可证复活")
        }
    }

    /// 删除 UserDefaults 里的试用起点，钥匙串锚点仍在 → 试用不重置（取两处最早值）
    func testDeletingDefaultsDoesNotResetTrial() throws {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let service1 = trialService()
        XCTAssertEqual(service1.status(now: start).state, .trial(daysRemaining: 14))
        // 用户执行 `defaults delete`：清空该 suite
        defaults.removePersistentDomain(forName: suiteName)
        // 新实例共享同一钥匙串锚点（anchor 仍持有 start）
        let service2 = trialService()
        XCTAssertEqual(service2.status(now: start.addingTimeInterval(10 * 86_400)).state,
                       .trial(daysRemaining: 4), "删偏好不应重置试用——锚点仍记得起点")
    }

    /// 吊销名单命中的许可证即使签名合法也被拒
    func testRevokedLicenseIsRejected() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let key = Curve25519.Signing.PrivateKey()
        let service = LicenseService(
            trustedPublicKeys: ["release": key.publicKey.rawRepresentation],
            licenseDirectory: tmpDir, defaults: defaults, anchor: anchor,
            revokedLicenseIDs: ["refunded-007"])
        let data = try envelopeData(licenseID: "refunded-007", customerName: "Refunded", key: key)
        do {
            _ = try service.installLicense(fromEnvelopeData: data, now: now)
            XCTFail("被吊销的许可证必须拒绝")
        } catch LicenseError.invalidPayload {
            // 预期
        }
    }

    private func trialService() -> LicenseService {
        LicenseService(trustedPublicKeys: [:], licenseDirectory: tmpDir,
                       defaults: defaults, trialDays: 14, anchor: anchor)
    }

    private func makeService(key: Curve25519.Signing.PrivateKey) -> LicenseService {
        LicenseService(
            trustedPublicKeys: ["release": key.publicKey.rawRepresentation],
            licenseDirectory: tmpDir,
            defaults: defaults,
            anchor: anchor
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
