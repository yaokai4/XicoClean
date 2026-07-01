import Foundation
import os
import OSLog

/// 统一日志门面：主 App 此前零日志，线上「扫不出/清不掉/历史丢了」完全无法定位。
/// 按子系统分 category，所有 catch/try? 失败路径至少落一条 .error。
public enum XicoLog {
    public static let subsystem = "com.xico.app"

    public static let scan = Logger(subsystem: subsystem, category: "scan")
    public static let clean = Logger(subsystem: subsystem, category: "clean")
    public static let helper = Logger(subsystem: subsystem, category: "helper")
    public static let license = Logger(subsystem: subsystem, category: "license")
    public static let update = Logger(subsystem: subsystem, category: "update")
    public static let fs = Logger(subsystem: subsystem, category: "fs")
    public static let history = Logger(subsystem: subsystem, category: "history")
    public static let app = Logger(subsystem: subsystem, category: "app")
}

/// 诊断日志导出：从统一日志系统拉取本 App 最近的日志，写成文本供用户反馈。
/// 用户在「设置 › 导出诊断日志」触发；不含任何自动上报（隐私优先）。
public enum XicoDiagnostics {
    /// 导出最近 `hours` 小时的本 App 日志到目标文件。返回是否成功。
    @discardableResult
    public static func export(to url: URL, hours: Double = 6) -> Bool {
        do {
            let store = try OSLogStore(scope: .currentProcessIdentifier)
            let since = store.position(date: Date(timeIntervalSinceNow: -hours * 3600))
            let entries = try store.getEntries(at: since)
            var lines: [String] = ["Xico 诊断日志 · 最近 \(Int(hours)) 小时", "生成于进程内 OSLogStore", ""]
            for entry in entries {
                guard let log = entry as? OSLogEntryLog, log.subsystem == XicoLog.subsystem else { continue }
                lines.append("[\(log.date)] [\(log.category)] \(log.composedMessage)")
            }
            if lines.count == 3 { lines.append("（无 Xico 日志记录）") }
            try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
            return true
        } catch {
            XicoLog.app.error("导出诊断日志失败：\(error.localizedDescription, privacy: .public)")
            return false
        }
    }
}
