import Foundation
import IOKit
import Security

/// 稳定的本机标识，用于在线激活时的「授权台数」绑定，以及签名许可的设备绑定
/// （服务端把此值印进 `LicensePayload.deviceId`，App 侧 `LicenseService.validate` 复核）。
///
/// 派生规则（稳定性 & 唯一性）：
///  - 首选 `IOPlatformUUID`（IOPlatformExpertDevice 的硬件 UUID）：每台 Mac 出厂唯一、
///    重装系统/升级 App 均不变——避免重装白白吃掉一个授权名额，也让设备绑定跨启动稳定。
///  - 取不到时回落到一次生成、持久化在 UserDefaults 的随机 UUID：同一安装内跨启动稳定，
///    唯一性由 UUID v4 保证。换机/抹盘会变（此时用户在新机重新「激活」即可，服务端重签）。
///
/// 隐私（如实告知，勿过度弱化）：本标识是一枚**持久的硬件标识符**——它跨系统重装存活，
/// 在激活与每 ~3 天的在线复验时上送授权后端，并在服务端与该客户的购买身份（Stripe）关联，
/// 用于「授权台数」绑定。它不含姓名/邮箱等直接 PII，但作为稳定标识仍属应披露的数据采集：
/// 采集目的与范围已在激活界面（`PricingView`）以隐私说明 + 隐私政策链接向用户明示。
/// 注意：历史版本在线激活曾把主机名（`Host.current().localizedName`，可能含用户真名）作为
/// `deviceName` 一并上送——该 PII 已由 WS1 在调用端脱敏/移除；`DeviceIdentity` 自身从不采集主机名。
/// 备注：可选的「上送前用产品盐做单向哈希」增强未在此启用——存量设备绑定许可的 `deviceId`
/// 已印入原始 UUID，改变本函数返回值会令这些许可失配而误伤付费用户；如启用须与服务端同步迁移。
public enum DeviceIdentity {
    public static func current() -> String {
        hardwareUUID() ?? persistentFallback()
    }

    private static func hardwareUUID() -> String? {
        let service = IOServiceGetMatchingService(
            kIOMainPortDefault,
            IOServiceMatching("IOPlatformExpertDevice"),
        )
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        guard
            let cf = IORegistryEntryCreateCFProperty(
                service, "IOPlatformUUID" as CFString, kCFAllocatorDefault, 0,
            )?.takeRetainedValue(),
            let uuid = cf as? String, !uuid.isEmpty
        else { return nil }
        return uuid
    }

    private static let fallbackKey = "xico.device.id"
    private static let keychainService = "com.xico.app.device"

    /// 回落设备标识（取不到硬件 UUID 时）。**双副本 + earliest-value-wins（审计 P3）**：
    /// 除 UserDefaults 外，另在钥匙串（ThisDeviceOnly）留一份镜像。一处已有值即沿用、绝不新生——
    /// 因此一条 `defaults delete` 抹掉偏好副本也不能重置本机标识（钥匙串副本存活并回填），
    /// 与 trialStartedAt/吊销名单等反滥用锚点一致。钥匙串副本优先（更耐抹除）。
    /// ThisDeviceOnly：绝不随 iCloud/加密备份迁移到别的机器，避免「拷贝钥匙串」搬走设备身份。
    private static func persistentFallback() -> String {
        let defaults = UserDefaults.standard
        let fromDefaults = defaults.string(forKey: fallbackKey).flatMap { $0.isEmpty ? nil : $0 }
        let fromKeychain = keychainFallback()
        if let existing = fromKeychain ?? fromDefaults {
            // 回填缺失的副本，保证两处一致（任一副本已存在即沿用，稳定跨 defaults 抹除）。
            if fromKeychain == nil { setKeychainFallback(existing) }
            if fromDefaults == nil { defaults.set(existing, forKey: fallbackKey) }
            return existing
        }
        let fresh = UUID().uuidString
        defaults.set(fresh, forKey: fallbackKey)
        setKeychainFallback(fresh)
        return fresh
    }

    private static func keychainFallback() -> String? {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: fallbackKey,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data,
              let str = String(data: data, encoding: .utf8), !str.isEmpty else { return nil }
        return str
    }

    private static func setKeychainFallback(_ value: String) {
        let data = Data(value.utf8)
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: fallbackKey,
        ]
        if SecItemCopyMatching(base as CFDictionary, nil) == errSecSuccess {
            SecItemUpdate(base as CFDictionary, [
                kSecValueData as String: data,
                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            ] as CFDictionary)
        } else {
            var add = base
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            SecItemAdd(add as CFDictionary, nil)
        }
    }
}
