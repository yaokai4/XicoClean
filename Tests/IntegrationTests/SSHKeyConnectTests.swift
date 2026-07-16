import XCTest
import Domain
@testable import Infrastructure

/// SSH 传输（系统 ssh）+ 真实连接回归。
///
/// 背景（本次修复）：Citadel 的 RSA 公钥认证只签 SHA-1 `ssh-rsa`，被现代 OpenSSH（如 Machi 的 8.7）拒绝，
/// 导致「用 .pem（RSA）连接失败」。改走系统 `ssh` 后原生支持 rsa-sha2 与任意 `.pem` 格式。
///
/// - `testContextBuildsForPKCS1Key` 等：**恒跑**、离线——验证 `SSHContext` 为各类凭据正确落盘并拼出 ssh 参数。
/// - `testLiveConnectWithEnvKey`：真机连接，仅在设置了 `XICO_SSH_TEST_KEY` / HOST / USER 时运行。
final class SSHKeyConnectTests: XCTestCase {
    private let testHostKey = "AAAAC3NzaC1lZDI1NTE5AAAAIF7Ek4ZPOf+GJCGmOpCq0EqEFtaigoVc/lF7Ybbzn146"

    /// 现场用 ssh-keygen 生成一把 PKCS#1（`-m PEM`）RSA 私钥（AWS/Lightsail 下发的格式）。
    private func makePKCS1RSAKey() throws -> String {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("xico-keytest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let keyPath = dir.appendingPathComponent("id").path
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keygen")
        p.arguments = ["-t", "rsa", "-b", "2048", "-m", "PEM", "-N", "", "-C", "xico-test", "-f", keyPath, "-q"]
        p.standardOutput = Pipe(); p.standardError = Pipe()
        try p.run(); p.waitUntilExit()
        XCTAssertEqual(p.terminationStatus, 0, "ssh-keygen 生成测试密钥失败")
        return try String(contentsOfFile: keyPath, encoding: .utf8)
    }

    private func host(_ user: String = "ec2-user", _ h: String = "example.com", _ port: Int = 22) -> ServerHost {
        let token = port == 22 ? h : "[\(h)]:\(port)"
        return ServerHost(name: "t", hostname: h, port: port, username: user, authKind: .privateKey,
                          pinnedHostKeys: ["\(token) ssh-ed25519 \(testHostKey)"])
    }

    /// 私钥凭据：SSHContext 应把私钥落盘、拼出 `-i <key> -o IdentitiesOnly=yes` 且不需要 askpass。
    func testContextBuildsForPKCS1Key() throws {
        let pkcs1 = try makePKCS1RSAKey()
        XCTAssertTrue(pkcs1.contains("BEGIN RSA PRIVATE KEY"), "应为 PKCS#1 .pem")
        let ctx = try SSHContext(host: host(), credential: .privateKey(pem: pkcs1, passphrase: nil), multiplexed: true)
        defer { ctx.close() }
        let args = ctx.sshArgs(remoteCommand: "uname -s")
        XCTAssertTrue(args.contains("-i"), "私钥凭据应带 -i")
        XCTAssertTrue(args.contains("IdentitiesOnly=yes"), "应仅用指定私钥")
        XCTAssertTrue(args.contains("BatchMode=yes"), "无口令私钥应 BatchMode=yes（防挂起）")
        XCTAssertTrue(args.contains("ControlMaster=auto"), "复用连接应启用 ControlMaster")
        let controlPath = try XCTUnwrap(ctx.controlPath)
        XCTAssertLessThanOrEqual(controlPath.utf8.count, SSHContext.maxControlPathBytes,
                                 "ControlPath 必须为 OpenSSH 的原子创建后缀预留空间")
        XCTAssertTrue(args.contains("StrictHostKeyChecking=yes"))
        XCTAssertTrue(args.contains("GlobalKnownHostsFile=/dev/null"))
        XCTAssertFalse(args.contains("StrictHostKeyChecking=accept-new"))
        XCTAssertEqual(args.last, "uname -s")
        XCTAssertTrue(args.contains("ec2-user@example.com"))
        // 系统 ssh 直接读 .pem，无需任何格式转换——不设 SSH_ASKPASS。
        XCTAssertNil(ctx.environment["SSH_ASKPASS"])
    }

    func testMultiplexedControlSocketUsesShortPrivateDirectoryAndCleansUp() throws {
        let ctx = try SSHContext(host: host(), credential: .password("secret"), multiplexed: true)
        let controlPath = try XCTUnwrap(ctx.controlPath)
        let directory = URL(fileURLWithPath: controlPath).deletingLastPathComponent()
        XCTAssertTrue(controlPath.hasPrefix("/private/tmp/xs-"))
        XCTAssertLessThanOrEqual(controlPath.utf8.count, SSHContext.maxControlPathBytes)
        let attrs = try FileManager.default.attributesOfItem(atPath: directory.path)
        let permissions = (attrs[.posixPermissions] as? NSNumber)?.intValue ?? 0
        XCTAssertEqual(permissions & 0o777, 0o700, "SSH 控制 socket 目录必须只允许当前用户访问")
        ctx.close()
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path), "断开后必须删除控制 socket 目录")
    }

    func testContextNormalizesPastedEndpointWhitespace() throws {
        var padded = host(" ec2-user\n", "  example.com\n")
        padded.pinnedHostKeys = ["example.com ssh-ed25519 \(testHostKey)"]
        let ctx = try SSHContext(host: padded, credential: .password("secret"), multiplexed: false)
        defer { ctx.close() }
        XCTAssertEqual(ctx.endpoint, "ec2-user@example.com")
    }

    /// 加密私钥：应写 askpass 助手并置 BatchMode=no（让 ssh 能取口令）。
    func testContextBuildsAskpassForEncryptedKey() throws {
        let pkcs1 = try makePKCS1RSAKey()
        let ctx = try SSHContext(host: host(), credential: .privateKey(pem: pkcs1, passphrase: "secret"), multiplexed: true)
        defer { ctx.close() }
        XCTAssertNotNil(ctx.environment["SSH_ASKPASS"], "加密私钥应配置 askpass")
        XCTAssertEqual(ctx.environment["SSH_ASKPASS_REQUIRE"], "force")
        XCTAssertTrue(ctx.sshArgs().contains("BatchMode=no"))
    }

    /// 密码凭据：应走 askpass 且禁用公钥、偏好密码认证。
    func testContextBuildsForPassword() throws {
        let ctx = try SSHContext(host: host(), credential: .password("hunter2"), multiplexed: false)
        defer { ctx.close() }
        let args = ctx.sshArgs()
        XCTAssertNotNil(ctx.environment["SSH_ASKPASS"])
        XCTAssertTrue(args.contains("PubkeyAuthentication=no"))
        XCTAssertTrue(args.contains("PreferredAuthentications=password,keyboard-interactive"))
        XCTAssertFalse(args.contains("ControlMaster=auto"), "multiplexed=false 不应带 ControlMaster")
    }

    func testContextRefusesHostWithoutConfirmedKey() throws {
        let untrusted = ServerHost(name: "untrusted", hostname: "example.com", username: "ec2-user",
                                   authKind: .password)
        XCTAssertThrowsError(try SSHContext(host: untrusted, credential: .password("secret"))) { error in
            guard case ServerSSHError.hostKeyNotTrusted = error else {
                return XCTFail("应拒绝未确认的主机身份，实际：\(error)")
            }
        }
    }

    func testHostKeyParserBindsEndpointAndFingerprint() {
        let key = SSHHostKey.parse("example.com ssh-ed25519 \(testHostKey)", hostname: "example.com", port: 22)
        XCTAssertEqual(key?.algorithm, "ssh-ed25519")
        XCTAssertEqual(key?.fingerprint, "SHA256:gThESTKZ+mh0foDXbnPOskX4fez91MxY2MTXGONK0FM")
        XCTAssertNil(SSHHostKey.parse("evil.example ssh-ed25519 \(testHostKey)", hostname: "example.com", port: 22))
        XCTAssertNil(SSHHostKey.parse("example.com ssh-rsa \(testHostKey)", hostname: "example.com", port: 22),
                     "声明算法与 key blob 不一致必须拒绝")
        XCTAssertNil(SSHHostKey.parse("example.com ssh-ed25519 \(testHostKey) comment", hostname: "example.com", port: 22))
    }

    func testChangedHostKeyGetsExplicitBlockingMessage() {
        let message = friendlySSHError("WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED!", code: 255)
        XCTAssertTrue(message.contains("已阻止连接"))
        XCTAssertTrue(message.contains("重新验证"))
    }

    /// `ls -la` 行解析（SFTP 列目录）：目录 / 文件 / 含空格名 / 软链。
    func testLSLineParsing() {
        let dir = SFTPBrowser.parseLSLine("drwxr-xr-x  4 ec2-user ec2-user 4096 Jul 13 07:00 my folder")
        XCTAssertEqual(dir?.name, "my folder"); XCTAssertEqual(dir?.isDirectory, true)
        let file = SFTPBrowser.parseLSLine("-rw-r--r--  1 root root 1048576 Jul 13 07:00 app.log")
        XCTAssertEqual(file?.name, "app.log"); XCTAssertEqual(file?.isDirectory, false); XCTAssertEqual(file?.size, 1_048_576)
        let link = SFTPBrowser.parseLSLine("lrwxrwxrwx 1 root root 7 Jul 13 07:00 latest -> app.log")
        XCTAssertEqual(link?.name, "latest"); XCTAssertEqual(link?.isSymlink, true)
        XCTAssertNil(SFTPBrowser.parseLSLine("total 24"))
    }

    func testStructuredSFTPListingPreservesSpecialNamesWithoutExecutingThem() throws {
        let ordinary = Data("report -> final.txt".utf8).base64EncodedString()
        let controlled = Data("line\nwith\ttabs".utf8).base64EncodedString()
        let raw = "XICO_SFTP_V1\n\(ordinary)\tf\t42\t-rw-r--r--\n\(controlled)\td\t96\tdrwx------\n"
        let entries = try SFTPBrowser.parseStructuredListing(raw)
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries[0].name, "report -> final.txt")
        XCTAssertFalse(entries[0].isSymlink, "名称中的 -> 不得再被误解析为软链接")
        XCTAssertTrue(entries[0].isOperationallySafe)
        XCTAssertEqual(entries[1].name, "line\nwith\ttabs")
        XCTAssertFalse(entries[1].isOperationallySafe, "控制字符名称应可见但所有操作必须禁用")
        XCTAssertTrue(entries[1].displayName.contains("\\u{0A}"))
    }

    func testStructuredSFTPListingFailsClosedOnMalformedProtocol() {
        XCTAssertThrowsError(try SFTPBrowser.parseStructuredListing("total 2\n-rw-r--r-- file"))
        XCTAssertThrowsError(try SFTPBrowser.parseStructuredListing("XICO_SFTP_V1\n!!!!\tf\t2\t-rw-r--r--\n"))
    }

    func testSSHProcessHardStopsTermIgnoringProcess() async {
        let started = Date()
        let result = await SSHProcess.run(executable: "/bin/sh",
                                          args: ["-c", "trap '' TERM; while :; do :; done"],
                                          timeout: 0.1, maxOutputBytes: 4_096)
        XCTAssertNotEqual(result.code, 0)
        XCTAssertLessThan(Date().timeIntervalSince(started), 2.0, "忽略 SIGTERM 的子进程也必须在两秒内被 SIGKILL")
    }

    func testSSHProcessStopsOnOutputFlood() async {
        let started = Date()
        let result = await SSHProcess.run(executable: "/usr/bin/yes", args: [],
                                          timeout: 10, maxOutputBytes: 4_096)
        XCTAssertTrue(result.outputLimitExceeded)
        XCTAssertLessThanOrEqual(result.stdout.count, 4_096)
        XCTAssertLessThan(Date().timeIntervalSince(started), 3.5, "输出洪泛达到上限后必须及时停止")
    }

    func testSSHProcessTaskCancellationStopsChild() async {
        let task = Task {
            await SSHProcess.run(executable: "/bin/sh",
                                 args: ["-c", "trap '' TERM; while :; do :; done"],
                                 timeout: 60, maxOutputBytes: 4_096)
        }
        try? await Task.sleep(for: .milliseconds(150))
        let started = Date()
        task.cancel()
        let result = await task.value
        XCTAssertNotEqual(result.code, 0)
        XCTAssertLessThan(Date().timeIntervalSince(started), 2.0, "取消 Swift Task 必须同步停止底层 ssh/sftp 子进程")
    }

    /// 真机连接：仅当 env 提供了私钥/主机/用户时运行（不泄密、不硬编码路径）。
    /// 用法：`XICO_SSH_TEST_KEY=~/Downloads/Machi2.pem XICO_SSH_TEST_HOST=35.79.109.50 \
    ///        XICO_SSH_TEST_USER=ec2-user swift test --filter testLiveConnectWithEnvKey`
    func testLiveConnectWithEnvKey() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let rawPath = env["XICO_SSH_TEST_KEY"],
              let hostAddr = env["XICO_SSH_TEST_HOST"],
              let user = env["XICO_SSH_TEST_USER"] else {
            throw XCTSkip("未设置 XICO_SSH_TEST_KEY/HOST/USER，跳过真机连接测试")
        }
        let keyPath = (rawPath as NSString).expandingTildeInPath
        let pem = try String(contentsOfFile: keyPath, encoding: .utf8)
        let port = Int(env["XICO_SSH_TEST_PORT"] ?? "22") ?? 22

        let scanned = try await SSHHostKeyScanner.scan(hostname: hostAddr, port: port)
        let h = ServerHost(name: "test", hostname: hostAddr, port: port, username: user, authKind: .privateKey,
                           pinnedHostKeys: scanned.map(\.rawLine))
        let conn = HostConnection(host: h)
        try await conn.connect(credential: .privateKey(pem: pem, passphrase: env["XICO_SSH_TEST_PASSPHRASE"]))

        let out = try await conn.execute("echo XICO_OK; uname -s")
        XCTAssertTrue(out.contains("XICO_OK"), "远端命令应回显 XICO_OK，实际：\(out)")

        // 采一帧指标，验证监控路径（解析器）在真实主机上可用。
        let snap = try await conn.sampleMetrics(includeServices: false)
        XCTAssertNotNil(snap, "应能采到一帧远端指标")
        if let snap { XCTAssertGreaterThan(snap.memTotal, 0, "内存总量应 > 0") }

        await conn.disconnect()
    }
}
