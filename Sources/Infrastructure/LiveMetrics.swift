import Foundation
import Darwin
import Domain

public enum ThermalLevel: String, Sendable {
    case nominal = "正常"
    case fair = "一般"
    case serious = "偏热"
    case critical = "过热"
}

public struct SystemSnapshot: Sendable {
    public let cpuUsage: Double          // 0...1
    public let memoryUsed: Int64
    public let memoryTotal: Int64
    public let memoryActive: Int64
    public let memoryWired: Int64
    public let memoryCompressed: Int64
    public let diskFree: Int64
    public let diskTotal: Int64
    public let netDownBytesPerSec: Double
    public let netUpBytesPerSec: Double
    public let thermal: ThermalLevel
    public let fanRPM: Int?

    public var memoryUsedFraction: Double { memoryTotal > 0 ? Double(memoryUsed) / Double(memoryTotal) : 0 }
    public var diskUsedFraction: Double { diskTotal > 0 ? Double(diskTotal - diskFree) / Double(diskTotal) : 0 }
}

public struct MacInfo: Sendable {
    public let model: String
    public let chip: String
    public let macOS: String
    public let memory: String
    public let cores: Int
    public let uptime: String
}

/// 实时系统指标采样（CPU / 内存 / 网络 / 磁盘 / 温度）。
/// 差分状态（prevCPU/prevNet）用锁保护——类型系统层面 Sendable，任何线程调 sample()
/// 都不会被编译器拦，无锁会算错速率甚至数据竞争（审计）。
public final class LiveMetricsSampler: @unchecked Sendable {
    private let stateLock = NSLock()
    private var prevCPU: host_cpu_load_info?
    private var prevNet: (down: UInt64, up: UInt64)?
    private var prevNetTime: Date?
    private let fs: FileSystemService
    private let smc = SMCReader()

    public init(fs: FileSystemService = LocalFileSystemService()) { self.fs = fs }

    public func sample() -> SystemSnapshot {
        let cpu = sampleCPU()
        let mem = sampleMemory()
        let net = sampleNetwork()
        let cap = fs.volumeCapacity(for: FileManager.default.homeDirectoryForCurrentUser)
        return SystemSnapshot(
            cpuUsage: cpu,
            memoryUsed: mem.used, memoryTotal: mem.total,
            memoryActive: mem.active, memoryWired: mem.wired, memoryCompressed: mem.compressed,
            diskFree: cap?.available ?? 0, diskTotal: cap?.total ?? 0,
            netDownBytesPerSec: net.down, netUpBytesPerSec: net.up,
            thermal: thermalLevel(), fanRPM: smc.fanRPM())
    }

    // MARK: CPU

    private func sampleCPU() -> Double {
        guard let cur = cpuTicks() else { return 0 }
        stateLock.lock(); defer { stateLock.unlock() }
        defer { prevCPU = cur }
        guard let prev = prevCPU else { return 0 }
        let user = Double(cur.cpu_ticks.0) - Double(prev.cpu_ticks.0)
        let sys  = Double(cur.cpu_ticks.1) - Double(prev.cpu_ticks.1)
        let idle = Double(cur.cpu_ticks.2) - Double(prev.cpu_ticks.2)
        let nice = Double(cur.cpu_ticks.3) - Double(prev.cpu_ticks.3)
        let busy = max(0, user + sys + nice)
        let total = busy + max(0, idle)
        return total > 0 ? busy / total : 0
    }

    private func cpuTicks() -> host_cpu_load_info? {
        var size = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size)
        var info = host_cpu_load_info()
        let result = withUnsafeMutablePointer(to: &info) { ptr -> kern_return_t in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(size)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &size)
            }
        }
        return result == KERN_SUCCESS ? info : nil
    }

    // MARK: 内存

    private func sampleMemory() -> (used: Int64, total: Int64, active: Int64, wired: Int64, compressed: Int64) {
        let total = Int64(ProcessInfo.processInfo.physicalMemory)
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &stats) { ptr -> kern_return_t in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return (0, total, 0, 0, 0) }
        let page = Int64(getpagesize())
        let active = Int64(stats.active_count) * page
        let wired = Int64(stats.wire_count) * page
        let compressed = Int64(stats.compressor_page_count) * page
        return (active + wired + compressed, total, active, wired, compressed)
    }

    // MARK: 网络速率

    private func sampleNetwork() -> (down: Double, up: Double) {
        let cur = netCounters()
        let now = Date()
        stateLock.lock(); defer { stateLock.unlock() }
        defer { prevNet = cur; prevNetTime = now }
        guard let prev = prevNet, let prevTime = prevNetTime else { return (0, 0) }
        let dt = now.timeIntervalSince(prevTime)
        guard dt > 0 else { return (0, 0) }
        let down = cur.down >= prev.down ? Double(cur.down - prev.down) / dt : 0
        let up = cur.up >= prev.up ? Double(cur.up - prev.up) / dt : 0
        return (down, up)
    }

    private func netCounters() -> (down: UInt64, up: UInt64) {
        var down: UInt64 = 0, up: UInt64 = 0
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0 else { return (0, 0) }
        defer { freeifaddrs(ifaddr) }
        var ptr = ifaddr
        while let p = ptr {
            defer { ptr = p.pointee.ifa_next }
            let name = String(cString: p.pointee.ifa_name)
            guard !name.hasPrefix("lo"), p.pointee.ifa_addr?.pointee.sa_family == UInt8(AF_LINK),
                  let data = p.pointee.ifa_data else { continue }
            let netData = data.assumingMemoryBound(to: if_data.self)
            down += UInt64(netData.pointee.ifi_ibytes)
            up += UInt64(netData.pointee.ifi_obytes)
        }
        return (down, up)
    }

    // MARK: 温度（用公开的热状态指示）

    private func thermalLevel() -> ThermalLevel {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: return .nominal
        case .fair: return .fair
        case .serious: return .serious
        case .critical: return .critical
        @unknown default: return .nominal
        }
    }

    // MARK: Mac 详情

    public func macInfo() -> MacInfo {
        let total = Int64(ProcessInfo.processInfo.physicalMemory)
        let v = ProcessInfo.processInfo.operatingSystemVersion
        let chip = sysctlString("machdep.cpu.brand_string")
        let model = sysctlString("hw.model")
        return MacInfo(
            model: model.isEmpty ? "Mac" : model,
            chip: chip.isEmpty ? "Apple Silicon" : chip,
            macOS: "macOS \(v.majorVersion).\(v.minorVersion).\(v.patchVersion)",
            memory: total.formattedBytes,
            cores: ProcessInfo.processInfo.processorCount,
            uptime: formatUptime(ProcessInfo.processInfo.systemUptime))
    }

    private func sysctlString(_ name: String) -> String {
        var size = 0
        sysctlbyname(name, nil, &size, nil, 0)
        guard size > 0 else { return "" }
        var buf = [CChar](repeating: 0, count: size)
        sysctlbyname(name, &buf, &size, nil, 0)
        return xicoString(fromNullTerminated: buf)
    }

    private func formatUptime(_ seconds: TimeInterval) -> String {
        let d = Int(seconds) / 86400
        let h = (Int(seconds) % 86400) / 3600
        let m = (Int(seconds) % 3600) / 60
        if d > 0 { return "\(d) 天 \(h) 小时" }
        if h > 0 { return "\(h) 小时 \(m) 分" }
        return "\(m) 分"
    }
}

public extension Double {
    /// 速率格式化，如 "1.2 MB/s"（0 显示为 "0 KB/s"）
    var formattedRate: String {
        if self < 1 { return "0 KB/s" }
        return Int64(self).formattedBytes + "/s"
    }
    /// 菜单栏紧凑速率，如 "1.2M" / "386K"
    var compactRate: String {
        if self >= 1_000_000 { return String(format: "%.1fM", self / 1_000_000) }
        if self >= 1_000 { return String(format: "%.0fK", self / 1_000) }
        return "0"
    }
}
