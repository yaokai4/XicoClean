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

    func testAllowsRealJunk() {
        assertAllowed("/Users/alice/Library/Caches/com.foo.bar/Cache.db")
        assertAllowed("/Users/alice/Library/Logs/foo.log")
        assertAllowed("/Users/alice/Downloads/old.dmg")
        assertAllowed("/usr/local/Cellar/foo/old")   // /usr/local 例外
        assertAllowed("/Library/Caches/com.foo/stale") // 系统级缓存（非 Apple 子树）
    }

    // MARK: 直接对已解析分量判定（不依赖文件系统）

    func testResolvedComponentsAPI() {
        XCTAssertNotNil(rules.denyReason(forResolvedComponents: ["/", "System"]))
        XCTAssertNotNil(rules.denyReason(forResolvedComponents: ["/", "Users", "alice"]))
        XCTAssertNil(rules.denyReason(forResolvedComponents: ["/", "Users", "alice", "Library", "Caches", "x"]))
    }
}
