import Foundation

// MARK: - 诚实空间账本（docs/14 P3 · 签名时刻 S2）
// 把「可回收空间」拆成三本账，绝不合并成一个大数字吹牛（CleanMyMac 被骂 snake oil 的反面教材）：
//   1. 永久回收 —— 用户点清理就真回来的字节（来自扫描选中项，账本外部传入）；
//   2. purgeable —— macOS 自管的可清除空间（快照/缓存/休眠镜像等），第三方无法可靠释放，
//      手动"清理"它除了数字好看毫无作用（Apple 社区共识）——只展示、只解释，不计入可回收；
//   3. 本地快照 —— purgeable 的头号大户；无特权拿不到逐个体积（DaisyDisk MAS 版同样拿不到），
//      诚实标注「体积估算不可用」而非编数字。
// 层级：放 Infrastructure（需 URLResourceValues + Process 跑 tmutil）；Domain 保持纯净。

public struct SpaceLedger: Sendable {
    /// macOS 标记为「可清除」的字节（importantUsage 口径可用容量 − 立即可用容量）。
    /// nil = 读取失败（如此卷不支持该口径）。
    public let purgeableBytes: Int64?
    /// Time Machine 本地快照个数；nil = tmutil 不可用/执行失败。
    /// 体积**刻意不提供**：无特权无法估算，宁缺毋假。
    public let snapshotCount: Int?
    /// 快照名（如 com.apple.TimeMachine.2026-07-11-054512.local），供详情展示。
    public let snapshotNames: [String]

    public init(purgeableBytes: Int64?, snapshotCount: Int?, snapshotNames: [String] = []) {
        self.purgeableBytes = purgeableBytes
        self.snapshotCount = snapshotCount
        self.snapshotNames = snapshotNames
    }

    /// 采集系统卷账本。快照枚举走 tmutil（3 秒超时，失败即 nil——绝不卡住扫描收尾）。
    public static func collect(volume: URL = URL(fileURLWithPath: "/")) async -> SpaceLedger {
        let purgeable = purgeableBytes(volume: volume)
        let names = await listLocalSnapshots(volume: volume)
        return SpaceLedger(purgeableBytes: purgeable,
                           snapshotCount: names.map(\.count),
                           snapshotNames: names ?? [])
    }

    /// purgeable = 「重要用途可用」−「立即可用」。两个键任一读不到即 nil（不编数字）。
    static func purgeableBytes(volume: URL) -> Int64? {
        let keys: Set<URLResourceKey> = [.volumeAvailableCapacityForImportantUsageKey,
                                         .volumeAvailableCapacityKey]
        guard let values = try? volume.resourceValues(forKeys: keys),
              let important = values.volumeAvailableCapacityForImportantUsage,
              let available = values.volumeAvailableCapacity else { return nil }
        return max(0, important - Int64(available))
    }

    /// 删除单个本地快照：`tmutil deletelocalsnapshots <日期>`。
    /// 入参为完整快照名（com.apple.TimeMachine.2026-07-11-054512.local），内部提取日期段。
    /// 系统级操作、不可移废纸篓——调用方**必须**先弹二次确认（透镜快照通道的红线）。
    public static func deleteLocalSnapshot(named name: String) async -> Bool {
        // com.apple.TimeMachine.<date>.local → <date>
        var date = name
        if let range = date.range(of: "com.apple.TimeMachine.") { date.removeSubrange(range) }
        if date.hasSuffix(".local") { date.removeLast(".local".count) }
        guard !date.isEmpty, date.allSatisfy({ $0.isNumber || $0 == "-" }) else { return false }
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let proc = Process()
                proc.executableURL = URL(fileURLWithPath: "/usr/bin/tmutil")
                proc.arguments = ["deletelocalsnapshots", date]
                proc.standardOutput = FileHandle.nullDevice
                proc.standardError = FileHandle.nullDevice
                do { try proc.run() } catch { return continuation.resume(returning: false) }
                let watchdog = DispatchWorkItem { if proc.isRunning { proc.terminate() } }
                DispatchQueue.global().asyncAfter(deadline: .now() + 10, execute: watchdog)
                proc.waitUntilExit()
                watchdog.cancel()
                continuation.resume(returning: proc.terminationStatus == 0)
            }
        }
    }

    /// `tmutil listlocalsnapshots <卷>` → 快照名数组；nil = 执行失败/超时。
    /// public（P0-d）：透镜快照管理浮层直接枚举。
    public static func listLocalSnapshots(volume: URL) async -> [String]? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let proc = Process()
                proc.executableURL = URL(fileURLWithPath: "/usr/bin/tmutil")
                proc.arguments = ["listlocalsnapshots", volume.path]
                let pipe = Pipe()
                proc.standardOutput = pipe
                proc.standardError = FileHandle.nullDevice
                do { try proc.run() } catch { return continuation.resume(returning: nil) }
                // 3s 看门狗：tmutil 偶发挂起时不拖累扫描收尾。
                let watchdog = DispatchWorkItem { if proc.isRunning { proc.terminate() } }
                DispatchQueue.global().asyncAfter(deadline: .now() + 3, execute: watchdog)
                proc.waitUntilExit()
                watchdog.cancel()
                guard proc.terminationStatus == 0 else { return continuation.resume(returning: nil) }
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let text = String(decoding: data, as: UTF8.self)
                let names = text.split(separator: "\n")
                    .map(String.init)
                    .filter { $0.contains("com.apple.TimeMachine") }
                continuation.resume(returning: names)
            }
        }
    }
}
