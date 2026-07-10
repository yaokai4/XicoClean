import Foundation

/// 磁盘测速的接口代际参考区间（P5·H4）：给「3000 MB/s」一个语境——这算什么水平？
/// 参考值为业界典型顺序读速（MB/s），写死在 Domain、UI 侧标注「参考值」；
/// 只做「达到 X 水准」的正向评级，绝不做「你的盘不行」式的贬损文案。
public enum DiskSpeedReference {
    /// 评级键（原始中文即 i18n key，显示处 xLoc）。返回 nil = 速度过低/无效，不评级。
    public static func ratingKey(readMBps: Double) -> String? {
        switch readMBps {
        case 6500...:        return "达到 NVMe Gen5 水准"
        case 4800..<6500:    return "达到 NVMe Gen4 水准"
        case 2500..<4800:    return "达到 NVMe Gen3 水准"
        case 800..<2500:     return "达到入门 NVMe 水准"
        case 350..<800:      return "达到 SATA 固态水准"
        case 60..<350:       return "达到外置 USB 硬盘水准"
        default:             return nil
        }
    }
}
