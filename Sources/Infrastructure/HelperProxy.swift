import Foundation
import ServiceManagement
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

    /// 经 XPC 调用助手执行维护任务
    public func runMaintenance(_ task: MaintenanceTask) async -> (Bool, String?) {
        await withCheckedContinuation { continuation in
            let connection = NSXPCConnection(machServiceName: XicoHelperMachServiceName, options: .privileged)
            connection.remoteObjectInterface = NSXPCInterface(with: XicoHelperProtocol.self)
            connection.resume()

            let resumeOnce = ResumeGuard(continuation)
            let proxy = connection.remoteObjectProxyWithErrorHandler { error in
                resumeOnce.finish((false, "无法连接助手：\(error.localizedDescription)"))
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
}

/// 确保 continuation 只 resume 一次
private final class ResumeGuard: @unchecked Sendable {
    private var continuation: CheckedContinuation<(Bool, String?), Never>?
    private let lock = NSLock()
    init(_ c: CheckedContinuation<(Bool, String?), Never>) { continuation = c }
    func finish(_ value: (Bool, String?)) {
        lock.lock(); defer { lock.unlock() }
        continuation?.resume(returning: value)
        continuation = nil
    }
}
