import Foundation
import DesignSystem
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
    private static let store = FriendlyNameStore()

    static func resolve(_ folder: String) -> String {
        store.resolve(folder)
    }

    private final class FriendlyNameStore: @unchecked Sendable {
        private let lock = NSLock()
        private var cache: [String: String] = [:]

        func resolve(_ folder: String) -> String {
            lock.lock()
            if let hit = cache[folder] {
                lock.unlock()
                return hit
            }
            lock.unlock()

            let value = FriendlyName.compute(folder)

            lock.lock()
            cache[folder] = value
            lock.unlock()
            return value
        }
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

    static func isExcluded(_ url: URL, byRoots roots: [String]) -> Bool {
        let target = normalized(url)
        return roots.contains { root in
            let normalizedRoot = normalized(URL(fileURLWithPath: root))
            return target == normalizedRoot || target.hasPrefix(normalizedRoot + "/")
        }
    }

    private static func normalized(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }
}

/// 日志类规则：macOS 自动轮转日志，正常体积清了没意义还破坏故障诊断（Eclectic Light 结论）——
/// 默认只勾选**异常膨胀**（单项 ≥ 该阈值）的日志，其余列出不选（P5 保守化默认）。
private let conservativeLogDefIDs: Set<String> = ["user-logs", "system-logs"]
private let logAnomalyThreshold: Int64 = 500 * 1_048_576

/// 把一组定义跑成扫描结果（系统垃圾 / 隐私共用）。
/// async（P1 性能）：`allocatedSize` 对大容器缓存是同步递归求和——每项之间让出协作线程，
/// 长扫描不再饿死同池的其它异步任务（菜单栏采样等）。
func scanDefinitions(_ definitions: [CleanupDefinition], moduleID: ModuleID,
                     fs: FileSystemService, safety: SafetyEngine, home: URL,
                     progress: @escaping ProgressHandler,
                     runningIDs: Set<String> = []) async -> ScanResult {
    var groups: [ScanResultGroup] = []
    var runningTotal: Int64 = 0

    for def in definitions {
        if Task.isCancelled { break }
        let excludePaths = def.exclude.map { PathExpander.expandHome($0, home: home) }
        let conservativeLog = conservativeLogDefIDs.contains(def.id)
        var items: [CleanableItem] = []

        for pattern in def.paths {
            for url in PathExpander.expand(pattern, home: home, fs: fs) {
                if Task.isCancelled { break }
                await Task.yield()   // 每项一次让步：递归求和不长占协作线程
                if PathExpander.isExcluded(url, byRoots: excludePaths) { continue }
                guard safety.verify(url, intent: .trash).isAllowed else { continue }
                let size = fs.allocatedSize(of: url)
                guard size > 0 else { continue }
                guard let constraintEvidence = evaluate(def.constraints, for: url, size: size) else { continue }
                let running = runningIDs.contains(url.lastPathComponent)
                let oversizeLog = conservativeLog && size >= logAnomalyThreshold
                let note: String?
                if def.requiresHelper {
                    note = "需要管理员权限 · 彻底删除"
                } else if running {
                    note = "正在运行 · 建议退出后再清理"
                } else if oversizeLog {
                    note = "异常膨胀 · 建议清理"
                } else {
                    note = nil
                }
                // 勾选策略：管理员/运行中一律不选；保守日志仅异常膨胀者选；其余按安全级默认。
                let selected: Bool?
                if running || def.requiresHelper {
                    selected = false
                } else if conservativeLog {
                    selected = oversizeLog
                } else {
                    selected = nil
                }
                let confidence = def.constraints?.recommendationConfidence
                    ?? (def.safety == .safe ? 0.99 : 0.82)
                let evidence: [ScanEvidence] = [
                    ScanEvidence(code: "definition-\(def.id)", kind: .signedRule,
                                 title: "命中 Xico 清理规则 \(def.id)",
                                 detail: def.resolvedExplanation, strength: 1),
                    ScanEvidence(code: "path-verified", kind: .pathOwnership,
                                 title: "路径归属与删除红线校验通过", strength: 0.98)
                ] + constraintEvidence
                items.append(CleanableItem(url: url, displayName: FriendlyName.resolve(url.lastPathComponent),
                                           detail: url.path, size: size, safety: def.safety,
                                           isSelected: selected,
                                           requiresHelper: def.requiresHelper,
                                           note: note,
                                           assessment: FindingAssessment(
                                            ruleID: def.id,
                                            confidence: confidence,
                                            evidence: evidence,
                                            ownerBundleID: inferredBundleID(from: url),
                                            reclaimableBytes: size,
                                            recovery: def.constraints?.recovery
                                                ?? (def.safety == .safe ? .regenerate : .trash),
                                            regenerationCost: def.constraints?.regenerationCost
                                                ?? (def.safety == .safe ? .low : .medium),
                                            impact: def.resolvedExplanation,
                                            provenance: "definition-library"
                                           )))
                runningTotal += size
                progress(ScanProgress(message: url.lastPathComponent, bytesFound: runningTotal))
            }
        }

        if !items.isEmpty {
            items.sort { $0.size > $1.size }
            // 保留策略（P1）：DeviceSupport **按平台各保最新一份**（iOS/watchOS/tvOS 三平台
            // 合在一条定义里，全局取一会把「手表平台唯一且在用」的符号目录默认勾删——终审 P2）；
            // iOS 备份保留最近一次（数据安全底线）——保留项强制不勾 + 说明。
            if def.id == "xcode-devicesupport" {
                markNewestKeepPerParent(&items, fs: fs, note: "最新版本 · 真机调试仍需，建议保留")
            } else if def.id == "ios-backups" {
                markNewestKeep(&items, fs: fs, note: "最近一次备份 · 建议保留")
            }
            groups.append(ScanResultGroup(id: def.id, title: def.title, description: def.description,
                                          systemImage: def.systemImage, safety: def.safety,
                                          explanation: def.resolvedExplanation, items: items))
        }
    }
    groups.sort { $0.totalSize > $1.totalSize }
    return ScanResult(moduleID: moduleID, groups: groups)
}

/// Rule DSL 2.0 谓词求值。返回 nil 表示至少一项无法证明，必须从严跳过。
private func evaluate(_ constraints: CleanupConstraints?, for url: URL,
                      size: Int64, now: Date = Date()) -> [ScanEvidence]? {
    guard let constraints else { return [] }
    let osMajor = ProcessInfo.processInfo.operatingSystemVersion.majorVersion
    if let minimum = constraints.minimumOSMajor, osMajor < minimum { return nil }
    if let maximum = constraints.maximumOSMajor, osMajor > maximum { return nil }
    if let minimum = constraints.minimumSizeBytes, size < minimum { return nil }
    if let maximum = constraints.maximumSizeBytes, size > maximum { return nil }
    if !constraints.fileExtensions.isEmpty {
        let allowed = Set(constraints.fileExtensions.map { $0.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".")) })
        guard allowed.contains(url.pathExtension.lowercased()) else { return nil }
    }

    var evidence: [ScanEvidence] = []
    if let minimum = constraints.minimumSizeBytes {
        evidence.append(ScanEvidence(code: "min-size-\(minimum)", kind: .size,
                                     title: "达到规则体积阈值",
                                     detail: "至少 \(minimum.formattedBytes)", strength: 0.9))
    }
    if let days = constraints.minimumAgeDays {
        let values = try? url.resourceValues(forKeys: [.contentAccessDateKey,
                                                       .contentModificationDateKey])
        guard let last = values?.contentModificationDate ?? values?.contentAccessDate,
              now.timeIntervalSince(last) >= Double(days) * 86_400 else { return nil }
        evidence.append(ScanEvidence(code: "min-age-\(days)", kind: .age,
                                     title: "超过 \(days) 天未使用", strength: 0.9))
    }
    if !constraints.fileExtensions.isEmpty {
        evidence.append(ScanEvidence(code: "file-extension", kind: .pathOwnership,
                                     title: "文件类型符合规则范围", strength: 0.85))
    }
    return evidence
}

/// 缓存/容器目录常以 bundle id 命名；只在格式足够明确时标注归属，宁可 nil 不乱猜。
private func inferredBundleID(from url: URL) -> String? {
    for component in url.pathComponents.reversed() {
        let lower = component.lowercased()
        if lower.contains("."), !component.hasPrefix("."),
           component.split(separator: ".").count >= 3,
           component.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" || $0 == "_" }) {
            return component
        }
    }
    return nil
}

/// 按「父目录」分桶后各自保留最新一份——DeviceSupport 的 iOS/watchOS/tvOS 三平台在同一条
/// 定义里，父目录（"iOS DeviceSupport" 等）即平台边界；每个平台的最新版本都可能正在使用。
private func markNewestKeepPerParent(_ items: inout [CleanableItem], fs: FileSystemService, note: String) {
    let parents = Set(items.map { $0.url.deletingLastPathComponent().path })
    for parent in parents {
        let bucket = items.enumerated().filter { $0.element.url.deletingLastPathComponent().path == parent }
        guard !bucket.isEmpty else { continue }
        var newestIdx = bucket[0].offset
        var newestDate = Date.distantPast
        for (offset, item) in bucket {
            let d = fs.entry(for: item.url)?.modificationDate ?? .distantPast
            if d > newestDate { newestDate = d; newestIdx = offset }
        }
        let old = items[newestIdx]
        items[newestIdx] = CleanableItem(id: old.id, url: old.url, displayName: old.displayName,
                                         detail: old.detail, size: old.size, safety: old.safety,
                                         isSelected: false, requiresHelper: old.requiresHelper,
                                         note: note, assessment: old.assessment)
    }
}

/// 把（按修改时间）最新的一项强制置为不勾选并加保留提示——DeviceSupport/iOS 备份的保留策略。
private func markNewestKeep(_ items: inout [CleanableItem], fs: FileSystemService, note: String) {
    guard items.count > 0 else { return }
    var newestIdx = 0
    var newestDate = Date.distantPast
    for (i, item) in items.enumerated() {
        let d = fs.entry(for: item.url)?.modificationDate ?? .distantPast
        if d > newestDate { newestDate = d; newestIdx = i }
    }
    let old = items[newestIdx]
    items[newestIdx] = CleanableItem(id: old.id, url: old.url, displayName: old.displayName,
                                     detail: old.detail, size: old.size, safety: old.safety,
                                     isSelected: false, requiresHelper: old.requiresHelper,
                                     note: note, assessment: old.assessment)
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
    /// 是否内联「已卸载应用残留」浅扫（容器 + 窗口状态）。独立「系统垃圾」页默认开；
    /// 智能扫描中枢传 false——那里由 OrphanScanner（P4 全量孤儿引擎，按 App 分组）接管，避免两套并列。
    private let includeLeftovers: Bool

    /// 是否纳入 privacy 类定义（浏览器缓存）。独立「系统垃圾」页默认开——侧边栏没有独立
    /// 隐私入口，而 user-caches 又刻意排除了浏览器目录（交给专项规则），不纳入的话浏览器
    /// 缓存在独立页上两头落空（2026-07 审计发现）；智能扫描中枢传 false（那里由并列的
    /// PrivacyScanner 承担，避免同一路径在两个引擎里重复计量）。
    public init(definitions: [CleanupDefinition], fs: FileSystemService, safety: SafetyEngine,
                home: URL = FileManager.default.homeDirectoryForCurrentUser,
                includeLeftovers: Bool = true, includePrivacy: Bool = true) {
        var junkCategories: Set<String> = ["system-junk", "developer-junk", "ios"]
        if includePrivacy { junkCategories.insert("privacy") }
        self.definitions = definitions.filter { junkCategories.contains($0.category) }
        self.fs = fs
        self.safety = safety
        self.home = home
        self.includeLeftovers = includeLeftovers
    }

    public func scan(progress: @escaping ProgressHandler) async throws -> ScanResult {
        let running = await MainActor.run {
            Set(NSWorkspace.shared.runningApplications.compactMap { $0.bundleIdentifier })
        }
        var groups = await scanDefinitions(definitions, moduleID: .systemJunk, fs: fs, safety: safety,
                                           home: home, progress: progress, runningIDs: running).groups
        // 继续累计已发现字节，避免后续分组从 0 汇报导致进度环数字中途回跳。
        var base = groups.reduce(Int64(0)) { $0 + $1.totalSize }
        if let darwin = darwinTempCacheGroup(running: running, baseTotal: base, progress: progress) {
            groups.append(darwin); base += darwin.totalSize
        }
        // /private/var/folders 的 T（临时）目录：与 C（缓存）同为系统分配的每用户目录，
        // 只列 3 天以上未动的项——新鲜临时文件可能被进程持有中（2026-07 系统级精细化）。
        if let darwinTemp = darwinTempFilesGroup(running: running, baseTotal: base, progress: progress) {
            groups.append(darwinTemp); base += darwinTemp.totalSize
        }
        // Docker 磁盘镜像引导（P1）：Docker.raw 动辄几十 GB，但**绝不能直接删**（删 = 所有容器/镜像全毁）。
        // 列出体积 + 指路 `docker system prune`，risky 永不勾选——「不做危险项」是安全卖点。
        if let docker = dockerGuidanceGroup() { groups.append(docker) }
        // 三个「仅提示」组（2026-07 系统级精细化）：只解释体量与正确的处置方式，永不代删——
        // 「大而不能乱删」的诚实呈现是与激进清理器的差异化卖点。
        if let sims = simulatorDevicesGuidanceGroup() { groups.append(sims) }
        if let gomod = goModCacheGuidanceGroup() { groups.append(gomod) }
        if let vm = vmFilesGuidanceGroup() { groups.append(vm) }
        if includeLeftovers {
            let (leftovers, orphanContainerPaths) = leftoversGroup(baseTotal: base, progress: progress)
            // 去重：孤儿容器整体已计入「残留」，从「沙盒应用缓存」里剔除其下子项，避免重复计入夸大总量
            if !orphanContainerPaths.isEmpty,
               let idx = groups.firstIndex(where: { $0.id == "containers-caches" }) {
                groups[idx].items.removeAll { item in
                    orphanContainerPaths.contains { item.url.path.hasPrefix($0 + "/") }
                }
                if groups[idx].items.isEmpty { groups.remove(at: idx) }
            }
            if let leftovers { groups.append(leftovers) }
        }
        groups.sort { $0.totalSize > $1.totalSize }
        return ScanResult(moduleID: .systemJunk, groups: groups)
    }

    /// macOS 给各 App 分配的每用户临时缓存（/private/var/folders/.../C），无需 root，删除安全可重建。
    private func darwinTempCacheGroup(running: Set<String>, baseTotal: Int64,
                                      progress: @escaping ProgressHandler) -> ScanResultGroup? {
        guard let dir = Self.darwinUserCacheURL() else { return nil }
        var items: [CleanableItem] = []
        var total = baseTotal
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
            total += size
            progress(ScanProgress(message: url.lastPathComponent, bytesFound: total))
        }
        guard !items.isEmpty else { return nil }
        items.sort { $0.size > $1.size }
        return ScanResultGroup(id: "darwin-temp-cache", title: "系统临时缓存",
                               description: "macOS 为各应用分配的临时缓存（/private/var/folders），删除安全、会自动重建。",
                               systemImage: "cpu", safety: .caution, items: items)
    }

    /// /private/var/folders 的 T（临时）目录：macOS 为各 App 分配的每用户临时文件区。
    /// 与 C（缓存）目录同源同性质，但临时文件可能被运行中的进程持有——只列**3 天以上未动**
    /// 且 ≥1MB 的项，caution 默认不勾，由用户确认。
    private func darwinTempFilesGroup(running: Set<String>, baseTotal: Int64,
                                      progress: @escaping ProgressHandler) -> ScanResultGroup? {
        guard let dir = Self.darwinUserTempURL() else { return nil }
        let now = Date()
        var items: [CleanableItem] = []
        var total = baseTotal
        for url in fs.contentsOfDirectory(dir) {
            if Task.isCancelled { break }
            guard safety.verify(url, intent: .trash).isAllowed else { continue }
            // 3 天新鲜期：正在被进程使用的临时文件多在此窗口内，宁可漏、不可误。
            let modified = fs.entry(for: url)?.modificationDate ?? now
            guard now.timeIntervalSince(modified) > 3 * 86400 else { continue }
            let size = fs.allocatedSize(of: url)
            guard size > 1_000_000 else { continue }
            let isRunning = running.contains(url.lastPathComponent)
            items.append(CleanableItem(url: url, displayName: FriendlyName.resolve(url.lastPathComponent),
                                       detail: url.path, size: size, safety: .caution,
                                       isSelected: false,
                                       note: isRunning ? "正在运行 · 建议退出后再清理" : "3 天以上未动的临时文件"))
            total += size
            progress(ScanProgress(message: url.lastPathComponent, bytesFound: total))
        }
        guard !items.isEmpty else { return nil }
        items.sort { $0.size > $1.size }
        return ScanResultGroup(id: "darwin-temp-files", title: "系统临时文件",
                               description: "macOS 为各应用分配的临时文件区（/private/var/folders 的 T 目录），只列 3 天以上未动的项。",
                               systemImage: "clock.arrow.2.circlepath", safety: .caution,
                               explanation: "T 目录与系统临时缓存同源，存放应用的中间临时文件；新鲜文件可能仍被进程持有，因此只列出 3 天以上未动的项，默认不勾选。删除后应用按需重建。",
                               items: items)
    }

    /// iOS 模拟器设备引导项（仅提示）：CoreSimulator/Devices 动辄 20–100GB，但哪些「不可用」
    /// 需要 simctl 运行时判定——指路 `xcrun simctl delete unavailable`，Xico 不代删模拟器设备。
    private func simulatorDevicesGuidanceGroup() -> ScanResultGroup? {
        let devices = home.appendingPathComponent("Library/Developer/CoreSimulator/Devices")
        guard fs.exists(devices) else { return nil }
        let size = fs.allocatedSize(of: devices)
        guard size > 1 << 30 else { return nil }   // <1GB 不值得提示
        let item = CleanableItem(url: devices, displayName: "CoreSimulator/Devices",
                                 detail: devices.path, size: size, safety: .risky,
                                 note: "模拟器设备 · 请在终端运行 xcrun simctl delete unavailable 清理旧版本，勿直接删除",
                                 isInformational: true)
        return ScanResultGroup(
            id: "simulator-devices-guidance", title: "模拟器设备（仅提示）",
            description: "iOS 模拟器设备的数据盘。直接删除会毁掉全部模拟器与其中数据。正确瘦身：xcrun simctl delete unavailable（清理不可用旧设备）。Xico 不代删。",
            systemImage: "iphone.gen3.slash", safety: .risky,
            explanation: "每个模拟器设备是一块完整的数据盘，其中可能有你测试中的 App 与数据。哪些设备属于「不可用旧版本」需要 Xcode 工具链运行时判定，因此 Xico 只提示总体积、指路官方命令，绝不代删。",
            items: [item])
    }

    /// Go 模块缓存引导项（仅提示）：~/go/pkg/mod 的文件是**只读**权限，直接移废纸篓会
    /// 大面积失败——正确方式是 `go clean -modcache`。列体积 + 指路，不代删。
    private func goModCacheGuidanceGroup() -> ScanResultGroup? {
        let mod = home.appendingPathComponent("go/pkg/mod")
        guard fs.exists(mod) else { return nil }
        let size = fs.allocatedSize(of: mod)
        guard size > 1 << 30 else { return nil }
        let item = CleanableItem(url: mod, displayName: xLoc("Go 模块缓存"),
                                 detail: mod.path, size: size, safety: .risky,
                                 note: "只读缓存 · 请在终端运行 go clean -modcache 释放，勿直接删除",
                                 isInformational: true)
        return ScanResultGroup(
            id: "go-modcache-guidance", title: "Go 模块缓存（终端瘦身）",
            description: "Go 的全局模块缓存（~/go/pkg/mod）。其中文件为只读权限，直接删除会部分失败。正确瘦身：go clean -modcache。Xico 不代删。",
            systemImage: "shippingbox.circle", safety: .risky,
            explanation: "Go 工具链刻意把模块缓存设为只读以保证构建可复现，绕过权限强删既不完整也可能留下损坏的缓存状态；go clean -modcache 是官方且完整的释放方式，下次构建按需重新下载。",
            items: [item])
    }

    /// 休眠镜像与交换文件（仅提示）：/private/var/vm 由 macOS 全权自管，任何工具都不应删——
    /// 诚实解释「这块空间为什么在、什么时候还」，与激进清理器划清界限。
    private func vmFilesGuidanceGroup() -> ScanResultGroup? {
        let vm = URL(fileURLWithPath: "/private/var/vm", isDirectory: true)
        guard fs.exists(vm) else { return nil }
        let size = fs.allocatedSize(of: vm)
        guard size > 1 << 30 else { return nil }
        let item = CleanableItem(url: vm, displayName: xLoc("休眠镜像与交换文件"),
                                 detail: vm.path, size: size, safety: .risky,
                                 note: "系统自管 · 重启或内存压力缓解后自动回收，任何工具都不应删除",
                                 isInformational: true)
        return ScanResultGroup(
            id: "vm-files-guidance", title: "休眠镜像与交换文件（仅提示）",
            description: "macOS 的内存休眠镜像（sleepimage）与交换文件（swapfile）。系统自动管理，删除会被立即重建甚至引发不稳定。Xico 只解释、不代删。",
            systemImage: "memorychip", safety: .risky,
            explanation: "这块空间是 macOS 虚拟内存体系的一部分：休眠镜像保存睡眠时的内存快照，交换文件在内存吃紧时兜底。它们随内存压力自动伸缩，重启后自然回收——把它们算进「可清理垃圾」是行业里常见的虚标，Xico 不这么做。",
            items: [item])
    }

    /// 已卸载应用残留：仅扫沙盒容器与窗口状态（按 bundle id 一一对应，误判极低）。
    /// 刻意不扫 Application Support —— 那里混有 Adobe dunamis 等"无独立 App 的框架组件"，
    /// 会被误判成残留，对清理器而言误删比漏删更致命。
    private func leftoversGroup(baseTotal: Int64, progress: @escaping ProgressHandler) -> (group: ScanResultGroup?, orphanContainerPaths: Set<String>) {
        let containersRoot = home.appendingPathComponent("Library/Containers")
        let roots = [containersRoot, home.appendingPathComponent("Library/Saved Application State")]
        var items: [CleanableItem] = []
        var orphanContainerPaths = Set<String>()
        var total = baseTotal
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
                total += size
                progress(ScanProgress(message: name, bytesFound: total))
            }
        }
        guard !items.isEmpty else { return (nil, orphanContainerPaths) }
        items.sort { $0.size > $1.size }
        let group = ScanResultGroup(id: "app-leftovers", title: "已卸载应用残留",
                               description: "已不在本机的应用遗留的支持文件。确认不再需要后再清理（移入废纸篓可恢复）。",
                               systemImage: "questionmark.folder", safety: .caution, items: items)
        return (group, orphanContainerPaths)
    }

    /// Docker/OrbStack 虚拟磁盘引导项：只陈述占用与「正确的瘦身方式」，永不勾选、永不代删。
    private func dockerGuidanceGroup() -> ScanResultGroup? {
        let candidates = [
            home.appendingPathComponent("Library/Containers/com.docker.docker/Data/vms/0/data/Docker.raw"),
            home.appendingPathComponent("Library/Containers/com.docker.docker/Data/vms/0/Docker.raw"),
            home.appendingPathComponent(".orbstack/data/data.img"),
        ]
        var items: [CleanableItem] = []
        for url in candidates where fs.exists(url) {
            let size = fs.allocatedSize(of: url)
            guard size > 1 << 30 else { continue }
            items.append(CleanableItem(url: url, displayName: url.lastPathComponent,
                                       detail: url.path, size: size, safety: .risky,
                                       note: "虚拟磁盘 · 请在终端运行 docker system prune 瘦身，勿直接删除",
                                       isInformational: true))
        }
        guard !items.isEmpty else { return nil }
        return ScanResultGroup(
            id: "docker-guidance", title: "容器虚拟磁盘（仅提示）",
            description: "Docker/OrbStack 的虚拟磁盘删除会毁掉全部容器与镜像。正确瘦身：docker system prune -a（清理未用镜像）。Xico 不代删。",
            systemImage: "shippingbox.circle", safety: .risky,
            explanation: "该文件是容器运行时的整块虚拟磁盘，内含你的全部镜像、容器与卷。直接删除等于卸载所有容器数据，因此 Xico 只提示体积、指路官方瘦身命令，绝不代删。",
            items: items)
    }

    static func darwinUserCacheURL() -> URL? {
        var buf = [CChar](repeating: 0, count: Int(PATH_MAX))
        let n = confstr(_CS_DARWIN_USER_CACHE_DIR, &buf, buf.count)
        guard n > 0 else { return nil }
        return URL(fileURLWithPath: xicoString(fromNullTerminated: buf), isDirectory: true)
    }

    /// /private/var/folders/.../T——系统分配的每用户临时目录（与 C 缓存目录同级）。
    static func darwinUserTempURL() -> URL? {
        var buf = [CChar](repeating: 0, count: Int(PATH_MAX))
        let n = confstr(_CS_DARWIN_USER_TEMP_DIR, &buf, buf.count)
        guard n > 0 else { return nil }
        return URL(fileURLWithPath: xicoString(fromNullTerminated: buf), isDirectory: true)
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
        // 应用扩展点的 bundle id 常与宿主 App 不同（如 com.x.OneDrive.FileProvider 宿主是 com.x.OneDrive-mac），
        // 易被误判为残留——一律豁免，避免误删活跃组件（误判比漏判更致命）。
        let extensionSuffixes = ["fileprovider", "findersync", "shareextension", "actionextension",
                                 "widget", "notificationservice", "intents", "intentsextension",
                                 "networkextension", "systemextension", "endpointsecurity",
                                 "quicklook", "spotlight", "xpc", "helper", "agent"]
        if extensionSuffixes.contains(where: { lower.hasSuffix("." + $0) }) { return false }
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
        await scanDefinitions(definitions, moduleID: .privacy, fs: fs, safety: safety, home: home, progress: progress)
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
    private let snapshotStore: ScanSnapshotStore?

    /// 用户可调阈值（P1）：`xico.largefiles.thresholdMB`，未设置默认 100MB。
    public static var configuredThreshold: Int64 {
        let mb = UserDefaults.standard.integer(forKey: "xico.largefiles.thresholdMB")
        return mb > 0 ? Int64(mb) * 1024 * 1024 : 100 * 1024 * 1024
    }
    /// 是否纳入外置卷（P1）：`xico.largefiles.externals`，默认关。
    public static var includeExternalVolumes: Bool {
        UserDefaults.standard.bool(forKey: "xico.largefiles.externals")
    }

    public init(fs: FileSystemService, safety: SafetyEngine,
                home: URL = FileManager.default.homeDirectoryForCurrentUser,
                thresholdBytes: Int64? = nil, maxItems: Int = 500,
                snapshotStore: ScanSnapshotStore? = nil) {
        self.fs = fs
        self.safety = safety
        self.home = home
        self.threshold = thresholdBytes ?? Self.configuredThreshold
        self.maxItems = maxItems
        self.snapshotStore = snapshotStore
    }

    /// 体量达标的大文件，附带「是否长期未使用」的年龄维度（回应模块名「大文件与旧文件」）。
    private struct ScoredFile: Sendable {
        let item: CleanableItem
        let stale: Bool
    }

    /// 长期未使用阈值：最后访问（回退到最后修改）超过此天数即视为「旧文件」。
    private static let staleInterval: TimeInterval = 180 * 86400

    private static func isStale(access: Date?, modified: Date?, now: Date) -> Bool {
        guard let last = access ?? modified else { return false }
        return now.timeIntervalSince(last) > staleInterval
    }

    public func scan(progress: @escaping ProgressHandler) async throws -> ScanResult {
        let roots = scanRoots()
        let counter = AtomicInt()
        let now = Date()
        let collection: (items: [ScoredFile], coverage: ScanCoverage?)
        if let snapshotStore {
            collection = await collectFromSharedIndex(roots: roots, store: snapshotStore,
                                                      now: now, counter: counter, progress: progress)
        } else {
            collection = await collectLegacy(roots: roots, now: now,
                                             counter: counter, progress: progress)
        }
        var scored = collection.items

        scored.sort { $0.item.size > $1.item.size }
        if scored.count > maxItems { scored = Array(scored.prefix(maxItems)) }

        // 双维度呈现：先单列「长期未使用 · >180 天」的旧文件（最值得优先释放），
        // 再按体量排行其余大文件——回应模块名「大文件与旧文件」对年龄维度的承诺。
        let staleItems = scored.filter(\.stale).map(\.item)
        let freshItems = scored.filter { !$0.stale }.map(\.item)
        var groups: [ScanResultGroup] = []
        if !staleItems.isEmpty {
            groups.append(ScanResultGroup(
                id: "large-old-files", title: xLoc("长期未使用 · >180 天"),
                description: "体量大且超过 180 天未打开的文件——最值得优先释放；删除前请确认，全部移入废纸篓可恢复。",
                systemImage: "clock.badge.xmark", safety: .caution, items: staleItems))
        }
        if !freshItems.isEmpty {
            groups.append(ScanResultGroup(
                id: "large-files", title: xLocF("大文件（≥ %@）", threshold.formattedBytes),
                description: "扫描下载、文稿、影片等用户目录；删除前请确认，全部移入废纸篓可恢复。",
                systemImage: "doc.viewfinder", safety: .caution, items: freshItems))
        }
        return ScanResult(moduleID: .largeFiles, groups: groups, coverage: collection.coverage)
    }

    private func collectFromSharedIndex(roots: [URL], store: ScanSnapshotStore, now: Date,
                                        counter: AtomicInt,
                                        progress: @escaping ProgressHandler) async
        -> (items: [ScoredFile], coverage: ScanCoverage?) {
        let homePath = home.standardizedFileURL.path
        let homeRoots = roots.filter { $0.standardizedFileURL.path.hasPrefix(homePath + "/") }
        let externalRoots = roots.filter { !$0.standardizedFileURL.path.hasPrefix(homePath + "/") }
        var snapshots = [await store.snapshot(for: home, progress: progress)]
        for root in externalRoots {
            snapshots.append(await store.snapshot(for: root, progress: progress))
        }

        var items: [ScoredFile] = []
        for snapshot in snapshots {
            for entry in snapshot.entries {
                if Task.isCancelled { break }
                if snapshot.root.standardizedFileURL.path == homePath {
                    let directHomeFile = entry.url.deletingLastPathComponent().standardizedFileURL.path == homePath
                    let inConfiguredRoot = homeRoots.contains {
                        let path = $0.standardizedFileURL.path
                        return entry.url.path == path || entry.url.path.hasPrefix(path + "/")
                    }
                    guard directHomeFile || inConfiguredRoot else { continue }
                }
                guard !entry.isHidden(relativeTo: snapshot.root),
                      !entry.isInsideRebuildableDirectory(relativeTo: snapshot.root),
                      entry.logicalBytes >= threshold,
                      safety.verify(entry.url, intent: .trash).isAllowed else { continue }
                let metadata = fs.entry(for: entry.url)
                let stale = Self.isStale(access: metadata?.accessDate,
                                         modified: metadata?.modificationDate, now: now)
                let allocated = entry.allocatedBytes > 0 ? entry.allocatedBytes : entry.logicalBytes
                items.append(ScoredFile(
                    item: makeItem(url: entry.url, allocated: allocated,
                                   reclaimable: entry.estimatedReclaimableBytes,
                                   stale: stale),
                    stale: stale
                ))
                let running = counter.add(entry.estimatedReclaimableBytes)
                progress(ScanProgress(message: entry.url.lastPathComponent, bytesFound: running,
                                      filesVisited: snapshot.coverage.filesVisited,
                                      directoriesVisited: snapshot.coverage.directoriesVisited,
                                      deniedDirectories: snapshot.coverage.deniedDirectories,
                                      elapsedSeconds: snapshot.coverage.elapsedSeconds))
            }
        }
        return (items, ScanCoverage.merged(snapshots.map(\.coverage)))
    }

    private func collectLegacy(roots: [URL], now: Date, counter: AtomicInt,
                               progress: @escaping ProgressHandler) async
        -> (items: [ScoredFile], coverage: ScanCoverage?) {
        let fs = self.fs
        let safety = self.safety
        let threshold = self.threshold
        let home = self.home
        let scored = await withTaskGroup(of: [ScoredFile].self) { group in
            for root in roots {
                group.addTask {
                    var local: [ScoredFile] = []
                    for await entry in fs.deepEnumerate(root, includeFiles: true) {
                        if Task.isCancelled { break }
                        guard !entry.isDirectory, entry.size >= threshold,
                              safety.verify(entry.url, intent: .trash).isAllowed else { continue }
                        let allocated = fs.entry(for: entry.url)?.size ?? entry.size
                        let stale = Self.isStale(access: entry.accessDate,
                                                 modified: entry.modificationDate, now: now)
                        local.append(ScoredFile(
                            item: self.makeItem(url: entry.url, allocated: allocated,
                                                reclaimable: allocated, stale: stale),
                            stale: stale))
                        let running = counter.add(allocated)
                        progress(ScanProgress(message: entry.url.lastPathComponent, bytesFound: running))
                    }
                    return local
                }
            }
            group.addTask {
                var local: [ScoredFile] = []
                for url in fs.contentsOfDirectory(home) {
                    if Task.isCancelled { break }
                    guard let entry = fs.entry(for: url), !entry.isDirectory,
                          entry.size >= threshold,
                          safety.verify(url, intent: .trash).isAllowed else { continue }
                    let stale = Self.isStale(access: entry.accessDate,
                                             modified: entry.modificationDate, now: now)
                    local.append(ScoredFile(
                        item: self.makeItem(url: url, allocated: entry.size,
                                            reclaimable: entry.size, stale: stale),
                        stale: stale))
                    let running = counter.add(entry.size)
                    progress(ScanProgress(message: url.lastPathComponent, bytesFound: running))
                }
                return local
            }
            var all: [ScoredFile] = []
            for await part in group { all += part }
            return all
        }
        return (scored, nil)
    }

    private func makeItem(url: URL, allocated: Int64, reclaimable: Int64,
                          stale: Bool) -> CleanableItem {
        var evidence = [ScanEvidence(code: "large-file-size", kind: .size,
                                     title: "文件超过大文件阈值",
                                     detail: "磁盘占用 \(allocated.formattedBytes)", strength: 1)]
        if stale {
            evidence.append(ScanEvidence(code: "last-used-180d", kind: .age,
                                         title: "超过 180 天未使用", strength: 0.9))
        }
        return CleanableItem(
            url: url, displayName: url.lastPathComponent, detail: url.path,
            size: allocated, safety: .caution, isSelected: false,
            note: stale ? "长期未使用 · 超过 180 天未打开" : nil,
            assessment: FindingAssessment(
                ruleID: stale ? "large-old-file" : "large-file",
                confidence: stale ? 0.9 : 0.75,
                evidence: evidence,
                reclaimableBytes: reclaimable,
                recovery: .trash,
                regenerationCost: .high,
                impact: "个人文件；删除前必须人工确认"
            )
        )
    }

    /// 用户内容目录 + ~/Library（大文件常藏在 Containers/Application Support/iOS 备份里）。
    /// deepEnumerate 会剪掉 node_modules/DerivedData 等海量小文件目录，故纳入 Library 不至于拖垮。
    /// P1：可选纳入外置卷（`xico.largefiles.externals`）。
    private func scanRoots() -> [URL] {
        let skipDot = true
        var roots = fs.contentsOfDirectory(home).filter { url in
            let name = url.lastPathComponent
            guard !(skipDot && name.hasPrefix(".")), name != "Library" else { return false }
            return (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
        }
        roots.append(home.appendingPathComponent("Library"))
        if Self.includeExternalVolumes {
            let keys: [URLResourceKey] = [.volumeIsInternalKey]
            let mounted = FileManager.default.mountedVolumeURLs(
                includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
            for vol in mounted {
                let isInternal = (try? vol.resourceValues(forKeys: [.volumeIsInternalKey]))?.volumeIsInternal ?? true
                if !isInternal { roots.append(vol) }
            }
        }
        return roots
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
        var items: [CleanableItem] = []
        var total: Int64 = 0
        // 主废纸篓 + 各外置/网络卷的 .Trashes/<uid>（此前只扫家目录 .Trash，外置卷全漏）
        let locations = trashLocations()
        for trash in locations {
            for url in fs.contentsOfDirectory(trash) {
                if Task.isCancelled { break }
                let size = fs.allocatedSize(of: url)
                items.append(CleanableItem(url: url, displayName: url.lastPathComponent,
                                           detail: url.path, size: size, safety: .safe,
                                           assessment: FindingAssessment(
                                            ruleID: "trash-content",
                                            confidence: 0.99,
                                            evidence: [
                                                ScanEvidence(code: "system-trash-location",
                                                             kind: .userLocation,
                                                             title: "项目位于 macOS 废纸篓", strength: 1),
                                                ScanEvidence(code: "permanent-delete-confirmation",
                                                             kind: .safetyPolicy,
                                                             title: "清空前必须再次确认", strength: 1)
                                            ],
                                            reclaimableBytes: size,
                                            recovery: .none,
                                            regenerationCost: .unknown,
                                            impact: "清空废纸篓后不可恢复"
                                           )))
                total += size
                progress(ScanProgress(message: url.lastPathComponent, bytesFound: total))
            }
        }
        items.sort { $0.size > $1.size }
        let group = ScanResultGroup(id: "trash", title: "废纸篓内容",
                                    description: "清空将彻底删除这些项目（不可恢复）。含外置卷废纸篓。",
                                    systemImage: "trash.circle", safety: .safe, items: items)
        let coverage = ScanCoverage(
            roots: locations.map(\.path),
            filesVisited: items.count,
            directoriesVisited: locations.count,
            bytesInspected: total,
            hiddenFilesIncluded: true,
            cancelled: Task.isCancelled)
        return ScanResult(moduleID: .trash, groups: items.isEmpty ? [] : [group], coverage: coverage)
    }

    private func trashLocations() -> [URL] {
        var locations = [home.appendingPathComponent(".Trash")]
        let uid = getuid()
        let keys: [URLResourceKey] = [.volumeIsInternalKey]
        let mounted = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        for vol in mounted {
            // 跳过系统盘（其废纸篓即家目录 .Trash，已含）；只补外置/其它卷
            let isInternal = (try? vol.resourceValues(forKeys: [.volumeIsInternalKey]))?.volumeIsInternal ?? true
            if isInternal { continue }
            let volTrash = vol.appendingPathComponent(".Trashes/\(uid)")
            if fs.exists(volTrash) { locations.append(volTrash) }
        }
        return locations
    }
}

// MARK: - 深度全盘扫描器（智能扫描的「全面检测」层）
//
// 与定点清理不同：这里对整个用户目录做真实逐文件走查（复用 deepEnumerate，
// node_modules / Pods / DerivedData 等海量小文件目录仅为扫描提速而剪枝——
// 它们并非可清理物，也未被任何系统垃圾定义覆盖，只是跳过不深入），路上识别两类
// 「定点规则覆盖不到、但人人都有」的可清理物：
//   1. 残留安装包：.dmg/.pkg/.xip/.iso——装完即弃，30 天未动默认勾选；
//   2. 中断的下载：.crdownload/.part/.partial/.download——续传会重新开始，残块无用。
// 走查过程实时上报「已走查 N 个文件」，扫描的覆盖面对用户可见。

public struct DeepScanner: ScannerModule {
    public let metadata = ModuleMetadata(
        id: .deepScan, title: "深度扫描", subtitle: "全盘走查：残留安装包 / 中断下载",
        systemImage: "binoculars", category: .cleanup)

    private let fs: FileSystemService
    private let safety: SafetyEngine
    private let home: URL
    private let snapshotStore: ScanSnapshotStore?

    private static let installerExts: Set<String> = ["dmg", "pkg", "mpkg", "xip", "iso"]
    private static let partialExts: Set<String> = ["crdownload", "part", "partial", "download"]

    public init(fs: FileSystemService, safety: SafetyEngine,
                home: URL = FileManager.default.homeDirectoryForCurrentUser,
                snapshotStore: ScanSnapshotStore? = nil) {
        self.fs = fs
        self.safety = safety
        self.home = home
        self.snapshotStore = snapshotStore
    }

    public func scan(progress: @escaping ProgressHandler) async throws -> ScanResult {
        if let snapshotStore {
            let snapshot = await snapshotStore.snapshot(for: home, progress: progress)
            return scan(snapshot: snapshot, progress: progress)
        }
        var installers: [CleanableItem] = []
        var partials: [CleanableItem] = []
        var zombies: [CleanableItem] = []
        var filesScanned = 0
        var bytesFound: Int64 = 0
        let now = Date()

        for await entry in fs.deepEnumerate(home, includeFiles: true) {
            if Task.isCancelled { break }
            let ext = entry.url.pathExtension.lowercased()

            // 僵尸 node_modules（P2，CMM/柠檬都没有）：项目 90 天没动过的依赖树——
            // 重跑 `npm install` 即可完整重建，是开发者机器上最肥的「隐形垃圾」。
            // deepEnumerate 先产出该目录再剪枝，正好在此拦截；体量 ≥50MB 才列。
            if entry.isDirectory, entry.url.lastPathComponent == "node_modules" {
                let projectDir = entry.url.deletingLastPathComponent()
                let projectMtime = fs.entry(for: projectDir)?.modificationDate ?? entry.modificationDate ?? now
                let stale = now.timeIntervalSince(projectMtime) > 90 * 86400
                if stale, safety.verify(entry.url, intent: .trash).isAllowed {
                    let size = fs.allocatedSize(of: entry.url)
                    if size >= 50 << 20 {
                        zombies.append(CleanableItem(
                            url: entry.url, displayName: projectDir.lastPathComponent + "/node_modules",
                            detail: entry.url.path, size: size,
                            safety: .caution, isSelected: false,
                            note: "项目超过 90 天未动 · npm install 可完整重建"))
                        bytesFound += size
                        progress(ScanProgress(message: entry.url.lastPathComponent, bytesFound: bytesFound))
                    }
                }
                continue
            }

            // Safari 的 .download 是目录包——目录也要看扩展名，其余目录跳过
            if entry.isDirectory && ext != "download" { continue }

            filesScanned += 1
            if filesScanned % 1500 == 0 {
                progress(ScanProgress(message: xLocF("已走查 %@ 个文件", Self.countText(filesScanned)),
                                      bytesFound: bytesFound))
            }

            if Self.installerExts.contains(ext), !entry.isDirectory {
                guard entry.size > 512 * 1024 else { continue }   // 碎渣不值得列
                guard safety.verify(entry.url, intent: .trash).isAllowed else { continue }
                let age = now.timeIntervalSince(entry.modificationDate ?? entry.accessDate ?? now)
                let stale = age > 30 * 86400
                let size = fs.entry(for: entry.url)?.size ?? entry.size
                // 默认不自动勾选（P0 勾选纪律）：安装包是用户下载的文件，可能要留档/分发，
                // 「>30 天就勾」过于激进——对齐 CleanMyMac 的安全姿态，把决定权交回用户。
                installers.append(CleanableItem(
                    url: entry.url, displayName: entry.url.lastPathComponent,
                    detail: entry.url.path, size: size,
                    safety: stale ? .safe : .caution, isSelected: false,
                    note: stale ? "安装包 · 超过 30 天未动，装完即可删" : "安装包 · 装完即可删"))
                bytesFound += size
                progress(ScanProgress(message: entry.url.lastPathComponent, bytesFound: bytesFound))
            } else if Self.partialExts.contains(ext) {
                guard safety.verify(entry.url, intent: .trash).isAllowed else { continue }
                let age = now.timeIntervalSince(entry.modificationDate ?? now)
                guard age > 7 * 86400 else { continue }   // 一周内的可能还在续传
                let size = max(fs.allocatedSize(of: entry.url), 1)
                partials.append(CleanableItem(
                    url: entry.url, displayName: entry.url.lastPathComponent,
                    detail: entry.url.path, size: size,
                    safety: .safe, isSelected: true,
                    note: "中断的下载残块"))
                bytesFound += size
                progress(ScanProgress(message: entry.url.lastPathComponent, bytesFound: bytesFound))
            }
        }
        progress(ScanProgress(message: xLocF("已走查 %@ 个文件", Self.countText(filesScanned)),
                              bytesFound: bytesFound))

        installers.sort { $0.size > $1.size }
        partials.sort { $0.size > $1.size }
        var groups: [ScanResultGroup] = []
        if !installers.isEmpty {
            groups.append(ScanResultGroup(
                id: "leftover-installers", title: "残留安装包",
                description: "安装完成后 .dmg / .pkg 就完成了使命；超过 30 天未动的默认勾选，移入废纸篓可恢复。",
                systemImage: "shippingbox", safety: .safe, items: installers))
        }
        if !partials.isEmpty {
            groups.append(ScanResultGroup(
                id: "partial-downloads", title: "中断的下载",
                description: "下载中断留下的残块（.crdownload / .part / .download），续传会重新开始，可安全清理。",
                systemImage: "icloud.and.arrow.down", safety: .safe, items: partials))
        }
        if !zombies.isEmpty {
            zombies.sort { $0.size > $1.size }
            groups.append(ScanResultGroup(
                id: "zombie-node-modules", title: "僵尸依赖（node_modules）",
                description: "超过 90 天未动的项目的依赖树。重跑 npm/yarn/pnpm install 即可完整重建；默认不勾选。",
                systemImage: "shippingbox.and.arrow.backward", safety: .caution,
                explanation: "node_modules 是 npm 生态的本地依赖副本，完全由 package.json 派生——删除后在项目里重跑一次安装命令即可恢复。只列出项目本身长期未动的（90 天），活跃项目不打扰。",
                items: zombies))
        }
        return ScanResult(moduleID: .deepScan, groups: groups)
    }

    /// 智能扫描复用共享快照，仅对少量候选补读修改时间，避免再次遍历整个家目录。
    private func scan(snapshot: ScanSnapshot, progress: @escaping ProgressHandler) -> ScanResult {
        var installers: [CleanableItem] = []
        var partials: [CleanableItem] = []
        var nodeModules: [URL: (allocated: Int64, reclaimable: Int64)] = [:]
        var downloadPackages: [URL: (allocated: Int64, reclaimable: Int64)] = [:]
        let now = Date()

        for (index, entry) in snapshot.entries.enumerated() {
            if Task.isCancelled { break }
            if let package = Self.ancestor(named: "node_modules", of: entry.url, below: home) {
                let old = nodeModules[package] ?? (0, 0)
                nodeModules[package] = (old.allocated + entry.allocatedBytes,
                                        old.reclaimable + entry.estimatedReclaimableBytes)
                continue
            }
            if let package = Self.ancestor(withExtension: "download", of: entry.url, below: home) {
                let old = downloadPackages[package] ?? (0, 0)
                downloadPackages[package] = (old.allocated + entry.allocatedBytes,
                                              old.reclaimable + entry.estimatedReclaimableBytes)
                continue
            }
            guard !entry.isInsideRebuildableDirectory(relativeTo: home) else { continue }

            let ext = entry.url.pathExtension.lowercased()
            if Self.installerExts.contains(ext), entry.logicalBytes > 512 * 1024,
               safety.verify(entry.url, intent: .trash).isAllowed {
                let metadata = fs.entry(for: entry.url)
                let age = now.timeIntervalSince(metadata?.modificationDate ?? metadata?.accessDate ?? now)
                let stale = age > 30 * 86400
                installers.append(CleanableItem(
                    url: entry.url, displayName: entry.url.lastPathComponent,
                    detail: entry.url.path, size: entry.allocatedBytes,
                    safety: stale ? .safe : .caution, isSelected: false,
                    note: stale ? "安装包 · 超过 30 天未动，装完即可删" : "安装包 · 装完即可删",
                    assessment: FindingAssessment(
                        ruleID: "leftover-installer", confidence: stale ? 0.9 : 0.7,
                        evidence: [
                            ScanEvidence(code: "installer-extension", kind: .applicationState,
                                         title: "识别为 macOS 安装介质", detail: ".\(ext)", strength: 0.9),
                            ScanEvidence(code: "installer-location", kind: .userLocation,
                                         title: "位于用户文件范围",
                                         detail: entry.url.deletingLastPathComponent().path, strength: 0.8),
                            ScanEvidence(code: "installer-age", kind: .age,
                                         title: stale ? "超过 30 天未修改" : "近期仍有修改",
                                         strength: stale ? 0.9 : 0.5)
                        ], reclaimableBytes: entry.estimatedReclaimableBytes,
                        recovery: .trash, regenerationCost: .high,
                        impact: "可能是用户保留的安装归档，始终需要人工确认")))
            } else if Self.partialExts.contains(ext),
                      safety.verify(entry.url, intent: .trash).isAllowed {
                let modified = fs.entry(for: entry.url)?.modificationDate ?? now
                guard now.timeIntervalSince(modified) > 7 * 86400 else { continue }
                partials.append(makePartialItem(
                    url: entry.url, allocated: max(entry.allocatedBytes, 1),
                    reclaimable: entry.estimatedReclaimableBytes,
                    detail: "下载残块超过 7 天未修改"))
            }
            if (index + 1).isMultiple(of: 1_500) {
                progress(ScanProgress(
                    message: xLocF("已走查 %@ 个文件", Self.countText(index + 1)),
                    filesVisited: index + 1,
                    elapsedSeconds: snapshot.coverage.elapsedSeconds))
            }
        }

        var zombies: [CleanableItem] = []
        for (url, sizes) in nodeModules where sizes.allocated >= 50 << 20 {
            let projectDir = url.deletingLastPathComponent()
            let modified = fs.entry(for: projectDir)?.modificationDate ?? now
            guard now.timeIntervalSince(modified) > 90 * 86400,
                  safety.verify(url, intent: .trash).isAllowed else { continue }
            zombies.append(CleanableItem(
                url: url, displayName: projectDir.lastPathComponent + "/node_modules",
                detail: url.path, size: sizes.allocated, safety: .caution,
                isSelected: false, note: "项目超过 90 天未动 · npm install 可完整重建",
                assessment: FindingAssessment(
                    ruleID: "zombie-node-modules", confidence: 0.92,
                    evidence: [
                        ScanEvidence(code: "node-modules-regenerable", kind: .regenerable,
                                     title: "依赖可由包管理器重建", strength: 0.98),
                        ScanEvidence(code: "project-age-90d", kind: .age,
                                     title: "项目超过 90 天未修改", strength: 0.9)
                    ], reclaimableBytes: sizes.reclaimable, recovery: .regenerate,
                    regenerationCost: .medium, impact: "下次开发前需要重新安装依赖")))
        }
        for (url, sizes) in downloadPackages {
            let modified = fs.entry(for: url)?.modificationDate ?? now
            guard now.timeIntervalSince(modified) > 7 * 86400,
                  safety.verify(url, intent: .trash).isAllowed else { continue }
            partials.append(makePartialItem(
                url: url, allocated: max(sizes.allocated, 1), reclaimable: sizes.reclaimable,
                detail: "Safari 下载包超过 7 天未修改"))
        }

        let bytesFound = installers.reduce(0) { $0 + $1.estimatedReclaimableBytes }
            + partials.reduce(0) { $0 + $1.estimatedReclaimableBytes }
            + zombies.reduce(0) { $0 + $1.estimatedReclaimableBytes }
        progress(ScanProgress(
            message: xLocF("已走查 %@ 个文件", Self.countText(snapshot.entries.count)),
            bytesFound: bytesFound, filesVisited: snapshot.entries.count,
            directoriesVisited: snapshot.coverage.directoriesVisited,
            deniedDirectories: snapshot.coverage.deniedDirectories,
            elapsedSeconds: snapshot.coverage.elapsedSeconds))

        installers.sort { $0.estimatedReclaimableBytes > $1.estimatedReclaimableBytes }
        partials.sort { $0.estimatedReclaimableBytes > $1.estimatedReclaimableBytes }
        zombies.sort { $0.estimatedReclaimableBytes > $1.estimatedReclaimableBytes }
        var groups: [ScanResultGroup] = []
        if !installers.isEmpty {
            groups.append(ScanResultGroup(
                id: "leftover-installers", title: "残留安装包",
                description: "安装完成后的 .dmg / .pkg 等安装介质；始终由你确认后再移入废纸篓。",
                systemImage: "shippingbox", safety: .caution, items: installers))
        }
        if !partials.isEmpty {
            groups.append(ScanResultGroup(
                id: "partial-downloads", title: "中断的下载",
                description: "超过 7 天未修改的下载残块，可移入废纸篓并重新下载。",
                systemImage: "icloud.and.arrow.down", safety: .safe, items: partials))
        }
        if !zombies.isEmpty {
            groups.append(ScanResultGroup(
                id: "zombie-node-modules", title: "僵尸依赖（node_modules）",
                description: "超过 90 天未动的项目依赖树，可由 npm/yarn/pnpm 重建；默认不勾选。",
                systemImage: "shippingbox.and.arrow.backward", safety: .caution,
                explanation: "node_modules 是包管理器生成的依赖副本。删除后需重新安装依赖。",
                items: zombies))
        }
        return ScanResult(moduleID: .deepScan, groups: groups, coverage: snapshot.coverage)
    }

    private func makePartialItem(url: URL, allocated: Int64, reclaimable: Int64,
                                 detail: String) -> CleanableItem {
        CleanableItem(
            url: url, displayName: url.lastPathComponent, detail: url.path,
            size: allocated, safety: .safe, note: "中断的下载残块",
            assessment: FindingAssessment(
                ruleID: "stale-partial-download", confidence: 0.98,
                evidence: [
                    ScanEvidence(code: "partial-download-state", kind: .applicationState,
                                 title: "下载未完成", detail: detail, strength: 0.98),
                    ScanEvidence(code: "partial-download-age", kind: .age,
                                 title: "超过 7 天未修改", strength: 0.95)
                ], reclaimableBytes: reclaimable, recovery: .redownload,
                regenerationCost: .low, impact: "需要时可重新下载"))
    }

    private static func ancestor(named name: String, of url: URL, below root: URL) -> URL? {
        ancestor(of: url, below: root) { $0 == name }
    }

    private static func ancestor(withExtension ext: String, of url: URL, below root: URL) -> URL? {
        ancestor(of: url, below: root) {
            URL(fileURLWithPath: $0).pathExtension.lowercased() == ext
        }
    }

    private static func ancestor(of url: URL, below root: URL,
                                 matching predicate: (String) -> Bool) -> URL? {
        let rootComponents = root.standardizedFileURL.pathComponents
        let components = url.standardizedFileURL.pathComponents
        guard components.starts(with: rootComponents), components.count > rootComponents.count else { return nil }
        for index in rootComponents.count..<(components.count - 1) where predicate(components[index]) {
            return URL(fileURLWithPath: NSString.path(withComponents: Array(components[...index])),
                       isDirectory: true)
        }
        return nil
    }

    /// 千分位计数（不依赖 locale 的稳定输出）。
    private static func countText(_ n: Int) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        return f.string(from: NSNumber(value: n)) ?? "\(n)"
    }
}
