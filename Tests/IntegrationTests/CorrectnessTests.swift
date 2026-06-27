import XCTest
@testable import Infrastructure
import Domain

/// Wave B 正确性回归：重复文件全量哈希防误判、PathExpander 多段 glob。
final class CorrectnessTests: XCTestCase {

    private var tmp: URL!
    private let fs = LocalFileSystemService()

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent("xico-correctness-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    // MARK: 重复文件——头尾相同、中段不同者绝不能被判为重复（否则会删错）

    func testDuplicatesRequireFullContentMatch() async throws {
        let mb = 2 * 1024 * 1024
        let head = Data(repeating: 0x41, count: 16 * 1024)
        let tail = Data(repeating: 0x41, count: 16 * 1024)
        let same = Data(repeating: 0x41, count: mb)
        // file3：头尾与 same 一致，但中段是 0x42 —— 部分哈希会撞，全量哈希必须区分
        var tricky = Data()
        tricky.append(head)
        tricky.append(Data(repeating: 0x42, count: mb - 32 * 1024))
        tricky.append(tail)

        try same.write(to: tmp.appendingPathComponent("a.bin"))
        try same.write(to: tmp.appendingPathComponent("b.bin"))
        try tricky.write(to: tmp.appendingPathComponent("c.bin"))

        let scanner = DuplicatesScanner(fs: fs, safety: DefaultSafetyEngine(home: tmp), root: tmp)
        let result = await scanner.scan { _ in }

        XCTAssertEqual(result.groups.count, 1, "只应有 a/b 一组真重复，c 因中段不同必须被排除")
        XCTAssertEqual(result.groups.first?.items.count, 2, "重复组应恰含 a、b 两份")
        let names = Set(result.groups.first?.items.map { $0.url.lastPathComponent } ?? [])
        XCTAssertFalse(names.contains("c.bin"), "中段不同的 c.bin 绝不能被判为重复")
    }

    // MARK: PathExpander——中段通配与前缀通配都要能展开

    func testPathExpanderMultiSegmentGlob() throws {
        let fm = FileManager.default
        // tmp/AppOne/Data/Caches/x.txt, tmp/AppTwo/Data/Caches/y.txt
        for app in ["AppOne", "AppTwo"] {
            let dir = tmp.appendingPathComponent("\(app)/Data/Caches")
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            try Data("x".utf8).write(to: dir.appendingPathComponent("\(app).txt"))
        }
        let mid = PathExpander.expand(tmp.path + "/*/Data/Caches/*", home: tmp, fs: fs)
        XCTAssertEqual(mid.count, 2, "中段通配应展开两个 App 的缓存文件")

        let prefix = PathExpander.expand(tmp.path + "/App*", home: tmp, fs: fs)
        XCTAssertEqual(prefix.count, 2, "前缀通配 App* 应匹配 AppOne / AppTwo")

        let exact = PathExpander.expand(tmp.path + "/AppOne/Data", home: tmp, fs: fs)
        XCTAssertEqual(exact.count, 1, "无通配的存在路径应返回其本身")

        let missing = PathExpander.expand(tmp.path + "/Nope/*", home: tmp, fs: fs)
        XCTAssertTrue(missing.isEmpty, "不存在的路径应返回空")
    }
}
