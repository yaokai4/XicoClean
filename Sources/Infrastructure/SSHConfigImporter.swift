import Foundation
import Domain

/// 从 `~/.ssh/config` 导入主机——ServerCat 让你逐台手输，Core Shell 直接读 ssh_config，是巨大的上手优势。
/// 只导入元数据（名称/地址/端口/用户/鉴权猜测），凭据仍由用户在连接前提供（不擅自读私钥文件）。
/// 非沙盒主 build 可直接读 `~/.ssh/config`；未来 MAS 版需改走 NSOpenPanel + 安全书签。
public enum SSHConfigImporter {

    public static func defaultConfigURL() -> URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh/config")
    }

    public static func importFromDefault() -> [ServerHost] {
        guard let text = try? String(contentsOf: defaultConfigURL(), encoding: .utf8) else { return [] }
        return parse(text)
    }

    public static func importFrom(url: URL) -> [ServerHost] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return parse(text)
    }

    struct Block {
        var aliases: [String] = []
        var hostName: String?
        var user: String?
        var port: Int?
        var identityFile: String?
        var proxyJump: String?
    }

    public static func parse(_ text: String) -> [ServerHost] {
        var blocks: [Block] = []
        var current: Block?

        func flush() { if let c = current { blocks.append(c) }; current = nil }

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            var line = String(rawLine).trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            // 允许 `Key value` 或 `Key=value`
            line = line.replacingOccurrences(of: "=", with: " ")
            let parts = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            guard let keyword = parts.first else { continue }
            let key = keyword.lowercased()
            let value = parts.dropFirst().joined(separator: " ")

            switch key {
            case "host":
                flush()
                current = Block(aliases: Array(parts.dropFirst()))
            case "hostname": current?.hostName = value
            case "user": current?.user = value
            case "port": current?.port = Int(value)
            case "identityfile": current?.identityFile = value
            case "proxyjump": current?.proxyJump = value
            default: break
            }
        }
        flush()

        var out: [ServerHost] = []
        for b in blocks {
            // 跳过通配/无效条目
            guard let alias = b.aliases.first(where: { !$0.contains("*") && !$0.contains("?") }) else { continue }
            let hostname = b.hostName ?? alias
            guard !hostname.contains("*") else { continue }
            let auth: SSHAuthKind = b.identityFile != nil ? .privateKey : .password
            out.append(ServerHost(
                name: alias,
                hostname: hostname,
                port: b.port ?? 22,
                username: b.user ?? NSUserName(),
                authKind: auth,
                symbol: "server.rack",
                colorIndex: out.count % 6))
        }
        return out
    }
}
