import SwiftUI
import Domain
import Infrastructure
import DesignSystem

public struct MonitorView: View {
    private let env: XicoEnvironment
    private let sampler = LiveMetricsSampler()   // 独立采样器，避免与菜单栏争用 CPU 差分状态
    @State private var snap: SystemSnapshot?
    @State private var info: MacInfo?
    @State private var cpuHist: [Double] = []
    @State private var memHist: [Double] = []
    @State private var netDownHist: [Double] = []
    @State private var netUpHist: [Double] = []
    private let ticker = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    public init(env: XicoEnvironment) { self.env = env }

    public var body: some View {
        VStack(spacing: 0) {
            XHeaderBar(title: xLoc("系统监视"), subtitle: xLoc("实时刷新 · 每秒")) {
                HStack(spacing: XSpacing.xs) {
                    Circle().fill(XColor.success).frame(width: 7, height: 7)
                    Text("LIVE").font(.system(size: 10, weight: .bold)).tracking(1).foregroundStyle(XColor.success)
                }
            }
            ScrollView {
                VStack(spacing: XSpacing.m) {
                    macCard
                    HStack(spacing: XSpacing.m) {
                        ringCard(title: xLoc("处理器"), value: snap?.cpuUsage ?? 0, sub: cpuSub)
                        ringCard(title: xLoc("内存"), value: snap?.memoryUsedFraction ?? 0, sub: memSub)
                    }
                    historyCard
                    HStack(spacing: XSpacing.m) {
                        diskCard
                        networkCard
                        thermalCard
                    }
                    memoryBreakdown
                }
                .padding(XSpacing.xl)
            }
        }
        .onAppear {
            info = sampler.macInfo()
            // 先放一份基线：内存/磁盘立即可见（CPU/网速需要两次采样的时间差）
            snap = sampler.sample()
            // 0.6s 后取得有效时间差，首帧即显示真实 CPU/网速，避免一直 0%
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { refresh() }
        }
        .onReceive(ticker) { _ in refresh() }
    }

    private func refresh() {
        let s = sampler.sample()
        snap = s
        push(&cpuHist, s.cpuUsage)
        push(&memHist, s.memoryUsedFraction)
        push(&netDownHist, s.netDownBytesPerSec)
        push(&netUpHist, s.netUpBytesPerSec)
    }
    private func push(_ a: inout [Double], _ v: Double) {
        a.append(v); if a.count > 60 { a.removeFirst(a.count - 60) }
    }

    private var historyCard: some View {
        XCard {
            VStack(alignment: .leading, spacing: XSpacing.m) {
                cardHeader("waveform.path.ecg", xLoc("实时历史 · 近 1 分钟"))
                chartRow(xLoc("处理器"), cpuHist, XColor.brandGradientColors, "\(Int((snap?.cpuUsage ?? 0) * 100))%")
                chartRow(xLoc("内存"), memHist, [XColor.auroraViolet, XColor.auroraRose], "\(Int((snap?.memoryUsedFraction ?? 0) * 100))%")
                chartRow(xLoc("网络"), netNorm, [XColor.accentTeal, XColor.auroraBlue],
                         "↓\((snap?.netDownBytesPerSec ?? 0).formattedRate)")
            }
        }
    }

    private var netNorm: [Double] {
        let maxV = max((netDownHist + netUpHist).max() ?? 1, 1)
        return netDownHist.map { $0 / maxV }
    }

    private func chartRow(_ title: String, _ values: [Double], _ colors: [Color], _ value: String) -> some View {
        HStack(spacing: XSpacing.m) {
            Text(title).font(XFont.caption).foregroundStyle(XColor.textSecondary).frame(width: 40, alignment: .leading)
            XLineChart(values: values, colors: colors).frame(height: 38)
            Text(value).font(XFont.mono).foregroundStyle(XColor.textPrimary).frame(width: 84, alignment: .trailing)
        }
    }

    private var cpuSub: String { "\(Int((snap?.cpuUsage ?? 0) * 100))%" }
    private var memSub: String {
        guard let s = snap else { return "" }
        return "\(s.memoryUsed.formattedBytes) / \(s.memoryTotal.formattedBytes)"
    }

    // MARK: Mac 详情

    private var macCard: some View {
        XCard {
            HStack(alignment: .top, spacing: XSpacing.xl) {
                XIconTile(systemImage: "laptopcomputer", colors: XColor.brandGradientColors, size: 46)
                VStack(alignment: .leading, spacing: 3) {
                    Text(info?.chip ?? "—").xHeadline().foregroundStyle(XColor.textPrimary)
                    Text(info?.model ?? "—").font(XFont.caption).foregroundStyle(XColor.textSecondary)
                }
                Spacer()
                HStack(spacing: XSpacing.xl) {
                    infoCol(xLoc("系统"), info?.macOS ?? "—")
                    infoCol(xLoc("内存"), info?.memory ?? "—")
                    infoCol(xLoc("核心"), info.map { "\($0.cores)" } ?? "—")
                    infoCol(xLoc("已运行"), info?.uptime ?? "—")
                }
            }
        }
    }

    private func infoCol(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(XFont.caption).foregroundStyle(XColor.textTertiary)
            Text(value).font(XFont.bodyEmphasis).foregroundStyle(XColor.textPrimary)
        }
    }

    // MARK: 环形

    private func ringCard(title: String, value: Double, sub: String) -> some View {
        XCard {
            VStack(spacing: XSpacing.m) {
                XRingGauge(progress: value, colors: XColor.gauge(value), lineWidth: 12, size: 150) {
                    Text("\(Int(value * 100))%").xLargeTitle().foregroundStyle(XColor.textPrimary)
                }
                Text(title).xHeadline().foregroundStyle(XColor.textPrimary)
                Text(sub).font(XFont.caption).foregroundStyle(XColor.textSecondary)
            }
            .frame(maxWidth: .infinity)
            .animation(.easeOut(duration: 0.5), value: value)
        }
    }

    // MARK: 磁盘 / 网络 / 温度

    private var diskCard: some View {
        XCard {
            VStack(alignment: .leading, spacing: XSpacing.m) {
                cardHeader("internaldrive.fill", xLoc("磁盘"))
                XDiskBar(usedFraction: snap?.diskUsedFraction ?? 0, label: "", height: 10)
                Text(xLocF("%@ 可用 / %@", (snap?.diskFree ?? 0).formattedBytes, (snap?.diskTotal ?? 0).formattedBytes))
                    .font(XFont.caption).foregroundStyle(XColor.textSecondary)
            }
        }
    }

    private var networkCard: some View {
        XCard {
            VStack(alignment: .leading, spacing: XSpacing.m) {
                cardHeader("antenna.radiowaves.left.and.right", xLoc("网络"))
                HStack(spacing: XSpacing.l) {
                    rateView("arrow.down", XColor.accentTeal, snap?.netDownBytesPerSec ?? 0)
                    rateView("arrow.up", XColor.accentPink, snap?.netUpBytesPerSec ?? 0)
                }
            }
        }
    }

    private func rateView(_ icon: String, _ color: Color, _ rate: Double) -> some View {
        HStack(spacing: XSpacing.xs) {
            Image(systemName: icon).font(.system(size: 11, weight: .bold)).foregroundStyle(color)
            Text(rate.formattedRate).font(XFont.mono).foregroundStyle(XColor.textPrimary)
        }
    }

    private var thermalCard: some View {
        XCard {
            VStack(alignment: .leading, spacing: XSpacing.m) {
                cardHeader("thermometer.medium", xLoc("热状态"))
                HStack {
                    XBadge(snap?.thermal.rawValue ?? "—", color: thermalColor)
                    Spacer()
                    Text(xLoc("系统热压力等级")).font(XFont.caption).foregroundStyle(XColor.textTertiary)
                }
            }
        }
    }

    private var thermalColor: Color {
        switch snap?.thermal {
        case .nominal: return XColor.success
        case .fair: return XColor.accentTeal
        case .serious: return XColor.warning
        case .critical: return XColor.danger
        default: return XColor.textSecondary
        }
    }

    private var memoryBreakdown: some View {
        XCard {
            VStack(alignment: .leading, spacing: XSpacing.m) {
                cardHeader("memorychip.fill", xLoc("内存明细"))
                HStack(spacing: XSpacing.xl) {
                    infoCol(xLoc("活跃"), (snap?.memoryActive ?? 0).formattedBytes)
                    infoCol(xLoc("联动"), (snap?.memoryWired ?? 0).formattedBytes)
                    infoCol(xLoc("已压缩"), (snap?.memoryCompressed ?? 0).formattedBytes)
                    Spacer()
                }
            }
        }
    }

    private func cardHeader(_ icon: String, _ title: String) -> some View {
        HStack(spacing: XSpacing.s) {
            Image(systemName: icon).font(.system(size: 12, weight: .semibold)).foregroundStyle(XColor.brand)
            Text(title).font(XFont.captionEmphasis).foregroundStyle(XColor.textSecondary)
        }
    }
}
