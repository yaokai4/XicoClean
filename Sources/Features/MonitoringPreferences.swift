import Foundation
import Domain
import Infrastructure

public enum MonitoringPanelDensity: String, CaseIterable, Sendable {
    case compact
    case balanced
    case detailed
}

public enum MonitoringPreferences {
    public static let cpuModeKey = "xico.monitor.cpuMode"
    public static let combinesProcessesKey = "xico.monitor.combinesProcesses"
    public static let processLimitKey = "xico.monitor.processLimit"
    public static let densityKey = "xico.monitor.density"
    public static let memoryUnitKey = "xico.monitor.memoryUnit"

    private static let legacyCombinesProcessesKey = "xico.monitoring.combinesProcesses"
    private static let legacyProcessLimitKey = "xico.monitoring.processLimit"
    private static let supportedProcessLimits = Set([4, 6, 10, 20])

    public static func cpuMode(_ defaults: UserDefaults = .standard) -> CPUDisplayMode {
        CPUDisplayMode(rawValue: defaults.string(forKey: cpuModeKey) ?? "normalized") ?? .normalized
    }

    public static func combinesProcesses(_ defaults: UserDefaults = .standard) -> Bool {
        if defaults.object(forKey: combinesProcessesKey) != nil {
            return defaults.bool(forKey: combinesProcessesKey)
        }
        if defaults.object(forKey: legacyCombinesProcessesKey) != nil {
            return defaults.bool(forKey: legacyCombinesProcessesKey)
        }
        return true
    }

    public static func processLimit(_ defaults: UserDefaults = .standard) -> Int {
        let key = defaults.object(forKey: processLimitKey) == nil
            ? legacyProcessLimitKey
            : processLimitKey
        let value = defaults.integer(forKey: key)
        return supportedProcessLimits.contains(value) ? value : 6
    }

    public static func density(_ defaults: UserDefaults = .standard) -> MonitoringPanelDensity {
        MonitoringPanelDensity(rawValue: defaults.string(forKey: densityKey) ?? "balanced") ?? .balanced
    }

    public static func memoryUnit(_ defaults: UserDefaults = .standard) -> MemoryUnitStyle {
        MemoryUnitStyle(rawValue: defaults.string(forKey: memoryUnitKey) ?? "binary") ?? .binary
    }
}
