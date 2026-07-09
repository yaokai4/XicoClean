import XCTest
@testable import Features

/// 菜单栏详情采样门禁的回归测试（审计 P1 回归：`metricsDetailConsumerVisible` 无人置位，
/// 导致主窗口未在前台时菜单栏弹窗里的温度/风扇/GPU 详情停采）。
///
/// 纯判定 `AppModel.detailConsumerVisible(consumerVisible:hasVisibleMainWindow:)` 是 `refreshMetrics`
/// 里 `hasVisibleMetricsConsumer` 的唯一来源；`wantDetail = consumer && …` 又以它为前置，
/// 因此断言这一判定即等价于断言「详情采样是否会跑」。
final class MetricsGatingTests: XCTestCase {

    /// 回归核心：弹窗打开(consumerVisible=true) 时，即便无可见主窗口，也必须触发详情采样。
    /// MenuBarController 已在 showPopover 置位、popoverDidClose 复位该标志。
    func testPopoverVisibleForcesDetailSamplingWithoutMainWindow() {
        XCTAssertTrue(
            AppModel.detailConsumerVisible(consumerVisible: true, hasVisibleMainWindow: false),
            "弹窗打开即应视为详情消费者可见，纵无前台主窗口——否则温度/风扇/GPU 详情停采")
    }

    /// 主窗口在前台可见（无弹窗）同样应完整采样，不回归监视/详情页体验。
    func testFrontMainWindowAloneEnablesDetailSampling() {
        XCTAssertTrue(
            AppModel.detailConsumerVisible(consumerVisible: false, hasVisibleMainWindow: true))
    }

    /// 常驻菜单栏且既无弹窗、又无前台主窗口时，跳过昂贵详情采样（审计 P2 常驻满载的收益不被抵消）。
    func testNoConsumerNoWindowSkipsDetailSampling() {
        XCTAssertFalse(
            AppModel.detailConsumerVisible(consumerVisible: false, hasVisibleMainWindow: false),
            "无弹窗、无前台主窗口时应跳过详情采样")
    }
}
