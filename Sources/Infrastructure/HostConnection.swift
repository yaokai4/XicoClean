import Foundation
import Domain
import DesignSystem
import Citadel
import Crypto
import NIOCore
import NIOSSH

/// SSH 连接错误（面向用户的中文文案）。
public enum ServerSSHError: Error, LocalizedError, Sendable {
    case notConnected
    case missingCredential
    case keyParseFailed
    case agentUnsupported
    case connectFailed(String)

    public var errorDescription: String? {
        switch self {
        case .notConnected: return xLoc("未连接到服务器")
        case .missingCredential: return xLoc("缺少凭据：请在主机设置中填写密码或选择私钥")
        case .keyParseFailed: return xLoc("私钥解析失败：目前支持 OpenSSH 格式的 ed25519 / RSA 私钥")
        case .agentUnsupported: return xLoc("SSH Agent 转发暂未支持，请改用密码或私钥")
        case .connectFailed(let m): return m
        }
    }
}

/// 每台主机一个连接对象：拥有唯一的 Citadel `SSHClient`。
///
/// 用 `@unchecked Sendable` + `NSLock`（与 `LiveMetricsSampler`/`ProcessSampler` 同构）而非 `actor`：
/// Citadel 的 `SSHClient` 非 Sendable，其 `executeCommand`/`close` 是 nonisolated async；放进 actor 会触发
/// 严格并发「把 self 隔离的 client 送往 nonisolated 方法」的报错。改为把 client 取成局部值再调用，
/// 既不跨隔离域，又由 NIO 事件循环保证底层线程安全（同一连接可并发开多条 exec 通道）。
public final class HostConnection: SSHExecuting, @unchecked Sendable {
    public let host: ServerHost
    private let lock = NSLock()
    private var _client: SSHClient?
    private var _jumpClient: SSHClient?
    private var _detectedOS: String?

    public init(host: ServerHost) { self.host = host }

    private var client: SSHClient? { lock.lock(); defer { lock.unlock() }; return _client }
    private func setClients(_ c: SSHClient?, jump: SSHClient?) { lock.lock(); _client = c; _jumpClient = jump; lock.unlock() }
    private func takeClients() -> (SSHClient?, SSHClient?) { lock.lock(); let a = _client; let b = _jumpClient; _client = nil; _jumpClient = nil; lock.unlock(); return (a, b) }
    public var isConnectedNow: Bool { client != nil }
    public var osName: String? { lock.lock(); defer { lock.unlock() }; return _detectedOS }
    private func setOS(_ s: String) { lock.lock(); _detectedOS = s; lock.unlock() }

    // MARK: 连接（支持跳板机 ProxyJump——ServerCat 没有的能力）

    public func connect(credential: SSHCredential,
                        via jump: (host: ServerHost, credential: SSHCredential)? = nil) async throws {
        if client != nil { return }
        do {
            let auth = try Self.authMethod(username: host.username, credential: credential)
            if let jump {
                // 1) 连跳板机 → 2) 经其开 direct-tcpip 到目标 → 3) 在该通道上握手目标 SSH
                let jumpAuth = try Self.authMethod(username: jump.host.username, credential: jump.credential)
                let jc = try await SSHClient.connect(
                    host: jump.host.hostname, port: jump.host.port,
                    authenticationMethod: jumpAuth, hostKeyValidator: .acceptAnything(),
                    reconnect: .never, connectTimeout: .seconds(15))
                let origin = try SocketAddress(ipAddress: "127.0.0.1", port: 0)
                let channel = try await jc.createDirectTCPIPChannel(
                    using: .init(targetHost: host.hostname, targetPort: host.port, originatorAddress: origin)
                ) { ch in ch.eventLoop.makeSucceededFuture(()) }
                let c = try await SSHClient.connect(on: channel, authenticationMethod: auth, hostKeyValidator: .acceptAnything())
                setClients(c, jump: jc)
            } else {
                let c = try await SSHClient.connect(
                    host: host.hostname, port: host.port,
                    authenticationMethod: auth, hostKeyValidator: .acceptAnything(),   // TOFU v1；TODO: known_hosts
                    reconnect: .never, connectTimeout: .seconds(15))
                setClients(c, jump: nil)
            }
        } catch {
            throw ServerSSHError.connectFailed(Self.friendly(error))
        }
    }

    public func disconnect() async {
        let (c, jc) = takeClients()
        try? await c?.close()
        try? await jc?.close()
    }

    // MARK: SSHExecuting

    public func execute(_ command: String) async throws -> String {
        guard let c = client else { throw ServerSSHError.notConnected }
        let buffer = try await c.executeCommand(command, maxResponseSize: 8 * 1024 * 1024, mergeStreams: true)
        var b = buffer
        return b.readString(length: b.readableBytes) ?? ""
    }

    /// 采样一帧指标（含服务，若 includeServices）。返回 nil 表示解析失败（引擎据此标记 degraded）。
    public func sampleMetrics(includeServices: Bool) async throws -> RemoteSnapshot? {
        let raw = try await execute(RemoteSampleParser.linuxMetricsCommand)
        if let os = RemoteSampleParser.parseOS(raw) { setOS(os) }
        guard var snap = RemoteSampleParser.parseMetrics(raw, now: Date()) else { return nil }
        if includeServices {
            if let sraw = try? await execute(RemoteSampleParser.servicesCommand) {
                snap.services = RemoteSampleParser.parseServices(sraw)
            }
        }
        return snap
    }

    // MARK: 鉴权构建

    static func authMethod(username: String, credential: SSHCredential) throws -> SSHAuthenticationMethod {
        switch credential {
        case .password(let pw):
            return .passwordBased(username: username, password: pw)
        case .agent:
            throw ServerSSHError.agentUnsupported
        case .privateKey(let pem, let passphrase):
            let passData = passphrase.map { Data($0.utf8) }
            if let key = try? Curve25519.Signing.PrivateKey(sshEd25519: pem, decryptionKey: passData) {
                return .ed25519(username: username, privateKey: key)
            }
            if let key = try? Insecure.RSA.PrivateKey(sshRsa: pem, decryptionKey: passData) {
                return .rsa(username: username, privateKey: key)
            }
            throw ServerSSHError.keyParseFailed
        }
    }

    private static func friendly(_ error: Error) -> String {
        let d = (error as? LocalizedError)?.errorDescription ?? "\(error)"
        if d.contains("authentication") || d.contains("Authentication") || d.contains("allAuthenticationOptionsFailed") {
            return xLoc("鉴权失败：请检查用户名、密码或私钥")
        }
        if d.contains("Connection refused") || d.contains("refused") {
            return xLoc("连接被拒绝：请检查主机地址与端口，以及服务器 SSH 是否开启")
        }
        if d.contains("timed out") || d.contains("timeout") {
            return xLoc("连接超时：请检查网络与主机可达性")
        }
        return xLoc("连接失败：") + d
    }
}
