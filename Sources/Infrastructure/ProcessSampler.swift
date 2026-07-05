import Foundation
import Darwin

/// 单个进程的资源占用。
public struct ProcessUsage: Sendable, Identifiable {
    public let id: Int32          // pid
    public let name: String
    public let cpuPercent: Double // 0...(核数×100)
    public let memoryBytes: Int64 // phys_footprint（对齐活动监视器"内存"列）
}

/// 进程资源采样器：proc_listallpids + proc_pid_rusage 差分。
/// 与 top/活动监视器同权，普通用户即可读全部进程，无需特权。
public final class ProcessSampler: @unchecked Sendable {
    private let lock = NSLock()
    private var prevCPUTime: [Int32: UInt64] = [:]
    private var prevWall: Date?

    public init() {}

    /// 返回按 CPU 和按内存排序的前 N 个进程。
    public func sample(top: Int = 6) -> (byCPU: [ProcessUsage], byMemory: [ProcessUsage]) {
        let pids = allPIDs()
        guard !pids.isEmpty else { return ([], []) }

        let now = Date()
        lock.lock()
        let prevWallLocal = prevWall
        let prevMap = prevCPUTime
        lock.unlock()
        let wallDelta = prevWallLocal.map { now.timeIntervalSince($0) } ?? 0

        var newCPUTime: [Int32: UInt64] = [:]
        newCPUTime.reserveCapacity(pids.count)
        var results: [ProcessUsage] = []
        results.reserveCapacity(pids.count)

        for pid in pids where pid > 0 {
            guard let info = rusage(pid) else { continue }
            let cpuTime = info.ri_user_time &+ info.ri_system_time   // 纳秒
            newCPUTime[pid] = cpuTime
            var cpuPercent = 0.0
            if wallDelta > 0, let prev = prevMap[pid], cpuTime >= prev {
                let deltaNs = Double(cpuTime - prev)
                cpuPercent = (deltaNs / (wallDelta * 1_000_000_000)) * 100
            }
            let mem = Int64(info.ri_phys_footprint)
            // 跳过既不耗 CPU 又几乎不占内存的僵尸/内核线程
            if cpuPercent < 0.05 && mem < 2_000_000 { continue }
            results.append(ProcessUsage(id: pid, name: processName(pid),
                                        cpuPercent: cpuPercent, memoryBytes: mem))
        }

        lock.lock(); prevCPUTime = newCPUTime; prevWall = now; lock.unlock()

        let byCPU = Array(results.sorted { $0.cpuPercent > $1.cpuPercent }.prefix(top))
        let byMem = Array(results.sorted { $0.memoryBytes > $1.memoryBytes }.prefix(top))
        return (byCPU, byMem)
    }

    /// 某进程的即时内存占用（phys_footprint）。用于给「运行中应用」列表标注内存，
    /// 无需时间差分即准确（CPU% 才需要两次采样，故此处只给内存）。
    public func memoryFootprint(pid: Int32) -> Int64? {
        guard let info = rusage(pid) else { return nil }
        return Int64(info.ri_phys_footprint)
    }

    private func allPIDs() -> [Int32] {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        var pids = [Int32](repeating: 0, count: Int(count) + 32)
        let bytes = proc_listallpids(&pids, Int32(pids.count) * Int32(MemoryLayout<Int32>.size))
        guard bytes > 0 else { return [] }
        let n = Int(bytes) / MemoryLayout<Int32>.size
        return Array(pids.prefix(n))
    }

    private func rusage(_ pid: Int32) -> rusage_info_v4? {
        var info = rusage_info_v4()
        let rc = withUnsafeMutablePointer(to: &info) { ptr -> Int32 in
            ptr.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V4, $0)
            }
        }
        return rc == 0 ? info : nil
    }

    private func processName(_ pid: Int32) -> String {
        var buf = [CChar](repeating: 0, count: 256)
        let n = proc_name(pid, &buf, UInt32(buf.count))
        if n > 0 { return String(cString: buf) }
        return "PID \(pid)"
    }
}
