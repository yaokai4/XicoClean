import Foundation
import Combine
import Domain

/// 端口转发隧道的运行时管理（对标 Termius/Core Shell 的 tunnel manager；ServerCat 无）。
@MainActor
public final class TunnelManager: ObservableObject {
    public enum TunnelState: Sendable, Equatable { case stopped, starting, active, failed(String) }

    @Published public private(set) var states: [UUID: TunnelState] = [:]
    private var forwarders: [UUID: PortForwarder] = [:]
    private var startTasks: [UUID: Task<Void, Never>] = [:]
    private var startGenerations: [UUID: UUID] = [:]

    public init() {}

    public func state(_ id: UUID) -> TunnelState { states[id] ?? .stopped }
    public func isActive(_ id: UUID) -> Bool { if case .active = state(id) { return true }; return false }

    public func start(tunnel: Tunnel, host: ServerHost, credential: SSHCredential) {
        guard forwarders[tunnel.id] == nil else { return }
        states[tunnel.id] = .starting
        let fwd = PortForwarder(host: host, localPort: tunnel.localPort,
                                targetHost: tunnel.targetHost, targetPort: tunnel.targetPort)
        forwarders[tunnel.id] = fwd
        let id = tunnel.id
        let generation = UUID()
        startGenerations[id] = generation
        startTasks[id] = Task {
            defer {
                if startGenerations[id] == generation {
                    startTasks[id] = nil; startGenerations[id] = nil
                }
            }
            do {
                try await fwd.start(credential: credential)
                if forwarders[id] === fwd { states[id] = .active }
            } catch is CancellationError {
                if forwarders[id] === fwd { states[id] = .stopped; forwarders[id] = nil }
            } catch {
                if forwarders[id] === fwd {
                    states[id] = .failed((error as? LocalizedError)?.errorDescription ?? "\(error)")
                    forwarders[id] = nil
                }
                await fwd.stop()
            }
        }
    }

    public func stop(_ id: UUID) {
        let fwd = forwarders[id]
        forwarders[id] = nil
        startTasks[id]?.cancel(); startTasks[id] = nil
        startGenerations[id] = nil
        states[id] = .stopped
        Task { await fwd?.stop() }
    }

    public func stopAll() { for id in Array(forwarders.keys) { stop(id) } }
}
