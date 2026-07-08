import Foundation
import DesignSystem

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

    public init(
        baseURL: URL = LicenseService.activationBaseURL(),
        session: URLSession = .shared,
    ) {
        self.baseURL = baseURL
        self.session = session
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

    /// 定期在线复验：询问服务器该许可证当前状态。设计为「疑罪从无」——
    /// 只有服务器明确回答 revoked/refunded 才返回 `.revoked`；断网、超时、
    /// 5xx、404（库中查无，可能是服务端数据迁移）都返回 `.inconclusive`，
    /// 绝不因此惩罚正版用户。
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
        case "active": return .valid
        case "revoked", "refunded": return .revoked
        default: return .inconclusive
        }
    }
}
