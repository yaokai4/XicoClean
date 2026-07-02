import Foundation
import CSensors

/// 一个温度读数。
public struct TempReading: Sendable, Identifiable {
    public let id: String          // 传感器名（稳定标识）
    public let name: String        // 展示名（已本地化/简化）
    public let celsius: Double
    public let category: Category

    public enum Category: String, Sendable {
        case cpu, gpu, ssd, battery, ambient, other
    }
}

/// 一组风扇读数。
public struct FanInfo: Sendable, Identifiable {
    public let id: Int
    public let rpm: Int
    public let minimum: Int?
    public let maximum: Int?
    /// 当前转速在 [min, max] 中的比例（用于仪表）。
    public var fraction: Double {
        guard let mn = minimum, let mx = maximum, mx > mn else { return 0 }
        return min(1, max(0, Double(rpm - mn) / Double(mx - mn)))
    }
}

/// 温度传感器 + 风扇的统一读取器。
///
/// 策略（与 Stats / iSMC / TG Pro 一致）：
/// - Apple Silicon：主路径走 IOHIDEventSystemClient（CSensors 垫片）枚举全部命名温度传感器；
/// - Intel：走 SMC 温度键表（TC0P/TG0P/…）；
/// - 电池温度始终优先用 AppleSmartBattery.Temperature（最可靠，见 HardwareProfileService）；
/// - 任一路径读不到即返回空数组，UI 静默降级，绝不崩溃、绝不显示错值。
public final class SensorReader: @unchecked Sendable {
    private let smc = SMCReader()

    public init() {}

    /// 全部温度传感器（已归类、按类别聚合的代表值另见 summary()）。
    public func temperatures() -> [TempReading] {
        var out = appleSiliconTemperatures()
        if out.isEmpty {
            out = intelTemperatures()   // Intel 机型降级
        }
        return out
    }

    /// 归纳后的关键温度：CPU / GPU / SSD（若各自有传感器则取平均）。
    public func summary() -> (cpu: Double?, gpu: Double?) {
        let all = temperatures()
        func avg(_ cat: TempReading.Category) -> Double? {
            let vals = all.filter { $0.category == cat }.map(\.celsius)
            guard !vals.isEmpty else { return nil }
            return vals.reduce(0, +) / Double(vals.count)
        }
        return (avg(.cpu), avg(.gpu))
    }

    public func fans() -> [FanInfo] {
        smc.allFans().map { FanInfo(id: $0.index, rpm: $0.current, minimum: $0.minimum, maximum: $0.maximum) }
    }

    // MARK: Apple Silicon（IOHIDEventSystemClient）

    private func appleSiliconTemperatures() -> [TempReading] {
        let capacity = 128
        var buffer = [XicoTempSensor](repeating: XicoTempSensor(), count: capacity)
        let count = buffer.withUnsafeMutableBufferPointer { ptr -> Int32 in
            xico_copy_thermal_sensors(ptr.baseAddress, Int32(capacity))
        }
        guard count > 0 else { return [] }

        var out: [TempReading] = []
        for i in 0..<Int(count) {
            let sensor = buffer[i]
            let name = withUnsafeBytes(of: sensor.name) { raw -> String in
                let bytes = raw.bindMemory(to: CChar.self)
                return String(cString: bytes.baseAddress!)
            }
            guard !name.isEmpty else { continue }
            out.append(TempReading(id: name, name: prettyName(name),
                                   celsius: sensor.celsius, category: classify(name)))
        }
        return out
    }

    // 传感器名 → 类别（依据 Apple Silicon 命名惯例，参考 exelban/stats 键表）
    private func classify(_ raw: String) -> TempReading.Category {
        let n = raw.lowercased()
        if n.contains("tp") || n.contains("cpu") || n.contains("pmu tdie") || n.contains("efficiency") || n.contains("performance") { return .cpu }
        if n.contains("tg") || n.contains("gpu") { return .gpu }
        if n.contains("ssd") || n.contains("nand") || n.contains("flash") { return .ssd }
        if n.contains("batt") || n.contains("gas gauge") { return .battery }
        if n.contains("ambient") || n.contains("skin") { return .ambient }
        return .other
    }

    private func prettyName(_ raw: String) -> String {
        raw.replacingOccurrences(of: "PMU ", with: "")
    }

    // MARK: Intel（SMC 键表）

    private func intelTemperatures() -> [TempReading] {
        // 经典 Intel 温度键（读不到自动跳过）。
        let table: [(key: String, name: String, cat: TempReading.Category)] = [
            ("TC0P", "CPU 近端", .cpu),
            ("TC0D", "CPU 芯片", .cpu),
            ("TCXC", "CPU PECI", .cpu),
            ("TG0P", "GPU 近端", .gpu),
            ("TG0D", "GPU 芯片", .gpu),
            ("TM0P", "内存", .other),
            ("Ts0P", "机身", .ambient),
            ("TA0P", "环境", .ambient),
            ("TH0P", "硬盘", .ssd)
        ]
        var out: [TempReading] = []
        for row in table {
            if let t = smc.temperature(key: row.key) {
                out.append(TempReading(id: row.key, name: row.name, celsius: t, category: row.cat))
            }
        }
        return out
    }
}
