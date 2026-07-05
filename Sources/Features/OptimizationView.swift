import SwiftUI
import AppKit
import Infrastructure
import DesignSystem

public struct OptimizationView: View {
    private let env: XicoEnvironment
    @State private var runningApps: [RunningAppItem] = []
    @State private var agents: [LaunchAgentItem] = []
    @State private var memByPID: [Int32: Int64] = [:]
    @State private var tab = 0
    @State private var toggleWarning: String?
    @State private var selection: Set<Int32> = []      // 勾选待批量退出的应用 pid
    @State private var quitFreed: Int64?               // 批量退出后释放的内存（触发计数庆祝）
    @State private var quitCount = 0
    private let sampler = ProcessSampler()

    public init(env: XicoEnvironment) { self.env = env }

    public var body: some View {
        VStack(spacing: 0) {
            XHeaderBar(title: xLoc("优化"), subtitle: xLoc("管理启动项与运行中的应用")) {
                Picker("", selection: $tab) {
                    Text(xLoc("运行中的应用")).tag(0)
                    Text(xLoc("启动项")).tag(1)
                }
                .pickerStyle(.segmented).frame(width: 260).labelsHidden()
            }
            if tab == 0, let freed = quitFreed {
                // 批量退出完成：统一计数庆祝（释放内存 + 退出应用数）。
                TaskCompletionView(
                    animateTo: freed,
                    metricText: { xLocF("已释放 %@", $0.formattedMemory) },
                    detail: xLocF("已退出 %d 个应用", quitCount),
                    doneTitle: xLoc("完成"),
                    onDone: { quitFreed = nil; reload() })
            } else {
                ScrollView {
                    LazyVStack(spacing: XSpacing.s) {
                        if tab == 0 { runningSection } else { startupSection }
                    }
                    .padding(XSpacing.xl)
                }
            }
        }
        .onAppear(perform: reload)
        .onChange(of: tab) { _ in reload() }
        .alert(xLoc("启动项状态"), isPresented: Binding(get: { toggleWarning != nil }, set: { if !$0 { toggleWarning = nil } })) {
            Button(xLoc("好"), role: .cancel) {}
        } message: {
            Text(toggleWarning ?? "")
        }
    }

    @ViewBuilder private var runningSection: some View {
        if runningApps.isEmpty {
            Text(xLoc("没有正在运行的前台应用。")).font(XFont.body).foregroundStyle(XColor.textSecondary)
                .frame(maxWidth: .infinity, alignment: .center).padding(.top, XSpacing.xxl)
        } else {
            // 全选/全不选 + 批量退出（对齐清理/卸载流的 Select-All + 计数完成）。
            HStack(spacing: XSpacing.s) {
                XCheckbox(isOn: allRunningSelected) { toggleAllRunning(!allRunningSelected) }
                Text(xLoc("全选")).font(XFont.captionEmphasis).foregroundStyle(XColor.textSecondary)
                Spacer()
                if !selection.isEmpty {
                    Button(xLocF("退出所选 · %@", selectedMemory.formattedMemory)) { batchQuit() }
                        .buttonStyle(XPrimaryButtonStyle(compact: true))
                }
            }
            .padding(.horizontal, XSpacing.xs)
        }
        ForEach(runningApps) { app in
            XCard(padding: XSpacing.m) {
                HStack(spacing: XSpacing.m) {
                    XCheckbox(isOn: selection.contains(app.pid)) { toggleSelect(app.pid) }
                    if let path = app.iconPath {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: path))
                            .resizable().frame(width: 30, height: 30)
                    }
                    VStack(alignment: .leading, spacing: 1) {
                        Text(app.name).font(XFont.bodyEmphasis).foregroundStyle(XColor.textPrimary)
                        Text(app.bundleID).font(XFont.caption).foregroundStyle(XColor.textSecondary).lineLimit(1)
                    }
                    Spacer()
                    if let mem = memByPID[app.pid] {
                        VStack(alignment: .trailing, spacing: 1) {
                            Text(mem.formattedMemory).font(XFont.mono).foregroundStyle(XColor.textPrimary)
                            Text(xLoc("内存")).font(XFont.nano).foregroundStyle(XColor.textTertiary)
                        }
                    }
                    Button(xLoc("退出")) { env.optimization.quit(pid: app.pid); reload() }
                        .buttonStyle(XSecondaryButtonStyle(compact: true))
                }
            }
        }
    }

    private var allRunningSelected: Bool { !runningApps.isEmpty && runningApps.allSatisfy { selection.contains($0.pid) } }
    private func toggleAllRunning(_ on: Bool) { selection = on ? Set(runningApps.map(\.pid)) : [] }
    private func toggleSelect(_ pid: Int32) {
        if selection.contains(pid) { selection.remove(pid) } else { selection.insert(pid) }
    }
    private var selectedMemory: Int64 { selection.reduce(0) { $0 + (memByPID[$1] ?? 0) } }

    private func batchQuit() {
        let pids = selection
        let freed = selectedMemory
        let count = pids.count
        for pid in pids { env.optimization.quit(pid: pid) }
        selection = []
        quitCount = count
        quitFreed = freed          // 触发计数庆祝完成页
    }

    @ViewBuilder private var startupSection: some View {
        if agents.isEmpty {
            Text(xLoc("未发现启动代理。")).font(XFont.body).foregroundStyle(XColor.textSecondary)
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
                        Text(agent.isSystem ? xLoc("系统级") : (agent.isEnabled ? xLoc("用户级 · 已启用") : xLoc("用户级 · 已停用")))
                            .font(XFont.caption).foregroundStyle(XColor.textSecondary)
                    }
                    Spacer()
                    if agent.isSystem {
                        XBadge(xLoc("需管理员"), color: XColor.warning)
                        Button(xLoc("显示")) { env.optimization.reveal(agent.url) }.buttonStyle(XSecondaryButtonStyle(compact: true))
                    } else {
                        Toggle("", isOn: Binding(
                            get: { agent.isEnabled },
                            set: { newVal in
                                Task {
                                    let result = await env.optimization.setEnabled(agent, enabled: newVal)
                                    if let w = result.warning { toggleWarning = w }
                                    reload()
                                }
                            }))
                            .toggleStyle(.switch).labelsHidden()
                    }
                }
            }
        }
    }

    private func reload() {
        let apps = env.optimization.runningApps()
        runningApps = apps
        agents = env.optimization.launchAgents()
        // 标注每个应用的即时内存占用（决定该不该退出时的资源代价）
        var map: [Int32: Int64] = [:]
        for app in apps { if let m = sampler.memoryFootprint(pid: app.pid) { map[app.pid] = m } }
        memByPID = map
    }
}
