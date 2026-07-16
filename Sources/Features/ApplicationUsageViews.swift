import SwiftUI
import AppKit
import Foundation
import Darwin
import Domain
import Infrastructure
import DesignSystem

public enum ApplicationUsageFocus: Equatable, Sendable {
    case cpu
    case memory
}

public extension ApplicationUsageFocus {
    var columnTitles: [String] {
        switch self {
        case .cpu: return [xLoc("应用"), "CPU", xLoc("内存")]
        case .memory: return [xLoc("应用"), xLoc("内存"), "CPU"]
        }
    }
}

public extension ProcessCoverage {
    var displayText: String {
        xLocF("数据覆盖 %d%%", Int((fraction * 100).rounded()))
    }
}

public enum ApplicationUsageListPresentation {
    public static func usages(
        focus: ApplicationUsageFocus,
        snapshot: ApplicationUsageSnapshot
    ) -> [ApplicationUsage] {
        switch focus {
        case .cpu:
            if snapshot.status == .warmingUp, snapshot.byCPU.isEmpty {
                return snapshot.byMemory
            }
            return snapshot.byCPU
        case .memory:
            return snapshot.byMemory
        }
    }

    public static func rowLimit(configuredLimit: Int) -> Int {
        [4, 6, 10, 20].contains(configuredLimit) ? configuredLimit : 6
    }

    public static func viewportHeight(
        rowCount: Int,
        configuredLimit: Int,
        density: MonitoringPanelDensity
    ) -> CGFloat {
        let rowHeight: CGFloat
        let maximum: CGFloat
        // 行高对齐收紧后的真实行（双行内容 ≈ 33pt），视口不再为空白留高。
        switch density {
        case .compact: (rowHeight, maximum) = (32, 208)
        case .balanced: (rowHeight, maximum) = (36, 252)
        case .detailed: (rowHeight, maximum) = (44, 308)
        }
        let boundedCount = min(max(0, rowCount), rowLimit(configuredLimit: configuredLimit))
        return min(maximum, CGFloat(boundedCount) * rowHeight)
    }
}

public struct MemoryPanelHistoryAccumulator: Sendable, Equatable {
    public private(set) var pressure: [Double] = []
    public private(set) var compression: [Double] = []
    public private(set) var swap: [Double] = []
    private let capacity: Int

    public init(capacity: Int = 60) {
        self.capacity = max(0, capacity)
    }

    public mutating func record(
        pressureIndex: Double?,
        totalBytes: Int64,
        compressedBytes: Int64,
        swapUsedBytes: Int64,
        swapTotalBytes: Int64
    ) {
        // A non-nil index proves that the memory and swap inputs for this same frame were complete.
        guard let pressureIndex, pressureIndex.isFinite, totalBytes > 0 else { return }
        let clamp: (Double) -> Double = { min(1, max(0, $0)) }
        pressure.append(clamp(pressureIndex))
        compression.append(clamp(Double(max(0, compressedBytes)) / Double(totalBytes)))
        swap.append(swapTotalBytes > 0
            ? clamp(Double(max(0, swapUsedBytes)) / Double(swapTotalBytes))
            : 0)
        trimToCapacity()
    }

    private mutating func trimToCapacity() {
        if pressure.count > capacity { pressure.removeFirst(pressure.count - capacity) }
        if compression.count > capacity { compression.removeFirst(compression.count - capacity) }
        if swap.count > capacity { swap.removeFirst(swap.count - capacity) }
    }
}

@MainActor
public final class ApplicationIconCache {
    public static let shared = ApplicationIconCache()
    private var storage: [String: NSImage] = [:]

    public init() {}

    public func image(
        for path: String,
        loader: (String) -> NSImage?
    ) -> NSImage? {
        if let cached = storage[path] { return cached }
        guard let loaded = loader(path) else { return nil }
        storage[path] = loaded
        return loaded
    }
}

public enum ApplicationInspectorLifecycleState: Equatable, Sendable {
    case live
    case stale
    case exited
}

public struct ApplicationInspectorLifecycleResolver {
    private let isBundleRunning: (String) -> Bool
    private let processExists: (Int32) -> Bool

    public init(
        isBundleRunning: @escaping (String) -> Bool,
        processExists: @escaping (Int32) -> Bool
    ) {
        self.isBundleRunning = isBundleRunning
        self.processExists = processExists
    }

    public static var system: Self {
        Self(
            isBundleRunning: { bundleIdentifier in
                NSWorkspace.shared.runningApplications.contains {
                    $0.bundleIdentifier == bundleIdentifier
                }
            },
            processExists: { pid in
                if kill(pid, 0) == 0 { return true }
                return errno == EPERM
            })
    }

    public func state(
        live: ApplicationUsage?,
        last: ApplicationUsage?
    ) -> ApplicationInspectorLifecycleState {
        if live != nil { return .live }
        guard let last,
              last.id.rawValue.hasPrefix("bundle:"),
              let bundleIdentifier = last.bundleIdentifier,
              !last.members.isEmpty,
              !isBundleRunning(bundleIdentifier),
              last.members.allSatisfy({ !processExists($0.identity.pid) })
        else { return .stale }
        return .exited
    }
}

@MainActor
public enum MonitoringCardWindowRelationship {
    public static func isInside(eventWindow: NSWindow?, card: NSWindow) -> Bool {
        guard let eventWindow else { return false }
        return eventWindow === card
            || eventWindow.sheetParent === card
            || card.attachedSheet === eventWindow
    }

    public static func shouldDismissWhenResigning(card: NSWindow) -> Bool {
        card.attachedSheet == nil
    }

    public static func shouldCloseForEscape(card: NSWindow) -> Bool {
        card.attachedSheet == nil
    }
}

@MainActor
public enum MonitoringCardWindowLifecycle {
    public static func isCardWindow(_ window: NSWindow) -> Bool {
        window.identifier?.rawValue.hasPrefix("card.") == true
    }

    public static func closeCardWindows(in windows: [NSWindow]) {
        var closed: Set<ObjectIdentifier> = []
        for window in windows where isCardWindow(window) {
            guard closed.insert(ObjectIdentifier(window)).inserted else { continue }
            window.delegate = nil
            // Let Swift ARC own destruction. AppKit's legacy release-on-close can deallocate
            // a Swift-held NSPanel before ARC releases its reference, causing an over-release.
            window.isReleasedWhenClosed = false
            window.orderOut(nil)
            window.contentViewController = nil
            window.contentView = nil
            window.close()
        }
    }
}

public enum MonitoringCardGeometry {
    public static func frame(
        fittingSize: CGSize,
        anchorFrame: CGRect,
        visibleFrame: CGRect,
        margin: CGFloat = 8,
        gap: CGFloat = 6
    ) -> CGRect {
        let availableWidth = max(1, visibleFrame.width - margin * 2)
        let availableHeight = max(1, visibleFrame.height - margin * 2)
        let width = min(max(fittingSize.width, 300), availableWidth)
        let height = min(max(fittingSize.height, 200), availableHeight)
        let proposedX = anchorFrame.midX - width / 2
        let proposedY = anchorFrame.minY - gap - height
        let x = min(max(proposedX, visibleFrame.minX + margin), visibleFrame.maxX - margin - width)
        let y = min(max(proposedY, visibleFrame.minY + margin), visibleFrame.maxY - margin - height)
        return CGRect(x: x, y: y, width: width, height: height)
    }
}

public struct XicoPressureGaugePresentation: Equatable, Sendable {
    public let hasValue: Bool
    public let fraction: Double

    public init(index: Double?) {
        guard let index, index.isFinite else {
            hasValue = false
            fraction = 0
            return
        }
        hasValue = true
        fraction = min(1, max(0, index))
    }
}

public struct ApplicationUsageRowPresentation: Equatable, Sendable {
    public let primaryText: String
    public let secondaryText: String
    public let fillFraction: Double

    public static func make(
        usage: ApplicationUsage,
        focus: ApplicationUsageFocus,
        cpuMode: CPUDisplayMode,
        memoryStyle: MemoryUnitStyle,
        largestMemory: Int64 = 1
    ) -> Self {
        let cpu = usage.cpuPercent(mode: cpuMode)
        let cpuText = cpu.map { String(format: "%.1f%%", $0) } ?? xLoc("采样中")
        let memoryText = usage.physicalFootprintBytes.formattedMemory(style: memoryStyle)
        let unboundedFill: Double
        switch focus {
        case .cpu:
            let maximum = cpuMode == .normalized
                ? 100
                : 100 * Double(ProcessInfo.processInfo.activeProcessorCount)
            unboundedFill = (cpu ?? 0) / maximum
        case .memory:
            unboundedFill = Double(usage.physicalFootprintBytes) / Double(max(1, largestMemory))
        }
        let fill = min(1, max(0, unboundedFill))

        switch focus {
        case .cpu:
            return Self(primaryText: cpuText, secondaryText: memoryText, fillFraction: fill)
        case .memory:
            return Self(primaryText: memoryText, secondaryText: cpuText, fillFraction: fill)
        }
    }
}

public enum ApplicationUsageAccessibility {
    public struct Chart: Equatable, Sendable {
        public let label: String
        public let value: String

        public init(label: String, value: String) {
            self.label = label
            self.value = value
        }
    }

    public static func rowLabel(
        usage: ApplicationUsage,
        presentation: ApplicationUsageRowPresentation,
        focus: ApplicationUsageFocus
    ) -> String {
        let cpu = focus == .cpu ? presentation.primaryText : presentation.secondaryText
        let memory = focus == .memory ? presentation.primaryText : presentation.secondaryText
        return [
            usage.displayName,
            xLocF("%d 个进程", usage.memberCount),
            "CPU \(cpu)",
            "\(xLoc("内存")) \(memory)",
        ].joined(separator: "，")
    }

    public static func statusLabel(
        status: ProcessSamplingStatus,
        coverage: ProcessCoverage
    ) -> String {
        let state: String
        switch status {
        case .live: state = xLoc("实时")
        case .warmingUp: state = xLoc("采样中")
        case .partial: state = xLoc("部分数据")
        case .stale: state = xLoc("数据已过期")
        case .unavailable: state = xLoc("数据不可用")
        }
        return "\(state)，\(coverage.displayText)"
    }

    public static func chart(label: String, latestValue: String?) -> Chart {
        Chart(label: label, value: latestValue ?? xLoc("采样中"))
    }
}

public struct ApplicationUsageList: View {
    private let focus: ApplicationUsageFocus
    private let snapshot: ApplicationUsageSnapshot
    private let cpuMode: CPUDisplayMode
    private let memoryStyle: MemoryUnitStyle
    private let totalMemory: Int64
    private let onSelect: (ApplicationIdentity) -> Void

    public init(
        focus: ApplicationUsageFocus,
        snapshot: ApplicationUsageSnapshot,
        cpuMode: CPUDisplayMode,
        memoryStyle: MemoryUnitStyle,
        totalMemory: Int64,
        onSelect: @escaping (ApplicationIdentity) -> Void
    ) {
        self.focus = focus
        self.snapshot = snapshot
        self.cpuMode = cpuMode
        self.memoryStyle = memoryStyle
        self.totalMemory = totalMemory
        self.onSelect = onSelect
    }

    private var usages: [ApplicationUsage] {
        ApplicationUsageListPresentation.usages(focus: focus, snapshot: snapshot)
    }

    private var displayStatus: ProcessSamplingStatus {
        snapshot.effectiveStatus(
            now: Date(),
            refreshInterval: MonitoringPreferences.refreshInterval().rawValue)
    }

    private var largestMemory: Int64 {
        max(1, usages.map(\.physicalFootprintBytes).max() ?? 1)
    }

    private var viewportHeight: CGFloat {
        ApplicationUsageListPresentation.viewportHeight(
            rowCount: usages.count,
            configuredLimit: MonitoringPreferences.processLimit(),
            density: MonitoringPreferences.density())
    }

    public var body: some View {
        XMonitoringSection {
            VStack(alignment: .leading, spacing: XSpacing.s) {
                HStack(spacing: XSpacing.s) {
                    Text(xLoc("应用"))
                        .font(XFont.captionEmphasis)
                        .foregroundStyle(XColor.textPrimary)
                    samplingPill
                    if displayStatus == .partial || displayStatus == .stale {
                        Text(snapshot.coverage.displayText)
                            .font(XFont.nano)
                            .foregroundStyle(XColor.textTertiary)
                            .accessibilityHidden(true)
                    }
                    Spacer(minLength: 0)
                }

                if displayStatus == .unavailable {
                    unavailableBlock
                } else if usages.isEmpty {
                    waitingBlock
                } else {
                    columnHeader
                    ScrollView(.vertical) {
                        LazyVStack(spacing: 2) {
                            ForEach(usages) { usage in
                                usageRow(usage)
                            }
                        }
                    }
                    .frame(
                        minHeight: min(84, viewportHeight),
                        idealHeight: viewportHeight,
                        maxHeight: viewportHeight)
                }
            }
        }
    }

    private var columnHeader: some View {
        HStack(spacing: XSpacing.s) {
            Text(focus.columnTitles[0])
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(focus.columnTitles[1])
                .frame(width: 66, alignment: .trailing)
            Text(focus.columnTitles[2])
                .frame(width: 66, alignment: .trailing)
        }
        .font(XFont.nano)
        .lineLimit(1)
        .minimumScaleFactor(0.7)   // de "Arbeitsspeicher" 在 66pt 定宽列里缩放而非折行
        .foregroundStyle(XColor.textTertiary)
        .padding(.horizontal, 6)
        .accessibilityHidden(true)
    }

    private func usageRow(_ usage: ApplicationUsage) -> some View {
        let presentation = ApplicationUsageRowPresentation.make(
            usage: usage,
            focus: focus,
            cpuMode: cpuMode,
            memoryStyle: memoryStyle,
            largestMemory: focus == .memory ? max(1, totalMemory) : largestMemory)
        let metricColor = focus == .cpu ? XColor.auroraBlue : XColor.auroraViolet

        return Button {
            onSelect(usage.id)
        } label: {
            HStack(spacing: XSpacing.s) {
                ApplicationIcon(bundlePath: usage.bundlePath)
                VStack(alignment: .leading, spacing: 0) {
                    Text(usage.displayName)
                        .font(XFont.caption)
                        .foregroundStyle(XColor.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if usage.memberCount > 1 {
                        Text(xLocF("%d 个进程", usage.memberCount))
                            .font(XFont.nano)
                            .foregroundStyle(XColor.textTertiary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                VStack(alignment: .trailing, spacing: 0) {
                    Text(presentation.primaryText)
                        .font(XFont.captionEmphasis.monospacedDigit())
                        .foregroundStyle(metricColor)
                    if focus == .memory, totalMemory > 0 {
                        Text(String(
                            format: "%.1f%%",
                            Double(max(0, usage.physicalFootprintBytes)) / Double(totalMemory) * 100))
                        .font(XFont.nano.monospacedDigit())
                        .foregroundStyle(XColor.textTertiary)
                    }
                }
                .frame(width: 66, alignment: .trailing)
                Text(presentation.secondaryText)
                    .font(XFont.microMono)
                    .monospacedDigit()
                    .foregroundStyle(XColor.textSecondary)
                    .frame(width: 66, alignment: .trailing)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .contentShape(Rectangle())
            .background(alignment: .leading) {
                GeometryReader { proxy in
                    RoundedRectangle(cornerRadius: XRadius.chip, style: .continuous)
                        .fill(metricColor.opacity(0.10))
                        .frame(width: proxy.size.width * presentation.fillFraction)
                        .accessibilityHidden(true)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(ApplicationUsageAccessibility.rowLabel(
            usage: usage,
            presentation: presentation,
            focus: focus))
        .help(xLoc("应用检查器"))
    }

    @ViewBuilder private var samplingPill: some View {
        switch displayStatus {
        case .live:
            XSamplingStatusPill(xLoc("实时"), tone: .live, accessibilityDetail: snapshot.coverage.displayText)
        case .warmingUp:
            XSamplingStatusPill(xLoc("采样中"), tone: .warming, accessibilityDetail: snapshot.coverage.displayText)
        case .partial:
            XSamplingStatusPill(xLoc("部分数据"), tone: .attention, accessibilityDetail: snapshot.coverage.displayText)
        case .stale:
            XSamplingStatusPill(xLoc("数据已过期"), tone: .attention, accessibilityDetail: snapshot.coverage.displayText)
        case .unavailable:
            XSamplingStatusPill(xLoc("数据不可用"), tone: .unavailable, accessibilityDetail: snapshot.coverage.displayText)
        }
    }

    private var unavailableBlock: some View {
        HStack(spacing: XSpacing.s) {
            Image(systemName: "arrow.clockwise.circle")
                .foregroundStyle(XColor.textTertiary)
            Text(xLoc("数据不可用"))
                .font(XFont.captionEmphasis)
                .foregroundStyle(XColor.textPrimary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, XSpacing.xs)
    }

    private var waitingBlock: some View {
        HStack(spacing: XSpacing.s) {
            ProgressView().controlSize(.small)
            Text(xLoc("采样中"))
                .font(XFont.caption)
                .foregroundStyle(XColor.textSecondary)
        }
        .padding(.vertical, XSpacing.xs)
    }
}

private struct ApplicationIcon: View {
    let bundlePath: String?
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
            } else {
                Image(systemName: "gearshape.fill")
                    .resizable()
                    .scaledToFit()
                    .padding(3)
                    .foregroundStyle(XColor.textTertiary)
            }
        }
        .frame(width: 18, height: 18)
        .accessibilityHidden(true)
        .task(id: bundlePath) {
            image = nil
            guard let bundlePath else { return }
            image = ApplicationIconCache.shared.image(for: bundlePath) {
                NSWorkspace.shared.icon(forFile: $0)
            }
        }
    }
}

public struct ApplicationUsageInspector: View {
    private let feed: MetricsFeed
    private let identity: ApplicationIdentity
    private let cpuMode: CPUDisplayMode
    private let memoryStyle: MemoryUnitStyle
    private let lifecycleResolver: ApplicationInspectorLifecycleResolver
    @State private var lastUsage: ApplicationUsage?
    @State private var lastSnapshot: ApplicationUsageSnapshot?

    public init(
        feed: MetricsFeed,
        identity: ApplicationIdentity,
        cpuMode: CPUDisplayMode,
        memoryStyle: MemoryUnitStyle,
        lifecycleResolver: ApplicationInspectorLifecycleResolver = .system
    ) {
        self.feed = feed
        self.identity = identity
        self.cpuMode = cpuMode
        self.memoryStyle = memoryStyle
        self.lifecycleResolver = lifecycleResolver
    }

    private var liveUsage: ApplicationUsage? {
        feed.applicationUsage.application(id: identity)
    }

    private var displayedUsage: ApplicationUsage? {
        liveUsage ?? lastUsage
    }

    private var lifecycleState: ApplicationInspectorLifecycleState {
        lifecycleResolver.state(live: liveUsage, last: lastUsage)
    }

    public var body: some View {
        Group {
            if let usage = displayedUsage {
                inspectorContent(usage)
            } else {
                ContentUnavailableView(
                    xLoc("数据不可用"),
                    systemImage: "waveform.path.ecg",
                    description: Text(xLoc("采样中")))
            }
        }
        .padding(XSpacing.l)
        .frame(minWidth: 520, idealWidth: 560, minHeight: 480, idealHeight: 600)
        .background(.regularMaterial)
        .onAppear(perform: rememberLatest)
        .onReceive(feed.snapshotPublisher.compactMap { $0 }) { _ in rememberLatest() }
    }

    private func inspectorContent(_ usage: ApplicationUsage) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: XSpacing.m) {
                HStack(spacing: XSpacing.m) {
                    ApplicationIcon(bundlePath: usage.bundlePath)
                        .scaleEffect(1.8)
                        .frame(width: 36, height: 36)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(usage.displayName)
                            .font(XFont.title2)
                            .foregroundStyle(XColor.textPrimary)
                        if let bundleIdentifier = usage.bundleIdentifier {
                            Text(bundleIdentifier)
                                .font(XFont.captionMono)
                                .foregroundStyle(XColor.textTertiary)
                        }
                    }
                    Spacer()
                    if lifecycleState == .exited {
                        XSamplingStatusPill(
                            xLoc("已退出"),
                            tone: .attention,
                            accessibilityDetail: (lastSnapshot ?? feed.applicationUsage).coverage.displayText)
                    } else if lifecycleState == .stale {
                        XSamplingStatusPill(
                            xLoc("数据已过期"),
                            tone: .attention,
                            accessibilityDetail: (lastSnapshot ?? feed.applicationUsage).coverage.displayText)
                    } else {
                        inspectorSamplingPill
                    }
                }

                currentMetrics(usage)
                trendSection(usage)
                memberSection(usage)
                sourceSection
            }
        }
    }

    private func currentMetrics(_ usage: ApplicationUsage) -> some View {
        XMonitoringSection {
            VStack(alignment: .leading, spacing: XSpacing.s) {
                Text(xLoc("应用检查器"))
                    .font(XFont.captionEmphasis)
                    .foregroundStyle(XColor.textPrimary)
                HStack(alignment: .top, spacing: XSpacing.xl) {
                    XAlignedValueColumn(
                        label: cpuMode == .normalized ? "CPU · 0–100%" : "CPU · 0–N×100%",
                        value: formatCPU(usage.cpuPercent(mode: cpuMode)),
                        emphasized: true,
                        alignment: .leading)
                    XAlignedValueColumn(
                        label: "CPU · 0–N×100%",
                        value: formatCPU(usage.cpuRawPercent),
                        alignment: .leading)
                    XAlignedValueColumn(
                        label: "CPU · 0–100%",
                        value: formatCPU(usage.cpuNormalizedPercent),
                        alignment: .leading)
                    XAlignedValueColumn(
                        label: xLoc("物理内存"),
                        value: usage.physicalFootprintBytes.formattedMemory(style: memoryStyle),
                        emphasized: true,
                        alignment: .leading)
                    XAlignedValueColumn(
                        label: xLoc("峰值内存"),
                        value: usage.peakFootprintBytes.formattedMemory(style: memoryStyle),
                        alignment: .leading)
                    Spacer(minLength: 0)
                }
            }
        }
    }

    private func trendSection(_ usage: ApplicationUsage) -> some View {
        let cpu = cpuTrend(usage)
        let memoryValues = Array(usage.trend.memoryBytes.suffix(60))
        let memoryMax = max(memoryValues.max() ?? 1, 1)
        let memory = memoryValues.map { Double(max(0, $0)) / Double(memoryMax) }

        return XMonitoringSection {
            VStack(alignment: .leading, spacing: XSpacing.s) {
                Text("60 s · CPU / \(xLoc("内存"))")
                    .font(XFont.captionEmphasis)
                    .foregroundStyle(XColor.textPrimary)
                HStack(spacing: XSpacing.m) {
                    trendChart(
                        title: "CPU",
                        values: cpu,
                        latestValue: usage.cpuPercent(mode: cpuMode).map { String(format: "%.1f%%", $0) },
                        color: XColor.auroraBlue)
                    trendChart(
                        title: xLoc("内存"),
                        values: memory,
                        latestValue: usage.trend.memoryBytes.last?.formattedMemory(style: memoryStyle),
                        color: XColor.auroraViolet)
                }
            }
        }
    }

    private func trendChart(
        title: String,
        values: [Double],
        latestValue: String?,
        color: Color
    ) -> some View {
        let accessibility = ApplicationUsageAccessibility.chart(label: title, latestValue: latestValue)
        return VStack(alignment: .leading, spacing: XSpacing.xs) {
            Text(title).font(XFont.nano).foregroundStyle(XColor.textTertiary)
                .accessibilityHidden(true)
            if values.count > 1 {
                XLineChart(values: values, colors: [color], showGrid: true)
                    .frame(height: 86)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(accessibility.label)
                    .accessibilityValue(accessibility.value)
            } else {
                Text(xLoc("采样中"))
                    .font(XFont.caption)
                    .foregroundStyle(XColor.textTertiary)
                    .frame(maxWidth: .infinity, minHeight: 86)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(accessibility.label)
                    .accessibilityValue(accessibility.value)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func memberSection(_ usage: ApplicationUsage) -> some View {
        XMonitoringSection {
            VStack(alignment: .leading, spacing: XSpacing.s) {
                HStack {
                    Text(xLoc("应用聚合"))
                        .font(XFont.captionEmphasis)
                        .foregroundStyle(XColor.textPrimary)
                    Spacer()
                    Text(xLocF("%d 个进程", usage.memberCount))
                        .font(XFont.nano)
                        .foregroundStyle(XColor.textTertiary)
                }
                memberHeader
                ForEach(usage.members) { member in
                    HStack(spacing: XSpacing.s) {
                        Text("\(member.identity.pid)")
                            .monospacedDigit()
                            .frame(width: 52, alignment: .leading)
                        Text(member.name)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text(formatCPU(member.cpuRawPercent))
                            .monospacedDigit()
                            .frame(width: 72, alignment: .trailing)
                        Text(member.physicalFootprintBytes.formattedMemory(style: memoryStyle))
                            .monospacedDigit()
                            .frame(width: 88, alignment: .trailing)
                    }
                    .font(XFont.captionMono)
                    .foregroundStyle(XColor.textSecondary)
                    .padding(.vertical, 2)
                }
            }
        }
    }

    private var memberHeader: some View {
        HStack(spacing: XSpacing.s) {
            Text("PID").frame(width: 52, alignment: .leading)
            Text("NAME").frame(maxWidth: .infinity, alignment: .leading)
            Text("CPU").frame(width: 72, alignment: .trailing)
            Text(xLoc("内存")).frame(width: 88, alignment: .trailing)
        }
        .font(XFont.nano)
        .foregroundStyle(XColor.textTertiary)
    }

    private var sourceSection: some View {
        let snapshot = liveUsage == nil ? lastSnapshot : feed.applicationUsage
        return XMonitoringSection {
            VStack(alignment: .leading, spacing: XSpacing.xs) {
                Text(xLoc("采样来源"))
                    .font(XFont.captionEmphasis)
                    .foregroundStyle(XColor.textPrimary)
                if let snapshot {
                    metadataRow(
                        "antenna.radiowaves.left.and.right",
                        snapshot.source == .helperEnhanced ? xLoc("助手增强") : xLoc("本地采样"))
                    metadataRow(
                        "clock",
                        snapshot.sampledAt.formatted(date: .omitted, time: .standard))
                    metadataRow("checkmark.shield", snapshot.coverage.displayText)
                }
            }
        }
    }

    private func metadataRow(_ systemImage: String, _ value: String) -> some View {
        HStack {
            Image(systemName: systemImage)
                .font(XFont.caption)
                .foregroundStyle(XColor.textTertiary)
                .frame(width: 16)
            Spacer()
            Text(value).font(XFont.captionMono).foregroundStyle(XColor.textSecondary)
                .monospacedDigit()
        }
    }

    @ViewBuilder private var inspectorSamplingPill: some View {
        switch feed.applicationUsage.effectiveStatus(
            now: Date(),
            refreshInterval: MonitoringPreferences.refreshInterval().rawValue
        ) {
        case .live:
            XSamplingStatusPill(
                xLoc("实时"), tone: .live,
                accessibilityDetail: feed.applicationUsage.coverage.displayText)
        case .warmingUp:
            XSamplingStatusPill(
                xLoc("采样中"), tone: .warming,
                accessibilityDetail: feed.applicationUsage.coverage.displayText)
        case .partial:
            XSamplingStatusPill(
                xLoc("部分数据"), tone: .attention,
                accessibilityDetail: feed.applicationUsage.coverage.displayText)
        case .stale:
            XSamplingStatusPill(
                xLoc("数据已过期"), tone: .attention,
                accessibilityDetail: feed.applicationUsage.coverage.displayText)
        case .unavailable:
            XSamplingStatusPill(
                xLoc("数据不可用"), tone: .unavailable,
                accessibilityDetail: feed.applicationUsage.coverage.displayText)
        }
    }

    private func cpuTrend(_ usage: ApplicationUsage) -> [Double] {
        let coreCount = Double(max(ProcessInfo.processInfo.activeProcessorCount, 1))
        return usage.trend.cpuRaw.suffix(60).map { raw in
            let percent = cpuMode == .normalized ? raw / coreCount : raw
            let maximum = cpuMode == .normalized ? 100 : coreCount * 100
            return min(1, max(0, percent / maximum))
        }
    }

    private func formatCPU(_ value: Double?) -> String {
        value.map { String(format: "%.1f%%", $0) } ?? xLoc("采样中")
    }

    private func rememberLatest() {
        let snapshot = feed.applicationUsage
        if let usage = snapshot.application(id: identity) {
            lastUsage = usage
        }
        lastSnapshot = snapshot
    }
}
