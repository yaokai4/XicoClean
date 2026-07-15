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
