import SwiftUI
import Domain
import Infrastructure
import DesignSystem

@MainActor
public final class NetworkViewModel: ObservableObject {
    @Published var interfaces: [NetworkInterfaceInfo] = []
    @Published var wifi: WiFiInfo?
    @Published var publicIP: String?
    @Published var ping: Double?

    private let service: NetworkInfoService
    private let bg = DispatchQueue(label: "app.xico.network", qos: .utility)
    private var timer: Timer?
    private var slowTick = 0
    var pingHost: String { service.pingHost }

    public init(service: NetworkInfoService) { self.service = service }

    public func start() {
        guard timer == nil else { return }   // 幂等：onAppear 二次触发不重复建 Timer（防泄漏+双采样）
        _ = interfacesSync()   // 预热差分
        refresh()
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        Task { await refreshSlow() }
    }
    public func stop() { timer?.invalidate(); timer = nil }

    private func interfacesSync() -> [NetworkInterfaceInfo] { service.interfaces() }

    private func refresh() {
        bg.async { [service] in
            let ifs = service.interfaces()
            let w = service.wifi()
            Task { @MainActor [weak self] in
                self?.interfaces = ifs
                self?.wifi = w
            }
        }
        slowTick += 1
        if slowTick % 10 == 0 { Task { await refreshSlow() } }   // 公网IP/Ping 每 10s
    }

    private func refreshSlow() async {
        async let p = service.ping()
        async let ip = service.publicIP()
        let (pingVal, ipVal) = await (p, ip)
        self.ping = pingVal
        if let ipVal { self.publicIP = ipVal }
    }

    var totalDown: Double { interfaces.reduce(0) { $0 + $1.downBytesPerSec } }
    var totalUp: Double { interfaces.reduce(0) { $0 + $1.upBytesPerSec } }
    var primaryIPv4: String? { interfaces.first { $0.isActive && $0.ipv4 != nil }?.ipv4 }
}

/// 详细网络视图（对标 iStat 网络面板：每接口/Wi-Fi/公网IP/内网IP/Ping）。
public struct NetworkView: View {
    @ObservedObject var vm: NetworkViewModel
    let history: [Double]   // 归一化下行历史，来自 MetricsEngine

    public init(vm: NetworkViewModel, history: [Double]) {
        self.vm = vm
        self.history = history
    }

    private let columns = [GridItem(.adaptive(minimum: 300), spacing: XSpacing.m)]

    public var body: some View {
        VStack(spacing: XSpacing.m) {
            throughputCard
            LazyVGrid(columns: columns, spacing: XSpacing.m) {
                if let w = vm.wifi { wifiCard(w) }
                connectivityCard
            }
            interfacesCard
        }
    }

    private var throughputCard: some View {
        XCard {
            VStack(alignment: .leading, spacing: XSpacing.m) {
                HStack(spacing: XSpacing.xxl) {
                    rateBig("arrow.down", XColor.accentTeal, xLoc("下载"), vm.totalDown)
                    rateBig("arrow.up", XColor.accentPink, xLoc("上传"), vm.totalUp)
                    Spacer()
                }
                XLineChart(values: history, colors: [XColor.accentTeal, XColor.auroraBlue], showDot: false)
                    .frame(height: 60)
            }
        }
    }

    private func rateBig(_ icon: String, _ color: Color, _ label: String, _ rate: Double) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: XSpacing.xs) {
                Image(systemName: icon).font(.system(size: 12, weight: .bold)).foregroundStyle(color)
                Text(label).font(XFont.caption).foregroundStyle(XColor.textSecondary)
            }
            Text(rate.formattedRate).font(XFont.monoLarge).foregroundStyle(XColor.textPrimary)
        }
    }

    private func wifiCard(_ w: WiFiInfo) -> some View {
        MonitorCard(icon: "wifi", title: "Wi-Fi", colors: [XColor.auroraBlue, XColor.accentTeal]) {
            if let ssid = w.ssid { row(xLoc("网络"), ssid) }
            if let f = w.signalFraction, let rssi = w.rssi {
                HStack {
                    Text(xLoc("信号")).font(XFont.caption).foregroundStyle(XColor.textSecondary)
                    Spacer()
                    signalBars(f)
                    Text("\(rssi) dBm").font(XFont.mono).foregroundStyle(XColor.textPrimary)
                }
            }
            if let ch = w.channel { row(xLoc("信道"), "\(ch)") }
            if let tx = w.txRate { row(xLoc("速率"), "\(Int(tx)) Mbps") }
            if let sec = w.security { row(xLoc("加密"), sec) }
            if w.ssid == nil {
                Text(xLoc("提示：显示 Wi-Fi 名称需在系统设置授予定位权限"))
                    .font(.system(size: 10)).foregroundStyle(XColor.textTertiary)
            }
        }
    }

    private func signalBars(_ f: Double) -> some View {
        HStack(spacing: 2) {
            ForEach(0..<4) { i in
                let on = f >= Double(i + 1) / 4
                RoundedRectangle(cornerRadius: 1)
                    .fill(on ? XColor.success : XColor.surfaceAlt)
                    .frame(width: 3, height: 6 + CGFloat(i) * 3)
            }
        }
    }

    private var connectivityCard: some View {
        MonitorCard(icon: "globe", title: xLoc("连通性"), colors: [XColor.auroraViolet, XColor.auroraBlue]) {
            row(xLoc("公网 IP"), vm.publicIP ?? xLoc("获取中…"))
            row(xLoc("内网 IP"), vm.primaryIPv4 ?? "—")
            HStack {
                Text(xLocF("Ping %@", vm.pingHost)).font(XFont.caption).foregroundStyle(XColor.textSecondary)
                Spacer()
                if let p = vm.ping {
                    HStack(spacing: 5) {
                        Circle().fill(pingColor(p)).frame(width: 7, height: 7)
                        Text(String(format: "%.0f ms", p)).font(XFont.mono).foregroundStyle(XColor.textPrimary)
                    }
                } else {
                    Text("—").font(XFont.mono).foregroundStyle(XColor.textTertiary)
                }
            }
        }
    }
    private func pingColor(_ ms: Double) -> Color {
        if ms > 200 { return XColor.danger }
        if ms > 80 { return XColor.warning }
        return XColor.success
    }

    private var interfacesCard: some View {
        MonitorCard(icon: "network", title: xLoc("网络接口"), colors: [XColor.accentTeal, XColor.auroraViolet]) {
            if vm.interfaces.isEmpty {
                Text(xLoc("正在读取…")).font(XFont.caption).foregroundStyle(XColor.textTertiary)
            }
            ForEach(vm.interfaces) { i in
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: XSpacing.s) {
                        Image(systemName: i.type.icon).font(.system(size: 12)).foregroundStyle(i.isActive ? XColor.brand : XColor.textTertiary)
                        Text(i.displayName).font(XFont.bodyEmphasis).foregroundStyle(XColor.textPrimary)
                        Spacer()
                        if i.isActive {
                            Text("↓\(i.downBytesPerSec.compactRate)  ↑\(i.upBytesPerSec.compactRate)")
                                .font(XFont.mono).foregroundStyle(XColor.textSecondary)
                        } else {
                            XBadge(xLoc("未连接"), color: XColor.textTertiary)
                        }
                    }
                    if let ip = i.ipv4 { Text(ip).font(XFont.caption).foregroundStyle(XColor.textTertiary) }
                    if let ip6 = i.ipv6 { Text(ip6).font(.system(size: 10)).foregroundStyle(XColor.textTertiary).lineLimit(1).truncationMode(.middle) }
                }
                .padding(.vertical, 2)
            }
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).font(XFont.caption).foregroundStyle(XColor.textSecondary)
            Spacer()
            Text(value).font(XFont.bodyEmphasis).foregroundStyle(XColor.textPrimary)
                .lineLimit(1).truncationMode(.middle)
        }
    }
}

/// 监视器通用卡片（图标 + 标题 + 内容）。
struct MonitorCard<Content: View>: View {
    let icon: String
    let title: String
    let colors: [Color]
    @ViewBuilder let content: Content
    var body: some View {
        XCard {
            VStack(alignment: .leading, spacing: XSpacing.m) {
                HStack(spacing: XSpacing.s) {
                    XIconTile(systemImage: icon, colors: colors, size: 28)
                    Text(title).font(XFont.captionEmphasis).foregroundStyle(XColor.textSecondary)
                        .textCase(.uppercase).tracking(0.6)
                    Spacer()
                }
                content
            }
        }
    }
}
