import Foundation
import Combine
import Domain
import DesignSystem

/// 远程服务器实时监控引擎——与本地 `MetricsEngine` 同构的发布模型，但按主机维护多份状态。
///
/// 每台连接的主机跑一条采样循环（`Task`，继承 MainActor）：`await` 时真正的 SSH 采样在
/// `HostConnection` actor + NIO 事件循环里执行（不阻塞主线程），解析亦在 actor 内（off-main），
/// 主线程只做最终 `@Published` 发布——与 `MetricsEngine.apply` 的「后台采样、主线程发布」纪律一致。
@MainActor
public final class ServerMonitorEngine: ObservableObject {
    public static let historyLength = 60

    @Published public private(set) var snapshots: [UUID: RemoteSnapshot] = [:]
    @Published public private(set) var states: [UUID: ConnectionState] = [:]
    @Published public private(set) var cpuHistory: [UUID: [Double]] = [:]
    @Published public private(set) var memHistory: [UUID: [Double]] = [:]
    @Published public private(set) var netDownHistory: [UUID: [Double]] = [:]
    @Published public private(set) var netUpHistory: [UUID: [Double]] = [:]

    private var connections: [UUID: HostConnection] = [:]
    private var pollTasks: [UUID: Task<Void, Never>] = [:]
    private var hostNames: [UUID: String] = [:]

    /// 阈值告警评估器（ServerCat 没有的能力）。默认规则，UI 可用 applyAlertConfig 覆盖。
    private let alertEvaluator = ServerAlertEvaluator(rules: ServerAlertRule.defaults, hostDownEnabled: true)

    public init() {}

    /// 由告警设置页在保存时调用，把持久化的规则灌入评估器。
    public func applyAlertConfig(rules: [ServerAlertRule], hostDownEnabled: Bool) {
        alertEvaluator.rules = rules
        alertEvaluator.hostDownEnabled = hostDownEnabled
    }

    // MARK: 查询

    public func state(for id: UUID) -> ConnectionState { states[id] ?? .disconnected }
    public func snapshot(for id: UUID) -> RemoteSnapshot? { snapshots[id] }
    public func isConnected(_ id: UUID) -> Bool { state(for: id).isLive }
    public var connectedCount: Int { states.values.filter { $0.isLive }.count }

    /// 菜单栏迷你监视器用：已连接主机的名称 + CPU/内存（ServerCat 无菜单栏能力）。
    public struct HostSummary: Sendable, Identifiable {
        public let id: UUID
        public let name: String
        public let cpu: Double
        public let mem: Double
    }
    public var liveSummaries: [HostSummary] {
        states.compactMap { (id, st) -> HostSummary? in
            guard st.isLive else { return nil }
            let s = snapshots[id]
            return HostSummary(id: id, name: hostNames[id] ?? xLoc("服务器"),
                               cpu: s?.cpuUsage ?? 0, mem: s?.memUsedFraction ?? 0)
        }.sorted { $0.cpu > $1.cpu }
    }

    /// 归一化的网络历史（上下行统一峰值），供折线图。
    public func netHistoryNormalized(_ id: UUID) -> (down: [Double], up: [Double]) {
        let d = netDownHistory[id] ?? [], u = netUpHistory[id] ?? []
        let peak = max((d + u).max() ?? 1, 1)
        return (d.map { $0 / peak }, u.map { $0 / peak })
    }

    // MARK: 连接 / 断开

    public func connect(host: ServerHost, credential: SSHCredential,
                        via jump: (host: ServerHost, credential: SSHCredential)? = nil) {
        let id = host.id
        guard pollTasks[id] == nil else { return }   // 已在连接/监控中
        states[id] = .connecting
        hostNames[id] = host.name
        let conn = HostConnection(host: host)
        connections[id] = conn
        pollTasks[id] = Task { [interval = host.pollInterval] in
            await self.runPollLoop(id: id, conn: conn, interval: interval, credential: credential, via: jump)
        }
    }

    public func disconnect(_ id: UUID) {
        pollTasks[id]?.cancel()
        pollTasks[id] = nil
        let conn = connections[id]
        connections[id] = nil
        states[id] = .disconnected
        snapshots[id] = nil
        Task { await conn?.disconnect() }
    }

    public func disconnectAll() {
        for id in Array(pollTasks.keys) { disconnect(id) }
    }

    /// 在已连接主机上执行一次性命令（供批量 Execute / 片段运行）。未连接则抛错。
    public func runCommand(_ command: String, on id: UUID) async throws -> String {
        guard let conn = connections[id], state(for: id).isLive else { throw ServerSSHError.notConnected }
        return try await conn.execute(command)
    }

    // MARK: 采样循环（MainActor；await 期间 SSH 在 actor 内执行）

    private func runPollLoop(id: UUID, conn: HostConnection, interval: Double, credential: SSHCredential,
                             via jump: (host: ServerHost, credential: SSHCredential)?) async {
        // 循环任一路径退出（连接失败 / 连续采样失败 / 取消 / 正常结束）都必须释放本主机的
        // pollTasks/connections 槽位并关闭底层 SSHClient——否则 connect() 的去重守卫会永久拒绝重连、
        // 且 SSHClient/NIO 通道泄漏（审计 P1）。仅当槽位仍属于本 conn 时清理，避免误清已重建的新连接。
        defer {
            if let cur = connections[id], cur === conn {
                pollTasks[id] = nil
                connections[id] = nil
            }
            Task { await conn.disconnect() }
        }
        do {
            try await conn.connect(credential: credential, via: jump)
        } catch {
            let m = message(error)
            states[id] = .failed(m)
            emitHostDown(id, reason: m)
            return
        }
        states[id] = .connected
        let ns = UInt64(max(1, interval) * 1_000_000_000)
        var tick = 0
        var consecutiveErrors = 0
        while !Task.isCancelled {
            do {
                if let snap = try await conn.sampleMetrics(includeServices: tick % 5 == 0) {
                    apply(id, snap)
                    consecutiveErrors = 0
                } else {
                    states[id] = .degraded(xLoc("采样解析失败"))
                }
            } catch {
                if Task.isCancelled { break }
                consecutiveErrors += 1
                // 连续多次失败视为连接中断。
                if consecutiveErrors >= 3 {
                    let m = message(error)
                    states[id] = .failed(m)
                    emitHostDown(id, reason: m)
                    break
                } else {
                    states[id] = .degraded(message(error))
                }
            }
            tick &+= 1
            try? await Task.sleep(nanoseconds: ns)
        }
    }

    private func apply(_ id: UUID, _ snap: RemoteSnapshot) {
        snapshots[id] = snap
        states[id] = .connected
        push(&cpuHistory, id, snap.cpuUsage)
        push(&memHistory, id, snap.memUsedFraction)
        push(&netDownHistory, id, snap.netRxBytesPerSec)
        push(&netUpHistory, id, snap.netTxBytesPerSec)
        // 采样成功即视为「已恢复」，允许下次掉线再次告警。
        alertEvaluator.clearHostDown(hostID: id)
        // 阈值告警评估 → 系统推送。
        let name = hostNames[id] ?? xLoc("服务器")
        for f in alertEvaluator.evaluate(hostID: id, hostName: name, snapshot: snap) {
            Notifier.notifyAlert(title: f.title, body: f.body, identifier: f.identifier)
        }
    }

    /// 主机掉线告警（连接/采样失败时）。
    private func emitHostDown(_ id: UUID, reason: String) {
        let name = hostNames[id] ?? xLoc("服务器")
        if let f = alertEvaluator.hostDown(hostID: id, hostName: name, reason: reason) {
            Notifier.notifyAlert(title: f.title, body: f.body, identifier: f.identifier)
        }
    }

    private func push(_ dict: inout [UUID: [Double]], _ id: UUID, _ v: Double) {
        var arr = dict[id] ?? []
        arr.append(v)
        if arr.count > Self.historyLength { arr.removeFirst(arr.count - Self.historyLength) }
        dict[id] = arr
    }

    private func message(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? "\(error)"
    }
}
