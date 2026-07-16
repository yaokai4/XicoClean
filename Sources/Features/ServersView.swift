import SwiftUI
import Domain
import Infrastructure
import DesignSystem

/// 服务器套件主页（反超 ServerCat）：左侧主机栏 + 右侧详情（概览 / 终端 / 片段）。
/// 连接会跨页面保活（离开侧栏不断开），返回即时可见——对齐 ServerCat 的 Sessions 常驻语义。
public struct ServersView: View {
    @ObservedObject private var model: AppModel
    @StateObject private var vm: ServersViewModel
    @ObservedObject private var engine: ServerMonitorEngine
    @State private var tab: DetailTab = .overview
    @State private var editingHost: ServerHost?
    @State private var showingEditor = false
    @State private var showingAlerts = false
    @State private var tunnelsHost: ServerHost?
    @State private var broadcast = false

    enum DetailTab: String, CaseIterable, Hashable {
        case overview, terminal, files, snippets
        var title: String {
            switch self {
            case .overview: return xLoc("概览")
            case .terminal: return xLoc("终端")
            case .files: return xLoc("文件")
            case .snippets: return xLoc("片段")
            }
        }
    }

    public init(model: AppModel) {
        self.model = model
        _vm = StateObject(wrappedValue: ServersViewModel(env: model.env))
        self.engine = model.env.serverMonitorEngine
    }

    public var body: some View {
        VStack(spacing: 0) {
            XHeaderBar(title: xLoc("服务器"), subtitle: xLoc("远程 SSH 监控 · 终端 · 片段")) {
                HStack(spacing: XSpacing.m) {
                    if engine.connectedCount > 0 {
                        HStack(spacing: 5) {
                            XLiveDot(size: 7)
                            Text(xLocF("%d 台在线", engine.connectedCount))
                                .font(XFont.micro).tracking(0.5).foregroundStyle(XColor.success)
                        }
                    }
                    Button { startAdd() } label: {
                        Label(xLoc("添加主机"), systemImage: "plus")
                    }.buttonStyle(XPrimaryButtonStyle())
                    Menu {
                        Button { vm.importSSHConfig() } label: { Label(xLoc("导入 ~/.ssh/config"), systemImage: "square.and.arrow.down") }
                        Button { showingAlerts = true } label: { Label(xLoc("告警与推送…"), systemImage: "bell.badge") }
                        if engine.connectedCount > 0 {
                            Divider()
                            Button(role: .destructive) { engine.disconnectAll() } label: { Label(xLoc("全部断开"), systemImage: "stop.circle") }
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle").font(.system(size: 17)).foregroundStyle(XColor.textSecondary)
                    }.menuStyle(.borderlessButton).frame(width: 30)
                        .accessibilityLabel(xLoc("更多服务器操作"))
                }
            }
            Divider().opacity(0.25)
            if vm.hosts.isEmpty {
                emptyOnboarding
            } else {
                HStack(spacing: 0) {
                    hostRail.frame(width: 264)
                    Divider().opacity(0.25)
                    detail.frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .sheet(isPresented: $showingEditor) {
            HostEditorView(vm: vm, editing: editingHost) { showingEditor = false }
        }
        .sheet(isPresented: $showingAlerts) {
            ServerAlertsView(vm: vm) { showingAlerts = false }
        }
        .sheet(item: $tunnelsHost) { h in
            TunnelsView(vm: vm, tunnels: vm.tunnels, host: h, onClose: { tunnelsHost = nil }, gate: { gateAction($0) })
        }
        .sheet(item: $vm.pendingHostTrust) { request in
            HostTrustSheet(request: request,
                           onCancel: { vm.cancelHostTrust() },
                           onTrust: { vm.trustPendingHost() })
        }
        .xToast($vm.toast)
    }

    // MARK: 空态引导（无主机时全宽居中，不再是空侧栏 + 空面板的丑分屏）

    private var emptyOnboarding: some View {
        VStack(spacing: XSpacing.l) {
            Spacer()
            ZStack {
                Circle().fill(XColor.brand.opacity(0.10)).frame(width: 140, height: 140)
                Circle().fill(XColor.brandGradient).frame(width: 96, height: 96)
                    .shadow(color: XColor.brand.opacity(0.35), radius: 22, y: 10)
                Image(systemName: "server.rack").font(.system(size: 42, weight: .medium)).foregroundStyle(.white)
            }
            VStack(spacing: XSpacing.s) {
                Text(xLoc("连接你的第一台服务器")).font(XFont.title).foregroundStyle(XColor.textPrimary)
                Text(xLoc("用 SSH 无需在服务器装任何 agent，即可实时监控 CPU / 内存 / 磁盘 / 网络与进程，并内置终端、SFTP、告警与端口转发。"))
                    .font(XFont.body).foregroundStyle(XColor.textSecondary)
                    .multilineTextAlignment(.center).frame(maxWidth: 440).lineSpacing(3)
            }
            HStack(spacing: XSpacing.s) {
                featureChip("waveform.path.ecg", xLoc("实时监控"))
                featureChip("apple.terminal", xLoc("终端"))
                featureChip("folder", xLoc("SFTP"))
                featureChip("bell.badge", xLoc("告警"))
                featureChip("arrow.left.arrow.right", xLoc("端口转发"))
            }
            .padding(.top, XSpacing.xs)
            HStack(spacing: XSpacing.m) {
                Button { startAdd() } label: { Label(xLoc("添加主机"), systemImage: "plus") }
                    .buttonStyle(XPrimaryButtonStyle())
                Button { vm.importSSHConfig() } label: { Label(xLoc("导入 ~/.ssh/config"), systemImage: "square.and.arrow.down") }
                    .buttonStyle(XSecondaryButtonStyle())
            }
            .padding(.top, XSpacing.s)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func featureChip(_ icon: String, _ label: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon).font(.system(size: 11))
            Text(label).font(XFont.micro)
        }
        .foregroundStyle(XColor.textSecondary)
        .padding(.horizontal, XSpacing.m).padding(.vertical, 7)
        .background(XColor.surfaceAlt.opacity(0.7), in: Capsule())
        .overlay(Capsule().strokeBorder(XColor.border, lineWidth: 1))
    }

    // MARK: 主机栏

    private var hostRail: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: XSpacing.s) {
                Text(xLocF("主机 · %d", vm.hosts.count))
                    .font(XFont.micro).tracking(0.6).foregroundStyle(XColor.textTertiary)
                    .padding(.horizontal, XSpacing.xs).padding(.top, XSpacing.xs)
                ForEach(vm.hosts) { host in
                    HostRailRow(host: host,
                                state: engine.state(for: host.id),
                                snapshot: engine.snapshot(for: host.id),
                                selected: vm.selectedHostID == host.id)
                        .contentShape(Rectangle())
                        .onTapGesture { withAnimation(.easeOut(duration: 0.15)) { vm.selectedHostID = host.id } }
                        .contextMenu {
                            Button { tunnelsHost = host } label: { Label(xLoc("端口转发…"), systemImage: "arrow.left.arrow.right") }
                            Button { vm.reverifyHost(host) } label: { Label(xLoc("重新验证服务器指纹…"), systemImage: "checkmark.shield") }
                            Button(xLoc("编辑")) { startEdit(host) }
                            Button(xLoc("删除"), role: .destructive) { vm.deleteHost(host.id) }
                        }
                }
            }
            .padding(XSpacing.m)
        }
        .background(XColor.surfaceAlt.opacity(0.35))
    }

    // MARK: 详情

    @ViewBuilder private var detail: some View {
        if let host = vm.selectedHost {
            VStack(spacing: 0) {
                detailHeader(host)
                XSegmentedControl(selection: $tab, options: DetailTab.allCases.map {
                    .init(tag: $0, label: xLoc($0.title), a11y: xLoc($0.title))
                })
                .padding(.horizontal, XSpacing.xl)
                .padding(.bottom, XSpacing.s)

                switch tab {
                case .overview:
                    ServerDashboardView(host: host, engine: engine)
                case .terminal:
                    ServerTerminalTab(vm: vm, host: host, engine: engine, broadcast: $broadcast, gate: { gateAction($0) })
                        .id(host.id)   // 切换主机时重建，重置「已打开终端」状态，避免连到错误主机
                case .files:
                    ServerFilesView(host: host, credential: vm.credential(for: host))
                        .id(host.id)
                case .snippets:
                    SnippetsPane(vm: vm, host: host, engine: engine, gate: { gateAction($0) })
                }
            }
        } else {
            VStack(spacing: XSpacing.l) {
                XEmptyState(systemImage: "server.rack",
                            title: xLoc("还没有服务器"),
                            subtitle: xLoc("添加一台主机，用 SSH 无需装 agent 即可实时监控 CPU / 内存 / 磁盘 / 网络与进程"))
                Button { startAdd() } label: {
                    Label(xLoc("添加主机"), systemImage: "plus")
                }.buttonStyle(XPrimaryButtonStyle())
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func detailHeader(_ host: ServerHost) -> some View {
        let state = engine.state(for: host.id)
        return HStack(spacing: XSpacing.m) {
            XIconTile(systemImage: host.symbol, colors: ServerPalette.colors(host.colorIndex), size: 34)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: XSpacing.s) {
                    Text(host.name).font(XFont.title2).foregroundStyle(XColor.textPrimary)
                    if let os = host.lastKnownOS { XBadge(os, color: XColor.info) }
                }
                Text(host.endpointLabel).font(XFont.captionMono).foregroundStyle(XColor.textSecondary)
            }
            Spacer()
            if let snap = engine.snapshot(for: host.id), state.isLive {
                Text(xLocF("运行 %@", SrvFmt.uptime(snap.uptimeSeconds)))
                    .font(XFont.caption).foregroundStyle(XColor.textTertiary)
            }
            connectButton(host, state: state)
            Menu {
                Button { tunnelsHost = host } label: { Label(xLoc("端口转发…"), systemImage: "arrow.left.arrow.right") }
                Button { vm.reverifyHost(host) } label: { Label(xLoc("重新验证服务器指纹…"), systemImage: "checkmark.shield") }
                Button(xLoc("编辑")) { startEdit(host) }
                Button(xLoc("删除"), role: .destructive) { vm.deleteHost(host.id) }
            } label: {
                Image(systemName: "ellipsis.circle").font(.system(size: 18)).foregroundStyle(XColor.textSecondary)
            }.menuStyle(.borderlessButton).frame(width: 28)
                .accessibilityLabel(xLoc("更多服务器操作") + " " + host.name)
        }
        .padding(.horizontal, XSpacing.xl)
        .padding(.vertical, XSpacing.m)
    }

    @ViewBuilder private func connectButton(_ host: ServerHost, state: ConnectionState) -> some View {
        if vm.scanningHostIDs.contains(host.id) {
            HStack(spacing: 6) { XSpinner(size: 13); Text(xLoc("读取服务器指纹")).font(XFont.caption) }
                .foregroundStyle(XColor.textSecondary)
                .accessibilityElement(children: .combine)
        } else if state.isLive {
            Button { vm.disconnect(host) } label: { Label(xLoc("断开"), systemImage: "stop.circle") }
                .buttonStyle(XSecondaryButtonStyle())
        } else if state.isBusy {
            HStack(spacing: 6) { XSpinner(size: 13); Text(xLoc("连接中")).font(XFont.caption) }
                .foregroundStyle(XColor.textSecondary)
        } else {
            Button { gateAction { vm.connect(host) } } label: { Label(xLoc("连接"), systemImage: "bolt.fill") }
                .buttonStyle(XPrimaryButtonStyle())
        }
    }

    // MARK: 授权门禁（浏览免费，连接/执行需授权）

    private func gateAction(_ action: () -> Void) {
        if model.licenseStatus?.state.allowsCommercialUse == true {
            action()
        } else {
            model.showPricing = true
        }
    }

    private func startAdd() { editingHost = nil; showingEditor = true }
    private func startEdit(_ host: ServerHost) { editingHost = host; showingEditor = true }
}

// MARK: - 首次连接服务器身份确认

public struct HostTrustSheet: View {
    let request: HostTrustRequest
    let onCancel: () -> Void
    let onTrust: () -> Void

    public init(request: HostTrustRequest, onCancel: @escaping () -> Void, onTrust: @escaping () -> Void) {
        self.request = request; self.onCancel = onCancel; self.onTrust = onTrust
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: XSpacing.l) {
            HStack(alignment: .top, spacing: XSpacing.m) {
                ZStack {
                    RoundedRectangle(cornerRadius: XRadius.control, style: .continuous)
                        .fill(XColor.warning.opacity(0.14))
                    Image(systemName: request.replacesExistingKeys ? "exclamationmark.shield.fill" : "checkmark.shield.fill")
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundStyle(request.replacesExistingKeys ? XColor.danger : XColor.warning)
                }
                .frame(width: 48, height: 48)
                .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: XSpacing.xs) {
                    Text(request.replacesExistingKeys ? xLoc("服务器指纹发生重新验证") : xLoc("确认服务器身份"))
                        .font(XFont.title2).foregroundStyle(XColor.textPrimary)
                    Text(request.host.endpointLabel)
                        .font(XFont.captionMono).foregroundStyle(XColor.textSecondary)
                        .textSelection(.enabled)
                }
                Spacer(minLength: 0)
            }

            Text(request.replacesExistingKeys
                 ? xLoc("这会替换此前固定的服务器身份。请先通过服务商控制台或管理员独立核对下面的 SHA-256 指纹；如果不是你预期的变更，请取消。")
                 : xLoc("首次连接前，请通过服务商控制台或管理员独立核对下面的 SHA-256 指纹。仅确认地址相同还不足以排除中间人攻击。"))
                .font(XFont.body).foregroundStyle(XColor.textSecondary).lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: 0) {
                ForEach(Array(request.keys.enumerated()), id: \.element.id) { index, key in
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            Text(key.algorithm).font(XFont.captionEmphasis).foregroundStyle(XColor.textPrimary)
                            Spacer()
                            XBadge(xLoc("公开主机密钥"), color: XColor.info)
                        }
                        Text(key.fingerprint)
                            .font(XFont.captionMono).foregroundStyle(XColor.textSecondary)
                            .textSelection(.enabled)
                            .accessibilityLabel(xLoc("SHA-256 指纹") + " " + key.fingerprint)
                    }
                    .padding(XSpacing.m)
                    if index < request.keys.count - 1 { Divider().opacity(0.35) }
                }
            }
            .background(XColor.surfaceAlt.opacity(0.65), in: RoundedRectangle(cornerRadius: XRadius.control, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: XRadius.control, style: .continuous).strokeBorder(XColor.border, lineWidth: 1))

            HStack(spacing: XSpacing.s) {
                Image(systemName: "lock.shield").foregroundStyle(XColor.success).accessibilityHidden(true)
                Text(xLoc("确认后会固定这些密钥；未来密钥变化时，Xico 会阻止连接，不会静默接受。"))
                    .font(XFont.caption).foregroundStyle(XColor.textSecondary)
            }

            HStack {
                Spacer()
                Button(xLoc("取消"), action: onCancel).buttonStyle(XSecondaryButtonStyle())
                    .keyboardShortcut(.cancelAction)
                Button(request.replacesExistingKeys ? xLoc("替换并固定指纹") : xLoc("信任并连接"), action: onTrust)
                    .buttonStyle(XPrimaryButtonStyle())
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(XSpacing.xl)
        .frame(width: 580)
        .interactiveDismissDisabled()
        .accessibilityElement(children: .contain)
    }
}

// MARK: - 主机栏行

private struct HostRailRow: View {
    let host: ServerHost
    let state: ConnectionState
    let snapshot: RemoteSnapshot?
    let selected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: XSpacing.s) {
            HStack(spacing: XSpacing.s) {
                // 渐变图标 + 右下状态点徽标
                ZStack(alignment: .bottomTrailing) {
                    XIconTile(systemImage: host.symbol, colors: ServerPalette.colors(host.colorIndex), size: 30)
                    Circle().fill(state.dotColor).frame(width: 9, height: 9)
                        .overlay(Circle().strokeBorder(selected ? XColor.surfaceHover : XColor.surface, lineWidth: 2))
                        .shadow(color: state.isLive ? state.dotColor.opacity(0.7) : .clear, radius: 3)
                        .offset(x: 3, y: 3)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(host.name).font(XFont.bodyEmphasis).foregroundStyle(XColor.textPrimary).lineLimit(1)
                    Text(host.endpointLabel).font(XFont.captionMono).foregroundStyle(XColor.textTertiary).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            if let s = snapshot, state.isLive {
                HStack(spacing: XSpacing.s) {
                    miniBar(xLoc("处理器"), s.cpuUsage, XColor.metricCPU)
                    miniBar(xLoc("内存"), s.memUsedFraction, XColor.metricMemory)
                }
                .padding(.top, 1)
            } else if let reason = state.failureReason {
                Text(reason).font(XFont.micro).foregroundStyle(XColor.danger).lineLimit(2)
            } else if state.isBusy {
                HStack(spacing: 5) { XSpinner(size: 10); Text(xLoc("连接中")).font(XFont.micro).foregroundStyle(XColor.textTertiary) }
            }
        }
        .padding(XSpacing.m)
        .background(selected ? XColor.surface : XColor.surface.opacity(0.55),
                    in: RoundedRectangle(cornerRadius: XRadius.card, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: XRadius.card, style: .continuous)
                .strokeBorder(selected ? AnyShapeStyle(XColor.brand.opacity(0.55)) : AnyShapeStyle(XColor.border.opacity(0.7)),
                              lineWidth: selected ? 1.5 : 1)
        )
        .shadow(color: selected ? XColor.brand.opacity(0.12) : .clear, radius: 8, y: 3)
    }

    private func miniBar(_ label: String, _ frac: Double, _ colors: [Color]) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 3) {
                Text(label).font(.system(size: 8, weight: .semibold)).foregroundStyle(XColor.textTertiary)
                Spacer(minLength: 2)
                Text("\(Int((max(0, min(1, frac))) * 100))%")
                    .font(.system(size: 8.5, weight: .bold, design: .rounded)).foregroundStyle(colors.first ?? XColor.brand)
            }
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(XColor.surfaceAlt)
                    Capsule().fill(LinearGradient(colors: colors, startPoint: .leading, endPoint: .trailing))
                        .frame(width: max(3, g.size.width * max(0, min(1, frac))))
                }
            }.frame(height: 4)
        }
    }
}

// MARK: - 命令控制台（macOS 14 回退 / 快速命令：真实远程命令执行 + 片段 + 批量广播）

struct ServerConsoleView: View {
    @ObservedObject var vm: ServersViewModel
    let host: ServerHost
    @ObservedObject var engine: ServerMonitorEngine
    @Binding var broadcast: Bool
    let gate: (() -> Void) -> Void
    @State private var command = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: XSpacing.s) {
            ScrollViewReader { proxy in
                ScrollView {
                    Text(vm.consoleOutput[host.id] ?? xLoc("在下方输入命令并回车，输出会显示在这里。\n提示：可勾选「广播」在所有已连接主机同时执行。"))
                        .font(XFont.captionMono)
                        .foregroundStyle(XColor.textPrimary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(XSpacing.m)
                        .id("consoleBottom")
                }
                .background(XColor.surfaceAlt.opacity(0.5), in: RoundedRectangle(cornerRadius: XRadius.card, style: .continuous))
                .onChange(of: vm.consoleOutput[host.id]) { _, _ in
                    withAnimation { proxy.scrollTo("consoleBottom", anchor: .bottom) }
                }
            }

            HStack(spacing: XSpacing.s) {
                Toggle(isOn: $broadcast) { Text(xLoc("广播")).font(XFont.caption) }
                    .toggleStyle(.checkbox)
                    .help(xLoc("在所有已连接主机上同时执行"))
                XCapsuleTextField(placeholder: state.isLive ? xLoc("输入命令…") : xLoc("请先连接主机"),
                                  text: $command, onSubmit: run)
                    .focused($focused)
                    .disabled(!state.isLive)
                Button(action: run) {
                    if vm.isRunning(host.id) { XSpinner(size: 14) } else { Image(systemName: "return") }
                }
                .buttonStyle(XPrimaryButtonStyle())
                .disabled(!state.isLive || command.trimmingCharacters(in: .whitespaces).isEmpty)
                Button { vm.clearConsole(host.id) } label: { Image(systemName: "trash") }
                    .buttonStyle(XSecondaryButtonStyle())
                    .help(xLoc("清空"))
            }
        }
        .padding(XSpacing.xl)
    }

    private var state: ConnectionState { engine.state(for: host.id) }

    private func run() {
        let cmd = command
        guard !cmd.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        gate {
            if broadcast { vm.runOnConnected(cmd) } else { vm.runCommand(cmd, on: host) }
            command = ""
            focused = true
        }
    }
}

// MARK: - 片段库

private struct SnippetsPane: View {
    @ObservedObject var vm: ServersViewModel
    let host: ServerHost
    @ObservedObject var engine: ServerMonitorEngine
    let gate: (() -> Void) -> Void
    @State private var editing: Snippet?
    @State private var showEditor = false

    var body: some View {
        ScrollView {
            VStack(spacing: XSpacing.m) {
                XSectionCard(icon: "chevron.left.forwardslash.chevron.right", title: xLoc("代码片段"),
                             iconColors: XColor.metricNetwork,
                             trailing: {
                                 Button { editing = nil; showEditor = true } label: {
                                     Label(xLoc("新建"), systemImage: "plus")
                                 }.buttonStyle(XSecondaryButtonStyle())
                             }) {
                    VStack(spacing: XSpacing.s) {
                        ForEach(vm.snippets) { snip in
                            SnippetRow(snippet: snip,
                                       canRun: engine.state(for: host.id).isLive,
                                       onRun: { gate { vm.runCommand(snip.command, on: host) } },
                                       onRunAll: { gate { vm.runOnConnected(snip.command) } },
                                       onEdit: { editing = snip; showEditor = true },
                                       onDelete: { vm.deleteSnippet(snip.id) })
                        }
                        if vm.snippets.isEmpty {
                            Text(xLoc("还没有片段，点「新建」添加常用命令")).font(XFont.caption)
                                .foregroundStyle(XColor.textTertiary).padding(.vertical, XSpacing.m)
                        }
                    }
                }
            }
            .padding(XSpacing.xl)
        }
        .sheet(isPresented: $showEditor) {
            SnippetEditor(snippet: editing) { snip in vm.saveSnippet(snip); showEditor = false } onCancel: { showEditor = false }
        }
    }
}

private struct SnippetRow: View {
    let snippet: Snippet
    let canRun: Bool
    let onRun: () -> Void
    let onRunAll: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: XSpacing.m) {
            VStack(alignment: .leading, spacing: 2) {
                Text(snippet.title).font(XFont.bodyEmphasis).foregroundStyle(XColor.textPrimary)
                Text(snippet.command).font(XFont.captionMono).foregroundStyle(XColor.textSecondary).lineLimit(1)
            }
            Spacer()
            Button(action: onRun) { Image(systemName: "play.fill") }
                .buttonStyle(XSecondaryButtonStyle()).disabled(!canRun).help(xLoc("在当前主机运行"))
            Menu {
                Button(xLoc("在所有已连接主机运行"), action: onRunAll)
                Button(xLoc("编辑"), action: onEdit)
                Button(xLoc("删除"), role: .destructive, action: onDelete)
            } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).frame(width: 24)
        }
        .padding(XSpacing.m)
        .background(XColor.surfaceAlt.opacity(0.5), in: RoundedRectangle(cornerRadius: XRadius.card, style: .continuous))
    }
}

private struct SnippetEditor: View {
    @State private var title: String
    @State private var command: String
    private let original: Snippet?
    let onSave: (Snippet) -> Void
    let onCancel: () -> Void

    init(snippet: Snippet?, onSave: @escaping (Snippet) -> Void, onCancel: @escaping () -> Void) {
        self.original = snippet
        _title = State(initialValue: snippet?.title ?? "")
        _command = State(initialValue: snippet?.command ?? "")
        self.onSave = onSave
        self.onCancel = onCancel
    }

    var body: some View {
        VStack(alignment: .leading, spacing: XSpacing.m) {
            Text(original == nil ? xLoc("新建片段") : xLoc("编辑片段")).font(XFont.title2)
            XCapsuleTextField(placeholder: xLoc("标题"), text: $title)
            TextEditor(text: $command)
                .font(XFont.captionMono)
                .frame(height: 120)
                .padding(XSpacing.s)
                .background(XColor.surfaceAlt.opacity(0.6), in: RoundedRectangle(cornerRadius: XRadius.control))
                .overlay(RoundedRectangle(cornerRadius: XRadius.control).strokeBorder(XColor.border))
            HStack {
                Spacer()
                Button(xLoc("取消"), action: onCancel).buttonStyle(XSecondaryButtonStyle())
                Button(xLoc("保存")) {
                    var s = original ?? Snippet(title: "", command: "")
                    s.title = title.isEmpty ? xLoc("未命名") : title
                    s.command = command
                    onSave(s)
                }.buttonStyle(XPrimaryButtonStyle())
                    .disabled(command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(XSpacing.xl)
        .frame(width: 460)
    }
}
