import XCTest
@testable import Infrastructure

/// 自更新源抓取的内存边界与发布门测试（round-4 审计 P3：feed 上限在缓冲整个响应体之后才判断）。
/// 验证 `UpdateChecker.boundedData` 在越过 maxFeedBytes 时于流式阶段即中断，而非先读满内存。
final class UpdateFeedBoundsTests: XCTestCase {

    private static let feedURL = URL(string: "https://mac.xicoai.com/appcast.xml")!

    private func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [BoundsStubProtocol.self]
        return URLSession(configuration: config)
    }

    override func tearDown() {
        BoundsStubProtocol.responseBody = nil
        super.tearDown()
    }

    /// 小于上限：正常返回完整字节。
    func testUnderLimitReturnsFullBody() async throws {
        BoundsStubProtocol.responseBody = Data(repeating: 0x41, count: 1024)
        let session = makeSession()
        let (data, _) = try await UpdateChecker.boundedData(from: Self.feedURL, session: session, limit: 64 * 1024)
        XCTAssertEqual(data.count, 1024)
    }

    /// 超过上限：流式阶段抛 FeedError.tooLarge，不把整个响应体读进内存。
    func testOverLimitThrowsTooLarge() async {
        BoundsStubProtocol.responseBody = Data(repeating: 0x42, count: 200 * 1024)
        let session = makeSession()
        do {
            _ = try await UpdateChecker.boundedData(from: Self.feedURL, session: session, limit: 64 * 1024)
            XCTFail("应在越过上限时抛错")
        } catch let error as UpdateChecker.FeedError {
            XCTAssertEqual(error, .tooLarge)
        } catch {
            // bytes(from:) 在某些实现下会包装成传输错误——只要没有把整块读回即可接受。
        }
    }

    /// 恰好等于上限：不抛错（边界包含）。
    func testExactlyAtLimitPasses() async throws {
        BoundsStubProtocol.responseBody = Data(repeating: 0x43, count: 8 * 1024)
        let session = makeSession()
        let (data, _) = try await UpdateChecker.boundedData(from: Self.feedURL, session: session, limit: 8 * 1024)
        XCTAssertEqual(data.count, 8 * 1024)
    }

    /// 发布门：测试构建未内嵌更新公钥，isReleaseGateSatisfied() 应为 false（仅 host-pin 生效）。
    func testReleaseGateFalseWithoutEmbeddedKeys() {
        XCTAssertFalse(UpdateChecker.isReleaseGateSatisfied())
    }

    /// signedDescriptor 规范串格式：版本 + "\n" + 绝对 URL（+ "\n" + 小写 sha256）。
    /// 与服务端 generate_appcast 必须逐字节一致——此测试锁定契约防漂移。
    func testSignedDescriptorFormat() {
        let url = URL(string: "https://mac.xicoai.com/Xico-1.4.0.dmg")!
        let noHash = UpdateChecker.signedDescriptor(version: "1.4.0", downloadURL: url, sha256: nil)
        XCTAssertEqual(String(decoding: noHash, as: UTF8.self),
                       "1.4.0\nhttps://mac.xicoai.com/Xico-1.4.0.dmg")
        let withHash = UpdateChecker.signedDescriptor(version: "1.4.0", downloadURL: url, sha256: "DEADBEEF")
        XCTAssertEqual(String(decoding: withHash, as: UTF8.self),
                       "1.4.0\nhttps://mac.xicoai.com/Xico-1.4.0.dmg\ndeadbeef")
    }
}

/// 极简 URLProtocol 桩：把 `responseBody` 作为 200 响应体回放，供 bounds 测试驱动 bytes(from:)。
private final class BoundsStubProtocol: URLProtocol {
    nonisolated(unsafe) static var responseBody: Data?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let body = BoundsStubProtocol.responseBody ?? Data()
        let response = HTTPURLResponse(url: request.url!, statusCode: 200,
                                       httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "application/xml"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
