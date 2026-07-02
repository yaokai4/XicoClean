import XCTest
@testable import Shared

/// 特权助手红线测试：助手以 home 无关的 XicoSafetyRules 守护所有用户。
/// 这正是 XicoHelper.removeProtected 删除前所用的判定逻辑。
final class SafetyRulesTests: XCTestCase {

    /// 助手用的 home 无关规则
    let rules = XicoSafetyRules()

    func assertDenied(_ path: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertNotNil(rules.denyReason(for: URL(fileURLWithPath: path)), "应拒绝: \(path)", file: file, line: line)
    }
    func assertAllowed(_ path: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertNil(rules.denyReason(for: URL(fileURLWithPath: path)), "应放行: \(path)", file: file, line: line)
    }

    // MARK: 系统区（任何情况都不可删）

    func testDeniesSystemAreas() {
        assertDenied("/")
        assertDenied("/System/Library/Extensions/foo.kext")
        assertDenied("/usr/bin/swift")
        assertDenied("/bin/sh")
        assertDenied("/sbin/launchd")
        assertDenied("/Library/Apple/System/x")
        assertDenied("/private/var/db/dslocal/nodes/Default")
        assertDenied("/Applications")
        assertDenied("/Volumes")
        assertDenied("/Volumes/External")
    }

    /// 这些是 root 可删、SIP 不挡、删之会瘫系统的要害目录——助手红线必须拒
    func testDeniesRootCriticalAreas() {
        assertDenied("/Library/LaunchDaemons/com.evil.plist")
        assertDenied("/Library/LaunchAgents/x.plist")
        assertDenied("/Library/Extensions/foo.kext")
        assertDenied("/Library/Preferences/com.apple.x.plist")
        assertDenied("/Library/Security/foo")
        assertDenied("/Library/Keychains/System.keychain")
        assertDenied("/private/etc/sudoers")
        assertDenied("/private/var/db/sudo/x")
        assertDenied("/cores/core.123")
        assertDenied("/opt/homebrew/bin/brew")
    }

    /// 助手白名单：只允许这些系统级垃圾根
    func testHelperDeletableWhitelist() {
        XCTAssertTrue(XicoHelperSecurity.isUnderDeletableRoot("/Library/Caches/com.foo/x"))
        XCTAssertTrue(XicoHelperSecurity.isUnderDeletableRoot("/Library/Logs/foo.log"))
        XCTAssertTrue(XicoHelperSecurity.isUnderDeletableRoot("/private/var/log/system.log"))
        XCTAssertFalse(XicoHelperSecurity.isUnderDeletableRoot("/Library/LaunchDaemons/x.plist"))
        XCTAssertFalse(XicoHelperSecurity.isUnderDeletableRoot("/Users/alice/Documents"))
        XCTAssertFalse(XicoHelperSecurity.isUnderDeletableRoot("/Library/CachesEvil")) // 前缀粘连不算
    }

    func testTeamIdentifierConfigured() {
        XCTAssertTrue(XicoHelperSecurity.isTeamIdentifierConfigured, "应已设置真实 10 位 Team ID")
    }

    // MARK: 任意用户的敏感目录（助手不知发起方是谁，必须全部守住）

    func testDeniesAnyUserSensitiveDirs() {
        assertDenied("/Users")
        assertDenied("/Users/alice")
        assertDenied("/Users/alice/Documents")
        assertDenied("/Users/alice/Desktop")
        assertDenied("/Users/alice/Library")
        assertDenied("/Users/alice/Library/Keychains/login.keychain-db")
        assertDenied("/Users/bob/.ssh")
        assertDenied("/Users/bob/.gnupg/secring.gpg")
    }

    // MARK: 大小写 / 例外 / 放行

    func testCaseInsensitiveDeny() {
        assertDenied("/SYSTEM/Library/Caches/x")
        assertDenied("/USERS/alice/DOCUMENTS")
    }

    /// Unicode NFD/NFC 归一：同一目录名的分解/预组合两种形态都应命中红线。
    /// 说明：Swift 的 String == / Hashable 本身按 Unicode 规范等价比较，NFD 与 NFC 天然相等；
    /// canonicalLower 里额外做 precomposed(NFC) 归一是显式加固。此测试锁定该不变量。
    func testUnicodeNormalizationDeny() {
        let nfc = "José"                                    // 预组合
        let nfd = "Jose\u{0301}"                            // 分解（e + 组合重音）
        // 字节表示不同（utf8 长度不同），但语义等价
        XCTAssertNotEqual(Array(nfc.utf8), Array(nfd.utf8))
        let rules = XicoSafetyRules(home: URL(fileURLWithPath: "/Users/\(nfc)"))
        XCTAssertNotNil(rules.denyReason(for: URL(fileURLWithPath: "/Users/\(nfd)/Documents")))
        XCTAssertNotNil(rules.denyReason(for: URL(fileURLWithPath: "/Users/\(nfd)/Library/Mail/x")))
    }

    func testAllowsRealJunk() {
        assertAllowed("/Users/alice/Library/Caches/com.foo.bar/Cache.db")
        assertAllowed("/Users/alice/Library/Logs/foo.log")
        assertAllowed("/Users/alice/Downloads/old.dmg")
        assertAllowed("/usr/local/Cellar/foo/old")   // /usr/local 例外
        assertAllowed("/Library/Caches/com.foo/stale") // 系统级缓存（非 Apple 子树）
    }

    // MARK: 云同步 / 邮件 / 应用数据 / 图库包（2026-07 审计新增红线）

    /// 云同步目录整棵封死——删除会同步到云端与其它设备，废纸篓救不回远端（"产品死亡"级）
    func testDeniesCloudSyncSubtrees() {
        assertDenied("/Users/alice/Library/Mobile Documents")
        assertDenied("/Users/alice/Library/Mobile Documents/com~apple~CloudDocs/report.key")
        assertDenied("/Users/alice/Library/CloudStorage")
        assertDenied("/Users/alice/Library/CloudStorage/Dropbox/Work/secret.pdf")
        assertDenied("/Users/alice/Library/CloudStorage/OneDrive-Personal/x")
    }

    /// 邮件 / 信息——本地不可逆数据整棵封死
    func testDeniesMailMessages() {
        assertDenied("/Users/alice/Library/Mail")
        assertDenied("/Users/alice/Library/Mail/V10/inbox.mbox")
        assertDenied("/Users/alice/Library/Messages")
        assertDenied("/Users/alice/Library/Messages/chat.db")
    }

    /// iPhone 备份**不**红线（合法可清理项，靠 caution + 强确认保护），但备份根本身仍可清
    func testAllowsIPhoneBackupsForCleaning() {
        assertAllowed("/Users/alice/Library/Application Support/MobileSync/Backup/0000/Manifest.db")
    }

    /// 应用数据根 / 容器根 / 钥匙串目录**本身**不可删（防止一键删掉整个数据根）
    func testDeniesAppDataRootsThemselves() {
        assertDenied("/Users/alice/Library/Application Support")
        assertDenied("/Users/alice/Library/Group Containers")
        assertDenied("/Users/alice/Library/Containers")
        assertDenied("/Users/alice/Library/Keychains")
        assertDenied("/Users/alice/Library/Keychains/login.keychain-db")
    }

    /// 但精确定位的子项仍可删——卸载器与容器缓存清理的合法路径不能被误伤
    func testAllowsPreciseChildrenOfAppDataRoots() {
        assertAllowed("/Users/alice/Library/Application Support/com.foo.bar")
        assertAllowed("/Users/alice/Library/Application Support/Slack/Cache/x")
        assertAllowed("/Users/alice/Library/Group Containers/group.com.foo/x")
        assertAllowed("/Users/alice/Library/Containers/com.foo/Data/Library/Caches/Stale")
    }

    /// 图库包（照片/音乐/影片等 bundle）整体保护——任意位置，删包=图库全毁
    func testDeniesLibraryPackages() {
        assertDenied("/Users/alice/Pictures/Photos Library.photoslibrary")
        assertDenied("/Users/alice/Pictures/Photos Library.photoslibrary/database/Photos.sqlite")
        assertDenied("/Users/alice/Music/Music Library.musiclibrary")
        assertDenied("/Users/alice/Movies/iMovie Library.imovielibrary")
        assertDenied("/Volumes/External/Backup.photoslibrary")   // 外置卷上的图库同样保护
    }

    /// 注入 home（非 /Users 布局，如单测/迁移）同样守住上述子树
    func testInjectedHomeGuardsCloudAndAppData() {
        let injected = XicoSafetyRules(home: URL(fileURLWithPath: "/private/tmp/xico-tester"))
        XCTAssertNotNil(injected.denyReason(for: URL(fileURLWithPath: "/private/tmp/xico-tester/Library/Mobile Documents/x")))
        XCTAssertNotNil(injected.denyReason(for: URL(fileURLWithPath: "/private/tmp/xico-tester/Library/Application Support")))
        XCTAssertNil(injected.denyReason(for: URL(fileURLWithPath: "/private/tmp/xico-tester/Library/Application Support/com.foo/Cache")))
    }

    // MARK: 直接对已解析分量判定（不依赖文件系统）

    func testResolvedComponentsAPI() {
        XCTAssertNotNil(rules.denyReason(forResolvedComponents: ["/", "System"]))
        XCTAssertNotNil(rules.denyReason(forResolvedComponents: ["/", "Users", "alice"]))
        XCTAssertNil(rules.denyReason(forResolvedComponents: ["/", "Users", "alice", "Library", "Caches", "x"]))
    }
}
