import XCTest
import CryptoKit
@testable import Infrastructure

/// 席位释放回归（2026-07 审计 P2：设备绑定绕过）。
///
/// 守护红线：在本机「释放授权」(deactivate) 后，仅删许可文件不足以真正释放席位——
/// 用户可能事先保存了旧信封，停用后**手动重新导入**同一份签名文件把席位「吹回来」。
/// 因此 `recordReleased` 落一个 (licenseID, deviceId) 的本地标记，`installLicense(enforceReleased:)`
/// 据此拒绝手动重导入，直到一次成功的**在线激活**（默认 `installLicense`，代表服务端已重新盖章席位）
/// 清除标记。整条链路绝不误伤正常激活/导入。
final class SeatReleaseTests: XCTestCase {
    private var tmpDir: URL!
    private var defaults: UserDefaults!
    private var suiteName: String!
    private var anchor: InMemoryAnchorStore!

    override func setUpWithError() throws {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("xico-seat-release-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        suiteName = "xico-seat-release-\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        anchor = InMemoryAnchorStore()   // 绝不触碰真实钥匙串
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: tmpDir)
    }

    /// 核心：释放本机席位后，手动重新导入同一份签名合法的信封 → 被拒。
    func testReleasedDeviceRejectsReimportedEnvelope() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let key = Curve25519.Signing.PrivateKey()
        let service = makeService(key: key)
        let data = try envelopeData(licenseID: "seat-1", key: key)

        // 首次安装正常（在线激活路径，默认 enforceReleased:false）
        let status = try service.installLicense(fromEnvelopeData: data, now: now)
        XCTAssertTrue(status.state.allowsCommercialUse)

        // 释放本机席位（PricingView.deactivate 成功后调用）
        XCTAssertFalse(service.isReleased(licenseID: "seat-1", deviceId: DeviceIdentity.current()))
        service.recordReleased(licenseID: "seat-1", deviceId: DeviceIdentity.current())
        XCTAssertTrue(service.isReleased(licenseID: "seat-1", deviceId: DeviceIdentity.current()))
        service.clearLicense()

        // 手动重导入同一份签名合法的信封 → 拒绝，无法复活席位
        do {
            _ = try service.installLicense(fromEnvelopeData: data, now: now, enforceReleased: true)
            XCTFail("已释放本机席位的手动重导入必须被拒")
        } catch LicenseError.invalidPayload {
            // 预期：命中本地释放标记
        }
    }

    /// 一次成功的在线激活（默认 installLicense，代表服务端已重新盖章席位）清除标记 → 后续手动导入恢复正常。
    func testOnlineActivationClearsReleaseMarker() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let key = Curve25519.Signing.PrivateKey()
        let service = makeService(key: key)
        let data = try envelopeData(licenseID: "seat-2", key: key)

        service.recordReleased(licenseID: "seat-2", deviceId: DeviceIdentity.current())
        XCTAssertTrue(service.isReleased(licenseID: "seat-2", deviceId: DeviceIdentity.current()))

        // 在线激活路径（默认 enforceReleased:false）：既不被拒，又清除释放标记
        let status = try service.installLicense(fromEnvelopeData: data, now: now)
        XCTAssertTrue(status.state.allowsCommercialUse, "在线激活必须成功放行，绝不误伤付费用户重新激活")
        XCTAssertFalse(service.isReleased(licenseID: "seat-2", deviceId: DeviceIdentity.current()),
                       "成功在线激活应清除释放标记")

        // 此后手动重导入也恢复正常
        let reimport = try service.installLicense(fromEnvelopeData: data, now: now, enforceReleased: true)
        XCTAssertTrue(reimport.state.allowsCommercialUse)
    }

    /// 释放标记按 (licenseID, deviceId) 精确命中：不误伤别的证 / 别的设备。
    func testReleaseMarkerIsScopedToLicenseAndDevice() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let key = Curve25519.Signing.PrivateKey()
        let service = makeService(key: key)
        let data = try envelopeData(licenseID: "seat-3", key: key)

        // 释放的是「别的证」和「别的设备」——都不应拦住 seat-3 在本机的手动导入
        service.recordReleased(licenseID: "other-license", deviceId: DeviceIdentity.current())
        service.recordReleased(licenseID: "seat-3", deviceId: "some-other-machine-uuid")
        XCTAssertFalse(service.isReleased(licenseID: "seat-3", deviceId: DeviceIdentity.current()))

        let status = try service.installLicense(fromEnvelopeData: data, now: now, enforceReleased: true)
        XCTAssertTrue(status.state.allowsCommercialUse)
    }

    /// 释放标记双副本 + 失败保守：抹掉 UserDefaults 副本后，钥匙串锚点副本仍令重导入被拒。
    func testReleaseMarkerSurvivesDefaultsWipe() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let key = Curve25519.Signing.PrivateKey()
        let service = makeService(key: key)
        let data = try envelopeData(licenseID: "seat-4", key: key)

        service.recordReleased(licenseID: "seat-4", deviceId: DeviceIdentity.current())
        // 模拟 `defaults delete`：只抹掉偏好副本，钥匙串锚点副本仍在
        defaults.removePersistentDomain(forName: suiteName)
        XCTAssertTrue(service.isReleased(licenseID: "seat-4", deviceId: DeviceIdentity.current()),
                      "抹掉 defaults 副本不能漂白释放标记（钥匙串副本存活）")

        do {
            _ = try service.installLicense(fromEnvelopeData: data, now: now, enforceReleased: true)
            XCTFail("释放标记仍在时手动重导入必须被拒")
        } catch LicenseError.invalidPayload {
            // 预期
        }
    }

    // MARK: Fixtures（沿用 LicenseBindingTests 风格）

    private func makeService(key: Curve25519.Signing.PrivateKey) -> LicenseService {
        LicenseService(
            trustedPublicKeys: ["release": key.publicKey.rawRepresentation],
            licenseDirectory: tmpDir,
            defaults: defaults,
            anchor: anchor
        )
    }

    private func envelopeData(licenseID: String, key: Curve25519.Signing.PrivateKey) throws -> Data {
        let payload = LicensePayload(
            licenseID: licenseID,
            productID: "com.xico.app",
            customerName: "Seat Co",
            issuedAt: Date(timeIntervalSince1970: 1_700_000_000),
            expiresAt: nil,
            maxMajorVersion: 1,
            deviceId: DeviceIdentity.current()   // 绑定本机，通过设备绑定校验
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
