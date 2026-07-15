import Foundation
import Shared

/// Compatibility model used by existing monitoring consumers until they migrate to
/// `ApplicationUsageSnapshot`.
public struct ProcessUsage: Sendable, Identifiable {
    public let id: Int32
    public let name: String
    public let cpuPercent: Double
    public let memoryBytes: Int64
}

public actor ProcessSampler {
    private let provider: any ProcessSnapshotProviding
    private let resolver: ApplicationOwnershipResolver
    private let aggregator: ApplicationUsageAggregator
    private var cpu = ProcessCPUDeltaCalculator()
    private var trends: [ApplicationIdentity: ApplicationUsageTrend] = [:]
    private var trendLastSeen: [ApplicationIdentity: UInt64] = [:]
    private var previousCPUOrder: [ApplicationIdentity] = []
    private var previousMemoryOrder: [ApplicationIdentity] = []
    nonisolated private let legacy = LegacyProcessSampler()

    public init(
        provider: any ProcessSnapshotProviding = LocalProcessSnapshotProvider(),
        logicalCPUCount: Int = ProcessInfo.processInfo.activeProcessorCount
    ) {
        self.provider = provider
        self.resolver = ApplicationOwnershipResolver()
        self.aggregator = ApplicationUsageAggregator(logicalCPUCount: logicalCPUCount)
    }

    public func resetBaseline() {
        cpu.reset()
    }

    public func sample(
        limit: Int = 6,
        combinesProcesses: Bool = true
    ) async -> ApplicationUsageSnapshot {
        let capture = await provider.capture()
        let cpuRates = cpu.rates(for: capture)
        let ownership = resolver.resolve(capture.records)
        let usages = aggregator.aggregate(
            records: capture.records,
            ownership: ownership,
            cpuRawByProcess: cpuRates ?? [:],
            combinesProcesses: combinesProcesses
        )

        var cpuOrder: [ApplicationUsage]
        if cpuRates == nil {
            cpuOrder = []
        } else {
            cpuOrder = UsageRanker.order(
                usages.filter { $0.cpuRawPercent != nil },
                metric: .cpu,
                previousOrder: previousCPUOrder
            )
        }
        var memoryOrder = UsageRanker.order(
            usages,
            metric: .memory,
            previousOrder: previousMemoryOrder
        )

        updateTrends(
            cpuOrder: cpuOrder,
            memoryOrder: memoryOrder,
            allCurrentIDs: Set(usages.map(\.id)),
            monotonicNanoseconds: capture.monotonicNanoseconds
        )
        cpuOrder = cpuOrder.map(attachingTrend)
        memoryOrder = memoryOrder.map(attachingTrend)

        let boundedLimit = max(0, limit)
        cpuOrder = Array(cpuOrder.prefix(boundedLimit))
        memoryOrder = Array(memoryOrder.prefix(boundedLimit))
        previousCPUOrder = cpuOrder.map(\.id)
        previousMemoryOrder = memoryOrder.map(\.id)

        let denied = capture.failures.values.filter { $0 == .permissionDenied }.count
        let exited = capture.failures.values.filter { $0 == .exited }.count
        let hasUnreadable = capture.failures.values.contains(.unreadable)
        let coverage = ProcessCoverage(
            enumerated: capture.enumeratedCount,
            sampled: capture.records.count,
            denied: denied,
            exited: exited
        )
        let status: ProcessSamplingStatus
        if capture.records.isEmpty {
            status = .unavailable
        } else if cpuRates == nil {
            status = .warmingUp
        } else if denied > 0 || hasUnreadable {
            status = .partial
        } else {
            status = .live
        }

        return ApplicationUsageSnapshot(
            byCPU: cpuOrder,
            byMemory: memoryOrder,
            status: status,
            coverage: coverage,
            sampledAt: capture.wallDate,
            source: capture.source
        )
    }

    /// Temporary source compatibility for call sites migrated in the next task.
    public nonisolated func sample(top: Int) -> (
        byCPU: [ProcessUsage],
        byMemory: [ProcessUsage]
    ) {
        legacy.sample(top: top)
    }

    /// Temporary source compatibility for the running-app optimization view.
    public nonisolated func memoryFootprint(pid: Int32) -> Int64? {
        legacy.memoryFootprint(pid: pid)
    }

    private func updateTrends(
        cpuOrder: [ApplicationUsage],
        memoryOrder: [ApplicationUsage],
        allCurrentIDs: Set<ApplicationIdentity>,
        monotonicNanoseconds: UInt64
    ) {
        let trackedUsages = Array(cpuOrder.prefix(20)) + Array(memoryOrder.prefix(20))
        let trackedByID = Dictionary(trackedUsages.map { ($0.id, $0) },
                                    uniquingKeysWith: { first, _ in first })
        let trackedIDs = Set(trackedByID.keys)

        for id in Array(trends.keys) {
            if allCurrentIDs.contains(id) {
                if !trackedIDs.contains(id) {
                    trends.removeValue(forKey: id)
                    trendLastSeen.removeValue(forKey: id)
                }
            } else if let lastSeen = trendLastSeen[id],
                      monotonicNanoseconds >= lastSeen,
                      monotonicNanoseconds - lastSeen >= 120_000_000_000 {
                trends.removeValue(forKey: id)
                trendLastSeen.removeValue(forKey: id)
            }
        }

        for (id, usage) in trackedByID {
            var trend = trends[id] ?? ApplicationUsageTrend(cpuRaw: [], memoryBytes: [])
            if let rawCPU = usage.cpuRawPercent {
                trend.cpuRaw.append(rawCPU)
                if trend.cpuRaw.count > 60 {
                    trend.cpuRaw.removeFirst(trend.cpuRaw.count - 60)
                }
            }
            trend.memoryBytes.append(usage.physicalFootprintBytes)
            if trend.memoryBytes.count > 60 {
                trend.memoryBytes.removeFirst(trend.memoryBytes.count - 60)
            }
            trends[id] = trend
            trendLastSeen[id] = monotonicNanoseconds
        }
    }

    private func attachingTrend(to usage: ApplicationUsage) -> ApplicationUsage {
        var result = usage
        result.trend = trends[usage.id] ?? ApplicationUsageTrend(cpuRaw: [], memoryBytes: [])
        return result
    }
}

private final class LegacyProcessSampler: @unchecked Sendable {
    private let lock = NSLock()
    private let enumerator = PIDEnumerator()
    private var previousCPUTime: [Int32: UInt64] = [:]
    private var previousWall: Date?

    func sample(top: Int) -> (byCPU: [ProcessUsage], byMemory: [ProcessUsage]) {
        let records = enumerator.allPIDs().compactMap { pid -> ProcessResourceRecord? in
            guard case .success(let record) = DarwinProcessResourceReader.read(pid: pid) else {
                return nil
            }
            return record
        }
        guard !records.isEmpty else { return ([], []) }

        let now = Date()
        lock.lock()
        let oldWall = previousWall
        let oldCPUTime = previousCPUTime
        lock.unlock()
        let elapsed = oldWall.map { now.timeIntervalSince($0) } ?? 0

        var nextCPUTime: [Int32: UInt64] = [:]
        var usages: [ProcessUsage] = []
        nextCPUTime.reserveCapacity(records.count)
        usages.reserveCapacity(records.count)
        for record in records {
            nextCPUTime[record.pid] = record.cpuTimeNanoseconds
            var cpuPercent = 0.0
            if elapsed > 0,
               let previous = oldCPUTime[record.pid],
               record.cpuTimeNanoseconds >= previous {
                cpuPercent = Double(record.cpuTimeNanoseconds - previous)
                    / (elapsed * 1_000_000_000) * 100
            }
            if cpuPercent < 0.05 && record.physicalFootprintBytes < 2_000_000 { continue }
            usages.append(ProcessUsage(
                id: record.pid,
                name: record.name,
                cpuPercent: cpuPercent,
                memoryBytes: record.physicalFootprintBytes
            ))
        }

        lock.lock()
        previousCPUTime = nextCPUTime
        previousWall = now
        lock.unlock()

        let boundedTop = max(0, top)
        let byCPU = usages.sorted {
            if $0.cpuPercent != $1.cpuPercent { return $0.cpuPercent > $1.cpuPercent }
            return $0.id < $1.id
        }
        let byMemory = usages.sorted {
            if $0.memoryBytes != $1.memoryBytes { return $0.memoryBytes > $1.memoryBytes }
            return $0.id < $1.id
        }
        return (Array(byCPU.prefix(boundedTop)), Array(byMemory.prefix(boundedTop)))
    }

    func memoryFootprint(pid: Int32) -> Int64? {
        guard case .success(let record) = DarwinProcessResourceReader.read(pid: pid) else {
            return nil
        }
        return record.physicalFootprintBytes
    }
}
