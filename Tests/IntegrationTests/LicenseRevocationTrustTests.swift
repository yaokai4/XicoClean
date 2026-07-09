import XCTest
import CryptoKit
@testable import Infrastructure

/// 在线复验的「信任模型」回归（2026-07 二轮审计 P1）。
///
/// 守护三条契约：
///  (a) **未签名**的 `revoked` 结论绝不 brick 正版——只当作暂态(`.inconclusive`)，本地许可原样保留；
///  (b) 一次**验签通过**的 `active` 复验，清除历史 flag/超期降级，令 `status()` 自愈回到 `.licensed`；
///  (c) 一份**验签通过**的 `revoked` 结论被采信(`.revoked`)，上层据此记名吊销后永久生效。
final class LicenseRevocationTrustTests: XCTestCase {
    private var tmpDir: URL!
    private var defaults: UserDefaults!
    private var suiteName: String!
    private var anchor: InMemoryAnchorStore!
    private var signingKey: Curve25519.Signing.PrivateKey!
    private var trustedKeys: [String: Data]!

    private let deviceId = "test-device-uuid"

    override func setUpWithError() throws {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("xico-license-revtrust-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        suiteName = "xico-license-revtrust-\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        anchor = InMemoryAnchorStore()   // 绝不触碰真实钥匙串
        signingKey = Curve25519.Signing.PrivateKey()
        trustedKeys = ["release": signingKey.publicKey.rawRepresentation]
        MockURLProtocol.responder = nil
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: tmpDir)
        MockURLProtocol.responder = nil
    }

    // MARK: (a) 未签名 revoked 绝不 brick

    func testUnsignedRevokedVerdictDoesNotBrickValidLicense() async throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let service = makeService()
        // 装一份合法签名许可（未绑定设备，永久有效）。
        let data = try envelopeData(licenseID: "lic-unsigned-rev", customerName: "Valid Co",
                                    expiresAt: nil, deviceId: nil)
        XCTAssertTrue(try service.installLicense(fromEnvelopeData: data, now: now).state.allowsCommercialUse)

        // 服务器（或 MITM）回一句未签名的 "revoked"。
        MockURLProtocol.responder = { _ in (200, Self.jsonData(["ok": true, "status": "revoked"])) }
        let verdict = await makeClient().validate(licenseId: "lic-unsigned-rev", deviceId: deviceId)

        XCTAssertEqual(verdict, .inconclusive, "未签名的 revoked 必须被视为暂态，绝不触发吊销")
        XCTAssertFalse(service.isRevoked("lic-unsigned-rev"))
        XCTAssertTrue(service.status(now: now).state.allowsCommercialUse, "正版许可不应因未签名的 revoked 被 brick")
    }

    // MARK: (b) 验签通过的 active 自愈超期降级

    func testSignedActiveClearsLapseAndRestoresLicensed() async throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let service = makeService()
        let data = try envelopeData(licenseID: "lic-heal", customerName: "Heal Co",
                                    expiresAt: nil, deviceId: nil)
        _ = try service.installLicense(fromEnvelopeData: data, now: now)

        // 种入一枚「40 天前」的 flag（共享 defaults+anchor 命名空间），令许可超出 30 天宽限期而降级为受限。
        let flaggedAt = now.addingTimeInterval(-40 * 86_400)
        defaults.set(flaggedAt, forKey: LicenseService.flaggedKey("lic-heal"))
        anchor.set(flaggedAt, forKey: LicenseService.flaggedKey("lic-heal"))
        XCTAssertTrue(service.isReverificationLapsed(licenseID: "lic-heal", now: now))
        XCTAssertFalse(service.status(now: now).state.allowsCommercialUse, "超期未复验应降级为受限")

        // 一次验签通过的 active 复验 → 清除 flag → 自愈。
        MockURLProtocol.responder = { [self] _ in
            (200, signedResponse(status: "active", licenseId: "lic-heal", deviceId: deviceId))
        }
        let verdict = await makeClient().validate(licenseId: "lic-heal", deviceId: deviceId)

        XCTAssertEqual(verdict, .valid)
        XCTAssertFalse(service.isReverificationLapsed(licenseID: "lic-heal", now: now), "签名 active 应清除超期降级")
        XCTAssertTrue(service.status(now: now).state.allowsCommercialUse, "自愈后应恢复为已授权")
    }

    // MARK: (c) 验签通过的 revoked 被采信

    func testSignedRevokedVerdictIsHonored() async throws {
        MockURLProtocol.responder = { [self] _ in
            (200, signedResponse(status: "revoked", licenseId: "lic-signed-rev", deviceId: deviceId))
        }
        let verdict = await makeClient().validate(licenseId: "lic-signed-rev", deviceId: deviceId)
        XCTAssertEqual(verdict, .revoked, "验签通过的 revoked 必须被采信")

        // 上层据此记名吊销后永久生效。
        let service = makeService()
        service.recordRevoked("lic-signed-rev")
        XCTAssertTrue(service.isRevoked("lic-signed-rev"))
    }

    /// 篡改签名（用攻击者私钥签）不应被采信——退化为暂态，不 brick。
    func testRevokedWithWrongKeySignatureIsInconclusive() async throws {
        let attacker = Curve25519.Signing.PrivateKey()
        MockURLProtocol.responder = { [self] _ in
            (200, signedResponse(status: "revoked", licenseId: "lic-x", deviceId: deviceId, signWith: attacker))
        }
        let verdict = await makeClient().validate(licenseId: "lic-x", deviceId: deviceId)
        XCTAssertEqual(verdict, .inconclusive, "非受信私钥签名的 revoked 不应被采信")
    }

    // MARK: Fixtures

    private func makeService() -> LicenseService {
        LicenseService(trustedPublicKeys: trustedKeys, licenseDirectory: tmpDir,
                       defaults: defaults, anchor: anchor)
    }

    private func makeClient() -> LicenseActivationClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        return LicenseActivationClient(
            baseURL: URL(string: "https://mac.xico.test")!,
            session: URLSession(configuration: config),
            defaults: defaults,
            anchor: anchor,
            trustedPublicKeys: trustedKeys
        )
    }

    /// 构造一份带有效 Ed25519 签名的复验响应（签名报文与 client 端 verifyVerdictSignature 逐字节一致）。
    private func signedResponse(
        status: String,
        licenseId: String,
        deviceId: String,
        signWith key: Curve25519.Signing.PrivateKey? = nil
    ) -> Data {
        let nonce = "nonce-abc"
        let timestamp = 1_700_000_000
        let message = Data("\(licenseId)\n\(deviceId)\n\(status)\n\(nonce)\n\(timestamp)".utf8)
        let signature = try! (key ?? signingKey).signature(for: message)
        return Self.jsonData([
            "ok": true,
            "status": status,
            "signature": signature.base64EncodedString(),
            "keyID": "release",
            "nonce": nonce,
            "timestamp": timestamp,
        ])
    }

    private static func jsonData(_ obj: [String: Any]) -> Data {
        try! JSONSerialization.data(withJSONObject: obj)
    }

    private func envelopeData(
        licenseID: String,
        customerName: String,
        expiresAt: Date?,
        deviceId: String?
    ) throws -> Data {
        let payload = LicensePayload(
            licenseID: licenseID,
            productID: "com.xico.app",
            customerName: customerName,
            issuedAt: Date(timeIntervalSince1970: 1_700_000_000),
            expiresAt: expiresAt,
            maxMajorVersion: 1,
            deviceId: deviceId
        )
        let payloadData = try JSONEncoder().encode(payload)
        let signature = try signingKey.signature(for: payloadData)
        let envelope = LicenseEnvelope(
            keyID: "release",
            payloadBase64: payloadData.base64EncodedString(),
            signatureBase64: signature.base64EncodedString()
        )
        return try JSONEncoder().encode(envelope)
    }
}

/// 拦截 URLSession 请求并回放预置响应的测试桩。
private final class MockURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var responder: ((URLRequest) -> (Int, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let responder = MockURLProtocol.responder else {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
            return
        }
        let (status, data) = responder(request)
        let response = HTTPURLResponse(url: request.url!, statusCode: status,
                                       httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
