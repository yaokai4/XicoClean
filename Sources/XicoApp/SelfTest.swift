import Foundation
import Domain
import Infrastructure

/// 全功能自检：真实跑每个模块，量耗时、抓错误。用法：Xico --selftest
/// 返回是否全部关键检查通过（供 CI 用退出码判定，不再永远 exit 0）。
@discardableResult
func runSelfTest() async -> Bool {
    var ok = true
    func log(_ s: String) { FileHandle.standardError.write((s + "\n").data(using: .utf8)!) }
    func time<T>(_ name: String, _ block: () async -> T, describe: (T) -> String) async {
        let start = Date()
        let result = await block()
        let ms = Int(Date().timeIntervalSince(start) * 1000)
        log(String(format: "  %-22@ %6dms  %@", name as NSString, ms, describe(result) as NSString))
    }

    let env = XicoEnvironment.live()
    log("=== Xico 全功能自检 ===")
    let definitionsStatus = env.definitionsUpdater.status()
    let definitionsSource = definitionsStatus.cachedVersion == env.definitions.version ? "signed-cache" : "bundled"
    let license = env.license.status()
    log("定义库 v\(env.definitions.version)（\(env.definitions.definitions.count) 条，\(definitionsSource)） · 授权=\(license.state.title) · FDA=\(env.permissions.hasFullDiskAccess()) · 助手=\(env.helper.status())")

    log("[扫描器]")
    for id in [ModuleID.systemJunk, .privacy, .trash, .largeFiles, .malware] {
        guard let s = env.scanner(for: id) else { continue }
        await time(s.metadata.title, { (try? await s.scan { _ in }) }, describe: { r in
            "\(r?.itemCount ?? 0) 项 / \((r?.totalReclaimable ?? 0).formattedBytes)" })
    }
    let downloads = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
    await time("重复文件", { await env.duplicatesScanner(root: downloads).scan { _ in } },
               describe: { "\($0.groups.count) 组" })

    log("[系统垃圾分组与命名抽样]")
    if let sj = env.scanner(for: .systemJunk), let r = try? await sj.scan(progress: { _ in }) {
        for g in r.groups.prefix(12) {
            let sample = g.items.prefix(3).map { $0.displayName }.joined(separator: ", ")
            log("  · \(g.title)  \(g.totalSize.formattedBytes)  [\(g.items.count)项]  例: \(sample)")
        }
    }

    log("[清理闭环]")
    let roundTrip = await cleaningRoundTrip(env)
    if !roundTrip { ok = false }
    log(String(format: "  %-22@ %@", "移废纸篓+撤销" as NSString, (roundTrip ? "✓ 通过" : "✗ 失败") as NSString))

    log("[应用与系统]")
    await time("卸载器列表", { env.uninstaller.listApps() }, describe: { "\($0.count) 个应用" })
    if let first = env.uninstaller.listApps().first {
        await time("卸载关联文件定位", { env.uninstaller.uninstallTargets(for: first) },
                   describe: { "\($0.count) 项（\(first.name)）" })
    }
    await time("启动项", { env.optimization.launchAgents() },
               describe: { "\($0.count) 个（用户级可开关 \($0.filter { !$0.isSystem }.count)）" })
    await time("运行中应用", { await MainActor.run { env.optimization.runningApps() } }, describe: { "\($0.count) 个" })
    await time("维护(清快速查看缓存)", { await env.maintenanceRunner.run(.flushQuickLook) },
               describe: { "ok=\($0.0)" })

    log("[系统监视]")
    let m = env.liveMetrics
    _ = m.sample(); let snap = m.sample()
    let info = m.macInfo()
    log("  \(info.chip) · \(info.macOS) · \(info.memory) · \(info.cores)核 · 已运行 \(info.uptime)")
    log(String(format: "  CPU=%.0f%%  内存=%.0f%%  网络↓%@ ↑%@  温度=%@  风扇=%@",
               snap.cpuUsage * 100, snap.memoryUsedFraction * 100,
               snap.netDownBytesPerSec.formattedRate, snap.netUpBytesPerSec.formattedRate,
               snap.thermal.rawValue,
               snap.fanRPM.map { "\($0) RPM" } ?? "—") as String)

    log("[空间透镜]")
    let caches = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches")
    await time("树扫描(Caches)", { await env.diskTreeScanner.scan(caches) },
               describe: { "\(countNodes($0)) 节点 / \($0.size.formattedBytes)" })

    log(ok ? "=== 自检完成：全部关键检查通过 ===" : "=== 自检完成：存在失败项（见上）===")
    return ok
}

private func cleaningRoundTrip(_ env: XicoEnvironment) async -> Bool {
    let dir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Caches/XicoSelfTest-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let file = dir.appendingPathComponent("junk.dat")
    try? Data(repeating: 0xAB, count: 64 * 1024).write(to: file)
    let item = CleanableItem(url: file, displayName: "junk.dat", size: 65536)
    let report = await env.cleaningEngine.execute(CleaningPlan(items: [item], intent: .trash))
    let removed = !FileManager.default.fileExists(atPath: file.path)
    let undo = await env.cleaningEngine.undo(report)
    let backOK = FileManager.default.fileExists(atPath: file.path)
    try? FileManager.default.removeItem(at: dir)
    return report.removedCount == 1 && removed && undo.restored == 1 && undo.allSucceeded && backOK
}

private func countNodes(_ n: DiskNode) -> Int { 1 + n.children.reduce(0) { $0 + countNodes($1) } }
