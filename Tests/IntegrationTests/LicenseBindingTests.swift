import XCTest
import CryptoKit
@testable import Infrastructure

/// 设备绑定 + 本地吊销名单回归（2026-07 审计两个 P1）。
///
/// 守护两条红线：
///  1. 签名许可拷到别的机器即失效——payload 带 `deviceId` 且与本机不符时拒绝；
///     但历史签发（`deviceId == nil`）的许可必须照常放行，绝不误伤存量付费用户。
///  2. 服务端一次「吊销/退款」结论经 `recordRevoked` 落地后永久生效——即便签名合法、
///     即便重新导入同一份信封，也无法复活。
final class LicenseBindingTests: XCTestCase {
    private var tmpDir: URL!
    private var defaults: UserDefaults!
    private var suiteName: String!
    private var anchor: InMemoryAnchorStore!

    override func setUpWithError() throws {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("xico-license-binding-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        suiteName = "xico-license-binding-\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        anchor = InMemoryAnchorStore()   // 绝不触碰真实钥匙串
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: tmpDir)
    }

    /// (a) deviceId 与本机不符的许可必须被拒（拷贝一份文件到别的机器不能解锁）。
    func testMismatchedDeviceIdIsRejected() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let key = Curve25519.Signing.PrivateKey()
        let service = makeService(key: key)
        let data = try envelopeData(
            licenseID: "license-bound",
            customerName: "Bound Co",
            deviceId: "some-other-machine-uuid",   // 冒充别的机器
            key: key
        )
        do {
            _ = try service.installLicense(fromEnvelopeData: data, now: now)
            XCTFail("设备不匹配的许可必须被拒")
        } catch LicenseError.invalidPayload {
            // 预期：设备绑定失配
        }
    }

    /// (b) deviceId 与本机一致的许可正常安装解锁。
    func testMatchingDeviceIdValidates() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let key = Curve25519.Signing.PrivateKey()
        let service = makeService(key: key)
        let data = try envelopeData(
            licenseID: "license-bound-ok",
            customerName: "Bound Co",
            deviceId: DeviceIdentity.current(),     // 本机
            key: key
        )
        let status = try service.installLicense(fromEnvelopeData: data, now: now)
        XCTAssertTrue(status.state.allowsCommercialUse, "绑定本机的许可应解锁商业功能")
        XCTAssertEqual(status.licenseID, "license-bound-ok")
    }

    /// (c) 历史签发（deviceId == nil）的许可仍然有效——向后兼容，不误伤存量用户。
    func testLegacyNilDeviceIdStillValidates() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let key = Curve25519.Signing.PrivateKey()
        let service = makeService(key: key)
        let data = try envelopeData(
            licenseID: "license-legacy",
            customerName: "Legacy Co",
            deviceId: nil,                          // 老信封无此字段
            key: key
        )
        let status = try service.installLicense(fromEnvelopeData: data, now: now)
        XCTAssertTrue(status.state.allowsCommercialUse, "无 deviceId 的历史许可必须照常解锁")
        XCTAssertEqual(status.licenseID, "license-legacy")
    }

    /// (d) 被本地吊销名单命中的许可，即使签名合法、即使重新导入，也被拒。
    func testRecordedRevokedLicenseIsRejectedEvenWithValidSignature() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let key = Curve25519.Signing.PrivateKey()
        let service = makeService(key: key)
        let data = try envelopeData(
            licenseID: "refunded-42",
            customerName: "Refund Co",
            deviceId: DeviceIdentity.current(),
            key: key
        )
        // 先能装（尚未吊销）
        _ = try service.installLicense(fromEnvelopeData: data, now: now)
        // 服务端在线复验判定退款 → 落地本地吊销名单
        XCTAssertFalse(service.isRevoked("refunded-42"))
        service.recordRevoked("refunded-42")
        XCTAssertTrue(service.isRevoked("refunded-42"))
        // 重新导入同一份签名合法的信封 → 仍被拒，无法复活
        do {
            _ = try service.installLicense(fromEnvelopeData: data, now: now)
            XCTFail("已吊销的许可即使签名合法也必须拒绝")
        } catch LicenseError.invalidPayload {
            // 预期：命中本地吊销名单
        }
    }

    // MARK: Fixtures（沿用 LicenseServiceTests 风格）

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
        deviceId: String?,
        key: Curve25519.Signing.PrivateKey
    ) throws -> Data {
        let payload = LicensePayload(
            licenseID: licenseID,
            productID: "com.xico.app",
            customerName: customerName,
            issuedAt: Date(timeIntervalSince1970: 1_700_000_000),
            expiresAt: nil,
            maxMajorVersion: 1,
            deviceId: deviceId
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
