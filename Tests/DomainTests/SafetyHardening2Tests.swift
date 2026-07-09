import XCTest
@testable import Domain

/// 对抗复核第 2 轮安全加固回归（2026-07）：
///  A. 定义摄入期（DefinitionPathPolicy）——裸 `~/.` 前缀收紧：凭证/密钥点目录一律拒，
///     仅缓存点目录放行；
///  B. 删除期红线（DefaultSafetyEngine.verify）——凭证/密钥/云配置点目录任何 intent 均拒；
///  C. 既有合法缓存点目录不被误伤（未过度收紧）。
final class SafetyHardening2Tests: XCTestCase {

    let home = URL(fileURLWithPath: "/Users/tester")
    var engine: DefaultSafetyEngine!

    override func setUp() {
        super.setUp()
        engine = DefaultSafetyEngine(home: home)
    }

    func url(_ p: String) -> URL { URL(fileURLWithPath: p) }

    // MARK: - A. 摄入期：凭证点目录被拒（此前 "~/." 会误放行）

    func testDefinitionIngestRejectsCredentialDotdirs() {
        // 核心回归：一条普通定义若把删除目标指向凭证/密钥/云配置点目录，摄入期必须整条拒绝。
        for p in ["~/.aws/credentials",
                  "~/.aws",
                  "~/.ssh/id_rsa",
                  "~/.gnupg/secring.gpg",
                  "~/.kube/config",
                  "~/.docker/config.json",
                  "~/.azure/accessTokens.json",
                  "~/.gcloud/credentials.db",
                  "~/.config/gcloud/credentials.db",
                  "~/.oci/config",
                  "~/.terraform.d/credentials.tfrc.json"] {
            XCTAssertFalse(DefinitionPathPolicy.isAllowed(path: p, requiresHelper: false),
                           "凭证/密钥定义路径必须被摄入期拒绝: \(p)")
        }
    }

    // MARK: - B. 摄入期：合法缓存点目录仍放行（未过度收紧）

    func testDefinitionIngestStillAllowsCacheDotdirs() {
        for p in ["~/.cache/*",
                  "~/.npm/_cacache",
                  "~/.yarn/cache",
                  "~/.gradle/caches/modules-2",
                  "~/.cargo/registry/cache/foo",
                  "~/.config/some-app/Caches/blob"] {  // .config 下确含 cache 分量 → 视为可重建缓存
            XCTAssertTrue(DefinitionPathPolicy.isAllowed(path: p, requiresHelper: false),
                          "缓存点目录应被摄入期放行: \(p)")
        }
    }

    func testDefinitionIngestRejectsNonCacheConfigTree() {
        // ~/.config 下非缓存子树（不含 cache 分量）不再被裸 "~/." 放行。
        XCTAssertFalse(DefinitionPathPolicy.isAllowed(path: "~/.config/app/settings.json",
                                                      requiresHelper: false),
                       "~/.config 非缓存子树不应放行")
    }

    // MARK: - C. 删除期红线：凭证点目录任何 intent 均拒

    func testDeleteRedlineDeniesCredentialDotdirsBothIntents() {
        for p in ["/Users/tester/.aws/credentials",
                  "/Users/tester/.kube/config",
                  "/Users/tester/.docker/config.json",
                  "/Users/tester/.azure/accessTokens.json",
                  "/Users/tester/.gcloud/credentials.db",
                  "/Users/tester/.config/gcloud/credentials.db",
                  "/Users/tester/.oci/config",
                  "/Users/tester/.terraform.d/credentials.tfrc.json"] {
            XCTAssertFalse(engine.verify(url(p), intent: .trash).isAllowed,
                           "凭证目录移入废纸篓也应拒: \(p)")
            XCTAssertFalse(engine.verify(url(p), intent: .permanent).isAllowed,
                           "凭证目录彻底删除必须拒: \(p)")
        }
    }

    func testDeleteRedlineStillAllowsCacheCleanup() {
        // 删除期不误伤合法缓存清理（.config 下缓存、XDG 缓存等仍可移入废纸篓）。
        for p in ["/Users/tester/.cache/foo/blob",
                  "/Users/tester/.config/app/Cache/x",
                  "/Users/tester/Library/Caches/com.foo/Cache.db"] {
            XCTAssertTrue(engine.verify(url(p), intent: .trash).isAllowed,
                          "合法缓存清理不应被凭证红线误伤: \(p)")
        }
    }
}
