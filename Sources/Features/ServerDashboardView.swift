import SwiftUI
import Domain
import Infrastructure
import DesignSystem

/// 单台主机的实时仪表盘：CPU / 内存双环 + 负载/网络/磁盘 I/O 统计 + 历史折线 + 磁盘挂载 + 进程表 + 服务网格。
/// 复用设计系统的环形仪表、折线图、磁盘条，与本地「系统监视」页视觉同源。
struct ServerDashboardView: View {
    let host: ServerHost
    @ObservedObject var engine: ServerMonitorEngine

    private let cardColumns = [GridItem(.adaptive(minimum: 168), spacing: XSpacing.m)]

    var body: some View {
        ScrollView {
            content.padding(XSpacing.xl)
        }
    }

    @ViewBuilder private var content: some View {
        let state = engine.state(for: host.id)
        if let snap = engine.snapshot(for: host.id), state.isLive {
            VStack(spacing: XSpacing.l) {
                heroRings(snap)
                statGrid(snap)
                historySection
                if !snap.mounts.isEmpty { mountsSection(snap.mounts) }
                if !snap.processes.isEmpty { processSection(snap.processes) }
                if !snap.services.isEmpty { servicesSection(snap.services) }
            }
        } else if state.isBusy || (state.isLive && engine.snapshot(for: host.id) == nil) {
            VStack(spacing: XSpacing.m) {
                XSpinner(size: 22)
                Text(xLoc("正在采样…")).font(XFont.caption).foregroundStyle(XColor.textSecondary)
            }.frame(maxWidth: .infinity, minHeight: 320)
        } else {
            XEmptyState(systemImage: "bolt.slash",
                        title: state.failureReason ?? xLoc("未连接"),
                        subtitle: xLoc("点右上角「连接」开始实时监控"),
                        kind: state.failureReason == nil ? .neutral : .error)
                .frame(maxWidth: .infinity, minHeight: 320)
        }
    }

    // MARK: 双环

    private func heroRings(_ s: RemoteSnapshot) -> some View {
        HStack(spacing: XSpacing.m) {
            ringCard(title: xLoc("处理器"), fraction: s.cpuUsage, colors: XColor.metricCPU,
                     center: SrvFmt.pct(s.cpuUsage), sub: s.coreCount > 0 ? xLocF("%d 核", s.coreCount) : "") {
                HStack(spacing: XSpacing.m) {
                    cpuLeg(xLoc("用户"), s.cpuUser)
                    cpuLeg(xLoc("系统"), s.cpuSystem)
                    cpuLeg(xLoc("等待"), s.cpuIOWait)
                    if s.cpuSteal > 0.001 { cpuLeg(xLoc("窃取"), s.cpuSteal) }
                }
            }
            ringCard(title: xLoc("内存"), fraction: s.memUsedFraction, colors: XColor.metricMemory,
                     center: SrvFmt.pct(s.memUsedFraction),
                     sub: "\(SrvFmt.bytes(s.memUsed)) / \(SrvFmt.bytes(s.memTotal))") {
                HStack(spacing: XSpacing.m) {
                    cpuLeg(xLoc("缓存"), s.memTotal > 0 ? Double(s.memCached) / Double(s.memTotal) : 0)
                    if s.swapTotal > 0 { cpuLeg(xLoc("交换"), s.swapUsedFraction) }
                }
            }
        }
    }

    private func ringCard<Legend: View>(title: String, fraction: Double, colors: [Color],
                                        center: String, sub: String,
                                        @ViewBuilder legend: () -> Legend) -> some View {
        XCard {
            VStack(spacing: XSpacing.s) {
                Text(title).font(XFont.captionEmphasis).foregroundStyle(XColor.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                XRingGauge(progress: fraction, colors: colors, lineWidth: 12, size: 118) {
                    VStack(spacing: 0) {
                        Text(center).font(XFont.monoMid).foregroundStyle(XColor.textPrimary)
                    }
                }
                if !sub.isEmpty {
                    Text(sub).font(XFont.microMono).foregroundStyle(XColor.textTertiary).lineLimit(1)
                }
                legend()
            }
        }
    }

    private func cpuLeg(_ label: String, _ f: Double) -> some View {
        VStack(spacing: 1) {
            Text(SrvFmt.pct(f)).font(XFont.microMono).foregroundStyle(XColor.textPrimary)
            Text(label).font(XFont.micro).foregroundStyle(XColor.textTertiary)
        }
    }

    // MARK: 统计磁贴

    private func statGrid(_ s: RemoteSnapshot) -> some View {
        LazyVGrid(columns: cardColumns, spacing: XSpacing.m) {
            XStatCard(icon: "gauge.with.dots.needle.bottom.50percent", iconColors: XColor.metricCPU,
                      value: String(format: "%.2f", s.load1), label: xLocF("负载 · 5m %.2f · 15m %.2f", s.load5, s.load15))
            XStatCard(icon: "clock.arrow.circlepath", value: SrvFmt.uptime(s.uptimeSeconds), label: xLoc("运行时间"))
            XStatCard(icon: "arrow.down.circle.fill", iconColors: [XColor.netDown, XColor.netDown],
                      value: SrvFmt.rate(s.netRxBytesPerSec), label: xLoc("下行"))
            XStatCard(icon: "arrow.up.circle.fill", iconColors: [XColor.netUp, XColor.netUp],
                      value: SrvFmt.rate(s.netTxBytesPerSec), label: xLoc("上行"))
            XStatCard(icon: "arrow.down.to.line", iconColors: XColor.metricDisk,
                      value: SrvFmt.rate(s.diskReadBytesPerSec), label: xLoc("磁盘读"))
            XStatCard(icon: "arrow.up.to.line", iconColors: XColor.metricDisk,
                      value: SrvFmt.rate(s.diskWriteBytesPerSec), label: xLoc("磁盘写"))
            if s.swapTotal > 0 {
                XStatCard(icon: "memorychip", iconColors: XColor.metricMemory,
                          value: SrvFmt.pct(s.swapUsedFraction),
                          label: xLocF("交换 %@", SrvFmt.bytes(s.swapTotal)))
            }
        }
    }

    // MARK: 历史折线

    private var historySection: some View {
        let cpu = engine.cpuHistory[host.id] ?? []
        let mem = engine.memHistory[host.id] ?? []
        let net = engine.netHistoryNormalized(host.id)
        return XSectionCard(icon: "chart.xyaxis.line", title: xLoc("历史"), iconColors: XColor.metricNetwork) {
            VStack(spacing: XSpacing.m) {
                chartRow(xLoc("处理器"), cpu, XColor.metricCPU)
                chartRow(xLoc("内存"), mem, XColor.metricMemory)
                chartRow(xLoc("网络下行"), net.down, [XColor.netDown, XColor.netDown])
            }
        }
    }

    private func chartRow(_ label: String, _ values: [Double], _ colors: [Color]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(XFont.micro).foregroundStyle(XColor.textTertiary)
            if values.count > 1 {
                XLineChart(values: values, colors: colors).frame(height: 44)
            } else {
                Text(xLoc("采集中…")).font(XFont.micro).foregroundStyle(XColor.textTertiary).frame(height: 44)
            }
        }
    }

    // MARK: 磁盘挂载

    private func mountsSection(_ mounts: [MountUsage]) -> some View {
        XSectionCard(icon: "internaldrive", title: xLoc("磁盘"), iconColors: XColor.metricDisk) {
            VStack(spacing: XSpacing.s) {
                ForEach(mounts) { m in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(m.mountPoint).font(XFont.captionMono).foregroundStyle(XColor.textPrimary)
                            Spacer()
                            Text("\(SrvFmt.bytes(m.usedBytes)) / \(SrvFmt.bytes(m.totalBytes))")
                                .font(XFont.microMono).foregroundStyle(XColor.textSecondary)
                        }
                        XDiskBar(usedFraction: m.usedFraction, label: SrvFmt.pct(m.usedFraction))
                    }
                }
            }
        }
    }

    // MARK: 进程

    private func processSection(_ procs: [RemoteProcess]) -> some View {
        XSectionCard(icon: "list.bullet.rectangle", title: xLoc("进程 · CPU 榜"), iconColors: XColor.metricCPU) {
            VStack(spacing: 0) {
                HStack {
                    Text("PID").frame(width: 56, alignment: .leading)
                    Text(xLoc("用户")).frame(width: 78, alignment: .leading)
                    Text("CPU").frame(width: 52, alignment: .trailing)
                    Text(xLoc("内存")).frame(width: 64, alignment: .trailing)
                    Text(xLoc("命令")).frame(maxWidth: .infinity, alignment: .leading)
                }
                .font(XFont.micro).foregroundStyle(XColor.textTertiary)
                .padding(.vertical, 4)
                Divider().opacity(0.3)
                ForEach(procs.prefix(12)) { p in
                    HStack {
                        Text("\(p.pid)").frame(width: 56, alignment: .leading).foregroundStyle(XColor.textTertiary)
                        Text(p.user).frame(width: 78, alignment: .leading).foregroundStyle(XColor.textSecondary).lineLimit(1)
                        Text(String(format: "%.1f%%", p.cpuPercent)).frame(width: 52, alignment: .trailing)
                            .foregroundStyle(p.cpuPercent > 50 ? XColor.warning : XColor.textPrimary)
                        Text(SrvFmt.bytes(p.rssBytes)).frame(width: 64, alignment: .trailing).foregroundStyle(XColor.textSecondary)
                        Text(p.command).frame(maxWidth: .infinity, alignment: .leading).foregroundStyle(XColor.textPrimary).lineLimit(1)
                    }
                    .font(XFont.captionMono)
                    .padding(.vertical, 3)
                }
            }
        }
    }

    // MARK: 服务

    private func servicesSection(_ services: [RemoteService]) -> some View {
        let cols = [GridItem(.adaptive(minimum: 150), spacing: XSpacing.s)]
        return XSectionCard(icon: "shippingbox", title: xLoc("服务与容器"), iconColors: XColor.metricNetwork) {
            LazyVGrid(columns: cols, spacing: XSpacing.s) {
                ForEach(services) { svc in
                    HStack(spacing: XSpacing.s) {
                        Circle().fill(svc.isHealthy ? XColor.success : XColor.warning).frame(width: 7, height: 7)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(svc.name).font(XFont.caption).foregroundStyle(XColor.textPrimary).lineLimit(1)
                            Text(svc.status).font(XFont.micro).foregroundStyle(XColor.textTertiary).lineLimit(1)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: svc.kind == .docker ? "shippingbox.fill" : "gearshape.fill")
                            .font(.system(size: 10)).foregroundStyle(XColor.textTertiary)
                    }
                    .padding(XSpacing.s)
                    .background(XColor.surfaceAlt.opacity(0.5), in: RoundedRectangle(cornerRadius: XRadius.control, style: .continuous))
                    .contextMenu { serviceActions(svc) }
                }
            }
            Text(xLoc("右键容器/服务可启停、重启")).font(XFont.micro).foregroundStyle(XColor.textTertiary)
                .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 2)
        }
    }

    // Docker / systemd 管理动作——ServerCat 把「创建/管理容器」列为付费项，我们直接内建启停重启。
    @ViewBuilder private func serviceActions(_ svc: RemoteService) -> some View {
        switch svc.kind {
        case .docker:
            Button(xLoc("重启")) { runService("docker restart \(svc.name)") }
            Button(svc.isHealthy ? xLoc("停止") : xLoc("启动")) {
                runService("docker \(svc.isHealthy ? "stop" : "start") \(svc.name)")
            }
        case .systemd:
            Button(xLoc("重启（sudo）")) { runService("sudo -n systemctl restart \(svc.name)") }
            Button(svc.isHealthy ? xLoc("停止（sudo）") : xLoc("启动（sudo）")) {
                runService("sudo -n systemctl \(svc.isHealthy ? "stop" : "start") \(svc.name)")
            }
        default:
            EmptyView()
        }
    }

    private func runService(_ cmd: String) {
        let id = host.id
        Task { _ = try? await engine.runCommand(cmd, on: id) }
    }
}
