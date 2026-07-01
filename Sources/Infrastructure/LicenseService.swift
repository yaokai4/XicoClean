import Foundation
import CryptoKit

public struct LicensePayload: Codable, Sendable, Equatable {
    public let licenseID: String
    public let productID: String
    public let customerName: String
    public let issuedAt: Date
    public let expiresAt: Date?
    public let maxMajorVersion: Int

    public init(
        licenseID: String,
        productID: String,
        customerName: String,
        issuedAt: Date,
        expiresAt: Date?,
        maxMajorVersion: Int
    ) {
        self.licenseID = licenseID
        self.productID = productID
        self.customerName = customerName
        self.issuedAt = issuedAt
        self.expiresAt = expiresAt
        self.maxMajorVersion = maxMajorVersion
    }
}

public struct LicenseEnvelope: Codable, Sendable, Equatable {
    public let keyID: String
    public let payloadBase64: String
    public let signatureBase64: String

    public init(keyID: String, payloadBase64: String, signatureBase64: String) {
        self.keyID = keyID
        self.payloadBase64 = payloadBase64
        self.signatureBase64 = signatureBase64
    }
}

public enum LicenseState: Sendable, Equatable {
    case licensed(customerName: String, expiresAt: Date?)
    case trial(daysRemaining: Int)
    case expired
    case invalid(reason: String)

    public var title: String {
        switch self {
        case .licensed: return "已授权"
        case .trial: return "试用中"
        case .expired: return "试用已结束"
        case .invalid: return "许可证无效"
        }
    }

    public var allowsCommercialUse: Bool {
        switch self {
        case .licensed, .trial: return true
        case .expired, .invalid: return false
        }
    }
}

public struct LicenseStatus: Sendable, Equatable {
    public let state: LicenseState
    public let licenseID: String?
    public let trialStartedAt: Date
    public let licenseURL: URL

    public var summary: String {
        switch state {
        case let .licensed(customerName, expiresAt):
            if let expiresAt {
                return "\(customerName) · 有效期至 \(Self.formatDate(expiresAt))"
            }
            return "\(customerName) · 永久授权"
        case let .trial(daysRemaining):
            return "剩余 \(daysRemaining) 天"
        case .expired:
            return "请输入有效许可证继续使用商业功能"
        case let .invalid(reason):
            return reason
        }
    }

    private static func formatDate(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate]
        return formatter.string(from: date)
    }
}

public enum LicenseError: Error, LocalizedError, Sendable, Equatable {
    case malformedEnvelope
    case untrustedKey(String)
    case invalidSignature
    case invalidPayload(String)
    case expired

    public var errorDescription: String? {
        switch self {
        case .malformedEnvelope: return "许可证文件格式无效"
        case let .untrustedKey(keyID): return "许可证签名密钥不受信任：\(keyID)"
        case .invalidSignature: return "许可证签名校验失败"
        case let .invalidPayload(reason): return "许可证内容无效：\(reason)"
        case .expired: return "许可证已过期"
        }
    }
}

public final class LicenseService: @unchecked Sendable {
    private static let trialStartKey = "xico.license.trialStartedAt"
    private static let lastSeenKey = "xico.license.lastSeenDate"

    private let productID: String
    private let appMajorVersion: Int
    private let trustedPublicKeys: [String: Data]
    private let licenseURL: URL
    private let defaults: UserDefaults
    private let trialDays: Int
    private let anchor: SecureAnchorStore
    /// 已吊销的许可证 ID（经签名规则库通道下发）——命中即视为无效。
    private let revokedLicenseIDs: Set<String>

    public init(
        productID: String = "com.xico.app",
        appMajorVersion: Int = 1,
        trustedPublicKeys: [String: Data],
        licenseDirectory: URL? = nil,
        defaults: UserDefaults = .standard,
        trialDays: Int = 14,
        anchor: SecureAnchorStore = KeychainAnchorStore(),
        revokedLicenseIDs: Set<String> = []
    ) {
        self.productID = productID
        self.appMajorVersion = appMajorVersion
        self.trustedPublicKeys = trustedPublicKeys
        let directory = licenseDirectory ?? Self.defaultLicenseDirectory()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        self.licenseURL = directory.appendingPathComponent("license.xico-license")
        self.defaults = defaults
        self.trialDays = trialDays
        self.anchor = anchor
        self.revokedLicenseIDs = revokedLicenseIDs
    }

    public static func live(revokedLicenseIDs: Set<String> = []) -> LicenseService {
        let bundle = Bundle.main
        // Release 构建**只**信任随 App 签名嵌入、受 codesign 保护的 Info.plist 公钥。
        // 开发调试通道（环境变量 / UserDefaults 覆盖）仅在 DEBUG 编译存在——否则终端用户
        // 一条 `defaults write com.xico.app xico.license.publicKeys ...` 即可注入自签信任根绕过付费。
        var keyString = bundle.object(forInfoDictionaryKey: "XicoLicensePublicKeys") as? String
        #if DEBUG
        keyString = ProcessInfo.processInfo.environment["XICO_LICENSE_PUBLIC_KEYS"]
            ?? UserDefaults.standard.string(forKey: "xico.license.publicKeys")
            ?? keyString
        #endif
        return LicenseService(trustedPublicKeys: parsePublicKeys(keyString),
                              revokedLicenseIDs: revokedLicenseIDs)
    }

    /// 购买页地址：优先取 Info.plist 的 XicoPurchaseURL（发布时通过 make_app.sh 注入），
    /// 缺省回落到官网占位地址。用于「购买」按钮，让试用到期用户有付费路径。
    public static func purchaseURL() -> URL {
        if let s = Bundle.main.object(forInfoDictionaryKey: "XicoPurchaseURL") as? String,
           let u = URL(string: s) { return u }
        return URL(string: "https://xico.app/buy")!
    }

    public func status(now wallClock: Date = Date()) -> LicenseStatus {
        // 防时钟回拨：用单调递增的「已见过的最晚时间」作为有效当前时间，
        // 把系统时钟往回调不能让过期许可证复活、也不能重置/延长试用。
        let now = effectiveNow(wallClock)
        let trialStart = trialStartedAt(now: now)
        if let data = try? Data(contentsOf: licenseURL) {
            do {
                let payload = try decodeVerifiedPayload(fromEnvelopeData: data, now: now)
                return LicenseStatus(
                    state: .licensed(customerName: payload.customerName, expiresAt: payload.expiresAt),
                    licenseID: payload.licenseID,
                    trialStartedAt: trialStart,
                    licenseURL: licenseURL
                )
            } catch {
                return LicenseStatus(
                    state: .invalid(reason: error.localizedDescription),
                    licenseID: nil,
                    trialStartedAt: trialStart,
                    licenseURL: licenseURL
                )
            }
        }

        let elapsed = Calendar.current.dateComponents([.day], from: trialStart, to: now).day ?? 0
        let remaining = max(0, trialDays - elapsed)
        return LicenseStatus(
            state: remaining > 0 ? .trial(daysRemaining: remaining) : .expired,
            licenseID: nil,
            trialStartedAt: trialStart,
            licenseURL: licenseURL
        )
    }

    /// 有效当前时间 = max(墙钟, 历史见过的最晚时间)。同时把新的最晚时间写回两处存储。
    private func effectiveNow(_ wallClock: Date) -> Date {
        let seenDefaults = defaults.object(forKey: Self.lastSeenKey) as? Date
        let seenAnchor = anchor.date(forKey: Self.lastSeenKey)
        let lastSeen = [seenDefaults, seenAnchor].compactMap { $0 }.max()
        let effective = max(wallClock, lastSeen ?? wallClock)
        if lastSeen == nil || effective > lastSeen! {
            defaults.set(effective, forKey: Self.lastSeenKey)
            anchor.set(effective, forKey: Self.lastSeenKey)
        }
        return effective
    }

    @discardableResult
    public func installLicense(fromEnvelopeData data: Data, now: Date = Date()) throws -> LicenseStatus {
        _ = try decodeVerifiedPayload(fromEnvelopeData: data, now: now)
        try data.write(to: licenseURL, options: .atomic)
        return status(now: now)
    }

    public func clearLicense() {
        try? FileManager.default.removeItem(at: licenseURL)
    }

    public func decodeVerifiedPayload(fromEnvelopeData data: Data, now: Date = Date()) throws -> LicensePayload {
        guard let envelope = try? JSONDecoder().decode(LicenseEnvelope.self, from: data),
              let payloadData = Data(base64Encoded: envelope.payloadBase64),
              let signature = Data(base64Encoded: envelope.signatureBase64) else {
            throw LicenseError.malformedEnvelope
        }
        guard let keyData = trustedPublicKeys[envelope.keyID] else {
            throw LicenseError.untrustedKey(envelope.keyID)
        }
        let publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: keyData)
        guard publicKey.isValidSignature(signature, for: payloadData) else {
            throw LicenseError.invalidSignature
        }
        let payload = try JSONDecoder().decode(LicensePayload.self, from: payloadData)
        try validate(payload, now: now)
        return payload
    }

    private func validate(_ payload: LicensePayload, now: Date) throws {
        guard payload.productID == productID else {
            throw LicenseError.invalidPayload("产品不匹配")
        }
        guard !payload.licenseID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw LicenseError.invalidPayload("licenseID 不能为空")
        }
        guard !revokedLicenseIDs.contains(payload.licenseID) else {
            throw LicenseError.invalidPayload("许可证已被吊销")
        }
        guard payload.maxMajorVersion >= appMajorVersion else {
            throw LicenseError.invalidPayload("许可证不支持当前主版本")
        }
        if let expiresAt = payload.expiresAt, expiresAt < now {
            throw LicenseError.expired
        }
    }

    private func trialStartedAt(now: Date) -> Date {
        // 取 UserDefaults 与钥匙串锚点中的最早值——删掉任一副本都不能重置试用。
        let fromDefaults = defaults.object(forKey: Self.trialStartKey) as? Date
        let fromAnchor = anchor.date(forKey: Self.trialStartKey)
        if let earliest = [fromDefaults, fromAnchor].compactMap({ $0 }).min() {
            // 回填缺失的副本，保证两处一致
            if fromDefaults == nil { defaults.set(earliest, forKey: Self.trialStartKey) }
            if fromAnchor == nil { anchor.set(earliest, forKey: Self.trialStartKey) }
            return earliest
        }
        defaults.set(now, forKey: Self.trialStartKey)
        anchor.set(now, forKey: Self.trialStartKey)
        return now
    }

    private static func defaultLicenseDirectory() -> URL {
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
