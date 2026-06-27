import Foundation

/// 默认安全引擎：清理器的命门。
/// 任何删除前都必须经过 verify；保护清单内的路径一律拒绝。
public struct DefaultSafetyEngine: SafetyEngine {

    /// 这些路径本身及其内部任何内容都不可删除
    private let denySubtrees: [[String]]
    /// 仅这些路径本身不可删除（其内部子项允许）
    private let denyExact: Set<[String]>
    /// 例外子树：即使落在 denySubtrees 内，只要也落在这里就放行（如 /usr/local）
    private let allowExceptions: [[String]]

    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        func comps(_ path: String) -> [String] {
            URL(fileURLWithPath: path).standardizedFileURL.pathComponents
        }
        let h = home.standardizedFileURL

        // 子树保护：这些位置及其内部任何内容都禁止删除（真正关键/不可恢复的）
        denySubtrees = [
            comps("/System"),
            comps("/usr"),
            comps("/bin"),
            comps("/sbin"),
            comps("/private/var/db/dslocal"),
            comps("/Library/Apple"),
            h.appendingPathComponent("Library/Keychains").pathComponents,
            h.appendingPathComponent(".ssh").pathComponents,
            h.appendingPathComponent(".gnupg").pathComponents
        ]

        // 精确保护：仅这些文件夹本身不可删除；其中用户显式选择的文件可移入废纸篓（可恢复）。
        // 这样大文件/重复文件等模块才能真正清理用户内容，同时杜绝整目录被误删。
        denyExact = [
            comps("/"),
            comps("/Applications"),
            comps("/Users"),
            comps("/Volumes"),
            h.pathComponents,
            h.appendingPathComponent("Library").pathComponents,
            h.appendingPathComponent("Downloads").pathComponents,
            h.appendingPathComponent("Documents").pathComponents,
            h.appendingPathComponent("Desktop").pathComponents,
            h.appendingPathComponent("Pictures").pathComponents,
            h.appendingPathComponent("Movies").pathComponents,
            h.appendingPathComponent("Music").pathComponents
        ]

        allowExceptions = [
            comps("/usr/local")
        ]
    }

    public func verify(_ url: URL, intent: DeleteIntent) -> SafetyVerdict {
        let standardized = url.standardizedFileURL.resolvingSymlinksInPath()
        let target = standardized.pathComponents
        let path = standardized.path

        // 1. 空路径 / 根目录
        if path.isEmpty || path == "/" {
            return .deny(reason: "不允许删除根目录")
        }

        // 2. 路径穿越保护
        if target.contains("..") {
            return .deny(reason: "路径包含非法的上跳分量")
        }

        // 3. 卷根 /Volumes/X 本身
        if target.count == 3 && target[1] == "Volumes" {
            return .deny(reason: "不允许删除卷的挂载根")
        }

        // 4. 精确保护
        if denyExact.contains(target) {
            return .deny(reason: "“\(standardized.lastPathComponent)” 是受保护的系统/用户目录")
        }

        // 5. 子树保护（含例外放行）
        for root in denySubtrees where Self.isInsideOrEqual(target, root) {
            if allowExceptions.contains(where: { Self.isInsideOrEqual(target, $0) }) {
                continue
            }
            return .deny(reason: "“\(path)” 位于受保护区域，禁止删除")
        }

        return .allow
    }

    /// target 是否等于或位于 root 之下
    static func isInsideOrEqual(_ target: [String], _ root: [String]) -> Bool {
        guard target.count >= root.count else { return false }
        return Array(target.prefix(root.count)) == root
    }
}
