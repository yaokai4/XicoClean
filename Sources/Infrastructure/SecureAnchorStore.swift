import Foundation
import Security

/// 试用期防滥用所需的「安全锚点」存储：与 UserDefaults 相互独立的第二副本。
/// 试用起始时间取两个来源中的**最早值**——单删 UserDefaults（`defaults delete`）并不能重置试用。
///
/// 定位要如实：本机为**非沙盒** App，钥匙串项对拥有 Terminal 访问权的本机用户并非不可篡改——
/// 有决心者仍可用 `security delete-generic-password` 抹掉锚点重置试用（详见审计 SecureAnchorStore P3）。
/// 因此这是「抬高门槛、拦住顺手的 `defaults delete`」的双副本冗余，**而非**防篡改保证；
/// 要根除本地重置，唯有把试用起点落到服务端（按设备/硬件 id 建账），此处不实现、作为已知限制接受。
public protocol SecureAnchorStore: Sendable {
    func date(forKey key: String) -> Date?
    func set(_ date: Date, forKey key: String)
    func remove(forKey key: String)
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
            // 顺带把可访问性收敛到「仅本机」——存量项（曾以 AfterFirstUnlock 写入）在此升级，
            // 从此不再随加密备份迁移到其它机器。
            SecItemUpdate(base as CFDictionary, [
                kSecValueData as String: data,
                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            ] as CFDictionary)
        } else {
            var add = base
            add[kSecValueData as String] = data
            // 仅本机可访问：试用锚点 / 吊销名单 / 设备绑定台账绝不随 iCloud/加密备份迁移到别的机器，
            // 否则「拷贝钥匙串」就能把绑定与吊销状态搬走。取不到（首解锁前）时读返回 nil，逻辑已优雅兜底。
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            SecItemAdd(add as CFDictionary, nil)
        }
    }

    public func remove(forKey key: String) {
        SecItemDelete(query(key) as CFDictionary)
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
    public func remove(forKey key: String) {
        lock.lock(); storage[key] = nil; lock.unlock()
    }
    public func removeAll() { lock.lock(); storage.removeAll(); lock.unlock() }
}
