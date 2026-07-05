import Foundation
import IOKit

/// 稳定的本机标识，用于在线激活时的「授权台数」绑定。
/// 优先用硬件 UUID（重装系统仍不变，避免重装白白吃掉一个名额）；
/// 取不到时回落到持久化的随机 UUID（每次安装稳定）。不含任何可识别个人信息。
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
    private static func persistentFallback() -> String {
        let defaults = UserDefaults.standard
        if let existing = defaults.string(forKey: fallbackKey), !existing.isEmpty {
            return existing
        }
        let fresh = UUID().uuidString
        defaults.set(fresh, forKey: fallbackKey)
        return fresh
    }
}
