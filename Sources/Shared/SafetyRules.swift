import Foundation

/// 删除红线的「唯一事实来源」（纯 Foundation，可被主应用、特权助手、测试共用）。
///
/// 设计要点：
/// 1. 通用系统保护（/System、/usr、/bin…）与「任意用户主目录」保护（/Users/<任何用户>/…）
///    都是 *home 无关* 的——因此以 root 运行、并不知道发起方用户是谁的特权助手，
///    也能对所有用户的敏感目录一视同仁地守住红线（纵深防御）。
/// 2. 可选注入 `home`：当主应用用非标准 home（或单测注入 /Users/tester）时，
///    额外把该 home 的敏感子目录并入保护集，保证与历史行为逐项一致。
/// 3. 判定前统一 `standardizedFileURL.resolvingSymlinksInPath()`，杜绝软链绕过前缀匹配。
/// 4. **大小写不敏感匹配**：macOS 默认 APFS 大小写不敏感，`/SYSTEM/...` 与 `/System/...`
///    指向同一对象，故红线一律按小写比较（对红线而言「多拒」永远是安全方向）。
public struct XicoSafetyRules: Sendable {

    // MARK: 通用（home 无关，均以小写存储用于不区分大小写匹配）

    private static let denyExactStatic: Set<[String]> = [
        lowered("/Applications"),
        lowered("/Users"),
        lowered("/Volumes")
    ]

    private static let denySubtreesStatic: [[String]] = [
        lowered("/System"),
        lowered("/usr"),
        lowered("/bin"),
        lowered("/sbin"),
        lowered("/private/var/db/dslocal"),
        lowered("/Library/Apple")
    ]

    private static let allowExceptionsStatic: [[String]] = [
        lowered("/usr/local")
    ]

    /// /Users/<user>/<这些子目录> 本身不可删（其内部用户显式选择的文件可删）。小写。
    private static let protectedHomeChildrenLower: Set<String> = [
        "library", "documents", "desktop", "downloads", "pictures", "movies", "music"
    ]

    // MARK: 注入 home 的额外保护（与通用规则取并集，均小写）

    private let extraDenyExact: Set<[String]>
    private let extraDenySubtrees: [[String]]

    public init(home: URL? = nil) {
        guard let home else {
            extraDenyExact = []
            extraDenySubtrees = []
            return
        }
        let h = home.standardizedFileURL
        var exact: Set<[String]> = [Self.lower(h.pathComponents)]
        for child in ["Library", "Documents", "Desktop", "Downloads", "Pictures", "Movies", "Music"] {
            exact.insert(Self.lower(h.appendingPathComponent(child).pathComponents))
        }
        extraDenyExact = exact
        extraDenySubtrees = [
            Self.lower(h.appendingPathComponent("Library/Keychains").pathComponents),
            Self.lower(h.appendingPathComponent(".ssh").pathComponents),
            Self.lower(h.appendingPathComponent(".gnupg").pathComponents)
        ]
    }

    // MARK: 判定

    /// 对一个 URL 判定：返回拒绝原因；nil 表示放行。内部统一标准化并解析符号链接后再判定。
    public func denyReason(for url: URL) -> String? {
        let resolved = url.standardizedFileURL.resolvingSymlinksInPath()
        return denyReason(forResolvedComponents: resolved.pathComponents)
    }

    public func isAllowed(_ url: URL) -> Bool { denyReason(for: url) == nil }

    /// 已标准化/解析后的 path components 判定（核心逻辑，可直接单测）。
    public func denyReason(forResolvedComponents target: [String]) -> String? {
        let t = target.map { $0.lowercased() }   // 不区分大小写匹配

        // 1. 空 / 根目录
        if t.isEmpty || t == ["/"] {
            return "不允许删除根目录"
        }
        // 2. 越界分量（标准化通常已消解 ..；保留为纵深防御）
        if t.contains("..") {
            return "路径包含非法的上跳分量"
        }
        // 3. 卷挂载根 /Volumes/X 本身
        if t.count == 3 && t[1] == "volumes" {
            return "不允许删除卷的挂载根"
        }
        // 4. 通用精确保护
        if Self.denyExactStatic.contains(t) || extraDenyExact.contains(t) {
            return "“\(target.last ?? "")” 是受保护的系统/用户目录"
        }
        // 5. 任意用户主目录保护（home 无关，保护所有用户）
        if t.count >= 2 && t[1] == "users" {
            if t.count == 3 {
                return "“\(target.last ?? "")” 是受保护的用户主目录"
            }
            if t.count == 4 && Self.protectedHomeChildrenLower.contains(t[3]) {
                return "“\(target.count > 3 ? target[3] : "")” 是受保护的用户内容目录"
            }
            if t.count >= 5 && t[3] == "library" && t[4] == "keychains" {
                return "钥匙串受保护，禁止删除"
            }
            if t.count >= 4 && (t[3] == ".ssh" || t[3] == ".gnupg") {
                return "密钥目录受保护，禁止删除"
            }
        }
        // 6. 通用子树保护（含例外放行）
        for root in Self.denySubtreesStatic where Self.isInsideOrEqual(t, root) {
            if Self.allowExceptionsStatic.contains(where: { Self.isInsideOrEqual(t, $0) }) {
                continue
            }
            return "位于受保护区域，禁止删除"
        }
        // 7. 注入 home 的子树保护
        for root in extraDenySubtrees where Self.isInsideOrEqual(t, root) {
            return "位于受保护区域，禁止删除"
        }
        return nil
    }

    // MARK: 工具

    /// target 是否等于或位于 root 之下（两侧应已小写）
    public static func isInsideOrEqual(_ target: [String], _ root: [String]) -> Bool {
        guard target.count >= root.count else { return false }
        return Array(target.prefix(root.count)) == root
    }

    private static func lower(_ components: [String]) -> [String] { components.map { $0.lowercased() } }

    private static func lowered(_ path: String) -> [String] {
        lower(URL(fileURLWithPath: path).standardizedFileURL.pathComponents)
    }
}
