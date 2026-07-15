import Foundation
import Darwin

public struct ProcessResourceRecord: Codable, Sendable, Hashable {
    public let pid: Int32
    public let parentPID: Int32
    public let startTimeNanoseconds: UInt64
    public let name: String
    public let executablePath: String?
    public let cpuTimeNanoseconds: UInt64
    public let physicalFootprintBytes: Int64
    public let peakFootprintBytes: Int64
    public init(pid: Int32, parentPID: Int32, startTimeNanoseconds: UInt64,
                name: String, executablePath: String?, cpuTimeNanoseconds: UInt64,
                physicalFootprintBytes: Int64, peakFootprintBytes: Int64) {
        self.pid = pid
        self.parentPID = parentPID
        self.startTimeNanoseconds = startTimeNanoseconds
        self.name = name
        self.executablePath = executablePath
        self.cpuTimeNanoseconds = cpuTimeNanoseconds
        self.physicalFootprintBytes = physicalFootprintBytes
        self.peakFootprintBytes = peakFootprintBytes
    }
}

public enum ProcessResourceReadFailure: String, Error, Codable, Sendable {
    case permissionDenied
    case exited
    case unreadable

    static func fromErrno(_ value: Int32) -> Self {
        switch value {
        case EPERM, EACCES: return .permissionDenied
        case ESRCH: return .exited
        default: return .unreadable
        }
    }
}

public struct ProcessHelperBatchResponse: Codable, Sendable {
    public let requestedCount: Int
    public let records: [ProcessResourceRecord]
    public init(requestedCount: Int, records: [ProcessResourceRecord]) {
        self.requestedCount = requestedCount
        self.records = records
    }
}

public enum DarwinProcessResourceReader {
    public static func read(pid: Int32) -> Result<ProcessResourceRecord, ProcessResourceReadFailure> {
        var bsd = proc_bsdinfo()
        let bsdSize = Int32(MemoryLayout<proc_bsdinfo>.stride)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bsd, bsdSize) == bsdSize else {
            return .failure(.fromErrno(errno))
        }

        var usage = rusage_info_v4()
        let usageResult = withUnsafeMutablePointer(to: &usage) { pointer -> Int32 in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V4, $0)
            }
        }
        guard usageResult == 0 else { return .failure(.fromErrno(errno)) }

        var pathBuffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        let pathLength = proc_pidpath(pid, &pathBuffer, UInt32(pathBuffer.count))
        let executablePath: String? = pathLength > 0
            ? String(decoding: pathBuffer.prefix(Int(pathLength)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
            : nil

        var nameBuffer = [CChar](repeating: 0, count: 256)
        let nameLength = proc_name(pid, &nameBuffer, UInt32(nameBuffer.count))
        let name = nameLength > 0
            ? String(decoding: nameBuffer.prefix(Int(nameLength)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
            : "PID \(pid)"

        let start = UInt64(bsd.pbi_start_tvsec) * 1_000_000_000
            + UInt64(bsd.pbi_start_tvusec) * 1_000
        return .success(ProcessResourceRecord(
            pid: pid,
            parentPID: Int32(bitPattern: bsd.pbi_ppid),
            startTimeNanoseconds: start,
            name: name,
            executablePath: executablePath,
            cpuTimeNanoseconds: usage.ri_user_time &+ usage.ri_system_time,
            physicalFootprintBytes: Int64(usage.ri_phys_footprint),
            peakFootprintBytes: Int64(usage.ri_lifetime_max_phys_footprint)
        ))
    }
}
