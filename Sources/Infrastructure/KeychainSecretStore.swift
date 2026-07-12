import Foundation
import Security

/// 通用 Keychain 机密存储（供服务器套件存 SSH 密码 / 私钥用）。
///
/// 复用与 `KeychainAnchorStore` 完全相同的 `SecItem*` 模式，但存任意 `Data`/`String`（而非仅 `Date`），
/// 用独立 service 命名空间 `com.xico.app.ssh`，按 host id 派生 account key。
/// 可访问性用 `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`——本机、首次解锁后可读、不随备份迁移。
///
/// 诚实边界（与 SecureAnchorStore 一致）：非沙盒应用的本机 Keychain 对能开终端的用户并非绝对防篡改；
/// 这里只保证「凭据不落在明文 JSON / 不进日志 / 不进 URL」，并优先引导用户用密钥而非密码。
public struct KeychainSecretStore: Sendable {
    private let service: String
    public init(service: String = "com.xico.app.ssh") { self.service = service }

    private func baseQuery(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    // MARK: 读

    public func data(forKey account: String) -> Data? {
        var q = baseQuery(account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return d
    }

    public func string(forKey account: String) -> String? {
        data(forKey: account).flatMap { String(data: $0, encoding: .utf8) }
    }

    public func hasSecret(forKey account: String) -> Bool {
        SecItemCopyMatching(baseQuery(account) as CFDictionary, nil) == errSecSuccess
    }

    // MARK: 写

    @discardableResult
    public func set(_ data: Data, forKey account: String) -> Bool {
        let base = baseQuery(account)
        if SecItemCopyMatching(base as CFDictionary, nil) == errSecSuccess {
            let update: [String: Any] = [kSecValueData as String: data]
            return SecItemUpdate(base as CFDictionary, update as CFDictionary) == errSecSuccess
        } else {
            var add = base
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
        }
    }

    @discardableResult
    public func set(_ string: String, forKey account: String) -> Bool {
        set(Data(string.utf8), forKey: account)
    }

    public func remove(forKey account: String) {
        SecItemDelete(baseQuery(account) as CFDictionary)
    }

    // MARK: 派生 key（按 host id）

    /// 密码项：`pw.<hostID>`
    public static func passwordKey(_ hostID: UUID) -> String { "pw.\(hostID.uuidString)" }
    /// 私钥项：`pk.<ref>`（ref 可为 host id 或用户命名的密钥别名）
    public static func privateKeyKey(_ ref: String) -> String { "pk.\(ref)" }
    /// 私钥口令项。
    public static func passphraseKey(_ ref: String) -> String { "pkpass.\(ref)" }
}
