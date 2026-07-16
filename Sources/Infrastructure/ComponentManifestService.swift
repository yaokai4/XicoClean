import Foundation
import CryptoKit

/// 运行时下载组件的唯一标识。签名清单只允许这三类，拒绝服务端借清单下发任意可执行文件。
public enum DownloadComponentID: String, Codable, Sendable, CaseIterable {
    case ytDlp = "yt-dlp"
    case ffmpeg
    case aria2

    var executableName: String {
        switch self {
        case .ytDlp: return "yt-dlp"
        case .ffmpeg: return "ffmpeg"
        case .aria2: return "aria2c"
        }
    }
}

public enum DownloadComponentArchive: String, Codable, Sendable {
    case raw
    case zip
    case tarGzip = "tar.gz"
}

/// 签名 payload 里的单个组件。hash/size/version/URL/架构全部在签名覆盖范围内。
public struct DownloadComponentDescriptor: Codable, Sendable, Equatable {
    public let id: DownloadComponentID
    public let version: String
    public let architecture: String       // arm64 / x86_64 / universal
    public let downloadURL: URL
    public let sha256: String
    public let size: Int64
    public let archive: DownloadComponentArchive
    public let executableName: String

    public init(id: DownloadComponentID, version: String, architecture: String,
                downloadURL: URL, sha256: String, size: Int64,
                archive: DownloadComponentArchive, executableName: String) {
        self.id = id
        self.version = version
        self.architecture = architecture
        self.downloadURL = downloadURL
        self.sha256 = sha256
        self.size = size
        self.archive = archive
        self.executableName = executableName
    }
}

/// sequence 单调递增，阻止 CDN/代理把客户端回退到已撤回的旧组件清单。
/// 时间均为 Unix 秒，避免跨 Swift/Node 的 Date 编码口径漂移。
public struct DownloadComponentManifest: Codable, Sendable, Equatable {
    public let schemaVersion: Int
    public let sequence: UInt64
    public let issuedAt: Int64
    public let expiresAt: Int64
    public let minimumAppVersion: String?
    public let components: [DownloadComponentDescriptor]

    public init(schemaVersion: Int = 1, sequence: UInt64, issuedAt: Int64, expiresAt: Int64,
                minimumAppVersion: String? = nil, components: [DownloadComponentDescriptor]) {
        self.schemaVersion = schemaVersion
        self.sequence = sequence
        self.issuedAt = issuedAt
        self.expiresAt = expiresAt
        self.minimumAppVersion = minimumAppVersion
        self.components = components
    }
}

public struct DownloadComponentEnvelope: Codable, Sendable, Equatable {
    public let keyID: String
    public let payloadBase64: String
    public let signatureBase64: String

    public init(keyID: String, payloadBase64: String, signatureBase64: String) {
        self.keyID = keyID
        self.payloadBase64 = payloadBase64
        self.signatureBase64 = signatureBase64
    }
}

public enum ComponentTrustError: Error, LocalizedError, Sendable, Equatable {
    case notConfigured
    case insecureEndpoint
    case responseTooLarge
    case malformedEnvelope
    case untrustedKey(String)
    case invalidSignature
    case invalidManifest(String)
    case expired
    case rollback(remote: UInt64, cached: UInt64)
    case componentUnavailable(String)

    public var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "组件信任链未配置，已停止安装"
        case .insecureEndpoint:
            return "组件清单必须使用 HTTPS"
        case .responseTooLarge:
            return "组件清单响应异常过大，已停止安装"
        case .malformedEnvelope:
            return "组件签名清单格式无效"
        case .untrustedKey(let id):
            return "组件签名密钥不受信任：\(id)"
        case .invalidSignature:
            return "组件清单签名校验失败"
        case .invalidManifest(let reason):
            return "组件清单内容无效：\(reason)"
        case .expired:
            return "组件签名清单已过期，请稍后重试"
        case .rollback(let remote, let cached):
            return "组件清单疑似回滚（远端 \(remote)，本机 \(cached)）"
        case .componentUnavailable(let id):
            return "签名清单没有适用于本机的组件：\(id)"
        }
    }
}

/// Ed25519 签名组件目录：Release 的 endpoint/公钥只从受 codesign 保护的 Info.plist 读取；
/// DEBUG 才允许环境变量覆盖。远端不可用时只降级到仍在有效期内且签名可验证的本地缓存。
public actor ComponentManifestService {
    public nonisolated let isConfigured: Bool

    private let endpoint: URL?
    private let trustedPublicKeys: [String: Data]
    private let cacheURL: URL
    private let session: URLSession
    private let now: @Sendable () -> Date
    private let appVersion: String

    public init(endpoint: URL?, trustedPublicKeys: [String: Data], cacheDirectory: URL? = nil,
                session: URLSession = .shared, appVersion: String = "0.0.0",
                now: @escaping @Sendable () -> Date = Date.init) {
        self.endpoint = endpoint
        self.trustedPublicKeys = trustedPublicKeys
        self.session = session
        self.appVersion = appVersion
        self.now = now
        self.isConfigured = endpoint != nil && !trustedPublicKeys.isEmpty
        let directory = cacheDirectory ?? Self.defaultCacheDirectory()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        self.cacheURL = directory.appendingPathComponent("components.signed.json")
    }

    public static func live() -> ComponentManifestService {
        let bundle = Bundle.main
        var endpointString = bundle.object(forInfoDictionaryKey: "XicoComponentsURL") as? String
        var keyString = bundle.object(forInfoDictionaryKey: "XicoComponentsPublicKeys") as? String
        #if DEBUG
        endpointString = ProcessInfo.processInfo.environment["XICO_COMPONENTS_URL"] ?? endpointString
        keyString = ProcessInfo.processInfo.environment["XICO_COMPONENTS_PUBLIC_KEYS"] ?? keyString
        #endif
        let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
        return ComponentManifestService(endpoint: endpointString.flatMap(URL.init(string:)),
                                        trustedPublicKeys: Self.parsePublicKeys(keyString),
                                        appVersion: version)
    }

    public func descriptor(for id: DownloadComponentID) async throws -> DownloadComponentDescriptor {
        let manifest = try await currentManifest()
        let arch = Self.currentArchitecture
        let candidates = manifest.components.filter {
            $0.id == id && ($0.architecture == arch || $0.architecture == "universal")
        }
        guard let selected = candidates.sorted(by: { lhs, rhs in
            if lhs.architecture == rhs.architecture { return lhs.version > rhs.version }
            return lhs.architecture == arch
        }).first else {
            throw ComponentTrustError.componentUnavailable("\(id.rawValue)/\(arch)")
        }
        return selected
    }

    public func currentManifest() async throws -> DownloadComponentManifest {
        guard let endpoint, !trustedPublicKeys.isEmpty else { throw ComponentTrustError.notConfigured }
        guard endpoint.isFileURL || endpoint.scheme?.lowercased() == "https" else {
            throw ComponentTrustError.insecureEndpoint
        }

        let cached = try? verifiedManifest(at: cacheURL)
        do {
            let data = try await fetch(endpoint)
            let remote = try decodeVerifiedEnvelope(data)
            if let cached, remote.sequence < cached.sequence {
                throw ComponentTrustError.rollback(remote: remote.sequence, cached: cached.sequence)
            }
            try data.write(to: cacheURL, options: [.atomic, .completeFileProtection])
            return remote
        } catch {
            // 只允许回退到仍在有效期内、签名仍有效的缓存；不允许未签名/过期缓存保可用性。
            if let cached { return cached }
            throw error
        }
    }

    public func decodeVerifiedEnvelope(_ data: Data) throws -> DownloadComponentManifest {
        guard data.count <= 1_048_576 else { throw ComponentTrustError.responseTooLarge }
        guard let envelope = try? JSONDecoder().decode(DownloadComponentEnvelope.self, from: data),
              let payload = Data(base64Encoded: envelope.payloadBase64),
              let signature = Data(base64Encoded: envelope.signatureBase64) else {
            throw ComponentTrustError.malformedEnvelope
        }
        guard let rawKey = trustedPublicKeys[envelope.keyID] else {
            throw ComponentTrustError.untrustedKey(envelope.keyID)
        }
        let key: Curve25519.Signing.PublicKey
        do { key = try Curve25519.Signing.PublicKey(rawRepresentation: rawKey) }
        catch { throw ComponentTrustError.untrustedKey(envelope.keyID) }
        guard key.isValidSignature(signature, for: payload) else {
            throw ComponentTrustError.invalidSignature
        }
        let manifest: DownloadComponentManifest
        do { manifest = try JSONDecoder().decode(DownloadComponentManifest.self, from: payload) }
        catch { throw ComponentTrustError.invalidManifest("JSON 无法解码") }
        try validate(manifest)
        return manifest
    }

    public func validate(_ manifest: DownloadComponentManifest) throws {
        guard manifest.schemaVersion == 1 else { throw ComponentTrustError.invalidManifest("schemaVersion 不受支持") }
        guard manifest.sequence > 0 else { throw ComponentTrustError.invalidManifest("sequence 必须大于 0") }
        let timestamp = Int64(now().timeIntervalSince1970)
        guard manifest.issuedAt <= timestamp + 300 else { throw ComponentTrustError.invalidManifest("签发时间来自未来") }
        guard manifest.expiresAt > timestamp else { throw ComponentTrustError.expired }
        guard manifest.expiresAt > manifest.issuedAt,
              manifest.expiresAt - manifest.issuedAt <= 31 * 24 * 60 * 60 else {
            throw ComponentTrustError.invalidManifest("有效期必须在 31 天内")
        }
        if let minimum = manifest.minimumAppVersion,
           Self.compareVersions(appVersion, minimum) == .orderedAscending {
            throw ComponentTrustError.invalidManifest("需要 Xico \(minimum) 或更高版本")
        }
        guard !manifest.components.isEmpty, manifest.components.count <= 24 else {
            throw ComponentTrustError.invalidManifest("components 数量异常")
        }
        var seen = Set<String>()
        for item in manifest.components {
            let key = "\(item.id.rawValue):\(item.architecture)"
            guard seen.insert(key).inserted else { throw ComponentTrustError.invalidManifest("组件重复：\(key)") }
            guard item.version.count <= 64, !item.version.isEmpty,
                  item.version.unicodeScalars.allSatisfy({ $0.isASCII && !CharacterSet.controlCharacters.contains($0) }) else {
                throw ComponentTrustError.invalidManifest("版本号无效：\(item.id.rawValue)")
            }
            guard ["arm64", "x86_64", "universal"].contains(item.architecture) else {
                throw ComponentTrustError.invalidManifest("架构无效：\(item.architecture)")
            }
            guard item.downloadURL.scheme?.lowercased() == "https",
                  item.downloadURL.host != nil,
                  item.downloadURL.user == nil, item.downloadURL.password == nil,
                  item.downloadURL.fragment == nil,
                  item.downloadURL.absoluteString.utf8.count <= 2_048 else {
                throw ComponentTrustError.invalidManifest("下载地址不安全：\(item.id.rawValue)")
            }
            guard item.sha256.count == 64,
                  item.sha256.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "0123456789abcdefABCDEF").contains($0) }) else {
                throw ComponentTrustError.invalidManifest("SHA-256 无效：\(item.id.rawValue)")
            }
            guard (1...Int64(500 * 1_024 * 1_024)).contains(item.size) else {
                throw ComponentTrustError.invalidManifest("文件大小无效：\(item.id.rawValue)")
            }
            guard item.executableName == item.id.executableName else {
                throw ComponentTrustError.invalidManifest("可执行文件名不匹配：\(item.id.rawValue)")
            }
            let expectedArchive: DownloadComponentArchive = switch item.id {
            case .ytDlp: .raw
            case .ffmpeg: .zip
            case .aria2: .tarGzip
            }
            guard item.archive == expectedArchive else {
                throw ComponentTrustError.invalidManifest("压缩格式不匹配：\(item.id.rawValue)")
            }
        }
    }

    private func verifiedManifest(at url: URL) throws -> DownloadComponentManifest {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        return try decodeVerifiedEnvelope(data)
    }

    private func fetch(_ url: URL) async throws -> Data {
        if url.isFileURL { return try Data(contentsOf: url) }
        let (data, response) = try await UpdateChecker.boundedData(from: url, session: session, limit: 1_048_576)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              response.url?.scheme?.lowercased() == "https" else {
            throw URLError(.badServerResponse)
        }
        return data
    }

    private static var currentArchitecture: String {
        #if arch(arm64)
        "arm64"
        #else
        "x86_64"
        #endif
    }

    private static func defaultCacheDirectory() -> URL {
        let base = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                 appropriateFor: nil, create: true))
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Xico/ComponentTrust", isDirectory: true)
    }

    static func parsePublicKeys(_ raw: String?) -> [String: Data] {
        guard let raw, !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [:] }
        var result: [String: Data] = [:]
        for pair in raw.split(separator: ",") {
            let parts = pair.split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2, !parts[0].isEmpty,
                  let value = Data(base64Encoded: parts[1]), value.count == 32 else { continue }
            result[parts[0]] = value
        }
        return result
    }

    private static func compareVersions(_ lhs: String, _ rhs: String) -> ComparisonResult {
        lhs.compare(rhs, options: .numeric)
    }
}
