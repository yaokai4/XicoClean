import Foundation
import DesignSystem
import ServiceManagement
import Domain
import Shared

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
    private static let callTimeout: TimeInterval = 30

    /// 经 XPC 调用助手执行维护任务
    public func runMaintenance(_ task: MaintenanceTask) async -> (Bool, String?) {
        await withCheckedContinuation { continuation in
            let connection = NSXPCConnection(machServiceName: XicoHelperMachServiceName, options: .privileged)
            connection.remoteObjectInterface = NSXPCInterface(with: XicoHelperProtocol.self)
            connection.resume()

            let resumeOnce = ResumeGuard<(Bool, String?)>(continuation)
            Self.scheduleTimeout(resumeOnce, connection, value: (false, xLocF("助手响应超时（%d 秒）", Int(Self.callTimeout))))
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
            connection.resume()

            let resumeOnce = ResumeGuard<(Int64, [String])>(continuation)
            Self.scheduleTimeout(resumeOnce, connection, value: (0, paths))
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

    /// 版本握手：返回助手自报版本（连接失败/超时返回 nil）。
    public func remoteVersion() async -> String? {
        await withCheckedContinuation { continuation in
            let connection = NSXPCConnection(machServiceName: XicoHelperMachServiceName, options: .privileged)
            connection.remoteObjectInterface = NSXPCInterface(with: XicoHelperProtocol.self)
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
        DispatchQueue.global().asyncAfter(deadline: .now() + (timeout ?? callTimeout)) {
            guardRef.finish(value)
            connection.invalidate()
        }
    }
}

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
    private let lock = NSLock()
    init(_ c: CheckedContinuation<Value, Never>) { continuation = c }
    func finish(_ value: sending Value) {
        lock.lock(); defer { lock.unlock() }
        continuation?.resume(returning: value)
        continuation = nil
    }
}
