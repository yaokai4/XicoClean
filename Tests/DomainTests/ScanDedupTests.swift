import XCTest
@testable import Domain

/// 回归：跨模块父/子路径重叠去重时，必须保留**父级超集**——
/// 既不因「丢父保子」而少算可释放空间、漏清子树里的其它文件，
/// 也不因把父子都计入而重复计算、虚报总量。
/// 仅当路径完全相同时，才让更具体 / 更高风险的记录胜出，且只计一次。
final class ScanDedupTests: XCTestCase {

    /// 产出单个可清理项的测试扫描器（url + 大小 + 安全级可配）。
    struct FixedScanner: ScannerModule {
        let metadata: ModuleMetadata
        let url: URL
        let size: Int64
        let safety: SafetyLevel
        func scan(progress: @escaping ProgressHandler) async throws -> ScanResult {
            ScanResult(moduleID: metadata.id, groups: [
                ScanResultGroup(id: metadata.id.rawValue, title: metadata.title, items: [
                    CleanableItem(url: url, displayName: url.lastPathComponent, size: size, safety: safety)
                ])
            ])
        }
    }

    private func meta(_ id: String) -> ModuleMetadata {
        ModuleMetadata(id: ModuleID(id), title: id, subtitle: "", systemImage: "x", category: .cleanup)
    }

    /// 父模块命中整棵缓存目录（超集），子模块命中其下子目录（子集）：应保留父、剔除子。
    func testParentChildOverlapKeepsParentSuperset() async throws {
        let parent = URL(fileURLWithPath: "/tmp/Xico/Cache")
        let child = URL(fileURLWithPath: "/tmp/Xico/Cache/Browser")
        // 父级大小 = 整棵子树的可释放量；子级只是其中一块。
        let parentSize: Int64 = 1000
        let childSize: Int64 = 300
        let coord = ScanCoordinator(modules: [
            FixedScanner(metadata: meta("parent"), url: parent, size: parentSize, safety: .safe),
            FixedScanner(metadata: meta("child"), url: child, size: childSize, safety: .caution)
        ])

        let results = try await coord.scanAll()
        let items = results.flatMap { $0.groups }.flatMap { $0.items }

        // 只保留父级超集：子项被父覆盖而剔除。
        XCTAssertEqual(items.map(\.url.path), [parent.path], "父/子重叠应保留父超集，剔除子项")

        // 聚合可释放量 = 父级（1000）：不因保子而少算，也不因双计而虚报 1300。
        let totalReclaimable = results.reduce(Int64(0)) { $0 + $1.totalReclaimable }
        XCTAssertEqual(totalReclaimable, parentSize, "应按父超集计一次，既不少算也不重复计入")
    }

    /// 完全同路径（不同风险级）：仍应更高风险的记录胜出，且只计一次（不双计）。
    func testExactSamePathKeepsHigherRiskOnce() async throws {
        let path = URL(fileURLWithPath: "/tmp/Xico/Cache/dup")
        let coord = ScanCoordinator(modules: [
            FixedScanner(metadata: meta("safe"), url: path, size: 500, safety: .safe),
            FixedScanner(metadata: meta("risky"), url: path, size: 500, safety: .risky)
        ])

        let results = try await coord.scanAll()
        let items = results.flatMap { $0.groups }.flatMap { $0.items }
        XCTAssertEqual(items.count, 1, "完全同路径应只保留一条")
        XCTAssertEqual(items.first?.safety, .risky, "完全同路径应保留更高风险的记录")

        let total = results.reduce(Int64(0)) { $0 + $1.totalReclaimable }
        XCTAssertEqual(total, 500, "完全同路径不得重复计入")
    }
}
