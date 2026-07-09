import XCTest
@testable import Infrastructure

/// 私有硬件监控 SPI 的冒烟/佐证回归（对应 CSensors.c 的「维护约定（CI）」注释）。
///
/// 三条监控通路（温度 IOHIDEventSystemClient / CPU 频率 IOReport / SSD SMART IONVMeSMART）
/// 全部依赖未公开 SPI，皆做了「缺失即降级」。本测试断言的是**健壮性与合理性**而非「必然有值」：
/// - 无 SPI 的 CI/VM 上返回空/nil 是允许的（正是我们要保住的降级路径，绝不崩溃）；
/// - 一旦返回值，就必须落在物理合理区间，绝不出现被外推/错配污染的荒谬值。
///
/// 真机全量冒烟（要求这三组符号在每代 macOS beta 上仍解析且返回**非空**）通过设置
/// `XICO_RUN_HARDWARE_SMOKE=1` 打开——CI 在配了真实 Apple Silicon 的 runner 上置位即可
/// 把「非空」升级为硬断言；缺硬件的常规 CI 不置位，只跑健壮性/合理性断言，不误伤。
final class SensorSmokeTests: XCTestCase {

    private var requireHardware: Bool {
        ProcessInfo.processInfo.environment["XICO_RUN_HARDWARE_SMOKE"] == "1"
    }

    // MARK: 温度（IOHIDEventSystemClient）

    func testTemperatureReadIsRobustAndPlausible() {
        let reader = SensorReader()
        // 不得崩溃；重复调用（含短 TTL 缓存路径）稳定。
        let temps = reader.temperatures()
        _ = reader.temperatures()   // 命中缓存分支
        for t in temps {
            XCTAssertFalse(t.name.isEmpty, "温度传感器展示名不应为空")
            XCTAssertTrue(t.celsius.isFinite, "温度必须是有限值，不能是 NaN/Inf")
            // 命名温度传感器的物理合理区间（芯片/环境/电池），远超此即为错值。
            XCTAssertTrue(t.celsius > -40 && t.celsius < 150,
                          "温度 \(t.celsius)℃ 落在物理不合理区间")
        }
        let summary = reader.summary()
        if let cpu = summary.cpu { XCTAssertTrue(cpu.isFinite && cpu > -40 && cpu < 150) }
        if let gpu = summary.gpu { XCTAssertTrue(gpu.isFinite && gpu > -40 && gpu < 150) }

        if requireHardware {
            XCTAssertFalse(temps.isEmpty, "真机应至少枚举到一个命名温度传感器（SPI 可能在本代系统失效）")
        }
    }

    // MARK: CPU 频率（IOReport DVFS 驻留 + voltage-states 频率表）

    func testCpuFrequencyIsNilOrPlausible() {
        let sampler = LiveMetricsSampler()
        // 内部阻塞 ~90ms；此处只跑一次，验证不崩溃且值合理。
        guard let freq = sampler.cpuFrequency() else {
            // Intel / VM / 接口变更 → nil 是允许的降级。
            if requireHardware { XCTFail("真机（Apple Silicon）应能读到 CPU 频率") }
            return
        }
        // 佐证守卫（xico_weighted_freq）保证：错配的频率表宁可返回 0 也不外推错值。
        // 因此任一簇要么为 0（无值），要么落在合理 MHz 区间，绝不出现荒谬的外推数。
        for f in [freq.performance, freq.efficiency] {
            XCTAssertTrue(f.isFinite, "频率必须有限")
            XCTAssertTrue(f >= 0 && f < 20_000, "频率 \(f) MHz 落在物理不合理区间（疑似错配外推）")
        }
        // cpuFrequency() 仅在至少一簇 >0 时返回非 nil。
        XCTAssertTrue(freq.performance > 0 || freq.efficiency > 0,
                      "既然返回非 nil，至少一簇应有正频率")
    }

    // MARK: SSD SMART（IONVMeSMARTUserClient）

    func testNVMeSMARTIsNilOrWellFormed() {
        let svc = HardwareProfileService()
        guard let smart = svc.nvmeSMART() else {
            if requireHardware { XCTFail("真机（内置 NVMe）应能读到 SMART") }
            return
        }
        // 字段为计数/温度：不得为负、温度须落在物理合理区间。
        XCTAssertTrue(smart.temperature > -40 && smart.temperature < 150,
                      "SSD 温度 \(smart.temperature)℃ 落在物理不合理区间")
        XCTAssertGreaterThanOrEqual(smart.percentUsed, 0)
        XCTAssertGreaterThanOrEqual(smart.availableSpare, 0)
        XCTAssertGreaterThanOrEqual(smart.powerOnHours, 0)
        XCTAssertGreaterThanOrEqual(smart.unsafeShutdowns, 0)
        XCTAssertTrue(smart.terabytesWritten.isFinite && smart.terabytesWritten >= 0)
    }
}
