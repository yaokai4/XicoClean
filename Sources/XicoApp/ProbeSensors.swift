import Foundation
import Infrastructure

/// 开发用探针：验证温度/风扇/电池/存储/GPU 数据通路在本机是否真的可读。
/// 用法：Xico --probe-sensors
func probeSensors() {
    let reader = SensorReader()
    let temps = reader.temperatures()
    FileHandle.standardError.write("=== 温度传感器（\(temps.count)）===\n".data(using: .utf8)!)
    for t in temps.prefix(40) {
        FileHandle.standardError.write(String(format: "  [%@] %@ = %.1f℃\n", t.category.rawValue, t.name, t.celsius).data(using: .utf8)!)
    }
    let fans = reader.fans()
    FileHandle.standardError.write("=== 风扇（\(fans.count)）===\n".data(using: .utf8)!)
    for f in fans {
        FileHandle.standardError.write("  fan#\(f.id): \(f.rpm) rpm [\(f.minimum.map(String.init) ?? "?")…\(f.maximum.map(String.init) ?? "?")]\n".data(using: .utf8)!)
    }

    let hw = HardwareProfileService()
    let profile = hw.staticProfile()
    FileHandle.standardError.write("=== 硬件档案 ===\n".data(using: .utf8)!)
    FileHandle.standardError.write("  型号: \(profile.marketingName)\n  芯片: \(profile.chip)\n  标识: \(profile.modelIdentifier)\n  序列号: \(profile.serialNumber)\n  内存: \(profile.memoryDescription)\n  核心: \(profile.coreDescription)\n".data(using: .utf8)!)

    if let bat = hw.battery() {
        FileHandle.standardError.write("=== 电池 ===\n  健康: \(bat.healthPercent)%  循环: \(bat.cycleCount)  设计: \(bat.designCapacity)mAh  满充: \(bat.fullChargeCapacity)mAh  温度: \(String(format: "%.1f", bat.temperature))℃  功率: \(String(format: "%.1f", bat.powerWatts))W  状态: \(bat.condition)\n".data(using: .utf8)!)
    } else {
        FileHandle.standardError.write("=== 电池：无（台式机或读取失败）===\n".data(using: .utf8)!)
    }

    let gpu = hw.gpu()
    FileHandle.standardError.write("=== GPU ===\n  \(gpu?.name ?? "—")  核心: \(gpu?.coreCount.map(String.init) ?? "—")  占用: \(gpu?.utilizationPercent.map { String(format: "%.0f%%", $0) } ?? "—")\n".data(using: .utf8)!)

    let storage = hw.storageHealth()
    FileHandle.standardError.write("=== 存储（\(storage.count)）===\n".data(using: .utf8)!)
    for s in storage {
        FileHandle.standardError.write("  \(s.name): \(s.model)  SMART=\(s.smartStatus)  TRIM=\(s.trimEnabled.map { $0 ? "是" : "否" } ?? "?")  \(ByteCountFormatter.string(fromByteCount: s.totalBytes, countStyle: .file))\n".data(using: .utf8)!)
    }
    if let smart = hw.nvmeSMART() {
        FileHandle.standardError.write("=== NVMe SMART 详细 ===\n  剩余寿命: \(smart.lifeRemaining)%（消耗 \(smart.percentUsed)%）  备用块: \(smart.availableSpare)%  温度: \(smart.temperature)℃  通电: \(smart.powerOnHours) 小时  写入: \(String(format: "%.1f", smart.terabytesWritten)) TB  异常断电: \(smart.unsafeShutdowns)  告警: \(smart.hasWarning ? "有" : "无")\n".data(using: .utf8)!)
    } else {
        FileHandle.standardError.write("=== NVMe SMART：读取失败或不支持 ===\n".data(using: .utf8)!)
    }

    // 实时指标：采样两次（间隔 1s）取有效差分
    let sampler = LiveMetricsSampler()
    _ = sampler.sample()
    Thread.sleep(forTimeInterval: 1.0)
    let s = sampler.sample()
    func gb(_ b: Int64) -> String { String(format: "%.2f GB", Double(b) / 1_073_741_824) }
    FileHandle.standardError.write("=== 实时指标 ===\n".data(using: .utf8)!)
    FileHandle.standardError.write("  CPU 总: \(Int(s.cpuUsage*100))%（用户 \(Int(s.cpuUser*100))% 系统 \(Int(s.cpuSystem*100))%）\n".data(using: .utf8)!)
    FileHandle.standardError.write("  每核: \(s.perCore.map { "\(Int($0*100))" }.joined(separator: " ")) %\n".data(using: .utf8)!)
    FileHandle.standardError.write("  负载: \(String(format: "%.2f %.2f %.2f", s.load1, s.load5, s.load15))\n".data(using: .utf8)!)
    FileHandle.standardError.write("  内存已用: \(gb(s.memoryUsed)) / \(gb(s.memoryTotal))（应用 \(gb(s.memoryApp)) 联动 \(gb(s.memoryWired)) 压缩 \(gb(s.memoryCompressed)) 缓存 \(gb(s.memoryCached))）\n".data(using: .utf8)!)
    FileHandle.standardError.write("  交换: \(gb(s.swapUsed)) / \(gb(s.swapTotal))\n".data(using: .utf8)!)
    FileHandle.standardError.write("  网络: ↓\(s.netDownBytesPerSec.formattedRate) ↑\(s.netUpBytesPerSec.formattedRate)\n".data(using: .utf8)!)
    FileHandle.standardError.write("  GPU: \(s.gpuUsage.map { "\(Int($0*100))%" } ?? "—")\n".data(using: .utf8)!)

    // 网络详情
    let net = NetworkInfoService()
    _ = net.interfaces(); Thread.sleep(forTimeInterval: 0.8)
    let ifs = net.interfaces()
    FileHandle.standardError.write("=== 网络接口（\(ifs.count)）===\n".data(using: .utf8)!)
    for i in ifs {
        FileHandle.standardError.write("  [\(i.type.rawValue)] \(i.displayName)  IPv4=\(i.ipv4 ?? "—")  IPv6=\(i.ipv6 ?? "—")  ↓\(i.downBytesPerSec.formattedRate) ↑\(i.upBytesPerSec.formattedRate)  \(i.isActive ? "活跃" : "未连接")\n".data(using: .utf8)!)
    }
    if let w = net.wifi() {
        FileHandle.standardError.write("=== Wi-Fi ===\n  SSID=\(w.ssid ?? "（需定位授权）")  RSSI=\(w.rssi.map { "\($0) dBm" } ?? "—")  信道=\(w.channel.map(String.init) ?? "—")  速率=\(w.txRate.map { "\(Int($0)) Mbps" } ?? "—")  安全=\(w.security ?? "—")\n".data(using: .utf8)!)
    } else {
        FileHandle.standardError.write("=== Wi-Fi：未连接或不可读 ===\n".data(using: .utf8)!)
    }
    let sem = DispatchSemaphore(value: 0)
    Task {
        let ping = await net.ping()
        let pub = await net.publicIP()
        FileHandle.standardError.write("=== 连通性 ===\n  公网 IP=\(pub ?? "—")  Ping \(net.pingHost)=\(ping.map { String(format: "%.0f ms", $0) } ?? "—")\n".data(using: .utf8)!)
        sem.signal()
    }
    sem.wait()

    // CPU 频率（IOReport）
    if let f = sampler.cpuFrequency() {
        FileHandle.standardError.write(String(format: "=== CPU 频率 ===\n  性能核 %.0f MHz  能效核 %.0f MHz\n", f.performance, f.efficiency).data(using: .utf8)!)
    } else {
        FileHandle.standardError.write("=== CPU 频率：不可用 ===\n".data(using: .utf8)!)
    }
}
