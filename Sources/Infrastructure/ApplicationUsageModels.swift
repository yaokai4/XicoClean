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

    public var fraction: Double { enumerated > 0 ? Double(sampled) / Double(enumerated) : 0 }
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
