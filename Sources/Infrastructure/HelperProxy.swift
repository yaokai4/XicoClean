import Foundation
import DesignSystem
import ServiceManagement
import Domain
import Shared

public protocol PrivilegedProcessSampling: Sendable {
    var processSamplingAvailable: Bool { get }
    func sampleProcesses(pids: [Int32]) async -> ProcessHelperBatchResponse?
}

/// 特权助手客户端：注册 / 状态查询 / 经 XPC 调用。
public final class HelperProxy: @unchecked Sendable {
    public enum Status: Sendable, Equatable {
        case notInstalled      // 未注册
        case requiresApproval  // 已注册但用户需在系统设置中批准
        case installed         // 就绪
        case unavailable       // 当前构建无法使用（如未签名/未嵌入）
    }

    public init() {}

    private var service: SMAppService {
        SMAppService.daemon(plistName: XicoHelperPlistName)
    }

    public func status() -> Status {
        switch service.status {
        case .notRegistered: return .notInstalled
        case .enabled: return .installed
        case .requiresApproval: return .requiresApproval
        case .notFound: return .unavailable
        @unknown default: return .unavailable
        }
    }

    /// 安装（注册）助手。需正式签名 + App 内嵌守护进程才会成功。
    public func install() throws {
        try service.register()
    }

    public func uninstall() throws {
        try service.unregister()
    }

    /// 打开「系统设置 › 通用 › 登录项与扩展」让用户批准助手
    @MainActor public func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    /// XPC 调用超时（秒）：助手挂起时 UI 不会永久转圈。
    /// 仅用于轻量、可秒回的调用（版本握手另传更短的 5s）。大批量特权删除与维护脚本
    /// 用下面按规模放大的超时，避免「客户端看门狗 < 真实耗时」误报失败并截断计账。
    private static let callTimeout: TimeInterval = 30

    /// 特权操作超时上限（秒）：再大的批量也不会无限期转圈。
    private static let maxOperationTimeout: TimeInterval = 15 * 60

    /// 维护脚本（periodic daily/weekly、重建缓存等）可跑数分钟——给足 10 分钟余量。
    private static let maintenanceTimeout: TimeInterval = 10 * 60

    /// 按待删条目数推算 `removeProtected` 超时。
    /// 关键约束：基础值取 120s（> 助手 90s 空闲退出阈值），确保「客户端超时」永远不会
    /// 因为比助手空闲阈值更短而成为误报触发点；再按每条 ~8ms 线性放大（/Library/Caches
    /// 常是数 GB 小文件逐个 unlinkat），封顶 15 分钟。小批量仍能较快得到结论。
    /// 助手在忙时不会空闲退出（有在途 XPC 调用即视为活跃），故只需把客户端等待窗放宽到覆盖真实耗时。
    static func removalTimeout(pathCount: Int) -> TimeInterval {
        let base: TimeInterval = 120
        let scaled = base + Double(max(0, pathCount)) * 0.008
        return min(scaled, maxOperationTimeout)
    }

    /// 反向校验：把出站连接钉死在「同 Team ID / Developer ID 签名的 Xico 助手」上。
    /// 助手侧已用 `setCodeSigningRequirement` 校验客户端；这里补上另一半，形成双向互信——
    /// 内核在投递消息时强制校验，冒名顶替的助手连接会被立即失效。
    /// 结构与 `XicoHelperSecurity.clientCodeRequirement` 一致（Team ID 单一事实源），
    /// 但把 identifier 换成助手自身，发布构建同样要求 Developer ID 叶证书标记。
    private static var helperCodeRequirement: String {
        let base = "anchor apple generic and identifier \"\(XicoHelperMachServiceName)\" "
            + "and certificate leaf[subject.OU] = \"\(XicoHelperSecurity.teamIdentifier)\""
        #if DEBUG
        return base
        #else
        return base + " and certificate leaf[field.1.2.840.113635.100.6.1.13] exists"
        #endif
    }

    /// 在连接 `resume()` 前钉死助手签名要求（macOS 13+ 内核级校验，与助手侧同一可用性门槛）。
    private static func pinHelper(_ connection: NSXPCConnection) {
        if #available(macOS 13.0, *) {
            connection.setCodeSigningRequirement(helperCodeRequirement)
        }
    }

    /// 经 XPC 调用助手执行维护任务
    public func runMaintenance(_ task: MaintenanceTask) async -> (Bool, String?) {
        await withCheckedContinuation { continuation in
            let connection = NSXPCConnection(machServiceName: XicoHelperMachServiceName, options: .privileged)
            connection.remoteObjectInterface = NSXPCInterface(with: XicoHelperProtocol.self)
            Self.pinHelper(connection)
            connection.resume()

            let resumeOnce = ResumeGuard<(Bool, String?)>(continuation)
            Self.scheduleTimeout(resumeOnce, connection,
                                 value: (false, xLocF("助手响应超时（%d 秒）", Int(Self.maintenanceTimeout))),
                                 timeout: Self.maintenanceTimeout)
            let proxy = connection.remoteObjectProxyWithErrorHandler { error in
                resumeOnce.finish((false, xLocF("无法连接助手：%@", error.localizedDescription)))
                connection.invalidate()
            } as? XicoHelperProtocol

            guard let proxy else {
                resumeOnce.finish((false, "助手接口不可用"))
                connection.invalidate()
                return
            }
            proxy.runMaintenance(task.rawValue) { ok, output in
                resumeOnce.finish((ok, output))
                connection.invalidate()
            }
        }
    }

    public func removeProtected(paths: [String]) async -> (Int64, [String]) {
        await withCheckedContinuation { continuation in
            let connection = NSXPCConnection(machServiceName: XicoHelperMachServiceName, options: .privileged)
            connection.remoteObjectInterface = NSXPCInterface(with: XicoHelperProtocol.self)
            Self.pinHelper(connection)
            connection.resume()

            let resumeOnce = ResumeGuard<(Int64, [String])>(continuation)
            // 大批量删除据条目数放宽超时，避免长耗时特权删除被客户端看门狗中途截断、
            // 造成已释放字节计账与失败清单错位。
            Self.scheduleTimeout(resumeOnce, connection, value: (0, paths),
                                 timeout: Self.removalTimeout(pathCount: paths.count))
            let proxy = connection.remoteObjectProxyWithErrorHandler { _ in
                resumeOnce.finish((0, paths))
                connection.invalidate()
            } as? XicoHelperProtocol

            guard let proxy else {
                resumeOnce.finish((0, paths))
                connection.invalidate()
                return
            }
            proxy.removeProtected(paths: paths) { freed, failures in
                resumeOnce.finish((freed, failures))
                connection.invalidate()
            }
        }
    }

    public var processSamplingAvailable: Bool {
        status() == .installed
    }

    public func sampleProcesses(pids: [Int32]) async -> ProcessHelperBatchResponse? {
        guard pids.count <= XicoHelperInfo.maximumProcessSampleCount else { return nil }
        return await withCheckedContinuation { continuation in
            let connection = NSXPCConnection(
                machServiceName: XicoHelperMachServiceName,
                options: .privileged
            )
            connection.remoteObjectInterface = NSXPCInterface(with: XicoHelperProtocol.self)
            Self.pinHelper(connection)
            connection.resume()

            let resumeOnce = ResumeGuard<ProcessHelperBatchResponse?>(continuation)
            Self.scheduleTimeout(resumeOnce, connection, value: nil, timeout: 1.5)
            let proxy = connection.remoteObjectProxyWithErrorHandler { _ in
                resumeOnce.finish(nil)
                connection.invalidate()
            } as? XicoHelperProtocol
            guard let proxy else {
                resumeOnce.finish(nil)
                connection.invalidate()
                return
            }
            proxy.sampleProcesses(pids: pids.map(NSNumber.init(value:))) { data in
                let response = data.flatMap { try? JSONDecoder().decode(
                    ProcessHelperBatchResponse.self,
                    from: $0
                ) }
                resumeOnce.finish(response)
                connection.invalidate()
            }
        }
    }

    /// 版本握手：返回助手自报版本（连接失败/超时返回 nil）。
    public func remoteVersion() async -> String? {
        await withCheckedContinuation { continuation in
            let connection = NSXPCConnection(machServiceName: XicoHelperMachServiceName, options: .privileged)
            connection.remoteObjectInterface = NSXPCInterface(with: XicoHelperProtocol.self)
            Self.pinHelper(connection)
            connection.resume()
            let resumeOnce = ResumeGuard<String?>(continuation)
            Self.scheduleTimeout(resumeOnce, connection, value: nil, timeout: 5)
            let proxy = connection.remoteObjectProxyWithErrorHandler { _ in
                resumeOnce.finish(nil); connection.invalidate()
            } as? XicoHelperProtocol
            guard let proxy else { resumeOnce.finish(nil); connection.invalidate(); return }
            proxy.version { v in resumeOnce.finish(v); connection.invalidate() }
        }
    }

    /// 健康检查 + 自愈：已安装但版本不匹配（协议升级后旧助手常驻）时，注销并重装。
    /// 返回最终是否就绪。
    public func ensureHealthy() async -> Bool {
        guard status() == .installed else { return false }
        let remote = await remoteVersion()
        if remote == XicoHelperInfo.version { return true }
        // 版本不符或无响应 → 尝试自愈：unregister + register
        try? uninstall()
        try? install()
        let after = await remoteVersion()
        return after == XicoHelperInfo.version
    }

    private static func scheduleTimeout<V: Sendable>(_ guardRef: ResumeGuard<V>,
                                                     _ connection: NSXPCConnection,
                                                     value: V, timeout: TimeInterval? = nil) {
        // 用 DispatchWorkItem 承载超时看门狗，交给 ResumeGuard 持有；真正的回复/错误先到时
        // finish() 会取消它，避免这枚定时块把 NSXPCConnection 一直留到 deadline 才释放。
        let work = DispatchWorkItem {
            guardRef.finish(value)
            connection.invalidate()
        }
        guardRef.setTimeout(work)
        DispatchQueue.global().asyncAfter(deadline: .now() + (timeout ?? callTimeout), execute: work)
    }
}

extension HelperProxy: PrivilegedProcessSampling {}

extension HelperProxy: PrivilegedCleaningService {
    public func removeProtected(_ urls: [URL]) async -> PrivilegedRemovalReport {
        let paths = urls.map(\.path)
        let (freed, failures) = await removeProtected(paths: paths)
        return PrivilegedRemovalReport(
            freedBytes: freed,
            failures: failures.map { URL(fileURLWithPath: $0) }
        )
    }
}

/// 确保 continuation 只 resume 一次
private final class ResumeGuard<Value: Sendable>: @unchecked Sendable {
    private var continuation: CheckedContinuation<Value, Never>?
    private var timeout: DispatchWorkItem?
    private let lock = NSLock()
    init(_ c: CheckedContinuation<Value, Never>) { continuation = c }

    /// 登记超时看门狗；finish() 时会取消它，好让持有的连接尽早释放。
    func setTimeout(_ item: DispatchWorkItem) {
        lock.lock(); defer { lock.unlock() }
        timeout = item
    }

    func finish(_ value: sending Value) {
        lock.lock(); defer { lock.unlock() }
        continuation?.resume(returning: value)
        continuation = nil
        timeout?.cancel()
        timeout = nil
    }
}
