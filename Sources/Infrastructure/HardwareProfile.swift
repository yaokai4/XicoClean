import Foundation
import DesignSystem
import IOKit
import Metal
import AppKit
import CSensors

// MARK: - 数据模型

/// 机器静态档案（生命周期内不变，取一次即缓存）。
public struct HardwareProfile: Sendable {
    public let marketingName: String     // "MacBook Pro (13-inch, M1, 2020)"
    public let chip: String              // "Apple M1" / Intel brand string
    public let modelIdentifier: String   // "MacBookPro17,1"
    public let modelNumber: String       // "Z11C000HFJ/A"（可能为空）
    public let serialNumber: String
    public let memoryDescription: String // "16 GB LPDDR4X" / "16 GB 统一内存"
    public let coreDescription: String   // "8 核（4 性能 + 4 能效）"
    public let performanceCores: Int
    public let efficiencyCores: Int
    public let totalCores: Int
    public let macOS: String
    public let isAppleSilicon: Bool
}

/// system_profiler 派生的补充档案（较慢，后台按需加载，复用缓存的 profiler JSON）。
/// 与 HardwareProfile 分离：让 AppModel 冷启动只走微秒级快通道，型号编号/内存规格这类
/// 需要子进程的字段异步补齐。
public struct HardwareDetails: Sendable {
    public let modelNumber: String       // "Z11C000HFJ/A"，部分机型为空
    public let memoryType: String        // "LPDDR5" / "DDR4"，读不到为空
    public let memorySpeed: String       // "6400 MT/s" / "3733 MHz"，Apple Silicon 常为空
    public let memoryManufacturer: String // "Samsung" / "Micron"，读不到为空（AS 通常不透传）
    public let memorySlots: String       // Intel："已用 2 / 共 4"；Apple Silicon："板载"；读不到为空
    public init(modelNumber: String, memoryType: String, memorySpeed: String,
                memoryManufacturer: String = "", memorySlots: String = "") {
        self.modelNumber = modelNumber
        self.memoryType = memoryType
        self.memorySpeed = memorySpeed
        self.memoryManufacturer = memoryManufacturer
        self.memorySlots = memorySlots
    }
}

/// 电池健康。
public struct BatteryHealth: Sendable {
    public let healthPercent: Int        // 满充/设计 容量比（对齐系统设置"最大容量"）
    public let cycleCount: Int
    public let designCapacity: Int       // mAh
    public let fullChargeCapacity: Int   // mAh（NominalChargeCapacity）
    public let currentChargePercent: Int
    public let temperature: Double       // ℃
    public let voltage: Double           // V
    public let powerWatts: Double        // 正=充电，负=放电
    public let isCharging: Bool
    public let externalConnected: Bool
    public let condition: String         // "正常" / "维修" 等
    public let serialNumber: String
}

/// GPU 信息。
public struct GPUInfo: Sendable {
    public let name: String
    public let coreCount: Int?
    public let utilizationPercent: Double?   // 实时占用（IOAccelerator）
    public let inUseMemoryBytes: Int64?
}

/// 内置 NVMe SSD 的 S.M.A.R.T. 详细读数。
public struct NVMeSMART: Sendable {
    public let percentUsed: Int          // 寿命消耗 %
    public let availableSpare: Int       // 可用备用块 %
    public let temperature: Int          // ℃
    public let powerOnHours: Int
    public let terabytesWritten: Double  // 累计写入量（TB）
    public let unsafeShutdowns: Int
    public let hasWarning: Bool
    /// 剩余寿命 %（100 − 消耗，下限 0）。
    public var lifeRemaining: Int { max(0, 100 - percentUsed) }
}

/// 单块存储卷的健康与容量。
public struct StorageHealth: Sendable, Identifiable {
    public let id: String
    public let name: String
    public let model: String
    public let totalBytes: Int64
    public let freeBytes: Int64
    public let smartStatus: String       // "Verified" / "不支持" 等
    public let trimEnabled: Bool?
    public let isInternal: Bool
    public var usedFraction: Double {
        totalBytes > 0 ? Double(totalBytes - freeBytes) / Double(totalBytes) : 0
    }
}

/// 显示器信息。
public struct DisplayInfo: Sendable, Identifiable {
    public let id: Int
    public let name: String
    public let pixelWidth: Int
    public let pixelHeight: Int
    public let pointWidth: Int         // 逻辑分辨率（缩放后）
    public let pointHeight: Int
    public let refreshHz: Int
    public let scale: Double
    public let isBuiltin: Bool
    public let diagonalInches: Double? // 物理对角线（英寸）
    public let isHDR: Bool
    public let proMotion: Bool         // 支持 >60Hz 可变刷新（由真实可用模式推导；读不到即 false）
    public var resolutionText: String { "\(pixelWidth) × \(pixelHeight)" }
    public var scaledText: String { "\(pointWidth) × \(pointHeight) @ \(String(format: "%.1f", scale))x" }
}

// MARK: - 服务

/// 硬件档案与健康的读取器。全部通道无需 root、Developer ID 直销可行。
/// 静态档案缓存；电池/存储/GPU 为按需刷新（调用方自行控制频率）。
public final class HardwareProfileService: @unchecked Sendable {
    private let lock = NSLock()
    private var cachedProfile: HardwareProfile?
    private var cachedProfilerJSON: [String: Any]?
    private var cachedClusters: [Bool]?

    public init() {}

    // MARK: 每逻辑 CPU 的簇类型（性能核 / 能效核）

    /// 每个逻辑 CPU 是否为性能核（true=P，false=E），按 logical-cpu-id 升序索引——
    /// 与 host_processor_info / perCore 数组顺序一一对应。权威读自 IODeviceTree 的 `cluster-type`，
    /// 不猜核序（Apple Silicon 上 E 簇通常在前，但以真实读数为准）。Intel / 读不到返回空数组。
    public func cpuClusterTypes() -> [Bool] {
        lock.lock()
        if let c = cachedClusters { lock.unlock(); return c }
        lock.unlock()

        var pairs: [(id: Int, perf: Bool)] = []
        let root = IORegistryEntryFromPath(kIOMainPortDefault, "IODeviceTree:/cpus")
        if root != 0 {
            defer { IOObjectRelease(root) }
            var iter: io_iterator_t = 0
            if IORegistryEntryGetChildIterator(root, "IODeviceTree", &iter) == KERN_SUCCESS {
                defer { IOObjectRelease(iter) }
                var child = IOIteratorNext(iter)
                while child != 0 {
                    if let id = ioRegInt(child, "logical-cpu-id"),
                       let ct = clusterTypeString(child) {
                        pairs.append((id, ct.uppercased().hasPrefix("P")))
                    }
                    IOObjectRelease(child)
                    child = IOIteratorNext(iter)
                }
            }
        }
        let sorted = pairs.sorted { $0.id < $1.id }.map(\.perf)
        lock.lock(); cachedClusters = sorted; lock.unlock()
        return sorted
    }

    /// 读 cpu 节点的 `cluster-type`（Data "E"/"P"，可能带 NUL；个别机型为 String）。
    private func clusterTypeString(_ entry: io_registry_entry_t) -> String? {
        guard let prop = IORegistryEntryCreateCFProperty(entry, "cluster-type" as CFString, kCFAllocatorDefault, 0) else { return nil }
        let value = prop.takeRetainedValue()
        if let data = value as? Data {
            return String(data: data, encoding: .utf8)?.trimmingCharacters(in: CharacterSet(charactersIn: "\0 \n"))
        }
        return value as? String
    }

    // MARK: 静态档案

    public func staticProfile() -> HardwareProfile {
        lock.lock()
        if let p = cachedProfile { lock.unlock(); return p }
        lock.unlock()

        let isAS = isAppleSiliconMachine()
        let chip = sysctlString("machdep.cpu.brand_string")
        let modelID = sysctlString("hw.model")
        let (pCores, eCores, total) = coreCounts()
        let memBytes = Int64(ProcessInfo.processInfo.physicalMemory)
        let v = ProcessInfo.processInfo.operatingSystemVersion

        // 关键：静态档案只走「快速」通道（IORegistry + sysctl，微秒级）。
        // 营销名主路径 IODeviceTree product-name；system_profiler（1-3s 子进程）绝不在此调用——
        // 否则 AppModel.init 冷启动会同步阻塞主线程。型号编号/内存类型/GPU 核数等 system_profiler
        // 派生字段留给 HardwareView 在后台队列按需补充（profilerExtras）。
        let marketing = ioRegMarketingName() ?? friendlyModel(from: modelID)
        // 内存容量按二进制 GB 取整显示（如 16GiB → "16 GB"，对齐 Apple 关于本机）
        let memGB = Int((Double(memBytes) / 1_073_741_824.0).rounded())
        let memDesc = isAS ? xLocF("%d GB 统一内存", memGB) : "\(memGB) GB"
        let coreDesc = isAS && pCores > 0 && eCores > 0
            ? xLocF("%d 核（%d 性能 + %d 能效）", total, pCores, eCores)
            : xLocF("%d 核", total)

        let profile = HardwareProfile(
            marketingName: marketing,
            chip: chip.isEmpty ? "Apple Silicon" : chip,
            modelIdentifier: modelID,
            modelNumber: "",
            serialNumber: platformSerial(),
            memoryDescription: memDesc,
            coreDescription: coreDesc,
            performanceCores: pCores,
            efficiencyCores: eCores,
            totalCores: total,
            macOS: "macOS \(v.majorVersion).\(v.minorVersion).\(v.patchVersion)",
            isAppleSilicon: isAS)

        lock.lock(); cachedProfile = profile; lock.unlock()
        return profile
    }

    private func isAppleSiliconMachine() -> Bool {
        #if arch(arm64)
        return true
        #else
        return false
        #endif
    }

    private func coreCounts() -> (p: Int, e: Int, total: Int) {
        let total = sysctlInt("hw.logicalcpu") ?? ProcessInfo.processInfo.processorCount
        let p = sysctlInt("hw.perflevel0.logicalcpu") ?? 0
        let e = sysctlInt("hw.perflevel1.logicalcpu") ?? 0
        return (p, e, total)
    }

    /// IODeviceTree:/product 的 product-name（Apple Silicon 上是营销全名，含年份）。
    private func ioRegMarketingName() -> String? {
        let entry = IORegistryEntryFromPath(kIOMainPortDefault, "IODeviceTree:/product")
        guard entry != 0 else { return nil }
        defer { IOObjectRelease(entry) }
        guard let prop = IORegistryEntryCreateCFProperty(entry, "product-name" as CFString, kCFAllocatorDefault, 0) else { return nil }
        let value = prop.takeRetainedValue()
        if let data = value as? Data {
            return String(data: data, encoding: .utf8)?.trimmingCharacters(in: CharacterSet(charactersIn: "\0 \n"))
        }
        if let s = value as? String { return s }
        return nil
    }

    private func platformSerial() -> String {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
        guard service != 0 else { return "" }
        defer { IOObjectRelease(service) }
        guard let prop = IORegistryEntryCreateCFProperty(service, kIOPlatformSerialNumberKey as CFString, kCFAllocatorDefault, 0) else { return "" }
        return (prop.takeRetainedValue() as? String) ?? ""
    }

    // MARK: 电池（IORegistry AppleSmartBattery）

    public func battery() -> BatteryHealth? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }

        func int(_ key: String) -> Int? { ioRegInt(service, key) }
        func bool(_ key: String) -> Bool? { ioRegBool(service, key) }

        // 台式机无此节点；某些机型键缺失时返回 nil
        guard let design = int("DesignCapacity"), design > 0 else { return nil }
        // 满充容量：优先 AppleRawMaxCapacity（mAh），退回 NominalChargeCapacity
        let fullCharge = int("AppleRawMaxCapacity") ?? int("NominalChargeCapacity") ?? design
        // 健康 %：对齐系统设置用 NominalChargeCapacity/DesignCapacity
        let nominal = int("NominalChargeCapacity") ?? fullCharge
        let health = min(100, Int((Double(nominal) / Double(design) * 100).rounded()))

        let cycles = int("CycleCount") ?? 0
        let rawCurrent = int("AppleRawCurrentCapacity") ?? 0
        let chargePercent = int("CurrentCapacity") ?? (fullCharge > 0 ? Int(Double(rawCurrent) / Double(fullCharge) * 100) : 0)
        let tempRaw = int("Temperature") ?? 0        // 百分之一 ℃
        let voltage = Double(int("Voltage") ?? 0) / 1000.0
        let amperage = Double(int("Amperage") ?? 0) / 1000.0   // A（负=放电）
        let power = voltage * amperage
        let charging = bool("IsCharging") ?? false
        let external = bool("ExternalConnected") ?? false
        let serial = ioRegString(service, "Serial") ?? ""

        return BatteryHealth(
            healthPercent: health,
            cycleCount: cycles,
            designCapacity: design,
            fullChargeCapacity: fullCharge,
            currentChargePercent: max(0, min(100, chargePercent)),
            temperature: Double(tempRaw) / 100.0,
            voltage: voltage,
            powerWatts: power,
            isCharging: charging,
            externalConnected: external,
            condition: health >= 80 ? "正常" : "建议维修",
            serialNumber: serial)
    }

    // MARK: GPU（Metal 名称 + IOAccelerator 占用）

    public func gpu() -> GPUInfo? {
        let device = MTLCreateSystemDefaultDevice()
        let name = device?.name ?? "GPU"
        let (util, mem) = acceleratorPerformance()
        let cores = gpuCoreCount()
        return GPUInfo(name: name, coreCount: cores, utilizationPercent: util, inUseMemoryBytes: mem)
    }

    /// 遍历 IOAccelerator 读 PerformanceStatistics 的 "Device Utilization %" 与在用显存。
    public func acceleratorPerformance() -> (utilization: Double?, inUseMemory: Int64?) {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iterator) == KERN_SUCCESS else {
            return (nil, nil)
        }
        defer { IOObjectRelease(iterator) }

        var util: Double?
        var inUse: Int64?
        var service = IOIteratorNext(iterator)
        while service != 0 {
            if let prop = IORegistryEntryCreateCFProperty(service, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0),
               let stats = prop.takeRetainedValue() as? [String: Any] {
                if let u = (stats["Device Utilization %"] as? NSNumber)?.doubleValue { util = u }
                if let m = (stats["In use system memory"] as? NSNumber)?.int64Value { inUse = m }
            }
            IOObjectRelease(service)
            service = IOIteratorNext(iterator)
        }
        return (util, inUse)
    }

    private func gpuCoreCount() -> Int? {
        guard let displays = hardwareProfilerData()["SPDisplaysDataType"] as? [[String: Any]] else { return nil }
        for d in displays {
            if let cores = d["sppci_cores"] as? String, let n = Int(cores) { return n }
        }
        return nil
    }

    // MARK: 存储健康

    public func storageHealth() -> [StorageHealth] {
        var out: [StorageHealth] = []
        let keys: [URLResourceKey] = [.volumeNameKey, .volumeTotalCapacityKey,
                                      .volumeAvailableCapacityForImportantUsageKey,
                                      .volumeIsInternalKey, .volumeIsBrowsableKey]
        guard let vols = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys,
                                                               options: [.skipHiddenVolumes]) else { return out }
        // NVMe 元数据（SMART 状态 / TRIM / 型号）一次性取
        let nvme = nvmeInfo()
        for url in vols {
            guard let vals = try? url.resourceValues(forKeys: Set(keys)),
                  vals.volumeIsBrowsable == true,
                  let total = vals.volumeTotalCapacity, total > 0 else { continue }
            let name = vals.volumeName ?? url.lastPathComponent
            let free = Int64(vals.volumeAvailableCapacityForImportantUsage ?? 0)
            let isInternal = vals.volumeIsInternal ?? false
            out.append(StorageHealth(
                id: url.path,
                name: name,
                model: isInternal ? (nvme.model ?? "内置固态硬盘") : "外置磁盘",
                totalBytes: Int64(total),
                freeBytes: free,
                smartStatus: isInternal ? (nvme.smartStatus.map(Self.localizedSMART) ?? "—") : "外置设备不透传",
                trimEnabled: isInternal ? nvme.trim : nil,
                isInternal: isInternal))
        }
        // 内置系统卷排最前
        return out.sorted { ($0.isInternal ? 0 : 1, -$0.totalBytes) < ($1.isInternal ? 0 : 1, -$1.totalBytes) }
    }

    /// 内置盘 S.M.A.R.T. 详细日志（IONVMeSMARTUserClient）。外置/不支持返回 nil。
    public func nvmeSMART() -> NVMeSMART? {
        var raw = XicoNVMeSMART()
        guard xico_read_nvme_smart(&raw) == 1 else { return nil }
        // 每写入单位 = 512000 字节；TBW = units × 512000 / 1e12
        let tbw = Double(raw.data_units_written) * 512_000.0 / 1_000_000_000_000.0
        return NVMeSMART(
            percentUsed: Int(raw.percent_used),
            availableSpare: Int(raw.available_spare),
            temperature: Int(raw.temperature_celsius),
            // clamping：异常/损坏读数（UInt64 超 Int.max）不触发陷阱崩溃，饱和到上限
            powerOnHours: Int(clamping: raw.power_on_hours),
            terabytesWritten: tbw,
            unsafeShutdowns: Int(clamping: raw.unsafe_shutdowns),
            hasWarning: raw.critical_warning != 0)
    }

    private struct NVMeInfo {
        var model: String?
        var serial: String?
        var revision: String?
        var smartStatus: String?
        var trim: Bool?
    }

    private func nvmeInfo() -> NVMeInfo {
        var info = NVMeInfo()
        guard let controllers = hardwareProfilerData()["SPNVMeDataType"] as? [[String: Any]] else { return info }
        for controller in controllers {
            guard let drives = controller["_items"] as? [[String: Any]] else { continue }
            for drive in drives {
                info.model = (drive["device_model"] as? String) ?? (drive["_name"] as? String)
                info.serial = drive["device_serial"] as? String
                info.revision = drive["device_revision"] as? String
                if let smart = drive["smart_status"] as? String { info.smartStatus = smart }
                if let trim = drive["spnvme_trim_support"] as? String { info.trim = (trim == "Yes") }
            }
        }
        return info
    }

    /// 内置盘的 SMART 状态本地化。
    public static func localizedSMART(_ raw: String) -> String {
        switch raw.lowercased() {
        case "verified": return "正常"
        case "failing", "not verified": return "警告"
        default: return raw
        }
    }

    // MARK: 显示器

    public func displays() -> [DisplayInfo] {
        var out: [DisplayInfo] = []
        for (i, screen) in NSScreen.screens.enumerated() {
            let num = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
            let scale = screen.backingScaleFactor
            let pointW = Int(screen.frame.width)
            let pointH = Int(screen.frame.height)
            var w = Int(screen.frame.width * scale)
            var h = Int(screen.frame.height * scale)
            var refresh = 60
            var diagonal: Double? = nil
            var proMotion = false
            if num != 0 {
                let did = CGDirectDisplayID(num)
                if let mode = CGDisplayCopyDisplayMode(did) {
                    w = mode.pixelWidth; h = mode.pixelHeight
                    if mode.refreshRate > 0 { refresh = Int(mode.refreshRate.rounded()) }
                }
                // ProMotion = 该显示器**真实支持** >60Hz 的可变刷新（枚举全部可用模式取最高）。
                // 读不到模式表即 false，绝不臆测。
                if let modes = CGDisplayCopyAllDisplayModes(did, nil) as? [CGDisplayMode] {
                    let maxHz = modes.map { $0.refreshRate }.max() ?? 0
                    proMotion = maxHz > 60.5
                    if maxHz.rounded() > Double(refresh) { refresh = max(refresh, Int(maxHz.rounded())) }
                }
                let sizeMM = CGDisplayScreenSize(did)   // 毫米
                if sizeMM.width > 0 && sizeMM.height > 0 {
                    let diagMM = (sizeMM.width * sizeMM.width + sizeMM.height * sizeMM.height).squareRoot()
                    diagonal = diagMM / 25.4
                }
            }
            let builtin = num != 0 ? (CGDisplayIsBuiltin(CGDirectDisplayID(num)) != 0) : false
            let hdr = screen.maximumPotentialExtendedDynamicRangeColorComponentValue > 1.0
            let name = screen.localizedName
            out.append(DisplayInfo(id: i, name: name.isEmpty ? xLocF("显示器 %d", i+1) : name,
                                   pixelWidth: w, pixelHeight: h, pointWidth: pointW, pointHeight: pointH,
                                   refreshHz: refresh, scale: Double(scale), isBuiltin: builtin,
                                   diagonalInches: diagonal, isHDR: hdr, proMotion: proMotion))
        }
        return out
    }

    // MARK: system_profiler（后台一次，缓存）

    private func hardwareProfilerData() -> [String: Any] {
        lock.lock()
        if let c = cachedProfilerJSON { lock.unlock(); return c }
        lock.unlock()
        let json = runSystemProfiler(["SPHardwareDataType", "SPNVMeDataType", "SPDisplaysDataType", "SPMemoryDataType"])
        var flattened: [String: Any] = [:]
        // SPHardwareDataType → 顶层键（machine_name/model_number 等）
        if let hw = (json["SPHardwareDataType"] as? [[String: Any]])?.first {
            for (k, v) in hw { flattened[k] = v }
        }
        flattened["SPNVMeDataType"] = json["SPNVMeDataType"]
        flattened["SPDisplaysDataType"] = json["SPDisplaysDataType"]
        if let mem = (json["SPMemoryDataType"] as? [[String: Any]])?.first {
            flattened["SPMemoryDataType"] = mem
        }
        lock.lock(); cachedProfilerJSON = flattened; lock.unlock()
        return flattened
    }

    private func runSystemProfiler(_ types: [String]) -> [String: Any] {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
        task.arguments = ["-json"] + types
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        do {
            try task.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            task.waitUntilExit()
            return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        } catch {
            return [:]
        }
    }

    // MARK: 补充档案（型号编号 / 内存规格）

    /// 从（缓存的）system_profiler 数据派生型号编号与内存规格。首次调用会触发 profiler
    /// 子进程（1–3s），务必在后台队列调用；之后走缓存，微秒级。
    public func profilerDetails() -> HardwareDetails {
        let data = hardwareProfilerData()
        let modelNumber = ((data["model_number"] as? String) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        var memType = "", memSpeed = "", memMfr = "", memSlots = ""
        if let mem = data["SPMemoryDataType"] as? [String: Any] {
            let parsed = Self.parseMemorySpec(mem)
            memType = parsed.type; memSpeed = parsed.speed
            let extras = Self.parseMemoryExtras(mem, isAppleSilicon: isAppleSiliconMachine())
            memMfr = extras.manufacturer; memSlots = extras.slots
        } else if isAppleSiliconMachine() {
            memSlots = xLoc("板载")
        }
        return HardwareDetails(modelNumber: modelNumber, memoryType: memType, memorySpeed: memSpeed,
                               memoryManufacturer: memMfr, memorySlots: memSlots)
    }

    /// 解析内存制造商与插槽占用。Intel：逐条 DIMM（制造商 + 已用/总插槽）；
    /// Apple Silicon：统一内存板载（"板载"）。读不到安静留空，UI 隐藏该行——绝不编造。
    static func parseMemoryExtras(_ mem: [String: Any], isAppleSilicon: Bool) -> (manufacturer: String, slots: String) {
        func cleanMfr(_ raw: String) -> String {
            let t = raw.trimmingCharacters(in: .whitespaces)
            let low = t.lowercased()
            if t.isEmpty || low.contains("empty") || low.contains("unknown")
                || low.contains("noname") || low.hasPrefix("0x") { return "" }
            return t
        }
        if let items = mem["_items"] as? [[String: Any]] {
            var total = 0, used = 0, mfr = ""
            for dimm in items {
                total += 1
                let status = ((dimm["dimm_status"] as? String) ?? "").lowercased()
                let size = ((dimm["dimm_size"] as? String) ?? "").lowercased()
                let occupied = !(status.contains("empty") || size.contains("empty") || size == "0 gb" || size.isEmpty)
                if occupied {
                    used += 1
                    if mfr.isEmpty { mfr = cleanMfr((dimm["dimm_manufacturer"] as? String) ?? "") }
                }
            }
            let slots = total > 0 ? xLocF("已用 %d / 共 %d", used, total) : (isAppleSilicon ? xLoc("板载") : "")
            return (mfr, slots)
        }
        let mfr = cleanMfr((mem["dimm_manufacturer"] as? String) ?? "")
        return (mfr, isAppleSilicon ? xLoc("板载") : "")
    }

    /// 解析内存类型/速率。Intel：逐条 DIMM（_items）；Apple Silicon：单条整机内存。
    /// 键名随机型/系统版本略有出入，故对所有字符串值做 DDR 关键字兜底扫描——
    /// 目标是「在每台 Mac 上都尽量识别到内存规格」，识别不到则安静留空（UI 隐藏该行）。
    static func parseMemorySpec(_ mem: [String: Any]) -> (type: String, speed: String) {
        func normalizeType(_ s: String) -> String {
            let up = s.uppercased().replacingOccurrences(of: "_", with: "")
            return up.contains("DDR") ? up : ""
        }
        // Intel：逐条 DIMM，取首条已装配的
        if let items = mem["_items"] as? [[String: Any]] {
            for dimm in items {
                let t = normalizeType((dimm["dimm_type"] as? String) ?? "")
                if !t.isEmpty {
                    let sp = ((dimm["dimm_speed"] as? String) ?? "").trimmingCharacters(in: .whitespaces)
                    return (t, sp)
                }
            }
        }
        // Apple Silicon / 兜底：直接键 + 全值扫描
        if let t = mem["dimm_type"] as? String {
            let n = normalizeType(t)
            if !n.isEmpty { return (n, ((mem["dimm_speed"] as? String) ?? "")) }
        }
        for v in mem.values {
            if let s = v as? String {
                let n = normalizeType(s)
                if !n.isEmpty { return (n, "") }
            }
        }
        return ("", "")
    }

    private func friendlyModel(from identifier: String) -> String {
        if identifier.contains("MacBookPro") { return "MacBook Pro" }
        if identifier.contains("MacBookAir") { return "MacBook Air" }
        if identifier.contains("MacBook") { return "MacBook" }
        if identifier.contains("Macmini") { return "Mac mini" }
        if identifier.contains("MacStudio") { return "Mac Studio" }
        if identifier.contains("MacPro") { return "Mac Pro" }
        if identifier.contains("iMac") { return "iMac" }
        if identifier.contains("Mac") { return "Mac" }
        return identifier.isEmpty ? "Mac" : identifier
    }

    // MARK: IORegistry / sysctl 辅助

    private func ioRegInt(_ service: io_registry_entry_t, _ key: String) -> Int? {
        guard let prop = IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0) else { return nil }
        return (prop.takeRetainedValue() as? NSNumber)?.intValue
    }
    private func ioRegBool(_ service: io_registry_entry_t, _ key: String) -> Bool? {
        guard let prop = IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0) else { return nil }
        return (prop.takeRetainedValue() as? NSNumber)?.boolValue
    }
    private func ioRegString(_ service: io_registry_entry_t, _ key: String) -> String? {
        guard let prop = IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0) else { return nil }
        return prop.takeRetainedValue() as? String
    }

    private func sysctlString(_ name: String) -> String {
        var size = 0
        sysctlbyname(name, nil, &size, nil, 0)
        guard size > 0 else { return "" }
        var buf = [CChar](repeating: 0, count: size)
        sysctlbyname(name, &buf, &size, nil, 0)
        return xicoString(fromNullTerminated: buf)
    }
    private func sysctlInt(_ name: String) -> Int? {
        var value: Int = 0
        var size = MemoryLayout<Int>.size
        return sysctlbyname(name, &value, &size, nil, 0) == 0 ? value : nil
    }
}
