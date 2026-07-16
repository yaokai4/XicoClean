import Foundation
import Domain
import DesignSystem

/// SFTP 文件浏览器——ServerCat 完全没有文件传输，是离开 ServerCat 的头号功能（Termius/Core Shell 都有）。
///
/// 走系统 `/usr/bin/sftp` + `/usr/bin/ssh`（与监控/终端各自独立连接），原生支持 rsa-sha2 与任意 `.pem` 私钥。
/// 目录列举使用 base64 名称的结构化协议，换行/制表符/` -> ` 等特殊名称不会再被 `ls` 文本误解析；
/// 上传/下载/删除/建目录用 `sftp -b` 批处理。连接经 ControlMaster 复用。
public final class SFTPBrowser: @unchecked Sendable {
    private let host: ServerHost
    private let lock = NSLock()
    private var _ctx: SSHContext?

    public init(host: ServerHost) { self.host = host }

    private var ctx: SSHContext? { lock.lock(); defer { lock.unlock() }; return _ctx }
    private func setCtx(_ c: SSHContext?) { lock.lock(); _ctx = c; lock.unlock() }
    private func takeCtx() -> SSHContext? { lock.lock(); let c = _ctx; _ctx = nil; lock.unlock(); return c }

    public func connect(credential: SSHCredential) async throws {
        if ctx != nil { return }
        let context = try SSHContext(host: host, credential: credential, multiplexed: true)
        // 建立 ControlMaster + 验证鉴权。
        let probe = await SSHProcess.run(executable: SSHContext.sshPath,
                                         args: context.sshArgs(remoteCommand: "echo XICO_OK"),
                                         env: context.environment, timeout: 25)
        guard probe.code == 0, probe.out.contains("XICO_OK") else {
            context.close()
            throw ServerSSHError.connectFailed(friendlySSHError(probe.err.isEmpty ? probe.out : probe.err, code: probe.code))
        }
        setCtx(context)
    }

    public func disconnect() async {
        takeCtx()?.close()
    }

    // MARK: 列目录（ssh + 结构化、长度受限协议）

    private static let listingHeader = "XICO_SFTP_V1"
    private static let listingProgram = #"""
import base64, os, stat, sys
p = base64.b64decode(sys.argv[1], validate=True)
print("XICO_SFTP_V1")
with os.scandir(p) as entries:
    for entry in entries:
        info = entry.stat(follow_symlinks=False)
        kind = "d" if stat.S_ISDIR(info.st_mode) else ("l" if stat.S_ISLNK(info.st_mode) else "f")
        name = base64.b64encode(entry.name).decode("ascii")
        print(name + "\t" + kind + "\t" + str(info.st_size) + "\t" + stat.filemode(info.st_mode))
"""#

    public func list(_ path: String) async throws -> [SFTPEntry] {
        guard let ctx else { throw ServerSSHError.notConnected }
        guard let pathData = path.data(using: .utf8), pathData.count <= 16_384 else {
            throw ServerSSHError.invalidConfiguration(xLoc("远端路径过长或编码无效"))
        }
        let pathBase64 = pathData.base64EncodedString()
        // 程序文本固定并经 shellQuote；唯一变量是 base64 字符串，不进入远端 shell 语法。
        let cmd = "python3 -c \(shellQuote(Self.listingProgram)) \(shellQuote(pathBase64))"
        let r = await SSHProcess.run(executable: SSHContext.sshPath,
                                     args: ctx.sshArgs(remoteCommand: cmd),
                                     env: ctx.environment, timeout: 30, maxOutputBytes: 16 * 1_024 * 1_024)
        if r.outputLimitExceeded {
            throw ServerSSHError.connectFailed(xLoc("远端目录输出超过 16 MB，已及时停止以保护应用"))
        }
        if r.code != 0 {
            let detail = r.err.isEmpty ? r.out : r.err
            throw ServerSSHError.connectFailed(r.code == 255
                ? friendlySSHError(detail, code: r.code)
                : xLoc("无法安全读取远端目录（服务器需要 Python 3）：") + lastLine(detail))
        }
        let out = try Self.parseStructuredListing(r.out)
        return out.sorted {
            if $0.isDirectory != $1.isDirectory { return $0.isDirectory && !$1.isDirectory }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    static func parseStructuredListing(_ output: String) throws -> [SFTPEntry] {
        let lines = output.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.first.map(String.init) == listingHeader else {
            throw ServerSSHError.connectFailed(xLoc("远端目录协议响应无效，已停止解析"))
        }
        guard lines.count <= 100_002 else {
            throw ServerSSHError.connectFailed(xLoc("远端目录项目过多，已停止解析"))
        }
        var entries: [SFTPEntry] = []
        entries.reserveCapacity(max(0, lines.count - 1))
        for raw in lines.dropFirst() where !raw.isEmpty {
            guard raw.utf8.count <= 32_768 else {
                throw ServerSSHError.connectFailed(xLoc("远端目录包含异常超长文件名，已停止解析"))
            }
            let fields = raw.split(separator: "\t", omittingEmptySubsequences: false)
            guard fields.count == 4,
                  let nameData = Data(base64Encoded: String(fields[0])), nameData.count <= 16_384,
                  ["d", "f", "l"].contains(String(fields[1])),
                  let size = Int64(fields[2]), size >= 0,
                  fields[3].utf8.count == 10 else {
                throw ServerSSHError.connectFailed(xLoc("远端目录协议包含无效条目，已停止解析"))
            }
            let validUTF8 = String(data: nameData, encoding: .utf8)
            let name = validUTF8 ?? String(decoding: nameData, as: UTF8.self)
            guard name != ".", name != "..", !name.contains("/") else {
                throw ServerSSHError.connectFailed(xLoc("远端目录协议包含不安全名称，已停止解析"))
            }
            let safe = validUTF8 != nil && SSHInputValidator.isValidBatchPath(name)
            let kind = String(fields[1])
            entries.append(SFTPEntry(name: name, isDirectory: kind == "d", isSymlink: kind == "l",
                                     size: size, permissions: String(fields[3]),
                                     rawNameBase64: String(fields[0]), isOperationallySafe: safe))
        }
        return entries
    }

    /// 解析一行 `ls -la`：`drwxr-xr-x  2 user group 4096 Jul 13 07:00 name`（名字可能含空格、软链 `a -> b`）。
    static func parseLSLine(_ line: String) -> SFTPEntry? {
        // 前 8 个空白分隔字段固定：权限 链接数 属主 属组 大小 月 日 时间；名字是其后全部。
        var fields: [String] = []
        var rest = Substring(line)
        for _ in 0..<8 {
            while let f = rest.first, f == " " || f == "\t" { rest = rest.dropFirst() }
            guard let spaceIdx = rest.firstIndex(where: { $0 == " " || $0 == "\t" }) else { return nil }
            fields.append(String(rest[rest.startIndex..<spaceIdx]))
            rest = rest[spaceIdx...]
        }
        while let f = rest.first, f == " " || f == "\t" { rest = rest.dropFirst() }
        let perms = fields[0]
        guard perms.count >= 10 else { return nil }
        let size = Int64(fields[4]) ?? 0
        var name = String(rest)
        let isLink = perms.hasPrefix("l")
        if isLink, let range = name.range(of: " -> ") {
            name = String(name[name.startIndex..<range.lowerBound])
        }
        let isDir = perms.hasPrefix("d")
        return SFTPEntry(name: name, isDirectory: isDir, isSymlink: isLink,
                         size: size, permissions: String(perms.prefix(10)))
    }

    // MARK: 传输（sftp -b 批处理）

    private func runSFTP(_ commands: [String]) async throws {
        guard let ctx else { throw ServerSSHError.notConnected }
        let script = commands.joined(separator: "\n") + "\n"
        let r = await SSHProcess.run(executable: SSHContext.sftpPath,
                                     args: ctx.sftpBatchArgs(),
                                     env: ctx.environment,
                                     input: Data(script.utf8), timeout: 600)
        if r.code != 0 {
            let msg = r.err.isEmpty ? r.out : r.err
            throw ServerSSHError.connectFailed(msg.isEmpty ? xLocF("SFTP 操作失败（退出码 %d）", Int(r.code)) : xLoc("SFTP 操作失败：") + lastLine(msg))
        }
    }

    public func download(remotePath: String, to localURL: URL) async throws {
        try await runSFTP(["get -p \(try sftpQuote(remotePath)) \(try sftpQuote(localURL.path))"])
    }

    public func upload(localURL: URL, toRemotePath remotePath: String) async throws {
        try await runSFTP(["put \(try sftpQuote(localURL.path)) \(try sftpQuote(remotePath))"])
    }

    public func remove(_ path: String, isDirectory: Bool = false) async throws {
        // 目录只用 rmdir（仅空目录）而不做递归删除：远端不可撤销，默认必须 fail-closed。
        try await runSFTP(["\(isDirectory ? "rmdir" : "rm") \(try sftpQuote(path))"])
    }

    public func makeDirectory(_ path: String) async throws {
        try await runSFTP(["mkdir \(try sftpQuote(path))"])
    }
}

/// sftp 命令行内的路径引用：双引号包裹并转义 `\` 与 `"`。
func sftpQuote(_ s: String) throws -> String {
    guard SSHInputValidator.isValidBatchPath(s) else {
        throw ServerSSHError.invalidConfiguration(xLoc("路径含不支持的控制字符"))
    }
    return "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
}

private func lastLine(_ s: String) -> String {
    s.split(whereSeparator: \.isNewline).map(String.init).last(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) ?? s
}
