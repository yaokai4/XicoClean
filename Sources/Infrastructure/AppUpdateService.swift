import Foundation

public struct AppUpdateCandidate: Identifiable, Sendable {
    public var id: String { bundleID }
    public let name: String
    public let bundleID: String
    public let url: URL
    public let currentVersion: String
    public let feedURL: URL?
    public var latestVersion: String?     // 检查后填入
    public var downloadURL: URL?
    public var hasUpdate: Bool { latestVersion != nil }
}

/// 应用更新器：枚举 /Applications 中带 Sparkle 自更新源（SUFeedURL）的第三方应用，
/// 拉取各自 appcast 比对版本，列出可更新项并提供下载入口。
/// 覆盖面对齐 CleanMyMac 的 Updater（限具备 Sparkle 源的应用；App Store 应用由系统更新）。
public struct AppUpdateService: Sendable {
    private let uninstaller: UninstallerService
    private let session: URLSession

    public init(uninstaller: UninstallerService, session: URLSession = .shared) {
        self.uninstaller = uninstaller
        self.session = session
    }

    /// 列出带 Sparkle 更新源的已安装应用（不联网）。
    public func candidates() -> [AppUpdateCandidate] {
        uninstaller.listApps().compactMap { app in
            guard let bundle = Bundle(url: app.url) else { return nil }
            let version = (bundle.infoDictionary?["CFBundleShortVersionString"] as? String)
                ?? (bundle.infoDictionary?["CFBundleVersion"] as? String) ?? "—"
            let feed = (bundle.object(forInfoDictionaryKey: "SUFeedURL") as? String).flatMap(URL.init(string:))
            guard feed != nil else { return nil }   // 只列可自更新的应用
            return AppUpdateCandidate(name: app.name, bundleID: app.bundleID, url: app.url,
                                      currentVersion: version, feedURL: feed,
                                      latestVersion: nil, downloadURL: nil)
        }
    }

    /// 并发检查每个候选的 appcast，返回填好 latestVersion/downloadURL 的可更新项。
    public func checkForUpdates(_ candidates: [AppUpdateCandidate],
                                progress: @Sendable @escaping (Int, Int) -> Void = { _, _ in }) async -> [AppUpdateCandidate] {
        let total = candidates.count
        return await withTaskGroup(of: AppUpdateCandidate?.self) { group in
            let session = self.session
            for c in candidates {
                group.addTask { await Self.check(c, session: session) }
            }
            var updated: [AppUpdateCandidate] = []
            var done = 0
            for await result in group {
                done += 1
                progress(done, total)
                if let result, result.hasUpdate { updated.append(result) }
            }
            return updated.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        }
    }

    private static func check(_ c: AppUpdateCandidate, session: URLSession) async -> AppUpdateCandidate? {
        guard let feed = c.feedURL else { return nil }
        guard let (data, _) = try? await session.data(from: feed),
              let latest = UpdateChecker.parseLatest(data) else { return nil }
        guard UpdateChecker.isVersion(latest.version, newerThan: c.currentVersion) else { return c }
        var out = c
        out.latestVersion = latest.version
        out.downloadURL = latest.downloadURL
        return out
    }
}
