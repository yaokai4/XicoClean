import Foundation

// MARK: - 每进程网络流量（P6·3，iStat 下拉的支柱内容）
//
// 数据源：系统自带 `nettop`（无私有框架依赖）。取两帧快照差分得出每进程 ↓/↑ 速率。
// 铁律「诚实降级」：nettop 输出格式跨版本有波动——解析失败/权限异常时返回 nil，
// UI 整块隐藏，绝不显示坏数据。仅在网络面板可见时按需采样（引用计数式启停由调用方控制）。

public struct ProcessNetUsage: Sendable, Identifiable, Equatable {
    public let id: Int32          // pid
    public let name: String
    public let bytesInPerSec: Double
    public let bytesOutPerSec: Double
}

public final class NetTopSampler: Sendable {
    public init() {}

    /// 同步采样（内部约 1.1s，两帧差分）——只能在后台线程调用。
    /// 返回 nil = nettop 不可用/输出无法解析（调用方隐藏区块）。
    public func sample(top: Int = 4) -> [ProcessNetUsage]? {
        // -P 按进程聚合，-x 原始数字，-L 2 两帧，-s 1 帧间 1s，-J 只要需要的列
        guard let out = runNettop(args: ["-P", "-x", "-L", "2", "-s", "1", "-J", "bytes_in,bytes_out"]) else {
            return nil
        }
        // 输出为两段 CSV：time,process,bytes_in,bytes_out（首行表头，两帧以表头行分隔）。
        let lines = out.split(separator: "\n").map(String.init)
        var frames: [[String: (in: Double, out: Double)]] = []
        var current: [String: (in: Double, out: Double)] = [:]
        var sawHeader = false
        for line in lines {
            if line.hasPrefix("time,") || line.contains(",process,") || line.hasPrefix(",process") {
                if sawHeader, !current.isEmpty { frames.append(current); current = [:] }
                sawHeader = true
                continue
            }
            let cols = line.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
            guard cols.count >= 4,
                  let bin = Double(cols[cols.count - 2]),
                  let bout = Double(cols[cols.count - 1]) else { continue }
            // process 列形如 "kernel_task.0"（名称.pid）；时间戳列在最前。
            let proc = cols[1]
            current[proc] = (bin, bout)
        }
        if !current.isEmpty { frames.append(current) }
        guard frames.count >= 2 else { return nil }
        let a = frames[frames.count - 2], b = frames[frames.count - 1]
        var usages: [ProcessNetUsage] = []
        for (proc, later) in b {
            guard let earlier = a[proc] else { continue }
            let din = max(0, later.in - earlier.in)
            let dout = max(0, later.out - earlier.out)
            guard din + dout > 0 else { continue }
            let (name, pid) = Self.splitProc(proc)
            usages.append(ProcessNetUsage(id: pid, name: name, bytesInPerSec: din, bytesOutPerSec: dout))
        }
        guard !usages.isEmpty else { return [] }
        return Array(usages.sorted { ($0.bytesInPerSec + $0.bytesOutPerSec) > ($1.bytesInPerSec + $1.bytesOutPerSec) }
            .prefix(top))
    }

    /// "Google Chrome H.264.482" → ("Google Chrome H.264", 482)。最后一个 '.' 后是 pid。
    static func splitProc(_ s: String) -> (String, Int32) {
        guard let dot = s.lastIndex(of: "."), let pid = Int32(s[s.index(after: dot)...]) else {
            return (s, 0)
        }
        return (String(s[..<dot]), pid)
    }

    private func runNettop(args: [String]) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/nettop")
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()   // 静默 stderr
        do {
            try p.run()
        } catch {
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0, let s = String(data: data, encoding: .utf8), !s.isEmpty else {
            return nil
        }
        return s
    }
}
