import Foundation
import IOKit

// 通过 SMC 读取风扇转速（容错：任何失败都返回 nil，绝不崩溃）。
// 结构体布局沿用业界通用的 SMCKit 定义。

private struct SMCVersion {
    var major: UInt8 = 0, minor: UInt8 = 0, build: UInt8 = 0, reserved: UInt8 = 0
    var release: UInt16 = 0
}
private struct SMCPLimitData {
    var version: UInt16 = 0, length: UInt16 = 0
    var cpuPLimit: UInt32 = 0, gpuPLimit: UInt32 = 0, memPLimit: UInt32 = 0
}
private struct SMCKeyInfoData {
    var dataSize: UInt32 = 0
    var dataType: UInt32 = 0
    var dataAttributes: UInt8 = 0
}
private struct SMCParamStruct {
    var key: UInt32 = 0
    var vers = SMCVersion()
    var pLimitData = SMCPLimitData()
    var keyInfo = SMCKeyInfoData()
    var padding: UInt16 = 0
    var result: UInt8 = 0
    var status: UInt8 = 0
    var data8: UInt8 = 0
    var data32: UInt32 = 0
    var bytes: (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8) =
        (0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0)
}

public final class SMCReader: @unchecked Sendable {
    private var conn: io_connect_t = 0
    private let isOpen: Bool
    private let kSMCReadKey: UInt8 = 5
    private let kSMCGetKeyInfo: UInt8 = 9
    private let kernelIndex: UInt32 = 2

    public init() {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { isOpen = false; return }
        var c: io_connect_t = 0
        let r = IOServiceOpen(service, mach_task_self_, 0, &c)
        IOObjectRelease(service)
        if r == kIOReturnSuccess { conn = c; isOpen = true } else { isOpen = false }
    }

    deinit { if isOpen { IOServiceClose(conn) } }

    /// 风扇 #1 转速（RPM），不可用返回 nil
    public func fanRPM() -> Int? {
        guard isOpen else { return nil }
        guard let count = readUInt8(key: "FNum"), count > 0 else { return nil }
        return readFan(index: 0)
    }

    public func fanCount() -> Int {
        guard isOpen, let count = readUInt8(key: "FNum") else { return 0 }
        return Int(count)
    }

    /// 全部风扇的当前/目标/最小/最大转速（Intel 及带风扇的机型）。
    public struct FanReading: Sendable {
        public let index: Int
        public let current: Int
        public let target: Int?
        public let minimum: Int?
        public let maximum: Int?
    }

    public func allFans() -> [FanReading] {
        guard isOpen, let count = readUInt8(key: "FNum"), count > 0 else { return [] }
        var out: [FanReading] = []
        for i in 0..<Int(count) {
            guard let rpm = readFan(index: i) else { continue }
            let tg = readFanValue(key: "F\(i)Tg")   // SMC 目标转速键（部分机型暴露；读不到即 nil）
            let mn = readFanValue(key: "F\(i)Mn")
            let mx = readFanValue(key: "F\(i)Mx")
            out.append(FanReading(index: i, current: rpm, target: tg, minimum: mn, maximum: mx))
        }
        return out
    }

    private func readFan(index: Int) -> Int? {
        let key = "F\(index)Ac"
        guard let val = readKey(key) else { return nil }
        let rpm = decode(val)
        // 现实机型风扇上限约 7000–7500 RPM（本机 M1 MBP 上限 7199）。
        // 收紧到 <9000 过滤 SMC 偶发坏帧（如 15607）——真实值都在此范围内，无副作用。
        return rpm > 100 && rpm < 9000 ? Int(rpm) : nil
    }

    private func readFanValue(key: String) -> Int? {
        guard let val = readKey(key) else { return nil }
        let v = decode(val)
        return v >= 0 && v < 20000 ? Int(v) : nil
    }

    /// 读取一个温度键（摄氏度）。Intel 机型温度键为 sp78/flt 类型；
    /// 值域外（<-40 或 >150）视为无效返回 nil。
    public func temperature(key: String) -> Double? {
        guard isOpen, let val = readKey(key) else { return nil }
        let t = decode(val)
        return (t > -40 && t < 150) ? t : nil
    }

    private func readUInt8(key: String) -> UInt8? {
        guard let val = readKey(key) else { return nil }
        return val.bytes.0
    }

    // MARK: 核心读取

    private func readKey(_ key: String) -> SMCParamStruct? {
        var input = SMCParamStruct()
        var output = SMCParamStruct()
        input.key = fourCharCode(key)

        // 1. 取 key 信息
        input.data8 = kSMCGetKeyInfo
        guard call(&input, &output), output.result == 0 else { return nil }

        // 2. 读取数据
        input.keyInfo.dataSize = output.keyInfo.dataSize
        input.keyInfo.dataType = output.keyInfo.dataType
        input.data8 = kSMCReadKey
        var readOut = SMCParamStruct()
        guard call(&input, &readOut), readOut.result == 0 else { return nil }
        readOut.keyInfo.dataType = output.keyInfo.dataType
        return readOut
    }

    private func call(_ input: inout SMCParamStruct, _ output: inout SMCParamStruct) -> Bool {
        let inputSize = MemoryLayout<SMCParamStruct>.stride
        var outputSize = MemoryLayout<SMCParamStruct>.stride
        let result = IOConnectCallStructMethod(conn, kernelIndex, &input, inputSize, &output, &outputSize)
        return result == kIOReturnSuccess
    }

    private func decode(_ val: SMCParamStruct) -> Double {
        let b = val.bytes
        let type = fourCharString(val.keyInfo.dataType)
        switch type {
        case "flt ":
            var f: Float = 0
            withUnsafeMutableBytes(of: &f) { ptr in
                ptr[0] = b.0; ptr[1] = b.1; ptr[2] = b.2; ptr[3] = b.3
            }
            return Double(f)
        case "fpe2":
            return Double((UInt16(b.0) << 8 | UInt16(b.1)) >> 2)
        case "fp2e":
            return Double((UInt16(b.0) << 8 | UInt16(b.1))) / 16384.0
        case "sp78":
            // 有符号 8.8 定点（Intel 温度键常用）：high.low / 256
            let raw = Int16(bitPattern: UInt16(b.0) << 8 | UInt16(b.1))
            return Double(raw) / 256.0
        default:
            // 兜底当 float
            var f: Float = 0
            withUnsafeMutableBytes(of: &f) { ptr in ptr[0] = b.0; ptr[1] = b.1; ptr[2] = b.2; ptr[3] = b.3 }
            return Double(f)
        }
    }

    private func fourCharCode(_ s: String) -> UInt32 {
        var r: UInt32 = 0
        for ch in s.utf8.prefix(4) { r = (r << 8) | UInt32(ch) }
        return r
    }
    private func fourCharString(_ code: UInt32) -> String {
        let chars = [UInt8((code >> 24) & 0xFF), UInt8((code >> 16) & 0xFF),
                     UInt8((code >> 8) & 0xFF), UInt8(code & 0xFF)]
        return String(bytes: chars, encoding: .ascii) ?? ""
    }
}
