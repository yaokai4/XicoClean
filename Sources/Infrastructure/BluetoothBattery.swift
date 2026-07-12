import Foundation
import IOKit

/// 一台带电量读数的蓝牙外设（AirPods / 妙控键盘 / 妙控鼠标 / 触控板等）。
public struct BluetoothPeripheral: Identifiable, Sendable, Equatable {
    public let id: String
    public let name: String
    /// 0...100 的真实电量百分比（IORegistry 上报）。
    public let batteryPercent: Int

    public init(id: String, name: String, batteryPercent: Int) {
        self.id = id
        self.name = name
        self.batteryPercent = batteryPercent
    }
}

/// 蓝牙外设电量读取（对标 iStat 的 Bluetooth 面板）：
/// 枚举 IORegistry 的 `AppleDeviceManagementHIDEventService`，逐个读取
/// `BatteryPercent`(Int) 与 `Product`(String)。任何一步读不到都直接跳过该设备，
/// 无匹配服务时返回空数组——绝不崩溃、绝不编造数字。
/// 无状态纯读取，可在任意后台队列调用。
public final class BluetoothBatteryReader: Sendable {
    public init() {}

    public func peripherals() -> [BluetoothPeripheral] {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault,
                                           IOServiceMatching("AppleDeviceManagementHIDEventService"),
                                           &iterator) == KERN_SUCCESS, iterator != 0 else { return [] }
        defer { IOObjectRelease(iterator) }

        var out: [BluetoothPeripheral] = []
        var seen = Set<String>()
        var service = IOIteratorNext(iterator)
        while service != 0 {
            // 同一设备可能挂多个 HID 服务（键盘+触控条等）——按产品名去重，取首个读数。
            if let percent = ioRegInt(service, "BatteryPercent"), (0...100).contains(percent),
               let name = ioRegString(service, "Product"), !name.isEmpty, !seen.contains(name) {
                seen.insert(name)
                out.append(BluetoothPeripheral(id: name, name: name, batteryPercent: percent))
            }
            IOObjectRelease(service)
            service = IOIteratorNext(iterator)
        }
        // 名称排序：读数会随时间变化，按名字排能让行序稳定不跳。
        return out.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    // MARK: IORegistry 属性读取（与 HardwareProfileService 同款 takeRetainedValue 写法）

    private func ioRegInt(_ service: io_object_t, _ key: String) -> Int? {
        guard let prop = IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0) else { return nil }
        return (prop.takeRetainedValue() as? NSNumber)?.intValue
    }

    private func ioRegString(_ service: io_object_t, _ key: String) -> String? {
        guard let prop = IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0) else { return nil }
        return prop.takeRetainedValue() as? String
    }
}
