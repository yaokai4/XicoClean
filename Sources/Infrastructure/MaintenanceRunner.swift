import Foundation

/// 用户级维护任务（无需 root，直接以当前用户身份执行，立即可用）
public enum UserMaintenanceTask: String, CaseIterable, Identifiable, Sendable {
    case flushQuickLook
    case flushFontCache
    case flushDNS
    case rebuildLaunchServices
    case restartFinder
    case restartDock

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .flushQuickLook: return "清理「快速查看」缓存"
        case .flushFontCache: return "清理用户字体缓存"
        case .flushDNS: return "刷新 DNS 缓存"
        case .rebuildLaunchServices: return "重建「打开方式」数据库"
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
                    proc.waitUntilExit()
                    // killall 在进程不存在时返回非 0，但维护意义上视为完成
                    let ok = proc.terminationStatus == 0 || path.hasSuffix("killall")
                    cont.resume(returning: (ok, ok ? "完成" : "退出码 \(proc.terminationStatus)"))
                } catch {
                    cont.resume(returning: (false, error.localizedDescription))
                }
            }
        }
    }
}
