import XCTest
@testable import Domain

/// 安全红线加固回归（2026-07 审计修复）：
///  A. `.permanent` 在家目录内默认拒绝——非白名单位置（如 ~/Library/Application Support）必被拒；
///  B. 既有可重建缓存/垃圾路径仍照常放行（未误伤合法清理）；
///  C. 规则库摄入期路径形状校验（DefinitionPathPolicy）挡下逃逸路径。
final class SafetyHardeningTests: XCTestCase {

    let home = URL(fileURLWithPath: "/Users/tester")
    var engine: DefaultSafetyEngine!

    override func setUp() {
        super.setUp()
        engine = DefaultSafetyEngine(home: home)
    }

    func url(_ p: String) -> URL { URL(fileURLWithPath: p) }

    // MARK: - A. permanent 默认拒绝（家目录内非白名单）

    func testPermanentDeniedForApplicationSupport() {
        // 红线核心断言：彻底删除 ~/Library/Application Support 下的应用数据必须被拒（不可逆）。
        XCTAssertFalse(engine.verify(url("/Users/tester/Library/Application Support/foo/data.db"),
                                     intent: .permanent).isAllowed,
                       "彻底删除应用数据必须被拒")
        // 但同一路径移入废纸篓（可恢复）仍允许——不误伤合法的应用缓存清理。
        XCTAssertTrue(engine.verify(url("/Users/tester/Library/Application Support/foo/data.db"),
                                    intent: .trash).isAllowed,
                      "移入废纸篓应放行")
    }

    func testPermanentDeniedForOtherHomeLocations() {
        // 家目录内其它非白名单位置（点文件配置、容器数据等）彻底删除同样默认拒绝。
        for p in ["/Users/tester/.config/app/settings.json",
                  "/Users/tester/Library/Containers/com.app/Data/Documents/keep.txt",
                  "/Users/tester/Library/Preferences/com.app.plist"] {
            XCTAssertFalse(engine.verify(url(p), intent: .permanent).isAllowed,
                           "permanent 应默认拒绝: \(p)")
        }
    }

    // MARK: - B. 既有缓存/垃圾路径仍放行

    func testPermanentStillAllowedForRebuildableJunk() {
        // 可无损重建的缓存/日志/废纸篓白名单——彻底删除仍放行（清空废纸篓、缓存 shred）。
        for p in ["/Users/tester/Library/Caches/com.foo.bar/Cache.db",
                  "/Users/tester/Library/Logs/foo.log",
                  "/Users/tester/.Trash/old-installer.dmg",
                  "/Users/tester/.cache/some/blob",
                  "/Users/tester/Library/Developer/Xcode/DerivedData/App-abc/Build"] {
            XCTAssertTrue(engine.verify(url(p), intent: .permanent).isAllowed,
                          "白名单垃圾 permanent 应放行: \(p)")
            XCTAssertTrue(engine.verify(url(p), intent: .trash).isAllowed,
                          "白名单垃圾 trash 应放行: \(p)")
        }
    }

    func testTrashStillAllowedForAppCaches() {
        // 常规清理（.trash）对 Application Support 缓存子项不受新红线影响。
        XCTAssertTrue(engine.verify(url("/Users/tester/Library/Application Support/Slack/Cache/x"),
                                    intent: .trash).isAllowed)
    }

    // MARK: - C. 定义摄入期路径形状校验

    func testDefinitionPathPolicyAcceptsLegitPaths() {
        XCTAssertTrue(DefinitionPathPolicy.isAllowed(path: "~/Library/Caches/*", requiresHelper: false))
        XCTAssertTrue(DefinitionPathPolicy.isAllowed(path: "~/Library/Logs/*", requiresHelper: false))
        XCTAssertTrue(DefinitionPathPolicy.isAllowed(path: "~/.cache/*", requiresHelper: false))
        XCTAssertTrue(DefinitionPathPolicy.isAllowed(path: "~/.npm/_cacache", requiresHelper: false))
        // requiresHelper 定义命中系统白名单根。
        XCTAssertTrue(DefinitionPathPolicy.isAllowed(path: "/Library/Caches/*", requiresHelper: true))
        XCTAssertTrue(DefinitionPathPolicy.isAllowed(path: "/private/var/log/*", requiresHelper: true))
    }

    func testDefinitionPathPolicyRejectsEscapingPaths() {
        // 逃逸出预期前缀集 → 拒绝。
        XCTAssertFalse(DefinitionPathPolicy.isAllowed(path: "~/Documents/secret/*", requiresHelper: false))
        XCTAssertFalse(DefinitionPathPolicy.isAllowed(path: "/etc/passwd", requiresHelper: false))
        XCTAssertFalse(DefinitionPathPolicy.isAllowed(path: "/System/Library/Foo/*", requiresHelper: false))
        // 含上跳分量 → 拒绝。
        XCTAssertFalse(DefinitionPathPolicy.isAllowed(path: "~/Library/../.ssh", requiresHelper: false))
        // requiresHelper 却指向家目录（助手白名单外）→ 拒绝（fail-closed）。
        XCTAssertFalse(DefinitionPathPolicy.isAllowed(path: "~/Library/Caches/x", requiresHelper: true))
    }
}
