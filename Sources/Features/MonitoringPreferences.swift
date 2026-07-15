import Foundation

public enum MonitoringPreferences {
    private static let processLimitKey = "xico.monitoring.processLimit"
    private static let combinesProcessesKey = "xico.monitoring.combinesProcesses"
    private static let supportedProcessLimits = Set([4, 6, 10, 20])

    public static func processLimit() -> Int {
        let value = UserDefaults.standard.integer(forKey: processLimitKey)
        return supportedProcessLimits.contains(value) ? value : 6
    }

    public static func combinesProcesses() -> Bool {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: combinesProcessesKey) != nil else { return true }
        return defaults.bool(forKey: combinesProcessesKey)
    }
}
