import XCTest
import CryptoKit
@testable import Infrastructure

/// 自更新 EdDSA 完整性验签测试（round-2 审计 P2：appcast enclosure 无签名 → 加密验签）。
final class UpdateSignatureTests: XCTestCase {

    private let version = "1.4.0"
    private let url = URL(string: "https://mac.xicoai.com/Xico-1.4.0.dmg")!

    /// 用私钥对规范描述串签名，返回 (keyID→公钥字典, base64 签名)。
    private func sign(version: String, url: URL, sha256: String?)
        -> (keys: [String: Data], signature: String) {
        let priv = Curve25519.Signing.PrivateKey()
        let message = UpdateChecker.signedDescriptor(version: version, downloadURL: url, sha256: sha256)
        let sig = try! priv.signature(for: message)
        return (["k1": priv.publicKey.rawRepresentation], sig.base64EncodedString())
    }

    func testValidSignaturePasses() {
        let (keys, sig) = sign(version: version, url: url, sha256: nil)
        XCTAssertTrue(UpdateChecker.verifyEnclosureSignature(
            version: version, downloadURL: url, sha256: nil,
            signatureBase64: sig, trustedKeys: keys))
    }

    func testValidSignatureWithSHA256Passes() {
        let hash = "abc123DEF"
        let (keys, sig) = sign(version: version, url: url, sha256: hash)
        // 大小写规范化：验签侧对 sha256 统一小写，传入大写仍应通过。
        XCTAssertTrue(UpdateChecker.verifyEnclosureSignature(
            version: version, downloadURL: url, sha256: hash.uppercased(),
            signatureBase64: sig, trustedKeys: keys))
    }

    func testTamperedVersionFails() {
        let (keys, sig) = sign(version: version, url: url, sha256: nil)
        XCTAssertFalse(UpdateChecker.verifyEnclosureSignature(
            version: "9.9.9", downloadURL: url, sha256: nil,
            signatureBase64: sig, trustedKeys: keys))
    }

    func testTamperedURLFails() {
        let (keys, sig) = sign(version: version, url: url, sha256: nil)
        let evil = URL(string: "https://mac.xicoai.com/evil.dmg")!
        XCTAssertFalse(UpdateChecker.verifyEnclosureSignature(
            version: version, downloadURL: evil, sha256: nil,
            signatureBase64: sig, trustedKeys: keys))
    }

    func testWrongKeyFails() {
        let (_, sig) = sign(version: version, url: url, sha256: nil)
        let otherKey = ["k1": Curve25519.Signing.PrivateKey().publicKey.rawRepresentation]
        XCTAssertFalse(UpdateChecker.verifyEnclosureSignature(
            version: version, downloadURL: url, sha256: nil,
            signatureBase64: sig, trustedKeys: otherKey))
    }

    func testMissingSignatureFails() {
        let (keys, _) = sign(version: version, url: url, sha256: nil)
        XCTAssertFalse(UpdateChecker.verifyEnclosureSignature(
            version: version, downloadURL: url, sha256: nil,
            signatureBase64: nil, trustedKeys: keys))
    }

    func testEmptyTrustedKeysFails() {
        let (_, sig) = sign(version: version, url: url, sha256: nil)
        XCTAssertFalse(UpdateChecker.verifyEnclosureSignature(
            version: version, downloadURL: url, sha256: nil,
            signatureBase64: sig, trustedKeys: [:]))
    }

    /// 一枚受信公钥外加一枚无关公钥：只要有任一命中即通过（多密钥轮换场景）。
    func testAnyTrustedKeyMatches() {
        let (keys, sig) = sign(version: version, url: url, sha256: nil)
        var merged = keys
        merged["k0"] = Curve25519.Signing.PrivateKey().publicKey.rawRepresentation
        XCTAssertTrue(UpdateChecker.verifyEnclosureSignature(
            version: version, downloadURL: url, sha256: nil,
            signatureBase64: sig, trustedKeys: merged))
    }

    /// appcast 解析应从 enclosure 抽出 sparkle:edSignature 与 sha256。
    func testParserExtractsSignatureAndHash() throws {
        let xml = """
        <?xml version="1.0" encoding="utf-8"?>
        <rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" version="2.0">
          <channel>
            <item>
              <sparkle:shortVersionString>1.4.0</sparkle:shortVersionString>
              <enclosure url="https://mac.xicoai.com/Xico-1.4.0.dmg"
                         sparkle:edSignature="SIG=="
                         sha256="deadbeef"
                         sparkle:version="140"/>
            </item>
          </channel>
        </rss>
        """
        let info = try XCTUnwrap(UpdateChecker.parseLatest(Data(xml.utf8)))
        XCTAssertEqual(info.edSignature, "SIG==")
        XCTAssertEqual(info.sha256, "deadbeef")
    }
}
