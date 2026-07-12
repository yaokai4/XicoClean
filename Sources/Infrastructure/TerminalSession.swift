import Foundation
import Domain
import Citadel
import NIOCore
import NIOSSH

/// UI → 终端的输入事件（Sendable，可安全穿过 AsyncStream）。
public enum TerminalInput: Sendable {
    case data(Data)
    case resize(cols: Int, rows: Int)
}

/// 把非 Sendable 值封进 @unchecked Sendable 盒子，用于在结构化并发子任务里安全传递
/// Citadel 的 `TTYStdinWriter`/`TTYOutput`（NIO 通道线程安全；这里读写各自独立、无数据竞争）。
private struct UnsafeSendableBox<T>: @unchecked Sendable { let value: T }

/// 交互式 PTY 终端会话（真正的远程 shell：vim / htop / top 都可用）。**需 macOS 15+**（Citadel `withPTY`）。
/// 用一条独立 SSH 连接。输入经 Sendable 的 `AsyncStream<TerminalInput>` 注入，输出经 `@Sendable` 回调外发。
@available(macOS 15.0, *)
public final class TerminalSession: @unchecked Sendable {
    private let host: ServerHost
    private let onOutput: @Sendable (Data) -> Void
    private let onClosed: @Sendable (String?) -> Void
    private let inputStream: AsyncStream<TerminalInput>
    private let inputContinuation: AsyncStream<TerminalInput>.Continuation
    private var task: Task<Void, Never>?

    public init(host: ServerHost,
                onOutput: @escaping @Sendable (Data) -> Void,
                onClosed: @escaping @Sendable (String?) -> Void) {
        self.host = host
        self.onOutput = onOutput
        self.onClosed = onClosed
        let (stream, cont) = AsyncStream<TerminalInput>.makeStream()
        self.inputStream = stream
        self.inputContinuation = cont
    }

    public func send(_ data: Data) { inputContinuation.yield(.data(data)) }
    public func resize(cols: Int, rows: Int) { inputContinuation.yield(.resize(cols: cols, rows: rows)) }

    public func start(credential: SSHCredential, cols: Int, rows: Int) {
        let host = self.host
        let onOutput = self.onOutput
        let onClosed = self.onClosed
        let inputStream = self.inputStream
        task = Task {
            do {
                let auth = try HostConnection.authMethod(username: host.username, credential: credential)
                let client = try await SSHClient.connect(
                    host: host.hostname, port: host.port,
                    authenticationMethod: auth, hostKeyValidator: .acceptAnything(),
                    reconnect: .never, connectTimeout: .seconds(15))
                let request = SSHChannelRequestEvent.PseudoTerminalRequest(
                    wantReply: true, term: "xterm-256color",
                    terminalCharacterWidth: max(1, cols), terminalRowHeight: max(1, rows),
                    terminalPixelWidth: 0, terminalPixelHeight: 0,
                    terminalModes: SSHTerminalModes([:]))
                try await client.withPTY(request) { inbound, outbound in
                    let inBox = UnsafeSendableBox(value: inbound)
                    let outBox = UnsafeSendableBox(value: outbound)
                    try await withThrowingTaskGroup(of: Void.self) { group in
                        // 远端 → 终端
                        group.addTask {
                            do {
                                for try await chunk in inBox.value {
                                    switch chunk {
                                    case .stdout(let bb), .stderr(let bb):
                                        var b = bb
                                        if let d = b.readData(length: b.readableBytes) { onOutput(d) }
                                    }
                                }
                            } catch {}
                        }
                        // 终端 → 远端
                        group.addTask {
                            for await item in inputStream {
                                switch item {
                                case .data(let d):
                                    var buf = ByteBuffer(); buf.writeBytes(d)
                                    try? await outBox.value.write(buf)
                                case .resize(let c, let r):
                                    try? await outBox.value.changeSize(cols: c, rows: r, pixelWidth: 0, pixelHeight: 0)
                                }
                            }
                        }
                        // 任一循环结束（远端 EOF / 输入流关闭）即收尾。
                        try await group.next()
                        group.cancelAll()
                    }
                }
                onClosed(nil)
                try? await client.close()
            } catch {
                onClosed((error as? LocalizedError)?.errorDescription ?? "\(error)")
            }
        }
    }

    public func stop() {
        inputContinuation.finish()
        task?.cancel()
        task = nil
    }
}
