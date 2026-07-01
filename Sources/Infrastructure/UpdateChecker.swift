import Foundation

/// 更新检查结果
public struct UpdateInfo: Sendable, Equatable {
    public let version: String        // 最新版本号（CFBundleShortVersionString 语义）
    public let downloadURL: URL       // 下载地址
    public let releaseNotesURL: URL?  // 更新说明（可选）
}

public enum UpdateCheckResult: Sendable, Equatable {
    case upToDate
    case available(UpdateInfo)
    case failed(String)
}

/// 轻量更新检查器：读取 Info.plist 的 `SUFeedURL`（Sparkle 兼容的 appcast），
/// 拉取并解析最新版本，与当前版本比较。**这是发布刚需的最小实现**——发出去的版本
/// 不再"失联"：用户能收到有新版的提示并跳转下载。
///
/// 迁移到完整 Sparkle 的路径：appcast 格式已兼容，只需加 Sparkle SPM 依赖、
/// 用 `SPUStandardUpdaterController` 替换本类、并在 appcast 的 enclosure 上加
/// `sparkle:edSignature` 即可获得静默增量更新 + 签名校验（notarize.sh 已备 generate_appcast）。
public final class UpdateChecker: NSObject, @unchecked Sendable {
    private let feedURL: URL?
    private let currentVersion: String
    private let session: URLSession

    public init(feedURL: URL? = nil,
                currentVersion: String? = nil,
                session: URLSession = .shared) {
        let bundle = Bundle.main
        self.feedURL = feedURL
            ?? (bundle.object(forInfoDictionaryKey: "SUFeedURL") as? String).flatMap(URL.init(string:))
        self.currentVersion = currentVersion
            ?? (bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)
            ?? "0.0.0"
        self.session = session
    }

    public func check() async -> UpdateCheckResult {
        guard let feedURL else { return .failed("未配置更新源") }
        do {
            let (data, response) = try await session.data(from: feedURL)
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                return .failed("更新源返回 HTTP \(http.statusCode)")
            }
            guard let latest = Self.parseLatest(data) else {
                return .failed("无法解析更新信息")
            }
            if Self.isVersion(latest.version, newerThan: currentVersion) {
                return .available(latest)
            }
            return .upToDate
        } catch {
            XicoLog.update.error("检查更新失败：\(error.localizedDescription, privacy: .public)")
            return .failed(error.localizedDescription)
        }
    }

    // MARK: 版本比较（点分数字，缺位补 0）

    /// a 是否比 b 新
    public static func isVersion(_ a: String, newerThan b: String) -> Bool {
        let pa = a.split(separator: ".").map { Int($0) ?? 0 }
        let pb = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0
            let y = i < pb.count ? pb[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    // MARK: appcast 解析

    static func parseLatest(_ data: Data) -> UpdateInfo? {
        let parser = AppcastParser()
        return parser.parse(data)
    }
}

/// 极简 RSS/appcast 解析：取所有 <item>，选版本号最高的一条。
/// 版本号优先 sparkle:shortVersionString，其次 enclosure 的 sparkle:shortVersionString / version 属性。
private final class AppcastParser: NSObject, XMLParserDelegate {
    private var items: [(version: String, url: String, notes: String)] = []
    private var cur: (version: String, url: String, notes: String)?
    private var element = ""
    private var text = ""

    func parse(_ data: Data) -> UpdateInfo? {
        let p = XMLParser(data: data)
        p.delegate = self
        guard p.parse() else { return nil }
        let best = items.max { UpdateChecker.isVersion($1.version, newerThan: $0.version) }
        guard let best, let url = URL(string: best.url), !best.version.isEmpty else { return nil }
        return UpdateInfo(version: best.version, downloadURL: url,
                          releaseNotesURL: URL(string: best.notes))
    }

    func parser(_ parser: XMLParser, didStartElement el: String, namespaceURI: String?,
                qualifiedName qN: String?, attributes attrs: [String: String]) {
        element = el
        text = ""
        if el == "item" { cur = ("", "", "") }
        if el == "enclosure" {
            if let u = attrs["url"] { cur?.url = u }
            if cur?.version.isEmpty == true,
               let v = attrs["sparkle:shortVersionString"] ?? attrs["sparkle:version"] {
                cur?.version = v
            }
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

    func parser(_ parser: XMLParser, didEndElement el: String, namespaceURI: String?, qualifiedName qN: String?) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch el {
        case "sparkle:shortVersionString": if !trimmed.isEmpty { cur?.version = trimmed }
        case "sparkle:releaseNotesLink", "link": if cur?.notes.isEmpty == true { cur?.notes = trimmed }
        case "item": if let c = cur { items.append(c); cur = nil }
        default: break
        }
    }
}
