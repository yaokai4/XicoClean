import Foundation
import Domain
import DesignSystem

/// SSH 连接错误（面向用户的中文文案）。
public enum ServerSSHError: Error, LocalizedError, Sendable {
    case notConnected
    case missingCredential
    case agentUnsupported
    case hostKeyNotTrusted(String)
    case invalidConfiguration(String)
    case connectFailed(String)

    public var errorDescription: String? {
        switch self {
        case .notConnected: return xLoc("未连接到服务器")
        case .missingCredential: return xLoc("缺少凭据：请在主机设置中填写密码或选择私钥")
        case .agentUnsupported: return xLoc("SSH Agent 转发暂未支持，请改用密码或私钥")
        case .hostKeyNotTrusted(let endpoint): return xLoc("尚未确认服务器身份：") + endpoint
        case .invalidConfiguration(let m): return xLoc("连接参数无效：") + m
        case .connectFailed(let m): return m
        }
    }
}

/// 每台主机一个连接对象：拥有一条经系统 `ssh` 建立、并由 ControlMaster 复用的多路连接。
///
/// 传输走系统 `/usr/bin/ssh`（见 `SSHContext`）——原生支持 rsa-sha2、任意 `.pem` 私钥格式、现代密钥交换，
/// 彻底解决 Citadel「RSA 只签 SHA-1、被现代 OpenSSH 拒绝」导致的鉴权失败。首个采样命令建立 ControlMaster，
/// 后续每次 `execute` 复用同一底层连接（无需重复鉴权，采样开销极小）。
///
/// 用 `@unchecked Sendable` + `NSLock` 守护可变状态（与 `LiveMetricsSampler` 同构）；实际 IO 在子进程里发生。
public final class HostConnection: SSHExecuting, @unchecked Sendable {
    public let host: ServerHost
    private let lock = NSLock()
    private var _ctx: SSHContext?
    private var _detectedOS: String?

    public init(host: ServerHost) { self.host = host }

    private var ctx: SSHContext? { lock.lock(); defer { lock.unlock() }; return _ctx }
    private func setCtx(_ c: SSHContext?) { lock.lock(); _ctx = c; lock.unlock() }
    private func takeCtx() -> SSHContext? { lock.lock(); let c = _ctx; _ctx = nil; lock.unlock(); return c }
    public var isConnectedNow: Bool { ctx != nil }
    public var osName: String? { lock.lock(); defer { lock.unlock() }; return _detectedOS }
    private func setOS(_ s: String) { lock.lock(); _detectedOS = s; lock.unlock() }

    // MARK: 连接（支持跳板机 ProxyJump）

    public func connect(credential: SSHCredential,
                        via jump: (host: ServerHost, credential: SSHCredential)? = nil) async throws {
        if ctx != nil { return }
        let context: SSHContext
        do {
            context = try SSHContext(host: host, credential: credential, jump: jump, multiplexed: true)
        } catch let e as ServerSSHError {
            throw e
        } catch {
            throw ServerSSHError.connectFailed(xLoc("准备连接失败：") + "\(error)")
        }
        // 探测命令：建立 ControlMaster + 验证鉴权 + 探测远端系统。
        let probe = await SSHProcess.run(
            executable: SSHContext.sshPath,
            args: context.sshArgs(remoteCommand: "echo XICO_CONNECTED; uname -s"),
            env: context.environment, timeout: 25)
        guard probe.code == 0, probe.out.contains("XICO_CONNECTED") else {
            context.close()
            let msg = probe.err.isEmpty ? probe.out : probe.err
            throw ServerSSHError.connectFailed(friendlySSHError(msg, code: probe.code))
        }
        let os = probe.out.replacingOccurrences(of: "XICO_CONNECTED", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !os.isEmpty { setOS(os) }
        setCtx(context)
    }

    public func disconnect() async {
        let c = takeCtx()
        c?.close()
    }

    // MARK: SSHExecuting

    public func execute(_ command: String) async throws -> String {
        guard let ctx else { throw ServerSSHError.notConnected }
        let r = await SSHProcess.run(
            executable: SSHContext.sshPath,
            args: ctx.sshArgs(remoteCommand: command),
            env: ctx.environment, timeout: 30)
        // ssh 退出码 255 = 传输层/鉴权错误（连接断了）；其它非零 = 远端命令自身退出码（仍有输出可解析）。
        if r.code == 255 {
            throw ServerSSHError.connectFailed(friendlySSHError(r.err, code: 255))
        }
        return r.out.isEmpty ? r.err : r.out
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
}
