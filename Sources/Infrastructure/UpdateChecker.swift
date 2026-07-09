import Foundation
import CryptoKit
import DesignSystem

/// 更新检查结果
public struct UpdateInfo: Sendable, Equatable {
    public let version: String        // 最新版本号（CFBundleShortVersionString 语义）
    public let downloadURL: URL       // 下载地址
    public let releaseNotesURL: URL?  // 更新说明（可选）
    /// enclosure 的 EdDSA 签名（base64，`sparkle:edSignature`）——本站自更新源经受信私钥签名，
    /// 客户端用内嵌公钥离线验签后才认可为可安装。第三方 Sparkle 源无我方密钥，此字段留作忽略。
    public let edSignature: String?
    /// enclosure 内容 SHA-256（十六进制，可选）——签名材料的一部分；下载安装环节据此复核字节完整性。
    public let sha256: String?

    public init(version: String, downloadURL: URL, releaseNotesURL: URL?,
                edSignature: String? = nil, sha256: String? = nil) {
        self.version = version
        self.downloadURL = downloadURL
        self.releaseNotesURL = releaseNotesURL
        self.edSignature = edSignature
        self.sha256 = sha256
    }
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
/// 完整性信任根：本站自更新源在 enclosure 上带 `sparkle:edSignature`（EdDSA），
/// 客户端用内嵌公钥（Info.plist `XicoUpdatePublicKeys`，与许可证同一 Curve25519 原语）离线验签，
/// 通过才认可为可安装。这样即便 mac.xicoai.com 被入侵或 TLS 证书误签，攻击者无私钥便无法伪造更新。
///
/// ⚠️ 当前生效状态（务必如实理解，勿把「代码已就绪」误当「已强制验签」）：
///   EdDSA 验签门仅在**同时满足**「构建已内嵌 `XicoUpdatePublicKeys`」且「appcast 的 enclosure 带
///   `sparkle:edSignature`」时才真正拦截。二者尚未接通前，`trustedKeys` 为空、验签门被跳过，
///   更新完整性实际只依赖 **TLS + host-pin（限本站下载）+ Gatekeeper/公证**。
///   要闭合这一层需在发布链两端接通（见文件末 build/server 备注）：
///     1) make_app.sh 注入 `XicoUpdatePublicKeys`（`append_info_string`，值取 `${XICO_UPDATE_PUBLIC_KEYS}`）；
///     2) notarize.sh / generate_appcast 用配对私钥对每个 enclosure 的 `signedDescriptor` 签名并写入 `sparkle:edSignature`。
///   一旦两端就位，本类无需改动即自动从「host-pin 放行」升级为「验签失败即拒绝」（失败保守）。
/// 迁移到完整 Sparkle 的路径：appcast 格式已兼容，只需加 Sparkle SPM 依赖、
/// 用 `SPUStandardUpdaterController` 替换本类即可获得静默增量更新（notarize.sh 已备 generate_appcast）。
public final class UpdateChecker: NSObject, @unchecked Sendable {
    private let feedURL: URL?
    private let currentVersion: String
    private let session: URLSession
    /// keyID → Curve25519 公钥原始字节。为空 = 本构建尚未内嵌更新公钥（旧版发布链）：
    /// 退回仅 host-pin 的旧行为，不阻断更新；一旦发布脚本注入公钥且服务端签名，即强制验签。
    private let trustedKeys: [String: Data]

    public init(feedURL: URL? = nil,
                currentVersion: String? = nil,
                session: URLSession = .shared,
                trustedKeys: [String: Data]? = nil) {
        let bundle = Bundle.main
        self.feedURL = feedURL
            ?? (bundle.object(forInfoDictionaryKey: "SUFeedURL") as? String).flatMap(URL.init(string:))
        self.currentVersion = currentVersion
            ?? (bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)
            ?? "0.0.0"
        self.session = session
        self.trustedKeys = trustedKeys ?? Self.embeddedUpdateKeys()
    }

    /// 从 Info.plist 读取内嵌更新公钥（发布时经 make_app.sh / notarize.sh 注入，受 codesign 保护）。
    /// 格式与许可证公钥一致：`keyID:base64,keyID2:base64`。DEBUG 允许环境变量覆盖以便本地联调。
    static func embeddedUpdateKeys() -> [String: Data] {
        var raw = Bundle.main.object(forInfoDictionaryKey: "XicoUpdatePublicKeys") as? String
        #if DEBUG
        raw = ProcessInfo.processInfo.environment["XICO_UPDATE_PUBLIC_KEYS"] ?? raw
        #endif
        return parsePublicKeys(raw)
    }

    static func parsePublicKeys(_ raw: String?) -> [String: Data] {
        guard let raw, !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [:] }
        var keys: [String: Data] = [:]
        for pair in raw.split(separator: ",") {
            let parts = pair.split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2, let data = Data(base64Encoded: parts[1]) else { continue }
            keys[parts[0]] = data
        }
        return keys
    }

    /// 发布门（供 CI / 构建脚本调用，非运行期强制）：release 二进制是否已内嵌更新公钥。
    /// 为 true 才说明 EdDSA 验签门真正生效（见 `check()` 里的完整性门）；为 false 表示本构建仅靠
    /// host-pin + Gatekeeper 保护更新。CI 可断言 `UpdateChecker.isReleaseGateSatisfied()` 为 true 后再放行 DMG。
    public static func isReleaseGateSatisfied() -> Bool {
        !embeddedUpdateKeys().isEmpty
    }

    /// appcast 响应体上限：正常 appcast 仅数十 KB，设 4 MB 硬顶防超大/恶意响应拖垮内存。
    static let maxFeedBytes = 4 * 1024 * 1024

    enum FeedError: Error, Equatable { case tooLarge }

    /// 带上限的流式抓取：逐块累积，一旦越过 `limit` 立即中断并抛错——避免 `session.data(from:)`
    /// 那样先把整个响应体缓冲满内存再判断大小，杜绝超大/慢速塞满内存的响应。
    /// HTTP 状态码与最终落点 scheme 的校验仍由调用方在拿到 response 后处理。
    static func boundedData(from url: URL, session: URLSession,
                            limit: Int = maxFeedBytes) async throws -> (Data, URLResponse) {
        let (bytes, response) = try await session.bytes(from: url)
        var buffer = Data()
        buffer.reserveCapacity(min(limit, 64 * 1024))
        for try await byte in bytes {
            buffer.append(byte)
            if buffer.count > limit { throw FeedError.tooLarge }
        }
        return (buffer, response)
    }

    public func check() async -> UpdateCheckResult {
        guard let feedURL else { return .failed("未配置更新源") }
        do {
            let (data, response) = try await Self.boundedData(from: feedURL, session: session)
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                return .failed(xLocF("更新源返回 HTTP %d", http.statusCode))
            }
            guard let latest = Self.parseLatest(data) else {
                return .failed("无法解析更新信息")
            }
            // 纵深防御第一层（host-pin）：只接受指向本站（mac.xicoai.com）的 https 下载地址。
            // 即便更新源被调包/中间人篡改 enclosure，也无法把用户导向攻击者控制的下载主机。
            // 第二层是下方的 EdDSA 验签（内嵌公钥），封死「同主机换内容/改版本号」。二者叠加。
            guard Self.isTrustedDownloadHost(latest.downloadURL) else {
                XicoLog.update.error("拒绝不可信更新下载地址：\(latest.downloadURL.absoluteString, privacy: .public)")
                return .failed("更新下载地址未通过安全校验")
            }
            // 密码学完整性门：内嵌更新公钥后，enclosure 必须带一枚经受信私钥签名、且验签通过的
            // EdDSA 签名才认可为可安装——失败保守，宁可不更新也不放行被篡改/伪造的更新。
            // （未内嵌公钥的旧构建 trustedKeys 为空，跳过此门，退回仅 host-pin 的旧行为，不阻断更新。）
            if !trustedKeys.isEmpty,
               !Self.verifyEnclosureSignature(version: latest.version,
                                               downloadURL: latest.downloadURL,
                                               sha256: latest.sha256,
                                               signatureBase64: latest.edSignature,
                                               trustedKeys: trustedKeys) {
                XicoLog.update.error("更新签名校验未通过：\(latest.downloadURL.absoluteString, privacy: .public)")
                return .failed(xLoc("更新签名校验未通过"))
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

    // MARK: 下载地址信任校验

    /// 本站更新下载所在域——appcast 的 enclosure 只允许指向它（或其子域）。
    private static let trustedDownloadHost = "mac.xicoai.com"

    /// enclosure 下载地址是否可信：必须为 https 且 host 命中本站（或其子域）。
    static func isTrustedDownloadHost(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https", let host = url.host?.lowercased() else { return false }
        return host == trustedDownloadHost || host.hasSuffix(".\(trustedDownloadHost)")
    }

    // MARK: enclosure 签名验证（EdDSA / Curve25519）

    /// 待签名的规范描述串：把「版本 + 下载地址(+ 可选 SHA-256)」绑定进签名，
    /// 使攻击者既不能改版本号、也不能把下载指向另一个 DMG（host-pin 已限本站，签名再封死内容）。
    /// 服务端 generate_appcast 必须用同一规范串生成 `sparkle:edSignature`。
    static func signedDescriptor(version: String, downloadURL: URL, sha256: String?) -> Data {
        var s = version + "\n" + downloadURL.absoluteString
        if let sha256, !sha256.isEmpty { s += "\n" + sha256.lowercased() }
        return Data(s.utf8)
    }

    /// 用任一内嵌受信公钥验证 enclosure 签名。签名缺失/畸形/全部公钥都验不过 → false（失败保守）。
    static func verifyEnclosureSignature(version: String,
                                         downloadURL: URL,
                                         sha256: String?,
                                         signatureBase64: String?,
                                         trustedKeys: [String: Data]) -> Bool {
        guard let signatureBase64,
              let signature = Data(base64Encoded: signatureBase64),
              !trustedKeys.isEmpty else { return false }
        let message = signedDescriptor(version: version, downloadURL: downloadURL, sha256: sha256)
        for keyData in trustedKeys.values {
            guard let publicKey = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData) else { continue }
            if publicKey.isValidSignature(signature, for: message) { return true }
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
    private typealias Item = (version: String, url: String, notes: String, sig: String, sha256: String)
    private var items: [Item] = []
    private var cur: Item?
    private var element = ""
    private var text = ""

    func parse(_ data: Data) -> UpdateInfo? {
        let p = XMLParser(data: data)
        p.delegate = self
        guard p.parse() else { return nil }
        let best = items.max { UpdateChecker.isVersion($1.version, newerThan: $0.version) }
        guard let best, let url = URL(string: best.url), !best.version.isEmpty else { return nil }
        return UpdateInfo(version: best.version, downloadURL: url,
                          releaseNotesURL: URL(string: best.notes),
                          edSignature: best.sig.isEmpty ? nil : best.sig,
                          sha256: best.sha256.isEmpty ? nil : best.sha256)
    }

    func parser(_ parser: XMLParser, didStartElement el: String, namespaceURI: String?,
                qualifiedName qN: String?, attributes attrs: [String: String]) {
        element = el
        text = ""
        if el == "item" { cur = ("", "", "", "", "") }
        if el == "enclosure" {
            if let u = attrs["url"] { cur?.url = u }
            if cur?.version.isEmpty == true,
               let v = attrs["sparkle:shortVersionString"] ?? attrs["sparkle:version"] {
                cur?.version = v
            }
            if let sig = attrs["sparkle:edSignature"], cur?.sig.isEmpty == true { cur?.sig = sig }
            if let hash = attrs["sha256"] ?? attrs["sparkle:sha256"], cur?.sha256.isEmpty == true {
                cur?.sha256 = hash
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

// MARK: - 发布链 build/server 备注（闭合 EdDSA 验签门的两端，缺一不可）
//
// 本类的验签逻辑（verifyEnclosureSignature）已就绪且失败保守，但只有在下列两端同时接通后才「生效为强制」：
//
//   1) 构建端 — make_app.sh 注入内嵌公钥：
//        append_info_string "XicoUpdatePublicKeys" "${XICO_UPDATE_PUBLIC_KEYS}"
//      值格式与许可证公钥一致：`keyID:base64,keyID2:base64`（Curve25519 原始公钥字节的 base64）。
//      注入后受 codesign 覆盖，攻击者无法在不破坏签名的前提下清空它。
//      CI 发布门可断言 `UpdateChecker.isReleaseGateSatisfied() == true`，为空则拒绝出包。
//
//   2) 服务端 — generate_appcast 用配对私钥对每个 enclosure 的 `signedDescriptor` 签名：
//        signedDescriptor = version + "\n" + downloadURL.absoluteString [ + "\n" + sha256.lowercased() ]
//      即 `UpdateChecker.signedDescriptor(version:downloadURL:sha256:)` 生成的规范串（务必逐字节一致：
//      版本号、绝对下载 URL、可选小写 SHA-256，以 "\n" 连接），EdDSA/Curve25519 签名后 base64 写入
//      appcast enclosure 的 `sparkle:edSignature` 属性；若同时写 `sha256`/`sparkle:sha256` 属性则必须与
//      签名材料里的哈希一致，否则验签失败即拒绝更新。
//
// 两端就位后本类无需改动即自动从「host-pin 放行」升级为「验签失败即拒绝」（失败保守）。
// 二者未接通前（trustedKeys 为空）退回仅 host-pin + Gatekeeper/公证 的旧行为，不阻断更新。
