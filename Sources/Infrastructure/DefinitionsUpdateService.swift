import Foundation
import DesignSystem
import CryptoKit
import Domain

public struct DefinitionsUpdateEnvelope: Codable, Sendable, Equatable {
    public let keyID: String
    public let payloadBase64: String
    public let signatureBase64: String

    public init(keyID: String, payloadBase64: String, signatureBase64: String) {
        self.keyID = keyID
        self.payloadBase64 = payloadBase64
        self.signatureBase64 = signatureBase64
    }
}

public struct DefinitionsUpdateStatus: Sendable, Equatable {
    public let activeVersion: Int
    public let cachedVersion: Int?
    public let endpointConfigured: Bool
    public let trustConfigured: Bool
    public let cacheURL: URL
}

public enum DefinitionsUpdateError: Error, LocalizedError, Sendable, Equatable {
    case endpointNotConfigured
    case insecureRemoteURL
    case untrustedKey(String)
    case malformedEnvelope
    case invalidSignature
    case invalidLibrary(String)
    case staleVersion(remote: Int, current: Int)

    public var errorDescription: String? {
        switch self {
        case .endpointNotConfigured: return "未配置规则库更新地址"
        case .insecureRemoteURL: return "规则库更新地址必须使用 HTTPS"
        case let .untrustedKey(keyID): return xLocF("规则库签名密钥不受信任：%@", keyID)
        case .malformedEnvelope: return "规则库更新包格式无效"
        case .invalidSignature: return "规则库签名校验失败"
        case let .invalidLibrary(reason): return xLocF("规则库内容无效：%@", reason)
        case let .staleVersion(remote, current): return xLocF("远端规则库版本 %@ 不高于当前版本 %@", remote, current)
        }
    }
}

public final class DefinitionsUpdateService: @unchecked Sendable {
    private let bundled: DefinitionsLibrary
    private let endpoint: URL?
    private let trustedPublicKeys: [String: Data]
    private let cacheURL: URL
    private let session: URLSession

    public init(
        bundled: DefinitionsLibrary = .bundled(),
        endpoint: URL?,
        trustedPublicKeys: [String: Data],
        cacheDirectory: URL? = nil,
        session: URLSession = .shared
    ) {
        self.bundled = bundled
        self.endpoint = endpoint
        self.trustedPublicKeys = trustedPublicKeys
        let directory = cacheDirectory ?? Self.defaultCacheDirectory()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        self.cacheURL = directory.appendingPathComponent("definitions.signed.json")
        self.session = session
    }

    public static func live(bundled: DefinitionsLibrary = .bundled()) -> DefinitionsUpdateService {
        let bundle = Bundle.main
        // Release 只信任 Info.plist（受 codesign 保护）配置的更新端点与公钥。
        // 环境变量 / UserDefaults 覆盖仅供 DEBUG 联调，避免本机进程注入恶意端点/信任根。
        var endpointString = bundle.object(forInfoDictionaryKey: "XicoDefinitionsURL") as? String
        var keyString = bundle.object(forInfoDictionaryKey: "XicoDefinitionsPublicKeys") as? String
        #if DEBUG
        let defaults = UserDefaults.standard
        endpointString = ProcessInfo.processInfo.environment["XICO_DEFINITIONS_URL"]
            ?? defaults.string(forKey: "xico.definitions.url")
            ?? endpointString
        keyString = ProcessInfo.processInfo.environment["XICO_DEFINITIONS_PUBLIC_KEYS"]
            ?? defaults.string(forKey: "xico.definitions.publicKeys")
            ?? keyString
        #endif
        return DefinitionsUpdateService(
            bundled: bundled,
            endpoint: endpointString.flatMap(URL.init(string:)),
            trustedPublicKeys: Self.parsePublicKeys(keyString)
        )
    }

    public func currentLibrary() -> DefinitionsLibrary {
        cachedLibrary() ?? bundled
    }

    public func status() -> DefinitionsUpdateStatus {
        DefinitionsUpdateStatus(
            activeVersion: currentLibrary().version,
            cachedVersion: cachedLibrary()?.version,
            endpointConfigured: endpoint != nil,
            trustConfigured: !trustedPublicKeys.isEmpty,
            cacheURL: cacheURL
        )
    }

    public func refresh() async throws -> DefinitionsLibrary {
        guard let endpoint else { throw DefinitionsUpdateError.endpointNotConfigured }
        if endpoint.isFileURL == false && endpoint.scheme?.lowercased() != "https" {
            throw DefinitionsUpdateError.insecureRemoteURL
        }
        let data = try await fetchData(from: endpoint)
        let library = try decodeVerifiedLibrary(fromEnvelopeData: data)
        let current = currentLibrary()
        guard library.version > current.version else {
            throw DefinitionsUpdateError.staleVersion(remote: library.version, current: current.version)
        }
        try data.write(to: cacheURL, options: .atomic)
        return library
    }

    public func cachedLibrary() -> DefinitionsLibrary? {
        guard let data = try? Data(contentsOf: cacheURL) else { return nil }
        return try? decodeVerifiedLibrary(fromEnvelopeData: data)
    }

    public func decodeVerifiedLibrary(fromEnvelopeData data: Data) throws -> DefinitionsLibrary {
        guard let envelope = try? JSONDecoder().decode(DefinitionsUpdateEnvelope.self, from: data),
              let payload = Data(base64Encoded: envelope.payloadBase64),
              let signature = Data(base64Encoded: envelope.signatureBase64) else {
            throw DefinitionsUpdateError.malformedEnvelope
        }
        guard let keyData = trustedPublicKeys[envelope.keyID] else {
            throw DefinitionsUpdateError.untrustedKey(envelope.keyID)
        }
        let publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: keyData)
        guard publicKey.isValidSignature(signature, for: payload) else {
            throw DefinitionsUpdateError.invalidSignature
        }
        let library = try JSONDecoder().decode(DefinitionsLibrary.self, from: payload)
        try validate(library)
        return library
    }

    public func validate(_ library: DefinitionsLibrary) throws {
        guard library.version > 0 else {
            throw DefinitionsUpdateError.invalidLibrary("version 必须大于 0")
        }
        guard !library.definitions.isEmpty else {
            throw DefinitionsUpdateError.invalidLibrary("definitions 不能为空")
        }
        var seen = Set<String>()
        for definition in library.definitions {
            guard !definition.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw DefinitionsUpdateError.invalidLibrary("定义 id 不能为空")
            }
            guard seen.insert(definition.id).inserted else {
                throw DefinitionsUpdateError.invalidLibrary(xLocF("重复定义 id：%@", definition.id))
            }
            guard !definition.paths.isEmpty else {
                throw DefinitionsUpdateError.invalidLibrary(xLocF("%@ 缺少 paths", definition.id))
            }
            // 路径形状校验（摄入期纵深防御）：拒绝逃逸出预期前缀集的定义，requiresHelper
            // 定义额外必须落在助手白名单根下——把坏定义在入库前整条拒掉，而非仅靠删除期逐项兜底。
            for path in definition.paths {
                guard DefinitionPathPolicy.isAllowed(path: path, requiresHelper: definition.requiresHelper) else {
                    throw DefinitionsUpdateError.invalidLibrary(
                        xLocF("%@ 的路径超出允许范围：%@", definition.id, path))
                }
            }
        }
    }

    private func fetchData(from url: URL) async throws -> Data {
        if url.isFileURL { return try Data(contentsOf: url) }
        let (data, response) = try await session.data(from: url)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw URLError(.badServerResponse)
        }
        return data
    }

    private static func defaultCacheDirectory() -> URL {
        let base = (try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Xico", isDirectory: true)
    }

    private static func parsePublicKeys(_ raw: String?) -> [String: Data] {
        guard let raw, !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [:] }
        var keys: [String: Data] = [:]
        for pair in raw.split(separator: ",") {
            let parts = pair.split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2, let data = Data(base64Encoded: parts[1]) else { continue }
            keys[parts[0]] = data
        }
        return keys
    }
}
