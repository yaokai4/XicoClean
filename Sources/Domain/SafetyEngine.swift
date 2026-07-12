import Foundation
import Shared

/// 默认安全引擎：清理器的命门。
/// 任何删除前都必须经过 verify；保护清单内的路径一律拒绝。
///
/// 实现已下沉到 `Shared.XicoSafetyRules`（唯一事实来源），
/// 主应用与特权助手共用同一份红线，杜绝两侧口径分裂。
public struct DefaultSafetyEngine: SafetyEngine {
    private let rules: XicoSafetyRules
    /// 用户内容目录（其中的文件只允许移入废纸篓，绝不允许彻底删除）。小写、已解析。
    private let contentRootsLower: [[String]]
    /// 用户主目录（小写、已解析）——.permanent 默认拒绝其下一切，除非落在下方可重建垃圾白名单。
    private let homeLower: [String]
    /// `.permanent` 在家目录内的**唯一**放行区：可无损重建的缓存/日志/废纸篓等一次性垃圾。
    /// 家目录相对分量、小写。其余家目录路径（含 ~/Library/Application Support、点文件配置、
    /// 各类应用数据等）一律拒绝彻底删除——**默认拒绝**，杜绝任何模块误用 permanent
    /// 抹掉不可再生的用户数据。家目录之外（系统级 /Library/Caches 等）不受此限，
    /// 交由通用红线与助手白名单把关。
    private let permanentHomeAllowlistLower: [[String]]
    /// 家目录内凭证/密钥/云配置点目录——**任何 intent 都一律拒绝删除**（纵深防御，对抗复核 P2/P3）。
    /// 即便某个已签名但有缺陷的定义把这些树当成可清理项、或某模块误列，删除期红线也在此兜底拦下。
    /// 完整清单现由 `XicoSafetyRules.credentialDotdirsLower` 统一提供（红线已对任意用户保护同一清单），
    /// 此处以当前 home 展开后再兜一道。家目录相对分量、小写。刻意不含整个 `.config`——其下确有合法缓存
    /// （走通用缓存清理），仅收 `.config/gcloud`，由摄入期 `DefinitionPathPolicy` 精确区分缓存/非缓存子树。
    private let credentialDotdirsLower: [[String]]

    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        rules = XicoSafetyRules(home: home)
        let h = home.standardizedFileURL.resolvingSymlinksInPath()
        homeLower = XicoSafetyRules.canonicalLower(h.pathComponents)
        contentRootsLower = ["Documents", "Desktop", "Pictures", "Movies", "Music", "Downloads"].map {
            XicoSafetyRules.canonicalLower(h.appendingPathComponent($0).pathComponents)
        }
        // 仅这些「删了会自动重建、无不可逆数据」的家目录子树允许彻底删除。
        let hl = homeLower   // 本地副本，避免在 init 完成前于闭包中捕获 self
        permanentHomeAllowlistLower = [
            [".trash"],                              // 废纸篓（清空废纸篓走 .permanent）
            ["library", "caches"],                   // 用户级缓存
            ["library", "logs"],                     // 用户级日志（含诊断报告）
            ["library", "saved application state"],  // 窗口状态，重建无损
            ["library", "developer"],                // Xcode 派生数据 / 设备支持 / 模拟器缓存
            [".cache"]                               // XDG 缓存
        ].map { hl + $0 }
        // 凭证/密钥/云配置点目录：删除期一律拒。清单直接取自 `XicoSafetyRules` 唯一事实来源
        // （对抗复核 P3——红线现已对任意用户保护完整清单，此处对当前 home 再兜一道纵深防御，
        // 口径与红线严格一致，杜绝两侧分裂）。
        credentialDotdirsLower = XicoSafetyRules.credentialDotdirsLower.map { hl + $0 }
    }

    public func verify(_ url: URL, intent: DeleteIntent) -> SafetyVerdict {
        if let reason = rules.denyReason(for: url) {
            return .deny(reason: reason)
        }
        // 凭证/密钥/云配置点目录：任何 intent 都拒（纵深防御，对抗复核 P2）。解析符号链接后判定，
        // 杜绝用软链把删除指向 ~/.aws 等目录。
        let resolvedLower = XicoSafetyRules.canonicalLower(
            url.standardizedFileURL.resolvingSymlinksInPath().pathComponents)
        for dir in credentialDotdirsLower where XicoSafetyRules.isInsideOrEqual(resolvedLower, dir) {
            // 复用既有已全量本地化的键（与 XicoSafetyRules 同款），避免未入 11 语言表的字面量。
            return .deny(reason: "密钥目录受保护，禁止删除")
        }
        // DeleteIntent 差异化：.permanent（彻底删除，永不可逆）在家目录内**默认拒绝**——
        // 只放行可无损重建的缓存/日志/废纸篓白名单，其余（应用数据、点文件配置、图库派生等）
        // 一律拒。任何模块误用 permanent intent 都会在此被红线兜底拦下。
        if intent == .permanent {
            let t = resolvedLower   // 复用上方已解析的分量，避免重复 resolvingSymlinksInPath
            // 内容目录（文稿/桌面/图片/影片/音乐/下载）给出更具体的文案。
            for root in contentRootsLower where XicoSafetyRules.isInsideOrEqual(t, root) {
                return .deny(reason: "内容目录中的文件仅支持移入废纸篓（可恢复），不支持彻底删除")
            }
            // 家目录内、且不在可重建垃圾白名单 → 拒绝彻底删除（默认拒绝，fail-closed）。
            if XicoSafetyRules.isInsideOrEqual(t, homeLower),
               !permanentHomeAllowlistLower.contains(where: { XicoSafetyRules.isInsideOrEqual(t, $0) }) {
                return .deny(reason: "该位置的文件仅支持移入废纸篓（可恢复），不支持彻底删除")
            }
        }
        return .allow
    }
}

/// 规则库「摄入期」路径形状校验——与删除期红线（`XicoSafetyRules`）互补的纵深防御。
///
/// 删除期红线在**每一项删除前**逐项把关；本策略在**签名校验通过、入库之前**先把
/// 「路径逃逸出预期区域」的坏定义整条拒之门外，避免坏定义先入库、再靠逐项拦截兜底。
/// 逻辑纯字符串（对未展开的 `~`/`*` 模式判定），放在 Domain 便于单测直接覆盖，
/// 由 `Infrastructure.DefinitionsUpdateService.validate` 调用。
public enum DefinitionPathPolicy {
    /// 普通（用户级）定义允许的路径前缀集。
    ///
    /// 对抗复核 P2（第一轮）：此前含裸 `"~/."`，等于放行**任意**点文件目录——一个已签名但有缺陷/被误用的
    /// 普通定义即可命中 `~/.aws/credentials`、`~/.kube/config`、`~/.ssh`、`~/.docker/config.json`
    /// 等不可再生的凭证/配置树。现改为：家目录点文件目录**仅**放行可无损重建的缓存前缀
    /// （`cacheDotdirPrefixes`）或路径分量中确含 `cache`/`Caches` 的点目录（见 `isAllowedDotCache`），
    /// 且凭证/密钥点目录一律先行拒绝（见 `deniedCredentialDotdirs`），fail-closed。
    ///
    /// 对抗复核 P2（第二轮）：此前还含裸 `"~/Library"`，等于放行**整个** Library——一个已签名但有缺陷的
    /// 普通定义即可把 `~/Library/Preferences`（应用偏好，删=设置全丢）、`~/Library/Application Support/<app>`
    /// （非缓存应用数据）、乃至整个缓存根扫进废纸篓。现移除该裸前缀，改由 `isAllowedLibrarySubtree`
    /// 精确放行 Library 下可无损重建的缓存/日志/窗口状态/开发者派生数据子树，其余（Preferences、
    /// 非缓存 Application Support、Mail、Keychains 等）一律不再摄入放行，fail-closed。
    /// 删除期红线（`XicoSafetyRules` / `DefaultSafetyEngine.verify`）保持不变，作纵深防御第二道。
    public static let generalPrefixes = ["/Library/Caches", "/Library/Logs", "/private/var/log"]
    /// `~/Library` 下**整棵**放行的可清理根（小写，均可无损重建）：缓存 / 日志 / 窗口状态 / 开发者派生数据。
    /// 刻意不含 `preferences`、`application support`、`mail`、`keychains`、`containers`、`group containers`
    /// 等——这些根整棵不放行，仅其**含 `cache` 分量**的子树经 `isAllowedLibrarySubtree` 泛化放行。
    public static let libraryCacheRoots = ["caches", "logs", "saved application state", "developer"]
    /// `~/Library` 下**逐条具体列名**放行的非缓存可清理子树——均为内置规则库明确清理、位置固定的
    /// 一次性/可再生数据（iOS 本地备份与固件更新包、邮件附件预览副本、部分应用的自动下载/blob 临时数据）。
    /// 逐条精确前缀匹配（`isUnder`），不含任何 `Preferences` / 通用应用数据根，故不放大攻击面：
    /// 一条已签名但有缺陷的定义至多命中这几个固定已知目录，而非整个 Library。
    /// **与 definitions.json 保持同步**：新增此类固定位置的非缓存清理项时须在此登记，
    /// 否则其在线目录更新会被摄入期整条拒收（`DefinitionsUpdateService.validate`）。
    public static let libraryExtraAllowedSubtrees = [
        "~/Library/Application Support/MobileSync/Backup",                  // iOS 本地备份
        "~/Library/iTunes/iPhone Software Updates",                         // iPhone 固件更新包(IPSW)
        "~/Library/iTunes/iPad Software Updates",                          // iPad 固件更新包
        "~/Library/Containers/com.apple.mail/Data/Library/Mail Downloads",  // 邮件附件预览副本
        "~/Library/Application Support/zoom.us/AutoDownload",               // Zoom 自动下载缓存
        "~/Library/Application Support/*/blob_storage",                     // Electron 应用 blob 临时数据(通配段)
        "~/Library/Application Support/CrashReporter"                       // 崩溃报告器中间数据（系统按需重建）
    ]
    /// 家目录内**明确列名**放行的缓存点目录（可无损重建）。此外还接受任意分量含 `cache` 的点目录。
    /// pnpm store / sbt boot / NuGet packages（2026-07 CI 交叉审计发现的口径分裂）：三者均为
    /// 重装时可全量重下的包缓存，内置规则已在清理而摄入期却会拒收其在线更新版本——补入放行。
    public static let cacheDotdirPrefixes = [
        "~/.cache", "~/.npm", "~/.yarn", "~/.gradle/caches",
        "~/.cargo/registry/cache", "~/.pub-cache", "~/.gem", "~/.m2/repository",
        "~/.pnpm-store", "~/.sbt/boot", "~/.nuget/packages"
    ]
    /// 家目录内凭证/密钥/云配置点目录：普通定义**一律不得**命中（即便含 cache 分量也拒）。
    public static let deniedCredentialDotdirs = [
        "~/.ssh", "~/.gnupg", "~/.aws", "~/.kube", "~/.docker",
        "~/.azure", "~/.gcloud", "~/.oci", "~/.terraform.d"
    ]
    /// `requiresHelper` 定义额外必须落入的系统级白名单根（与 `XicoHelperSecurity.deletableRoots` 对齐）。
    public static let helperRoots = ["/Library/Caches", "/Library/Logs", "/private/var/log", "/var/log"]

    /// 单条路径模式是否形状合法。
    /// - 拒绝空串与含 `..` 上跳的路径；
    /// - 凭证/密钥点目录一律拒（fail-closed，先于任何放行判断）；
    /// - 必须命中 `generalPrefixes`、`~/Library` 缓存子树（`isAllowedLibrarySubtree`），或家目录缓存点目录（`isAllowedDotCache`）；
    /// - `requiresHelper` 时**同时**要求命中 `helperRoots`（否则以 root 权限删到白名单外，fail-closed）。
    public static func isAllowed(path: String, requiresHelper: Bool) -> Bool {
        let p = path.trimmingCharacters(in: .whitespacesAndNewlines)
        if p.isEmpty || p.contains("..") { return false }
        if isDeniedCredentialDotdir(p) { return false }
        guard isUnder(p, generalPrefixes) || isAllowedLibrarySubtree(p) || isAllowedDotCache(p) else { return false }
        if requiresHelper { return isUnder(p, helperRoots) }
        return true
    }

    private static func isUnder(_ path: String, _ prefixes: [String]) -> Bool {
        for prefix in prefixes where path == prefix || path.hasPrefix(prefix + "/") {
            return true
        }
        return false
    }

    /// `~/Library` 下的放行判定（对抗复核 P2 第二轮，取代裸 `~/Library` 前缀）：
    /// - 仅 `libraryCacheRoots`（Caches / Logs / Saved Application State / Developer）整棵放行；
    /// - 泛化：Library 之下任一分量含 `cache`、或为 `log`/`logs` 的可重建子树亦放行——覆盖
    ///   `Application Support/*/Cache`、`Service Worker/CacheStorage`、`*/CachedData`、`PersistentCache`、
    ///   `Media Cache Files`、`Containers/*/Data/Library/Caches`、`Group Containers/*/Library/Caches`、
    ///   `Containers/*/Data/log` 等既有合法清理项；
    /// - `libraryExtraAllowedSubtrees` 中逐条列名的固定位置非缓存清理项（iOS 备份/固件、邮件附件等）放行；
    /// - 其余（`Preferences`、非缓存 `Application Support/<app>`、`Mail`、`Messages`、`Keychains`
    ///   等不可再生数据）一律拒。裸 `~/Library` 本身亦不放行。
    private static func isAllowedLibrarySubtree(_ path: String) -> Bool {
        guard path == "~/Library" || path.hasPrefix("~/Library/") else { return false }
        if isUnder(path, libraryExtraAllowedSubtrees) { return true }   // 逐条具体列名的非缓存清理项
        // 分量：["~", "library", <根>, ...]；未展开的 `*` 通配段按普通分量参与判定。
        let comps = path.split(separator: "/").map { $0.lowercased() }
        guard comps.count >= 3 else { return false }          // 裸 ~/Library 不放行
        if libraryCacheRoots.contains(comps[2]) { return true }
        return comps.dropFirst(2).contains { $0.contains("cache") || $0 == "log" || $0 == "logs" }
    }

    /// 家目录点文件目录中，仅缓存前缀 / 含 `cache` 分量的点目录放行（凭证目录已在上游拒）。
    private static func isAllowedDotCache(_ path: String) -> Bool {
        guard path.hasPrefix("~/.") else { return false }
        if isUnder(path, cacheDotdirPrefixes) { return true }
        // 泛化：路径任一分量含 "cache"（如 ~/.npm/_cacache、~/.foo/Caches）视为可重建缓存。
        return path.split(separator: "/").contains { $0.lowercased().contains("cache") }
    }

    /// 凭证/密钥/云配置点目录（含其子树）——普通定义一律拒。`~/.config/gcloud` 亦拒；
    /// `~/.config` 其余子树留待缓存判定（其下确有合法缓存）。
    private static func isDeniedCredentialDotdir(_ path: String) -> Bool {
        if isUnder(path, deniedCredentialDotdirs) { return true }
        if path == "~/.config/gcloud" || path.hasPrefix("~/.config/gcloud/") { return true }
        return false
    }
}
