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
                Text(xLoc(metric.title)).font(XFont.headline).foregroundStyle(XColor.textPrimary)
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
        .frame(width: 288)
    }

    @ViewBuilder private func content(_ s: SystemSnapshot) -> some View {
        switch metric {
        case .cpu:
            VStack(alignment: .leading, spacing: XSpacing.m) {
                HStack(spacing: XSpacing.m) {
                    ringGauge(s.cpuUsage)
                    VStack(alignment: .leading, spacing: XSpacing.s) {
                        HStack(spacing: XSpacing.l) {
                            metricChip(xLoc("用户"), "\(Int(s.cpuUser * 100))%")
                            metricChip(xLoc("系统"), "\(Int(s.cpuSystem * 100))%")
                        }
                        HStack(spacing: XSpacing.l) {
                            if let t = s.cpuTemp { metricChip(xLoc("温度"), String(format: "%.0f°C", t)) }
                            if let g = s.gpuUsage { metricChip("GPU", "\(Int(g * 100))%") }
                        }
                    }
                    Spacer(minLength: 0)
                }
                if !s.perCore.isEmpty { perCoreBars(s.perCore) }
                XLineChart(values: model.cpuHistory, colors: XColor.ringColors).frame(height: 40)
                processList(model.topByCPU, kind: .cpu)
            }
        case .memory:
            VStack(alignment: .leading, spacing: XSpacing.m) {
                HStack(spacing: XSpacing.m) {
                    ringGauge(s.memoryUsedFraction)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(s.memoryUsed.formattedMemory).font(XFont.monoLarge).foregroundStyle(XColor.textPrimary)
                        Text("/ \(s.memoryTotal.formattedMemory)").font(XFont.caption).foregroundStyle(XColor.textSecondary)
                    }
                    Spacer(minLength: 0)
                }
                memBreakdownBar(s)
                HStack {
                    legendDot(xLoc("应用"), XColor.auroraBlue, s.memoryApp)
                    legendDot(xLoc("联动"), XColor.accentPink, s.memoryWired)
                    legendDot(xLoc("压缩"), XColor.warning, s.memoryCompressed)
                }
                if s.swapTotal > 0 {
                    metricChip(xLoc("交换区"), "\(s.swapUsed.formattedMemory) / \(s.swapTotal.formattedMemory)")
                }
                processList(model.topByMemory, kind: .memory)
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

    private func perCoreBars(_ cores: [Double]) -> some View {
        HStack(alignment: .bottom, spacing: 3) {
            ForEach(Array(cores.enumerated()), id: \.offset) { _, v in
                GeometryReader { geo in
                    ZStack(alignment: .bottom) {
                        RoundedRectangle(cornerRadius: 2).fill(XColor.surfaceAlt)
                        RoundedRectangle(cornerRadius: 2)
                            .fill(LinearGradient(colors: XColor.gauge(v), startPoint: .bottom, endPoint: .top))
                            .frame(height: max(2, geo.size.height * v))
                            .animation(.easeOut(duration: 0.3), value: v)
                    }
                }
                .frame(maxWidth: .infinity)
            }
        }
        .frame(height: 30)
    }

    private func memBreakdownBar(_ s: SystemSnapshot) -> some View {
        GeometryReader { geo in
            let total = Double(s.memoryTotal == 0 ? 1 : s.memoryTotal)
            HStack(spacing: 1) {
                seg(Double(s.memoryApp) / total, geo.size.width, XColor.auroraBlue)
                seg(Double(s.memoryWired) / total, geo.size.width, XColor.accentPink)
                seg(Double(s.memoryCompressed) / total, geo.size.width, XColor.warning)
                seg(Double(s.memoryCached) / total, geo.size.width, XColor.accentTeal)
                Spacer(minLength: 0)
            }
            .frame(height: 8).clipShape(Capsule()).background(Capsule().fill(XColor.surfaceAlt))
        }
        .frame(height: 8)
    }
    private func seg(_ f: Double, _ w: CGFloat, _ c: Color) -> some View {
        Rectangle().fill(c).frame(width: max(0, w * min(1, max(0, f))))
    }
    private func legendDot(_ label: String, _ color: Color, _ bytes: Int64) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 6, height: 6)
            VStack(alignment: .leading, spacing: 0) {
                Text(label).font(.system(size: 9)).foregroundStyle(XColor.textTertiary)
                Text(bytes.formattedMemory).font(.system(size: 10, weight: .semibold)).foregroundStyle(XColor.textPrimary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private enum ProcKind { case cpu, memory }
    private func processList(_ procs: [ProcessUsage], kind: ProcKind) -> some View {
        VStack(spacing: 3) {
            ForEach(procs.prefix(4)) { p in
                HStack {
                    Text(p.name).font(.system(size: 11)).foregroundStyle(XColor.textSecondary)
                        .lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Text(kind == .cpu ? String(format: "%.1f%%", p.cpuPercent) : p.memoryBytes.formattedMemory)
                        .font(.system(size: 11, weight: .semibold, design: .rounded).monospacedDigit())
                        .foregroundStyle(XColor.textPrimary)
                }
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
