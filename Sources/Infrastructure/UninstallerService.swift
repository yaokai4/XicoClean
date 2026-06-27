import Foundation
import Domain

public struct InstalledApp: Identifiable, Sendable, Hashable {
    public let id: String
    public let name: String
    public let bundleID: String
    public let url: URL
    public let size: Int64
    public init(id: String, name: String, bundleID: String, url: URL, size: Int64) {
        self.id = id
        self.name = name
        self.bundleID = bundleID
        self.url = url
        self.size = size
    }
}

/// 卸载器：枚举已安装应用，定位其关联文件，生成可预览的卸载计划。
public struct UninstallerService: Sendable {
    private let fs: FileSystemService
    private let safety: SafetyEngine
    private let home: URL

    public init(fs: FileSystemService, safety: SafetyEngine,
                home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.fs = fs
        self.safety = safety
        self.home = home
    }

    /// 快速列出应用（不计算体积，便于秒级出列表）；体积随后由 fillSize 异步补齐。
    public func listApps() -> [InstalledApp] {
        let dirs = [
            URL(fileURLWithPath: "/Applications"),
            URL(fileURLWithPath: "/Applications/Utilities"),
            home.appendingPathComponent("Applications")
        ]
        var apps: [InstalledApp] = []
        var seen = Set<String>()
        for dir in dirs {
            for url in fs.contentsOfDirectory(dir) where url.pathExtension == "app" {
                guard !seen.contains(url.path) else { continue }
                seen.insert(url.path)
                let bundle = Bundle(url: url)
                let bundleID = bundle?.bundleIdentifier ?? url.path
                let name = (bundle?.infoDictionary?["CFBundleDisplayName"] as? String)
                    ?? (bundle?.infoDictionary?["CFBundleName"] as? String)
                    ?? url.deletingPathExtension().lastPathComponent
                apps.append(InstalledApp(id: url.path, name: name, bundleID: bundleID, url: url, size: 0))
            }
        }
        return apps.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// 计算单个应用本体的实际占用
    public func appSize(_ app: InstalledApp) -> Int64 {
        fs.allocatedSize(of: app.url)
    }

    /// 应用本体 + 全部关联文件
    public func uninstallTargets(for app: InstalledApp) -> [CleanableItem] {
        var items: [CleanableItem] = []
        var seen = Set<String>()

        func add(_ url: URL, safety level: SafetyLevel) {
            guard !seen.contains(url.path), fs.exists(url),
                  safety.verify(url, intent: .trash).isAllowed else { return }
            seen.insert(url.path)
            let size = fs.allocatedSize(of: url)
            items.append(CleanableItem(url: url, displayName: url.lastPathComponent,
                                       detail: url.path, size: size, safety: level, isSelected: true))
        }

        // 应用本体
        add(app.url, safety: .safe)

        let lib = home.appendingPathComponent("Library")
        let bid = app.bundleID
        let name = app.name

        // 按 bundleID / 名称定位的固定位置
        let fixed: [URL] = [
            lib.appendingPathComponent("Application Support/\(bid)"),
            lib.appendingPathComponent("Application Support/\(name)"),
            lib.appendingPathComponent("Caches/\(bid)"),
            lib.appendingPathComponent("Preferences/\(bid).plist"),
            lib.appendingPathComponent("Containers/\(bid)"),
            lib.appendingPathComponent("Saved Application State/\(bid).savedState"),
            lib.appendingPathComponent("Logs/\(bid)"),
            lib.appendingPathComponent("HTTPStorages/\(bid)"),
            lib.appendingPathComponent("WebKit/\(bid)")
        ]
        for url in fixed { add(url, safety: .caution) }

        // 需要模糊匹配的位置
        for groupDir in ["Group Containers", "LaunchAgents"] {
            let dir = lib.appendingPathComponent(groupDir)
            for url in fs.contentsOfDirectory(dir) where url.lastPathComponent.contains(bid) {
                add(url, safety: .caution)
            }
        }

        return items
    }
}
