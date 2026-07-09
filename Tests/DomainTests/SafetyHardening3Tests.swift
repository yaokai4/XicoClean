import XCTest
@testable import Domain
import Shared

/// 对抗复核第 3 轮安全加固回归（2026-07 最终轮）：
///  A. 摄入期（DefinitionPathPolicy）——移除裸 `~/Library` 放行：`~/Library/Preferences` 及非缓存
///     应用数据不再被摄入放行；而缓存/日志/窗口状态/开发者派生数据及少数具体列名清理项仍放行；
///  B. 删除期红线（XicoSafetyRules）——凭证/密钥/云配置点目录对**任意用户**均拒（此前仅 .ssh/.gnupg）。
final class SafetyHardening3Tests: XCTestCase {

    func url(_ p: String) -> URL { URL(fileURLWithPath: p) }

    // MARK: - A. 摄入期：裸 ~/Library 收紧后，Preferences / 非缓存应用数据被拒

    func testIngestRejectsPreferencesAndNonCacheLibrary() {
        for p in ["~/Library/Preferences/*",
                  "~/Library/Preferences/com.apple.finder.plist",
                  "~/Library/Application Support/Foo/data.db",   // 非缓存应用数据
                  "~/Library/Mail/*",
                  "~/Library/Keychains/login.keychain-db",
                  "~/Library/Messages/chat.db",
                  "~/Library",                                    // 裸 Library 本身
                  "~/Library/Containers/com.some.app/Data/Documents/keep.txt"] {
            XCTAssertFalse(DefinitionPathPolicy.isAllowed(path: p, requiresHelper: false),
                           "非缓存 Library 子树必须被摄入期拒绝: \(p)")
        }
    }

    // MARK: - A. 摄入期：合法缓存/日志/状态/开发者子树及具体列名清理项仍放行（未过度收紧）

    func testIngestStillAllowsLegitLibrarySubtrees() {
        for p in ["~/Library/Caches/*",
                  "~/Library/Logs/*",
                  "~/Library/Saved Application State/*",
                  "~/Library/Developer/Xcode/DerivedData/*",
                  "~/Library/Developer/CoreSimulator/Caches/*",
                  "~/Library/Containers/*/Data/Library/Caches/*",
                  "~/Library/Group Containers/*/Library/Caches/*",
                  "~/Library/Application Support/*/Cache/*",
                  "~/Library/Application Support/*/Code Cache/*",
                  "~/Library/Application Support/*/Service Worker/CacheStorage/*",
                  "~/Library/Application Support/Code/CachedData/*",
                  "~/Library/Application Support/Spotify/PersistentCache/*",
                  "~/Library/Application Support/Adobe/Common/Media Cache Files/*",
                  "~/Library/Containers/com.docker.docker/Data/log/*",
                  // 具体列名放行的非缓存清理项（与 definitions.json 同步）
                  "~/Library/Application Support/MobileSync/Backup/*",
                  "~/Library/iTunes/iPhone Software Updates/*",
                  "~/Library/iTunes/iPad Software Updates/*",
                  "~/Library/Containers/com.apple.mail/Data/Library/Mail Downloads/*",
                  "~/Library/Application Support/zoom.us/AutoDownload/*",
                  "~/Library/Application Support/*/blob_storage/*"] {
            XCTAssertTrue(DefinitionPathPolicy.isAllowed(path: p, requiresHelper: false),
                          "合法可清理 Library 子树应被摄入期放行: \(p)")
        }
    }

    /// 每一条内置规则库路径都必须仍能通过收紧后的摄入期策略——否则其在线目录更新会被整条拒收。
    func testEveryBundledPathStillPassesIngestPolicy() {
        let lib = DefinitionsLibrary.bundled()
        XCTAssertFalse(lib.definitions.isEmpty)
        for def in lib.definitions {
            for path in def.paths {
                // 少数点目录缓存项（~/.pnpm-store、~/.sbt/boot、~/.nuget/packages）本就不在摄入白名单内，
                // 属既有行为（本轮未触及 isAllowedDotCache），此处只校验 ~/Library 类路径不被本轮收紧误伤。
                guard path.hasPrefix("~/Library") || path.hasPrefix("/Library") || path.hasPrefix("/private/var/log") else { continue }
                XCTAssertTrue(DefinitionPathPolicy.isAllowed(path: path, requiresHelper: def.requiresHelper),
                              "规则 \(def.id) 的路径被收紧后的摄入期误拒: \(path)")
            }
        }
    }

    // MARK: - B. 删除期红线：凭证目录对任意用户均拒（home 无关）

    func testRedlineDeniesCredentialDotdirsForArbitraryUser() {
        // 不注入 home——纯 home 无关红线；断言任意用户 /Users/<x> 下凭证目录均被拒。
        let rules = XicoSafetyRules()
        for p in ["/Users/alice/.aws/credentials",
                  "/Users/bob/.kube/config",
                  "/Users/carol/.docker/config.json",
                  "/Users/dave/.azure/accessTokens.json",
                  "/Users/erin/.gcloud/credentials.db",
                  "/Users/frank/.config/gcloud/credentials.db",
                  "/Users/grace/.oci/config",
                  "/Users/heidi/.terraform.d/credentials.tfrc.json",
                  "/Users/ivan/.ssh/id_ed25519",
                  "/Users/judy/.gnupg/secring.gpg",
                  "/Users/mallory/.netrc"] {
            XCTAssertNotNil(rules.denyReason(for: url(p)),
                            "任意用户凭证/密钥目录必须被红线拒绝: \(p)")
        }
    }

    /// 反向：任意用户主目录下的合法缓存清理不被新增的凭证红线误伤（.config 非 gcloud 子树、XDG 缓存、
    /// Library/Caches 等仍放行）——确保收紧未过度、未误伤合法清理。
    func testRedlineStillAllowsArbitraryUserCacheCleanup() {
        let rules = XicoSafetyRules()
        for p in ["/Users/alice/.cache/foo/blob",
                  "/Users/bob/.config/some-app/settings.json",   // .config 非 gcloud → 不属凭证目录
                  "/Users/carol/Library/Caches/com.foo/Cache.db"] {
            XCTAssertNil(rules.denyReason(for: url(p)),
                         "合法缓存路径不应被红线拒绝: \(p)")
        }
    }
}
