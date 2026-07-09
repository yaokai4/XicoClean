import XCTest
import CryptoKit
@testable import Infrastructure

/// 授权时钟/绑定/心跳的补漏回归（2026-07 round-3 审计）：
/// 1) 未来时钟裁剪——一次错误的未来读数不得永久 brick 试用/到期/被标记许可（P2）。
/// 2) 未绑定信封切换日——切换日后缺 deviceId 的信封被拒，切换日前的遗留未绑定仍放行（P2）。
/// 3) 永久授权软心跳——默认关闭时离线永久可用；启用后超窗降级、一次成功复验自愈（P3）。
final class LicenseClockClampTests: XCTestCase {
    private var tmpDir: URL!
    private var defaults: UserDefaults!
    private var suiteName: String!
    private var anchor: InMemoryAnchorStore!

    override func setUpWithError() throws {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("xico-license-clamp-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        suiteName = "xico-license-clamp-\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        anchor = InMemoryAnchorStore()
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: tmpDir)
    }

    // MARK: 1) 未来时钟裁剪（P2）

    /// 一次「未来时钟」读数（系统时钟前跳 100 天）把锚点污染后，时钟恢复正常不应把试用永久 brick。
    /// 有效当前时间被夹在 `wallClock + futureSkewTolerance(2d)` 内，随真实时间推进即恢复。
    func testFarFutureClockDoesNotPermanentlyBrickTrial() {
        let service = trialService()
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        XCTAssertEqual(service.status(now: start).state, .trial(daysRemaining: 14))   // 记 trialStart=start
        // 错误的未来读数：污染 lastSeen 到 start+100d
        _ = service.status(now: start.addingTimeInterval(100 * 86_400))
        // 时钟恢复到 start+1d：若无裁剪，有效时间将取 start+100d → 永久 .expired（brick）。
        let recovered = service.status(now: start.addingTimeInterval(86_400))
        if case .expired = recovered.state { XCTFail("一次未来时钟读数不应把试用永久 brick") }
        if case .invalid = recovered.state { XCTFail("一次未来时钟读数不应把试用永久降级") }
        // 具体：有效当前被夹在 (start+1d) + 12d 容差 = start+13d → 剩 1 天（仍在试用，未 brick）
        XCTAssertEqual(recovered.state, .trial(daysRemaining: 1))
    }

    /// 裁剪不破坏向后防回拨：污染后把时钟回拨到更早，仍不能让试用天数倒流增加。
    func testClampStillBlocksBackwardRollback() {
        let service = trialService()
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        _ = service.status(now: start)
        XCTAssertEqual(service.status(now: start.addingTimeInterval(5 * 86_400)).state, .trial(daysRemaining: 9))
        // 回拨到第 2 天：有效时间仍取历史最晚(第 5 天)，剩余不该变多
        XCTAssertEqual(service.status(now: start.addingTimeInterval(2 * 86_400)).state, .trial(daysRemaining: 9))
    }

    // MARK: 2) 未绑定信封切换日（P2）

    func testUnboundEnvelopeAfterCutoverRejected() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let key = Curve25519.Signing.PrivateKey()
        let service = LicenseService(
            trustedPublicKeys: ["release": key.publicKey.rawRepresentation],
            licenseDirectory: tmpDir, defaults: defaults, anchor: anchor,
            bindingCutover: now)
        // 未绑定(deviceId=nil) 且签发于切换日之后 → 拒绝
        let after = try envelope(licenseID: "post", deviceId: nil,
                                 issuedAt: now.addingTimeInterval(86_400), key: key)
        XCTAssertThrowsError(try service.decodeVerifiedPayload(
            fromEnvelopeData: after, now: now.addingTimeInterval(2 * 86_400)),
            "切换日后缺 deviceId 的信封必须拒绝")
        // 遗留未绑定但签发于切换日之前 → 放行（不误伤存量）
        let before = try envelope(licenseID: "legacy", deviceId: nil,
                                  issuedAt: now.addingTimeInterval(-86_400), key: key)
        XCTAssertNoThrow(try service.decodeVerifiedPayload(fromEnvelopeData: before, now: now),
                         "切换日前的遗留未绑定许可仍应放行")
    }

    func testDefaultNoCutoverKeepsUnboundHonored() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let key = Curve25519.Signing.PrivateKey()
        // 默认 bindingCutover=nil（测试 bundle 无该 Info.plist 键）→ 未绑定信封照常放行（现状行为）
        let service = LicenseService(
            trustedPublicKeys: ["release": key.publicKey.rawRepresentation],
            licenseDirectory: tmpDir, defaults: defaults, anchor: anchor)
        let env = try envelope(licenseID: "unbound", deviceId: nil,
                               issuedAt: now.addingTimeInterval(365 * 86_400), key: key)
        XCTAssertNoThrow(try service.decodeVerifiedPayload(
            fromEnvelopeData: env, now: now.addingTimeInterval(366 * 86_400)),
            "不设切换日时未绑定信封不应被拒（保持现状，不回归存量用户）")
    }

    // MARK: 3) 永久授权软心跳（P3）

    func testPerpetualHeartbeatDefaultOffKeepsOfflineForever() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let key = Curve25519.Signing.PrivateKey()
        let service = LicenseService(
            trustedPublicKeys: ["release": key.publicKey.rawRepresentation],
            licenseDirectory: tmpDir, defaults: defaults, anchor: anchor)   // 心跳默认关闭
        let data = try envelope(licenseID: "perp", deviceId: nil, issuedAt: now, expiresAt: nil, key: key)
        _ = try service.installLicense(fromEnvelopeData: data, now: now)
        guard case .licensed = service.status(now: now.addingTimeInterval(400 * 86_400)).state else {
            return XCTFail("默认不启用心跳时永久授权离线 400 天仍应有效")
        }
    }

    func testPerpetualHeartbeatDowngradesAfterWindowThenSelfHeals() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let key = Curve25519.Signing.PrivateKey()
        let service = LicenseService(
            trustedPublicKeys: ["release": key.publicKey.rawRepresentation],
            licenseDirectory: tmpDir, defaults: defaults, anchor: anchor,
            perpetualHeartbeatDays: 30)
        let data = try envelope(licenseID: "perp", deviceId: nil, issuedAt: now, expiresAt: nil, key: key)
        _ = try service.installLicense(fromEnvelopeData: data, now: now)   // firstSeen 打桩=now
        guard case .licensed = service.status(now: now.addingTimeInterval(10 * 86_400)).state else {
            return XCTFail("心跳宽限窗内应仍授权")
        }
        guard case .invalid = service.status(now: now.addingTimeInterval(31 * 86_400)).state else {
            return XCTFail("超过心跳窗且零复验应降级为受限")
        }
        // 模拟一次成功联网复验（写与 LicenseActivationClient 共享的 lastValidated 键）
        let vkey = LicenseService.lastValidatedKey("perp")
        let validatedAt = now.addingTimeInterval(31 * 86_400)
        defaults.set(validatedAt, forKey: vkey)
        anchor.set(validatedAt, forKey: vkey)
        guard case .licensed = service.status(now: now.addingTimeInterval(40 * 86_400)).state else {
            return XCTFail("一次成功复验应把心跳锚点推进并自愈回授权")
        }
    }

    // MARK: 夹具

    private func trialService() -> LicenseService {
        LicenseService(trustedPublicKeys: [:], licenseDirectory: tmpDir,
                       defaults: defaults, trialDays: 14, anchor: anchor)
    }

    private func envelope(
        licenseID: String,
        deviceId: String?,
        issuedAt: Date,
        expiresAt: Date? = nil,
        key: Curve25519.Signing.PrivateKey
    ) throws -> Data {
        let payload = LicensePayload(
            licenseID: licenseID, productID: "com.xico.app", customerName: "Co",
            issuedAt: issuedAt, expiresAt: expiresAt, maxMajorVersion: 1, deviceId: deviceId)
        let payloadData = try JSONEncoder().encode(payload)
        let signature = try key.signature(for: payloadData)
        let env = LicenseEnvelope(
            keyID: "release",
            payloadBase64: payloadData.base64EncodedString(),
            signatureBase64: signature.base64EncodedString())
        return try JSONEncoder().encode(env)
    }
}
