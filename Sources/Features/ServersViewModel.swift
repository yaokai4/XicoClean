import Foundation
import Domain
import Infrastructure
import DesignSystem

/// 服务器套件视图模型：主机 CRUD、凭据（Keychain）取放、连接/断开、命令控制台与批量执行、片段库。
/// 门禁在视图层用 `model.licenseStatus` 判定（浏览免费；连接/执行等动作需授权）。
@MainActor
public final class ServersViewModel: ObservableObject {
    private let store: ServerHostStore
    private let keychain: KeychainSecretStore
    public let engine: ServerMonitorEngine
    public let tunnels: TunnelManager
    private let alertStore = ServerAlertRuleStore()

    @Published public var hosts: [ServerHost] = []
    @Published public var snippets: [Snippet] = []
    @Published public var selectedHostID: UUID?
    /// 命令控制台滚动回显（按主机）。
    @Published public var consoleOutput: [UUID: String] = [:]
    @Published public var runningCommandHosts: Set<UUID> = []
    @Published public var toast: String?
    // 告警配置
    @Published public var alertRules: [ServerAlertRule] = []
    @Published public var hostDownAlerts: Bool = true

    public init(env: XicoEnvironment) {
        self.store = env.serverHostStore
        self.keychain = env.keychainSecretStore
        self.engine = env.serverMonitorEngine
        self.tunnels = env.tunnelManager
        self.hosts = store.hosts()
        self.snippets = store.snippets()
        self.selectedHostID = hosts.first?.id
        self.alertRules = alertStore.load()
        self.hostDownAlerts = alertStore.hostDownEnabled
        engine.applyAlertConfig(rules: alertRules, hostDownEnabled: hostDownAlerts)
    }

    // MARK: 告警

    public func saveAlerts() {
        alertStore.save(alertRules)
        alertStore.hostDownEnabled = hostDownAlerts
        engine.applyAlertConfig(rules: alertRules, hostDownEnabled: hostDownAlerts)
    }

    public var enabledAlertCount: Int { alertRules.filter { $0.enabled }.count + (hostDownAlerts ? 1 : 0) }

    // MARK: 从 ~/.ssh/config 导入

    public func importSSHConfig() {
        let imported = SSHConfigImporter.importFromDefault()
        guard !imported.isEmpty else { toast = xLoc("未在 ~/.ssh/config 找到可导入的主机"); return }
        var added = 0
        for h in imported {
            // 去重：同 host+user+port 视为已存在
            let dup = hosts.contains { $0.hostname == h.hostname && $0.username == h.username && $0.port == h.port }
            if !dup { store.upsert(h); added += 1 }
        }
        reload()
        toast = added > 0 ? xLocF("已导入 %d 台主机", added) : xLoc("没有新主机（都已存在）")
    }

    public var selectedHost: ServerHost? { hosts.first { $0.id == selectedHostID } }

    public func reload() {
        hosts = store.hosts()
        snippets = store.snippets()
        if selectedHostID == nil || !hosts.contains(where: { $0.id == selectedHostID }) {
            selectedHostID = hosts.first?.id
        }
    }

    // MARK: 主机 CRUD（机密进 Keychain，主机元数据进 JSON）

    public func saveHost(_ host: ServerHost, password: String?, privateKeyPEM: String?, passphrase: String?) {
        var h = host
        switch h.authKind {
        case .password:
            if let pw = password, !pw.isEmpty {
                keychain.set(pw, forKey: KeychainSecretStore.passwordKey(h.id))
            }
        case .privateKey:
            let ref = h.privateKeyRef ?? h.id.uuidString
            h.privateKeyRef = ref
            if let pem = privateKeyPEM, !pem.isEmpty {
                keychain.set(pem, forKey: KeychainSecretStore.privateKeyKey(ref))
            }
            if let pass = passphrase, !pass.isEmpty {
                keychain.set(pass, forKey: KeychainSecretStore.passphraseKey(ref))
            } else {
                keychain.remove(forKey: KeychainSecretStore.passphraseKey(ref))
            }
        case .agent:
            break
        }
        store.upsert(h)
        reload()
        selectedHostID = h.id
    }

    public func deleteHost(_ id: UUID) {
        engine.disconnect(id)
        keychain.remove(forKey: KeychainSecretStore.passwordKey(id))
        keychain.remove(forKey: KeychainSecretStore.privateKeyKey(id.uuidString))
        keychain.remove(forKey: KeychainSecretStore.passphraseKey(id.uuidString))
        store.delete(id)
        reload()
    }

    /// 是否已存有该主机的密码（编辑页用来显示「已保存」而非回显明文）。
    public func hasStoredPassword(_ host: ServerHost) -> Bool {
        keychain.hasSecret(forKey: KeychainSecretStore.passwordKey(host.id))
    }
    public func hasStoredKey(_ host: ServerHost) -> Bool {
        let ref = host.privateKeyRef ?? host.id.uuidString
        return keychain.hasSecret(forKey: KeychainSecretStore.privateKeyKey(ref))
    }

    // MARK: 凭据

    public func credential(for host: ServerHost) -> SSHCredential? {
        switch host.authKind {
        case .password:
            guard let pw = keychain.string(forKey: KeychainSecretStore.passwordKey(host.id)) else { return nil }
            return .password(pw)
        case .privateKey:
            let ref = host.privateKeyRef ?? host.id.uuidString
            guard let pem = keychain.string(forKey: KeychainSecretStore.privateKeyKey(ref)) else { return nil }
            return .privateKey(pem: pem, passphrase: keychain.string(forKey: KeychainSecretStore.passphraseKey(ref)))
        case .agent:
            return .agent
        }
    }

    // MARK: 连接 / 断开（授权门禁由调用方先判，见 ServersView）

    public func connect(_ host: ServerHost) {
        guard let cred = credential(for: host) else {
            toast = xLoc("缺少凭据：请编辑主机并填写密码或私钥")
            return
        }
        // 跳板机链：若设了 jumpHostID，解析出跳板机主机与其凭据一并传入。
        var jump: (host: ServerHost, credential: SSHCredential)?
        if let jid = host.jumpHostID, let jh = hosts.first(where: { $0.id == jid }), let jc = credential(for: jh) {
            jump = (jh, jc)
        }
        engine.connect(host: host, credential: cred, via: jump)
    }

    public func disconnect(_ host: ServerHost) { engine.disconnect(host.id) }

    public func state(for host: ServerHost) -> ConnectionState { engine.state(for: host.id) }
    public func snapshot(for host: ServerHost) -> RemoteSnapshot? { engine.snapshot(for: host.id) }

    // MARK: 命令控制台

    public func appendConsole(_ id: UUID, _ text: String) {
        var s = consoleOutput[id] ?? ""
        s += text
        if s.count > 60_000 { s = String(s.suffix(48_000)) }
        consoleOutput[id] = s
    }

    public func clearConsole(_ id: UUID) { consoleOutput[id] = "" }

    public func runCommand(_ command: String, on host: ServerHost) {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        appendConsole(host.id, "\n\u{001B}$ \(trimmed)\n")
        runningCommandHosts.insert(host.id)
        let id = host.id
        Task {
            defer { runningCommandHosts.remove(id) }
            do {
                let out = try await engine.runCommand(trimmed, on: id)
                appendConsole(id, out.hasSuffix("\n") || out.isEmpty ? out : out + "\n")
            } catch {
                appendConsole(id, "⚠️ " + ((error as? LocalizedError)?.errorDescription ?? "\(error)") + "\n")
            }
        }
    }

    /// 批量执行：在所有「已连接」主机上跑同一条命令，各自回显到自己的控制台。
    public func runOnConnected(_ command: String) {
        let targets = hosts.filter { engine.isConnected($0.id) }
        guard !targets.isEmpty else { toast = xLoc("没有已连接的主机"); return }
        for h in targets { runCommand(command, on: h) }
        toast = xLocF("已在 %d 台主机执行", targets.count)
    }

    public func isRunning(_ id: UUID) -> Bool { runningCommandHosts.contains(id) }

    // MARK: 端口转发隧道

    public func saveTunnel(_ t: Tunnel, on host: ServerHost) {
        var h = host
        if let idx = h.tunnels.firstIndex(where: { $0.id == t.id }) { h.tunnels[idx] = t } else { h.tunnels.append(t) }
        store.upsert(h); reload()
    }
    public func deleteTunnel(_ id: UUID, on host: ServerHost) {
        tunnels.stop(id)
        var h = host; h.tunnels.removeAll { $0.id == id }
        store.upsert(h); reload()
    }
    public func startTunnel(_ t: Tunnel, on host: ServerHost) {
        guard let cred = credential(for: host) else { toast = xLoc("缺少凭据：请先在主机设置中填写密码或私钥"); return }
        tunnels.start(tunnel: t, host: host, credential: cred)
    }
    public func stopTunnel(_ id: UUID) { tunnels.stop(id) }

    // MARK: 片段

    public func saveSnippet(_ s: Snippet) { store.upsertSnippet(s); snippets = store.snippets() }
    public func deleteSnippet(_ id: UUID) { store.deleteSnippet(id); snippets = store.snippets() }
}
