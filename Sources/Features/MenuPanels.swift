import SwiftUI
import Infrastructure
import DesignSystem

public enum MenuMetric: Sendable {
    case cpu, memory, network

    var title: String {
        switch self { case .cpu: return xLoc("处理器"); case .memory: return xLoc("内存"); case .network: return xLoc("网络") }
    }
    var icon: String {
        switch self {
        case .cpu: return "cpu"
        case .memory: return "memorychip"
        case .network: return "antenna.radiowaves.left.and.right"
        }
    }
    var colors: [Color] {
        switch self {
        case .cpu: return [XColor.auroraBlue, XColor.auroraViolet]
        case .memory: return [XColor.auroraViolet, XColor.auroraRose]
        case .network: return [XColor.accentTeal, XColor.auroraBlue]
        }
    }
}

/// 单指标的菜单栏详情面板（CPU / 内存 / 网络 各一个，独立菜单栏项）
public struct MenuMetricPanel: View {
    @ObservedObject var model: AppModel
    let metric: MenuMetric

    public init(model: AppModel, metric: MenuMetric) {
        self.model = model
        self.metric = metric
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: XSpacing.m) {
            HStack(spacing: XSpacing.s) {
                XIconTile(systemImage: metric.icon, colors: metric.colors, size: 28)
                Text(metric.title).font(XFont.headline).foregroundStyle(XColor.textPrimary)
                Spacer()
                if let chip = model.macInfo?.chip {
                    Text(chip).font(XFont.caption).foregroundStyle(XColor.textTertiary)
                }
            }

            if let s = model.liveSnapshot {
                content(s)
            } else {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity)
            }

            Divider().padding(.vertical, 2)
            HStack(spacing: XSpacing.s) {
                Button {
                    NSApp.activate(ignoringOtherApps: true)
                    model.selection = .monitor
                    for w in NSApp.windows where w.canBecomeMain { w.makeKeyAndOrderFront(nil) }
                } label: { Text(xLoc("打开监视器")).frame(maxWidth: .infinity) }
                    .buttonStyle(.borderedProminent)
                Button { NSApp.terminate(nil) } label: { Image(systemName: "power") }.buttonStyle(.bordered)
            }
        }
        .padding(XSpacing.m)
        .frame(width: 260)
    }

    @ViewBuilder private func content(_ s: SystemSnapshot) -> some View {
        switch metric {
        case .cpu:
            VStack(alignment: .leading, spacing: XSpacing.m) {
                HStack(spacing: XSpacing.m) {
                    ringGauge(s.cpuUsage)
                    VStack(alignment: .leading, spacing: XSpacing.s) {
                        metricChip(xLoc("热状态"), s.thermal.rawValue)
                        if let rpm = s.fanRPM { metricChip(xLoc("风扇"), "\(rpm) RPM") }
                    }
                    Spacer(minLength: 0)
                }
                XLineChart(values: model.cpuHistory, colors: XColor.ringColors).frame(height: 44)
            }
        case .memory:
            VStack(alignment: .leading, spacing: XSpacing.m) {
                HStack(spacing: XSpacing.m) {
                    ringGauge(s.memoryUsedFraction)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(s.memoryUsed.formattedBytes).font(XFont.monoLarge).foregroundStyle(XColor.textPrimary)
                        Text("/ \(s.memoryTotal.formattedBytes)").font(XFont.caption).foregroundStyle(XColor.textSecondary)
                    }
                    Spacer(minLength: 0)
                }
                XLineChart(values: model.memHistory, colors: XColor.ringColors).frame(height: 44)
                HStack {
                    metricChip(xLoc("活跃"), s.memoryActive.formattedBytes)
                    metricChip(xLoc("联动"), s.memoryWired.formattedBytes)
                    metricChip(xLoc("压缩"), s.memoryCompressed.formattedBytes)
                }
            }
        case .network:
            VStack(alignment: .leading, spacing: XSpacing.m) {
                HStack(spacing: XSpacing.xl) {
                    rateColumn("arrow.down", XColor.ringMint, xLoc("下载"), s.netDownBytesPerSec)
                    rateColumn("arrow.up", XColor.ringRose, xLoc("上传"), s.netUpBytesPerSec)
                    Spacer()
                }
                networkChart.frame(height: 48)
            }
        }
    }

    /// 彩虹极光圆环 + 中心百分数（详情面板里的「数据」用 App 同款彩色）
    private func ringGauge(_ fraction: Double) -> some View {
        XMiniRing(fraction: fraction, colors: XColor.ringColors, size: 60, lineWidth: 7) {
            Text("\(Int((fraction * 100).rounded()))%")
                .font(.system(size: 15, weight: .bold, design: .rounded))
                .foregroundStyle(XColor.textPrimary)
        }
    }

    private var networkChart: some View {
        let maxV = max((model.netDownHistory + model.netUpHistory).max() ?? 1, 1)
        let down = model.netDownHistory.map { $0 / maxV }
        let up = model.netUpHistory.map { $0 / maxV }
        return ZStack {
            XLineChart(values: down, colors: [XColor.accentTeal, XColor.auroraBlue], showDot: false)
            XLineChart(values: up, colors: [XColor.accentPink, XColor.auroraRose], showFill: false, showDot: false)
        }
    }

    private func rateColumn(_ icon: String, _ color: Color, _ label: String, _ rate: Double) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: XSpacing.xs) {
                Image(systemName: icon).font(.system(size: 11, weight: .bold)).foregroundStyle(color)
                Text(label).font(XFont.caption).foregroundStyle(XColor.textSecondary)
            }
            Text(rate.formattedRate).font(XFont.monoLarge).foregroundStyle(XColor.textPrimary)
        }
    }

    private func metricChip(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(XFont.caption).foregroundStyle(XColor.textTertiary)
            Text(value).font(XFont.captionEmphasis).foregroundStyle(XColor.textPrimary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
