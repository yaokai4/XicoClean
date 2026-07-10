import Foundation
import DesignSystem
import CryptoKit

public struct LicensePayload: Codable, Sendable, Equatable {
    public let licenseID: String
    public let productID: String
    public let customerName: String
    public let issuedAt: Date
    public let expiresAt: Date?
    public let maxMajorVersion: Int
    /// 设备绑定：签发时由服务端把 `DeviceIdentity.current()` 印进签名 payload。
    /// **可选且向后兼容**——历史签发的许可缺此字段（解码为 nil），仍按未绑定处理照常放行，
    /// 绝不影响存量付费用户；新签发的许可一旦带上此值，拷贝到别的机器即失配被拒。
    /// 合成 Codable 对 Optional 走 encodeIfPresent/decodeIfPresent，nil 时不写入 JSON，
    /// 因此老信封的签名字节与验签结果完全不变（interop 契约不破）。
    public let deviceId: String?

    public init(
        licenseID: String,
        productID: String,
        customerName: String,
        issuedAt: Date,
        expiresAt: Date?,
        maxMajorVersion: Int,
        deviceId: String? = nil
    ) {
        self.licenseID = licenseID
        self.productID = productID
        self.customerName = customerName
        self.issuedAt = issuedAt
        self.expiresAt = expiresAt
        self.maxMajorVersion = maxMajorVersion
        self.deviceId = deviceId
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

    /// 商业功能闸门。**如实告知的已知限制（审计 P3，已接受）**：这是一个纯客户端布尔——
    /// 有决心者给二进制打补丁即可翻转，客户端无法自证完全封堵。真正的控制点在服务端：
    /// 未付款不签发许可信封（离线验签所需的 Ed25519 私钥只在服务器），配合设备绑定 + 在线复验
    /// (revoked/refunded) 收敛滥用。此处仅作 UI/流程闸门，不假装是防破解保证。
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
                return xLocF("%@ · 有效期至 %@", customerName, Self.formatDate(expiresAt))
            }
            return xLocF("%@ · 永久授权", customerName)
        case let .trial(daysRemaining):
            return xLocF("剩余 %d 天", daysRemaining)
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
        case let .untrustedKey(keyID): return xLocF("许可证签名密钥不受信任：%@", keyID)
        case .invalidSignature: return "许可证签名校验失败"
        case let .invalidPayload(reason): return xLocF("许可证内容无效：%@", reason)
        case .expired: return "许可证已过期"
        }
    }
}

public final class LicenseService: @unchecked Sendable {
    private static let trialStartKey = "xico.license.trialStartedAt"
    private static let lastSeenKey = "xico.license.lastSeenDate"
    /// 本地吊销名单键前缀：`recordRevoked` 落一个该证被撤销的时间戳，`isRevoked` 命中即拒。
    /// 令服务端一次「吊销/退款」结论永久生效——重新导入同一份签名许可也无法复活。
    private static let revokedKeyPrefix = "xico.license.revoked."
    /// 本地「席位已释放」台账键前缀：按 (licenseID, deviceId) 记一个时间戳。用户在本机主动
    /// 「释放授权」(deactivate) 后落此标记；此后**手动重新导入**同一份签名信封（无服务端 round-trip）
    /// 被 `installLicense(enforceReleased:)` 拒绝，直到一次成功的**在线激活**（服务端重新盖章席位）
    /// 经默认 `installLicense` 清除该标记。堵住「停用→重导入即把席位吹回来」的设备绑定绕过（审计 P2）。
    private static let releasedKeyPrefix = "xico.license.released."
    static func releasedKey(_ licenseID: String, _ deviceId: String) -> String {
        releasedKeyPrefix + licenseID + "." + deviceId
    }
    /// 联网复验台账（与 `LicenseActivationClient` 共享同一 defaults + 钥匙串命名空间）：
    /// `flagged.<id>` = 服务器首次把该证标记为可疑的时间；`lastValidated.<id>` = 单调递增的
    /// 最近一次成功联网复验时间。曾被 flagged 且超过宽限期仍未成功复验 → 降级为受限。
    static func flaggedKey(_ id: String) -> String { "xico.license.flagged." + id }
    static func lastValidatedKey(_ id: String) -> String { "xico.license.lastValidated." + id }
    /// 被 flagged 后要求在此宽限窗内完成一次成功联网复验，否则降级。正常离线（从未被 flagged）不受影响。
    static let reverifyGraceWindow: TimeInterval = 30 * 86_400
    /// 未来时钟容差：单调 lastSeen 只允许比墙钟至多超前这么多，超出部分视为一次瞬态时钟前跳被裁掉。
    /// 防「一次错误的未来时钟读数把锚点永久毒化，从而把试用/到期/被标记许可永久 brick」（审计 P2）：
    /// 有效时间因此恒 ≤ 墙钟 + 本容差，任何前跳都随真实时间推进自动收敛，绝不永久化。
    ///
    /// 取值 12 天的取舍：既有防回拨用例会把「已到期许可」的时钟回拨 20 天并要求它保持到期
    /// （从到期日 +30d 回拨到 +20d，须使有效时间仍 > +30d），这要求容差 > 10 天才不放行回拨续命；
    /// 同时须 < 试用期 14 天，令一次未来跳变最多消耗试用的一部分而非全部（不 brick 试用）。
    /// 向后（回拨）保护因此在 ≤12 天范围内完全不受影响，仅超 12 天的极端前跳被收敛。
    static let futureSkewTolerance: TimeInterval = 12 * 86_400
    /// 「首次见到本证」的落盘键前缀（供永久授权软心跳锚点，见 perpetualHeartbeatDays）。
    static let firstSeenKeyPrefix = "xico.license.firstSeen."

    private let productID: String
    private let appMajorVersion: Int
    private let trustedPublicKeys: [String: Data]
    private let licenseURL: URL
    private let defaults: UserDefaults
    private let trialDays: Int
    private let anchor: SecureAnchorStore
    /// 已吊销的许可证 ID（经签名规则库通道下发）——命中即视为无效。
    private let revokedLicenseIDs: Set<String>
    /// 未绑定信封切换日：若设置，则 `deviceId == nil` 且 `issuedAt` 晚于此日的信封一律拒绝
    /// （切换日之后服务端必须为每次签发印上 deviceId，缺失即视为被拷贝/篡改的副本）。
    /// **默认 nil（不设 = 现状行为）**——切换日之前签发的遗留未绑定许可仍照常放行，绝不误伤存量用户。
    /// 完整设备绑定仍需服务端在 100% 签发上印章 deviceId（见 cross_file_notes 的服务端要求）。审计 P2。
    /// 默认试用天数（docs/14 P2：14 → 15，与首启付费墙「先试用 15 天」文案一致）。
    /// UI（PricingView 逃逸按钮）据此判断「全新试用 vs 试用中」，改这里即全局生效。
    public static let defaultTrialDays = 15

    private let bindingCutover: Date?
    /// 永久授权软心跳天数：若设置(>0)，无到期日的永久授权在连续这么多天「零成功联网复验」后
    /// 降级为受限，直至一次成功联网复验自愈（服务端可据此收敛离线退款/吊销滥用）。审计 P3（AppModel:432）。
    /// **默认 nil（不设 = 现状：永久授权永久离线可用）**——只有运营方显式注入才启用，绝不默认惩罚离线用户。
    private let perpetualHeartbeatDays: Int?

    public init(
        productID: String = "com.xico.app",
        appMajorVersion: Int = 1,
        trustedPublicKeys: [String: Data],
        licenseDirectory: URL? = nil,
        defaults: UserDefaults = .standard,
        trialDays: Int = LicenseService.defaultTrialDays,
        anchor: SecureAnchorStore = KeychainAnchorStore(),
        revokedLicenseIDs: Set<String> = [],
        bindingCutover: Date? = LicenseService.infoPlistBindingCutover(),
        perpetualHeartbeatDays: Int? = LicenseService.infoPlistHeartbeatDays()
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
        self.bindingCutover = bindingCutover
        self.perpetualHeartbeatDays = perpetualHeartbeatDays
    }

    /// 未绑定信封切换日：优先取 Info.plist 的 `XicoLicenseBindingCutover`（ISO 日期，如 `2026-01-01`）。
    /// make_app.sh 注入；未注入则返回 nil（不启用切换，保持现状放行）。
    public static func infoPlistBindingCutover() -> Date? {
        guard let s = Bundle.main.object(forInfoDictionaryKey: "XicoLicenseBindingCutover") as? String,
              !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let dateOnly = ISO8601DateFormatter()
        dateOnly.formatOptions = [.withFullDate]
        if let d = dateOnly.date(from: s) { return d }
        return ISO8601DateFormatter().date(from: s)
    }

    /// 永久授权软心跳天数：优先取 Info.plist 的 `XicoPerpetualHeartbeatDays`（正整数，可为字符串数字）。
    /// make_app.sh 注入；未注入 / 非正整数则返回 nil（不启用心跳，保持现状）。
    public static func infoPlistHeartbeatDays() -> Int? {
        let raw = Bundle.main.object(forInfoDictionaryKey: "XicoPerpetualHeartbeatDays")
        if let n = raw as? Int, n > 0 { return n }
        if let s = raw as? String, let n = Int(s.trimmingCharacters(in: .whitespacesAndNewlines)), n > 0 { return n }
        return nil
    }

    public static func live(revokedLicenseIDs: Set<String> = []) -> LicenseService {
        return LicenseService(trustedPublicKeys: liveTrustedPublicKeys(),
                              revokedLicenseIDs: revokedLicenseIDs)
    }

    /// 加载「随 App 签名嵌入、受 codesign 保护」的 Ed25519 信任根公钥集。
    /// 与在线复验（`LicenseActivationClient`）共用同一信任根——复验响应的签名也以这批公钥验证，
    /// 令「离线许可信封」与「在线复验结论」处于同一密码学信任边界。
    /// Release 构建**只**信任 Info.plist 公钥；DEBUG 调试通道（环境变量 / UserDefaults 覆盖）
    /// 仅在 DEBUG 编译存在——否则终端用户一条 `defaults write ...` 即可注入自签信任根绕过付费。
    public static func liveTrustedPublicKeys() -> [String: Data] {
        let bundle = Bundle.main
        var keyString = bundle.object(forInfoDictionaryKey: "XicoLicensePublicKeys") as? String
        #if DEBUG
        keyString = ProcessInfo.processInfo.environment["XICO_LICENSE_PUBLIC_KEYS"]
            ?? UserDefaults.standard.string(forKey: "xico.license.publicKeys")
            ?? keyString
        #endif
        return parsePublicKeys(keyString)
    }

    /// 购买页地址：优先取 Info.plist 的 XicoPurchaseURL（发布时通过 make_app.sh 注入），
    /// 缺省回落到官网占位地址。用于「购买」按钮，让试用到期用户有付费路径。
    public static func purchaseURL() -> URL {
        if let s = Bundle.main.object(forInfoDictionaryKey: "XicoPurchaseURL") as? String,
           let u = URL(string: s) { return u }
        return URL(string: "https://mac.xicoai.com/buy")!
    }

    /// 在线激活服务地址：软件把激活码 POST 到 `<此地址>/api/license/activate`，
    /// 服务端校验后返回一份用受信私钥签名的许可信封，本地离线验签后落盘解锁。
    /// 优先取 Info.plist 的 XicoActivationURL（make_app.sh 注入），缺省回落官网。
    public static func activationBaseURL() -> URL {
        if let s = Bundle.main.object(forInfoDictionaryKey: "XicoActivationURL") as? String,
           let u = URL(string: s) { return u }
        #if DEBUG
        if let s = ProcessInfo.processInfo.environment["XICO_ACTIVATION_URL"],
           let u = URL(string: s) { return u }
        #endif
        return URL(string: "https://mac.xicoai.com")!
    }

    public func status(now wallClock: Date = Date()) -> LicenseStatus {
        // 防时钟回拨：用单调递增的「已见过的最晚时间」作为有效当前时间，
        // 把系统时钟往回调不能让过期许可证复活、也不能重置/延长试用。
        let now = effectiveNow(wallClock)
        let trialStart = trialStartedAt(now: now)
        if let data = try? Data(contentsOf: licenseURL) {
            do {
                let payload = try decodeVerifiedPayload(fromEnvelopeData: data, now: now)
                // 曾被服务器标记为可疑、又长期(>宽限期)没能成功联网复验 → 降级为受限（非删除许可）。
                // 一旦恢复联网并成功复验，flag 被清除、时间戳更新，status 自动回到 .licensed（自愈）。
                if isReverificationLapsed(licenseID: payload.licenseID, now: now) {
                    return LicenseStatus(
                        state: .invalid(reason: xLoc("许可证需要联网重新验证，请联网后重试。")),
                        licenseID: payload.licenseID,
                        trialStartedAt: trialStart,
                        licenseURL: licenseURL
                    )
                }
                // 永久授权软心跳（审计 P3，默认关闭）：仅当运营方注入 perpetualHeartbeatDays 时生效。
                // 无到期日的永久授权若连续超过该天数「零成功联网复验」，降级为受限，一次成功复验即自愈。
                // 锚点 = max(首次见到本证的时间, 最近一次成功复验)——离线退款/吊销滥用因此不再零成本。
                if payload.expiresAt == nil, let hbDays = perpetualHeartbeatDays, hbDays > 0,
                   now.timeIntervalSince(heartbeatAnchor(licenseID: payload.licenseID, now: now)) > Double(hbDays) * 86_400 {
                    return LicenseStatus(
                        state: .invalid(reason: xLoc("许可证需要联网重新验证，请联网后重试。")),
                        licenseID: payload.licenseID,
                        trialStartedAt: trialStart,
                        licenseURL: licenseURL
                    )
                }
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
    ///
    /// 未来越界裁剪（审计 P2）：历史 lastSeen 只允许比墙钟至多超前 `futureSkewTolerance`；
    /// 超出部分裁到该上限，令「一次错误的未来时钟读数」不能把锚点永久毒化、把试用/到期/被标记
    /// 许可永久 brick。落盘的有效时间因此也被夹在 `wallClock + futureSkewTolerance` 之内，
    /// 随真实时间推进即自动恢复。向后（回拨）保护完全不动——回拨仍取历史最晚值，绝不续命。
    private func effectiveNow(_ wallClock: Date) -> Date {
        let seenDefaults = defaults.object(forKey: Self.lastSeenKey) as? Date
        let seenAnchor = anchor.date(forKey: Self.lastSeenKey)
        let rawLastSeen = [seenDefaults, seenAnchor].compactMap { $0 }.max()
        // 未来上限：锚点不得超前墙钟太多。取 min 裁掉瞬态前跳，但保留其余的向后防回拨语义。
        let futureCap = wallClock.addingTimeInterval(Self.futureSkewTolerance)
        let lastSeen = rawLastSeen.map { min($0, futureCap) }
        let effective = max(wallClock, lastSeen ?? wallClock)   // effective ≤ futureCap，天然有界
        if lastSeen == nil || effective > lastSeen! {
            defaults.set(effective, forKey: Self.lastSeenKey)
            anchor.set(effective, forKey: Self.lastSeenKey)
        }
        return effective
    }

    /// 未绑定设备（`deviceId == nil`）信封的度量键：签发绑定设备前的历史/遗留信封落在此队列。
    /// 只落一个指标供后续统计「未绑定占比」，不改变放行逻辑（存量用户照常解锁）。审计 P3。
    static let unboundCohortKey = "xico.license.unboundCohort"

    /// 安装许可信封。
    ///
    /// `enforceReleased`（默认 false）区分两条来源，是「释放席位不可凭本地重导入复活」的关键：
    ///  - **false（默认，在线激活路径）**：调用发生在 `LicenseActivationClient.activate` 服务端 round-trip
    ///    之后（服务端已为本设备重新盖章席位），因此**清除**本机对该 (licenseID, deviceId) 的释放标记，
    ///    令后续手动导入恢复正常。这就是「成功在线激活即清除标记」。
    ///  - **true（手动导入信封路径，无服务端 round-trip）**：若本机曾释放此证席位，则**拒绝**——
    ///    直到一次成功的在线激活清除标记。堵住「停用→重导入同一份签名文件把席位吹回来」（审计 P2）。
    @discardableResult
    public func installLicense(fromEnvelopeData data: Data, now: Date = Date(),
                               enforceReleased: Bool = false) throws -> LicenseStatus {
        let payload = try decodeVerifiedPayload(fromEnvelopeData: data, now: now)
        let device = DeviceIdentity.current()
        if enforceReleased {
            // 手动重导入：本机已释放该证席位且尚未在线重新激活 → 拒绝（失败保守，不放行绕过）。
            if isReleased(licenseID: payload.licenseID, deviceId: device) {
                throw LicenseError.invalidPayload("本机授权已释放，请重新在线激活")
            }
        } else {
            // 在线激活成功 round-trip：服务端已重新盖章本设备席位，清除释放标记，恢复正常。
            clearReleased(licenseID: payload.licenseID, deviceId: device)
        }
        // 度量未绑定队列：新签发的信封都应带 deviceId；仍为 nil 的属遗留/未印章队列，记一个指标以便量化其规模，
        // 而不是假设该队列为空。放行逻辑不变——存量未绑定用户照常解锁。
        if payload.deviceId == nil {
            defaults.set(payload.licenseID, forKey: Self.unboundCohortKey)
        } else {
            defaults.removeObject(forKey: Self.unboundCohortKey)
        }
        try data.write(to: licenseURL, options: .atomic)
        return status(now: now)
    }

    /// 是否存在「已安装但未设备绑定」的许可（供上层上报未绑定队列规模的指标）。审计 P3。
    public var hasUnboundLicense: Bool {
        defaults.object(forKey: Self.unboundCohortKey) != nil
    }

    /// 移除授权：仅删除授权文件即完成「去授权」——`status()` 以文件为准，文件不在即视为未授权。
    /// 有意**保留**钥匙串锚点（trialStartedAt 防回拨、revoked.* 吊销名单、flagged/lastValidated 复验状态）：
    /// 它们是「按设备、按证 ID」的反滥用状态，不是授权凭据。清掉反而会打开
    /// 「删除→重导入即重置试用 / 逃避吊销与宽限降级」的绕过口子。跨机复制的席位另由
    /// 设备绑定（签名内 deviceId）+ 钥匙串 ThisDeviceOnly 拦截，无需在此清锚点。
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
        guard !isRevoked(payload.licenseID) else {
            throw LicenseError.invalidPayload("许可证已被吊销")
        }
        // 设备绑定：payload 带 deviceId 时必须与本机一致，否则拒绝——一份签名文件拷到别的机器即失效。
        // deviceId 为 nil（历史签发、服务端尚未印章）时默认不校验，存量用户照常放行。
        // 换机/换主板等硬件变更导致 DeviceIdentity 变化时，用户在新机上重新「激活」即可，
        // 服务端会为新设备重新签发一份印上新 deviceId 的许可（即「重新激活」宽限路径）。
        //
        // 未绑定信封切换日（审计 P2）：一旦运营方设定 bindingCutover，则「deviceId==nil 且签发于切换日之后」
        // 的信封一律拒绝——切换日后服务端须为每次签发印上 deviceId，缺失即视为被拷贝/篡改的副本。
        // 切换日之前签发的遗留未绑定许可（issuedAt <= cutover）仍照常放行，不误伤存量用户。
        // **注意：完整设备绑定仍依赖服务端在 100% 签发上印章 deviceId**——本地无法凭空补印，仅能凭切换日拒绝缺章的新证。
        if let boundDevice = payload.deviceId {
            if boundDevice != DeviceIdentity.current() {
                throw LicenseError.invalidPayload("许可证与本机不匹配")
            }
        } else if let cutover = bindingCutover, payload.issuedAt > cutover {
            throw LicenseError.invalidPayload("许可证与本机不匹配")
        }
        guard payload.maxMajorVersion >= appMajorVersion else {
            throw LicenseError.invalidPayload("许可证不支持当前主版本")
        }
        if let expiresAt = payload.expiresAt, expiresAt < now {
            throw LicenseError.expired
        }
    }

    // MARK: 本地吊销名单（防「重新导入复活」）

    /// 该许可证是否已被吊销：命中「规则库下发的静态名单」或「本地持久台账（钥匙串/偏好任一副本）」即为真。
    /// 采用「任一命中即拒」的失败保守策略——删掉某一处副本也无法漂白。
    public func isRevoked(_ licenseID: String) -> Bool {
        if revokedLicenseIDs.contains(licenseID) { return true }
        let key = Self.revokedKeyPrefix + licenseID
        return anchor.date(forKey: key) != nil || defaults.object(forKey: key) != nil
    }

    /// 记录一次吊销：由在线复验返回 revoked/refunded 时调用（见 AppModel）。
    /// 同时写入钥匙串锚点与 UserDefaults 两处，令「重新导入同一份签名许可」也无法复活。
    public func recordRevoked(_ licenseID: String) {
        let trimmed = licenseID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let key = Self.revokedKeyPrefix + trimmed
        let now = Date()
        anchor.set(now, forKey: key)
        defaults.set(now, forKey: key)
    }

    // MARK: 本地「席位已释放」台账（防「停用→重导入即复活席位」）

    /// 本机是否已释放该 (licenseID, deviceId) 的席位：钥匙串锚点或偏好任一副本命中即为真
    /// （失败保守：删掉其中一处副本也不能漂白）。仅拦截**手动重导入**；成功在线激活会清除此标记。
    public func isReleased(licenseID: String, deviceId: String) -> Bool {
        let key = Self.releasedKey(licenseID, deviceId)
        return anchor.date(forKey: key) != nil || defaults.object(forKey: key) != nil
    }

    /// 记录本机释放了某证的席位：由「释放本机授权」(deactivate) 成功后调用（见 PricingView）。
    /// 同写钥匙串锚点与 UserDefaults 两处（ThisDeviceOnly，不随备份迁移），令重导入同一份信封无法复活席位。
    public func recordReleased(licenseID: String, deviceId: String) {
        let id = licenseID.trimmingCharacters(in: .whitespacesAndNewlines)
        let dev = deviceId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty, !dev.isEmpty else { return }
        let key = Self.releasedKey(id, dev)
        let now = Date()
        anchor.set(now, forKey: key)
        defaults.set(now, forKey: key)
    }

    /// 清除释放标记：仅在一次成功的在线激活 round-trip 后调用（默认 `installLicense` 内部触发）——
    /// 服务端此时已为本设备重新盖章席位，本地标记随之作废，后续手动导入恢复正常。
    public func clearReleased(licenseID: String, deviceId: String) {
        let id = licenseID.trimmingCharacters(in: .whitespacesAndNewlines)
        let dev = deviceId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty, !dev.isEmpty else { return }
        let key = Self.releasedKey(id, dev)
        anchor.remove(forKey: key)
        defaults.removeObject(forKey: key)
    }

    /// 曾被服务器标记(flagged)的许可证，若超过宽限期仍无一次成功联网复验，则应降级为受限。
    /// 从未被 flagged 的许可（绝大多数正版）永远返回 false——正常离线不受任何影响。
    /// 时间戳取钥匙串/偏好两处的**最早**flag 时间（失败保守：删一处副本不能推迟降级）。
    func isReverificationLapsed(licenseID: String, now: Date) -> Bool {
        let key = Self.flaggedKey(licenseID)
        let flaggedAt = [defaults.object(forKey: key) as? Date, anchor.date(forKey: key)]
            .compactMap { $0 }.min()
        guard let flaggedAt else { return false }
        return now.timeIntervalSince(flaggedAt) > Self.reverifyGraceWindow
    }

    /// 当前已安装的许可是否处于「联网复验超期」的受限降级态（供 AppModel 判定是否应主动联网自愈）。
    /// 读取当前落盘许可的 licenseID；无许可文件 / 无法解出 ID 时返回 false。审计 CONTRACT (c)。
    public func isReverificationLapsed(now wallClock: Date = Date()) -> Bool {
        let now = effectiveNow(wallClock)
        guard let data = try? Data(contentsOf: licenseURL),
              let payload = try? decodeVerifiedPayload(fromEnvelopeData: data, now: now) else {
            return false
        }
        return isReverificationLapsed(licenseID: payload.licenseID, now: now)
    }

    /// 自愈入口：清除某证的「可疑标记(flag)/超期降级」台账，令 `status()` 从受限态回到 `.licensed`。
    /// 仅应在取得可信证据后调用——即一次**签名验证通过**的 `active` 在线复验（见 `LicenseActivationClient`）。
    /// **不**触碰本地吊销名单（`recordRevoked` 落地的吊销结论仍永久生效，不因自愈而复活）。审计 CONTRACT (b)(c)。
    public func clearReverificationFlag(_ licenseID: String) {
        let key = Self.flaggedKey(licenseID)
        defaults.removeObject(forKey: key)
        anchor.remove(forKey: key)
    }

    /// 永久授权软心跳锚点 = max(首次见到本证的时间, 最近一次成功联网复验)。
    /// 首次见到时间惰性落盘（缺失即以 now 打桩，双副本取最早，删一处不重置）——因此运营方启用心跳后，
    /// 存量已安装许可从「启用后首次读取」起算宽限窗，不会因 issuedAt 久远而被立刻降级。
    /// lastValidated 由成功的在线复验（LicenseActivationClient）单调写入，成功一次即把锚点推到当下 → 自愈。
    private func heartbeatAnchor(licenseID: String, now: Date) -> Date {
        let seenKey = Self.firstSeenKeyPrefix + licenseID
        let firstSeen: Date
        if let seen = [defaults.object(forKey: seenKey) as? Date, anchor.date(forKey: seenKey)]
            .compactMap({ $0 }).min() {
            firstSeen = seen
            if defaults.object(forKey: seenKey) == nil { defaults.set(seen, forKey: seenKey) }
            if anchor.date(forKey: seenKey) == nil { anchor.set(seen, forKey: seenKey) }
        } else {
            firstSeen = now
            defaults.set(now, forKey: seenKey)
            anchor.set(now, forKey: seenKey)
        }
        let validatedKey = Self.lastValidatedKey(licenseID)
        let lastValidated = [defaults.object(forKey: validatedKey) as? Date, anchor.date(forKey: validatedKey)]
            .compactMap { $0 }.max()
        return [firstSeen, lastValidated].compactMap { $0 }.max() ?? firstSeen
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
