import SwiftUI
import AppKit
import Foundation
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
        focus == .cpu ? snapshot.byCPU : snapshot.byMemory
    }

    private var displayStatus: ProcessSamplingStatus {
        snapshot.effectiveStatus(
            now: Date(),
            refreshInterval: MonitoringPreferences.refreshInterval().rawValue)
    }

    private var largestMemory: Int64 {
        max(1, usages.map(\.physicalFootprintBytes).max() ?? 1)
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
                    }
                    Spacer(minLength: 0)
                }

                if displayStatus == .unavailable {
                    unavailableBlock
                } else if usages.isEmpty {
                    waitingBlock
                } else {
                    columnHeader
                    VStack(spacing: 3) {
                        ForEach(usages) { usage in
                            usageRow(usage)
                        }
                    }
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
                    .foregroundStyle(XColor.textSecondary)
                    .frame(width: 66, alignment: .trailing)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
            .background(alignment: .leading) {
                GeometryReader { proxy in
                    RoundedRectangle(cornerRadius: XRadius.chip, style: .continuous)
                        .fill(metricColor.opacity(0.10))
                        .frame(width: proxy.size.width * presentation.fillFraction)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(rowAccessibilityLabel(usage, presentation: presentation))
        .help(xLoc("应用检查器"))
    }

    private func rowAccessibilityLabel(
        _ usage: ApplicationUsage,
        presentation: ApplicationUsageRowPresentation
    ) -> String {
        let cpu = focus == .cpu ? presentation.primaryText : presentation.secondaryText
        let memory = focus == .memory ? presentation.primaryText : presentation.secondaryText
        return "\(usage.displayName)，\(xLocF("%d 个进程", usage.memberCount))，CPU \(cpu)，\(xLoc("内存")) \(memory)"
    }

    @ViewBuilder private var samplingPill: some View {
        switch displayStatus {
        case .live:
            XSamplingStatusPill(xLoc("实时"), tone: .live)
        case .warmingUp:
            XSamplingStatusPill(xLoc("采样中"), tone: .warming)
        case .partial:
            XSamplingStatusPill(xLoc("部分数据"), tone: .attention)
        case .stale:
            XSamplingStatusPill(xLoc("数据已过期"), tone: .attention)
        case .unavailable:
            XSamplingStatusPill(xLoc("数据不可用"), tone: .unavailable)
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

    var body: some View {
        Group {
            if let bundlePath, FileManager.default.fileExists(atPath: bundlePath) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: bundlePath))
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
    }
}

public struct ApplicationUsageInspector: View {
    @ObservedObject private var feed: MetricsFeed
    private let identity: ApplicationIdentity
    private let cpuMode: CPUDisplayMode
    private let memoryStyle: MemoryUnitStyle
    @State private var lastUsage: ApplicationUsage?
    @State private var lastSnapshot: ApplicationUsageSnapshot?

    public init(
        feed: MetricsFeed,
        identity: ApplicationIdentity,
        cpuMode: CPUDisplayMode,
        memoryStyle: MemoryUnitStyle
    ) {
        self._feed = ObservedObject(wrappedValue: feed)
        self.identity = identity
        self.cpuMode = cpuMode
        self.memoryStyle = memoryStyle
    }

    private var liveUsage: ApplicationUsage? {
        feed.applicationUsage.application(id: identity)
    }

    private var displayedUsage: ApplicationUsage? {
        liveUsage ?? lastUsage
    }

    /// Falling out of a capped ranking is not proof that an application exited. Confirm GUI app
    /// lifecycle by its representative root PID; background-only groups remain honestly stale.
    private var isConfirmedExited: Bool {
        guard liveUsage == nil, let usage = lastUsage, usage.bundlePath != nil else { return false }
        return NSRunningApplication(processIdentifier: usage.representativePID) == nil
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
        .onChange(of: feed.applicationUsage.sampledAt) { _, _ in rememberLatest() }
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
                    if isConfirmedExited {
                        XSamplingStatusPill(xLoc("已退出"), tone: .attention)
                    } else if liveUsage == nil {
                        XSamplingStatusPill(xLoc("数据已过期"), tone: .attention)
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
                    trendChart(title: "CPU", values: cpu, color: XColor.auroraBlue)
                    trendChart(title: xLoc("内存"), values: memory, color: XColor.auroraViolet)
                }
            }
        }
    }

    private func trendChart(title: String, values: [Double], color: Color) -> some View {
        VStack(alignment: .leading, spacing: XSpacing.xs) {
            Text(title).font(XFont.nano).foregroundStyle(XColor.textTertiary)
            if values.count > 1 {
                XLineChart(values: values, colors: [color], showGrid: true)
                    .frame(height: 86)
            } else {
                Text(xLoc("采样中"))
                    .font(XFont.caption)
                    .foregroundStyle(XColor.textTertiary)
                    .frame(maxWidth: .infinity, minHeight: 86)
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
                            .frame(width: 52, alignment: .leading)
                        Text(member.name)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text(formatCPU(member.cpuRawPercent))
                            .frame(width: 72, alignment: .trailing)
                        Text(member.physicalFootprintBytes.formattedMemory(style: memoryStyle))
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
        }
    }

    @ViewBuilder private var inspectorSamplingPill: some View {
        switch feed.applicationUsage.effectiveStatus(
            now: Date(),
            refreshInterval: MonitoringPreferences.refreshInterval().rawValue
        ) {
        case .live:
            XSamplingStatusPill(xLoc("实时"), tone: .live)
        case .warmingUp:
            XSamplingStatusPill(xLoc("采样中"), tone: .warming)
        case .partial:
            XSamplingStatusPill(xLoc("部分数据"), tone: .attention)
        case .stale:
            XSamplingStatusPill(xLoc("数据已过期"), tone: .attention)
        case .unavailable:
            XSamplingStatusPill(xLoc("数据不可用"), tone: .unavailable)
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
        guard let usage = feed.applicationUsage.application(id: identity) else { return }
        lastUsage = usage
        lastSnapshot = feed.applicationUsage
    }
}
