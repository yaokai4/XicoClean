import XCTest
@testable import Shared

/// 对全项目权限最高、后果最重的 root 递归删除核心（此前塞在 executableTarget 里无法测）
/// 做对抗性回归：符号链接必拒、只删链本身、递归、拒删白名单根、越界拒绝。
/// 全部在临时目录、以当前用户权限运行（HelperFileRemover 逻辑与 root 时完全一致）。
final class HelperFileRemoverTests: XCTestCase {

    private var root: URL!
    private var remover: HelperFileRemover!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        root = fm.temporaryDirectory.appendingPathComponent("xico-remover-" + UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        // 白名单根 = 临时目录（注入化，正是「可测」的关键）
        remover = HelperFileRemover(deletableRoots: [root.path])
    }
    override func tearDownWithError() throws { try? fm.removeItem(at: root) }

    func testDeletesFileUnderRoot() throws {
        let f = root.appendingPathComponent("junk.log")
        try Data("x".utf8).write(to: f)
        XCTAssertTrue(remover.safeRemove(f.path))
        XCTAssertFalse(fm.fileExists(atPath: f.path))
    }

    func testRecursivelyDeletesDirectory() throws {
        let dir = root.appendingPathComponent("cache")
        try fm.createDirectory(at: dir.appendingPathComponent("a/b"), withIntermediateDirectories: true)
        try Data("1".utf8).write(to: dir.appendingPathComponent("a/b/deep.bin"))
        try Data("2".utf8).write(to: dir.appendingPathComponent("top.bin"))
        XCTAssertTrue(remover.safeRemove(dir.path))
        XCTAssertFalse(fm.fileExists(atPath: dir.path))
    }

    func testRefusesToDeleteWhitelistRootItself() {
        XCTAssertFalse(remover.safeRemove(root.path), "绝不允许删除白名单根本身")
        XCTAssertTrue(fm.fileExists(atPath: root.path))
    }

    func testRefusesPathOutsideWhitelist() throws {
        let outside = fm.temporaryDirectory.appendingPathComponent("xico-outside-" + UUID().uuidString)
        try fm.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: outside) }
        let f = outside.appendingPathComponent("victim.txt")
        try Data("keep".utf8).write(to: f)
        XCTAssertFalse(remover.safeRemove(f.path), "白名单外路径必须拒绝")
        XCTAssertTrue(fm.fileExists(atPath: f.path), "白名单外文件绝不能被删")
    }

    /// 叶子是符号链接：只删链接本身，绝不跟随删除目标
    func testLeafSymlinkDeletesLinkNotTarget() throws {
        let targetDir = fm.temporaryDirectory.appendingPathComponent("xico-target-" + UUID().uuidString)
        try fm.createDirectory(at: targetDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: targetDir) }
        let precious = targetDir.appendingPathComponent("precious.txt")
        try Data("do-not-delete".utf8).write(to: precious)

        let link = root.appendingPathComponent("link")
        try fm.createSymbolicLink(at: link, withDestinationURL: targetDir)

        XCTAssertTrue(remover.safeRemove(link.path))
        XCTAssertFalse(fm.fileExists(atPath: link.path), "软链本身应被删除")
        XCTAssertTrue(fm.fileExists(atPath: precious.path), "软链指向的真实数据绝不能被删")
    }

    /// 中段目录被换成符号链接：openat(O_NOFOLLOW) 必拒，不会穿透到链接目标（防 TOCTOU 换链）
    func testMidPathSymlinkIsRefused() throws {
        let outside = fm.temporaryDirectory.appendingPathComponent("xico-evil-target-" + UUID().uuidString)
        try fm.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: outside) }
        let precious = outside.appendingPathComponent("precious.txt")
        try Data("keep".utf8).write(to: precious)

        // root/sub 是指向 outside 的符号链接；尝试删 root/sub/precious.txt
        let sub = root.appendingPathComponent("sub")
        try fm.createSymbolicLink(at: sub, withDestinationURL: outside)

        let attack = root.appendingPathComponent("sub/precious.txt").path
        XCTAssertFalse(remover.safeRemove(attack), "中段 symlink 必须被 openat(O_NOFOLLOW) 拒绝")
        XCTAssertTrue(fm.fileExists(atPath: precious.path), "链接目标内的数据绝不能被穿透删除")
    }

    func testPrefixGluePathIsNotUnderRoot() {
        // 前缀粘连不算「在根之下」：/tmp/xxx 与 /tmp/xxxEvil
        XCTAssertFalse(remover.isUnderDeletableRoot(root.path + "Evil/x"))
        XCTAssertTrue(remover.isUnderDeletableRoot(root.path + "/x"))
    }
}
