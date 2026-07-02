import XCTest
import Domain
@testable import Infrastructure

final class ShredderServiceTests: XCTestCase {
    private var dir: URL!
    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("xico-shred-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    func testShredsFileAndReportsFreed() async throws {
        let f = dir.appendingPathComponent("secret.txt")
        try Data(repeating: 0x42, count: 4096).write(to: f)
        let svc = ShredderService(safety: DefaultSafetyEngine(), passes: 2)
        let result = await svc.shred([f])
        XCTAssertEqual(result.shredded, 1)
        XCTAssertTrue(result.failed.isEmpty)
        XCTAssertEqual(result.freedBytes, 4096)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.path), "粉碎后文件应不存在")
    }

    func testRefusesRedLinedTarget() async throws {
        // 受保护路径（系统区）绝不能被粉碎
        let svc = ShredderService(safety: DefaultSafetyEngine())
        let result = await svc.shred([URL(fileURLWithPath: "/System/Library/Xico-never")])
        XCTAssertEqual(result.shredded, 0)
        XCTAssertEqual(result.failed.count, 1)
    }

    /// 目录内的符号链接：只删链接本身，绝不跟随进入目标覆写/删除（对抗复核 P1）
    func testDoesNotFollowSymlinksIntoProtectedTargets() async throws {
        // 目标目录（模拟"受保护/珍贵"数据），放在 shred 目录之外
        let precious = FileManager.default.temporaryDirectory.appendingPathComponent("xico-precious-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: precious, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: precious) }
        let preciousFile = precious.appendingPathComponent("keep.txt")
        try Data("do-not-touch".utf8).write(to: preciousFile)

        // 待粉碎目录，内含一个指向 precious 的符号链接 + 一个普通文件
        let bag = dir.appendingPathComponent("bag")
        try FileManager.default.createDirectory(at: bag, withIntermediateDirectories: true)
        try Data(repeating: 0x7, count: 512).write(to: bag.appendingPathComponent("junk.bin"))
        try FileManager.default.createSymbolicLink(at: bag.appendingPathComponent("link"), withDestinationURL: precious)

        let svc = ShredderService(safety: DefaultSafetyEngine(), passes: 1)
        _ = await svc.shred([bag])

        // 链接目标内的真实数据必须完好无损、内容未被覆写
        XCTAssertTrue(FileManager.default.fileExists(atPath: preciousFile.path), "软链目标绝不能被粉碎穿透")
        XCTAssertEqual(try String(contentsOf: preciousFile, encoding: .utf8), "do-not-touch")
    }

    /// 用户自有内容目录（~/Documents 之类）内、显式选定的文件应可粉碎——
    /// 用注入 home 到临时目录来验证：内容目录内文件用 .trash 基础红线放行。
    func testShredsUserContentFileWithConfirmation() async throws {
        let injectedHome: URL = dir  // 把临时目录当作 home
        let docs = injectedHome.appendingPathComponent("Documents")
        try FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)
        let secret = docs.appendingPathComponent("tax.pdf")
        try Data(repeating: 0x9, count: 2048).write(to: secret)
        let svc = ShredderService(safety: DefaultSafetyEngine(home: injectedHome), passes: 1)
        let result = await svc.shred([secret])
        XCTAssertEqual(result.shredded, 1, "用户显式选定的自有内容文件应可粉碎")
        XCTAssertFalse(FileManager.default.fileExists(atPath: secret.path))
    }
}
