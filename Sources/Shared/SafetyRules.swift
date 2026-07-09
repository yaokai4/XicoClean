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
        lowered("/cores"),
        lowered("/opt"),
        lowered("/private/etc"),
        lowered("/private/var/db"),            // 含 sudo / dslocal / ConfigurationProfiles 等关键状态
        lowered("/Library/Apple"),
        lowered("/Library/LaunchDaemons"),     // 第三方 root 守护进程清单（删之即瘫）
        lowered("/Library/LaunchAgents"),
        lowered("/Library/Extensions"),
        lowered("/Library/Preferences"),
        lowered("/Library/Security"),
        lowered("/Library/Keychains")          // 系统钥匙串
        // 注意：刻意不含 /private/var/folders（用户级 Darwin 缓存，主程合法清理）
        //       与 /Library/Caches、/Library/Logs（系统级垃圾，经助手白名单清理）
    ]

    private static let allowExceptionsStatic: [[String]] = [
        lowered("/usr/local")
    ]

    /// /Users/<user>/<这些子目录> 本身不可删（其内部用户显式选择的文件可删）。小写。
    private static let protectedHomeChildrenLower: Set<String> = [
        "library", "documents", "desktop", "downloads", "pictures", "movies", "music"
    ]

    /// /Users/<user>/Library/<这些子树> 整棵受保护——当代 Mac 上最大的数据损失面：
    /// 云同步目录一旦被删会把删除同步到云端与其它设备，废纸篓救不回远端；
    /// 邮件/信息删了同样不可逆。这些目录内**没有任何合法可清理项**，故整棵封死。
    /// 均以 home 相对分量、小写存储。
    ///
    /// 注意：iPhone/iPad 本地备份（MobileSync/Backup）**刻意不在此列**——它是合法的
    /// 可清理项（对标 CleanMyMac 的 iOS 备份清理），由规则库标为 caution、默认不勾选、
    /// 清理前二次强警示；红线一刀切会误伤该功能。
    static let protectedLibrarySubtreesLower: [[String]] = [
        ["library", "mobile documents"],          // iCloud Drive（含"桌面与文稿"同步）
        ["library", "cloudstorage"],              // Dropbox/OneDrive/Google Drive 文件提供器挂载点
        ["library", "mail"],                       // Apple Mail 本地邮件库
        ["library", "messages"],                   // 信息（iMessage）本地库
        ["library", "keychains"]                    // 用户钥匙串（含 login.keychain-db 等，整棵封死）
    ]

    /// /Users/<user>/Library/<这些目录> **本身**不可删（防止一键删掉整个应用数据根），
    /// 但其内部精确定位的子项仍可删——卸载器删 `App Support/<bundleID>`、
    /// 容器缓存清理 `Containers/*/Data/Library/Caches/*` 等合法路径不受影响。home 相对、小写。
    static let protectedLibraryExactLower: [[String]] = [
        ["library", "application support"],        // 应用数据根
        ["library", "group containers"],           // App Group 共享容器根
        ["library", "containers"]                  // 沙盒应用容器根
    ]

    /// 凭证/密钥/云配置点目录（home 相对分量、小写）——**任意用户**主目录下均受保护，禁止删除。
    /// 单一事实来源（对抗复核 P3）：此前红线仅对任意用户保护 `.ssh`/`.gnupg`，其余凭证目录
    /// （`.aws`/`.kube`/`.docker` 等）只在**当前用户**由 `DefaultSafetyEngine` 兜底、对其他用户失守。
    /// 现把完整清单上提到红线唯一事实来源，既覆盖任意用户 `/Users/<any>/…` 分支，也并入注入 home 的
    /// `extraDenySubtrees`，三处（本类 / `DefaultSafetyEngine` 纵深兜底 / `DefinitionPathPolicy` 摄入期）
    /// 口径统一。刻意仅收 `.config/gcloud` 而非整个 `.config`——`.config` 下确有合法缓存（走缓存清理）。
    public static let credentialDotdirsLower: [[String]] = [
        [".ssh"], [".gnupg"], [".aws"], [".kube"], [".docker"],
        [".azure"], [".gcloud"], [".oci"], [".terraform.d"],
        [".config", "gcloud"], [".netrc"]
    ]

    /// 以这些扩展名结尾的「库包」整体受保护（照片/音乐/影片/图库等 bundle，删=图库全毁）。小写。
    // 仅包含「资料库/图库 bundle 目录」后缀；刻意不含 .motn 等单文件类型，
    // 避免把名为 X.motn 的普通模板文件误判为受保护资料库。
    private static let protectedPackageSuffixesLower: Set<String> = [
        "photoslibrary", "photolibrary", "aplibrary", "migratedaperturelibrary",
        "musiclibrary", "tvlibrary", "imovielibrary", "fcpbundle"
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
        let homeLower = Self.canonicalLower(h.pathComponents)
        var exact: Set<[String]> = [homeLower]
        for child in ["Library", "Documents", "Desktop", "Downloads", "Pictures", "Movies", "Music"] {
            exact.insert(Self.canonicalLower(h.appendingPathComponent(child).pathComponents))
        }
        // 应用数据根 / 容器根 / 钥匙串目录本身（相对注入 home，精确保护）
        for rel in Self.protectedLibraryExactLower {
            exact.insert(homeLower + rel)
        }
        extraDenyExact = exact
        // 凭证/密钥/云配置点目录（相对注入 home，整棵保护）——完整清单，单一事实来源。
        var subtrees: [[String]] = Self.credentialDotdirsLower.map { homeLower + $0 }
        // 云同步/邮件/信息/iPhone 备份子树（相对注入 home，整棵保护）
        for rel in Self.protectedLibrarySubtreesLower {
            subtrees.append(homeLower + rel)
        }
        extraDenySubtrees = subtrees
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
        let t = Self.canonicalLower(target)   // 不区分大小写 + firmlink 统一

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
        // 4.5 库包整体保护（照片/音乐/影片图库等 bundle，任意位置）——删包=图库全毁
        if let bad = t.first(where: { comp in
            guard let dot = comp.lastIndex(of: ".") else { return false }
            return Self.protectedPackageSuffixesLower.contains(String(comp[comp.index(after: dot)...]))
        }) {
            return "“\(bad)” 是受保护的图库/资料库，禁止删除"
        }
        // 5. 任意用户主目录保护（home 无关，保护所有用户）
        if t.count >= 2 && t[1] == "users" {
            if t.count == 3 {
                return "“\(target.last ?? "")” 是受保护的用户主目录"
            }
            if t.count == 4 && Self.protectedHomeChildrenLower.contains(t[3]) {
                return "“\(target.count > 3 ? target[3] : "")” 是受保护的用户内容目录"
            }
            // home 相对分量（t[3...]）——凭证目录与云同步/邮件/备份子树共用。
            let relative = Array(t.dropFirst(3))   // ["library", "mobile documents", ...] / [".aws", ...]
            // 5.0 凭证/密钥/云配置点目录：**任意用户**主目录下均保护（对抗复核 P3，扩至完整清单）。
            //     复用既有已全量本地化的键 "密钥目录受保护，禁止删除"（原 .ssh/.gnupg 分支同款文案），
            //     避免在 Shared 红线引入未入 11 语言表的新字面量（保持 i18n 覆盖不退化）。
            for dir in Self.credentialDotdirsLower where Self.isInsideOrEqual(relative, dir) {
                return "密钥目录受保护，禁止删除"
            }
            // 5.1 家目录内的云同步/邮件/信息/iPhone 备份子树整体保护。
            //     以 home 相对分量匹配 protectedLibrarySubtreesLower。
            for subtree in Self.protectedLibrarySubtreesLower where Self.isInsideOrEqual(relative, subtree) {
                return "“\(subtree.last ?? "")” 是受保护的用户数据目录（云同步/邮件/备份），禁止删除"
            }
            // 5.2 应用数据根 / 容器根 / 钥匙串目录**本身**不可删（内部精确子项仍可删）。
            for exact in Self.protectedLibraryExactLower where relative == exact {
                return "“\(exact.last ?? "")” 是受保护的应用数据根目录，禁止整体删除"
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

    /// 小写 + Unicode NFC 归一 + firmlink 统一：
    /// - standardizedFileURL 对「存在」的路径会把 /private/var 砍成 /var、对「不存在」的保留 /private/var，
    ///   两侧不一致会漏匹配 → 强制统一到无 /private 形态。
    /// - macOS 文件名可能以 NFD（分解）或 NFC（预组合）出现（如 é），两种字节序列指向同一文件；
    ///   统一 precomposed(NFC) 后比较，杜绝用 NFD 形态绕过红线前缀匹配。
    public static func canonicalLower(_ components: [String]) -> [String] {
        var c = components.map { $0.precomposedStringWithCanonicalMapping.lowercased() }
        if c.count >= 3, c[1] == "private", c[2] == "var" || c[2] == "etc" || c[2] == "tmp" {
            c.remove(at: 1)
        }
        return c
    }

    private static func lowered(_ path: String) -> [String] {
        canonicalLower(URL(fileURLWithPath: path).pathComponents)
    }
}
