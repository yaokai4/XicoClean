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
}
