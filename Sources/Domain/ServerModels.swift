import Foundation

// MARK: - 远程服务器（反超 ServerCat）领域模型
//
// 设计原则：与本地 `SystemSnapshot` 对齐的一份 `RemoteSnapshot`，让服务器监控页能直接复用
// 设计系统里的环形仪表 / 折线图 / 磁盘条。SSH 库无关——Domain 只声明 `SSHExecuting` 协议，
// 具体 Citadel 实现留在 Infrastructure（与 SafetyEngine 红线同构：风险/具体能力隔离在协议之后）。

// MARK: 鉴权

/// 鉴权方式。凭据本身（密码明文 / 私钥 PEM）不入模型，只存 Keychain，按需取出注入连接。
public enum SSHAuthKind: String, Codable, Sendable, CaseIterable, Identifiable {
    case password
    case privateKey
    case agent        // SSH agent 转发（预留）

    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .password: return "密码"
        case .privateKey: return "私钥"
        case .agent: return "SSH Agent"
        }
    }
}

/// 连接时注入的凭据（从 Keychain 取出后传入，绝不持久化在 ServerHost 里）。
public enum SSHCredential: Sendable {
    case password(String)
    case privateKey(pem: String, passphrase: String?)
    case agent
}

// MARK: 主机

/// 一台被管理的远程主机。**不含任何密钥/密码**——敏感凭据在 Keychain（见 KeychainSecretStore）。
public struct ServerHost: Identifiable, Codable, Sendable, Hashable {
    public var id: UUID
    public var name: String
    public var hostname: String
    public var port: Int
    public var username: String
    public var authKind: SSHAuthKind
    /// 私钥在 Keychain 中的引用键（authKind == .privateKey 时有效）。
    public var privateKeyRef: String?
    /// 分组标签（如「生产」「测试」）——侧栏/列表分组用。
    public var group: String?
    /// 跳板机 ProxyJump（预留）：指向另一台 ServerHost.id。
    public var jumpHostID: UUID?
    /// 上次探测到的远端系统："Linux" / "Darwin" / "FreeBSD"。
    public var lastKnownOS: String?
    /// 展示：SF Symbol 图标名 + 主题渐变色索引。
    public var symbol: String
    public var colorIndex: Int
    /// 采样间隔（秒）——每台可独立配置（默认 3s）。
    public var pollInterval: Double
    /// 该主机上配置的端口转发隧道。
    public var tunnels: [Tunnel]

    public init(id: UUID = UUID(), name: String, hostname: String, port: Int = 22,
                username: String, authKind: SSHAuthKind = .password,
                privateKeyRef: String? = nil, group: String? = nil, jumpHostID: UUID? = nil,
                lastKnownOS: String? = nil, symbol: String = "server.rack",
                colorIndex: Int = 0, pollInterval: Double = 3, tunnels: [Tunnel] = []) {
        self.id = id
        self.name = name
        self.hostname = hostname
        self.port = port
        self.username = username
        self.authKind = authKind
        self.privateKeyRef = privateKeyRef
        self.group = group
        self.jumpHostID = jumpHostID
        self.lastKnownOS = lastKnownOS
        self.symbol = symbol
        self.colorIndex = colorIndex
        self.pollInterval = pollInterval
        self.tunnels = tunnels
    }

    /// 展示用「user@host:port」。
    public var endpointLabel: String {
        port == 22 ? "\(username)@\(hostname)" : "\(username)@\(hostname):\(port)"
    }
}

// MARK: 端口转发隧道

/// 本地端口转发规则（ssh -L）：本机 localPort → 经该服务器 → targetHost:targetPort。
public struct Tunnel: Identifiable, Codable, Sendable, Hashable {
    public var id: UUID
    public var localPort: Int
    public var targetHost: String
    public var targetPort: Int
    public init(id: UUID = UUID(), localPort: Int, targetHost: String = "localhost", targetPort: Int) {
        self.id = id; self.localPort = localPort; self.targetHost = targetHost; self.targetPort = targetPort
    }
    public var label: String { "127.0.0.1:\(localPort) → \(targetHost):\(targetPort)" }
}

// MARK: 远端快照（对齐本地 SystemSnapshot）

public struct MountUsage: Sendable, Equatable, Identifiable, Codable {
    public var filesystem: String
    public var mountPoint: String
    public var totalBytes: Int64
    public var usedBytes: Int64
    public var id: String { mountPoint }
    public var availableBytes: Int64 { max(0, totalBytes - usedBytes) }
    public var usedFraction: Double { totalBytes > 0 ? Double(usedBytes) / Double(totalBytes) : 0 }
    public init(filesystem: String, mountPoint: String, totalBytes: Int64, usedBytes: Int64) {
        self.filesystem = filesystem; self.mountPoint = mountPoint
        self.totalBytes = totalBytes; self.usedBytes = usedBytes
    }
}

public struct RemoteProcess: Sendable, Equatable, Identifiable, Codable {
    public var pid: Int
    public var user: String
    public var cpuPercent: Double
    public var memPercent: Double
    public var rssBytes: Int64
    public var command: String
    public var id: Int { pid }
    public init(pid: Int, user: String, cpuPercent: Double, memPercent: Double, rssBytes: Int64, command: String) {
        self.pid = pid; self.user = user; self.cpuPercent = cpuPercent
        self.memPercent = memPercent; self.rssBytes = rssBytes; self.command = command
    }
}

public struct RemoteService: Sendable, Equatable, Identifiable, Codable {
    public enum Kind: String, Sendable, Codable { case docker, systemd, port, process }
    public var kind: Kind
    public var name: String
    public var status: String
    public var isHealthy: Bool
    public var detail: String?
    public var id: String { "\(kind.rawValue):\(name)" }
    public init(kind: Kind, name: String, status: String, isHealthy: Bool, detail: String? = nil) {
        self.kind = kind; self.name = name; self.status = status
        self.isHealthy = isHealthy; self.detail = detail
    }
}

/// 与本地 `SystemSnapshot` 对齐的远端一帧。所有字节均为绝对值，速率已由采样器算好差分。
public struct RemoteSnapshot: Sendable, Equatable {
    public var timestamp: Date
    // CPU（0...1）
    public var cpuUsage: Double
    public var cpuUser: Double
    public var cpuSystem: Double
    public var cpuIOWait: Double
    public var cpuSteal: Double
    public var perCore: [Double]
    public var coreCount: Int
    // 负载 / 运行时间
    public var load1: Double
    public var load5: Double
    public var load15: Double
    public var uptimeSeconds: Double
    // 内存 / 交换（字节）
    public var memTotal: Int64
    public var memAvailable: Int64
    public var memUsed: Int64
    public var memCached: Int64
    public var swapTotal: Int64
    public var swapUsed: Int64
    // 磁盘挂载
    public var mounts: [MountUsage]
    // 速率（B/s）
    public var netRxBytesPerSec: Double
    public var netTxBytesPerSec: Double
    public var diskReadBytesPerSec: Double
    public var diskWriteBytesPerSec: Double
    public var tcpRetransRate: Double?
    // 进程 / 服务
    public var processes: [RemoteProcess]
    public var services: [RemoteService]

    public var memUsedFraction: Double { memTotal > 0 ? Double(memUsed) / Double(memTotal) : 0 }
    public var swapUsedFraction: Double { swapTotal > 0 ? Double(swapUsed) / Double(swapTotal) : 0 }
    /// 主根挂载（"/"）使用率，用于列表卡「磁盘」环。
    public var rootDiskFraction: Double {
        (mounts.first { $0.mountPoint == "/" } ?? mounts.max { $0.totalBytes < $1.totalBytes })?.usedFraction ?? 0
    }

    public init(timestamp: Date, cpuUsage: Double = 0, cpuUser: Double = 0, cpuSystem: Double = 0,
                cpuIOWait: Double = 0, cpuSteal: Double = 0, perCore: [Double] = [], coreCount: Int = 0,
                load1: Double = 0, load5: Double = 0, load15: Double = 0, uptimeSeconds: Double = 0,
                memTotal: Int64 = 0, memAvailable: Int64 = 0, memUsed: Int64 = 0, memCached: Int64 = 0,
                swapTotal: Int64 = 0, swapUsed: Int64 = 0, mounts: [MountUsage] = [],
                netRxBytesPerSec: Double = 0, netTxBytesPerSec: Double = 0,
                diskReadBytesPerSec: Double = 0, diskWriteBytesPerSec: Double = 0,
                tcpRetransRate: Double? = nil, processes: [RemoteProcess] = [], services: [RemoteService] = []) {
        self.timestamp = timestamp
        self.cpuUsage = cpuUsage; self.cpuUser = cpuUser; self.cpuSystem = cpuSystem
        self.cpuIOWait = cpuIOWait; self.cpuSteal = cpuSteal; self.perCore = perCore; self.coreCount = coreCount
        self.load1 = load1; self.load5 = load5; self.load15 = load15; self.uptimeSeconds = uptimeSeconds
        self.memTotal = memTotal; self.memAvailable = memAvailable; self.memUsed = memUsed; self.memCached = memCached
        self.swapTotal = swapTotal; self.swapUsed = swapUsed; self.mounts = mounts
        self.netRxBytesPerSec = netRxBytesPerSec; self.netTxBytesPerSec = netTxBytesPerSec
        self.diskReadBytesPerSec = diskReadBytesPerSec; self.diskWriteBytesPerSec = diskWriteBytesPerSec
        self.tcpRetransRate = tcpRetransRate; self.processes = processes; self.services = services
    }
}

// MARK: 连接状态

public enum ConnectionState: Sendable, Equatable {
    case disconnected
    case connecting
    case connected
    case degraded(String)   // 可达但近期采样有错
    case failed(String)     // 连接/鉴权失败

    public var isLive: Bool {
        switch self { case .connected, .degraded: return true; default: return false }
    }
    public var isBusy: Bool { if case .connecting = self { return true }; return false }
    public var failureReason: String? {
        switch self { case .failed(let r): return r; case .degraded(let r): return r; default: return nil }
    }
}

// MARK: 代码片段（Snippets）

public struct Snippet: Identifiable, Codable, Sendable, Hashable {
    public var id: UUID
    public var title: String
    public var command: String
    public var tags: [String]
    public init(id: UUID = UUID(), title: String, command: String, tags: [String] = []) {
        self.id = id; self.title = title; self.command = command; self.tags = tags
    }
}

// MARK: SFTP 文件条目

/// 远端目录中的一个条目（SFTP 浏览器用）。
public struct SFTPEntry: Sendable, Identifiable, Equatable {
    public var name: String
    public var isDirectory: Bool
    public var isSymlink: Bool
    public var size: Int64
    public var permissions: String   // ls -l 风格 longname 首段
    public var id: String { name }
    public init(name: String, isDirectory: Bool, isSymlink: Bool = false, size: Int64, permissions: String) {
        self.name = name; self.isDirectory = isDirectory; self.isSymlink = isSymlink
        self.size = size; self.permissions = permissions
    }
}

// MARK: SSH 执行协议（Domain 侧库无关抽象）

/// 一条已建立的远端连接可执行命令。Citadel 实现（HostConnection actor）留在 Infrastructure。
/// 让监控引擎可对 fake 实现单测，且 Domain 不依赖任何 SSH 库。
public protocol SSHExecuting: Sendable {
    /// 执行一条命令，返回合并后的输出（stdout，必要时含 stderr）。
    func execute(_ command: String) async throws -> String
}
