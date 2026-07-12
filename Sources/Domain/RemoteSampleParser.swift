import Foundation

/// 远端指标解析器——纯函数、可单测、零 SSH 依赖。
///
/// 采样策略：一条**自包含**批量命令里取两次计数器（相隔 ~0.85s）+ 纳秒时间戳，于是 CPU%、
/// 网络/磁盘速率都能在单次轮询内算出差分，无需跨轮询保存状态（避免重连/乱序导致的速率跳变）。
/// 段落用 `@@MARK` 分隔（见 `linuxMetricsCommand`）。
public enum RemoteSampleParser {

    // MARK: 采样命令（Linux）
    /// `LC_ALL=C` 固定数字格式；`grep '^cpu'` 同时拿聚合行与每核心行；两次采样夹一个 sleep。
    public static let linuxMetricsCommand = """
    LC_ALL=C; \
    echo @@OS; uname -s; \
    echo @@T1; date +%s%N; \
    echo @@CPU1; grep '^cpu' /proc/stat; \
    echo @@NET1; cat /proc/net/dev; \
    echo @@DISK1; cat /proc/diskstats; \
    sleep 0.85; \
    echo @@T2; date +%s%N; \
    echo @@CPU2; grep '^cpu' /proc/stat; \
    echo @@NET2; cat /proc/net/dev; \
    echo @@DISK2; cat /proc/diskstats; \
    echo @@MEM; cat /proc/meminfo; \
    echo @@LOAD; cat /proc/loadavg; \
    echo @@UP; cat /proc/uptime; \
    echo @@DF; df -kP; \
    echo @@PS; ps -eo pid,user,pcpu,pmem,rss,comm --sort=-pcpu 2>/dev/null | head -n 26; \
    echo @@END
    """

    /// 服务探测命令（较慢的独立节奏跑；容错，不存在的工具静默跳过）。
    public static let servicesCommand = """
    LC_ALL=C; \
    echo @@DOCKER; { command -v docker >/dev/null 2>&1 && docker ps --format '{{.Names}}|{{.Status}}|{{.Image}}' 2>/dev/null; } || true; \
    echo @@SYSTEMD; { command -v systemctl >/dev/null 2>&1 && systemctl list-units --type=service --state=running --no-legend --no-pager 2>/dev/null | head -n 40; } || true; \
    echo @@END
    """

    // MARK: 分段

    /// 把带 `@@MARK` 标记的原始输出切成 [marker: [line]]。
    static func sections(_ raw: String) -> [String: [String]] {
        var out: [String: [String]] = [:]
        var current: String? = nil
        for rawLine in raw.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("@@") {
                current = trimmed
                if out[trimmed] == nil { out[trimmed] = [] }
            } else if let c = current {
                out[c, default: []].append(line)
            }
        }
        return out
    }

    // MARK: 主解析：指标（不含 services，由引擎另行合并）

    public static func parseMetrics(_ raw: String, now: Date) -> RemoteSnapshot? {
        let s = sections(raw)
        guard s["@@CPU1"] != nil || s["@@MEM"] != nil else { return nil }

        // dt（秒）
        let t1 = s["@@T1"]?.first.flatMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        let t2 = s["@@T2"]?.first.flatMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        var dt = 0.85
        if let a = t1, let b = t2, b > a { dt = (b - a) / 1_000_000_000.0 }
        if dt <= 0 { dt = 0.85 }

        // CPU
        let cpu = parseCPU(prev: s["@@CPU1"] ?? [], curr: s["@@CPU2"] ?? [])

        // 内存
        let mem = parseMeminfo(s["@@MEM"] ?? [])

        // 负载 / 运行时间
        let load = parseLoad(s["@@LOAD"]?.first ?? "")
        let uptime = Double((s["@@UP"]?.first ?? "").split(separator: " ").first ?? "") ?? 0

        // 磁盘
        let mounts = parseDF(s["@@DF"] ?? [])

        // 网络速率
        let (rx, tx) = parseNetRate(prev: s["@@NET1"] ?? [], curr: s["@@NET2"] ?? [], dt: dt)

        // 磁盘 I/O 速率
        let (rd, wr) = parseDiskRate(prev: s["@@DISK1"] ?? [], curr: s["@@DISK2"] ?? [], dt: dt)

        // 进程
        let procs = parsePS(s["@@PS"] ?? [])

        return RemoteSnapshot(
            timestamp: now,
            cpuUsage: cpu.usage, cpuUser: cpu.user, cpuSystem: cpu.system,
            cpuIOWait: cpu.iowait, cpuSteal: cpu.steal, perCore: cpu.perCore, coreCount: cpu.perCore.count,
            load1: load.0, load5: load.1, load15: load.2, uptimeSeconds: uptime,
            memTotal: mem.total, memAvailable: mem.available, memUsed: mem.used, memCached: mem.cached,
            swapTotal: mem.swapTotal, swapUsed: mem.swapUsed, mounts: mounts,
            netRxBytesPerSec: rx, netTxBytesPerSec: tx,
            diskReadBytesPerSec: rd, diskWriteBytesPerSec: wr,
            tcpRetransRate: nil, processes: procs, services: []
        )
    }

    /// 探测到的远端系统名。
    public static func parseOS(_ raw: String) -> String? {
        sections(raw)["@@OS"]?.first?.trimmingCharacters(in: .whitespaces)
    }

    // MARK: CPU

    struct CPUResult { var usage=0.0; var user=0.0; var system=0.0; var iowait=0.0; var steal=0.0; var perCore=[Double]() }

    /// `/proc/stat` cpu 行：user nice system idle iowait irq softirq steal guest guest_nice
    static func parseCPU(prev: [String], curr: [String]) -> CPUResult {
        func map(_ lines: [String]) -> [String: [Double]] {
            var m: [String: [Double]] = [:]
            for l in lines {
                let f = l.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
                guard let name = f.first, name.hasPrefix("cpu") else { continue }
                m[name] = f.dropFirst().compactMap { Double($0) }
            }
            return m
        }
        let p = map(prev), c = map(curr)
        func delta(_ name: String) -> (usage: Double, user: Double, sys: Double, io: Double, steal: Double)? {
            guard let a = p[name], let b = c[name], a.count >= 5, b.count >= 5 else { return nil }
            func at(_ arr: [Double], _ i: Int) -> Double { i < arr.count ? arr[i] : 0 }
            let dUser = at(b,0)-at(a,0), dNice = at(b,1)-at(a,1), dSys = at(b,2)-at(a,2)
            let dIdle = at(b,3)-at(a,3), dIO = at(b,4)-at(a,4), dIrq = at(b,5)-at(a,5)
            let dSoft = at(b,6)-at(a,6), dSteal = at(b,7)-at(a,7)
            let nonIdle = dUser+dNice+dSys+dIrq+dSoft+dSteal
            let total = nonIdle + dIdle + dIO
            guard total > 0 else { return nil }
            return (max(0, min(1, nonIdle/total)),
                    max(0, (dUser+dNice)/total), max(0, dSys/total),
                    max(0, dIO/total), max(0, dSteal/total))
        }
        var r = CPUResult()
        if let agg = delta("cpu") {
            r.usage = agg.usage; r.user = agg.user; r.system = agg.sys; r.iowait = agg.io; r.steal = agg.steal
        }
        var idx = 0
        while let core = delta("cpu\(idx)") { r.perCore.append(core.usage); idx += 1 }
        return r
    }

    // MARK: 内存

    struct MemResult { var total: Int64=0; var available: Int64=0; var used: Int64=0; var cached: Int64=0; var swapTotal: Int64=0; var swapUsed: Int64=0 }

    static func parseMeminfo(_ lines: [String]) -> MemResult {
        var kv: [String: Int64] = [:]
        for l in lines {
            let parts = l.split(separator: ":")
            guard parts.count >= 2 else { continue }
            let key = parts[0].trimmingCharacters(in: .whitespaces)
            let valStr = parts[1].trimmingCharacters(in: .whitespaces).split(separator: " ").first ?? ""
            if let v = Int64(valStr) { kv[key] = v * 1024 }   // kB → bytes
        }
        var r = MemResult()
        r.total = kv["MemTotal"] ?? 0
        r.available = kv["MemAvailable"] ?? ((kv["MemFree"] ?? 0) + (kv["Cached"] ?? 0) + (kv["Buffers"] ?? 0))
        r.used = max(0, r.total - r.available)
        r.cached = (kv["Cached"] ?? 0) + (kv["Buffers"] ?? 0)
        r.swapTotal = kv["SwapTotal"] ?? 0
        r.swapUsed = max(0, r.swapTotal - (kv["SwapFree"] ?? 0))
        return r
    }

    // MARK: 负载

    static func parseLoad(_ line: String) -> (Double, Double, Double) {
        let f = line.split(separator: " ").compactMap { Double($0) }
        return (f.count > 0 ? f[0] : 0, f.count > 1 ? f[1] : 0, f.count > 2 ? f[2] : 0)
    }

    // MARK: df -kP

    static func parseDF(_ lines: [String]) -> [MountUsage] {
        var out: [MountUsage] = []
        for l in lines {
            let f = l.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            guard f.count >= 6 else { continue }
            if f[0] == "Filesystem" { continue }                      // 表头
            // df -kP 行可能因设备名含空格错列——取「后 5 列」为数值段。
            let mountPoint = f.last!
            let fs = f[0]
            guard let blocks = Int64(f[f.count - 5]), let used = Int64(f[f.count - 4]) else { continue }
            // 过滤伪文件系统
            if fs == "tmpfs" || fs == "devtmpfs" || fs == "overlay" || fs == "shm" || fs.hasPrefix("/dev/loop") { continue }
            if mountPoint.hasPrefix("/dev") || mountPoint.hasPrefix("/sys") || mountPoint.hasPrefix("/proc") || mountPoint.hasPrefix("/run") { continue }
            if blocks <= 0 { continue }
            out.append(MountUsage(filesystem: fs, mountPoint: mountPoint, totalBytes: blocks * 1024, usedBytes: used * 1024))
        }
        // 大到小；根挂载优先
        return out.sorted { ($0.mountPoint == "/" ? 1 : 0, $0.totalBytes) > ($1.mountPoint == "/" ? 1 : 0, $1.totalBytes) }
    }

    // MARK: 网络速率（/proc/net/dev）

    static func parseNetRate(prev: [String], curr: [String], dt: Double) -> (Double, Double) {
        func totals(_ lines: [String]) -> (rx: Double, tx: Double) {
            var rx = 0.0, tx = 0.0
            for l in lines {
                guard let colon = l.firstIndex(of: ":") else { continue }
                let iface = l[..<colon].trimmingCharacters(in: .whitespaces)
                if iface == "lo" || iface.isEmpty { continue }
                let nums = l[l.index(after: colon)...].split(separator: " ", omittingEmptySubsequences: true).compactMap { Double($0) }
                guard nums.count >= 9 else { continue }
                rx += nums[0]      // rx_bytes
                tx += nums[8]      // tx_bytes
            }
            return (rx, tx)
        }
        let a = totals(prev), b = totals(curr)
        guard dt > 0 else { return (0, 0) }
        return (max(0, (b.rx - a.rx) / dt), max(0, (b.tx - a.tx) / dt))
    }

    // MARK: 磁盘 I/O 速率（/proc/diskstats，sector = 512B）

    static func parseDiskRate(prev: [String], curr: [String], dt: Double) -> (Double, Double) {
        func isWholeDisk(_ name: String) -> Bool {
            // 只计整盘，避免分区重复计数
            let patterns = ["sd", "vd", "xvd", "hd"]
            for p in patterns where name.hasPrefix(p) {
                let suffix = name.dropFirst(p.count)
                return !suffix.isEmpty && suffix.allSatisfy { $0.isLetter }   // sda 是整盘，sda1 是分区
            }
            if name.range(of: #"^nvme[0-9]+n[0-9]+$"#, options: .regularExpression) != nil { return true }
            if name.range(of: #"^mmcblk[0-9]+$"#, options: .regularExpression) != nil { return true }
            return false
        }
        func totals(_ lines: [String]) -> (rd: Double, wr: Double) {
            var rd = 0.0, wr = 0.0
            for l in lines {
                let f = l.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
                guard f.count >= 10, isWholeDisk(f[2]) else { continue }
                rd += Double(f[5]) ?? 0     // rd_sectors
                wr += Double(f[9]) ?? 0     // wr_sectors
            }
            return (rd * 512, wr * 512)
        }
        let a = totals(prev), b = totals(curr)
        guard dt > 0 else { return (0, 0) }
        return (max(0, (b.rd - a.rd) / dt), max(0, (b.wr - a.wr) / dt))
    }

    // MARK: 进程表（ps）

    static func parsePS(_ lines: [String]) -> [RemoteProcess] {
        var out: [RemoteProcess] = []
        for l in lines {
            let f = l.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            guard f.count >= 6, let pid = Int(f[0]) else { continue }   // 表头 "PID" 非数字→跳过
            let user = f[1]
            let cpu = Double(f[2]) ?? 0
            let mem = Double(f[3]) ?? 0
            let rssKB = Int64(f[4]) ?? 0
            let comm = f[5...].joined(separator: " ")
            out.append(RemoteProcess(pid: pid, user: user, cpuPercent: cpu, memPercent: mem,
                                     rssBytes: rssKB * 1024, command: comm))
        }
        return out
    }

    // MARK: 服务解析

    public static func parseServices(_ raw: String) -> [RemoteService] {
        let s = sections(raw)
        var out: [RemoteService] = []
        for l in s["@@DOCKER"] ?? [] {
            let p = l.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            guard p.count >= 2, !p[0].isEmpty else { continue }
            let up = p[1].hasPrefix("Up")
            out.append(RemoteService(kind: .docker, name: p[0], status: p[1],
                                     isHealthy: up, detail: p.count > 2 ? p[2] : nil))
        }
        for l in s["@@SYSTEMD"] ?? [] {
            let f = l.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            guard f.count >= 4 else { continue }
            var name = f[0]
            if name.hasSuffix(".service") { name = String(name.dropLast(8)) }
            let active = f[2], sub = f[3]
            out.append(RemoteService(kind: .systemd, name: name, status: sub,
                                     isHealthy: active == "active" && (sub == "running" || sub == "exited"),
                                     detail: f.count > 4 ? f[4...].joined(separator: " ") : nil))
        }
        return out
    }
}
