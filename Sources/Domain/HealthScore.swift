import Foundation

// MARK: - 可解释健康分（P6·1）
//
// 铁律「诚实指标」：每个子项都可溯源到真实采样值与公开的打分公式；分数只反映机器状态，
// 与「跑没跑扫描」完全解耦（CleanMyMac 假健康分的反面）。
// 子项数据不可用时如实标注（score = nil），总分按可用子项的权重重新归一——绝不编造。

public struct HealthScore: Sendable, Equatable {
    public struct Component: Sendable, Equatable, Identifiable {
        /// 稳定键（disk/memory/temp/thermal/smart）。
        public let id: String
        /// 名称 key（原始中文即 i18n key）。
        public let titleKey: String
        /// 0–100；nil = 该项数据当前不可用（UI 显示「暂无数据」，不计入总分）。
        public let score: Int?
        /// 权重（全量可用时的占比）。
        public let weight: Double
        /// 当前原始值的展示文本（预格式化，如 "48.4 GB 可用 · 9.8%"）。
        public let valueText: String
        /// 打分依据说明 key（公式口径，公开可查）。
        public let basisKey: String
        /// 改善建议 key（一句话）。
        public let adviceKey: String
    }

    public let total: Int
    public let components: [Component]

    // MARK: 纯打分函数（全部可单测）

    /// 磁盘余量：可用 ≥25% 满分；5%–25% 线性 20→100；<5% 按比例落到 20 以下。
    public static func diskScore(freeFraction: Double) -> Int {
        let f = min(max(freeFraction, 0), 1)
        if f >= 0.25 { return 100 }
        if f <= 0 { return 0 }
        if f < 0.05 { return Int((f / 0.05 * 20).rounded()) }
        return Int((20 + (f - 0.05) / 0.20 * 80).rounded())
    }

    /// 内存压力：占用 ≤60% 满分；60%–95% 线性 100→30；>95% 30 以下。
    public static func memoryScore(usedFraction: Double) -> Int {
        let u = min(max(usedFraction, 0), 1)
        if u <= 0.60 { return 100 }
        if u >= 0.98 { return 20 }
        return Int((100 - (u - 0.60) / 0.35 * 70).rounded())
    }

    /// 处理器温度：≤55℃ 满分；55–90℃ 线性 100→30；>90℃ 30 以下（≥100℃ 10）。
    public static func tempScore(celsius: Double) -> Int {
        if celsius <= 55 { return 100 }
        if celsius >= 100 { return 10 }
        if celsius >= 90 { return Int((30 - (celsius - 90) / 10 * 20).rounded()) }
        return Int((100 - (celsius - 55) / 35 * 70).rounded())
    }

    /// 系统热压力（macOS 官方四档）：nominal 100 / fair 70 / serious 40 / critical 10。
    public static func thermalScore(level: Int) -> Int {
        switch level {
        case 0: return 100
        case 1: return 70
        case 2: return 40
        default: return 10
        }
    }

    /// 磁盘健康（SMART）：全部正常 100；任一告警 10。
    public static func smartScore(allHealthy: Bool) -> Int { allHealthy ? 100 : 10 }

    /// 组装总分：权重 磁盘 25 / 内存 20 / 温度 20 / 热压力 20 / SMART 15；
    /// 不可用子项（nil）被剔除，剩余权重归一——总分永远是「已知信息的诚实加权」。
    public static func compute(diskFreeFraction: Double?,
                               diskFreeText: String,
                               memoryUsedFraction: Double?,
                               memoryText: String,
                               cpuTempCelsius: Double?,
                               thermalLevel: Int?,
                               thermalText: String,
                               smartAllHealthy: Bool?,
                               smartText: String) -> HealthScore {
        let comps: [Component] = [
            Component(id: "disk", titleKey: "磁盘余量",
                      score: diskFreeFraction.map(diskScore(freeFraction:)), weight: 0.25,
                      valueText: diskFreeText,
                      basisKey: "可用 ≥25% 满分；5%–25% 线性折算",
                      adviceKey: "运行智能扫描或用空间透镜找出大文件"),
            Component(id: "memory", titleKey: "内存压力",
                      score: memoryUsedFraction.map(memoryScore(usedFraction:)), weight: 0.20,
                      valueText: memoryText,
                      basisKey: "占用 ≤60% 满分；60%–95% 线性折算",
                      adviceKey: "在优化页退出高占用应用或释放内存"),
            Component(id: "temp", titleKey: "处理器温度",
                      score: cpuTempCelsius.flatMap { $0 > 0 ? tempScore(celsius: $0) : nil }, weight: 0.20,
                      valueText: cpuTempCelsius.flatMap { $0 > 0 ? String(format: "%.0f°C", $0) : nil } ?? "—",
                      basisKey: "≤55°C 满分；55–90°C 线性折算",
                      adviceKey: "关闭重负载任务、保证散热通风"),
            Component(id: "thermal", titleKey: "热压力",
                      score: thermalLevel.map(thermalScore(level:)), weight: 0.20,
                      valueText: thermalText,
                      basisKey: "系统热压力四档：正常/偏高/严重/临界",
                      adviceKey: "热压力非正常时系统已在降频，减负或改善散热"),
            Component(id: "smart", titleKey: "磁盘健康",
                      score: smartAllHealthy.map(smartScore(allHealthy:)), weight: 0.15,
                      valueText: smartText,
                      basisKey: "全部卷 SMART 正常即满分",
                      adviceKey: "SMART 告警意味着硬件风险，请立即备份数据"),
        ]
        let available = comps.filter { $0.score != nil }
        let weightSum = available.reduce(0) { $0 + $1.weight }
        let total: Int
        if weightSum > 0 {
            let weighted = available.reduce(0.0) { $0 + Double($1.score!) * $1.weight }
            total = Int((weighted / weightSum).rounded())
        } else {
            total = 0
        }
        return HealthScore(total: total, components: comps)
    }
}
