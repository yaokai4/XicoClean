import Foundation
import Security

/// 试用期防篡改所需的「安全锚点」存储：与 UserDefaults 相互独立的第二副本。
/// 试用起始时间取两个来源中的**最早值**——删掉 UserDefaults 并不能重置试用。
public protocol SecureAnchorStore: Sendable {
    func date(forKey key: String) -> Date?
    func set(_ date: Date, forKey key: String)
    func removeAll()
}

/// 基于系统钥匙串的实现（非沙盒 App 可用）。存储为 timeIntervalSinceReferenceDate 的字符串。
public struct KeychainAnchorStore: SecureAnchorStore {
    private let service: String
    public init(service: String = "com.xico.app.anchor") { self.service = service }

    private func query(_ key: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: key]
    }

    public func date(forKey key: String) -> Date? {
        var q = query(key)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data,
              let str = String(data: data, encoding: .utf8),
              let ti = TimeInterval(str) else { return nil }
        return Date(timeIntervalSinceReferenceDate: ti)
    }

    public func set(_ date: Date, forKey key: String) {
        let data = Data(String(date.timeIntervalSinceReferenceDate).utf8)
        let base = query(key)
        let status = SecItemCopyMatching(base as CFDictionary, nil)
        if status == errSecSuccess {
            SecItemUpdate(base as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        } else {
            var add = base
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            SecItemAdd(add as CFDictionary, nil)
        }
    }

    public func removeAll() {
        SecItemDelete([kSecClass as String: kSecClassGenericPassword,
                       kSecAttrService as String: service] as CFDictionary)
    }
}

/// 内存实现（测试注入，避免污染真实钥匙串）。
public final class InMemoryAnchorStore: SecureAnchorStore, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: Date] = [:]
    public init(_ seed: [String: Date] = [:]) { storage = seed }
    public func date(forKey key: String) -> Date? {
        lock.lock(); defer { lock.unlock() }; return storage[key]
    }
    public func set(_ date: Date, forKey key: String) {
        lock.lock(); storage[key] = date; lock.unlock()
    }
    public func removeAll() { lock.lock(); storage.removeAll(); lock.unlock() }
}
