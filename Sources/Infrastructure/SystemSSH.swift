import Foundation
import Darwin
import CryptoKit
import Domain
import DesignSystem

/// SSH/SFTP 所有入口共享的输入红线。参数最终虽由 Process.arguments 传递（不经本地 shell），
/// 但 endpoint 与 -L/SFTP batch 仍有各自的命令语法，必须拒绝控制字符与选项形态。
public enum SSHInputValidator {
    public static func normalizedUsername(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func normalizedHostname(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func isValidUsername(_ value: String) -> Bool {
        let v = normalizedUsername(value)
        guard !v.isEmpty, v.utf8.count <= 128, !v.hasPrefix("-") else { return false }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        return !containsControlOrWhitespace(v) && !v.contains("@") && v.unicodeScalars.allSatisfy(allowed.contains)
    }

    public static func isValidHostname(_ value: String) -> Bool {
        let v = normalizedHostname(value)
        guard !v.isEmpty, v.utf8.count <= 255, !v.hasPrefix("-") else { return false }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-:[]%")
        return !containsControlOrWhitespace(v) && !v.contains("@") && v.unicodeScalars.allSatisfy(allowed.contains)
    }

    public static func isValidPort(_ value: Int) -> Bool { (1...65_535).contains(value) }

    public static func isValidBatchPath(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 16_384 && !value.unicodeScalars.contains {
            $0.value < 0x20 || $0.value == 0x7f
        }
    }

    private static func containsControlOrWhitespace(_ value: String) -> Bool {
        value.unicodeScalars.contains { CharacterSet.whitespacesAndNewlines.contains($0) || $0.value < 0x20 || $0.value == 0x7f }
    }
}

/// 一条经过严格解析的 OpenSSH 主机公钥。只保存公开信息，用于让用户在首次连接时核对服务器身份。
public struct SSHHostKey: Sendable, Hashable, Identifiable {
    public let hostToken: String
    public let algorithm: String
    public let keyBase64: String
    public let fingerprint: String

    public var id: String { rawLine }
    public var rawLine: String { "\(hostToken) \(algorithm) \(keyBase64)" }

    private static let allowedAlgorithms: Set<String> = [
        "ssh-ed25519", "ssh-rsa",
        "ecdsa-sha2-nistp256", "ecdsa-sha2-nistp384", "ecdsa-sha2-nistp521",
        "sk-ssh-ed25519@openssh.com", "sk-ecdsa-sha2-nistp256@openssh.com"
    ]

    /// 解析并绑定到预期 endpoint；拒绝注释、通配/哈希 host、控制字符、未知算法与畸形 key blob。
    public static func parse(_ line: String, hostname: String, port: Int) -> SSHHostKey? {
        guard SSHInputValidator.isValidHostname(hostname), SSHInputValidator.isValidPort(port),
              line.utf8.count <= 24_576,
              !line.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7f }) else { return nil }
        let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        guard fields.count == 3,
              expectedHostTokens(hostname: hostname, port: port).contains(fields[0]),
              allowedAlgorithms.contains(fields[1]),
              fields[2].utf8.count <= 16_384,
              let keyData = Data(base64Encoded: fields[2]),
              keyData.count >= 16, keyData.count <= 12_288,
              wireAlgorithm(in: keyData) == fields[1] else { return nil }
        let digest = Data(SHA256.hash(data: keyData)).base64EncodedString().replacingOccurrences(of: "=", with: "")
        return SSHHostKey(hostToken: fields[0], algorithm: fields[1], keyBase64: fields[2], fingerprint: "SHA256:\(digest)")
    }

    public static func expectedHostTokens(hostname: String, port: Int) -> Set<String> {
        let bare = hostname.hasPrefix("[") && hostname.hasSuffix("]")
            ? String(hostname.dropFirst().dropLast()) : hostname
        var tokens: Set<String> = [hostname, bare, "[\(bare)]:\(port)"]
        if port == 22 { tokens.insert("[\(bare)]:22") }
        return tokens
    }

    private static func wireAlgorithm(in data: Data) -> String? {
        guard data.count >= 4 else { return nil }
        let length = data.prefix(4).reduce(0) { ($0 << 8) | Int($1) }
        guard length > 0, length <= 256, data.count >= 4 + length else { return nil }
        return String(data: data.subdata(in: 4..<(4 + length)), encoding: .utf8)
    }
}

public enum SSHHostKeyScanner {
    public static let executable = "/usr/bin/ssh-keyscan"

    /// 只读取公开 host key，不发送密码/私钥。扫描结果必须在 UI 中由用户确认后才能持久化和连接。
    public static func scan(hostname: String, port: Int, timeout: TimeInterval = 10) async throws -> [SSHHostKey] {
        guard SSHInputValidator.isValidHostname(hostname), SSHInputValidator.isValidPort(port) else {
            throw ServerSSHError.invalidConfiguration(xLoc("请检查主机地址与端口"))
        }
        let result = await SSHProcess.run(
            executable: executable,
            args: ["-T", String(max(1, min(15, Int(timeout.rounded(.up))))), "-p", String(port), hostname],
            timeout: timeout + 2,
            maxOutputBytes: 1_048_576)
        var seen = Set<String>()
        let keys = result.out.split(whereSeparator: \.isNewline)
            .compactMap { SSHHostKey.parse(String($0), hostname: hostname, port: port) }
            .filter { seen.insert($0.rawLine).inserted }
        guard !keys.isEmpty else {
            let detail = result.err.split(whereSeparator: \.isNewline).last.map(String.init) ?? ""
            throw ServerSSHError.connectFailed(detail.isEmpty
                ? xLoc("未能读取服务器指纹，请检查网络、地址与 SSH 端口")
                : xLoc("未能读取服务器指纹：") + detail)
        }
        return keys
    }

    /// 私网目标无法从本机直连时，经已确认身份的跳板机读取其公开 host key。
    public static func scan(hostname: String, port: Int,
                            via jump: ServerHost, credential: SSHCredential,
                            timeout: TimeInterval = 10) async throws -> [SSHHostKey] {
        guard SSHInputValidator.isValidHostname(hostname), SSHInputValidator.isValidPort(port) else {
            throw ServerSSHError.invalidConfiguration(xLoc("请检查主机地址与端口"))
        }
        let context = try SSHContext(host: jump, credential: credential, multiplexed: false)
        defer { context.close() }
        // hostname/port 已收敛到无 shell 元字符且 hostname 禁止以 - 开头。
        let command = "ssh-keyscan -T \(max(1, min(15, Int(timeout.rounded(.up))))) -p \(port) \(hostname)"
        let result = await SSHProcess.run(executable: SSHContext.sshPath,
                                          args: context.sshArgs(remoteCommand: command),
                                          env: context.environment, timeout: timeout + 17,
                                          maxOutputBytes: 1_048_576)
        var seen = Set<String>()
        let keys = result.out.split(whereSeparator: \.isNewline)
            .compactMap { SSHHostKey.parse(String($0), hostname: hostname, port: port) }
            .filter { seen.insert($0.rawLine).inserted }
        guard !keys.isEmpty else {
            let detail = result.err.split(whereSeparator: \.isNewline).last.map(String.init) ?? ""
            throw ServerSSHError.connectFailed(detail.isEmpty
                ? xLoc("跳板机未能读取目标服务器指纹")
                : xLoc("跳板机未能读取目标服务器指纹：") + detail)
        }
        return keys
    }
}

/// 基于系统 `/usr/bin/ssh` · `/usr/bin/sftp` 的 SSH 传输层。
///
/// 为什么不用纯 Swift 的 Citadel：Citadel 的 RSA 公钥认证**只会用 SHA-1 的 `ssh-rsa` 签名**
/// （`Insecure.SHA1` / `NID_sha1`），而现代 OpenSSH（8.2+，尤其 8.8 起默认）**拒绝 SHA-1 RSA**，
/// 只接受 `rsa-sha2-256/512`。于是「用 AWS/Lightsail 的 `.pem`（RSA）连接现代服务器」在 Citadel 下
/// 必然「鉴权失败」——这正是 Machi 连接失败的真正根因（服务器 OpenSSH 8.7，实测拒绝 ssh-rsa）。
///
/// 系统 `ssh` 原生支持 rsa-sha2、现代密钥交换、任意私钥格式（PKCS#1 `.pem` / PKCS#8 / OpenSSH / 加密 /
/// PuTTY）、ProxyJump、known_hosts——把传输交给它，`.pem` 直接可用、无需任何格式转换，且永不受签名算法所限。
///
/// 机密处理：私钥/密码/口令写入进程私有临时目录（0700，文件 0600），密码与口令通过 `SSH_ASKPASS`
/// 助手脚本喂给 ssh（不进命令行、不进环境变量明文、不在 `ps` 里可见），连接生命周期结束即删除。
public final class SSHContext: @unchecked Sendable {
    public let username: String
    public let hostname: String
    public let port: Int
    /// 唯一工作目录（私钥/密码/askpass/控制 socket 都在这里；deinit/close 时删除）。
    private let workDir: URL
    /// ControlMaster 的 socket 必须放在短路径下；OpenSSH 原子创建时会再附加随机后缀。
    private let controlDirectory: URL?
    private let knownHostsPath: String
    /// SSH 连接复用的控制 socket 路径（启用多路复用时）；nil = 每次独立连接（终端/隧道用）。
    public let controlPath: String?
    /// 传给子进程的环境变量（含 SSH_ASKPASS 等）。
    public private(set) var environment: [String: String]
    private var authArgs: [String]
    private let cleanedUp = NSLock()
    private var didCleanUp = false

    /// 系统二进制路径（固定用系统自带，避开 PATH 里 Homebrew 版本的行为差异）。
    public static let sshPath = "/usr/bin/ssh"
    public static let sftpPath = "/usr/bin/sftp"
    static let maxControlPathBytes = 80

    /// - Parameters:
    ///   - multiplexed: 是否启用 ControlMaster 连接复用（监控/SFTP 用 true；终端/隧道用 false）。
    public init(host: ServerHost, credential: SSHCredential,
                jump: (host: ServerHost, credential: SSHCredential)? = nil,
                multiplexed: Bool = true) throws {
        self.username = SSHInputValidator.normalizedUsername(host.username)
        self.hostname = SSHInputValidator.normalizedHostname(host.hostname)
        self.port = host.port
        guard SSHInputValidator.isValidUsername(username),
              SSHInputValidator.isValidHostname(hostname),
              SSHInputValidator.isValidPort(host.port) else {
            throw ServerSSHError.invalidConfiguration(xLoc("请检查用户名、主机地址与端口"))
        }

        let base = FileManager.default.temporaryDirectory
        // 直接在当前用户私有 TMPDIR 下创建随机 0700 目录。旧实现先创建共享的
        // /tmp/.xico-ssh 固定根，存在被其他本机用户预占/替换成链接的风险。
        let dir = base.appendingPathComponent("xs-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: NSNumber(value: Int16(0o700))])
        self.workDir = dir
        let knownHosts = dir.appendingPathComponent("known_hosts")
        self.knownHostsPath = knownHosts.path
        let shortControlDirectory = multiplexed ? Self.makeControlDirectory() : nil
        self.controlDirectory = shortControlDirectory
        let socket = shortControlDirectory?.appendingPathComponent("s").path
        // macOS sockaddr_un.sun_path 只有约 104 字节，且 OpenSSH 会先创建 `path.<随机串>` 再 rename。
        // 给该内部后缀和结尾 NUL 留足余量；短目录创建失败时自动退回普通非复用 SSH。
        self.controlPath = socket.flatMap { $0.utf8.count <= Self.maxControlPathBytes ? $0 : nil }
        self.environment = [:]
        self.authArgs = []
        do {
            var normalizedHost = host
            normalizedHost.username = username
            normalizedHost.hostname = hostname
            try Self.writePinnedHostKeys(host.pinnedHostKeys, for: normalizedHost, to: knownHosts)
            try configure(credential: credential, jump: jump)
        } catch {
            cleanup()
            throw error
        }
    }

    deinit { cleanup() }

    // MARK: 组装鉴权 / 环境

    private func configure(credential: SSHCredential,
                           jump: (host: ServerHost, credential: SSHCredential)?) throws {
        var args: [String] = []
        var needsAskpass = false

        switch credential {
        case .agent:
            throw ServerSSHError.agentUnsupported
        case .privateKey(let pem, let passphrase):
            let keyFile = workDir.appendingPathComponent("id")
            try writeSecret(pem, to: keyFile)
            args += ["-o", "PreferredAuthentications=publickey",
                     "-o", "IdentitiesOnly=yes",
                     "-i", keyFile.path]
            if let pass = passphrase, !pass.isEmpty {
                try setupAskpass(secret: pass, name: "askpass")
                needsAskpass = true
            }
        case .password(let pw):
            try setupAskpass(secret: pw, name: "askpass")
            args += ["-o", "PreferredAuthentications=password,keyboard-interactive",
                     "-o", "PubkeyAuthentication=no",
                     "-o", "NumberOfPasswordPrompts=1"]
            needsAskpass = true
        }

        // 有机密要喂 → 必须允许 askpass（BatchMode=yes 会禁用 askpass）；无机密 → BatchMode=yes 防挂起。
        args += ["-o", needsAskpass ? "BatchMode=no" : "BatchMode=yes"]

        // 跳板机 ProxyJump（可选）：用 ProxyCommand 显式指定跳板私钥/口令，env 前缀隔离其 askpass。
        if let jump {
            args += try proxyCommandArgs(jump: jump)
        }

        self.authArgs = args
    }

    /// ProxyJump：`-o ProxyCommand=env SSH_ASKPASS=<j> ... /usr/bin/ssh <jumpAuth> -W %h:%p <jumpEndpoint>`
    private func proxyCommandArgs(jump: (host: ServerHost, credential: SSHCredential)) throws -> [String] {
        let jumpUsername = SSHInputValidator.normalizedUsername(jump.host.username)
        let jumpHostname = SSHInputValidator.normalizedHostname(jump.host.hostname)
        guard SSHInputValidator.isValidUsername(jumpUsername),
              SSHInputValidator.isValidHostname(jumpHostname),
              SSHInputValidator.isValidPort(jump.host.port) else {
            throw ServerSSHError.invalidConfiguration(xLoc("请检查跳板机用户名、地址与端口"))
        }
        var normalizedJumpHost = jump.host
        normalizedJumpHost.username = jumpUsername
        normalizedJumpHost.hostname = jumpHostname
        let jumpKnownHosts = workDir.appendingPathComponent("jump_known_hosts")
        try Self.writePinnedHostKeys(jump.host.pinnedHostKeys, for: normalizedJumpHost, to: jumpKnownHosts)
        var jargs: [String] = ["-o", "StrictHostKeyChecking=yes",
                               "-o", "UserKnownHostsFile=\(jumpKnownHosts.path)",
                               "-o", "GlobalKnownHostsFile=/dev/null",
                               "-o", "UpdateHostKeys=no",
                               "-o", "ConnectTimeout=15", "-p", String(jump.host.port)]
        var envPrefix = ""
        switch jump.credential {
        case .agent: throw ServerSSHError.agentUnsupported
        case .privateKey(let pem, let passphrase):
            let jk = workDir.appendingPathComponent("jump_id")
            try writeSecret(pem, to: jk)
            jargs += ["-o", "IdentitiesOnly=yes", "-i", jk.path]
            if let pass = passphrase, !pass.isEmpty {
                let s = workDir.appendingPathComponent("jump_askpass_secret")
                try writeSecret(pass, to: s)
                let script = try writeAskpassScript(secretFile: s, name: "jump_askpass")
                envPrefix = "env SSH_ASKPASS=\(shellQuote(script)) SSH_ASKPASS_REQUIRE=force DISPLAY=:0 "
                jargs = ["-o", "BatchMode=no"] + jargs
            } else {
                jargs = ["-o", "BatchMode=yes"] + jargs
            }
        case .password(let pw):
            let s = workDir.appendingPathComponent("jump_askpass_secret")
            try writeSecret(pw, to: s)
            let script = try writeAskpassScript(secretFile: s, name: "jump_askpass")
            envPrefix = "env SSH_ASKPASS=\(shellQuote(script)) SSH_ASKPASS_REQUIRE=force DISPLAY=:0 "
            jargs += ["-o", "BatchMode=no", "-o", "PreferredAuthentications=password,keyboard-interactive",
                      "-o", "PubkeyAuthentication=no"]
        }
        let endpoint = "\(jumpUsername)@\(jumpHostname)"
        let cmd = "\(envPrefix)\(Self.sshPath) \(jargs.map(shellQuote).joined(separator: " ")) -W %h:%p \(shellQuote(endpoint))"
        return ["-o", "ProxyCommand=\(cmd)"]
    }

    private func setupAskpass(secret: String, name: String) throws {
        let secretFile = workDir.appendingPathComponent("\(name)_secret")
        try writeSecret(secret, to: secretFile)
        let script = try writeAskpassScript(secretFile: secretFile, name: name)
        environment["SSH_ASKPASS"] = script
        environment["SSH_ASKPASS_REQUIRE"] = "force"
        environment["DISPLAY"] = ":0"   // 老版本 ssh 需要 DISPLAY 才走 askpass；force 下无害。
    }

    /// 写一个只 cat 指定机密文件的 askpass 脚本（机密路径写死在脚本里，避免多 askpass 的 env 冲突）。
    @discardableResult
    private func writeAskpassScript(secretFile: URL, name: String) throws -> String {
        let script = workDir.appendingPathComponent("\(name).sh")
        let body = "#!/bin/sh\ncat \(shellQuote(secretFile.path))\n"
        try body.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: Int16(0o700))],
                                              ofItemAtPath: script.path)
        return script.path
    }

    private func writeSecret(_ s: String, to url: URL) throws {
        var content = s
        if url.lastPathComponent == "id" || url.lastPathComponent == "jump_id" {
            // 私钥：规整换行 + 补尾行（有些粘贴丢了结尾换行会让 ssh 报错）。
            content = s.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            if !content.hasSuffix("\n") { content += "\n" }
        }
        try content.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: Int16(0o600))],
                                              ofItemAtPath: url.path)
    }

    // MARK: 参数拼装

    private static func writePinnedHostKeys(_ lines: [String]?, for host: ServerHost, to url: URL) throws {
        let parsed = (lines ?? []).compactMap { SSHHostKey.parse($0, hostname: host.hostname, port: host.port) }
        guard !parsed.isEmpty, parsed.count == (lines ?? []).count else {
            throw ServerSSHError.hostKeyNotTrusted(host.endpointLabel)
        }
        let content = parsed.map(\.rawLine).joined(separator: "\n") + "\n"
        try content.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: Int16(0o600))], ofItemAtPath: url.path)
    }

    /// ControlMaster socket 单独放进随机、0700 的短目录。这里只存本地 socket，不存任何凭据。
    /// 使用不可预测目录名且禁止覆盖现有项，避免共享 `/private/tmp` 中的预占与符号链接攻击。
    private static func makeControlDirectory() -> URL? {
        let base = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
        for _ in 0..<3 {
            let dir = base.appendingPathComponent("xs-\(UUID().uuidString)", isDirectory: true)
            do {
                try FileManager.default.createDirectory(
                    at: dir,
                    withIntermediateDirectories: false,
                    attributes: [.posixPermissions: NSNumber(value: Int16(0o700))])
                return dir
            } catch {
                continue
            }
        }
        return nil
    }

    public var endpoint: String { "\(username)@\(hostname)" }

    /// 通用连接选项：只信任用户已确认并固定到该主机的 key，主机换 key 会硬失败。
    private var commonArgs: [String] {
        var a = ["-p", String(port),
                 "-o", "StrictHostKeyChecking=yes",
                 "-o", "UserKnownHostsFile=\(knownHostsPath)",
                 "-o", "GlobalKnownHostsFile=/dev/null",
                 "-o", "UpdateHostKeys=no",
                 "-o", "ConnectTimeout=15",
                 "-o", "ServerAliveInterval=15",
                 "-o", "ServerAliveCountMax=3"]
        if let cp = controlPath {
            a += ["-o", "ControlMaster=auto", "-o", "ControlPath=\(cp)", "-o", "ControlPersist=30"]
        }
        return a
    }

    /// 完整 ssh 参数（不含可执行文件本身）：鉴权 + 通用 + 额外 + endpoint + 可选远端命令。
    public func sshArgs(extra: [String] = [], remoteCommand: String? = nil, requestTTY: Bool = false) -> [String] {
        var a = authArgs + commonArgs + extra
        if requestTTY { a += ["-tt"] }
        a.append(endpoint)
        if let cmd = remoteCommand { a.append(cmd) }
        return a
    }

    /// sftp 批处理参数：`sftp -b - <opts> <endpoint>`（命令走 stdin）。
    public func sftpBatchArgs() -> [String] {
        // sftp 用 -P（大写）指定端口；控制多路复用与通用选项同 ssh。
        var a = ["-b", "-", "-P", String(port),
                 "-o", "StrictHostKeyChecking=yes",
                 "-o", "UserKnownHostsFile=\(knownHostsPath)",
                 "-o", "GlobalKnownHostsFile=/dev/null",
                 "-o", "UpdateHostKeys=no",
                 "-o", "ConnectTimeout=15"]
        // 复用 authArgs 里除 -p/-i 端口无关的鉴权项（-i / Preferred* / IdentitiesOnly / BatchMode / ProxyCommand）。
        a += authArgs
        if let cp = controlPath {
            a += ["-o", "ControlMaster=auto", "-o", "ControlPath=\(cp)", "-o", "ControlPersist=30"]
        }
        a.append(endpoint)
        return a
    }

    /// 终端交互式调用（供 SwiftTerm LocalProcessTerminalView）：ssh -tt，env 以 "K=V" 数组给出。
    public func terminalInvocation() -> (executable: String, args: [String], env: [String]) {
        let args = sshArgs(remoteCommand: nil, requestTTY: true)
        // 继承当前环境 + 叠加 askpass 等（LocalProcess 用给定 env 覆盖，需带上 PATH/HOME）。
        var merged = ProcessInfo.processInfo.environment
        for (k, v) in environment { merged[k] = v }
        merged["TERM"] = "xterm-256color"
        let envArray = merged.map { "\($0.key)=\($0.value)" }
        return (Self.sshPath, args, envArray)
    }

    // MARK: 清理

    public func close() {
        // 优雅关闭控制主连接（若在）。
        if let cp = controlPath, FileManager.default.fileExists(atPath: cp) {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: Self.sshPath)
            p.arguments = ["-o", "ControlPath=\(cp)", "-O", "exit", endpoint]
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            try? p.run(); p.waitUntilExit()
        }
        cleanup()
    }

    private func cleanup() {
        cleanedUp.lock(); defer { cleanedUp.unlock() }
        guard !didCleanUp else { return }
        didCleanUp = true
        try? FileManager.default.removeItem(at: workDir)
        if let controlDirectory { try? FileManager.default.removeItem(at: controlDirectory) }
    }
}

// MARK: - 进程执行

public enum SSHProcess {
    public struct Result: Sendable {
        public let code: Int32
        public let stdout: Data
        public let stderr: Data
        public let outputLimitExceeded: Bool
        public var out: String { String(data: stdout, encoding: .utf8) ?? "" }
        public var err: String { String(data: stderr, encoding: .utf8) ?? "" }
    }

    /// 异步跑一个短命进程；stdout/stderr 分开收集，硬超时兜底（防止极端情况下挂死）。
    public static func run(executable: String, args: [String], env: [String: String] = [:],
                           input: Data? = nil, timeout: TimeInterval = 30,
                           maxOutputBytes: Int = 16 * 1_024 * 1_024) async -> Result {
        let controller = ProcessController()
        return await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { (cont: CheckedContinuation<Result, Never>) in
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: executable)
            proc.arguments = args
            if !env.isEmpty {
                var merged = ProcessInfo.processInfo.environment
                for (k, v) in env { merged[k] = v }
                proc.environment = merged
            }
            let outPipe = Pipe(), errPipe = Pipe(), inPipe = Pipe()
            proc.standardOutput = outPipe
            proc.standardError = errPipe
            proc.standardInput = inPipe

            let cap = max(1_024, min(maxOutputBytes, 64 * 1_024 * 1_024))
            let outBox = DataBox(maxBytes: cap), errBox = DataBox(maxBytes: cap)
            outPipe.fileHandleForReading.readabilityHandler = { h in
                let d = h.availableData
                if !d.isEmpty, outBox.append(d), proc.isRunning { requestStop(proc) }
            }
            errPipe.fileHandleForReading.readabilityHandler = { h in
                let d = h.availableData
                if !d.isEmpty, errBox.append(d), proc.isRunning { requestStop(proc) }
            }

            let resumed = ResumeGuard()
            let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global())
            timer.schedule(deadline: .now() + timeout)
            timer.setEventHandler {
                guard proc.isRunning else { return }
                requestStop(proc)
            }
            timer.resume()

            proc.terminationHandler = { p in
                controller.clear(p)
                timer.cancel()
                outPipe.fileHandleForReading.readabilityHandler = nil
                errPipe.fileHandleForReading.readabilityHandler = nil
                let to = outPipe.fileHandleForReading.readDataToEndOfFile(); if !to.isEmpty { outBox.append(to) }
                let te = errPipe.fileHandleForReading.readDataToEndOfFile(); if !te.isEmpty { errBox.append(te) }
                if resumed.claim() {
                    cont.resume(returning: Result(code: p.terminationStatus, stdout: outBox.data, stderr: errBox.data,
                                                  outputLimitExceeded: outBox.didOverflow || errBox.didOverflow))
                }
            }
            do {
                try proc.run()
                controller.set(proc)
                if let input {
                    inPipe.fileHandleForWriting.write(input)
                }
                try? inPipe.fileHandleForWriting.close()
            } catch {
                timer.cancel()
                if resumed.claim() {
                    cont.resume(returning: Result(code: -1, stdout: Data(), stderr: Data("\(error)".utf8),
                                                  outputLimitExceeded: false))
                }
            }
            }
        }, onCancel: {
            controller.cancel()
        })
    }

    private static func requestStop(_ process: Process) {
        let pid = process.processIdentifier
        process.terminate()
        // SIGTERM 对失控的 ssh/sftp/远端命令不一定有效；750ms 后仍存活就 SIGKILL，
        // 让「停止」在用户感知的一秒量级内真正生效。
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.75) {
            if process.isRunning { _ = Darwin.kill(pid, SIGKILL) }
        }
    }

    private final class ProcessController: @unchecked Sendable {
        private let lock = NSLock()
        private var process: Process?
        private var canceled = false

        func set(_ value: Process) {
            lock.lock()
            if canceled {
                lock.unlock()
                if value.isRunning { SSHProcess.requestStop(value) }
            } else {
                process = value
                lock.unlock()
            }
        }

        func clear(_ value: Process) {
            lock.lock()
            if process === value { process = nil }
            lock.unlock()
        }

        func cancel() {
            lock.lock(); canceled = true; let value = process; process = nil; lock.unlock()
            if let value, value.isRunning { SSHProcess.requestStop(value) }
        }
    }

    private final class DataBox: @unchecked Sendable {
        private let lock = NSLock()
        private var _d = Data()
        private var overflow = false
        private let maxBytes: Int
        init(maxBytes: Int) { self.maxBytes = maxBytes }
        /// 返回 true 表示达到上限，调用方应停止产出进程。
        @discardableResult func append(_ d: Data) -> Bool {
            lock.lock(); defer { lock.unlock() }
            guard !overflow else { return true }
            let remaining = maxBytes - _d.count
            if d.count > remaining {
                if remaining > 0 { _d.append(d.prefix(remaining)) }
                overflow = true
            } else {
                _d.append(d)
            }
            return overflow
        }
        var data: Data { lock.lock(); defer { lock.unlock() }; return _d }
        var didOverflow: Bool { lock.lock(); defer { lock.unlock() }; return overflow }
    }
    private final class ResumeGuard: @unchecked Sendable {
        private let lock = NSLock(); private var done = false
        func claim() -> Bool { lock.lock(); defer { lock.unlock() }; if done { return false }; done = true; return true }
    }
}

// MARK: - 工具

/// 单引号 shell 转义（用于 ProxyCommand 拼串）。
func shellQuote(_ s: String) -> String {
    "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

/// 把 ssh/sftp 的 stderr 归一成面向用户的中文错误。
func friendlySSHError(_ stderr: String, code: Int32) -> String {
    let d = stderr.lowercased()
    if d.contains("remote host identification has changed") || d.contains("offending") && d.contains("host key") {
        return xLoc("服务器指纹已变化，已阻止连接。请先向服务器管理员核对新指纹，再在主机菜单中重新验证")
    }
    if d.contains("no ed25519 host key is known") || d.contains("no ecdsa host key is known") ||
        d.contains("no rsa host key is known") {
        return xLoc("服务器身份未被信任，已阻止连接；请重新验证服务器指纹")
    }
    if d.contains("permission denied") || d.contains("authentication failed") || d.contains("too many authentication") {
        return xLoc("鉴权失败：请检查用户名、密码或私钥（若为加密私钥，请填写「私钥口令」）")
    }
    if d.contains("connection refused") {
        return xLoc("连接被拒绝：请检查主机地址与端口，以及服务器 SSH 是否开启")
    }
    if d.contains("connection timed out") || d.contains("operation timed out") || d.contains("timed out") {
        return xLoc("连接超时：请检查网络与主机可达性")
    }
    if d.contains("could not resolve") || d.contains("name or service not known") || d.contains("nodename nor servname") {
        return xLoc("无法解析主机名：请检查主机地址")
    }
    if d.contains("no such file") && d.contains("identity") {
        return xLoc("私钥无效：无法读取私钥内容")
    }
    if d.contains("host key verification failed") {
        return xLoc("服务器指纹校验失败，已阻止连接；请核对或重新验证服务器身份")
    }
    if d.contains("invalid format") || d.contains("error in libcrypto") || d.contains("incorrect passphrase") {
        return xLoc("私钥格式或口令错误：请检查私钥内容与「私钥口令」")
    }
    if d.contains("unix_listener") && d.contains("too long for unix domain socket") {
        return xLoc("无法建立 SSH 复用通道：系统临时路径过长，请重试连接")
    }
    // 兜底：取最后一行非空 stderr。
    let last = stderr.split(whereSeparator: \.isNewline).map(String.init)
        .last(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) ?? ""
    return last.isEmpty ? xLocF("连接失败（退出码 %d）", Int(code)) : xLoc("连接失败：") + last
}
