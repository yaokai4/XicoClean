import Foundation
import DesignSystem

/// 用户级维护任务（无需 root，直接以当前用户身份执行，立即可用）
public enum UserMaintenanceTask: String, CaseIterable, Identifiable, Sendable {
    case flushQuickLook
    case flushFontCache
    case flushDNS
    case rebuildLaunchServices
    case thinSnapshots
    case restartFinder
    case restartDock

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .flushQuickLook: return "清理「快速查看」缓存"
        case .flushFontCache: return "清理用户字体缓存"
        case .flushDNS: return "刷新 DNS 缓存"
        case .rebuildLaunchServices: return "重建「打开方式」数据库"
        case .thinSnapshots: return "瘦身本地快照"
        case .restartFinder: return "重启访达"
        case .restartDock: return "重启程序坞"
        }
    }
    public var detail: String {
        switch self {
        case .flushQuickLook: return "qlmanage -r cache，解决预览异常。"
        case .flushFontCache: return "atsutil，修复字体显示问题。"
        case .flushDNS: return "dscacheutil，解决网络解析异常。"
        case .rebuildLaunchServices: return "去除右键「打开方式」里的重复项。"
        case .thinSnapshots: return "tmutil，请求系统立即回收 Time Machine 本地快照占用（删文件后空间不涨的头号原因）。"
        case .restartFinder: return "killall Finder，刷新文件浏览。"
        case .restartDock: return "killall Dock，刷新程序坞与触发角。"
        }
    }
    public var systemImage: String {
        switch self {
        case .flushQuickLook: return "eye"
        case .flushFontCache: return "textformat"
        case .flushDNS: return "network"
        case .rebuildLaunchServices: return "arrow.triangle.2.circlepath"
        case .thinSnapshots: return "clock.arrow.circlepath"
        case .restartFinder: return "macwindow"
        case .restartDock: return "dock.rectangle"
        }
    }
    var command: (String, [String]) {
        switch self {
        case .flushQuickLook: return ("/usr/bin/qlmanage", ["-r", "cache"])
        case .flushFontCache: return ("/usr/bin/atsutil", ["databases", "-removeUser"])
        case .flushDNS: return ("/usr/bin/dscacheutil", ["-flushcache"])
        case .rebuildLaunchServices:
            return ("/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister",
                    ["-kill", "-r", "-domain", "local", "-domain", "user"])
        // 请求瘦身全部本地快照（purge 目标给到天文数字 = 尽量多回收；紧迫度 1 = 温和）。
        // tmutil 以当前用户即可发起瘦身请求（实际回收由系统决定并如实回显）。
        case .thinSnapshots: return ("/usr/bin/tmutil", ["thinlocalsnapshots", "/", "999999999999", "1"])
        case .restartFinder: return ("/usr/bin/killall", ["Finder"])
        case .restartDock: return ("/usr/bin/killall", ["Dock"])
        }
    }
}

public struct MaintenanceRunner: Sendable {
    public init() {}

    public func run(_ task: UserMaintenanceTask) async -> (Bool, String) {
        let (path, args) = task.command
        return await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                let proc = Process()
                proc.executableURL = URL(fileURLWithPath: path)
                proc.arguments = args
                let pipe = Pipe()
                proc.standardOutput = pipe
                proc.standardError = pipe
                do {
                    try proc.run()
                    // 先排空管道再 waitUntilExit——否则输出超过管道缓冲区时子进程会阻塞在写、
                    // 父进程阻塞在 wait，维护任务永久挂起（与 runSystemProfiler 同样的排空顺序）。
                    _ = try? pipe.fileHandleForReading.readToEnd()
                    proc.waitUntilExit()
                    // killall 在进程不存在时返回非 0，但维护意义上视为完成
                    let ok = proc.terminationStatus == 0 || path.hasSuffix("killall")
                    // 结果文案在此本地化（与 HelperProxy 一致）：视图直接 Text(msg) 展示，
                    // 复用已翻译的「完成」/「退出码 %d」键，避免向非中文用户漏出中文。
                    cont.resume(returning: (ok, ok ? xLoc("完成") : xLocF("退出码 %d", proc.terminationStatus)))
                } catch {
                    cont.resume(returning: (false, error.localizedDescription))
                }
            }
        }
    }
}
