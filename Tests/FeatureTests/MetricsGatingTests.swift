import XCTest
@testable import Features
@testable import Infrastructure

/// 菜单栏详情采样门禁的回归测试（审计 P1 回归：`metricsDetailConsumerVisible` 无人置位，
/// 导致主窗口未在前台时菜单栏弹窗里的温度/风扇/GPU 详情停采）。
///
/// 纯判定 `AppModel.detailConsumerVisible(consumerVisible:hasVisibleMainWindow:)` 是 `refreshMetrics`
/// 里 `hasVisibleMetricsConsumer` 的唯一来源；`wantDetail = consumer && …` 又以它为前置，
/// 因此断言这一判定即等价于断言「详情采样是否会跑」。
final class MetricsGatingTests: XCTestCase {

    func testOpeningDetailConsumerRequestsFreshProcessBaseline() {
        XCTAssertTrue(AppModel.shouldResetProcessBaseline(wasVisible: false, isVisible: true))
        XCTAssertFalse(AppModel.shouldResetProcessBaseline(wasVisible: true, isVisible: true))
    }

    func testOpeningCardWhileMainWindowIsVisibleDoesNotResetAggregateVisibility() {
        XCTAssertFalse(AppModel.shouldPrepareApplicationSampling(
            cardWasVisible: false,
            cardIsVisible: true,
            hasVisibleMainWindow: true))
        XCTAssertTrue(AppModel.shouldPrepareApplicationSampling(
            cardWasVisible: false,
            cardIsVisible: true,
            hasVisibleMainWindow: false))
        XCTAssertFalse(AppModel.shouldPrepareApplicationSampling(
            cardWasVisible: true,
            cardIsVisible: true,
            hasVisibleMainWindow: false))
    }

    func testCoverageBelowNinetyPercentIsPartial() {
        XCTAssertEqual(
            ProcessSamplingStatus.from(
                coverage: .init(enumerated: 100, sampled: 89, denied: 11, exited: 0),
                hasCPU: true),
            .partial)
        XCTAssertEqual(
            ProcessSamplingStatus.from(
                coverage: .init(enumerated: 100, sampled: 95, denied: 5, exited: 0),
                hasCPU: true),
            .live)
    }

    func testExitedChurnDoesNotReduceCoverageButDeniedProcessesDo() {
        let exited = ProcessCoverage(
            enumerated: 100, sampled: 89, denied: 0, exited: 11)
        XCTAssertEqual(exited.fraction, 1, accuracy: 0.001)
        XCTAssertEqual(ProcessSamplingStatus.from(coverage: exited, hasCPU: true), .live)

        let denied = ProcessCoverage(
            enumerated: 100, sampled: 89, denied: 11, exited: 0)
        XCTAssertEqual(denied.fraction, 0.89, accuracy: 0.001)
        XCTAssertEqual(ProcessSamplingStatus.from(coverage: denied, hasCPU: true), .partial)

        XCTAssertEqual(
            ProcessCoverage(enumerated: 2, sampled: 2, denied: 0, exited: 1).fraction,
            1,
            accuracy: 0.001)
        XCTAssertEqual(
            ProcessCoverage(enumerated: 0, sampled: 0, denied: 0, exited: 4).fraction,
            0,
            accuracy: 0.001)
    }

    func testNewApplicationSamplingGenerationRejectsOlderSnapshotsAndDefersRefresh() {
        var lifecycle = ApplicationSamplingLifecycle()
        XCTAssertEqual(lifecycle.baselineEpoch, 0)
        let olderGeneration = lifecycle.generation
        let currentGeneration = lifecycle.prepare()

        XCTAssertFalse(lifecycle.accepts(olderGeneration))
        XCTAssertTrue(lifecycle.accepts(currentGeneration))
        XCTAssertFalse(lifecycle.isReadyToSample)
        XCTAssertFalse(lifecycle.completeReset(
            for: currentGeneration,
            baselineEpoch: 7,
            samplingInFlight: true,
            isVisible: true))
        XCTAssertEqual(lifecycle.baselineEpoch, 7)
        XCTAssertTrue(lifecycle.isReadyToSample)
        XCTAssertTrue(lifecycle.finishSampling(isVisible: true))
        XCTAssertFalse(lifecycle.finishSampling(isVisible: true))
    }

    func testResetCompletionRefreshesImmediatelyOnlyForCurrentVisibleGeneration() {
        var lifecycle = ApplicationSamplingLifecycle()
        let staleGeneration = lifecycle.prepare()
        let currentGeneration = lifecycle.prepare()

        XCTAssertFalse(lifecycle.completeReset(
            for: staleGeneration,
            baselineEpoch: 6,
            samplingInFlight: false,
            isVisible: true))
        XCTAssertFalse(lifecycle.isReadyToSample)
        XCTAssertTrue(lifecycle.completeReset(
            for: currentGeneration,
            baselineEpoch: 7,
            samplingInFlight: false,
            isVisible: true))
        XCTAssertEqual(lifecycle.baselineEpoch, 7)

        let hiddenGeneration = lifecycle.prepare()
        XCTAssertFalse(lifecycle.completeReset(
            for: hiddenGeneration,
            baselineEpoch: 8,
            samplingInFlight: false,
            isVisible: false))
    }

    func testSnapshotBecomesStaleAfterTwoRefreshIntervals() {
        let snapshot = ApplicationUsageSnapshot.liveFixture(
            sampledAt: Date(timeIntervalSince1970: 100))
        XCTAssertEqual(
            snapshot.effectiveStatus(
                now: Date(timeIntervalSince1970: 103),
                refreshInterval: 1),
            .stale)
    }

    func testMonitoringPreferencesUseValidatedDefaults() {
        let defaults = UserDefaults.standard
        let processLimitKey = "xico.monitoring.processLimit"
        let combinesProcessesKey = "xico.monitoring.combinesProcesses"
        let previousLimit = defaults.object(forKey: processLimitKey)
        let previousCombining = defaults.object(forKey: combinesProcessesKey)
        defer {
            if let previousLimit {
                defaults.set(previousLimit, forKey: processLimitKey)
            } else {
                defaults.removeObject(forKey: processLimitKey)
            }
            if let previousCombining {
                defaults.set(previousCombining, forKey: combinesProcessesKey)
            } else {
                defaults.removeObject(forKey: combinesProcessesKey)
            }
        }

        defaults.removeObject(forKey: processLimitKey)
        defaults.removeObject(forKey: combinesProcessesKey)
        XCTAssertEqual(MonitoringPreferences.processLimit(), 6)
        XCTAssertTrue(MonitoringPreferences.combinesProcesses())

        for allowedLimit in [4, 6, 10, 20] {
            defaults.set(allowedLimit, forKey: processLimitKey)
            XCTAssertEqual(MonitoringPreferences.processLimit(), allowedLimit)
        }
        defaults.set(12, forKey: processLimitKey)
        defaults.set(false, forKey: combinesProcessesKey)
        XCTAssertEqual(MonitoringPreferences.processLimit(), 6)
        XCTAssertFalse(MonitoringPreferences.combinesProcesses())
    }

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

private extension ApplicationUsageSnapshot {
    static func liveFixture(sampledAt: Date) -> Self {
        Self(
            byCPU: [],
            byMemory: [],
            status: .live,
            coverage: .init(enumerated: 1, sampled: 1, denied: 0, exited: 0),
            sampledAt: sampledAt,
            source: .local)
    }
}
