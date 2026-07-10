import XCTest
@testable import Infrastructure
import Domain

/// 空间透镜扫描的**尺寸真相**测试——512GB 盘扫出 1.79TB 事故的回归防线。
/// 口径基准：物理已分配字节、硬链接只计一次、符号链接不跟随、挂载点不跨入（与 `du` 一致）。
final class DiskScanAccuracyTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("xico-scan-accuracy-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
    }

    private func write(_ bytes: Int, to name: String, in dir: URL? = nil) throws -> URL {
        let url = (dir ?? tempDir!).appendingPathComponent(name)
        // 随机数据抗透明压缩——全零文件在 APFS 上可能被压到几乎不占空间，抹掉被测差异。
        var data = Data(capacity: bytes)
        var rng = SystemRandomNumberGenerator()
        while data.count < bytes {
            data.append(contentsOf: withUnsafeBytes(of: rng.next()) { Array($0) })
        }
        try data.write(to: url)
        return url
    }

    private func scan(_ url: URL) async -> DiskNode {
        await DiskTreeScanner(fs: LocalFileSystemService()).scan(url)
    }

    /// 硬链接：同一份数据的两个目录项只计一次。
    func testHardLinksCountedOnce() async throws {
        let original = try write(4 << 20, to: "original.bin")
        try FileManager.default.linkItem(at: original,
                                         to: tempDir.appendingPathComponent("hardlink.bin"))
        let tree = await scan(tempDir)
        XCTAssertGreaterThanOrEqual(tree.size, 4 << 20)
        XCTAssertLessThan(tree.size, 5 << 20, "硬链接被重复计数")
    }

    /// 符号链接：绝不跟随——链接指向的目录内容不得再计一遍。
    func testSymlinkNotFollowed() async throws {
        let sub = tempDir.appendingPathComponent("real")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        _ = try write(10 << 20, to: "payload.bin", in: sub)
        try FileManager.default.createSymbolicLink(
            at: tempDir.appendingPathComponent("alias"),
            withDestinationURL: sub)
        let tree = await scan(tempDir)
        XCTAssertGreaterThanOrEqual(tree.size, 10 << 20)
        XCTAssertLessThan(tree.size, 11 << 20, "符号链接被当目录跟进去了")
    }

    /// 稀疏文件：按物理已分配字节计，不按逻辑长度（Docker.raw/模拟器镜像的口径关键）。
    func testSparseFileUsesPhysicalSize() async throws {
        let url = tempDir.appendingPathComponent("sparse.bin")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        try handle.seek(toOffset: 100 << 20)   // 逻辑 100MB
        try handle.write(contentsOf: Data([1]))
        try handle.close()
        let tree = await scan(tempDir)
        XCTAssertLessThan(tree.size, 5 << 20, "稀疏文件被按逻辑大小计数")
    }

    /// maxDepth 之下的深层内容也必须精确入账（旧实现深层走逐文件枚举、极慢且可被取消截断）。
    func testDeepTreeCountsFully() async throws {
        var dir = tempDir!
        for i in 0..<10 {
            dir = dir.appendingPathComponent("level\(i)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        _ = try write(3 << 20, to: "deep.bin", in: dir)
        let tree = await scan(tempDir)
        XCTAssertGreaterThanOrEqual(tree.size, 3 << 20, "深层文件未被计入")
        XCTAssertLessThan(tree.size, 4 << 20)
    }

    /// 整盘扫描的总量红线：可见明细绝不能超过卷已用量（512GB 盘扫出 1.79TB 的直接回归线——
    /// firmlink/挂载点重复计数、/.nofollow 魔法目录、符号链接跟随任何一个复发都会立刻打爆此线）。
    /// 门控实测：设 XICO_WHOLE_DISK_AUDIT=1 才跑（全盘扫描分钟级，CI 跳过）。
    func testWholeDiskScanDoesNotOvercount() async throws {
        guard ProcessInfo.processInfo.environment["XICO_WHOLE_DISK_AUDIT"] == "1" else {
            throw XCTSkip("未设置 XICO_WHOLE_DISK_AUDIT=1，跳过整盘实测")
        }
        let root = URL(fileURLWithPath: "/")
        let fs = LocalFileSystemService()
        let tree = await DiskTreeScanner(fs: fs).scan(root)

        let cap = try XCTUnwrap(fs.volumeCapacity(for: root))
        let used = cap.total - cap.available
        // 可见明细 = 总量减去「隐藏空间」补差段（若有）。
        let hidden = tree.children.first { $0.name == "隐藏空间" }?.size ?? 0
        let visible = tree.size - hidden

        let fmt = ByteCountFormatter()
        print("[整盘审计] 卷已用 \(fmt.string(fromByteCount: used)) · 可见明细 \(fmt.string(fromByteCount: visible)) · 隐藏空间 \(fmt.string(fromByteCount: hidden)) · 顶层 \(tree.children.map { "\($0.name)=\(fmt.string(fromByteCount: $0.size))" }.joined(separator: " "))")
        // APFS 克隆会带来少量合理高估，放 10% 余量；1.79TB 级别的重复计数是 4.6 倍，绝无逃逸。
        XCTAssertLessThan(visible, Int64(Double(used) * 1.10),
                          "可见明细 \(visible) 超过卷已用 \(used)——存在重复计数")
        XCTAssertGreaterThan(visible, used / 10, "可见明细异常偏小，扫描疑似未生效")
        // 魔法目录与挂载点绝不可成为可见子节点。
        let names = Set(tree.children.map(\.name))
        for banned in [".nofollow", ".vol", ".resolve"] {
            XCTAssertFalse(names.contains(banned), "\(banned) 不应出现在扫描结果里")
        }
    }

    /// 与 `du -sk` 对账（口径相同：物理占用、硬链接一次、不跟链接、不跨挂载点）。
    /// 门控实测：设 XICO_DU_AUDIT_PATH 指向一个稳定目录时才跑（家目录实盘核对用，CI 跳过）。
    func testAgreesWithDu() async throws {
        guard let path = ProcessInfo.processInfo.environment["XICO_DU_AUDIT_PATH"] else {
            throw XCTSkip("未设置 XICO_DU_AUDIT_PATH，跳过实盘对账")
        }
        let url = URL(fileURLWithPath: path)
        let tree = await scan(url)

        let du = Process()
        du.executableURL = URL(fileURLWithPath: "/usr/bin/du")
        // -H：跟随命令行参数上的符号链接（扫描器对根路径做 realpath，同口径）；遍历中依旧不跟链接。
        du.arguments = ["-skH", path]
        let pipe = Pipe()
        du.standardOutput = pipe
        du.standardError = Pipe()
        try du.run()
        du.waitUntilExit()
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let duBytes = Int64(out.split(separator: "\t").first.flatMap { Int($0) } ?? 0) * 1024
        XCTAssertGreaterThan(duBytes, 0)

        let deviation = abs(Double(tree.size - duBytes)) / Double(max(duBytes, 1))
        XCTAssertLessThan(deviation, 0.05,
                          "与 du 偏差 \(Int(deviation * 100))%：scanner=\(tree.size) du=\(duBytes)")
    }
}
