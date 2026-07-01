import XCTest
import Domain
@testable import Infrastructure

/// 相似图片扫描的集成测试：在临时目录放两张视觉相同的图 + 一张不同的，
/// 断言相同的两张被聚为一组、不同的那张不混入。用纯色 PNG（Vision 对纯色指纹稳定）。
final class SimilarImagesScannerTests: XCTestCase {

    private var dir: URL!
    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("xico-sim-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    func testGroupsVisuallyIdenticalImages() async throws {
        #if canImport(Vision)
        // 两张相同的红图 + 一张蓝图
        try writePNG(color: (255, 0, 0), to: dir.appendingPathComponent("red1.png"))
        try writePNG(color: (255, 0, 0), to: dir.appendingPathComponent("red2.png"))
        try writePNG(color: (0, 0, 255), to: dir.appendingPathComponent("blue.png"))

        let scanner = SimilarImagesScanner(fs: LocalFileSystemService(), safety: DefaultSafetyEngine(),
                                           roots: [dir], minSizeBytes: 1)
        let result = await scanner.scan { _ in }
        // 应恰好聚出一组（两张红图），蓝图不成组
        XCTAssertEqual(result.groups.count, 1, "两张相同的图应聚为一组，蓝图不混入")
        XCTAssertEqual(result.groups.first?.items.count, 2)
        #else
        throw XCTSkip("Vision 不可用")
        #endif
    }

    /// 写一张 64x64 纯色 PNG
    private func writePNG(color: (UInt8, UInt8, UInt8), to url: URL) throws {
        let w = 64, h = 64
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        for i in 0..<(w * h) {
            pixels[i*4] = color.0; pixels[i*4+1] = color.1; pixels[i*4+2] = color.2; pixels[i*4+3] = 255
        }
        let cs = CGColorSpaceCreateDeviceRGB()
        let ctx = CGContext(data: &pixels, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w*4,
                            space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let cg = ctx.makeImage()!
        let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, cg, nil)
        guard CGImageDestinationFinalize(dest) else { throw NSError(domain: "test", code: 1) }
    }
}
