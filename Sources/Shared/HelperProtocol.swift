import Foundation

/// 特权助手的 Mach 服务名（与嵌入 App 的 LaunchDaemon plist 对应）
public let XicoHelperMachServiceName = "com.xico.app.helper"
public let XicoHelperPlistName = "com.xico.app.helper.plist"

/// 需要 root 的维护任务
public enum MaintenanceTask: String, Sendable, Codable, CaseIterable {
    case freeMemory
    case flushDNS
    case rebuildSpotlight
    case runPeriodicScripts
    case deleteLocalSnapshots

    public var title: String {
        switch self {
        case .freeMemory: return "释放非活跃内存"
        case .flushDNS: return "刷新 DNS 缓存"
        case .rebuildSpotlight: return "重建 Spotlight 索引"
        case .runPeriodicScripts: return "运行系统维护脚本"
        case .deleteLocalSnapshots: return "删除本地 Time Machine 快照"
        }
    }
    public var detail: String {
        switch self {
        case .freeMemory: return "purge — 回收非活跃内存页，缓解内存压力。"
        case .flushDNS: return "清空 DNS 解析缓存，解决某些网络访问异常。"
        case .rebuildSpotlight: return "mdutil -E — 重建搜索索引（重建期间搜索会变慢）。"
        case .runPeriodicScripts: return "periodic daily weekly monthly — 清理旧日志、轮转等。"
        case .deleteLocalSnapshots: return "tmutil — 删除占用磁盘的本地快照，立刻腾出空间。"
        }
    }
    public var systemImage: String {
        switch self {
        case .freeMemory: return "memorychip"
        case .flushDNS: return "network"
        case .rebuildSpotlight: return "magnifyingglass"
        case .runPeriodicScripts: return "wrench.and.screwdriver"
        case .deleteLocalSnapshots: return "clock.arrow.circlepath"
        }
    }
}

/// 主应用 ↔ 特权助手 的 XPC 接口（最小、白名单化）
@objc public protocol XicoHelperProtocol {
    /// 执行一项维护任务
    func runMaintenance(_ rawTask: String, reply: @escaping (Bool, String?) -> Void)
    /// 删除需 root 权限的路径列表（助手端会再次做安全校验）
    func removeProtected(paths: [String], reply: @escaping (Int64, [String]) -> Void)
    /// 助手版本（用于连通性自检）
    func version(reply: @escaping (String) -> Void)
}
