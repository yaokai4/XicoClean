import Foundation
import AppKit
import Domain

// MARK: - 孤儿残留引擎（docs/14 P4 · 对标 Nektony Remaining Files 最佳实践）
// 已卸载应用的残留检测：bundle-id 比对已装应用集合，**按原应用分组**展示（决策成本最低），
// 与卸载器共用同一套 by-bundleID 关联路径口径（UninstallerService.uninstallTargets 的镜像）。
//
// Fail-closed 三道闸（误删比漏删更致命）：
//   1. `SystemJunkScanner.isOrphanBundleID`——系统前缀白名单 + 扩展点后缀豁免 + 逐级父 id
//      查 LaunchServices（宿主 App 还在就不算残留）；
//   2. **厂商前缀闸**：本机装着任何 com.adobe.* 应用，就跳过全部 com.adobe.* 候选——
//      堵住「无独立 App 的共享框架组件」（如 Adobe dunamis）被误判的整类漏洞
//      （Scanners.swift 旧注对 Application Support 的担忧由此闸解除）；
//   3. 每条路径仍过 SafetyEngine verify（红线规则库）。

public struct OrphanScanner: ScannerModule {
    public let metadata = ModuleMetadata(
        id: .orphans, title: "已卸载应用残留", subtitle: "按原应用分组",
        systemImage: "questionmark.folder", category: .cleanup, sidebar: false)

    private let fs: FileSystemService
    private let safety: SafetyEngine
    private let home: URL

    public init(fs: FileSystemService, safety: SafetyEngine,
                home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.fs = fs
        self.safety = safety
        self.home = home
    }

    /// 发现根：名字即 bundle-id（或其变体）的五个标准位置。
    /// Application Support 刻意**不作发现根**（框架组件重灾区），只在已证实孤儿的扩展定位里做精确匹配。
    private var discoveryRoots: [(URL, (String) -> String?)] {
        let lib = home.appendingPathComponent("Library")
        return [
            (lib.appendingPathComponent("Caches"), { $0 }),
            (lib.appendingPathComponent("Preferences"), { $0.hasSuffix(".plist") ? String($0.dropLast(6)) : nil }),
            (lib.appendingPathComponent("Containers"), { $0 }),
            (lib.appendingPathComponent("Saved Application State"),
             { $0.hasSuffix(".savedState") ? String($0.dropLast(11)) : nil }),
            (lib.appendingPathComponent("LaunchAgents"), { $0.hasSuffix(".plist") ? String($0.dropLast(6)) : nil }),
        ]
    }

    public func scan(progress: @escaping ProgressHandler) async throws -> ScanResult {
        // 已装集合（bundle id + 厂商前缀）——卸载器同一枚举口径 + 运行中应用兜底。
        let installed = UninstallerService(fs: fs, safety: safety, home: home).listApps()
        var installedIDs = Set(installed.map { $0.bundleID.lowercased() })
        let runningIDs: Set<String> = await MainActor.run {
            Set(NSWorkspace.shared.runningApplications.compactMap { $0.bundleIdentifier?.lowercased() })
        }
        installedIDs.formUnion(runningIDs)
        let installedVendors = Set(installedIDs.compactMap { vendorPrefix($0) })

        // 一趟发现：候选 bundle id（结论按 id 缓存，NSWorkspace 逐级父查询只做一次）。
        var verdicts: [String: Bool] = [:]
        var orphanIDs: [String] = []
        for (root, extract) in discoveryRoots {
            if Task.isCancelled { break }
            for url in fs.contentsOfDirectory(root) {
                guard let bid = extract(url.lastPathComponent), looksLikeBundleID(bid) else { continue }
                let key = bid.lowercased()
                if let known = verdicts[key] {
                    if known, !orphanIDs.contains(key) { orphanIDs.append(key) }
                    continue
                }
                let orphan = !installedIDs.contains(key)
                    && !(vendorPrefix(key).map { installedVendors.contains($0) } ?? false)
                    && SystemJunkScanner.isOrphanBundleID(bid)
                verdicts[key] = orphan
                if orphan { orphanIDs.append(key) }
            }
        }

        // 二趟扩展：每个孤儿 id 展开全部关联位置（与卸载器 by-bundleID 口径一致），按原应用分组。
        var groups: [ScanResultGroup] = []
        var runningTotal: Int64 = 0
        for bid in orphanIDs {
            if Task.isCancelled { break }
            var items: [CleanableItem] = []
            for url in Self.artifactURLs(for: bid, home: home, fs: fs) {
                guard safety.verify(url, intent: .trash).isAllowed else { continue }
                let size = fs.allocatedSize(of: url)
                guard size > 0 else { continue }
                items.append(CleanableItem(url: url, displayName: url.lastPathComponent,
                                           detail: url.path, size: size, safety: .caution,
                                           note: "已卸载应用残留"))
                runningTotal += size
                progress(ScanProgress(message: url.lastPathComponent, bytesFound: runningTotal))
            }
            guard !items.isEmpty else { continue }
            items.sort { $0.size > $1.size }
            groups.append(ScanResultGroup(
                id: "orphan-\(bid)",
                title: displayName(for: bid),
                description: "已不在本机的应用遗留的支持文件（缓存 / 偏好 / 容器 / 启动项）。确认不再需要后再清理，移入废纸篓可恢复。",
                systemImage: "questionmark.folder", safety: .caution, items: items))
        }
        groups.sort { $0.totalSize > $1.totalSize }
        return ScanResult(moduleID: .orphans, groups: groups)
    }

    /// 某 bundle id 的全部标准关联位置（存在的才返回）。与 UninstallerService.uninstallTargets
    /// 的 by-bundleID 清单同口径——卸载器与孤儿引擎一个脑子，废纸篓哨兵也复用此函数。
    public static func artifactURLs(for bundleID: String, home: URL, fs: FileSystemService) -> [URL] {
        guard UninstallerService.isValidPathToken(bundleID) else { return [] }
        let lib = home.appendingPathComponent("Library")
        var urls: [URL] = [
            lib.appendingPathComponent("Application Support/\(bundleID)"),
            lib.appendingPathComponent("Caches/\(bundleID)"),
            lib.appendingPathComponent("Preferences/\(bundleID).plist"),
            lib.appendingPathComponent("Containers/\(bundleID)"),
            lib.appendingPathComponent("Saved Application State/\(bundleID).savedState"),
            lib.appendingPathComponent("Logs/\(bundleID)"),
            lib.appendingPathComponent("HTTPStorages/\(bundleID)"),
            lib.appendingPathComponent("WebKit/\(bundleID)"),
        ].filter { fs.exists($0) }
        // 模糊位置（文件名包含 bundle id）：Group Containers / LaunchAgents。
        for dirName in ["Group Containers", "LaunchAgents"] {
            let dir = lib.appendingPathComponent(dirName)
            for url in fs.contentsOfDirectory(dir)
            where url.lastPathComponent.localizedCaseInsensitiveContains(bundleID) {
                urls.append(url)
            }
        }
        return urls
    }

    /// 形如 reverse-DNS（≥3 段、无空格）才进入候选。
    private func looksLikeBundleID(_ name: String) -> Bool {
        !name.contains(" ") && name.split(separator: ".").count >= 3
    }

    /// 厂商前缀（前两段，如 com.adobe）；不足两段返回 nil。
    private func vendorPrefix(_ bid: String) -> String? {
        let parts = bid.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        return parts.prefix(2).joined(separator: ".").lowercased()
    }

    /// 从 bundle id 推断展示名：先查 FriendlyName 表，兜底取末段首字母大写。
    /// 专有名词经 xLoc 原样透传（缺键回落键本身），不破坏 i18n。
    private func displayName(for bid: String) -> String {
        let friendly = FriendlyName.resolve(bid)
        if friendly != bid { return friendly }
        let last = bid.split(separator: ".").last.map(String.init) ?? bid
        return last.prefix(1).uppercased() + last.dropFirst()
    }
}
