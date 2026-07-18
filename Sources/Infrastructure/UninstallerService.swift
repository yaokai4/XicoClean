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
    private let entitlementReader: any EntitlementReader
    private let launchAgentReader: any LaunchAgentReader

    public init(fs: FileSystemService, safety: SafetyEngine,
                home: URL = FileManager.default.homeDirectoryForCurrentUser,
                entitlementReader: any EntitlementReader = CodesignEntitlementReader(),
                launchAgentReader: any LaunchAgentReader = PlistLaunchAgentReader()) {
        self.fs = fs
        self.safety = safety
        self.home = home
        self.entitlementReader = entitlementReader
        self.launchAgentReader = launchAgentReader
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
                // A missing identifier proves no ownership. Never turn the app's URL path into
                // an attribution token: doing so can construct unrelated Library targets.
                let bundleID = bundle?.bundleIdentifier ?? ""
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

    /// Compatibility projection for the current UI. Task 4's mode-aware candidate API below is
    /// the source of truth; execution/result consumption is intentionally left to Task 5.
    public func uninstallTargets(for app: InstalledApp) -> [CleanableItem] {
        (try? uninstallTargets(for: app, mode: .uninstallApp).map(\.item)) ?? []
    }

    /// Builds attributed, policy-bearing candidates without mutating the filesystem.
    public func uninstallTargets(for app: InstalledApp,
                                 mode: UninstallMode) throws -> [UninstallCandidate] {
        if mode == .cleanLeftovers, fs.exists(app.url) {
            throw UninstallerAttributionError.appStillPresent
        }

        var items: [UninstallCandidate] = []
        var seen = Set<String>()

        func add(_ url: URL,
                 safety level: SafetyLevel,
                 evidence: OwnershipEvidence,
                 policy: SelectionPolicy) {
            // 深度断言：关联文件至少要落在 `~/Library/<类别>/<具体项>`（≥6 分量）之下，
            // 绝不允许目标是 `~/Library/<类别>` 这一级本身（红线亦会拦，此为第一道闸）。
            let underLibrary = url.path.hasPrefix(home.appendingPathComponent("Library").path + "/")
            if underLibrary && url.pathComponents.count < 6 { return }
            guard !seen.contains(url.path), fs.exists(url),
                  safety.verify(url, intent: .trash).isAllowed else { return }
            seen.insert(url.path)
            let size = fs.allocatedSize(of: url)
            let cleanable = CleanableItem(url: url, displayName: url.lastPathComponent,
                                          detail: url.path, size: size, safety: level,
                                          isSelected: policy.defaultSelected)
            items.append(UninstallCandidate(item: cleanable, evidence: evidence,
                                            selectionPolicy: policy))
        }

        let parsedBundleID = BundleIdentifier(rawValue: app.bundleID)

        // App body is mandatory only for a normal uninstall. A missing/malformed bundle ID is
        // not inferred from a Library path; the direct app selection makes it required while
        // avoiding a false exact-path attribution claim.
        if mode == .uninstallApp {
            add(app.url, safety: .safe, evidence: .unverified, policy: .required)
        }

        let lib = home.appendingPathComponent("Library")
        let name = app.name
        let nameOK = Self.isValidPathToken(name)

        // The eight exact bundle-ID locations are the only bundle-derived recommended paths.
        if let parsedBundleID {
            let bid = parsedBundleID.rawValue
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
            for url in byBID {
                add(url, safety: .caution, evidence: .exactBundleIDPath, policy: .recommended)
            }

            // Group containers are ownership candidates only when their exact directory names
            // occur in the signed app's application-groups entitlement. Substring matching is
            // forbidden because it can attribute another app's shared container.
            if let groups = entitlementReader.applicationGroups(for: app.url) {
                let entitledGroups = Set(groups.filter(Self.isValidPathComponent))
                let groupDirectory = lib.appendingPathComponent("Group Containers")
                for url in fs.contentsOfDirectory(groupDirectory)
                where entitledGroups.contains(url.lastPathComponent) {
                    add(url, safety: .caution, evidence: .signedApplicationGroup, policy: .manualOnly)
                }
            }

            // Launch-agent ownership requires both an exact Label and an executable whose
            // standardized path is strictly inside this app bundle. Exact-label agents with an
            // external program remain visible but blocked; containing labels prove nothing.
            let launchAgentsDirectory = lib.appendingPathComponent("LaunchAgents")
            for url in fs.contentsOfDirectory(launchAgentsDirectory) {
                guard let record = launchAgentReader.launchAgent(at: url),
                      record.label == bid else { continue }
                if let program = record.executablePath,
                   Self.isProgram(program, inside: app.url) {
                    add(url, safety: .caution, evidence: .launchAgentProgramInsideBundle,
                        policy: .recommended)
                } else {
                    add(url, safety: .caution, evidence: .unverified, policy: .blocked)
                }
            }
        }

        // 按显示名定位（易与共享 vendor 目录碰撞，如 Firefox 含书签/密码）——默认**不勾选**，
        // 需用户主动确认，避免"卸载 App A 顺手删掉同厂商 App B 的数据"。
        if nameOK {
            add(lib.appendingPathComponent("Application Support/\(name)"), safety: .caution,
                evidence: .displayNameHeuristic, policy: .manualOnly)
        }

        return items
    }

    /// Hands selected Task 4 candidates to Task 1's immutable capability preparation boundary.
    /// Authorization and execution are deliberately not part of this task.
    public func prepareUninstallPlan(from candidates: [UninstallCandidate],
                                     using issuer: DestructiveOperationIssuer,
                                     now: Date = Date()) -> DestructivePlan {
        issuer.prepare(kind: .uninstall,
                       targets: candidates.filter(\.isSelected).map(\.targetRequest),
                       now: now)
    }

    private static func isValidPathComponent(_ value: String) -> Bool {
        !value.isEmpty && value != "." && value != ".."
            && !value.contains("/") && !value.contains("\\")
    }

    private static func isProgram(_ path: String, inside appURL: URL) -> Bool {
        guard path.hasPrefix("/") else { return false }
        let program = canonicalComparisonPath(path)
        let bundle = canonicalComparisonPath(appURL.path)
        return program != bundle && program.hasPrefix(bundle + "/")
    }

    private static func canonicalComparisonPath(_ path: String) -> String {
        let standardized = (path as NSString).standardizingPath
        // macOS exposes /var through the /private/var symlink. Foundation may preserve either
        // spelling across URL APIs; normalize that system alias before the component boundary test.
        return standardized.hasPrefix("/private/var/")
            ? String(standardized.dropFirst("/private".count))
            : standardized
    }
}
