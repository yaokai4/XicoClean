import Foundation
import Combine

/// 应用内实时指标引擎：**主窗口内**监视页 / 硬件页共享的单一采样循环（引用计数，仅当这些视图
/// 真正在屏时 retain 采样、离屏即 release 停采省电）。这是 in-app 详情页的唯一采样源——同一份
/// 引擎实例被这几页共享，杜绝「每视图各 new 一个 LiveMetricsSampler 随重建丢差分、CPU/网速恒为 0」。
///
/// 说明（避免旧注释「全 App 唯一循环」的误导）：菜单栏图标常驻另有一条**独立**的轻量采样循环
/// （AppModel.refreshMetrics + env.liveMetrics），因为菜单栏需在主窗口关闭时也持续绘制图标，而本引擎
/// 在监视/硬件页离屏后即停采。二者在常见稳态下**不会双采**：主窗口关闭时本引擎未被 retain（只有菜单栏
/// 轻量循环在跑，且其详情采样按「无可见消费者」跳过）；仅当用户打开监视/硬件页时两条循环短暂并存，属可接受。
///
/// 实现：引用计数 + 单例采样器 + .common 模式 Timer（滚动/菜单跟踪时仍刷新），采样在后台队列执行、
/// 主线程仅发布，避免卡顿。
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
    /// 采样序号：每 tick 自增并随该帧传递；apply 按序号丢弃迟到的乱序帧，
    /// 保证发布顺序与采样顺序一致（分离的 detached Task 不保证完成先后，审计 P3）。
    private var sampleSeq = 0
    private var lastAppliedSeq = 0

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
        sampleSeq &+= 1
        let seq = sampleSeq
        queue.async { [sampler, processes] in
            let snap = sampler.sample()
            let procs = doProcesses ? processes.sample(top: 6) : nil
            let freq = doFreq ? sampler.cpuFrequency() : nil
            Task { @MainActor [weak self] in
                self?.apply(snap, procs, freq, seq: seq)
            }
        }
    }

    private func apply(_ snap: SystemSnapshot, _ procs: (byCPU: [ProcessUsage], byMemory: [ProcessUsage])?,
                       _ freq: (performance: Double, efficiency: Double)?, seq: Int) {
        // 丢弃乱序迟到帧：只发布序号更新的采样，历史序列不会因乱序而回退。
        guard seq > lastAppliedSeq else { return }
        lastAppliedSeq = seq
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
