import Foundation
import Domain
import Citadel
import NIOCore
import NIOPosix

/// 本地端口转发（SSH local forward，`ssh -L`）——ServerCat 完全没有，Termius/Core Shell 核心能力。
///
/// 关键：SSH 连接与本地监听 socket 用**同一条单线程 event loop**（把自建 group 传给两者），
/// 于是每对「本地入站 ↔ direct-tcpip」通道都在同一 loop 上，GlueHandler 的同步互调安全无竞态。
public final class PortForwarder: @unchecked Sendable {
    public let localPort: Int
    public let targetHost: String
    public let targetPort: Int
    private let host: ServerHost

    private let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    private let lock = NSLock()
    private var _client: SSHClient?
    private var _serverChannel: Channel?

    public init(host: ServerHost, localPort: Int, targetHost: String, targetPort: Int) {
        self.host = host
        self.localPort = localPort
        self.targetHost = targetHost
        self.targetPort = targetPort
    }

    // 锁访问收进同步方法（NSLock.lock 在 async 上下文不可用）。
    private func setClient(_ c: SSHClient?) { lock.lock(); _client = c; lock.unlock() }
    private func setServerChannel(_ c: Channel?) { lock.lock(); _serverChannel = c; lock.unlock() }
    private func takeAll() -> (Channel?, SSHClient?) { lock.lock(); let sc = _serverChannel; let c = _client; _serverChannel = nil; _client = nil; lock.unlock(); return (sc, c) }

    public func start(credential: SSHCredential) async throws {
        // 1) 在自建单线程 group 上建立 SSH 连接。
        let auth = try HostConnection.authMethod(username: host.username, credential: credential)
        let client = try await SSHClient.connect(
            host: host.hostname, port: host.port,
            authenticationMethod: auth, hostKeyValidator: .acceptAnything(),
            reconnect: .never, group: group, connectTimeout: .seconds(15))
        setClient(client)

        // 2) 在同一 group 上监听本地端口；每个入站连接开一条到目标的 direct-tcpip 通道并对接。
        let target = self.targetHost
        let targetPort = self.targetPort
        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.backlog, value: 64)
            .childChannelInitializer { inbound in
                inbound.eventLoop.makeFutureWithTask {
                    let origin = try SocketAddress(ipAddress: "127.0.0.1", port: 0)
                    let sshChannel = try await client.createDirectTCPIPChannel(
                        using: .init(targetHost: target, targetPort: targetPort, originatorAddress: origin)
                    ) { $0.eventLoop.makeSucceededFuture(()) }
                    return sshChannel
                }.flatMap { (sshChannel: Channel) -> EventLoopFuture<Void> in
                    let (localGlue, remoteGlue) = GlueHandler.matchedPair()
                    return inbound.pipeline.addHandler(localGlue).flatMap {
                        sshChannel.pipeline.addHandler(remoteGlue)
                    }
                }.flatMapError { _ in
                    inbound.close()
                }
            }

        let serverChannel = try await bootstrap.bind(host: "127.0.0.1", port: localPort).get()
        setServerChannel(serverChannel)
    }

    public func stop() async {
        let (sc, c) = takeAll()
        try? await sc?.close()
        try? await c?.close()
        try? await group.shutdownGracefully()
    }
}

/// NIO 规范「胶水」处理器：把两条通道双向对接，含 EOF / 背压 / 关闭传播。
/// 仅在两条通道处于**同一 event loop** 时安全——本转发器已用同一单线程 group 保证。
private final class GlueHandler {
    private var partner: GlueHandler?
    private var context: ChannelHandlerContext?
    private var pendingRead = false

    private init() {}

    static func matchedPair() -> (GlueHandler, GlueHandler) {
        let first = GlueHandler()
        let second = GlueHandler()
        first.partner = second
        second.partner = first
        return (first, second)
    }

    private func partnerWrite(_ data: NIOAny) { context?.write(data, promise: nil) }
    private func partnerFlush() { context?.flush() }
    private func partnerWriteEOF() { context?.close(mode: .output, promise: nil) }
    private func partnerCloseFull() { context?.close(promise: nil) }
    private func partnerBecameWritable() {
        if pendingRead { pendingRead = false; context?.read() }
    }
    private var partnerWritable: Bool { context?.channel.isWritable ?? false }
}

extension GlueHandler: ChannelDuplexHandler {
    typealias InboundIn = NIOAny
    typealias InboundOut = NIOAny
    typealias OutboundIn = NIOAny
    typealias OutboundOut = NIOAny

    func handlerAdded(context: ChannelHandlerContext) { self.context = context }
    func handlerRemoved(context: ChannelHandlerContext) { self.context = nil; partner = nil }
    func channelRead(context: ChannelHandlerContext, data: NIOAny) { partner?.partnerWrite(data) }
    func channelReadComplete(context: ChannelHandlerContext) { partner?.partnerFlush() }
    func channelInactive(context: ChannelHandlerContext) { partner?.partnerCloseFull() }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if let evt = event as? ChannelEvent, case .inputClosed = evt {
            partner?.partnerWriteEOF()
        } else {
            context.fireUserInboundEventTriggered(event)
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) { partner?.partnerCloseFull() }

    func channelWritabilityChanged(context: ChannelHandlerContext) {
        if context.channel.isWritable { partner?.partnerBecameWritable() }
    }

    func read(context: ChannelHandlerContext) {
        if let partner, partner.partnerWritable {
            context.read()
        } else {
            pendingRead = true
        }
    }
}
