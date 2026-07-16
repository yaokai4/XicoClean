import Foundation
import Darwin
import Domain
import DesignSystem

/// 本地端口转发（SSH local forward，`ssh -L`）——ServerCat 完全没有，Termius/Core Shell 的核心能力。
///
/// 走系统 `ssh -L <local>:<targetHost>:<targetPort> -N`（专用连接、不复用），原生支持 rsa-sha2 与任意
/// `.pem` 私钥。相比旧的 NIO direct-tcpip 手写胶水，既更简洁又免受 Citadel 的 SHA-1 RSA 限制。
public final class PortForwarder: @unchecked Sendable {
    public let localPort: Int
    public let targetHost: String
    public let targetPort: Int
    private let host: ServerHost

    private let lock = NSLock()
    private var _process: Process?
    private var _ctx: SSHContext?
    private var stopped = false

    public init(host: ServerHost, localPort: Int, targetHost: String, targetPort: Int) {
        self.host = host
        self.localPort = localPort
        self.targetHost = targetHost
        self.targetPort = targetPort
    }

    private func storeIfActive(_ p: Process, _ c: SSHContext) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !stopped else { return false }
        _process = p; _ctx = c
        return true
    }
    private func takeAll(markStopped: Bool = false) -> (Process?, SSHContext?) {
        lock.lock(); if markStopped { stopped = true }
        let p = _process; let c = _ctx; _process = nil; _ctx = nil; lock.unlock()
        return (p, c)
    }
    private var isStopped: Bool { lock.lock(); defer { lock.unlock() }; return stopped }

    public func start(credential: SSHCredential) async throws {
        if isStopped { throw CancellationError() }
        guard SSHInputValidator.isValidPort(localPort), SSHInputValidator.isValidPort(targetPort),
              SSHInputValidator.isValidHostname(targetHost) else {
            throw ServerSSHError.invalidConfiguration(xLoc("请检查本地端口、目标主机与目标端口"))
        }
        // 专用连接（隧道需长期独占，不走 ControlMaster 复用）。
        let ctx = try SSHContext(host: host, credential: credential, multiplexed: false)
        let args = ctx.sshArgs(extra: [
            "-N",                                                  // 只转发、不执行远端命令
            "-o", "ExitOnForwardFailure=yes",                      // 本地端口占用 → 立即失败
            "-L", "127.0.0.1:\(localPort):\(targetHost):\(targetPort)"
        ])
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: SSHContext.sshPath)
        proc.arguments = args
        var env = ProcessInfo.processInfo.environment
        for (k, v) in ctx.environment { env[k] = v }
        proc.environment = env
        let errPipe = Pipe()
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = errPipe
        proc.standardInput = FileHandle.nullDevice
        let errBox = ErrBox()
        errPipe.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData; if !d.isEmpty { errBox.append(d) }
        }
        do { try proc.run() } catch {
            ctx.close()
            throw ServerSSHError.connectFailed(xLoc("无法启动端口转发：") + "\(error)")
        }
        guard storeIfActive(proc, ctx) else {
            Self.stopProcess(proc); ctx.close(); throw CancellationError()
        }

        // 给鉴权 + 绑定一点时间；若在窗口内退出即视为失败（鉴权失败/端口占用）。
        try? await Task.sleep(nanoseconds: 1_800_000_000)
        if Task.isCancelled { await stop(); throw CancellationError() }
        if !proc.isRunning {
            _ = takeAll()
            errPipe.fileHandleForReading.readabilityHandler = nil
            ctx.close()
            let msg = errBox.text
            throw ServerSSHError.connectFailed(friendlySSHError(msg, code: proc.terminationStatus))
        }
    }

    public func stop() async {
        let (p, c) = takeAll(markStopped: true)
        if let p, p.isRunning { Self.stopProcess(p) }
        c?.close()
    }

    private static func stopProcess(_ process: Process) {
        let pid = process.processIdentifier
        process.terminate()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.75) {
            if process.isRunning { _ = Darwin.kill(pid, SIGKILL) }
        }
    }

    private final class ErrBox: @unchecked Sendable {
        private let lock = NSLock(); private var d = Data()
        func append(_ x: Data) {
            lock.lock(); defer { lock.unlock() }
            let room = max(0, 1_048_576 - d.count)
            if room > 0 { d.append(x.prefix(room)) }
        }
        var text: String { lock.lock(); defer { lock.unlock() }; return String(data: d, encoding: .utf8) ?? "" }
    }
}
