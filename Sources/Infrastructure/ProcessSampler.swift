import Foundation
import Shared

/// Compatibility model used by existing monitoring consumers until they migrate to
/// `ApplicationUsageSnapshot`.
public struct ProcessUsage: Sendable, Identifiable {
    public let id: Int32
    public let name: String
    public let cpuPercent: Double
    public let memoryBytes: Int64

    public init(id: Int32, name: String, cpuPercent: Double, memoryBytes: Int64) {
        self.id = id
        self.name = name
        self.cpuPercent = cpuPercent
        self.memoryBytes = memoryBytes
    }
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
    private var baselineEpoch: UInt64 = 0
    private var sampleInProgress = false
    private var sampleWaiters: [CheckedContinuation<Void, Never>] = []
    nonisolated private let legacy: LegacyProcessSampler

    public init(
        provider: any ProcessSnapshotProviding = HybridProcessSnapshotProvider(),
        logicalCPUCount: Int = ProcessInfo.processInfo.activeProcessorCount
    ) {
        self.provider = provider
        self.resolver = ApplicationOwnershipResolver()
        self.aggregator = ApplicationUsageAggregator(logicalCPUCount: logicalCPUCount)
        self.legacy = LegacyProcessSampler()
    }

    public nonisolated static func production(
        local: any ProcessSnapshotProviding = LocalProcessSnapshotProvider(),
        helper: any PrivilegedProcessSampling = HelperProxy(),
        logicalCPUCount: Int = ProcessInfo.processInfo.activeProcessorCount
    ) -> ProcessSampler {
        ProcessSampler(
            provider: HybridProcessSnapshotProvider(local: local, helper: helper),
            logicalCPUCount: logicalCPUCount)
    }

    init(
        provider: any ProcessSnapshotProviding,
        logicalCPUCount: Int,
        legacyCapture: @escaping @Sendable () -> ProcessCapture
    ) {
        self.provider = provider
        self.resolver = ApplicationOwnershipResolver()
        self.aggregator = ApplicationUsageAggregator(logicalCPUCount: logicalCPUCount)
        self.legacy = LegacyProcessSampler(capture: legacyCapture)
    }

    @discardableResult
    public func resetBaseline() async -> UInt64 {
        await acquireSamplePermit()
        defer { releaseSamplePermit() }
        cpu.reset()
        baselineEpoch &+= 1
        return baselineEpoch
    }

    public func sample(
        limit: Int = 6,
        combinesProcesses: Bool = true
    ) async -> ApplicationUsageSnapshot {
        await acquireSamplePermit()
        defer { releaseSamplePermit() }

        return await sampleWithPermit(limit: limit, combinesProcesses: combinesProcesses)
    }

    public func sample(
        limit: Int = 6,
        combinesProcesses: Bool = true,
        requiringBaselineEpoch expectedEpoch: UInt64
    ) async -> ApplicationUsageSnapshot? {
        await acquireSamplePermit()
        defer { releaseSamplePermit() }

        guard expectedEpoch == baselineEpoch else { return nil }
        return await sampleWithPermit(limit: limit, combinesProcesses: combinesProcesses)
    }

    private func sampleWithPermit(
        limit: Int,
        combinesProcesses: Bool
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

    private func acquireSamplePermit() async {
        if !sampleInProgress {
            sampleInProgress = true
            return
        }
        await withCheckedContinuation { continuation in
            sampleWaiters.append(continuation)
        }
    }

    private func releaseSamplePermit() {
        guard !sampleWaiters.isEmpty else {
            sampleInProgress = false
            return
        }
        sampleWaiters.removeFirst().resume()
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
    private let capture: @Sendable () -> ProcessCapture
    private var cpu = ProcessCPUDeltaCalculator()

    init() {
        let enumerator = PIDEnumerator()
        self.capture = {
            let pids = enumerator.allPIDs()
            var records: [ProcessResourceRecord] = []
            var failures: [Int32: ProcessResourceReadFailure] = [:]
            records.reserveCapacity(pids.count)
            failures.reserveCapacity(pids.count)
            for pid in pids {
                switch DarwinProcessResourceReader.read(pid: pid) {
                case .success(let record): records.append(record)
                case .failure(let failure): failures[pid] = failure
                }
            }
            return ProcessCapture(
                records: records,
                failures: failures,
                wallDate: Date(),
                monotonicNanoseconds: DispatchTime.now().uptimeNanoseconds,
                source: .local,
                enumeratedCount: pids.count
            )
        }
    }

    init(capture: @escaping @Sendable () -> ProcessCapture) {
        self.capture = capture
    }

    func sample(top: Int) -> (byCPU: [ProcessUsage], byMemory: [ProcessUsage]) {
        lock.lock()
        defer { lock.unlock() }
        let capture = capture()
        let rates = cpu.rates(for: capture)
        guard !capture.records.isEmpty else { return ([], []) }

        var byCPU: [ProcessUsage] = []
        var byMemory: [ProcessUsage] = []
        byCPU.reserveCapacity(capture.records.count)
        byMemory.reserveCapacity(capture.records.count)
        for record in capture.records {
            let identity = ProcessIdentity(
                pid: record.pid,
                startTimeNanoseconds: record.startTimeNanoseconds
            )
            let knownCPU = rates?[identity]
            let cpuPercent = knownCPU ?? 0
            if cpuPercent < 0.05 && record.physicalFootprintBytes < 2_000_000 { continue }
            let usage = ProcessUsage(
                id: record.pid,
                name: record.name,
                cpuPercent: cpuPercent,
                memoryBytes: record.physicalFootprintBytes
            )
            byMemory.append(usage)
            if knownCPU != nil { byCPU.append(usage) }
        }

        let boundedTop = max(0, top)
        byCPU.sort {
            if $0.cpuPercent != $1.cpuPercent { return $0.cpuPercent > $1.cpuPercent }
            return $0.id < $1.id
        }
        byMemory.sort {
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
