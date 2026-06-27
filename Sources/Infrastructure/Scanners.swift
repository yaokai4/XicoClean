import Foundation
import AppKit
import Darwin
import Domain

/// 线程安全计数器
final class AtomicInt: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Int64 = 0
    func add(_ n: Int64) -> Int64 {
        lock.lock(); defer { lock.unlock() }
        value += n
        return value
    }
}

/// 把缓存目录名（常是 bundle id）解析成可读的应用名，让清理结果"看得懂"。
enum FriendlyName {
    private static let lock = NSLock()
    private static var cache: [String: String] = [:]

    static func resolve(_ folder: String) -> String {
        lock.lock(); defer { lock.unlock() }
        if let hit = cache[folder] { return hit }
        let value = compute(folder)
        cache[folder] = value
        return value
    }

    private static func compute(_ folder: String) -> String {
        // 仅当形似 reverse-DNS bundle id 时才尝试解析，避免把 "App-2024.crash" 之类误判
        let looksLikeBundleID = folder.contains(".") && !folder.contains(" ")
            && folder.split(separator: ".").count >= 2
        guard looksLikeBundleID else { return folder }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: folder) {
            return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
        }
        if let known = knownNames[folder] { return known }
        return folder   // 解析不到就保留原名，不瞎猜
    }

    private static let knownNames: [String: String] = [
        "com.apple.Safari": "Safari", "com.google.Chrome": "Google Chrome",
        "com.microsoft.VSCode": "VS Code", "com.microsoft.edgemac": "Microsoft Edge",
        "company.thebrowser.Browser": "Arc", "com.spotify.client": "Spotify",
        "com.tinyspeck.slackmacgap": "Slack", "com.hnc.Discord": "Discord",
        "ru.keepcoder.Telegram": "Telegram", "com.openai.chat": "ChatGPT",
        "com.anthropic.claudefordesktop": "Claude", "com.figma.Desktop": "Figma"
    ]
}

// MARK: - 路径展开

enum PathExpander {
    static func expandHome(_ path: String, home: URL) -> String {
        guard path.hasPrefix("~") else { return path }
        return home.path + String(path.dropFirst())
    }

    /// 多段 glob：支持任意分量含通配符（中段 "*"、前缀 "Name*"、尾部 "/*"）。
    /// 逐段从根下钻：普通分量直接拼接，含 "*" 的分量列目录并用 fnmatch 过滤。
    static func expand(_ pattern: String, home: URL, fs: FileSystemService) -> [URL] {
        let p = expandHome(pattern, home: home)
        let comps = URL(fileURLWithPath: p).pathComponents
        var frontier: [URL] = [URL(fileURLWithPath: "/")]
        for comp in comps.dropFirst() where comp != "/" {
            if comp.contains("*") {
                var next: [URL] = []
                for dir in frontier {
                    for child in fs.contentsOfDirectory(dir) where match(comp, child.lastPathComponent) {
                        next.append(child)
                    }
                }
                frontier = next
                if frontier.isEmpty { break }
            } else {
                frontier = frontier.map { $0.appendingPathComponent(comp) }
            }
        }
        return frontier.filter { fs.exists($0) }
    }

    /// shell 风格通配匹配（仅文件名级，不跨 "/"）
    static func match(_ pattern: String, _ name: String) -> Bool {
        fnmatch(pattern, name, 0) == 0
    }
}

/// 把一组定义跑成扫描结果（系统垃圾 / 隐私共用）。
func scanDefinitions(_ definitions: [CleanupDefinition], moduleID: ModuleID,
                     fs: FileSystemService, safety: SafetyEngine, home: URL,
                     progress: @escaping ProgressHandler,
                     runningIDs: Set<String> = []) -> ScanResult {
    var groups: [ScanResultGroup] = []
    var runningTotal: Int64 = 0

    for def in definitions {
        if Task.isCancelled { break }
        let excludePaths = def.exclude.map { PathExpander.expandHome($0, home: home) }
        var items: [CleanableItem] = []

        for pattern in def.paths {
            for url in PathExpander.expand(pattern, home: home, fs: fs) {
                if Task.isCancelled { break }
                if excludePaths.contains(where: { url.path.hasPrefix($0) }) { continue }
                guard safety.verify(url, intent: .trash).isAllowed else { continue }
                let size = fs.allocatedSize(of: url)
                guard size > 0 else { continue }
                let running = runningIDs.contains(url.lastPathComponent)
                items.append(CleanableItem(url: url, displayName: FriendlyName.resolve(url.lastPathComponent),
                                           detail: url.path, size: size, safety: def.safety,
                                           // 运行中的应用缓存默认不勾选，避免一键清理误删活跃缓存致其异常
                                           isSelected: running ? false : nil,
                                           note: running ? "正在运行 · 建议退出后再清理" : nil))
                runningTotal += size
                progress(ScanProgress(message: url.lastPathComponent, bytesFound: runningTotal))
            }
        }

        if !items.isEmpty {
            items.sort { $0.size > $1.size }
            groups.append(ScanResultGroup(id: def.id, title: def.title, description: def.description,
                                          systemImage: def.systemImage, safety: def.safety, items: items))
        }
    }
    groups.sort { $0.totalSize > $1.totalSize }
    return ScanResult(moduleID: moduleID, groups: groups)
}

// MARK: - 系统垃圾扫描器（系统/开发者/iOS 类别）

public struct SystemJunkScanner: ScannerModule {
    public let metadata = ModuleMetadata(
        id: .systemJunk, title: "系统垃圾", subtitle: "缓存、日志、开发者残余",
        systemImage: "trash", category: .cleanup)

    private let definitions: [CleanupDefinition]
    private let fs: FileSystemService
    private let safety: SafetyEngine
    private let home: URL

    public init(definitions: [CleanupDefinition], fs: FileSystemService, safety: SafetyEngine,
                home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        let junkCategories: Set<String> = ["system-junk", "developer-junk", "ios"]
        self.definitions = definitions.filter { junkCategories.contains($0.category) }
        self.fs = fs
        self.safety = safety
        self.home = home
    }

    public func scan(progress: @escaping ProgressHandler) async throws -> ScanResult {
        let running = await MainActor.run {
            Set(NSWorkspace.shared.runningApplications.compactMap { $0.bundleIdentifier })
        }
        var groups = scanDefinitions(definitions, moduleID: .systemJunk, fs: fs, safety: safety,
                                     home: home, progress: progress, runningIDs: running).groups
        if let darwin = darwinTempCacheGroup(running: running, progress: progress) { groups.append(darwin) }
        let (leftovers, orphanContainerPaths) = leftoversGroup(progress: progress)
        // 去重：孤儿容器整体已计入「残留」，从「沙盒应用缓存」里剔除其下子项，避免重复计入夸大总量
        if !orphanContainerPaths.isEmpty,
           let idx = groups.firstIndex(where: { $0.id == "containers-caches" }) {
            groups[idx].items.removeAll { item in
                orphanContainerPaths.contains { item.url.path.hasPrefix($0 + "/") }
            }
            if groups[idx].items.isEmpty { groups.remove(at: idx) }
        }
        if let leftovers { groups.append(leftovers) }
        groups.sort { $0.totalSize > $1.totalSize }
        return ScanResult(moduleID: .systemJunk, groups: groups)
    }

    /// macOS 给各 App 分配的每用户临时缓存（/private/var/folders/.../C），无需 root，删除安全可重建。
    private func darwinTempCacheGroup(running: Set<String>, progress: @escaping ProgressHandler) -> ScanResultGroup? {
        guard let dir = Self.darwinUserCacheURL() else { return nil }
        var items: [CleanableItem] = []
        for url in fs.contentsOfDirectory(dir) {
            if Task.isCancelled { break }
            guard safety.verify(url, intent: .trash).isAllowed else { continue }
            let size = fs.allocatedSize(of: url)
            guard size > 1_000_000 else { continue }   // 只列 ≥1MB，避免噪音
            let isRunning = running.contains(url.lastPathComponent)
            items.append(CleanableItem(url: url, displayName: FriendlyName.resolve(url.lastPathComponent),
                                       detail: url.path, size: size, safety: .caution,
                                       isSelected: isRunning ? false : nil,
                                       note: isRunning ? "正在运行 · 建议退出后再清理" : nil))
            progress(ScanProgress(message: url.lastPathComponent, bytesFound: 0))
        }
        guard !items.isEmpty else { return nil }
        items.sort { $0.size > $1.size }
        return ScanResultGroup(id: "darwin-temp-cache", title: "系统临时缓存",
                               description: "macOS 为各应用分配的临时缓存（/private/var/folders），删除安全、会自动重建。",
                               systemImage: "cpu", safety: .caution, items: items)
    }

    /// 已卸载应用残留：仅扫沙盒容器与窗口状态（按 bundle id 一一对应，误判极低）。
    /// 刻意不扫 Application Support —— 那里混有 Adobe dunamis 等"无独立 App 的框架组件"，
    /// 会被误判成残留，对清理器而言误删比漏删更致命。
    private func leftoversGroup(progress: @escaping ProgressHandler) -> (group: ScanResultGroup?, orphanContainerPaths: Set<String>) {
        let containersRoot = home.appendingPathComponent("Library/Containers")
        let roots = [containersRoot, home.appendingPathComponent("Library/Saved Application State")]
        var items: [CleanableItem] = []
        var orphanContainerPaths = Set<String>()
        for root in roots {
            for url in fs.contentsOfDirectory(root) {
                if Task.isCancelled { break }
                let name = url.lastPathComponent.replacingOccurrences(of: ".savedState", with: "")
                guard Self.isOrphanBundleID(name) else { continue }
                guard safety.verify(url, intent: .trash).isAllowed else { continue }
                let size = fs.allocatedSize(of: url)
                guard size > 0 else { continue }
                if root == containersRoot { orphanContainerPaths.insert(url.path) }
                items.append(CleanableItem(url: url, displayName: name, detail: url.path,
                                           size: size, safety: .caution, note: "已卸载应用残留"))
                progress(ScanProgress(message: name, bytesFound: 0))
            }
        }
        guard !items.isEmpty else { return (nil, orphanContainerPaths) }
        items.sort { $0.size > $1.size }
        let group = ScanResultGroup(id: "app-leftovers", title: "已卸载应用残留",
                               description: "已不在本机的应用遗留的支持文件。确认不再需要后再清理（移入废纸篓可恢复）。",
                               systemImage: "questionmark.folder", safety: .caution, items: items)
        return (group, orphanContainerPaths)
    }

    static func darwinUserCacheURL() -> URL? {
        var buf = [CChar](repeating: 0, count: Int(PATH_MAX))
        let n = confstr(_CS_DARWIN_USER_CACHE_DIR, &buf, buf.count)
        guard n > 0 else { return nil }
        return URL(fileURLWithPath: String(cString: buf), isDirectory: true)
    }

    /// 形似 reverse-DNS bundle id、非苹果/系统、且本机查不到对应 App → 视为残留。
    /// 关键：连同它的父级 id 一起查；只要任一父级对应着已安装 App（如扩展
    /// com.microsoft.OneDrive.FileProvider 的父级 com.microsoft.OneDrive 还在），就不算残留。
    static func isOrphanBundleID(_ name: String) -> Bool {
        let parts = name.split(separator: ".")
        guard !name.contains(" "), parts.count >= 3 else { return false }
        let lower = name.lowercased()
        let systemPrefixes = ["com.apple", "group.com.apple", "apple.", "com.crashlytics", "org.swift"]
        if systemPrefixes.contains(where: { lower.hasPrefix($0) }) { return false }
        var idx = parts.count
        while idx >= 2 {
            let candidate = parts.prefix(idx).joined(separator: ".")
            if NSWorkspace.shared.urlForApplication(withBundleIdentifier: candidate) != nil { return false }
            idx -= 1
        }
        return true
    }
}

// MARK: - 隐私扫描器（浏览器数据等）

public struct PrivacyScanner: ScannerModule {
    public let metadata = ModuleMetadata(
        id: .privacy, title: "隐私", subtitle: "浏览器缓存与历史",
        systemImage: "hand.raised", category: .performance)

    private let definitions: [CleanupDefinition]
    private let fs: FileSystemService
    private let safety: SafetyEngine
    private let home: URL

    public init(definitions: [CleanupDefinition], fs: FileSystemService, safety: SafetyEngine,
                home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.definitions = definitions.filter { $0.category == "privacy" }
        self.fs = fs
        self.safety = safety
        self.home = home
    }

    public func scan(progress: @escaping ProgressHandler) async throws -> ScanResult {
        scanDefinitions(definitions, moduleID: .privacy, fs: fs, safety: safety, home: home, progress: progress)
    }
}

// MARK: - 大文件扫描器

public struct LargeFilesScanner: ScannerModule {
    public let metadata = ModuleMetadata(
        id: .largeFiles, title: "大文件与旧文件", subtitle: "找出占空间的大块头",
        systemImage: "doc.viewfinder", category: .filesSpace)

    private let fs: FileSystemService
    private let safety: SafetyEngine
    private let home: URL
    private let threshold: Int64
    private let maxItems: Int

    public init(fs: FileSystemService, safety: SafetyEngine,
                home: URL = FileManager.default.homeDirectoryForCurrentUser,
                thresholdBytes: Int64 = 100 * 1024 * 1024, maxItems: Int = 200) {
        self.fs = fs
        self.safety = safety
        self.home = home
        self.threshold = thresholdBytes
        self.maxItems = maxItems
    }

    public func scan(progress: @escaping ProgressHandler) async throws -> ScanResult {
        let roots = scanRoots()
        let counter = AtomicInt()
        let fs = self.fs
        let safety = self.safety
        let threshold = self.threshold

        // 各用户目录并发遍历，重叠 I/O 提速
        var items = await withTaskGroup(of: [CleanableItem].self) { group in
            for root in roots {
                group.addTask {
                    var local: [CleanableItem] = []
                    for await entry in fs.deepEnumerate(root, includeFiles: true) {
                        if Task.isCancelled { break }
                        guard !entry.isDirectory, entry.size >= threshold else { continue }
                        guard safety.verify(entry.url, intent: .trash).isAllowed else { continue }
                        local.append(CleanableItem(url: entry.url, displayName: entry.url.lastPathComponent,
                                                   detail: entry.url.path, size: entry.size,
                                                   safety: .caution, isSelected: false))
                        let running = counter.add(entry.size)
                        progress(ScanProgress(message: entry.url.lastPathComponent, bytesFound: running))
                    }
                    return local
                }
            }
            var all: [CleanableItem] = []
            for await part in group { all += part }
            return all
        }

        items.sort { $0.size > $1.size }
        if items.count > maxItems { items = Array(items.prefix(maxItems)) }
        let group = ScanResultGroup(id: "large-files", title: "大文件（≥ \(threshold.formattedBytes)）",
                                    description: "扫描下载、文稿、影片等用户目录；删除前请确认，全部移入废纸篓可恢复。",
                                    systemImage: "doc.viewfinder", safety: .caution, items: items)
        return ScanResult(moduleID: .largeFiles, groups: items.isEmpty ? [] : [group])
    }

    /// 用户内容目录（跳过资源库与隐藏目录，避免遍历海量小文件拖慢扫描）
    private func scanRoots() -> [URL] {
        let skip: Set<String> = ["Library"]
        return fs.contentsOfDirectory(home).filter { url in
            let name = url.lastPathComponent
            guard !name.hasPrefix("."), !skip.contains(name) else { return false }
            return (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
        }
    }
}

// MARK: - 废纸篓扫描器

public struct TrashScanner: ScannerModule {
    public let metadata = ModuleMetadata(
        id: .trash, title: "废纸篓", subtitle: "清空废纸篓释放空间",
        systemImage: "trash.circle", category: .cleanup)

    private let fs: FileSystemService
    private let home: URL

    public init(fs: FileSystemService, home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.fs = fs
        self.home = home
    }

    public func scan(progress: @escaping ProgressHandler) async throws -> ScanResult {
        let trash = home.appendingPathComponent(".Trash")
        var items: [CleanableItem] = []
        var total: Int64 = 0
        for url in fs.contentsOfDirectory(trash) {
            if Task.isCancelled { break }
            let size = fs.allocatedSize(of: url)
            items.append(CleanableItem(url: url, displayName: url.lastPathComponent,
                                       detail: url.path, size: size, safety: .safe))
            total += size
            progress(ScanProgress(message: url.lastPathComponent, bytesFound: total))
        }
        items.sort { $0.size > $1.size }
        let group = ScanResultGroup(id: "trash", title: "废纸篓内容",
                                    description: "清空将彻底删除这些项目（不可恢复）。",
                                    systemImage: "trash.circle", safety: .safe, items: items)
        return ScanResult(moduleID: .trash, groups: items.isEmpty ? [] : [group])
    }
}
