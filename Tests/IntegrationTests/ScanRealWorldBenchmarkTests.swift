import XCTest
import Domain
@testable import Infrastructure

/// 门控真机扫描基准。默认 CI 跳过；发布前通过 XICO_SCAN_BENCH_PATH 指定稳定样本目录。
final class ScanRealWorldBenchmarkTests: XCTestCase {
    func testRealWorldSnapshotBudget() async throws {
        guard let path = ProcessInfo.processInfo.environment["XICO_SCAN_BENCH_PATH"],
              !path.isEmpty else {
            throw XCTSkip("未设置 XICO_SCAN_BENCH_PATH，跳过真机扫描基准")
        }
        let root = URL(fileURLWithPath: path, isDirectory: true)
        let maxSeconds = Double(ProcessInfo.processInfo.environment["XICO_SCAN_MAX_SECONDS"] ?? "60") ?? 60
        let firstProgress = FirstProgressRecorder()
        let started = Date()
        let snapshot = await ScanSnapshotStore(cacheTTL: 0).snapshot(for: root) { _ in
            firstProgress.record(Date().timeIntervalSince(started))
        }
        let elapsed = Date().timeIntervalSince(started)
        let filesPerSecond = elapsed > 0 ? Double(snapshot.coverage.filesVisited) / elapsed : 0
        let elapsedText = String(format: "%.3f", elapsed)
        let firstProgressText = String(format: "%.3f", firstProgress.value ?? elapsed)

        print("SCAN_BENCH root=\(root.path) files=\(snapshot.coverage.filesVisited) "
              + "dirs=\(snapshot.coverage.directoriesVisited) elapsed=\(elapsedText)s "
              + "firstProgress=\(firstProgressText)s "
              + "filesPerSecond=\(Int(filesPerSecond)) denied=\(snapshot.coverage.deniedDirectories) "
              + "cloudSkipped=\(snapshot.coverage.cloudPlaceholdersSkipped) "
              + "policyExcluded=\(snapshot.coverage.excludedByPolicy)")

        XCTAssertFalse(snapshot.coverage.cancelled)
        XCTAssertLessThanOrEqual(elapsed, maxSeconds,
                                 "真实样本扫描超过 XICO_SCAN_MAX_SECONDS 预算")
        XCTAssertEqual(snapshot.coverage.deniedDirectories, 0,
                       "基准样本必须可完整读取，否则性能与召回率结论无效")
        if snapshot.coverage.filesVisited >= 512 {
            XCTAssertLessThan(firstProgress.value ?? elapsed, 2,
                              "首批 512 个文件的进度必须在 2 秒内到达")
        }
    }
}

private final class FirstProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: TimeInterval?

    var value: TimeInterval? {
        lock.withLock { stored }
    }

    func record(_ value: TimeInterval) {
        lock.withLock {
            if stored == nil { stored = value }
        }
    }
}
