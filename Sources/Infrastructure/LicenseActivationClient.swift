import Foundation
import DesignSystem
import CryptoKit

/// 在线激活失败原因（面向用户的可读文案）。
public enum LicenseActivationError: Error, LocalizedError, Sendable, Equatable {
    case invalidKey
    case notFound
    case seatLimit(Int)
    case revoked
    case network
    case server
    case malformedResponse

    public var errorDescription: String? {
        switch self {
        case .invalidKey: return xLoc("激活码格式不正确，请检查后重试。")
        case .notFound: return xLoc("未找到该激活码，请确认输入是否正确。")
        case let .seatLimit(n):
            return n > 0
                ? xLocF("激活台数已达上限（%d 台）。如需在更多设备使用，请升级或联系我们。", n)
                : xLoc("激活台数已达上限。")
        case .revoked: return xLoc("该激活码已失效或已退款。")
        case .network: return xLoc("网络连接失败，请检查网络后重试。")
        case .server: return xLoc("服务器繁忙，请稍后重试。")
        case .malformedResponse: return xLoc("激活响应无效，请稍后重试。")
        }
    }
}

private struct ActivateRequest: Encodable {
    let key: String
    let deviceId: String
    let deviceName: String?
}

private struct ActivateResponse: Decodable {
    let ok: Bool
    let license: String?
    let error: String?
    let seats: Int?
}

private struct ValidateRequest: Encodable {
    let licenseId: String
    let deviceId: String
}

private struct ValidateResponse: Decodable {
    let ok: Bool
    let status: String?
    /// 服务端对 `{licenseId, deviceId, status, nonce, timestamp}` 的 Ed25519 签名（base64）。
    /// 服务端尚未签发此字段时为 nil——此时破坏性结论(revoked/refunded)一律降级为 `.inconclusive`（不 brick）。
    let signature: String?
    /// 签名所用公钥的 keyID（与许可信封同一命名空间）。缺省时用全部受信公钥逐一验签兜底。
    let keyID: String?
    /// 防重放随机串，纳入签名报文。
    let nonce: String?
    /// 签名时间戳（Unix 秒），纳入签名报文。
    let timestamp: Int?
}

private struct DeactivateRequest: Encodable {
    let licenseId: String
    let deviceId: String
}

private struct DeactivateResponse: Decodable {
    let ok: Bool
    let error: String?
}

/// 联网复验的落地档位：`.ok` 正常放行；`.limited` 表示该证曾被服务器标记(flagged)且
/// 超出宽限期仍无一次成功联网复验，界面应降级为受限（仍保留许可，联网复验成功即自愈）。
public enum LicenseReverificationGate: Sendable, Equatable {
    case ok
    case limited
}

/// 在线复验的服务器结论。只有 `.revoked` 会触发本地撤销；其余一律宽容。
public enum LicenseValidationVerdict: Sendable, Equatable {
    /// 服务器确认许可证有效。
    case valid
    /// 服务器明确表示已吊销/已退款——应清除本地许可。
    case revoked
    /// 网络失败、服务器错误、未知响应、库中查无此证——保持现状。
    case inconclusive
}

/// 把用户输入的激活码 POST 到官网激活接口，成功则返回可离线验签安装的许可信封字节。
public final class LicenseActivationClient: @unchecked Sendable {
    private let baseURL: URL
    private let session: URLSession
    /// 复验台账的两处持久化副本（与 `LicenseService` 共享同一 defaults + 钥匙串命名空间，
    /// 键由 `LicenseService.flaggedKey/lastValidatedKey` 统一派生，令服务侧 status() 能读到并据此降级）。
    private let defaults: UserDefaults
    private let anchor: SecureAnchorStore
    /// 复验响应的验签信任根：与离线许可信封**共用**同一批 Ed25519 公钥（`LicenseService.liveTrustedPublicKeys()`）。
    /// 破坏性结论（revoked/refunded）只有在此信任根下验签通过才会被采信，令 TLS 单点被 MITM 也无法伪造吊销。
    private let trustedPublicKeys: [String: Data]

    public init(
        baseURL: URL = LicenseService.activationBaseURL(),
        session: URLSession = .shared,
        defaults: UserDefaults = .standard,
        anchor: SecureAnchorStore = KeychainAnchorStore(),
        trustedPublicKeys: [String: Data] = LicenseService.liveTrustedPublicKeys(),
    ) {
        self.baseURL = baseURL
        self.session = session
        self.defaults = defaults
        self.anchor = anchor
        self.trustedPublicKeys = trustedPublicKeys
    }

    /// 返回签名许可信封的原始字节（交给 `LicenseService.installLicense(fromEnvelopeData:)`）。
    public func activate(
        key: String,
        deviceId: String,
        deviceName: String?,
    ) async throws -> Data {
        var request = URLRequest(
            url: baseURL.appendingPathComponent("api/license/activate"),
        )
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 20
        request.httpBody = try JSONEncoder().encode(
            ActivateRequest(key: key, deviceId: deviceId, deviceName: deviceName),
        )

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw LicenseActivationError.network
        }

        guard let http = response as? HTTPURLResponse else {
            throw LicenseActivationError.malformedResponse
        }
        let decoded = try? JSONDecoder().decode(ActivateResponse.self, from: data)

        if http.statusCode == 200, let body = decoded, body.ok,
           let license = body.license, let bytes = license.data(using: .utf8) {
            return bytes
        }

        switch decoded?.error {
        case "invalid": throw LicenseActivationError.invalidKey
        case "not_found": throw LicenseActivationError.notFound
        case "seat_limit": throw LicenseActivationError.seatLimit(decoded?.seats ?? 0)
        case "revoked", "refunded": throw LicenseActivationError.revoked
        default:
            throw http.statusCode >= 500
                ? LicenseActivationError.server
                : LicenseActivationError.malformedResponse
        }
    }

    /// 定期在线复验：询问服务器该许可证当前状态。设计为「疑罪从无」+「破坏性结论须签名背书」——
    /// 只有服务器回答 revoked/refunded **且**该响应带有效 Ed25519 签名时才返回 `.revoked`；
    /// 未签名 / 验签失败的 revoked 一律降级为 `.inconclusive`（视为暂态，绝不 brick 正版）。
    /// 断网、超时、5xx、404（库中查无）同样返回 `.inconclusive`。
    ///
    /// 破坏性(revoked)必须验签的原因：`.revoked` 会触发 `LicenseService.recordRevoked` 记名吊销并删除本地许可，
    /// 一旦被 MITM（伪造/误签 CA、企业代理、DNS+证书污染）以一句未签名的 "revoked" 触发即成永久 brick。
    /// 良性结论（active 清 flag、flagged 落标记）不改变红线，可在无签名时照常采信（只对用户有利）。
    public func validate(
        licenseId: String,
        deviceId: String,
    ) async -> LicenseValidationVerdict {
        var request = URLRequest(
            url: baseURL.appendingPathComponent("api/license/validate"),
        )
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15
        guard let body = try? JSONEncoder().encode(
            ValidateRequest(licenseId: licenseId, deviceId: deviceId),
        ) else { return .inconclusive }
        request.httpBody = body

        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse,
              http.statusCode == 200,
              let decoded = try? JSONDecoder().decode(ValidateResponse.self, from: data),
              decoded.ok, let status = decoded.status else {
            return .inconclusive
        }
        switch status {
        case "active":
            // 一次成功且「有效」的联网复验：更新单调时间戳并清除历史 flag（该证已确认无恙，不再受限）。
            // 良性结论——即便无签名也照常自愈（只对用户有利，不越过任何红线）。
            recordSuccessfulValidation(licenseId: licenseId)
            clearFlag(licenseId: licenseId)
            return .valid
        case "revoked", "refunded":
            // 破坏性结论：必须验签通过才采信，否则降级为暂态（不 brick）。
            return verifyVerdictSignature(licenseId: licenseId, deviceId: deviceId, response: decoded)
                ? .revoked
                : .inconclusive
        case "flagged", "grace":
            // 服务器把该证标记为可疑但尚未吊销——保持宽容（.inconclusive 不惩罚）。
            // 但「落 flag」本身会启动 30 天降级计时器，是一种破坏性副作用（软 brick），
            // 因此与 revoked 同样要求 Ed25519 签名背书：只有带有效签名的 flagged/grace 才落标记（审计 P3）。
            // 未签名的 flagged 视为纯暂态，不持久化任何状态——一次 MITM 的未签名 "flagged" 无法植入降级计时器。
            //
            // 网络抑制的兜底（审计 P3，findings:195）：能持续压制本端点的用户确实可回避实时吊销，
            // 但一旦服务器曾对其签名 flagged，本地 30 天宽限窗到点即降级为受限（isReverificationLapsed），
            // 使「屏蔽复验端点」不再零成本；完全实时吊销仍以联网可达为前提，属既定权衡。
            if verifyVerdictSignature(licenseId: licenseId, deviceId: deviceId, response: decoded) {
                markFlagged(licenseId: licenseId)
            }
            return .inconclusive
        default: return .inconclusive
        }
    }

    /// 主动停用本机席位（换机/换主板前在旧机释放一个授权名额）：把 licenseId + 本机标识
    /// POST 到停用接口。成功即返回；失败抛出可读错误。调用方随后应清除本地许可文件。审计 CONTRACT (d)。
    public func deactivate(
        licenseId: String,
        deviceId: String,
    ) async throws {
        var request = URLRequest(
            url: baseURL.appendingPathComponent("api/license/deactivate"),
        )
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 20
        request.httpBody = try JSONEncoder().encode(
            DeactivateRequest(licenseId: licenseId, deviceId: deviceId),
        )

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw LicenseActivationError.network
        }
        guard let http = response as? HTTPURLResponse else {
            throw LicenseActivationError.malformedResponse
        }
        let decoded = try? JSONDecoder().decode(DeactivateResponse.self, from: data)
        if http.statusCode == 200, let body = decoded, body.ok { return }
        switch decoded?.error {
        case "not_found": throw LicenseActivationError.notFound
        default:
            throw http.statusCode >= 500
                ? LicenseActivationError.server
                : LicenseActivationError.malformedResponse
        }
    }

    /// 用共用信任根验证复验响应对 `{licenseId, deviceId, status, nonce, timestamp}` 的 Ed25519 签名。
    /// 规范签名报文（服务端须逐字节一致地签名）：`"<licenseId>\n<deviceId>\n<status>\n<nonce>\n<timestamp>"`（UTF-8）。
    /// 缺任一字段、无受信公钥、或验签不过 → false（破坏性结论因此被视为暂态，不 brick）。
    private func verifyVerdictSignature(
        licenseId: String,
        deviceId: String,
        response: ValidateResponse,
    ) -> Bool {
        guard let status = response.status,
              let sigB64 = response.signature,
              let signature = Data(base64Encoded: sigB64),
              let nonce = response.nonce,
              let timestamp = response.timestamp,
              !trustedPublicKeys.isEmpty else {
            return false
        }
        let message = Data("\(licenseId)\n\(deviceId)\n\(status)\n\(nonce)\n\(timestamp)".utf8)
        // 优先按 keyID 选公钥；服务端暂未回传 keyID 时，用全部受信公钥逐一兜底验签。
        let candidates: [Data]
        if let keyID = response.keyID, let key = trustedPublicKeys[keyID] {
            candidates = [key]
        } else {
            candidates = Array(trustedPublicKeys.values)
        }
        for raw in candidates {
            guard let publicKey = try? Curve25519.Signing.PublicKey(rawRepresentation: raw) else { continue }
            if publicKey.isValidSignature(signature, for: message) { return true }
        }
        return false
    }

    // MARK: 复验台账（与 LicenseService 共享键命名空间）

    /// 联网复验降级判定：曾被 flagged 且超过宽限期仍无成功复验 → `.limited`，否则 `.ok`。
    /// 供界面在无法达成 `LicenseService.status()` 时兜底查询；两者判据一致（同键、同宽限期）。
    public func reverificationGate(
        licenseId: String,
        now: Date = Date(),
    ) -> LicenseReverificationGate {
        let key = LicenseService.flaggedKey(licenseId)
        let flaggedAt = [defaults.object(forKey: key) as? Date, anchor.date(forKey: key)]
            .compactMap { $0 }.min()
        guard let flaggedAt else { return .ok }
        return now.timeIntervalSince(flaggedAt) > LicenseService.reverifyGraceWindow ? .limited : .ok
    }

    /// 记录一次成功的联网复验时间（单调递增，回拨系统时钟不能让其倒退）。
    private func recordSuccessfulValidation(licenseId: String, now: Date = Date()) {
        let key = LicenseService.lastValidatedKey(licenseId)
        let previous = [defaults.object(forKey: key) as? Date, anchor.date(forKey: key)]
            .compactMap { $0 }.max()
        let monotonic = max(now, previous ?? now)
        defaults.set(monotonic, forKey: key)
        anchor.set(monotonic, forKey: key)
    }

    /// 首次把某证标记为可疑：只记一次最早的 flag 时间（已存在则不覆盖，避免刷新拖延降级）。
    private func markFlagged(licenseId: String, now: Date = Date()) {
        let key = LicenseService.flaggedKey(licenseId)
        let alreadyFlagged = defaults.object(forKey: key) != nil || anchor.date(forKey: key) != nil
        guard !alreadyFlagged else { return }
        defaults.set(now, forKey: key)
        anchor.set(now, forKey: key)
    }

    /// 清除 flag：仅当服务器明确回答 active（该证确认无恙）时调用。
    private func clearFlag(licenseId: String) {
        let key = LicenseService.flaggedKey(licenseId)
        defaults.removeObject(forKey: key)
        anchor.remove(forKey: key)
    }
}
