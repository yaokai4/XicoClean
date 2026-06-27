import XCTest
@testable import Domain

/// 安全回归测试 —— 发版红线：保护路径必须一律被拒。
final class SafetyEngineTests: XCTestCase {

    let home = URL(fileURLWithPath: "/Users/tester")
    var engine: DefaultSafetyEngine!

    override func setUp() {
        super.setUp()
        engine = DefaultSafetyEngine(home: home)
    }

    func url(_ p: String) -> URL { URL(fileURLWithPath: p) }

    // MARK: - 必须拒绝

    func testDeniesRootDirectory() {
        XCTAssertFalse(engine.verify(url("/"), intent: .trash).isAllowed)
    }

    func testDeniesSystemSubtree() {
        XCTAssertFalse(engine.verify(url("/System/Library/Caches/foo"), intent: .trash).isAllowed)
    }

    func testDeniesUsrBin() {
        XCTAssertFalse(engine.verify(url("/usr/bin/swift"), intent: .trash).isAllowed)
    }

    func testDeniesBinAndSbin() {
        XCTAssertFalse(engine.verify(url("/bin/ls"), intent: .trash).isAllowed)
        XCTAssertFalse(engine.verify(url("/sbin/fsck"), intent: .trash).isAllowed)
    }

    func testDeniesHomeItself() {
        XCTAssertFalse(engine.verify(home, intent: .trash).isAllowed)
    }

    func testDeniesUserContentFoldersThemselves() {
        // 这些文件夹本身不可删除
        XCTAssertFalse(engine.verify(url("/Users/tester/Documents"), intent: .trash).isAllowed)
        XCTAssertFalse(engine.verify(url("/Users/tester/Desktop"), intent: .trash).isAllowed)
        XCTAssertFalse(engine.verify(url("/Users/tester/Pictures"), intent: .trash).isAllowed)
        XCTAssertFalse(engine.verify(url("/Users/tester/Movies"), intent: .trash).isAllowed)
        XCTAssertFalse(engine.verify(url("/Users/tester/Music"), intent: .trash).isAllowed)
    }

    func testAllowsUserSelectedFilesInsideContentFolders() {
        // 用户在大文件/重复文件中显式选择的文件可移入废纸篓（可恢复）
        XCTAssertTrue(engine.verify(url("/Users/tester/Documents/old-draft.pages"), intent: .trash).isAllowed)
        XCTAssertTrue(engine.verify(url("/Users/tester/Movies/huge-render.mov"), intent: .trash).isAllowed)
        XCTAssertTrue(engine.verify(url("/Users/tester/Pictures/dup-copy.heic"), intent: .trash).isAllowed)
    }

    func testDeniesKeychains() {
        XCTAssertFalse(engine.verify(url("/Users/tester/Library/Keychains/login.keychain-db"), intent: .trash).isAllowed)
    }

    func testDeniesLibraryRootItself() {
        XCTAssertFalse(engine.verify(url("/Users/tester/Library"), intent: .trash).isAllowed)
    }

    func testDeniesVolumeMountRoot() {
        XCTAssertFalse(engine.verify(url("/Volumes/External"), intent: .trash).isAllowed)
    }

    func testDeniesApplicationsRoot() {
        XCTAssertFalse(engine.verify(url("/Applications"), intent: .trash).isAllowed)
    }

    func testDeniesPathTraversal() {
        let comps = ["/", "Users", "tester", "Library", "Caches", "..", "..", "Documents"]
        var u = URL(fileURLWithPath: "/")
        for c in comps where c != "/" { u.appendPathComponent(c) }
        // 注意：standardized 会消解 ".."，因此即使消解后落入受保护区也应被拒
        XCTAssertFalse(engine.verify(u, intent: .trash).isAllowed)
    }

    // MARK: - 应当放行

    func testAllowsUserCacheItem() {
        XCTAssertTrue(engine.verify(url("/Users/tester/Library/Caches/com.foo.bar/Cache.db"), intent: .trash).isAllowed)
    }

    func testAllowsUserLogItem() {
        XCTAssertTrue(engine.verify(url("/Users/tester/Library/Logs/foo.log"), intent: .trash).isAllowed)
    }

    func testAllowsUsrLocalException() {
        XCTAssertTrue(engine.verify(url("/usr/local/Cellar/foo/old"), intent: .trash).isAllowed)
    }

    func testAllowsItemInsideDownloads() {
        // Downloads 根受保护，但其中的具体文件可清理
        XCTAssertTrue(engine.verify(url("/Users/tester/Downloads/old-installer.dmg"), intent: .trash).isAllowed)
    }

    func testAllowsDerivedData() {
        XCTAssertTrue(engine.verify(url("/Users/tester/Library/Developer/Xcode/DerivedData/App-abc/Build"), intent: .trash).isAllowed)
    }

    // MARK: - 对抗向量（上线红线必过）

    /// symlink 逃逸：一个指向受保护区的真实符号链接，解析后必须仍被拒
    func testDeniesSymlinkEscapingToProtectedArea() throws {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }

        let link = tmp.appendingPathComponent("evil-link")
        try fm.createSymbolicLink(at: link, withDestinationURL: URL(fileURLWithPath: "/System/Library/Caches"))
        XCTAssertFalse(engine.verify(link, intent: .trash).isAllowed,
                       "指向受保护区的符号链接应在解析后被拒")
    }

    /// 大小写绕过：大小写不敏感卷上 /SYSTEM 与 /System 等价，必须拒
    func testDeniesCaseInsensitiveBypass() {
        XCTAssertFalse(engine.verify(url("/SYSTEM/Library/Caches/foo"), intent: .trash).isAllowed)
        XCTAssertFalse(engine.verify(url("/Users/tester/LIBRARY"), intent: .trash).isAllowed)
        XCTAssertFalse(engine.verify(url("/users/tester/documents"), intent: .trash).isAllowed)
    }

    /// 尾斜杠不应改变判定
    func testTrailingSlashStillDenied() {
        XCTAssertFalse(engine.verify(url("/System/"), intent: .trash).isAllowed)
        XCTAssertFalse(engine.verify(url("/Users/tester/Library/"), intent: .trash).isAllowed)
    }

    /// 跨用户保护：即使引擎注入的是 tester 的 home，其他用户的敏感目录同样必须拒
    func testDeniesOtherUsersSensitiveDirs() {
        XCTAssertFalse(engine.verify(url("/Users/alice/Documents"), intent: .trash).isAllowed)
        XCTAssertFalse(engine.verify(url("/Users/alice"), intent: .trash).isAllowed)
        XCTAssertFalse(engine.verify(url("/Users/bob/Library/Keychains/login.keychain-db"), intent: .trash).isAllowed)
        XCTAssertFalse(engine.verify(url("/Users/bob/.ssh"), intent: .trash).isAllowed)
    }
}
