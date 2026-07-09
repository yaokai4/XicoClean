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
    struct FixedScanner: ScannerModule {
        let metadata: ModuleMetadata
        let url: URL
        let safety: SafetyLevel
        func scan(progress: @escaping ProgressHandler) async throws -> ScanResult {
            ScanResult(moduleID: metadata.id, groups: [
                ScanResultGroup(id: metadata.id.rawValue, title: metadata.title, items: [
                    CleanableItem(url: url, displayName: url.lastPathComponent, size: 10, safety: safety)
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

    func testOverlappingPathsKeepParentSuperset() async throws {
        // 真父子重叠：保留父级超集（涵盖整棵子树的可回收字节），子项被覆盖跳过——
        // 否则丢父保子会少算/少清可回收空间（审计 P2）。删除期仍逐项过 SafetyEngine 红线。
        let parent = URL(fileURLWithPath: "/tmp/Xico/Cache")
        let child = URL(fileURLWithPath: "/tmp/Xico/Cache/Browser")
        let coord = ScanCoordinator(modules: [
            FixedScanner(metadata: meta("parent"), url: parent, safety: .safe),
            FixedScanner(metadata: meta("child"), url: child, safety: .caution)
        ])

        let paths = try await coord.scanAll().flatMap { $0.groups }.flatMap { $0.items }.map(\.url.path)
        XCTAssertEqual(paths, [parent.path], "父子重叠应保留父超集，避免少算/少清")
    }
}
