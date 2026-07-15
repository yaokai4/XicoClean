import Foundation
import Darwin
import Shared

public struct ProcessIdentity: Hashable, Codable, Sendable {
    public let pid: Int32
    public let startTimeNanoseconds: UInt64
}

public enum ProcessCaptureSource: String, Sendable { case local, helperEnhanced }

public struct ProcessCapture: Sendable {
    public let records: [ProcessResourceRecord]
    public let failures: [Int32: ProcessResourceReadFailure]
    public let wallDate: Date
    public let monotonicNanoseconds: UInt64
    public let source: ProcessCaptureSource
    public let enumeratedCount: Int
}

public protocol PIDListing: Sendable {
    func estimatedCount() -> Int
    func fill(_ buffer: inout [Int32]) -> Int
}

public struct DarwinPIDListing: PIDListing {
    public init() {}

    public func estimatedCount() -> Int { max(0, Int(proc_listallpids(nil, 0))) }
    public func fill(_ buffer: inout [Int32]) -> Int {
        Int(proc_listallpids(&buffer, Int32(buffer.count * MemoryLayout<Int32>.size)))
    }
}

public struct PIDEnumerator: Sendable {
    let listing: any PIDListing
    let reserve: Int
    public init(listing: any PIDListing = DarwinPIDListing(), reserve: Int = 64) {
        self.listing = listing
        self.reserve = reserve
    }
    public func allPIDs() -> [Int32] {
        var capacity = max(64, listing.estimatedCount() + reserve)
        for _ in 0..<4 {
            var buffer = [Int32](repeating: 0, count: capacity)
            let count = listing.fill(&buffer)
            guard count > 0 else { return [] }
            if count < capacity {
                return Array(Set(buffer.prefix(count).filter { $0 > 0 })).sorted()
            }
            capacity *= 2
        }
        return []
    }
}

public protocol ProcessSnapshotProviding: Sendable {
    func capture() async -> ProcessCapture
}

public struct ApplicationIdentity: Hashable, Codable, Sendable, Identifiable {
    public let rawValue: String
    public var id: String { rawValue }
}

public enum CPUDisplayMode: String, CaseIterable, Codable, Sendable {
    case normalized
    case totalCore
}

public struct ApplicationMemberUsage: Identifiable, Sendable {
    public let identity: ProcessIdentity
    public let name: String
    public let cpuRawPercent: Double?
    public let physicalFootprintBytes: Int64
    public var id: ProcessIdentity { identity }
}

public struct ApplicationUsageTrend: Sendable {
    public var cpuRaw: [Double]
    public var memoryBytes: [Int64]
}

public struct ApplicationUsage: Identifiable, Sendable {
    public let id: ApplicationIdentity
    public let displayName: String
    public let bundleIdentifier: String?
    public let bundlePath: String?
    public let representativePID: Int32
    public let members: [ApplicationMemberUsage]
    public let cpuRawPercent: Double?
    public let cpuNormalizedPercent: Double?
    public let physicalFootprintBytes: Int64
    public let peakFootprintBytes: Int64
    public var trend: ApplicationUsageTrend
    public var memberCount: Int { members.count }
    public func cpuPercent(mode: CPUDisplayMode) -> Double? {
        mode == .normalized ? cpuNormalizedPercent : cpuRawPercent
    }
}

public struct ProcessCoverage: Sendable, Equatable {
    public let enumerated: Int
    public let sampled: Int
    public let denied: Int
    public let exited: Int

    public init(enumerated: Int, sampled: Int, denied: Int, exited: Int) {
        self.enumerated = enumerated
        self.sampled = sampled
        self.denied = denied
        self.exited = exited
    }

    public var fraction: Double {
        let usableCount = max(0, enumerated - exited)
        guard usableCount > 0 else { return 0 }
        return min(1, max(0, Double(sampled) / Double(usableCount)))
    }
}

public enum ProcessSamplingStatus: String, Sendable { case warmingUp, live, partial, stale, unavailable }

public struct ApplicationUsageSnapshot: Sendable {
    public let byCPU: [ApplicationUsage]
    public let byMemory: [ApplicationUsage]
    public let status: ProcessSamplingStatus
    public let coverage: ProcessCoverage
    public let sampledAt: Date
    public let source: ProcessCaptureSource

    public init(
        byCPU: [ApplicationUsage],
        byMemory: [ApplicationUsage],
        status: ProcessSamplingStatus,
        coverage: ProcessCoverage,
        sampledAt: Date,
        source: ProcessCaptureSource
    ) {
        self.byCPU = byCPU
        self.byMemory = byMemory
        self.status = status
        self.coverage = coverage
        self.sampledAt = sampledAt
        self.source = source
    }
}

#if DEBUG
/// Narrow deterministic factory used by focused off-screen monitoring QA.
/// It is compiled out of release builds so fixture construction cannot become production API.
public extension ApplicationUsage {
    static func monitoringFixture(
        id: String,
        name: String,
        cpuRaw: Double?,
        cpuNormalized: Double?,
        memory: Int64,
        memberCount: Int = 1
    ) -> Self {
        let count = max(1, memberCount)
        let safeMemory = max(0, memory)
        let baseMemory = safeMemory / Int64(count)
        let remainder = safeMemory % Int64(count)
        let members = (0..<count).map { index in
            let pid = Int32(9_000 + index)
            let started = UInt64(1_000 + index)
            let memberName = index == 0 ? name : name + " Helper " + String(index)
            let memberCPU = cpuRaw.map { $0 / Double(count) }
            let memberMemory = baseMemory + (index == 0 ? remainder : 0)
            return ApplicationMemberUsage(
                identity: ProcessIdentity(pid: pid, startTimeNanoseconds: started),
                name: memberName,
                cpuRawPercent: memberCPU,
                physicalFootprintBytes: memberMemory)
        }
        let cpuTrend = cpuRaw.map { value in
            (0..<60).map { index in value * (0.72 + Double(index % 12) * 0.02) }
        } ?? []
        let memoryTrend = (0..<60).map { index in
            Int64(Double(safeMemory) * (0.88 + Double(index % 10) * 0.01))
        }
        return Self(
            id: ApplicationIdentity(rawValue: "fixture:\(id)"),
            displayName: name,
            bundleIdentifier: nil,
            bundlePath: nil,
            representativePID: members[0].identity.pid,
            members: members,
            cpuRawPercent: cpuRaw,
            cpuNormalizedPercent: cpuNormalized,
            physicalFootprintBytes: safeMemory,
            peakFootprintBytes: Int64(Double(safeMemory) * 1.18),
            trend: ApplicationUsageTrend(cpuRaw: cpuTrend, memoryBytes: memoryTrend))
    }
}
#endif
