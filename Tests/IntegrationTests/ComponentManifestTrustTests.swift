import XCTest
import CryptoKit
@testable import Infrastructure

final class ComponentManifestTrustTests: XCTestCase {

    private func descriptor(_ id: DownloadComponentID = .ffmpeg,
                            url: String = "https://components.xico.test/ffmpeg.zip",
                            archive: DownloadComponentArchive = .zip,
                            executable: String = "ffmpeg") -> DownloadComponentDescriptor {
        DownloadComponentDescriptor(id: id, version: "7.1.1", architecture: "universal",
                                    downloadURL: URL(string: url)!,
                                    sha256: String(repeating: "a", count: 64), size: 123,
                                    archive: archive, executableName: executable)
    }

    private func manifest(sequence: UInt64 = 1,
                          issuedAt: Int64 = 1_799_999_900,
                          expiresAt: Int64 = 1_800_086_400,
                          components: [DownloadComponentDescriptor]? = nil) -> DownloadComponentManifest {
        DownloadComponentManifest(sequence: sequence, issuedAt: issuedAt, expiresAt: expiresAt,
                                  minimumAppVersion: "1.0.0",
                                  components: components ?? [descriptor()])
    }

    private func envelope(_ manifest: DownloadComponentManifest,
                          key: Curve25519.Signing.PrivateKey,
                          keyID: String = "components-v1") throws -> Data {
        let payload = try JSONEncoder().encode(manifest)
        let signature = try key.signature(for: payload)
        return try JSONEncoder().encode(DownloadComponentEnvelope(
            keyID: keyID,
            payloadBase64: payload.base64EncodedString(),
            signatureBase64: signature.base64EncodedString()
        ))
    }

    private func service(key: Curve25519.Signing.PrivateKey,
                         directory: URL? = nil,
                         endpoint: URL? = nil) -> ComponentManifestService {
        ComponentManifestService(endpoint: endpoint,
                                 trustedPublicKeys: ["components-v1": key.publicKey.rawRepresentation],
                                 cacheDirectory: directory, appVersion: "2.0.0",
                                 now: { Date(timeIntervalSince1970: 1_800_000_000) })
    }

    func testValidSignedManifestIsAccepted() async throws {
        let key = Curve25519.Signing.PrivateKey()
        let catalog = service(key: key)
        let decoded = try await catalog.decodeVerifiedEnvelope(envelope(manifest(), key: key))
        XCTAssertEqual(decoded.sequence, 1)
        XCTAssertEqual(decoded.components.first?.id, .ffmpeg)
    }

    func testTamperedPayloadAndWrongKeyAreRejected() async throws {
        let trusted = Curve25519.Signing.PrivateKey()
        let attacker = Curve25519.Signing.PrivateKey()
        let catalog = service(key: trusted)
        let attacked = try envelope(manifest(), key: attacker)
        do {
            _ = try await catalog.decodeVerifiedEnvelope(attacked)
            XCTFail("攻击者签名不应通过")
        } catch {
            XCTAssertEqual(error as? ComponentTrustError, .invalidSignature)
        }

        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: try envelope(manifest(), key: trusted)) as? [String: Any])
        object["payloadBase64"] = Data("{}".utf8).base64EncodedString()
        let tampered = try JSONSerialization.data(withJSONObject: object)
        do {
            _ = try await catalog.decodeVerifiedEnvelope(tampered)
            XCTFail("签名后的 payload 被替换不应通过")
        } catch {
            XCTAssertEqual(error as? ComponentTrustError, .invalidSignature)
        }
    }

    func testExpiredAndUnsafeDescriptorsAreRejected() async throws {
        let key = Curve25519.Signing.PrivateKey()
        let catalog = service(key: key)
        do {
            _ = try await catalog.decodeVerifiedEnvelope(envelope(
                manifest(issuedAt: 1_799_000_000, expiresAt: 1_799_999_999), key: key))
            XCTFail("过期清单不应通过")
        } catch {
            XCTAssertEqual(error as? ComponentTrustError, .expired)
        }

        let unsafe = descriptor(url: "http://components.xico.test/ffmpeg.zip")
        do {
            _ = try await catalog.decodeVerifiedEnvelope(envelope(manifest(components: [unsafe]), key: key))
            XCTFail("HTTP 组件 URL 不应通过")
        } catch let ComponentTrustError.invalidManifest(reason) {
            XCTAssertTrue(reason.contains("下载地址"))
        }
    }

    func testCachedSequencePreventsRollback() async throws {
        let key = Curve25519.Signing.PrivateKey()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("xico-components-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let endpoint = directory.appendingPathComponent("remote.json")
        try envelope(manifest(sequence: 2), key: key).write(to: endpoint)
        let catalog = service(key: key, directory: directory.appendingPathComponent("cache"), endpoint: endpoint)
        let first = try await catalog.currentManifest()
        XCTAssertEqual(first.sequence, 2)

        try envelope(manifest(sequence: 1), key: key).write(to: endpoint, options: .atomic)
        // 远端回滚时继续使用已验证、未过期的 sequence=2 缓存，绝不安装旧目录内容。
        let afterRollback = try await catalog.currentManifest()
        XCTAssertEqual(afterRollback.sequence, 2)
    }

    func testDescriptorIdentityCannotRenameExecutable() async throws {
        let key = Curve25519.Signing.PrivateKey()
        let catalog = service(key: key)
        let renamed = descriptor(executable: "postinstall")
        do {
            _ = try await catalog.decodeVerifiedEnvelope(envelope(manifest(components: [renamed]), key: key))
            XCTFail("清单不能借组件 ID 下发任意可执行文件名")
        } catch let ComponentTrustError.invalidManifest(reason) {
            XCTAssertTrue(reason.contains("可执行文件名"))
        }
    }
}
