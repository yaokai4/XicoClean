import Foundation

// MARK: - 视频格式适配参考表（对标并超越 Blackmagic「Will it Work / How Fast」）
//
// 参考值来源（docs/14 附录 · 2026-07 调研）：
// - ProRes：Apple ProRes White Paper (April 2022) 官方目标码率，MB/s = Mb/s ÷ 8；
// - Blackmagic RAW：官方公式 MB/s ≈ W × H × 1.5 字节(12-bit) ÷ 压缩比 × fps ÷ 10⁶
//   （已对官方公布锚点验证：12K 5:1 24fps → 573 ≈ 官方 578；UHD 3:1 30fps → 124 ≈ 官方 127）；
// - H.265：相机内录 HEVC 常见上限 50–200 Mb/s 档；
// - 判定比 Blackmagic 更聪明：三态 ✓/⚠/✗——实测 ≥ 码率×1.2 才给 ✓（官方手册自己都说
//   「勾但帧率刚好达标 = marginal 不可靠」，我们把这层含糊做成显式的 ⚠ 边缘态）。

public enum VideoFitVerdict: Sendable {
    case ok        // ≥ 码率 × 1.2：稳
    case marginal  // 1.0×–1.2×：能跑但边缘（掉帧风险）
    case no        // < 码率：不行

    public static func judge(measuredMBps: Double, requiredMBps: Double) -> VideoFitVerdict {
        if measuredMBps >= requiredMBps * 1.2 { return .ok }
        if measuredMBps >= requiredMBps { return .marginal }
        return .no
    }
}

/// 一行视频格式：各编解码所需 MB/s（nil = 该格式无此档位）。
public struct VideoFormatRow: Identifiable, Sendable {
    public let id: String
    /// 展示名（中文字面量即 i18n key；分辨率/帧率等专有记号原样透传）。
    public let title: String
    public let h265: Double?
    public let proRes422HQ: Double?
    public let proRes4444XQ: Double?
    public let brawFiveToOne: Double?

    public init(id: String, title: String, h265: Double?, proRes422HQ: Double?,
                proRes4444XQ: Double?, brawFiveToOne: Double?) {
        self.id = id
        self.title = title
        self.h265 = h265
        self.proRes422HQ = proRes422HQ
        self.proRes4444XQ = proRes4444XQ
        self.brawFiveToOne = brawFiveToOne
    }
}

public enum VideoFitReference {
    /// 编解码列（展示序）。中文字面量即 i18n key。
    public static let codecTitles = ["H.265", "ProRes 422 HQ", "ProRes 4444 XQ", "BRAW 5:1"]

    /// 行集：从入门（人人绿勾的 H.265）到极限（12K RAW）。所需值单位 MB/s。
    public static let rows: [VideoFormatRow] = [
        VideoFormatRow(id: "1080p30", title: "1080p30",
                       h265: 6.3, proRes422HQ: 27.5, proRes4444XQ: 61.9, brawFiveToOne: 18.7),
        VideoFormatRow(id: "1080p60", title: "1080p60",
                       h265: 12.5, proRes422HQ: 55.0, proRes4444XQ: 123.8, brawFiveToOne: 37.3),
        VideoFormatRow(id: "2kdci24", title: "2K DCI 24",
                       h265: 12.5, proRes422HQ: 25.1, proRes4444XQ: 56.6, brawFiveToOne: 15.9),
        VideoFormatRow(id: "uhd30", title: "4K UHD 30",
                       h265: 12.5, proRes422HQ: 110.5, proRes4444XQ: 248.6, brawFiveToOne: 74.6),
        VideoFormatRow(id: "uhd60", title: "4K UHD 60",
                       h265: 25.0, proRes422HQ: 221.0, proRes4444XQ: 497.1, brawFiveToOne: 149.3),
        VideoFormatRow(id: "4kdci60", title: "4K DCI 60",
                       h265: 25.0, proRes422HQ: 235.8, proRes4444XQ: 530.3, brawFiveToOne: 159.3),
        VideoFormatRow(id: "6k60", title: "6K 60",
                       h265: nil, proRes422HQ: 530.3, proRes4444XQ: 1193.1, brawFiveToOne: 382.2),
        VideoFormatRow(id: "8k30", title: "8K 30",
                       h265: 25.0, proRes422HQ: 471.4, proRes4444XQ: 1060.6, brawFiveToOne: 318.5),
        VideoFormatRow(id: "12k24", title: "12K 24",
                       h265: nil, proRes422HQ: nil, proRes4444XQ: nil, brawFiveToOne: 573.3),
    ]

    /// How-Fast：给定实测吞吐与所需码率，可持续的帧率（fps = 实测 ÷ 每帧字节；此处直接按
    /// 码率折算：可达 fps = 名义 fps × 实测/所需）。上限截到 999 防荒谬数字。
    public static func sustainableFPS(measuredMBps: Double, requiredMBps: Double, nominalFPS: Double) -> Int {
        guard requiredMBps > 0 else { return 0 }
        return Int(min(999, nominalFPS * measuredMBps / requiredMBps))
    }
}
