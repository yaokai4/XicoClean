import XCTest
import CryptoKit
@testable import Infrastructure

/// 跨语言 interop 回归测试。
///
/// 官网（`xicoai.com` 的 `src/lib/license/sign.ts`）用 Node 端 Ed25519 逻辑签发的许可
/// 信封，必须能被本 App 的 `LicenseService` 离线验签、安装并解锁 Pro（`allowsCommercialUse`）。
///
/// 下方 fixture 由官网签名逻辑的等价 Node 脚本产出（Ed25519、sortedKeys、Apple 参考日期
/// 秒数、买断 perpetual 无 `expiresAt`、`productID=com.xico.app`、`keyID=xico-license-1`）。
/// 任一端改动破坏了信封契约，这个测试就会变红——正是它守护「官网发码 ↔ App 激活」互通。
/// （私钥为一次性测试密钥，只有公钥与信封参与校验，不含任何生产密钥。）
final class LicenseInteropTests: XCTestCase {
    private let trustedKeyID = "xico-license-1"
    private let publicKeyBase64 = #"lc4pc3x5G8wn67d2tgpKKHOeX04iuT2GlgT3Eqbebd8="#
    private let serverEnvelope = #"{"keyID":"xico-license-1","payloadBase64":"eyJjdXN0b21lck5hbWUiOiJidXllckBleGFtcGxlLmNvbSIsImlzc3VlZEF0Ijo3ODg5MTg0MDAsImxpY2Vuc2VJRCI6InVpZC1maXh0dXJlLXBlcnBldHVhbCIsIm1heE1ham9yVmVyc2lvbiI6OTksInByb2R1Y3RJRCI6ImNvbS54aWNvLmFwcCJ9","signatureBase64":"TIfF8RzQCdnZ/Ao1c21X73oKHRgIBDgI4pItJycYz/dexf1O9YrXshGkwjksP5tQ4bNvDVGqgRzEVdVHAOD2BQ=="}"#

    private func makeTempEnv() throws -> (URL, UserDefaults, String) {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("xico-interop-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let suite = "xico-interop-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        return (tmp, defaults, suite)
    }

    /// 官网签发的买断许可 → App 安装成功、永久有效、解锁商业功能。
    func testAppInstallsAndUnlocksServerSignedLicense() throws {
        let (tmp, defaults, suite) = try makeTempEnv()
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: tmp)
        }

        let pubData = try XCTUnwrap(Data(base64Encoded: publicKeyBase64))
        let service = LicenseService(
            trustedPublicKeys: [trustedKeyID: pubData],
            licenseDirectory: tmp,
            defaults: defaults,
            anchor: InMemoryAnchorStore(),
        )

        let envelopeData = try XCTUnwrap(serverEnvelope.data(using: .utf8))
        let status = try service.installLicense(fromEnvelopeData: envelopeData)

        XCTAssertTrue(status.state.allowsCommercialUse, "官网签发的许可应解锁商业功能")
        XCTAssertEqual(status.licenseID, "uid-fixture-perpetual")
        if case let .licensed(name, expiresAt) = status.state {
            XCTAssertEqual(name, "buyer@example.com")
            XCTAssertNil(expiresAt, "买断许可应为永久（无过期）")
        } else {
            XCTFail("状态应为 .licensed，实际为：\(status.state)")
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: status.licenseURL.path))
    }

    /// 同一个信封，若换成不匹配的公钥（等价于签名被篡改）必须被拒——确认签名真在保护 payload。
    func testServerEnvelopeRejectedUnderWrongKey() throws {
        let (tmp, defaults, suite) = try makeTempEnv()
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: tmp)
        }

        let wrongKey = Curve25519.Signing.PrivateKey().publicKey.rawRepresentation
        let service = LicenseService(
            trustedPublicKeys: [trustedKeyID: wrongKey],
            licenseDirectory: tmp,
            defaults: defaults,
            anchor: InMemoryAnchorStore(),
        )
        let envelopeData = try XCTUnwrap(serverEnvelope.data(using: .utf8))
        XCTAssertThrowsError(try service.installLicense(fromEnvelopeData: envelopeData)) { error in
            XCTAssertEqual(error as? LicenseError, .invalidSignature)
        }
    }
}
