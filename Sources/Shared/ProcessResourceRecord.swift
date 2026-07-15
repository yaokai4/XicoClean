import Foundation
import Darwin
import CProcessBatch

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

public struct ProcessResourceReadBatch: Sendable {
    public let records: [ProcessResourceRecord]
    public let failures: [Int32: ProcessResourceReadFailure]

    public init(
        records: [ProcessResourceRecord],
        failures: [Int32: ProcessResourceReadFailure]
    ) {
        self.records = records
        self.failures = failures
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

enum ProcessCPUTimeConverter {
    static func nanoseconds(
        fromMachAbsoluteTime ticks: UInt64,
        numerator: UInt32,
        denominator: UInt32
    ) -> UInt64 {
        let numerator = UInt64(numerator)
        let denominator = UInt64(max(1, denominator))
        let whole = ticks / denominator
        let remainder = ticks % denominator
        let (wholeNanoseconds, overflow) = whole.multipliedReportingOverflow(by: numerator)
        guard !overflow else { return UInt64.max }
        let remainderNanoseconds = remainder * numerator / denominator
        let (total, remainderOverflow) = wholeNanoseconds.addingReportingOverflow(remainderNanoseconds)
        return remainderOverflow ? UInt64.max : total
    }
}

enum ProcessStartTimeConverter {
    static func nanoseconds(
        rusageAbsoluteTime: UInt64,
        numerator: UInt32,
        denominator: UInt32,
        bsdSeconds: UInt64,
        bsdMicroseconds: UInt64
    ) -> UInt64 {
        if rusageAbsoluteTime != 0 {
            return ProcessCPUTimeConverter.nanoseconds(
                fromMachAbsoluteTime: rusageAbsoluteTime,
                numerator: numerator,
                denominator: denominator
            )
        }
        let (seconds, secondsOverflow) = bsdSeconds.multipliedReportingOverflow(
            by: 1_000_000_000
        )
        guard !secondsOverflow else { return UInt64.max }
        let (microseconds, microsecondsOverflow) = bsdMicroseconds.multipliedReportingOverflow(
            by: 1_000
        )
        guard !microsecondsOverflow else { return UInt64.max }
        let (total, totalOverflow) = seconds.addingReportingOverflow(microseconds)
        return totalOverflow ? UInt64.max : total
    }
}

struct ProcessResourceMetadata: Sendable, Equatable {
    let parentPID: Int32
    let name: String
    let executablePath: String?
}

struct ProcessExecutableUUID: Hashable, Sendable {
    let high: UInt64
    let low: UInt64
}

private struct ProcessResourceMetadataIdentity: Hashable {
    let pid: Int32
    let startTimeNanoseconds: UInt64
    let executableUUID: ProcessExecutableUUID
}

final class ProcessResourceMetadataCache: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [ProcessResourceMetadataIdentity: ProcessResourceMetadata] = [:]

    func metadata(
        pid: Int32,
        startTimeNanoseconds: UInt64,
        executableUUID: ProcessExecutableUUID,
        load: () -> ProcessResourceMetadata?
    ) -> ProcessResourceMetadata? {
        let identity = ProcessResourceMetadataIdentity(
            pid: pid,
            startTimeNanoseconds: startTimeNanoseconds,
            executableUUID: executableUUID
        )
        if let cached = lock.withLock({ values[identity] }) { return cached }
        guard let loaded = load() else { return nil }
        return lock.withLock {
            if let cached = values[identity] { return cached }
            if values.count >= 4_096 { values.removeAll(keepingCapacity: true) }
            values[identity] = loaded
            return loaded
        }
    }
}

public enum DarwinProcessResourceReader {
    private struct BSDMetadataRead {
        let metadata: ProcessResourceMetadata
        let startSeconds: UInt64
        let startMicroseconds: UInt64
    }

    private static let cpuTimebase: mach_timebase_info_data_t = {
        var value = mach_timebase_info_data_t()
        mach_timebase_info(&value)
        return value
    }()
    private static let metadataCache = ProcessResourceMetadataCache()

    private static func bsdString<T>(from value: inout T) -> String {
        withUnsafeBytes(of: &value) { bytes in
            let end = bytes.firstIndex(of: 0) ?? bytes.endIndex
            return String(decoding: bytes[..<end], as: UTF8.self)
        }
    }

    private static func executableUUID(from usage: inout rusage_info_v4) -> ProcessExecutableUUID {
        withUnsafeBytes(of: &usage.ri_uuid) { bytes in
            ProcessExecutableUUID(
                high: bytes.loadUnaligned(fromByteOffset: 0, as: UInt64.self),
                low: bytes.loadUnaligned(fromByteOffset: 8, as: UInt64.self)
            )
        }
    }

    private static func readBSDMetadata(
        pid: Int32
    ) -> Result<BSDMetadataRead, ProcessResourceReadFailure> {
        var bsd = proc_bsdinfo()
        let bsdSize = Int32(MemoryLayout<proc_bsdinfo>.stride)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bsd, bsdSize) == bsdSize else {
            return .failure(.fromErrno(errno))
        }
        var pathBuffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        let pathLength = proc_pidpath(pid, &pathBuffer, UInt32(pathBuffer.count))
        let executablePath: String? = pathLength > 0
            ? String(
                decoding: pathBuffer.prefix(Int(pathLength)).map { UInt8(bitPattern: $0) },
                as: UTF8.self
            )
            : nil
        let fullName = bsdString(from: &bsd.pbi_name)
        let commandName = bsdString(from: &bsd.pbi_comm)
        let name = !fullName.isEmpty
            ? fullName
            : (!commandName.isEmpty ? commandName : "PID \(pid)")
        return .success(BSDMetadataRead(
            metadata: ProcessResourceMetadata(
                parentPID: Int32(bitPattern: bsd.pbi_ppid),
                name: name,
                executablePath: executablePath
            ),
            startSeconds: UInt64(bsd.pbi_start_tvsec),
            startMicroseconds: UInt64(bsd.pbi_start_tvusec)
        ))
    }

    private static func makeRecord(
        pid: Int32,
        userTimeTicks: UInt64,
        systemTimeTicks: UInt64,
        physicalFootprint: UInt64,
        peakFootprint: UInt64,
        processStartAbsoluteTime: UInt64,
        executableUUID: ProcessExecutableUUID
    ) -> Result<ProcessResourceRecord, ProcessResourceReadFailure> {
        let start: UInt64
        let metadata: ProcessResourceMetadata
        if processStartAbsoluteTime != 0 {
            start = ProcessStartTimeConverter.nanoseconds(
                rusageAbsoluteTime: processStartAbsoluteTime,
                numerator: cpuTimebase.numer,
                denominator: cpuTimebase.denom,
                bsdSeconds: 0,
                bsdMicroseconds: 0
            )
            var metadataFailure = ProcessResourceReadFailure.unreadable
            guard let cached = metadataCache.metadata(
                pid: pid,
                startTimeNanoseconds: start,
                executableUUID: executableUUID,
                load: {
                    switch readBSDMetadata(pid: pid) {
                    case .success(let read):
                        return read.metadata
                    case .failure(let failure):
                        metadataFailure = failure
                        return nil
                    }
                }
            ) else {
                return .failure(metadataFailure)
            }
            metadata = cached
        } else {
            let read: BSDMetadataRead
            switch readBSDMetadata(pid: pid) {
            case .success(let value):
                read = value
            case .failure(let failure):
                return .failure(failure)
            }
            start = ProcessStartTimeConverter.nanoseconds(
                rusageAbsoluteTime: 0,
                numerator: cpuTimebase.numer,
                denominator: cpuTimebase.denom,
                bsdSeconds: read.startSeconds,
                bsdMicroseconds: read.startMicroseconds
            )
            metadata = metadataCache.metadata(
                pid: pid,
                startTimeNanoseconds: start,
                executableUUID: executableUUID
            ) {
                read.metadata
            } ?? read.metadata
        }
        let cpuTimeTicks = userTimeTicks &+ systemTimeTicks
        return .success(ProcessResourceRecord(
            pid: pid,
            parentPID: metadata.parentPID,
            startTimeNanoseconds: start,
            name: metadata.name,
            executablePath: metadata.executablePath,
            cpuTimeNanoseconds: ProcessCPUTimeConverter.nanoseconds(
                fromMachAbsoluteTime: cpuTimeTicks,
                numerator: cpuTimebase.numer,
                denominator: cpuTimebase.denom
            ),
            physicalFootprintBytes: Int64(clamping: physicalFootprint),
            peakFootprintBytes: Int64(clamping: peakFootprint)
        ))
    }

    public static func read(pid: Int32) -> Result<ProcessResourceRecord, ProcessResourceReadFailure> {
        var usage = rusage_info_v4()
        let usageResult = withUnsafeMutablePointer(to: &usage) { pointer -> Int32 in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V4, $0)
            }
        }
        guard usageResult == 0 else { return .failure(.fromErrno(errno)) }
        let executableUUID = executableUUID(from: &usage)
        return makeRecord(
            pid: pid,
            userTimeTicks: usage.ri_user_time,
            systemTimeTicks: usage.ri_system_time,
            physicalFootprint: usage.ri_phys_footprint,
            peakFootprint: usage.ri_lifetime_max_phys_footprint,
            processStartAbsoluteTime: usage.ri_proc_start_abstime,
            executableUUID: executableUUID
        )
    }

    public static func readBatch(pids: [Int32]) -> ProcessResourceReadBatch {
        guard !pids.isEmpty else {
            return ProcessResourceReadBatch(records: [], failures: [:])
        }
        guard pids.count <= Int(Int32.max) else {
            return ProcessResourceReadBatch(
                records: [],
                failures: Dictionary(
                    uniqueKeysWithValues: pids.map { ($0, .unreadable) }
                )
            )
        }

        var samples = [XicoProcessRUsageSample](
            repeating: XicoProcessRUsageSample(),
            count: pids.count
        )
        let sampledCount = pids.withUnsafeBufferPointer { pidBuffer in
            samples.withUnsafeMutableBufferPointer { sampleBuffer in
                xico_sample_process_rusage(
                    pidBuffer.baseAddress,
                    Int32(pidBuffer.count),
                    sampleBuffer.baseAddress,
                    Int32(sampleBuffer.count)
                )
            }
        }
        guard sampledCount >= 0 else {
            return ProcessResourceReadBatch(
                records: [],
                failures: Dictionary(
                    uniqueKeysWithValues: pids.map { ($0, .unreadable) }
                )
            )
        }

        var records: [ProcessResourceRecord] = []
        var failures: [Int32: ProcessResourceReadFailure] = [:]
        records.reserveCapacity(Int(sampledCount))
        failures.reserveCapacity(pids.count - Int(sampledCount))
        for sample in samples.prefix(Int(sampledCount)) {
            if sample.error_code != 0 {
                failures[sample.pid] = .fromErrno(sample.error_code)
                continue
            }
            let result = makeRecord(
                pid: sample.pid,
                userTimeTicks: sample.user_time,
                systemTimeTicks: sample.system_time,
                physicalFootprint: sample.physical_footprint,
                peakFootprint: sample.peak_footprint,
                processStartAbsoluteTime: sample.process_start_abstime,
                executableUUID: ProcessExecutableUUID(
                    high: sample.executable_uuid_high,
                    low: sample.executable_uuid_low
                )
            )
            switch result {
            case .success(let record):
                records.append(record)
            case .failure(let failure):
                failures[sample.pid] = failure
            }
        }
        if sampledCount < Int32(pids.count) {
            for pid in pids[Int(sampledCount)...] {
                failures[pid] = .unreadable
            }
        }
        return ProcessResourceReadBatch(records: records, failures: failures)
    }
}
