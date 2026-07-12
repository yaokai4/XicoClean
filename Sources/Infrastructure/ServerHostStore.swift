import Foundation
import Domain

/// 服务器主机 + 代码片段的持久化（**非机密**部分）。JSON 落盘 `Application Support/Xico/servers.json`。
/// 密码/私钥绝不入此文件——它们在 `KeychainSecretStore`。线程安全。
public final class ServerHostStore: @unchecked Sendable {
    private struct Payload: Codable { var hosts: [ServerHost]; var snippets: [Snippet] }

    private let lock = NSLock()
    private let url: URL
    private let ioQueue = DispatchQueue(label: "com.xico.servers.persist", qos: .utility)
    private var hostsCache: [ServerHost]
    private var snippetsCache: [Snippet]

    public init(directory: URL? = nil) {
        let dir: URL
        if let directory {
            dir = directory
        } else {
            let base = (try? FileManager.default.url(for: .applicationSupportDirectory,
                                                     in: .userDomainMask, appropriateFor: nil, create: true))
                ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
            dir = base.appendingPathComponent("Xico", isDirectory: true)
        }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir.appendingPathComponent("servers.json")
        if let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode(Payload.self, from: data) {
            hostsCache = decoded.hosts
            snippetsCache = decoded.snippets
        } else {
            hostsCache = []
            snippetsCache = Self.defaultSnippets
        }
    }

    // MARK: Hosts

    public func hosts() -> [ServerHost] { lock.lock(); defer { lock.unlock() }; return hostsCache }

    public func upsert(_ host: ServerHost) {
        lock.lock()
        if let idx = hostsCache.firstIndex(where: { $0.id == host.id }) {
            hostsCache[idx] = host
        } else {
            hostsCache.append(host)
        }
        let snap = Payload(hosts: hostsCache, snippets: snippetsCache)
        lock.unlock()
        persist(snap)
    }

    public func delete(_ id: UUID) {
        lock.lock()
        hostsCache.removeAll { $0.id == id }
        let snap = Payload(hosts: hostsCache, snippets: snippetsCache)
        lock.unlock()
        persist(snap)
    }

    // MARK: Snippets

    public func snippets() -> [Snippet] { lock.lock(); defer { lock.unlock() }; return snippetsCache }

    public func upsertSnippet(_ s: Snippet) {
        lock.lock()
        if let idx = snippetsCache.firstIndex(where: { $0.id == s.id }) {
            snippetsCache[idx] = s
        } else {
            snippetsCache.append(s)
        }
        let snap = Payload(hosts: hostsCache, snippets: snippetsCache)
        lock.unlock()
        persist(snap)
    }

    public func deleteSnippet(_ id: UUID) {
        lock.lock()
        snippetsCache.removeAll { $0.id == id }
        let snap = Payload(hosts: hostsCache, snippets: snippetsCache)
        lock.unlock()
        persist(snap)
    }

    // MARK: 落盘

    private func persist(_ payload: Payload) {
        ioQueue.async { [url] in
            guard let data = try? JSONEncoder().encode(payload) else { return }
            try? data.write(to: url, options: .atomic)
        }
    }

    /// 首次启动预置的常用运维片段（用户可编辑/删除）。
    static let defaultSnippets: [Snippet] = [
        Snippet(title: "磁盘占用 Top 20", command: "du -ahx / 2>/dev/null | sort -rh | head -n 20", tags: ["disk"]),
        Snippet(title: "内存占用 Top", command: "ps -eo pid,user,%mem,%cpu,comm --sort=-%mem | head -n 15", tags: ["mem"]),
        Snippet(title: "监听端口", command: "ss -tulpn 2>/dev/null || netstat -tulpn", tags: ["net"]),
        Snippet(title: "Docker 容器", command: "docker ps -a", tags: ["docker"]),
        Snippet(title: "系统更新（Debian/Ubuntu）", command: "sudo apt update && sudo apt -y upgrade", tags: ["ops"]),
        Snippet(title: "最近登录", command: "last -n 20", tags: ["security"])
    ]
}
