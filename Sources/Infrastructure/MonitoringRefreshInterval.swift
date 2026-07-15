import Foundation

public enum MonitoringRefreshInterval: Double, CaseIterable, Sendable {
    case oneSecond = 1
    case twoSeconds = 2
    case fiveSeconds = 5

    fileprivate static func closestSupported(to value: Double) -> Self {
        guard value.isFinite else { return .oneSecond }
        return allCases.min { lhs, rhs in
            let lhsDistance = abs(lhs.rawValue - value)
            let rhsDistance = abs(rhs.rawValue - value)
            if lhsDistance == rhsDistance { return lhs.rawValue < rhs.rawValue }
            return lhsDistance < rhsDistance
        } ?? .oneSecond
    }
}

public enum MonitoringRefreshIntervalStore {
    public static let key = "xico.mb.interval"

    public static func read(
        _ defaults: UserDefaults = .standard
    ) -> MonitoringRefreshInterval {
        guard defaults.object(forKey: key) != nil else { return .oneSecond }
        let stored = defaults.double(forKey: key)
        if let supported = MonitoringRefreshInterval(rawValue: stored) { return supported }
        let migrated = MonitoringRefreshInterval.closestSupported(to: stored)
        defaults.set(migrated.rawValue, forKey: key)
        return migrated
    }

    public static func write(
        _ interval: MonitoringRefreshInterval,
        _ defaults: UserDefaults = .standard
    ) {
        defaults.set(interval.rawValue, forKey: key)
    }
}
