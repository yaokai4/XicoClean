import XCTest
@testable import Domain

/// 验证：全部模块失败时 scanAll 抛错（绝不把失败静默成空结果伪装「很干净」）；
/// 部分成功时返回部分结果。
final class ScanCoordinatorTests: XCTestCase {

    struct FailingScanner: ScannerModule {
        let metadata: ModuleMetadata
        struct Boom: Error {}
        func scan(progress: @escaping ProgressHandler) async throws -> ScanResult { throw Boom() }
    }
    struct OKScanner: ScannerModule {
        let metadata: ModuleMetadata
        func scan(progress: @escaping ProgressHandler) async throws -> ScanResult {
            ScanResult(moduleID: metadata.id, groups: [
                ScanResultGroup(id: "g", title: "t", items: [
                    CleanableItem(url: URL(fileURLWithPath: "/tmp/x"), displayName: "x", size: 10)
                ])
            ])
        }
    }

    private func meta(_ id: String) -> ModuleMetadata {
        ModuleMetadata(id: ModuleID(id), title: id, subtitle: "", systemImage: "x", category: .cleanup)
    }

    func testAllFailingThrows() async {
        let coord = ScanCoordinator(modules: [FailingScanner(metadata: meta("a")),
                                              FailingScanner(metadata: meta("b"))])
        do {
            _ = try await coord.scanAll()
            XCTFail("全部失败时应抛错，而不是返回空结果")
        } catch {
            // 预期抛错
        }
    }

    func testPartialSuccessReturnsResults() async throws {
        let coord = ScanCoordinator(modules: [FailingScanner(metadata: meta("a")),
                                              OKScanner(metadata: meta("b"))])
        let results = try await coord.scanAll()
        XCTAssertEqual(results.count, 1, "部分成功应返回成功模块的结果")
    }
}
