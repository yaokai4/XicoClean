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
        var currentCPUByProcess: [ProcessIdentity: UInt64] = [:]
        currentCPUByProcess.reserveCapacity(capture.records.count)
        for record in capture.records {
            currentCPUByProcess[ProcessIdentity(
                pid: record.pid,
                startTimeNanoseconds: record.startTimeNanoseconds
            )] = record.cpuTimeNanoseconds
        }
        previousCPUByProcess = currentCPUByProcess

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
        combinesProcesses: Bool,
        sortsByCPU: Bool = true
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

        let aggregated = groups.values.map { group in
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

            let representative: ProcessResourceRecord?
            let sortedRecords: [ProcessResourceRecord]
            if group.records.count == 1 {
                representative = group.records[0]
                sortedRecords = group.records
            } else {
                let recordsByPID = Dictionary(
                    uniqueKeysWithValues: group.records.map { ($0.pid, $0) }
                )
                let roots = group.records.filter { recordsByPID[$0.parentPID] == nil }
                representative = roots.min(by: processIdentityPrecedes)
                    ?? group.records.min(by: processIdentityPrecedes)

                var depthByPID: [Int32: Int] = [:]
                depthByPID.reserveCapacity(group.records.count)
                var visiting: Set<Int32> = []
                func hierarchyDepth(pid: Int32) -> Int {
                    if let cached = depthByPID[pid] { return cached }
                    guard let record = recordsByPID[pid],
                          let parent = recordsByPID[record.parentPID] else {
                        depthByPID[pid] = 0
                        return 0
                    }
                    guard visiting.insert(pid).inserted else { return Int.max }
                    let parentDepth = hierarchyDepth(pid: parent.pid)
                    visiting.remove(pid)
                    let depth = parentDepth == Int.max ? Int.max : parentDepth + 1
                    depthByPID[pid] = depth
                    return depth
                }
                for record in group.records {
                    _ = hierarchyDepth(pid: record.pid)
                }
                sortedRecords = group.records.sorted { lhs, rhs in
                    let lhsDepth = depthByPID[lhs.pid] ?? Int.max
                    let rhsDepth = depthByPID[rhs.pid] ?? Int.max
                    if lhsDepth != rhsDepth { return lhsDepth < rhsDepth }
                    return processIdentityPrecedes(lhs, rhs)
                }
            }
            var members: [ApplicationMemberUsage] = []
            members.reserveCapacity(sortedRecords.count)
            var rawCPU = 0.0
            var hasCPU = false
            var physicalFootprintBytes: Int64 = 0
            var peakFootprintBytes: Int64 = 0
            for record in sortedRecords {
                let identity = ProcessIdentity(
                    pid: record.pid,
                    startTimeNanoseconds: record.startTimeNanoseconds
                )
                let processCPU = cpuRawByProcess[identity]
                if let processCPU {
                    rawCPU += processCPU
                    hasCPU = true
                }
                physicalFootprintBytes += record.physicalFootprintBytes
                peakFootprintBytes += record.peakFootprintBytes
                members.append(ApplicationMemberUsage(
                    identity: identity,
                    name: record.name,
                    cpuRawPercent: processCPU,
                    physicalFootprintBytes: record.physicalFootprintBytes
                ))
            }
            let aggregateCPU = hasCPU ? rawCPU : nil
            return ApplicationUsage(
                id: group.ownership.identity,
                displayName: group.ownership.displayName,
                bundleIdentifier: group.ownership.bundleIdentifier,
                bundlePath: group.ownership.bundlePath,
                representativePID: representative?.pid ?? 0,
                members: members,
                cpuRawPercent: aggregateCPU,
                cpuNormalizedPercent: aggregateCPU.map {
                    min(100, $0 / Double(logicalCPUCount))
                },
                physicalFootprintBytes: physicalFootprintBytes,
                peakFootprintBytes: peakFootprintBytes,
                trend: ApplicationUsageTrend(cpuRaw: [], memoryBytes: [])
            )
        }
        guard sortsByCPU else { return aggregated }
        return aggregated.sorted {
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
        previousOrder: [ApplicationIdentity],
        limit: Int? = nil
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

        let metricValues = usages.map(value)
        let stablePriorities = usages.enumerated().map { index, usage in
            (
                prior: priorIndex[usage.id] ?? Int.max,
                identity: usage.id.rawValue,
                index: index
            )
        }

        func stablePriority(_ lhs: Int, _ rhs: Int) -> Bool {
            let lhsPriority = stablePriorities[lhs]
            let rhsPriority = stablePriorities[rhs]
            if lhsPriority.prior != rhsPriority.prior {
                return lhsPriority.prior < rhsPriority.prior
            }
            if lhsPriority.identity != rhsPriority.identity {
                return lhsPriority.identity < rhsPriority.identity
            }
            return lhsPriority.index < rhsPriority.index
        }

        let outputCount = min(usages.count, max(0, limit ?? usages.count))

        // Preserve the public ranker's exact Optional/non-finite semantics. The
        // production CPU path removes nils and produces finite deltas, while the
        // memory path is finite, so unusual values can use the graph reference
        // implementation without affecting the menu hot path.
        if metricValues.contains(where: { $0?.isFinite == false }) {
            func mustPrecede(_ lhs: Int, _ rhs: Int) -> Bool {
                switch (metricValues[lhs], metricValues[rhs]) {
                case let (lhsValue?, rhsValue?):
                    guard lhsValue > rhsValue else { return false }
                    return lhsValue - rhsValue > lhsValue * 0.03
                case (_?, nil):
                    return true
                case (nil, _?), (nil, nil):
                    return false
                }
            }

            var successors = [[Int]](repeating: [], count: usages.count)
            var indegree = [Int](repeating: 0, count: usages.count)
            for lhs in usages.indices {
                for rhs in usages.indices where rhs > lhs {
                    if mustPrecede(lhs, rhs) {
                        successors[lhs].append(rhs)
                        indegree[rhs] += 1
                    } else if mustPrecede(rhs, lhs) {
                        successors[rhs].append(lhs)
                        indegree[lhs] += 1
                    }
                }
            }

            var ready = usages.indices.filter { indegree[$0] == 0 }
            var ordered: [ApplicationUsage] = []
            ordered.reserveCapacity(outputCount)
            while ordered.count < outputCount,
                  let next = ready.min(by: stablePriority) {
                ready.remove(at: ready.firstIndex(of: next)!)
                ordered.append(usages[next])
                for successor in successors[next] {
                    indegree[successor] -= 1
                    if indegree[successor] == 0 { ready.append(successor) }
                }
            }
            return ordered
        }

        // For a finite, non-negative metric, a row has no incoming mandatory edge
        // exactly when it is inside the 3% band of the current maximum. Selecting
        // the stable-priority row from that set is therefore the same Kahn order as
        // building every edge, while avoiding the O(n²) graph for a short menu.
        var ordered: [ApplicationUsage] = []
        ordered.reserveCapacity(outputCount)
        var selected = [Bool](repeating: false, count: usages.count)
        while ordered.count < outputCount {
            var maximum: Int?
            for index in usages.indices where !selected[index] {
                guard let candidate = metricValues[index], candidate.isFinite else { continue }
                if let current = maximum,
                   let currentValue = metricValues[current],
                   candidate <= currentValue {
                    continue
                }
                maximum = index
            }
            var next: Int?
            for index in usages.indices where !selected[index] {
                let isReady: Bool
                if let maximum,
                   let maximumValue = metricValues[maximum] {
                    guard let metricValue = metricValues[index] else { continue }
                    isReady = !metricValue.isFinite
                        || maximumValue <= metricValue
                        || maximumValue - metricValue <= maximumValue * 0.03
                } else {
                    isReady = true
                }
                if isReady, next == nil || stablePriority(index, next!) {
                    next = index
                }
            }
            guard let next else { break }
            selected[next] = true
            ordered.append(usages[next])
        }
        return ordered
    }
}
