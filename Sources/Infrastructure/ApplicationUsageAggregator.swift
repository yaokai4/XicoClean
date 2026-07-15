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
            func processIdentityPrecedes(
                _ lhs: ProcessResourceRecord,
                _ rhs: ProcessResourceRecord
            ) -> Bool {
                if lhs.pid != rhs.pid { return lhs.pid < rhs.pid }
                if lhs.startTimeNanoseconds != rhs.startTimeNanoseconds {
                    return lhs.startTimeNanoseconds < rhs.startTimeNanoseconds
                }
                if lhs.name != rhs.name { return lhs.name < rhs.name }
                return (lhs.executablePath ?? "") < (rhs.executablePath ?? "")
            }

            let recordsByPID = Dictionary(
                uniqueKeysWithValues: group.records.map { ($0.pid, $0) }
            )
            let roots = group.records.filter { recordsByPID[$0.parentPID] == nil }
            let representative = roots.min(by: processIdentityPrecedes)
                ?? group.records.min(by: processIdentityPrecedes)

            func hierarchyDepth(of record: ProcessResourceRecord) -> Int {
                var current = record
                var visited: Set<Int32> = [record.pid]
                var depth = 0
                while let parent = recordsByPID[current.parentPID] {
                    guard visited.insert(parent.pid).inserted else { return Int.max }
                    current = parent
                    depth += 1
                }
                return depth
            }

            let sortedRecords = group.records.sorted { lhs, rhs in
                let lhsDepth = hierarchyDepth(of: lhs)
                let rhsDepth = hierarchyDepth(of: rhs)
                if lhsDepth != rhsDepth { return lhsDepth < rhsDepth }
                return processIdentityPrecedes(lhs, rhs)
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
                representativePID: representative?.pid ?? 0,
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
        var priorIndex: [ApplicationIdentity: Int] = [:]
        for (index, identity) in previousOrder.enumerated() where priorIndex[identity] == nil {
            priorIndex[identity] = index
        }

        func value(_ usage: ApplicationUsage) -> Double? {
            switch metric {
            case .cpu: return usage.cpuRawPercent
            case .memory: return Double(usage.physicalFootprintBytes)
            }
        }

        func mustPrecede(_ lhs: ApplicationUsage, _ rhs: ApplicationUsage) -> Bool {
            switch (value(lhs), value(rhs)) {
            case let (lhsValue?, rhsValue?):
                guard lhsValue > rhsValue else { return false }
                return lhsValue - rhsValue > lhsValue * 0.03
            case (_?, nil):
                return true
            case (nil, _?), (nil, nil):
                return false
            }
        }

        func stablePriority(_ lhs: Int, _ rhs: Int) -> Bool {
            let lhsPrior = priorIndex[usages[lhs].id] ?? Int.max
            let rhsPrior = priorIndex[usages[rhs].id] ?? Int.max
            if lhsPrior != rhsPrior { return lhsPrior < rhsPrior }
            if usages[lhs].id.rawValue != usages[rhs].id.rawValue {
                return usages[lhs].id.rawValue < usages[rhs].id.rawValue
            }
            return lhs < rhs
        }

        // Metric differences outside the hysteresis band are mandatory edges in an
        // acyclic graph. Previous order is only used to choose among currently
        // unconstrained rows, so it can never create a comparator cycle.
        var successors = [[Int]](repeating: [], count: usages.count)
        var indegree = [Int](repeating: 0, count: usages.count)
        for lhs in usages.indices {
            for rhs in usages.indices where rhs > lhs {
                if mustPrecede(usages[lhs], usages[rhs]) {
                    successors[lhs].append(rhs)
                    indegree[rhs] += 1
                } else if mustPrecede(usages[rhs], usages[lhs]) {
                    successors[rhs].append(lhs)
                    indegree[lhs] += 1
                }
            }
        }

        var ready = usages.indices.filter { indegree[$0] == 0 }
        var ordered: [ApplicationUsage] = []
        ordered.reserveCapacity(usages.count)
        while let next = ready.min(by: stablePriority) {
            ready.remove(at: ready.firstIndex(of: next)!)
            ordered.append(usages[next])
            for successor in successors[next] {
                indegree[successor] -= 1
                if indegree[successor] == 0 { ready.append(successor) }
            }
        }
        return ordered
    }
}
