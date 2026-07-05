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
}
