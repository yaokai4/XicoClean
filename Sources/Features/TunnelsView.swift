import SwiftUI
import Domain
import Infrastructure
import DesignSystem

/// 端口转发隧道管理（ssh -L）——ServerCat 没有。为选中主机配置本地转发并一键启停。
struct TunnelsView: View {
    @ObservedObject var vm: ServersViewModel
    @ObservedObject var tunnels: TunnelManager
    let host: ServerHost
    let onClose: () -> Void
    let gate: (() -> Void) -> Void

    @State private var localPort = ""
    @State private var targetHost = "localhost"
    @State private var targetPort = ""

    private var currentHost: ServerHost { vm.hosts.first { $0.id == host.id } ?? host }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(xLoc("端口转发")).font(XFont.title2)
                    Text(xLocF("经 %@ 把本地端口转发到目标 · ssh -L", host.name)).font(XFont.caption).foregroundStyle(XColor.textSecondary)
                }
                Spacer()
            }
            .padding(XSpacing.xl)
            Divider().opacity(0.3)

            ScrollView {
                VStack(spacing: XSpacing.m) {
                    ForEach(currentHost.tunnels) { t in
                        tunnelRow(t)
                    }
                    if currentHost.tunnels.isEmpty {
                        Text(xLoc("还没有隧道。在下方添加一条。")).font(XFont.caption)
                            .foregroundStyle(XColor.textTertiary).padding(.vertical, XSpacing.m)
                    }
                    addForm
                }
                .padding(XSpacing.xl)
            }

            Divider().opacity(0.3)
            HStack { Spacer(); Button(xLoc("完成"), action: onClose).buttonStyle(XPrimaryButtonStyle()) }
                .padding(XSpacing.xl)
        }
        .frame(width: 520, height: 520)
    }

    private func tunnelRow(_ t: Tunnel) -> some View {
        let state = tunnels.state(t.id)
        return HStack(spacing: XSpacing.m) {
            Circle().fill(color(state)).frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 1) {
                Text(t.label).font(XFont.captionMono).foregroundStyle(XColor.textPrimary)
                if case .failed(let msg) = state {
                    Text(msg).font(XFont.micro).foregroundStyle(XColor.danger).lineLimit(1)
                }
            }
            Spacer()
            if case .starting = state { XSpinner(size: 13) }
            if tunnels.isActive(t.id) {
                Button(xLoc("停止")) { vm.stopTunnel(t.id) }.buttonStyle(XSecondaryButtonStyle())
            } else {
                Button(xLoc("启动")) { gate { vm.startTunnel(t, on: currentHost) } }.buttonStyle(XPrimaryButtonStyle())
            }
            Button { vm.deleteTunnel(t.id, on: currentHost) } label: { Image(systemName: "trash") }
                .buttonStyle(.plain).foregroundStyle(XColor.textTertiary)
        }
        .padding(XSpacing.m)
        .background(XColor.surfaceAlt.opacity(0.5), in: RoundedRectangle(cornerRadius: XRadius.card, style: .continuous))
    }

    private var addForm: some View {
        VStack(alignment: .leading, spacing: XSpacing.s) {
            Text(xLoc("新增隧道")).font(XFont.micro).foregroundStyle(XColor.textTertiary)
            HStack(spacing: XSpacing.s) {
                field(xLoc("本地端口"), "8080", $localPort, width: 96)
                Image(systemName: "arrow.right").foregroundStyle(XColor.textTertiary)
                field(xLoc("目标主机"), "localhost", $targetHost, width: 150)
                Text(":").foregroundStyle(XColor.textTertiary)
                field(xLoc("目标端口"), "80", $targetPort, width: 84)
                Spacer()
                Button { addTunnel() } label: { Image(systemName: "plus") }
                    .buttonStyle(XPrimaryButtonStyle())
                    .disabled(Int(localPort) == nil || Int(targetPort) == nil)
            }
        }
        .padding(XSpacing.m)
        .background(XColor.surface, in: RoundedRectangle(cornerRadius: XRadius.card, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: XRadius.card).strokeBorder(XColor.border))
    }

    private func field(_ label: String, _ placeholder: String, _ text: Binding<String>, width: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(XFont.micro).foregroundStyle(XColor.textTertiary)
            TextField(placeholder, text: text)
                .textFieldStyle(.plain).font(XFont.captionMono)
                .padding(.horizontal, XSpacing.s).padding(.vertical, 6)
                .frame(width: width)
                .background(XColor.surfaceAlt.opacity(0.8), in: RoundedRectangle(cornerRadius: XRadius.control))
                .overlay(RoundedRectangle(cornerRadius: XRadius.control).strokeBorder(XColor.border))
        }
    }

    private func addTunnel() {
        guard let lp = Int(localPort), let tp = Int(targetPort) else { return }
        let th = targetHost.trimmingCharacters(in: .whitespaces).isEmpty ? "localhost" : targetHost
        vm.saveTunnel(Tunnel(localPort: lp, targetHost: th, targetPort: tp), on: currentHost)
        localPort = ""; targetPort = ""; targetHost = "localhost"
    }

    private func color(_ s: TunnelManager.TunnelState) -> Color {
        switch s {
        case .active: return XColor.success
        case .starting: return XColor.warning
        case .failed: return XColor.danger
        case .stopped: return XColor.idle
        }
    }
}
