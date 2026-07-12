import Foundation
import SwiftUI
import Domain
import DesignSystem

/// 服务器套件的展示格式化与状态映射（模块内共用）。
enum SrvFmt {
    static func bytes(_ b: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: max(0, b), countStyle: .binary)
    }
    /// 速率 B/s → 人类可读。
    static func rate(_ bps: Double) -> String {
        var x = max(0, bps); let units = ["B/s", "KB/s", "MB/s", "GB/s"]; var i = 0
        while x >= 1024 && i < units.count - 1 { x /= 1024; i += 1 }
        return String(format: i == 0 ? "%.0f %@" : "%.1f %@", x, units[i])
    }
    static func uptime(_ s: Double) -> String {
        let total = Int(max(0, s))
        let d = total / 86400, h = (total % 86400) / 3600, m = (total % 3600) / 60
        if d > 0 { return "\(d)d \(h)h" }
        if h > 0 { return "\(h)h \(m)m" }
        return "\(m)m"
    }
    static func pct(_ f: Double) -> String { "\(Int((max(0, min(1, f)) * 100).rounded()))%" }
}

extension ConnectionState {
    var dotColor: Color {
        switch self {
        case .connected: return XColor.success
        case .connecting: return XColor.warning
        case .degraded: return XColor.warning
        case .failed: return XColor.danger
        case .disconnected: return XColor.idle
        }
    }
    var shortLabel: String {
        switch self {
        case .connected: return xLoc("已连接")
        case .connecting: return xLoc("连接中")
        case .degraded: return xLoc("不稳定")
        case .failed: return xLoc("失败")
        case .disconnected: return xLoc("未连接")
        }
    }
}

/// 主机图标可选调色板索引 → 渐变。
enum ServerPalette {
    static let options: [[Color]] = [
        XColor.metricCPU, XColor.metricMemory, XColor.metricNetwork,
        XColor.metricDisk, [XColor.warning, XColor.accentPink], [XColor.success, XColor.accentTeal]
    ]
    static func colors(_ index: Int) -> [Color] { options[((index % options.count) + options.count) % options.count] }

    static let symbols = ["server.rack", "externaldrive.connected.to.line.below", "cpu", "cloud", "network", "desktopcomputer", "xserve", "internaldrive"]
}
