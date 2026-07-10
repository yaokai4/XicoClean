import Foundation
import DesignSystem
import Darwin
import Domain
import IOKit.ps
import CSensors

public enum ThermalLevel: String, Sendable {
    case nominal = "正常"
    case fair = "一般"
    case serious = "偏热"
    case critical = "过热"
}

public struct SystemSnapshot: Sendable {
    public let cpuUsage: Double          // 0...1 聚合
    public let perCore: [Double]         // 每逻辑核 0...1
    public let cpuUser: Double           // 0...1
    public let cpuSystem: Double         // 0...1
    public let load1: Double
    public let load5: Double
    public let load15: Double
    public let memoryUsed: Int64         // 活动监视器口径「已使用」
    public let memoryTotal: Int64
    public let memoryApp: Int64          // 应用内存
    public let memoryWired: Int64        // 联动内存
    public let memoryCompressed: Int64   // 已压缩
    public let memoryCached: Int64        // 缓存文件（计入可用）
    public let swapUsed: Int64
    public let swapTotal: Int64
    public let memoryPressure: Int      // 1=正常 2=警告 4=危险（kern.memorystatus_vm_pressure_level）
    public let pageIns: Int64           // 累计换入字节
    public let pageOuts: Int64          // 累计换出字节
    public let diskFree: Int64
    public let diskTotal: Int64
    public let netDownBytesPerSec: Double
    public let netUpBytesPerSec: Double
    public let diskReadBytesPerSec: Double    // 全盘读速率（IOBlockStorageDriver 统计差分）
    public let diskWriteBytesPerSec: Double   // 全盘写速率
    public let gpuUsage: Double?          // 0...1（IOAccelerator）
    public let cpuTemp: Double?           // ℃（Apple Silicon HID / Intel SMC）
    public let gpuTemp: Double?           // ℃
    public let batteryPercent: Int?       // 0...100（无电池为 nil）
    public let batteryCharging: Bool
    public let thermal: ThermalLevel
    public let fanRPM: Int?

    // 兼容旧字段：活跃 ≈ 应用内存（菜单栏/仪表沿用）
    public var memoryActive: Int64 { memoryApp }
    public var memoryUsedFraction: Double { memoryTotal > 0 ? Double(memoryUsed) / Double(memoryTotal) : 0 }
    public var diskUsedFraction: Double { diskTotal > 0 ? Double(diskTotal - diskFree) / Double(diskTotal) : 0 }
    public var swapUsedFraction: Double { swapTotal > 0 ? Double(swapUsed) / Double(swapTotal) : 0 }
    /// 内存压力 0...1（正常≈0.25 警告≈0.6 危险≈0.9），供压力环显示。
    public var memoryPressureFraction: Double {
        switch memoryPressure { case 4: return 0.9; case 2: return 0.6; default: return 0.25 }
    }
    public var memoryPressureLabel: String {
        switch memoryPressure { case 4: return "危险"; case 2: return "警告"; default: return "正常" }
    }
}

public struct MacInfo: Sendable {
    public let model: String
    public let chip: String
    public let macOS: String
    public let memory: String
    public let cores: Int
    public let performanceCores: Int
    public let efficiencyCores: Int
    /// 每逻辑 CPU 是否性能核（按 perCore 索引对齐）；Intel/读不到为空数组。
    public let coreClusters: [Bool]
    public let uptime: String
}

/// 实时系统指标采样（CPU / 每核 / 内存 / 网络 / 磁盘 / 温度 / GPU）。
/// 差分状态（prevCPU/prevNet/prevPerCore）用锁保护——类型系统层面 Sendable。
public final class LiveMetricsSampler: @unchecked Sendable {
    private let stateLock = NSLock()
    private var prevCPU: host_cpu_load_info?
    private var prevPerCore: [(user: UInt32, system: UInt32, idle: UInt32, nice: UInt32)]?
    private var prevNet: (down: UInt64, up: UInt64)?
    private var prevNetTime: Date?
    /// GPU 利用率的指数移动平均状态。IOAccelerator 的 "Device Utilization %" 是瞬时忙碌值，
    /// 逐秒读数在 0↔80 间跳变属于硬件真实行为，但直接显示像假数据；
    /// iStat 同样做平滑。α=0.35：3 秒左右收敛，既平稳又不迟钝。
    private var gpuEMA: Double?
    /// 磁盘累计读写字节的差分状态（与网络同一套路）。
    private var prevDisk: (read: UInt64, write: UInt64)?
    private var prevDiskTime: Date?
    private let fs: FileSystemService
    private let smc = SMCReader()
    private let sensors = SensorReader()
    private let hardware = HardwareProfileService()

    public init(fs: FileSystemService = LocalFileSystemService()) { self.fs = fs }

    /// 采样一帧系统快照。
    ///
    /// `consumerVisible`：是否有在屏的详情消费者（监视 / 硬件页）。
    /// - `true`（默认，保持既有调用方全量语义）：GPU / 温度 / 风扇 / 电池全部读取。
    /// - `false`：菜单栏常驻循环的**稳态省电**路径——没人看时跳过昂贵读取
    ///   （GPU 走 IOAccelerator 枚举、温度走 HID 热传感器枚举、风扇走 SMC 读键、电源走 IOPS），
    ///   仅当对应菜单栏字形仍启用时才按需读取。字形启用状态直接读 `xico.mb.*` UserDefaults
    ///   以保持自洽（不改 AppModel 公有 API）。风扇 / 电池无专属菜单栏字形，故仅在详情可见时读。
    ///   被跳过的字段返回 nil（各字段本就是 Optional，UI 静默降级）。
    public func sample(consumerVisible: Bool = true) -> SystemSnapshot {
        let cpu = sampleCPU()
        let cores = samplePerCore()
        let mem = sampleMemory()
        let swap = sampleSwap()
        let net = sampleNetwork()
        let disk = sampleDiskIO()
        let load = loadAverage()
        let cap = fs.volumeCapacity(for: FileManager.default.homeDirectoryForCurrentUser)
        let needGPU = consumerVisible || Self.menuGlyphEnabled("gpu", default: false)
        let needTemp = consumerVisible || Self.menuGlyphEnabled("temp", default: false)
        // GPU：需要则读并平滑；跳过时以 smoothedGPU(nil) 清空 EMA，避免下次恢复采样时残留陈旧值。
        let gpu = needGPU
            ? smoothedGPU(hardware.acceleratorPerformance().utilization.map { min(1, max(0, $0 / 100)) })
            : smoothedGPU(nil)
        let temp: (cpu: Double?, gpu: Double?) = needTemp ? sensors.summary() : (nil, nil)
        // 电池：详情可见或菜单栏电池字形启用时读取（IOPS 快照成本低，与 gpu/temp 同一门控模式）。
        let needBattery = consumerVisible || Self.menuGlyphEnabled("battery", default: false)
        let battery: (percent: Int?, charging: Bool) = needBattery ? batteryStatus() : (nil, false)
        let fan: Int? = consumerVisible ? smc.fanRPM() : nil
        return SystemSnapshot(
            cpuUsage: cpu.busy, perCore: cores, cpuUser: cpu.user, cpuSystem: cpu.system,
            load1: load.0, load5: load.1, load15: load.2,
            memoryUsed: mem.used, memoryTotal: mem.total,
            memoryApp: mem.app, memoryWired: mem.wired, memoryCompressed: mem.compressed, memoryCached: mem.cached,
            swapUsed: swap.used, swapTotal: swap.total,
            memoryPressure: memoryPressureLevel(), pageIns: mem.pageIns, pageOuts: mem.pageOuts,
            diskFree: cap?.available ?? 0, diskTotal: cap?.total ?? 0,
            netDownBytesPerSec: net.down, netUpBytesPerSec: net.up,
            diskReadBytesPerSec: disk.read, diskWriteBytesPerSec: disk.write,
            gpuUsage: gpu,
            cpuTemp: temp.cpu, gpuTemp: temp.gpu,
            batteryPercent: battery.percent, batteryCharging: battery.charging,
            thermal: thermalLevel(), fanRPM: fan)
    }

    /// 某菜单栏字形是否启用（直接读 `xico.mb.<id>` UserDefaults，与 MenuBarController 同源）。
    /// 未写入过该键时用传入默认值（须与 MenuBarController / SettingsView 的默认一致）。
    private static func menuGlyphEnabled(_ id: String, default def: Bool) -> Bool {
        let key = "xico.mb.\(id)"
        guard UserDefaults.standard.object(forKey: key) != nil else { return def }
        return UserDefaults.standard.bool(forKey: key)
    }

    // MARK: 磁盘 I/O（IOBlockStorageDriver Statistics 差分，与 iStat 同源）

    private func sampleDiskIO() -> (read: Double, write: Double) {
        guard let cur = diskIOTotals() else { return (0, 0) }
        let now = Date()
        stateLock.lock(); defer { stateLock.unlock() }
        defer { prevDisk = cur; prevDiskTime = now }
        guard let prev = prevDisk, let prevT = prevDiskTime else { return (0, 0) }
        let dt = now.timeIntervalSince(prevT)
        guard dt > 0.1 else { return (0, 0) }
        // 卸载外置盘会让累计值回退——出现负差时按 0 处理
        let dr = cur.read >= prev.read ? Double(cur.read - prev.read) : 0
        let dw = cur.write >= prev.write ? Double(cur.write - prev.write) : 0
        return (dr / dt, dw / dt)
    }

    /// 汇总所有块存储驱动的累计读写字节。
    private func diskIOTotals() -> (read: UInt64, write: UInt64)? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault,
                                           IOServiceMatching("IOBlockStorageDriver"), &iterator) == KERN_SUCCESS else {
            return nil
        }
        defer { IOObjectRelease(iterator) }
        var read: UInt64 = 0, write: UInt64 = 0, found = false
        var service = IOIteratorNext(iterator)
        while service != 0 {
            if let prop = IORegistryEntryCreateCFProperty(service, "Statistics" as CFString, kCFAllocatorDefault, 0),
               let stats = prop.takeRetainedValue() as? [String: Any] {
                read += (stats["Bytes (Read)"] as? NSNumber)?.uint64Value ?? 0
                write += (stats["Bytes (Write)"] as? NSNumber)?.uint64Value ?? 0
                found = true
            }
            IOObjectRelease(service)
            service = IOIteratorNext(iterator)
        }
        return found ? (read, write) : nil
    }

    /// GPU EMA 平滑（见 gpuEMA 注释）。读不到时清状态，避免陈旧值假装还活着。
    private func smoothedGPU(_ raw: Double?) -> Double? {
        stateLock.lock(); defer { stateLock.unlock() }
        guard let raw else { gpuEMA = nil; return nil }
        let next = gpuEMA.map { 0.35 * raw + 0.65 * $0 } ?? raw
        gpuEMA = next
        return next
    }

    // MARK: CPU 聚合

    private func sampleCPU() -> (busy: Double, user: Double, system: Double) {
        guard let cur = cpuTicks() else { return (0, 0, 0) }
        stateLock.lock(); defer { stateLock.unlock() }
        defer { prevCPU = cur }
        guard let prev = prevCPU else { return (0, 0, 0) }
        let user = Double(cur.cpu_ticks.0) - Double(prev.cpu_ticks.0)
        let sys  = Double(cur.cpu_ticks.1) - Double(prev.cpu_ticks.1)
        let idle = Double(cur.cpu_ticks.2) - Double(prev.cpu_ticks.2)
        let nice = Double(cur.cpu_ticks.3) - Double(prev.cpu_ticks.3)
        let busy = max(0, user + sys + nice)
        let total = busy + max(0, idle)
        guard total > 0 else { return (0, 0, 0) }
        return (busy / total, (user + nice) / total, sys / total)
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

    // MARK: CPU 每核心（host_processor_info / PROCESSOR_CPU_LOAD_INFO）

    private func samplePerCore() -> [Double] {
        var cpuCount: natural_t = 0
        var infoArray: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        let kr = host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO,
                                     &cpuCount, &infoArray, &infoCount)
        guard kr == KERN_SUCCESS, let array = infoArray else { return [] }
        defer {
            let size = vm_size_t(UInt(infoCount) * UInt(MemoryLayout<integer_t>.size))
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: array), size)
        }

        var cur: [(user: UInt32, system: UInt32, idle: UInt32, nice: UInt32)] = []
        cur.reserveCapacity(Int(cpuCount))
        for i in 0..<Int(cpuCount) {
            let base = i * Int(CPU_STATE_MAX)
            let user = UInt32(bitPattern: array[base + Int(CPU_STATE_USER)])
            let system = UInt32(bitPattern: array[base + Int(CPU_STATE_SYSTEM)])
            let idle = UInt32(bitPattern: array[base + Int(CPU_STATE_IDLE)])
            let nice = UInt32(bitPattern: array[base + Int(CPU_STATE_NICE)])
            cur.append((user, system, idle, nice))
        }

        stateLock.lock(); defer { stateLock.unlock() }
        defer { prevPerCore = cur }
        guard let prev = prevPerCore, prev.count == cur.count else { return Array(repeating: 0, count: cur.count) }

        return (0..<cur.count).map { i in
            let du = Double(cur[i].user &- prev[i].user)
            let ds = Double(cur[i].system &- prev[i].system)
            let dn = Double(cur[i].nice &- prev[i].nice)
            let di = Double(cur[i].idle &- prev[i].idle)
            let busy = max(0, du + ds + dn)
            let total = busy + max(0, di)
            return total > 0 ? min(1, busy / total) : 0
        }
    }

    // MARK: 内存（活动监视器口径）

    private func sampleMemory() -> (used: Int64, total: Int64, app: Int64, wired: Int64, compressed: Int64, cached: Int64, pageIns: Int64, pageOuts: Int64) {
        let total = Int64(ProcessInfo.processInfo.physicalMemory)
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &stats) { ptr -> kern_return_t in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return (0, total, 0, 0, 0, 0, 0, 0) }
        let page = Int64(getpagesize())
        // 活动监视器口径：
        //   应用内存 = internal_page_count − purgeable_count
        //   联动     = wire_count
        //   已压缩   = compressor_page_count
        //   缓存文件 = external_page_count + purgeable_count（计入「可用」）
        //   已使用   = 应用 + 联动 + 已压缩
        let purgeable = Int64(stats.purgeable_count)
        let internalPages = Int64(stats.internal_page_count)
        let external = Int64(stats.external_page_count)
        let app = max(0, (internalPages - purgeable)) * page
        let wired = Int64(stats.wire_count) * page
        let compressed = Int64(stats.compressor_page_count) * page
        let cached = (external + purgeable) * page
        let used = app + wired + compressed
        let pageIns = Int64(stats.pageins) * page
        let pageOuts = Int64(stats.pageouts) * page
        return (used, total, app, wired, compressed, cached, pageIns, pageOuts)
    }

    /// CPU 当前频率（MHz）：性能核 / 能效核。经 IOReport DVFS 驻留率加权。
    /// 不可用（Intel / 接口变更）返回 nil。内部阻塞约 90ms，请在后台调用。
    public func cpuFrequency() -> (performance: Double, efficiency: Double)? {
        var p: Double = 0, e: Double = 0
        return xico_cpu_frequency(&p, &e) == 1 ? (p, e) : nil
    }

    /// 内存压力等级：1=正常 2=警告 4=危险。
    private func memoryPressureLevel() -> Int {
        var level: Int32 = 1
        var size = MemoryLayout<Int32>.size
        return sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0) == 0 ? Int(level) : 1
    }

    private func sampleSwap() -> (used: Int64, total: Int64) {
        var usage = xsw_usage()
        var size = MemoryLayout<xsw_usage>.stride
        var mib: [Int32] = [CTL_VM, VM_SWAPUSAGE]
        let r = sysctl(&mib, 2, &usage, &size, nil, 0)
        guard r == 0 else { return (0, 0) }
        return (Int64(usage.xsu_used), Int64(usage.xsu_total))
    }

    private func loadAverage() -> (Double, Double, Double) {
        var loads = [Double](repeating: 0, count: 3)
        guard getloadavg(&loads, 3) == 3 else { return (0, 0, 0) }
        return (loads[0], loads[1], loads[2])
    }

    // MARK: 网络速率（NET_RT_IFLIST2，64 位计数，排除虚拟接口）

    private func sampleNetwork() -> (down: Double, up: Double) {
        let cur = netCounters()
        let now = Date()
        stateLock.lock(); defer { stateLock.unlock() }
        defer { prevNet = cur; prevNetTime = now }
        guard let prev = prevNet, let prevTime = prevNetTime else { return (0, 0) }
        let dt = now.timeIntervalSince(prevTime)
        guard dt > 0 else { return (0, 0) }
        // 64 位计数几乎不会回绕；仍做 >= 保护防止接口重置
        let down = cur.down >= prev.down ? Double(cur.down - prev.down) / dt : 0
        let up = cur.up >= prev.up ? Double(cur.up - prev.up) / dt : 0
        return (down, up)
    }

    /// 只统计物理网络接口（en/ppp 等），排除 lo/utun/awdl/llw/bridge/gif/stf/ap/anpi 等虚拟接口，
    /// 避免 VPN 双倍计费与自组网干扰。
    private func netCounters() -> (down: UInt64, up: UInt64) {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var len = 0
        guard sysctl(&mib, 6, nil, &len, nil, 0) == 0, len > 0 else { return (0, 0) }
        var buf = [UInt8](repeating: 0, count: len)
        guard sysctl(&mib, 6, &buf, &len, nil, 0) == 0 else { return (0, 0) }

        var down: UInt64 = 0, up: UInt64 = 0
        buf.withUnsafeBytes { raw in
            var offset = 0
            while offset + MemoryLayout<if_msghdr>.size <= len {
                let hdr = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr.self)
                let msglen = Int(hdr.ifm_msglen)
                guard msglen > 0, offset + msglen <= len else { break }
                // 读 if_msghdr2（160 字节，大于 if_msghdr）前先确认可安全读取，防越界读
                if hdr.ifm_type == UInt8(RTM_IFINFO2),
                   offset + MemoryLayout<if_msghdr2>.size <= len {
                    let if2 = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr2.self)
                    if includeInterface(index: if2.ifm_index) {
                        down += if2.ifm_data.ifi_ibytes
                        up += if2.ifm_data.ifi_obytes
                    }
                }
                offset += msglen
            }
        }
        return (down, up)
    }

    private func includeInterface(index: UInt16) -> Bool {
        var nameBuf = [CChar](repeating: 0, count: Int(IF_NAMESIZE))
        guard if_indextoname(UInt32(index), &nameBuf) != nil else { return false }
        let name = String(cString: nameBuf)
        let excludedPrefixes = ["lo", "utun", "awdl", "llw", "bridge", "gif", "stf", "ap", "anpi", "XHC"]
        return !excludedPrefixes.contains { name.hasPrefix($0) }
    }

    // MARK: 电池（IOPSCopyPowerSourcesInfo，公开 API）

    private func batteryStatus() -> (percent: Int?, charging: Bool) {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef],
              let first = sources.first,
              let desc = IOPSGetPowerSourceDescription(blob, first)?.takeUnretainedValue() as? [String: Any]
        else { return (nil, false) }
        let cur = desc[kIOPSCurrentCapacityKey] as? Int
        let max = desc[kIOPSMaxCapacityKey] as? Int
        let charging = (desc[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue
        if let c = cur, let m = max, m > 0 {
            return (Int((Double(c) / Double(m) * 100).rounded()), charging)
        }
        return (nil, charging)
    }

    // MARK: 温度（公开热状态）

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
        let profile = hardware.staticProfile()
        return MacInfo(
            model: profile.marketingName,
            chip: profile.chip,
            macOS: profile.macOS,
            memory: profile.memoryDescription,
            cores: profile.totalCores,
            performanceCores: profile.performanceCores,
            efficiencyCores: profile.efficiencyCores,
            coreClusters: hardware.cpuClusterTypes(),
            uptime: formatUptime(bootUptime()))
    }

    /// 用 kern.boottime 计算真实开机时长（systemUptime 在睡眠时会漂移）。
    private func bootUptime() -> TimeInterval {
        var mib: [Int32] = [CTL_KERN, KERN_BOOTTIME]
        var boot = timeval()
        var size = MemoryLayout<timeval>.stride
        guard sysctl(&mib, 2, &boot, &size, nil, 0) == 0, boot.tv_sec != 0 else {
            return ProcessInfo.processInfo.systemUptime
        }
        return Date().timeIntervalSince1970 - Double(boot.tv_sec)
    }

    private func formatUptime(_ seconds: TimeInterval) -> String {
        let d = Int(seconds) / 86400
        let h = (Int(seconds) % 86400) / 3600
        let m = (Int(seconds) % 3600) / 60
        if d > 0 { return xLocF("%d 天 %d 小时", d, h) }
        if h > 0 { return xLocF("%d 小时 %d 分", h, m) }
        return xLocF("%d 分", m)
    }
}

public extension Double {
    /// 速率格式化，如 "1.2 MB/s"（0 显示为 "0 KB/s"）
    var formattedRate: String {
        if self < 1 { return "0 KB/s" }
        return Int64(self).formattedBytes + "/s"
    }
    /// 菜单栏紧凑速率，如 "1.2M" / "386K"。空闲也带单位后缀（"0K"），
    /// 绝不显示裸露无单位的 "0"（对标 iStat 的刀锋级读数）。
    var compactRate: String {
        if self >= 1_000_000 { return String(format: "%.1fM", self / 1_000_000) }
        if self >= 1_000 { return String(format: "%.0fK", self / 1_000) }
        return "0K"
    }
}
