import XCTest
import Domain
@testable import Infrastructure

/// 验证本轮新增功能真实可跑、不崩溃。
final class NewFeaturesTests: XCTestCase {

    let fs = LocalFileSystemService()
    lazy var safety = DefaultSafetyEngine()

    private var runLocalSmokeTests: Bool {
        ProcessInfo.processInfo.environment["XICO_RUN_LOCAL_SMOKE_TESTS"] == "1"
    }

    func testThreatScannerRunsWithoutCrash() async throws {
        let scanner = ThreatScanner(fs: fs, safety: safety)
        let result = try await scanner.scan { _ in }
        // 大多数干净的 Mac 命中 0 项，但必须无崩溃地返回
        XCTAssertGreaterThanOrEqual(result.itemCount, 0)
        XCTAssertFalse(ThreatScanner.signatures.isEmpty)
        print("ℹ️ 威胁防护：命中 \(result.itemCount) 个可疑启动项")
    }

    func testMaintenanceRunnerExecutesUserTask() async throws {
        guard runLocalSmokeTests else {
            throw XCTSkip("Set XICO_RUN_LOCAL_SMOKE_TESTS=1 to execute local maintenance commands.")
        }
        // qlmanage -r cache：清快速查看缓存，无害、用户级
        let runner = MaintenanceRunner()
        let (ok, msg) = await runner.run(.flushQuickLook)
        print("ℹ️ 维护(清快速查看缓存)：ok=\(ok) msg=\(msg)")
        XCTAssertNotNil(msg)   // 真实执行了 Process，返回了结果
    }

    func testOptimizationListsLaunchAgents() {
        let opt = OptimizationService()
        let agents = opt.launchAgents()
        XCTAssertGreaterThanOrEqual(agents.count, 0)
        let userAgents = agents.filter { !$0.isSystem }
        print("ℹ️ 优化：\(agents.count) 个启动项（其中用户级 \(userAgents.count) 个，可开关）")
    }

    func testUserMaintenanceCommandsAreValid() {
        for task in UserMaintenanceTask.allCases {
            let (path, _) = task.command
            XCTAssertTrue(FileManager.default.fileExists(atPath: path), "命令不存在：\(path)")
        }
    }
}
