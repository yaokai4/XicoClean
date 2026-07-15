import XCTest
import Combine
@testable import Features
@testable import Infrastructure
@testable import DesignSystem

/// 菜单栏详情采样门禁的回归测试（审计 P1 回归：`metricsDetailConsumerVisible` 无人置位，
/// 导致主窗口未在前台时菜单栏弹窗里的温度/风扇/GPU 详情停采）。
///
/// 纯判定 `AppModel.detailConsumerVisible(consumerVisible:hasVisibleMainWindow:)` 是 `refreshMetrics`
/// 里 `hasVisibleMetricsConsumer` 的唯一来源；`wantDetail = consumer && …` 又以它为前置，
/// 因此断言这一判定即等价于断言「详情采样是否会跑」。
final class MetricsGatingTests: XCTestCase {
    private static let snapshot = SystemSnapshot(
        cpuUsage: 0.25,
        perCore: [0.25],
        cpuUser: 0.15,
        cpuSystem: 0.10,
        load1: 0.5,
        load5: 0.4,
        load15: 0.3,
        memoryUsed: 4_000,
        memoryTotal: 8_000,
        memoryAvailable: 4_000,
        memoryApp: 2_000,
        memoryWired: 1_000,
        memoryCompressed: 1_000,
        memoryCached: 500,
        swapUsed: 0,
        swapTotal: 0,
        memoryPressure: 1,
        memoryPressureIndex: 0.25,
        pageIns: 0,
        pageOuts: 0,
        diskFree: 1_000,
        diskTotal: 2_000,
        netDownBytesPerSec: 0,
        netUpBytesPerSec: 0,
        diskReadBytesPerSec: 0,
        diskWriteBytesPerSec: 0,
        gpuUsage: nil,
        cpuTemp: nil,
        gpuTemp: nil,
        ssdTemp: nil,
        batteryPercent: nil,
        batteryCharging: false,
        batteryMinutesRemaining: nil,
        thermal: .nominal,
        fanRPM: nil
    )

    private func withMonitoringDefaults(_ body: (UserDefaults) -> Void) {
        let suiteName = "MetricsGatingTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        body(defaults)
    }

    func testMemoryPressureCopyNamesCompositeIndexHonestly() {
        XCTAssertEqual(MemoryPressureDisplayCopy.indexLabel, "Xico 压力指数")
        XCTAssertEqual(MemoryPressureDisplayCopy.stateLabel, "内存压力")
        XCTAssertEqual(MemoryPressureDisplayCopy.percentage(0.654), "65%")
        XCTAssertEqual(MemoryPressureDisplayCopy.percentage(nil), "—")
        XCTAssertTrue(MemoryPressureDisplayCopy.explanation.contains("可用内存"))
        XCTAssertTrue(MemoryPressureDisplayCopy.explanation.contains("压缩"))
        XCTAssertTrue(MemoryPressureDisplayCopy.explanation.contains("交换区"))
        XCTAssertTrue(MemoryPressureDisplayCopy.explanation.contains("不是 macOS 提供的百分比"))
    }

    @MainActor
    func testMemoryHistorySelectionMatchesConfiguredMetric() {
        let feed = MetricsFeed()
        feed.memHistory = [0.25, 0.50]
        feed.memoryPressureHistory = [0.65, 0.85]

        XCTAssertEqual(feed.memoryHistory(for: nil), [0.65, 0.85])
        XCTAssertEqual(feed.memoryHistory(for: "pressure"), [0.65, 0.85])
        XCTAssertEqual(feed.memoryHistory(for: "used"), [0.25, 0.50])
    }

    @MainActor
    func testUsedToPressureTransitionRejectsIncompleteHistoryUntilCompleteIndexArrives() {
        let feed = MetricsFeed()
        feed.memHistory = [0.25]

        feed.recordMemoryPressureIndex(nil, cap: 2)

        XCTAssertEqual(feed.memoryHistory(for: "used"), [0.25])
        XCTAssertEqual(feed.memoryHistory(for: "pressure"), [])

        feed.recordMemoryPressureIndex(0.65, cap: 2)

        XCTAssertEqual(feed.memoryHistory(for: "pressure"), [0.65])
    }

    @MainActor
    func testPressureHistoryPreservesValidPointsRejectsNilAndCapsOldest() {
        let feed = MetricsFeed()
        feed.memoryPressureHistory = [0.25]

        feed.recordMemoryPressureIndex(nil, cap: 2)
        XCTAssertEqual(feed.memoryPressureHistory, [0.25])

        feed.recordMemoryPressureIndex(0.50, cap: 2)
        XCTAssertEqual(feed.memoryPressureHistory, [0.25, 0.50])

        feed.recordMemoryPressureIndex(0.75, cap: 2)
        XCTAssertEqual(feed.memoryPressureHistory, [0.50, 0.75])
    }

    @MainActor
    func testCardOnlyPublishUsesLocalSnapshotStreamWithoutGlobalInvalidation() {
        let feed = MetricsFeed()
        var globalInvalidations = 0
        var localSnapshots = 0
        let global = feed.objectWillChange.sink { globalInvalidations += 1 }
        let local = feed.snapshotPublisher.compactMap { $0 }.sink { _ in localSnapshots += 1 }

        feed.publish(snapshot: Self.snapshot, notifyUI: false)
        XCTAssertEqual(globalInvalidations, 0)
        XCTAssertEqual(localSnapshots, 1)

        feed.publish(snapshot: Self.snapshot, notifyUI: true)
        XCTAssertEqual(globalInvalidations, 1)
        XCTAssertEqual(localSnapshots, 2)
        withExtendedLifetime((global, local)) {}
    }

    func testGlobalMetricsInvalidationRequiresVisibleMainWindow() {
        XCTAssertFalse(AppModel.shouldNotifyGlobalMetricsUI(hasVisibleMainWindow: false))
        XCTAssertTrue(AppModel.shouldNotifyGlobalMetricsUI(hasVisibleMainWindow: true))
    }

    func testRealtimeMonitoringChartsRejectNearContinuousUpdateAnimation() {
        XCTAssertTrue(XMonitoringUpdateCadence.ambient.animatesUpdates)
        XCTAssertFalse(XMonitoringUpdateCadence.realtime.animatesUpdates)
    }

    @MainActor
    func testMenuTelemetryTickDisablesOnlyItsUpdateTransactionAnimations() {
        XCTAssertTrue(MenuMetricPanelTelemetryUpdate.transaction.disablesAnimations)
    }

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

    func testMonitoringPreferencesUseTypedValidatedDefaults() {
        withMonitoringDefaults { defaults in
            XCTAssertEqual(MonitoringPreferences.cpuMode(defaults), .normalized)
            XCTAssertTrue(MonitoringPreferences.combinesProcesses(defaults))
            XCTAssertEqual(MonitoringPreferences.processLimit(defaults), 6)
            XCTAssertEqual(MonitoringPreferences.density(defaults), .balanced)
            XCTAssertEqual(MonitoringPreferences.memoryUnit(defaults), .binary)

            for allowedLimit in [4, 6, 10, 20] {
                defaults.set(allowedLimit, forKey: MonitoringPreferences.processLimitKey)
                XCTAssertEqual(MonitoringPreferences.processLimit(defaults), allowedLimit)
            }
            defaults.set(12, forKey: MonitoringPreferences.processLimitKey)
            XCTAssertEqual(MonitoringPreferences.processLimit(defaults), 6)
        }
    }

    func testGlobalRefreshDefaultsToOneSecondWhenMissing() {
        withMonitoringDefaults { defaults in
            XCTAssertEqual(MonitoringPreferences.refreshInterval(defaults), .oneSecond)
            XCTAssertNil(defaults.object(forKey: MonitoringPreferences.refreshIntervalKey))
        }
    }

    func testGlobalRefreshPreservesEverySupportedChoice() {
        withMonitoringDefaults { defaults in
            for interval in MonitoringRefreshInterval.allCases {
                defaults.set(interval.rawValue, forKey: MonitoringPreferences.refreshIntervalKey)

                XCTAssertEqual(MonitoringPreferences.refreshInterval(defaults), interval)
                XCTAssertEqual(
                    defaults.double(forKey: MonitoringPreferences.refreshIntervalKey),
                    interval.rawValue)
            }
        }
    }

    func testGlobalRefreshMigratesLegacyThreeSecondsToTwoSeconds() {
        withMonitoringDefaults { defaults in
            defaults.set(3.0, forKey: MonitoringPreferences.refreshIntervalKey)

            XCTAssertEqual(MonitoringPreferences.refreshInterval(defaults), .twoSeconds)
            XCTAssertEqual(defaults.double(forKey: MonitoringPreferences.refreshIntervalKey), 2.0)
        }
    }

    func testGlobalRefreshMigratesInvalidValuesToClosestSupportedChoice() {
        withMonitoringDefaults { defaults in
            defaults.set(-4.0, forKey: MonitoringPreferences.refreshIntervalKey)
            XCTAssertEqual(MonitoringPreferences.refreshInterval(defaults), .oneSecond)
            XCTAssertEqual(defaults.double(forKey: MonitoringPreferences.refreshIntervalKey), 1.0)

            defaults.set(99.0, forKey: MonitoringPreferences.refreshIntervalKey)
            XCTAssertEqual(MonitoringPreferences.refreshInterval(defaults), .fiveSeconds)
            XCTAssertEqual(defaults.double(forKey: MonitoringPreferences.refreshIntervalKey), 5.0)
        }
    }

    func testGlobalRefreshMigratesNonfiniteValuesToOneSecond() {
        withMonitoringDefaults { defaults in
            for value in [Double.nan, Double.infinity, -Double.infinity] {
                defaults.set(value, forKey: MonitoringPreferences.refreshIntervalKey)

                XCTAssertEqual(MonitoringPreferences.refreshInterval(defaults), .oneSecond)
                XCTAssertEqual(defaults.double(forKey: MonitoringPreferences.refreshIntervalKey), 1.0)
            }
        }
    }

    func testFocusedMonitoringShotsSkipInteractiveLicenseKeychain() {
        XCTAssertTrue(AppModel.isOfflineRender(arguments: ["Xico", "--monitoring-shots"]))
        XCTAssertFalse(AppModel.isOfflineRender(arguments: ["Xico"]))
    }

    func testCanonicalMonitoringKeysTakePrecedenceOverLegacyTaskFourKeys() {
        withMonitoringDefaults { defaults in
            defaults.set(false, forKey: "xico.monitoring.combinesProcesses")
            defaults.set(4, forKey: "xico.monitoring.processLimit")
            defaults.set(true, forKey: MonitoringPreferences.combinesProcessesKey)
            defaults.set(20, forKey: MonitoringPreferences.processLimitKey)

            XCTAssertTrue(MonitoringPreferences.combinesProcesses(defaults))
            XCTAssertEqual(MonitoringPreferences.processLimit(defaults), 20)
        }
    }

    func testLegacyTaskFourKeysAreReadWhenCanonicalKeysAreAbsent() {
        withMonitoringDefaults { defaults in
            defaults.set(false, forKey: "xico.monitoring.combinesProcesses")
            defaults.set(10, forKey: "xico.monitoring.processLimit")

            XCTAssertFalse(MonitoringPreferences.combinesProcesses(defaults))
            XCTAssertEqual(MonitoringPreferences.processLimit(defaults), 10)
            XCTAssertNil(defaults.object(forKey: MonitoringPreferences.combinesProcessesKey))
            XCTAssertNil(defaults.object(forKey: MonitoringPreferences.processLimitKey))
        }
    }

    func testCanonicalMonitoringPreferenceKeysAreStable() {
        XCTAssertEqual(MonitoringPreferences.cpuModeKey, "xico.monitor.cpuMode")
        XCTAssertEqual(MonitoringPreferences.combinesProcessesKey, "xico.monitor.combinesProcesses")
        XCTAssertEqual(MonitoringPreferences.processLimitKey, "xico.monitor.processLimit")
        XCTAssertEqual(MonitoringPreferences.densityKey, "xico.monitor.density")
        XCTAssertEqual(MonitoringPreferences.memoryUnitKey, "xico.monitor.memoryUnit")
        XCTAssertEqual(MonitoringPreferences.refreshIntervalKey, "xico.mb.interval")
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

    func testMetricCardRequestsOnlyItsRequiredDetailScope() {
        XCTAssertEqual(
            AppModel.detailDemand(cardID: nil, hasVisibleMainWindow: false),
            .none
        )
        XCTAssertEqual(
            AppModel.detailDemand(cardID: "cpu", hasVisibleMainWindow: false),
            .cpu
        )
        XCTAssertEqual(
            AppModel.detailDemand(cardID: "memory", hasVisibleMainWindow: false),
            .memory
        )
        XCTAssertEqual(
            AppModel.detailDemand(cardID: "network", hasVisibleMainWindow: false),
            .hardware
        )
        XCTAssertEqual(
            AppModel.detailDemand(cardID: "combined", hasVisibleMainWindow: false),
            .all
        )
        XCTAssertEqual(
            AppModel.detailDemand(cardID: "cpu", hasVisibleMainWindow: true),
            .all
        )
        XCTAssertTrue(MetricsDetailDemand.cpu.wantsApplicationUsage)
        XCTAssertTrue(MetricsDetailDemand.memory.wantsApplicationUsage)
        XCTAssertFalse(MetricsDetailDemand.hardware.wantsApplicationUsage)
    }

    func testMetricDetailDemandMapsToNarrowLiveMetricsScope() {
        XCTAssertEqual(AppModel.liveMetricsSamplingScope(for: .none), .steady)
        XCTAssertEqual(AppModel.liveMetricsSamplingScope(for: .cpu), .cpuDetail)
        XCTAssertEqual(AppModel.liveMetricsSamplingScope(for: .memory), .memoryDetail)
        XCTAssertEqual(AppModel.liveMetricsSamplingScope(for: .hardware), .extendedHardware)
        XCTAssertEqual(AppModel.liveMetricsSamplingScope(for: .all), .extendedHardware)
    }

    func testCPUFrequencySamplingGateIsVisibleThrottledAndSingleFlight() {
        var gate = CPUFrequencySamplingGate(timeToLive: 30)
        let started = Date(timeIntervalSince1970: 1_000)

        XCTAssertFalse(gate.begin(now: started, isVisible: false))
        XCTAssertTrue(gate.begin(now: started, isVisible: true))
        XCTAssertFalse(gate.begin(now: started.addingTimeInterval(20), isVisible: true))
        gate.finish(now: started)
        XCTAssertFalse(gate.begin(now: started.addingTimeInterval(29.9), isVisible: true))
        XCTAssertTrue(gate.begin(now: started.addingTimeInterval(30.1), isVisible: true))
    }

    func testSlowCPUHardwareSensorsUseOneMinuteCacheWithoutChangingOneHertzMetrics() {
        XCTAssertEqual(CPUFrequencySamplingPolicy.timeToLive, 60)
        XCTAssertEqual(HardwareSensorSamplingPolicy.temperatureTimeToLive, 60)
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
