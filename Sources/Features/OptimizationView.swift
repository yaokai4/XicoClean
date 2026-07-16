import SwiftUI
import AppKit
import Infrastructure
import DesignSystem
import Shared

// MARK: - 优化页（P4·C5 重做：内存英雄区 + 行卡占比条/hover + 启动项影响权重 + 规范空态）

public struct OptimizationView: View {
    private let env: XicoEnvironment
    /// 实时内存数据源（英雄区）。ShotRenderer 等无 feed 场景传 nil → 英雄区显示骨架。
    private let feed: MetricsFeed?
    @State private var runningApps: [RunningAppItem] = []
    @State private var agents: [LaunchAgentItem] = []
    @State private var memByPID: [Int32: Int64] = [:]
    @State private var tab = 0
    @State private var toggleWarning: String?
    @State private var selection: Set<Int32> = []      // 勾选待批量退出的应用 pid
    @State private var quitFreed: Int64?               // 批量退出后释放的内存（触发计数庆祝）
    @State private var quitCount = 0
    private let sampler = ProcessSampler()

    public init(env: XicoEnvironment, feed: MetricsFeed? = nil) {
        self.env = env
        self.feed = feed
    }

    public var body: some View {
        VStack(spacing: 0) {
            XHeaderBar(title: xLoc("优化"), subtitle: xLoc("管理启动项与运行中的应用")) {
                XSegmentedControl(selection: $tab, options: [
                    .init(tag: 0, label: xLoc("运行中的应用"), a11y: xLoc("运行中的应用")),
                    .init(tag: 1, label: xLoc("启动项"), a11y: xLoc("启动项")),
                ])
                .accessibilityLabel(xLoc("视图切换"))
            }
            if tab == 0, let freed = quitFreed {
                // 批量退出完成：统一计数庆祝（释放内存 + 退出应用数）。
                TaskCompletionView(
                    animateTo: freed,
                    // 诚实标注为「估计」：这里累加的是退出前各应用的内存占用，不等于系统真正回收的自由内存
                    //（内核会做压缩/惰性回收，实际可用内存变化未必等于此和），故用「约释放」而非「已释放」。
                    metricText: { xLocF("约释放 %@", $0.formattedMemory) },
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
        .onChange(of: tab) { reload() }
        .alert(xLoc("启动项状态"), isPresented: Binding(get: { toggleWarning != nil }, set: { if !$0 { toggleWarning = nil } })) {
            Button(xLoc("好"), role: .cancel) {}
        } message: {
            Text(toggleWarning ?? "")
        }
    }

    @ViewBuilder private var runningSection: some View {
        // 英雄区：实时内存压力环 + 构成条 + 释放内存（页面不再是「卡片行墙」，P4·C5）。
        if let feed {
            MemoryHeroCard(feed: feed, env: env)
        }
        if runningApps.isEmpty {
            XEmptyState(systemImage: "app.dashed",
                        title: xLoc("没有正在运行的前台应用"),
                        subtitle: xLoc("前台应用退出后，这里会实时更新。"))
                .frame(maxHeight: 260)
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
        // 按内存占用降序 + 行内占比条（一眼看清谁在吃内存，对齐 Top 进程行的语言）。
        let sorted = runningApps.sorted { (memByPID[$0.pid] ?? 0) > (memByPID[$1.pid] ?? 0) }
        let maxMem = max(memByPID.values.max() ?? 1, 1)
        ForEach(sorted) { app in
            runningRow(app, maxMem: maxMem)
        }
    }

    private func runningRow(_ app: RunningAppItem, maxMem: Int64) -> some View {
        XCard(padding: XSpacing.m) {
            HStack(spacing: XSpacing.m) {
                XCheckbox(isOn: selection.contains(app.pid)) { toggleSelect(app.pid) }
                if let path = app.iconPath {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: path))
                        .resizable().frame(width: 30, height: 30)
                }
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(app.name).font(XFont.bodyEmphasis).foregroundStyle(XColor.textPrimary)
                        Spacer()
                    }
                    if let mem = memByPID[app.pid] {
                        // 行内占比条：相对当前最大占用归一（同屏相对比较，非绝对刻度）。
                        GeometryReader { g in
                            ZStack(alignment: .leading) {
                                Capsule().fill(XColor.surfaceAlt)
                                Capsule().fill(LinearGradient(colors: XColor.metricMemory,
                                                              startPoint: .leading, endPoint: .trailing))
                                    .frame(width: max(3, g.size.width * CGFloat(Double(mem) / Double(maxMem))))
                            }
                        }
                        .frame(height: 4)
                    } else {
                        Text(app.bundleID).font(XFont.caption).foregroundStyle(XColor.textSecondary).lineLimit(1)
                    }
                }
                if let mem = memByPID[app.pid] {
                    VStack(alignment: .trailing, spacing: 1) {
                        Text(mem.formattedMemory).font(XFont.mono).foregroundStyle(XColor.textPrimary)
                        Text(xLoc("内存")).font(XFont.nano).foregroundStyle(XColor.textTertiary)
                    }
                    .frame(minWidth: 72, alignment: .trailing)
                }
                Button(xLoc("退出")) { env.optimization.quit(pid: app.pid); reload() }
                    .buttonStyle(XSecondaryButtonStyle(compact: true))
            }
        }
        .hoverLift(2)
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
            XEmptyState(systemImage: "bolt.slash",
                        title: xLoc("未发现启动代理"),
                        subtitle: xLoc("没有第三方应用注册开机自启动——很干净。"), kind: .success)
                .frame(maxHeight: 300)
        }
        ForEach(agents) { agent in
            startupRow(agent)
        }
    }

    private func startupRow(_ agent: LaunchAgentItem) -> some View {
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
                impactDots(agent)
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
                        .toggleStyle(XThemeSwitchStyle()).labelsHidden()
                        .accessibilityLabel(xLocF("启用或停用启动项 %@", agent.label))
                }
            }
        }
        .hoverLift(2)
    }

    /// 「对开机的影响」权重点（诚实推断：按启动项类型分级，非实测耗时——悬停说明推断依据）。
    private func impactDots(_ agent: LaunchAgentItem) -> some View {
        let level = !agent.isEnabled ? 0 : (agent.isSystem ? 3 : 2)
        let tint: Color = level >= 3 ? XColor.warning : (level >= 2 ? XColor.brand : XColor.idle)
        return HStack(spacing: 2) {
            ForEach(0..<3, id: \.self) { i in
                Circle().fill(i < level ? tint : XColor.idle.opacity(0.5)).frame(width: 5, height: 5)
            }
        }
        .help(xLoc("对开机的影响（按启动项类型推断：系统级 > 用户级已启用 > 已停用）"))
        .accessibilityLabel(xLoc("对开机的影响（按启动项类型推断：系统级 > 用户级已启用 > 已停用）"))
    }

    private func reload() {
        // NSWorkspace 只能在主线程枚举前台应用，先同步取回。
        let apps = env.optimization.runningApps()
        runningApps = apps
        // 启动代理枚举（磁盘 I/O）+ 逐进程内存采样（proc_pid_rusage × N）搬到后台线程，
        // 只把结果发布回主线程，避免在主线程同步阻塞 UI（镜像 HardwareViewModel.refreshHealth）。
        let sampler = self.sampler
        let optimization = env.optimization
        Task { @MainActor in
            let gathered = await Task.detached(priority: .userInitiated) { () -> (agents: [LaunchAgentItem], mem: [Int32: Int64]) in
                let agentItems = optimization.launchAgents()
                var map: [Int32: Int64] = [:]
                for app in apps { if let m = sampler.memoryFootprint(pid: app.pid) { map[app.pid] = m } }
                return (agentItems, map)
            }.value
            agents = gathered.agents
            memByPID = gathered.mem
        }
    }
}

// MARK: - 内存英雄区（实时压力环 + 构成条 + 释放内存快捷操作）

private struct MemoryHeroCard: View {
    @ObservedObject var feed: MetricsFeed
    let env: XicoEnvironment
    @State private var freeingMemory = false
    @State private var freeMemNote: String?

    var body: some View {
        XCard {
            if let s = feed.liveSnapshot {
                HStack(spacing: XSpacing.xl) {
                    XRingGauge(progress: s.memoryUsedFraction,
                               colors: XColor.gauge(s.memoryUsedFraction),
                               lineWidth: 9, size: 96, a11yLabel: xLoc("内存占用")) {
                        VStack(spacing: 0) {
                            Text("\(Int((s.memoryUsedFraction * 100).rounded()))%")
                                .font(XFont.monoMid).foregroundStyle(XColor.textPrimary)
                            Text(xLoc("内存")).font(XFont.nano).foregroundStyle(XColor.textTertiary)
                        }
                    }
                    VStack(alignment: .leading, spacing: XSpacing.s) {
                        HStack {
                            Text(xLocF("%@ / %@", s.memoryUsed.formattedMemory, s.memoryTotal.formattedMemory))
                                .font(XFont.monoLarge).foregroundStyle(XColor.textPrimary)
                                .contentTransition(.numericText())
                            Spacer()
                        }
                        let total = max(Double(s.memoryTotal), 1)
                        XSegmentBar(segments: [
                            .init(id: "app", fraction: Double(s.memoryApp) / total, color: XColor.memApp),
                            .init(id: "wired", fraction: Double(s.memoryWired) / total, color: XColor.memWired),
                            .init(id: "comp", fraction: Double(s.memoryCompressed) / total, color: XColor.memCompressed),
                            .init(id: "cached", fraction: Double(s.memoryCached) / total, color: XColor.memCached),
                        ], height: 8)
                        HStack(spacing: XSpacing.m) {
                            legend(xLoc("应用"), XColor.memApp, s.memoryApp)
                            legend(xLoc("联动"), XColor.memWired, s.memoryWired)
                            legend(xLoc("已压缩"), XColor.memCompressed, s.memoryCompressed)
                            legend(xLoc("缓存"), XColor.memCached, s.memoryCached)
                            Spacer()
                        }
                        if let note = freeMemNote {
                            Text(note).font(XFont.caption).foregroundStyle(XColor.textTertiary)
                        }
                    }
                    VStack {
                        Button {
                            freeMemory()
                        } label: {
                            HStack(spacing: XSpacing.xs) {
                                if freeingMemory { XSpinner(size: 13) } else { Image(systemName: "memorychip") }
                                Text(freeingMemory ? xLoc("释放中…") : xLoc("释放内存"))
                            }
                        }
                        .buttonStyle(XPrimaryButtonStyle(compact: true))
                        .disabled(freeingMemory)
                        .accessibilityLabel(xLoc("释放内存"))
                    }
                }
            } else {
                HStack(spacing: XSpacing.l) {
                    XSkeleton(width: 96, height: 96, cornerRadius: 48)
                    XSkeletonRows(count: 3)
                }
            }
        }
    }

    private func legend(_ label: String, _ color: Color, _ bytes: Int64) -> some View {
        HStack(spacing: 3) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(label).font(XFont.micro).foregroundStyle(XColor.textSecondary)
            Text(bytes.formattedMemory).font(XFont.micro).foregroundStyle(XColor.textTertiary).monospacedDigit()
        }
    }

    /// 「释放内存」快捷操作：与菜单栏快捷面板同一入口（经特权助手 purge 回收非活跃内存）。
    /// 助手未安装时优雅降级为提示（不静默失败），文案与 MenuPanels 共用同一批 xLoc 键。
    private func freeMemory() {
        guard !freeingMemory else { return }
        guard env.helper.status() == .installed else {
            freeMemNote = xLoc("需先在「维护」页安装后台助手")
            return
        }
        freeingMemory = true
        freeMemNote = nil
        Task {
            let (ok, out) = await env.helper.runMaintenance(.freeMemory)
            freeingMemory = false
            freeMemNote = ok ? xLoc("已释放非活跃内存") : (out ?? xLoc("释放失败"))
        }
    }
}
