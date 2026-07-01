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

    /// 关联文件定位所用的标识片段是否可安全用于拼接路径。
    /// 拒绝空 / 过短 / 含路径分隔符 / 相对分量的值——畸形 Info.plist 的空
    /// CFBundleDisplayName 曾可拼出 `~/Library/Application Support`（整个应用数据根）作为删除目标。
    static func isValidPathToken(_ token: String) -> Bool {
        let t = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.count >= 2 else { return false }              // 单字符/空一律拒绝
        if t == "." || t == ".." { return false }
        if t.contains("/") || t.contains("\\") { return false }
        if t.hasPrefix(".") { return false }                  // 隐藏/相对起头
        return true
    }

    /// 应用本体 + 全部关联文件
    public func uninstallTargets(for app: InstalledApp) -> [CleanableItem] {
        var items: [CleanableItem] = []
        var seen = Set<String>()

        func add(_ url: URL, safety level: SafetyLevel, selected: Bool = true) {
            // 深度断言：关联文件至少要落在 `~/Library/<类别>/<具体项>`（≥6 分量）之下，
            // 绝不允许目标是 `~/Library/<类别>` 这一级本身（红线亦会拦，此为第一道闸）。
            let underLibrary = url.path.hasPrefix(home.appendingPathComponent("Library").path + "/")
            if underLibrary && url.pathComponents.count < 6 { return }
            guard !seen.contains(url.path), fs.exists(url),
                  safety.verify(url, intent: .trash).isAllowed else { return }
            seen.insert(url.path)
            let size = fs.allocatedSize(of: url)
            items.append(CleanableItem(url: url, displayName: url.lastPathComponent,
                                       detail: url.path, size: size, safety: level, isSelected: selected))
        }

        // 应用本体
        add(app.url, safety: .safe)

        let lib = home.appendingPathComponent("Library")
        let bid = app.bundleID
        let name = app.name
        let bidOK = Self.isValidPathToken(bid)
        let nameOK = Self.isValidPathToken(name)

        // 按 bundleID 定位（bundleID 唯一性高，默认勾选）
        if bidOK {
            let byBID: [URL] = [
                lib.appendingPathComponent("Application Support/\(bid)"),
                lib.appendingPathComponent("Caches/\(bid)"),
                lib.appendingPathComponent("Preferences/\(bid).plist"),
                lib.appendingPathComponent("Containers/\(bid)"),
                lib.appendingPathComponent("Saved Application State/\(bid).savedState"),
                lib.appendingPathComponent("Logs/\(bid)"),
                lib.appendingPathComponent("HTTPStorages/\(bid)"),
                lib.appendingPathComponent("WebKit/\(bid)")
            ]
            for url in byBID { add(url, safety: .caution) }
        }

        // 按显示名定位（易与共享 vendor 目录碰撞，如 Firefox 含书签/密码）——默认**不勾选**，
        // 需用户主动确认，避免"卸载 App A 顺手删掉同厂商 App B 的数据"。
        if nameOK {
            add(lib.appendingPathComponent("Application Support/\(name)"), safety: .caution, selected: false)
        }

        // 需要模糊匹配的位置（子串包含 bundleID）
        if bidOK {
            for groupDir in ["Group Containers", "LaunchAgents"] {
                let dir = lib.appendingPathComponent(groupDir)
                for url in fs.contentsOfDirectory(dir) where url.lastPathComponent.contains(bid) {
                    add(url, safety: .caution)
                }
            }
        }

        return items
    }
}
