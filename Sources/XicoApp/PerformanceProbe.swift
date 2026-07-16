#if DEBUG
import Foundation
import Darwin
import AppKit
import SwiftUI
import Combine
import Infrastructure
import Features
import DesignSystem

/// 菜单栏稳态采样的可重复真机基准。它在单实例守卫前运行，因此不会打断用户正在使用的正式版，
/// 也不会创建第二组状态栏图标。输出一行机器可读结果，供审计/CI 留存性能证据。
///
/// 用法：`Xico --perfprobe`（约 12 秒）
@MainActor
func probeMetricsPerformance() {
    let defaults = UserDefaults.standard
    let argument = CommandLine.arguments.first(where: { $0.hasPrefix("--perfprobe=") })
    let profile = argument.map { String($0.dropFirst("--perfprobe=".count)) } ?? "standard"
    let isHeavy = profile == "heavy" || profile == "live" || profile == "detail"
        || profile == "cpu-detail" || profile == "memory-detail"
        || profile == "metrics-full"
    let overrideKeys = ["xico.mb.cpu", "xico.mb.memory", "xico.mb.network", "xico.mb.disk", "xico.mb.temp"]
    let previousValues = Dictionary(uniqueKeysWithValues: overrideKeys.map { ($0, defaults.object(forKey: $0)) })
    if isHeavy {
        for key in overrideKeys { defaults.set(true, forKey: key) }
    }
    defer {
        for (key, value) in previousValues {
            if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
        }
    }
    let interval = MonitoringPreferences.refreshInterval(defaults).rawValue

    if ["live", "detail", "cpu-detail", "memory-detail"].contains(profile) {
        let demand: MetricsDetailDemand = switch profile {
        case "cpu-detail": .cpu
        case "memory-detail": .memory
        case "detail": .all
        default: .none
        }
        probeLivePipeline(
            model: AppModel.shared,
            interval: interval,
            demand: demand
        )
        return
    }

    let samples = 6
    let sampler = LiveMetricsSampler()
    let consumerVisible = profile == "metrics-full"

    // 建立 CPU/网络/磁盘差分基线，并让一次性动态链接/缓存初始化不污染正式测量。
    _ = sampler.sample(consumerVisible: consumerVisible)
    Thread.sleep(forTimeInterval: interval)

    var wallMilliseconds: [Double] = []
    var cpuSeconds = 0.0
    for index in 0..<samples {
        let wallStart = CFAbsoluteTimeGetCurrent()
        let cpuStart = processCPUSeconds()
        _ = sampler.sample(consumerVisible: consumerVisible)
        let cpuEnd = processCPUSeconds()
        let elapsed = CFAbsoluteTimeGetCurrent() - wallStart
        wallMilliseconds.append(elapsed * 1_000)
        cpuSeconds += max(0, cpuEnd - cpuStart)

        if index + 1 < samples {
            Thread.sleep(forTimeInterval: max(0, interval - elapsed))
        }
    }

    let sorted = wallMilliseconds.sorted()
    let p95Index = min(sorted.count - 1, Int(ceil(Double(sorted.count) * 0.95)) - 1)
    let p95 = sorted[max(0, p95Index)]
    let average = wallMilliseconds.reduce(0, +) / Double(wallMilliseconds.count)
    let observationWindow = interval * Double(samples)
    let cpuPercent = cpuSeconds / observationWindow * 100
    let footprintMB = Double(processPhysicalFootprint()) / 1_048_576
    let enabled = ["cpu", "memory", "network", "disk", "diskio", "temp", "battery", "gpu", "combined"]
        .filter { id in
            let key = "xico.mb.\(id)"
            if defaults.object(forKey: key) == nil { return ["cpu", "memory", "network"].contains(id) }
            return defaults.bool(forKey: key)
        }
        .joined(separator: ",")

    let result = String(
        format: "PERF_RESULT profile=%@ interval=%.2f samples=%d enabled=%@ sample_cpu=%.3f%% sample_avg=%.2fms sample_p95=%.2fms footprint=%.1fMB",
        profile, interval, samples, enabled, cpuPercent, average, p95, footprintMB
    ) + "\n"
    FileHandle.standardOutput.write(Data(result.utf8))
}

@MainActor
private func probeLivePipeline(
    model: AppModel,
    interval: TimeInterval,
    demand: MetricsDetailDemand
) {
    let detailVisible = demand != .none
    var renders = 0
    var glyphCPU: [String: Double] = [:]
    var lastImages: [String: NSImage] = [:]
    let renderer = model.liveMetricsFeed.snapshotPublisher
        .compactMap { $0 }
        .sink { snapshot in
            let factories: [(String, () -> NSImage)] = [
                ("cpu", { MenuBarGlyph.cpu(fraction: snapshot.cpuUsage, history: model.cpuHistory,
                                            style: .rich, colored: true) }),
                ("memory", { MenuBarGlyph.memory(fraction: snapshot.memoryPressureIndex ?? snapshot.memoryUsedFraction,
                                                  history: model.memHistory, style: .rich, colored: true) }),
                ("network", { MenuBarGlyph.network(down: snapshot.netDownBytesPerSec, up: snapshot.netUpBytesPerSec,
                                                    history: [], style: .valueOnly, colored: true) }),
                ("disk", { MenuBarGlyph.disk(fraction: snapshot.diskUsedFraction, style: .rich, colored: true) }),
                ("temp", { MenuBarGlyph.temperature(celsius: snapshot.cpuTemp, style: .iconValue, colored: true) }),
            ]
            for (id, make) in factories {
                let start = processCPUSeconds()
                let image = make()
                if lastImages[id] === image { continue }
                lastImages[id] = image
                var rect = NSRect(origin: .zero, size: image.size)
                _ = image.cgImage(forProposedRect: &rect, context: nil, hints: nil)
                glyphCPU[id, default: 0] += max(0, processCPUSeconds() - start)
            }
            renders += 1
        }

    NSApp.setActivationPolicy(.prohibited)
    // 模拟用户关闭主窗口、仅保留菜单栏监控的真实稳态；orderOut 仍保留整棵 SwiftUI 图并持续布局，
    // 会把“隐藏但未关闭窗口”的动画成本误算进菜单栏基准。
    for window in NSApp.windows { window.close() }
    model.setMetricsDetailDemand(.none)
    model.startMetricsTimer()
    RunLoop.main.run(until: Date().addingTimeInterval(5))
    // SwiftUI may instantiate its Window scene after applicationDidFinishLaunching;
    // close it again after the baseline so the probe measures only the requested menu card.
    for window in NSApp.windows { window.close() }
    RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    let openedAt = CFAbsoluteTimeGetCurrent()
    model.setMetricsDetailDemand(demand)
    var memoryRowsMilliseconds = -1.0
    var cpuRowsMilliseconds = -1.0
    if detailVisible {
        let deadline = openedAt + max(4, interval * 3)
        while model.liveMetricsFeed.applicationUsage.byMemory.isEmpty,
              CFAbsoluteTimeGetCurrent() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        if !model.liveMetricsFeed.applicationUsage.byMemory.isEmpty {
            memoryRowsMilliseconds = (CFAbsoluteTimeGetCurrent() - openedAt) * 1_000
        }
        while model.liveMetricsFeed.applicationUsage.byCPU.isEmpty,
              CFAbsoluteTimeGetCurrent() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        if !model.liveMetricsFeed.applicationUsage.byCPU.isEmpty {
            cpuRowsMilliseconds = (CFAbsoluteTimeGetCurrent() - openedAt) * 1_000
        }
    }
    RunLoop.main.run(until: Date().addingTimeInterval(max(3, interval * 2)))
    glyphCPU.removeAll(keepingCapacity: true)

    let footprintStartMB = Double(processPhysicalFootprint()) / 1_048_576
    let wallStart = CFAbsoluteTimeGetCurrent()
    let cpuStart = processCPUSeconds()
    let renderStart = renders
    let duration = 60.0
    RunLoop.main.run(until: Date().addingTimeInterval(duration))
    let elapsed = CFAbsoluteTimeGetCurrent() - wallStart
    let cpu = max(0, processCPUSeconds() - cpuStart)
    let cpuPercent = elapsed > 0 ? cpu / elapsed * 100 : 0
    let footprintMB = Double(processPhysicalFootprint()) / 1_048_576
    let footprintDeltaMB = footprintMB - footprintStartMB
    let applicationUsage = model.liveMetricsFeed.applicationUsage
    let visibleMain = NSApp.windows.contains {
        $0.isVisible && $0.canBecomeMain && $0.occlusionState.contains(.visible)
    }
    let effectiveDemand: MetricsDetailDemand = visibleMain ? .all : demand
    let glyphBreakdown = glyphCPU.keys.sorted().map {
        "\($0)=\(String(format: "%.1f", glyphCPU[$0, default: 0] * 1_000))ms"
    }.joined(separator: ",")
    let result = String(
        format: "PERF_RESULT profile=%@ effective=%@ visible_main=%d interval=%.2f duration=%.2fs frames=%d pipeline_cpu=%.3f%% footprint_start=%.1fMB footprint_end=%.1fMB footprint_delta=%.1fMB memory_rows=%.1fms cpu_rows=%.1fms source=%@ status=%@ sampled=%d denied=%d coverage=%.3f glyph_cpu=%@ windows=%d",
        String(describing: demand), String(describing: effectiveDemand), visibleMain ? 1 : 0,
        interval, elapsed, renders - renderStart,
        cpuPercent, footprintStartMB, footprintMB, footprintDeltaMB,
        memoryRowsMilliseconds, cpuRowsMilliseconds,
        applicationUsage.source.rawValue, applicationUsage.status.rawValue,
        applicationUsage.coverage.sampled, applicationUsage.coverage.denied,
        applicationUsage.coverage.fraction, glyphBreakdown,
        NSApp.windows.filter(\.isVisible).count
    ) + "\n"
    FileHandle.standardOutput.write(Data(result.utf8))
    withExtendedLifetime(renderer) {}
}

private func processCPUSeconds() -> Double {
    var value = timespec()
    guard clock_gettime(CLOCK_PROCESS_CPUTIME_ID, &value) == 0 else { return 0 }
    return Double(value.tv_sec) + Double(value.tv_nsec) / 1_000_000_000
}

private func processPhysicalFootprint() -> UInt64 {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
    let result = withUnsafeMutablePointer(to: &info) { pointer in
        pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    return result == KERN_SUCCESS ? info.phys_footprint : 0
}

#endif
