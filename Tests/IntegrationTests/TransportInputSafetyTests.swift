import XCTest
import Domain
@testable import Infrastructure

final class TransportInputSafetyTests: XCTestCase {
    func testDownloadSourceAcceptsHTTPSAndValidMagnet() {
        XCTAssertEqual(
            DownloadManager.normalizedSource(" https://example.com/a%2Fb.mp4?token=x%2By ", kind: .video),
            "https://example.com/a%2Fb.mp4?token=x%2By"
        )
        XCTAssertNotNil(DownloadManager.normalizedSource("magnet:?xt=urn:btih:ABCDEF", kind: .video))
    }

    func testDownloadSourceRejectsLocalSchemesCredentialsAndMalformedMagnet() {
        XCTAssertNil(DownloadManager.normalizedSource("file:///etc/passwd", kind: .video))
        XCTAssertNil(DownloadManager.normalizedSource("javascript://example.com/x", kind: .video))
        XCTAssertNil(DownloadManager.normalizedSource("https://user:pass@example.com/x", kind: .video))
        XCTAssertNil(DownloadManager.normalizedSource("magnet:?dn=no-hash", kind: .video))
        XCTAssertNil(DownloadManager.normalizedSource("magnet:?xt=urn:btih:ABC", kind: .image))
    }

    @MainActor
    func testDangerousDownloadInputIsAcceptedAndVisiblyQuarantined() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("xico-download-test-\(UUID().uuidString)")
        let suite = "xico.download.test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { try? FileManager.default.removeItem(at: dir); defaults.removePersistentDomain(forName: suite) }
        let manager = DownloadManager(defaults: defaults, persistenceDirectory: dir)
        XCTAssertTrue(manager.add(urlString: "javascript:alert(document.cookie)"),
                      "非空危险输入不能被界面拒绝或静默丢弃")
        XCTAssertEqual(manager.jobs.count, 1)
        guard case .quarantined = manager.jobs[0].state else {
            return XCTFail("危险输入必须进入可见隔离态，且绝不交给执行组件")
        }
    }

    @MainActor
    func testDownloadQueueRestoresInterruptedWorkAsPaused() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("xico-download-restore-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let job = DownloadJob(sourceURL: "https://example.com/video.mp4", title: "Video", kind: .video,
                              state: .downloading(progress: 0.5, speed: "1 MB/s", eta: "10s"),
                              destinationDir: dir.path)
        let data = try JSONEncoder().encode([job])
        try data.write(to: dir.appendingPathComponent("download-queue-v1.json"))
        let manager = DownloadManager(defaults: UserDefaults(suiteName: "xico.restore.\(UUID().uuidString)")!,
                                      persistenceDirectory: dir)
        XCTAssertEqual(manager.jobs.count, 1)
        XCTAssertEqual(manager.jobs[0].state, .paused, "应用重启后不得伪装为仍在下载，应恢复为可继续的暂停态")
    }

    func testClipboardMediaHostDoesNotUseSubstringMatching() {
        XCTAssertTrue(DownloadManager.looksLikeMedia("https://www.youtube.com/watch?v=1"))
        XCTAssertFalse(DownloadManager.looksLikeMedia("https://evil.example/?next=youtube.com/watch"))
    }

    func testSSHInputValidationRejectsOptionAndControlForms() {
        XCTAssertTrue(SSHInputValidator.isValidUsername("ec2-user"))
        XCTAssertTrue(SSHInputValidator.isValidHostname("2001:db8::1"))
        XCTAssertFalse(SSHInputValidator.isValidUsername("-oProxyCommand=bad"))
        XCTAssertFalse(SSHInputValidator.isValidHostname("host\nother"))
        XCTAssertFalse(SSHInputValidator.isValidPort(0))
        XCTAssertFalse(SSHInputValidator.isValidPort(65_536))
    }

    func testSFTPBatchQuotingRejectsCommandSeparatorsByNewline() throws {
        XCTAssertEqual(try sftpQuote("folder/a \"quote\".txt"), "\"folder/a \\\"quote\\\".txt\"")
        XCTAssertThrowsError(try sftpQuote("safe\nrm /important"))
        XCTAssertThrowsError(try sftpQuote("safe\rput bad"))
    }

    func testArchiveEntriesRejectTraversalAbsoluteAndControlPaths() {
        XCTAssertTrue(ArchiveSafety.entriesAreSafe(["release/bin/ffmpeg", "release/LICENSE"]))
        XCTAssertFalse(ArchiveSafety.entriesAreSafe(["../escape"]))
        XCTAssertFalse(ArchiveSafety.entriesAreSafe(["/tmp/escape"]))
        XCTAssertFalse(ArchiveSafety.entriesAreSafe(["safe\\..\\escape"]))
        XCTAssertFalse(ArchiveSafety.entriesAreSafe(["safe\nother"]))
    }

    func testDownloadProcessHandleHardStopsAndLatchesEarlyCancel() throws {
        let handle = ProcessHandle()
        handle.terminate() // 模拟用户在子进程刚启动前就点取消。
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "trap '' TERM; while :; do :; done"]
        try process.run()
        let started = Date()
        handle.set(process) // 取消锁存必须立刻作用到稍后才登记的进程。
        process.waitUntilExit()
        XCTAssertFalse(process.isRunning)
        XCTAssertLessThan(Date().timeIntervalSince(started), 2.0)
    }
}
