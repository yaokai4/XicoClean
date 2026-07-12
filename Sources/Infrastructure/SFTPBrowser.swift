import Foundation
import Domain
import Citadel
import NIOCore

/// SFTP 文件浏览器——ServerCat 完全没有文件传输，是「为什么我离开 ServerCat」的头号功能（Termius/Core Shell 都有）。
/// 用一条**独立**的 SSH 连接（与监控/终端互不干扰）。同 HostConnection：class + NSLock（SFTPClient/SSHClient 非 Sendable）。
public final class SFTPBrowser: @unchecked Sendable {
    private let host: ServerHost
    private let lock = NSLock()
    private var _client: SSHClient?
    private var _sftp: SFTPClient?

    public init(host: ServerHost) { self.host = host }

    // 锁访问收进同步方法（NSLock.lock 在 async 上下文不可用；同步方法体是非 async 上下文，合法）。
    private var sftp: SFTPClient? { lock.lock(); defer { lock.unlock() }; return _sftp }
    private func store(_ c: SSHClient?, _ s: SFTPClient?) { lock.lock(); _client = c; _sftp = s; lock.unlock() }
    private func takeClient() -> SSHClient? { lock.lock(); let c = _client; _client = nil; _sftp = nil; lock.unlock(); return c }

    public func connect(credential: SSHCredential) async throws {
        if sftp != nil { return }
        let auth = try HostConnection.authMethod(username: host.username, credential: credential)
        let c = try await SSHClient.connect(
            host: host.hostname, port: host.port,
            authenticationMethod: auth, hostKeyValidator: .acceptAnything(),
            reconnect: .never, connectTimeout: .seconds(15))
        let s = try await c.openSFTP()
        store(c, s)
    }

    public func disconnect() async {
        let c = takeClient()
        try? await c?.close()
    }

    public func list(_ path: String) async throws -> [SFTPEntry] {
        guard let s = sftp else { throw ServerSSHError.notConnected }
        let names = try await s.listDirectory(atPath: path)
        var out: [SFTPEntry] = []
        for name in names {
            for comp in name.components {
                let fn = comp.filename
                if fn == "." || fn == ".." { continue }
                let mode = comp.attributes.permissions
                let typeBits = mode.map { $0 & 0o170000 }
                let isDir = typeBits.map { $0 == 0o040000 } ?? comp.longname.hasPrefix("d")
                let isLink = typeBits.map { $0 == 0o120000 } ?? comp.longname.hasPrefix("l")
                let permStr = String(comp.longname.prefix(10))
                out.append(SFTPEntry(name: fn, isDirectory: isDir, isSymlink: isLink,
                                     size: Int64(comp.attributes.size ?? 0),
                                     permissions: permStr))
            }
        }
        return out.sorted {
            if $0.isDirectory != $1.isDirectory { return $0.isDirectory && !$1.isDirectory }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    public func download(remotePath: String, to localURL: URL) async throws {
        guard let s = sftp else { throw ServerSSHError.notConnected }
        let buffer = try await s.withFile(filePath: remotePath, flags: .read) { file in
            try await file.readAll()
        }
        var b = buffer
        let data = b.readData(length: b.readableBytes) ?? Data()
        try data.write(to: localURL, options: .atomic)
    }

    public func upload(localURL: URL, toRemotePath remotePath: String) async throws {
        guard let s = sftp else { throw ServerSSHError.notConnected }
        let data = try Data(contentsOf: localURL)
        try await s.withFile(filePath: remotePath, flags: [.write, .create, .truncate]) { file in
            var buf = ByteBuffer()
            buf.writeBytes(data)
            try await file.write(buf, at: 0)
        }
    }

    public func remove(_ path: String) async throws {
        guard let s = sftp else { throw ServerSSHError.notConnected }
        try await s.remove(at: path)
    }

    public func makeDirectory(_ path: String) async throws {
        guard let s = sftp else { throw ServerSSHError.notConnected }
        try await s.createDirectory(atPath: path)
    }
}
