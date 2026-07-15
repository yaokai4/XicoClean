import Foundation
import Shared

public struct ProcessCPUDeltaCalculator: Sendable {
    private var previousTime: UInt64?
    private var previousCPUByProcess: [ProcessIdentity: UInt64] = [:]
    private let maximumIntervalNanoseconds: UInt64

    public init(maximumIntervalNanoseconds: UInt64 = 10_000_000_000) {
        self.maximumIntervalNanoseconds = maximumIntervalNanoseconds
    }

    public mutating func reset() {
        previousTime = nil
        previousCPUByProcess = [:]
    }

    public mutating func rates(for capture: ProcessCapture) -> [ProcessIdentity: Double]? {
        let oldTime = previousTime
        let oldCPUByProcess = previousCPUByProcess
        previousTime = capture.monotonicNanoseconds
        previousCPUByProcess = Dictionary(uniqueKeysWithValues: capture.records.map {
            (ProcessIdentity(pid: $0.pid, startTimeNanoseconds: $0.startTimeNanoseconds),
             $0.cpuTimeNanoseconds)
        })

        guard let oldTime,
              capture.monotonicNanoseconds > oldTime else { return nil }
        let interval = capture.monotonicNanoseconds - oldTime
        guard interval <= maximumIntervalNanoseconds else { return nil }

        let elapsed = Double(interval)
        var rates: [ProcessIdentity: Double] = [:]
        rates.reserveCapacity(capture.records.count)
        for record in capture.records {
            let identity = ProcessIdentity(
                pid: record.pid,
                startTimeNanoseconds: record.startTimeNanoseconds
            )
            guard let previous = oldCPUByProcess[identity],
                  record.cpuTimeNanoseconds >= previous else { continue }
            let delta = Double(record.cpuTimeNanoseconds - previous)
            rates[identity] = delta / elapsed * 100
        }
        return rates
    }
}

public struct ApplicationUsageAggregator: Sendable {
    private let logicalCPUCount: Int

    public init(logicalCPUCount: Int) {
        self.logicalCPUCount = max(1, logicalCPUCount)
    }

    public func aggregate(
        records: [ProcessResourceRecord],
        ownership: [ProcessIdentity: ResolvedApplicationOwnership],
        cpuRawByProcess: [ProcessIdentity: Double],
        combinesProcesses: Bool
    ) -> [ApplicationUsage] {
        struct Group {
            let ownership: ResolvedApplicationOwnership
            var records: [ProcessResourceRecord]
        }

        var groups: [ApplicationIdentity: Group] = [:]
        for record in records {
            let process = ProcessIdentity(
                pid: record.pid,
                startTimeNanoseconds: record.startTimeNanoseconds
            )
            guard let resolved = ownership[process] else { continue }
            let groupIdentity = combinesProcesses
                ? resolved.identity
                : ApplicationIdentity(
                    rawValue: "process:\(record.pid):\(record.startTimeNanoseconds)"
                )
            if groups[groupIdentity] == nil {
                let groupOwnership = ResolvedApplicationOwnership(
                    identity: groupIdentity,
                    displayName: resolved.displayName,
                    bundleIdentifier: resolved.bundleIdentifier,
                    bundlePath: resolved.bundlePath
                )
                groups[groupIdentity] = Group(ownership: groupOwnership, records: [])
            }
            groups[groupIdentity]?.records.append(record)
        }

        return groups.values.map { group in
            let sortedRecords = group.records.sorted { lhs, rhs in
                if lhs.parentPID == rhs.pid { return false }
                if rhs.parentPID == lhs.pid { return true }
                return lhs.pid < rhs.pid
            }
            let members = sortedRecords.map { record in
                let identity = ProcessIdentity(
                    pid: record.pid,
                    startTimeNanoseconds: record.startTimeNanoseconds
                )
                return ApplicationMemberUsage(
                    identity: identity,
                    name: record.name,
                    cpuRawPercent: cpuRawByProcess[identity],
                    physicalFootprintBytes: record.physicalFootprintBytes
                )
            }
            let knownCPU = members.compactMap(\.cpuRawPercent)
            let rawCPU = knownCPU.isEmpty ? nil : knownCPU.reduce(0, +)
            return ApplicationUsage(
                id: group.ownership.identity,
                displayName: group.ownership.displayName,
                bundleIdentifier: group.ownership.bundleIdentifier,
                bundlePath: group.ownership.bundlePath,
                representativePID: sortedRecords.first?.pid ?? 0,
                members: members,
                cpuRawPercent: rawCPU,
                cpuNormalizedPercent: rawCPU.map {
                    min(100, $0 / Double(logicalCPUCount))
                },
                physicalFootprintBytes: sortedRecords.reduce(0) {
                    $0 + $1.physicalFootprintBytes
                },
                peakFootprintBytes: sortedRecords.reduce(0) {
                    $0 + $1.peakFootprintBytes
                },
                trend: ApplicationUsageTrend(cpuRaw: [], memoryBytes: [])
            )
        }.sorted {
            let lhsCPU = $0.cpuRawPercent ?? -.infinity
            let rhsCPU = $1.cpuRawPercent ?? -.infinity
            if lhsCPU != rhsCPU { return lhsCPU > rhsCPU }
            return $0.id.rawValue < $1.id.rawValue
        }
    }
}

public enum ApplicationUsageMetric: Sendable {
    case cpu
    case memory
}

public enum UsageRanker {
    public static func order(
        _ usages: [ApplicationUsage],
        metric: ApplicationUsageMetric,
        previousOrder: [ApplicationIdentity]
    ) -> [ApplicationUsage] {
        let priorIndex = Dictionary(
            uniqueKeysWithValues: previousOrder.enumerated().map { ($0.element, $0.offset) }
        )

        func value(_ usage: ApplicationUsage) -> Double? {
            switch metric {
            case .cpu: return usage.cpuRawPercent
            case .memory: return Double(usage.physicalFootprintBytes)
            }
        }

        return usages.sorted { lhs, rhs in
            let lhsValue = value(lhs)
            let rhsValue = value(rhs)
            switch (lhsValue, rhsValue) {
            case let (lhsValue?, rhsValue?):
                let larger = max(lhsValue, rhsValue)
                if abs(lhsValue - rhsValue) > larger * 0.03 {
                    return lhsValue > rhsValue
                }
            case (_?, nil):
                return true
            case (nil, _?):
                return false
            case (nil, nil):
                break
            }

            if let lhsIndex = priorIndex[lhs.id], let rhsIndex = priorIndex[rhs.id],
               lhsIndex != rhsIndex {
                return lhsIndex < rhsIndex
            }
            return lhs.id.rawValue < rhs.id.rawValue
        }
    }
}
