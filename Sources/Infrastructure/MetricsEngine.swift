import Foundation
import Combine

/// 统一实时指标引擎：唯一的采样循环，供监视页 / 硬件页 / 菜单栏 / 告警共享观察。
///
/// 解决旧架构的根因缺陷——每个视图各自 new 一个 LiveMetricsSampler，随 SwiftUI 视图重建
/// 丢失差分状态，导致 CPU/网速恒为 0。这里用引用计数 + 单例采样器 + .common 模式 Timer
/// （滚动/菜单跟踪时仍刷新），采样在后台队列执行、主线程仅发布，避免卡顿。
@MainActor
public final class MetricsEngine: ObservableObject {
    public static let historyLength = 60

    @Published public private(set) var snapshot: SystemSnapshot?
    @Published public private(set) var cpuHistory: [Double] = []
    @Published public private(set) var memHistory: [Double] = []
    @Published public private(set) var gpuHistory: [Double] = []
    @Published public private(set) var netDownHistory: [Double] = []
    @Published public private(set) var netUpHistory: [Double] = []
    @Published public private(set) var perCoreHistory: [[Double]] = []
    @Published public private(set) var topByCPU: [ProcessUsage] = []
    @Published public private(set) var topByMemory: [ProcessUsage] = []
    /// CPU 频率（MHz）：性能核 / 能效核。经 IOReport DVFS 采样（阻塞 ~90ms，隔次后台采样）。
    @Published public private(set) var cpuFreqP: Double?
    @Published public private(set) var cpuFreqE: Double?

    /// 刷新间隔（秒）。设置后即时生效。
    @Published public var interval: TimeInterval = 1 {
        didSet { if refCount > 0 { restartTimer() } }
    }

    private let sampler = LiveMetricsSampler()
    private let processes = ProcessSampler()
    private let queue = DispatchQueue(label: "app.xico.metrics", qos: .utility)
    private var timer: Timer?
    private var refCount = 0
    private var processTick = 0

    public init() {}

    /// 视图出现时调用；引用计数为 1 时启动采样。
    public func retain() {
        refCount += 1
        if refCount == 1 { startTimer(); tick() }
    }

    /// 视图消失时调用；无人观察时停止采样，省电。
    public func release() {
        refCount = max(0, refCount - 1)
        if refCount == 0 { stopTimer() }
    }

    private func startTimer() {
        stopTimer()
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)   // 滚动/菜单跟踪时仍刷新
        timer = t
    }

    private func restartTimer() { if timer != nil { startTimer() } }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        let doProcesses = (processTick % 2 == 0)   // 进程榜较重，隔次采样
        let doFreq = (processTick % 2 == 1)        // 频率阻塞 ~90ms，隔次后台采样
        processTick &+= 1
        queue.async { [sampler, processes] in
            let snap = sampler.sample()
            let procs = doProcesses ? processes.sample(top: 6) : nil
            let freq = doFreq ? sampler.cpuFrequency() : nil
            Task { @MainActor [weak self] in
                self?.apply(snap, procs, freq)
            }
        }
    }

    private func apply(_ snap: SystemSnapshot, _ procs: (byCPU: [ProcessUsage], byMemory: [ProcessUsage])?,
                       _ freq: (performance: Double, efficiency: Double)?) {
        snapshot = snap
        push(&cpuHistory, snap.cpuUsage)
        push(&memHistory, snap.memoryUsedFraction)
        push(&gpuHistory, snap.gpuUsage ?? 0)
        push(&netDownHistory, snap.netDownBytesPerSec)
        push(&netUpHistory, snap.netUpBytesPerSec)
        perCoreHistory.append(snap.perCore)
        if perCoreHistory.count > Self.historyLength { perCoreHistory.removeFirst(perCoreHistory.count - Self.historyLength) }
        if let p = procs {
            topByCPU = p.byCPU
            topByMemory = p.byMemory
        }
        if let f = freq { cpuFreqP = f.performance; cpuFreqE = f.efficiency }
    }

    private func push(_ a: inout [Double], _ v: Double) {
        a.append(v)
        if a.count > Self.historyLength { a.removeFirst(a.count - Self.historyLength) }
    }

    /// 归一化的网络历史（上下行统一到同一峰值），供折线图用。
    public func netDownNormalized() -> [Double] { normalize(netDownHistory, peer: netUpHistory) }
    public func netUpNormalized() -> [Double] { normalize(netUpHistory, peer: netDownHistory) }
    private func normalize(_ series: [Double], peer: [Double]) -> [Double] {
        let maxV = max((series + peer).max() ?? 1, 1)
        return series.map { $0 / maxV }
    }
}
