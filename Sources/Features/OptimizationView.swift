import SwiftUI
import AppKit
import Infrastructure
import DesignSystem

public struct OptimizationView: View {
    private let env: XicoEnvironment
    @State private var runningApps: [RunningAppItem] = []
    @State private var agents: [LaunchAgentItem] = []
    @State private var tab = 0

    public init(env: XicoEnvironment) { self.env = env }

    public var body: some View {
        VStack(spacing: 0) {
            XHeaderBar(title: "优化", subtitle: "管理启动项与运行中的应用") {
                Picker("", selection: $tab) {
                    Text("运行中的应用").tag(0)
                    Text("启动项").tag(1)
                }
                .pickerStyle(.segmented).frame(width: 260).labelsHidden()
            }
            ScrollView {
                LazyVStack(spacing: XSpacing.s) {
                    if tab == 0 { runningSection } else { startupSection }
                }
                .padding(XSpacing.xl)
            }
        }
        .onAppear(perform: reload)
        .onChange(of: tab) { _ in reload() }
    }

    @ViewBuilder private var runningSection: some View {
        if runningApps.isEmpty {
            Text("没有正在运行的前台应用。").font(XFont.body).foregroundStyle(XColor.textSecondary)
                .frame(maxWidth: .infinity, alignment: .center).padding(.top, XSpacing.xxl)
        }
        ForEach(runningApps) { app in
            XCard(padding: XSpacing.m) {
                HStack(spacing: XSpacing.m) {
                    if let path = app.iconPath {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: path))
                            .resizable().frame(width: 30, height: 30)
                    }
                    VStack(alignment: .leading, spacing: 1) {
                        Text(app.name).font(XFont.bodyEmphasis).foregroundStyle(XColor.textPrimary)
                        Text(app.bundleID).font(XFont.caption).foregroundStyle(XColor.textSecondary).lineLimit(1)
                    }
                    Spacer()
                    Button("退出") { env.optimization.quit(pid: app.pid); reload() }
                        .buttonStyle(.bordered)
                }
            }
        }
    }

    @ViewBuilder private var startupSection: some View {
        if agents.isEmpty {
            Text("未发现启动代理。").font(XFont.body).foregroundStyle(XColor.textSecondary)
                .frame(maxWidth: .infinity, alignment: .center).padding(.top, XSpacing.xxl)
        }
        ForEach(agents) { agent in
            XCard(padding: XSpacing.m) {
                HStack(spacing: XSpacing.m) {
                    XIconTile(systemImage: "bolt.fill",
                              colors: !agent.isEnabled ? [XColor.textTertiary, XColor.textTertiary]
                                    : (agent.isSystem ? [XColor.warning, XColor.accentPink] : XColor.brandGradientColors),
                              size: 30)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(agent.label).font(XFont.bodyEmphasis).foregroundStyle(XColor.textPrimary).lineLimit(1)
                        Text(agent.isSystem ? "系统级" : (agent.isEnabled ? "用户级 · 已启用" : "用户级 · 已停用"))
                            .font(XFont.caption).foregroundStyle(XColor.textSecondary)
                    }
                    Spacer()
                    if agent.isSystem {
                        XBadge("需管理员", color: XColor.warning)
                        Button("显示") { env.optimization.reveal(agent.url) }.buttonStyle(.bordered)
                    } else {
                        Toggle("", isOn: Binding(
                            get: { agent.isEnabled },
                            set: { newVal in
                                _ = env.optimization.setEnabled(agent, enabled: newVal)
                                reload()
                            }))
                            .toggleStyle(.switch).labelsHidden()
                    }
                }
            }
        }
    }

    private func reload() {
        runningApps = env.optimization.runningApps()
        agents = env.optimization.launchAgents()
    }
}
