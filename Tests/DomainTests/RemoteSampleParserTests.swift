import XCTest
@testable import Domain

/// 验证远程指标解析的核心数学：CPU 两采样差分、内存 MemAvailable 口径、网络/磁盘速率按纳秒 dt、
/// df 过滤伪文件系统、ps 跳表头。用真实形态的 /proc 样本 + 已知 dt 断言数值。
final class RemoteSampleParserTests: XCTestCase {

    /// 构造一个自包含批量输出：两次采样相隔 1.0s（T2-T1 = 1e9 ns）。
    /// CPU：sample1 total=100(busy0)、sample2 busy 增 25 / total 增 100 → 25% 使用率。
    private func makeBlob() -> String {
        // T1 = 1_000_000_000_000 ns, T2 = 1_001_000_000_000 ns → dt = 1.0s
        let cpu1 = "cpu  0 0 0 100 0 0 0 0 0 0\ncpu0 0 0 0 100 0 0 0 0 0 0"
        // busy(user+sys) 增 25，idle 增 75 → total 增 100；user 增 20，system 增 5，iowait 0，steal 0
        let cpu2 = "cpu  20 0 5 175 0 0 0 0 0 0\ncpu0 20 0 5 175 0 0 0 0 0 0"
        // net: eth0 rx 增 1_000_000 B、tx 增 500_000 B 在 1s → 1 MB/s down, 500 KB/s up。lo 应被忽略。
        let net1 = "Inter-|   Receive                                                |  Transmit\n eth0: 1000000 10 0 0 0 0 0 0  2000000 20 0 0 0 0 0 0\n   lo: 999 1 0 0 0 0 0 0  999 1 0 0 0 0 0 0"
        let net2 = "Inter-|   Receive                                                |  Transmit\n eth0: 2000000 10 0 0 0 0 0 0  2500000 20 0 0 0 0 0 0\n   lo: 1999 1 0 0 0 0 0 0  1999 1 0 0 0 0 0 0"
        // diskstats: sda rd_sectors(col6) 增 2048、wr_sectors(col10) 增 1024 在 1s
        // → read 2048*512 = 1 MiB/s, write 1024*512 = 512 KiB/s。sda1 分区 + loop 应被忽略。
        let disk1 = "   8       0 sda 100 0 4096 0 50 0 2048 0 0 0 0\n   8       1 sda1 100 0 4096 0 50 0 2048 0 0 0 0\n   7       0 loop0 1 0 8 0 0 0 0 0 0 0 0"
        let disk2 = "   8       0 sda 200 0 6144 0 90 0 3072 0 0 0 0\n   8       1 sda1 200 0 6144 0 90 0 3072 0 0 0 0\n   7       0 loop0 1 0 8 0 0 0 0 0 0 0 0"
        let mem = "MemTotal:       8000000 kB\nMemFree:         500000 kB\nMemAvailable:   2000000 kB\nBuffers:         100000 kB\nCached:          900000 kB\nSwapTotal:      2000000 kB\nSwapFree:       1500000 kB"
        let load = "0.50 0.75 1.00 2/345 6789"
        let up = "123456.78 100000.00"
        let df = "Filesystem     1024-blocks     Used Available Capacity Mounted on\n/dev/sda1        102400000 51200000  51200000      50% /\ntmpfs               800000        0    800000       0% /run\n/dev/sda2        204800000 40960000 163840000      20% /data"
        let ps = "  PID USER     %CPU %MEM   RSS COMMAND\n 1234 root     12.5  3.2 262144 nginx\n 5678 www-data  4.0  1.0 131072 php-fpm"
        return [
            "@@OS", "Linux",
            "@@T1", "1000000000000",
            "@@CPU1", cpu1,
            "@@NET1", net1,
            "@@DISK1", disk1,
            "@@T2", "1001000000000",
            "@@CPU2", cpu2,
            "@@NET2", net2,
            "@@DISK2", disk2,
            "@@MEM", mem,
            "@@LOAD", load,
            "@@UP", up,
            "@@DF", df,
            "@@PS", ps,
            "@@END"
        ].joined(separator: "\n")
    }

    func testParsesCPUDelta() {
        let snap = RemoteSampleParser.parseMetrics(makeBlob(), now: Date())
        let s = try! XCTUnwrap(snap)
        XCTAssertEqual(s.cpuUsage, 0.25, accuracy: 0.01, "busy 增 25 / total 增 100 → 25%")
        XCTAssertEqual(s.cpuUser, 0.20, accuracy: 0.01)
        XCTAssertEqual(s.cpuSystem, 0.05, accuracy: 0.01)
        XCTAssertEqual(s.coreCount, 1)
        XCTAssertEqual(s.perCore.first ?? -1, 0.25, accuracy: 0.01)
    }

    func testParsesMemory() {
        let s = RemoteSampleParser.parseMetrics(makeBlob(), now: Date())!
        XCTAssertEqual(s.memTotal, 8_000_000 * 1024)
        XCTAssertEqual(s.memAvailable, 2_000_000 * 1024)
        XCTAssertEqual(s.memUsed, (8_000_000 - 2_000_000) * 1024)
        XCTAssertEqual(s.swapUsed, (2_000_000 - 1_500_000) * 1024)
        XCTAssertEqual(s.memUsedFraction, 0.75, accuracy: 0.001)
    }

    func testParsesNetworkRate_ignoresLo() {
        let s = RemoteSampleParser.parseMetrics(makeBlob(), now: Date())!
        XCTAssertEqual(s.netRxBytesPerSec, 1_000_000, accuracy: 1, "1 MB in 1s, lo excluded")
        XCTAssertEqual(s.netTxBytesPerSec, 500_000, accuracy: 1)
    }

    func testParsesDiskRate_wholeDiskOnly() {
        let s = RemoteSampleParser.parseMetrics(makeBlob(), now: Date())!
        XCTAssertEqual(s.diskReadBytesPerSec, 2048 * 512, accuracy: 1, "sda only, not sda1/loop0")
        XCTAssertEqual(s.diskWriteBytesPerSec, 1024 * 512, accuracy: 1)
    }

    func testParsesLoadAndUptime() {
        let s = RemoteSampleParser.parseMetrics(makeBlob(), now: Date())!
        XCTAssertEqual(s.load1, 0.5, accuracy: 0.001)
        XCTAssertEqual(s.load5, 0.75, accuracy: 0.001)
        XCTAssertEqual(s.load15, 1.0, accuracy: 0.001)
        XCTAssertEqual(s.uptimeSeconds, 123456.78, accuracy: 0.1)
    }

    func testParsesDF_filtersPseudoFS() {
        let s = RemoteSampleParser.parseMetrics(makeBlob(), now: Date())!
        // tmpfs /run 应被过滤；剩 / 与 /data
        XCTAssertEqual(s.mounts.count, 2)
        let root = try! XCTUnwrap(s.mounts.first { $0.mountPoint == "/" })
        XCTAssertEqual(root.totalBytes, 102_400_000 * 1024)
        XCTAssertEqual(root.usedFraction, 0.5, accuracy: 0.01)
        XCTAssertEqual(s.rootDiskFraction, 0.5, accuracy: 0.01)
    }

    func testParsesProcesses_skipsHeader() {
        let s = RemoteSampleParser.parseMetrics(makeBlob(), now: Date())!
        XCTAssertEqual(s.processes.count, 2, "表头 PID 行被跳过")
        let nginx = try! XCTUnwrap(s.processes.first)
        XCTAssertEqual(nginx.pid, 1234)
        XCTAssertEqual(nginx.user, "root")
        XCTAssertEqual(nginx.cpuPercent, 12.5, accuracy: 0.01)
        XCTAssertEqual(nginx.rssBytes, 262144 * 1024)
        XCTAssertEqual(nginx.command, "nginx")
    }

    func testParsesServices() {
        let raw = [
            "@@DOCKER", "web|Up 3 hours|nginx:latest", "db|Exited (0) 2 min ago|postgres:16",
            "@@SYSTEMD", "ssh.service loaded active running OpenBSD Secure Shell server",
            "@@END"
        ].joined(separator: "\n")
        let svcs = RemoteSampleParser.parseServices(raw)
        XCTAssertEqual(svcs.count, 3)
        let web = try! XCTUnwrap(svcs.first { $0.name == "web" })
        XCTAssertTrue(web.isHealthy)
        XCTAssertEqual(web.detail, "nginx:latest")
        let db = try! XCTUnwrap(svcs.first { $0.name == "db" })
        XCTAssertFalse(db.isHealthy, "Exited 非 Up")
        let ssh = try! XCTUnwrap(svcs.first { $0.name == "ssh" })
        XCTAssertEqual(ssh.kind, .systemd)
        XCTAssertTrue(ssh.isHealthy)
    }

    func testMalformedInputReturnsNilGracefully() {
        XCTAssertNil(RemoteSampleParser.parseMetrics("garbage\nno markers here", now: Date()))
    }
}
