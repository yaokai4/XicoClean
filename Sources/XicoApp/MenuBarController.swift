import AppKit
import SwiftUI
import Combine
import Features
import Infrastructure
import DesignSystem

/// 用 AppKit 接管菜单栏：NSStatusItem + 无箭头「玻璃卡片」浮窗（P9 弃用 NSPopover 尖角样式）。
/// 支持在「设置」里实时编辑显示哪些项（像 iStat 一样可自定义）。
///
/// P3 升级：字形渲染 CG 直绘（见 MenuBarGlyph）、真 · 合并项、电池项、项目排序（xico.mb.order）、
/// 每项独立刷新率、面板可钉住为浮动小窗。
/// P9 升级：点击面板 = 独立无边框卡片窗（圆角 16 + 系统玻璃材质，macOS 26 走原生
/// NSGlassEffectView）——与现代菜单栏工具一致的卡片式展示，无 popover 尖角。
@MainActor
final class MenuBarController: NSObject {
    private let model: AppModel
    private var statusItems: [String: NSStatusItem] = [:]
    private var cancellables = Set<AnyCancellable>()
    /// 点击面板（卡片窗）。同一时间至多一个；再次点同一图标关闭，点其他图标切换。
    private var cardPanel: NSPanel?
    private var cardPanelID: String?
    /// 面板外点击监听（全局 = 其他 App / 桌面；本地 = 本进程窗口）+ Esc 关闭。
    private var outsideClickMonitor: Any?
    private var insideClickMonitor: Any?
    private var escKeyMonitor: Any?
    /// 上一次 `xico.mb.*` 配置快照——仅菜单栏相关键变化才重建（审计 P3）。
    private var lastMBDefaults: [String: String] = [:]
    /// 每项上次真正重绘的时刻——每项独立刷新率（P3·M7）的跳拍依据。
    private var lastImageUpdate: [String: Date] = [:]
    /// 钉住的浮动面板（P3·M5）：id → NSPanel。钉住期间保持详情采样。
    private var pinnedPanels: [String: NSPanel] = [:]

    /// 各项：UserDefaults 键 + 默认是否显示。默认顺序（用户可在设置里重排，存 xico.mb.order）。
    private let config: [(id: String, key: String, def: Bool)] = [
        ("network", "xico.mb.network", true),
        ("disk",    "xico.mb.disk",    false),
        ("temp",    "xico.mb.temp",    false),
        ("battery", "xico.mb.battery", false),
        ("gpu",     "xico.mb.gpu",     false),
        ("memory",  "xico.mb.memory",  true),
        ("cpu",     "xico.mb.cpu",     true),
        ("combined","xico.mb.combined", false)
    ]

    init(model: AppModel) {
        self.model = model
        super.init()

        model.startMetricsTimer()            // 即使主窗口未开，菜单栏也持续刷新
        lastMBDefaults = Self.mbDefaultsSnapshot()
        rebuild()

        // 指标变化 → 刷新图标
        model.liveMetricsFeed.$liveSnapshot
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateImages() }
            .store(in: &cancellables)

        // 设置里的开关变化 → 重建菜单栏项（实时增删）。
        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .debounce(for: .milliseconds(150), scheduler: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                let snapshot = Self.mbDefaultsSnapshot()
                guard snapshot != self.lastMBDefaults else { return }
                self.lastMBDefaults = snapshot
                self.rebuild()
            }
            .store(in: &cancellables)
    }

    /// 当前所有 `xico.mb.*` 偏好键的字符串化快照（供变化比对）。
    private static func mbDefaultsSnapshot() -> [String: String] {
        var out: [String: String] = [:]
        for (key, value) in UserDefaults.standard.dictionaryRepresentation() where key.hasPrefix("xico.mb.") {
            out[key] = "\(value)"
        }
        return out
    }

    private func isEnabled(_ key: String, default def: Bool) -> Bool {
        UserDefaults.standard.object(forKey: key) == nil ? def : UserDefaults.standard.bool(forKey: key)
    }

    /// 用户排序（左→右显示顺序）；新增项自动补到末尾，绝不因升级而消失。
    private func orderedIDs() -> [String] {
        let all = config.map(\.id)
        guard let saved = UserDefaults.standard.string(forKey: "xico.mb.order")?
            .split(separator: ",").map(String.init), !saved.isEmpty else { return all }
        let known = saved.filter { all.contains($0) }
        let missing = all.filter { !known.contains($0) }
        return known + missing
    }

    /// 按设置增删 NSStatusItem。顺序或集合变化 → 整体重排（倒序插入 = 视觉左→右）。
    private func rebuild() {
        let desired = orderedIDs().filter { id in
            guard let c = config.first(where: { $0.id == id }) else { return false }
            return isEnabled(c.key, default: c.def)
        }
        let currentOrder = Array(statusItems.keys)
        let needFullRebuild = Set(desired) != Set(currentOrder)
            || UserDefaults.standard.string(forKey: "xico.mb.order") != nil

        if needFullRebuild {
            for (_, item) in statusItems { NSStatusBar.system.removeStatusItem(item) }
            statusItems.removeAll()
            for id in desired.reversed() {
                let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
                item.button?.target = self
                item.button?.action = #selector(handleClick(_:))
                item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
                item.button?.identifier = NSUserInterfaceItemIdentifier(id)
                item.button?.imageScaling = .scaleNone
                statusItems[id] = item
            }
        }
        lastImageUpdate.removeAll()
        updateImages(force: true)
    }

    private func contextMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(withTitle: xLoc("打开 Xico"), action: #selector(openMainWindow), keyEquivalent: "").target = self
        menu.addItem(withTitle: xLoc("设置…"), action: #selector(openSettings), keyEquivalent: ",").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: xLoc("退出 Xico"), action: #selector(quit), keyEquivalent: "q").target = self
        return menu
    }

    @objc private func openMainWindow() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        for window in NSApp.windows where window.canBecomeMain {
            window.makeKeyAndOrderFront(nil)
        }
    }

    @objc private func openSettings() {
        model.selection = .settings
        openMainWindow()
    }

    @objc private func quit() { NSApp.terminate(nil) }

    /// 每项独立刷新率（秒）。未设置 → 跟随全局采样节拍。
    private func itemInterval(_ id: String) -> Double? {
        let v = UserDefaults.standard.double(forKey: "xico.mb.\(id).interval")
        return v > 0 ? v : nil
    }

    private func updateImages(force: Bool = false) {
        let s = model.liveSnapshot
        let now = Date()
        for (id, item) in statusItems {
            if !force, let interval = itemInterval(id), let last = lastImageUpdate[id],
               now.timeIntervalSince(last) < interval - 0.05 {
                continue
            }
            lastImageUpdate[id] = now
            item.button?.image = image(for: id, snapshot: s)
        }
    }

    /// 每项独立的显示样式；未设置时用该项默认（与设置页 @AppStorage 默认一致）。
    private func defaultStyle(for id: String) -> MenuBarStyle {
        switch id {
        case "cpu", "memory", "gpu": return .rich
        case "network":              return .graph
        default:                     return .iconValue   // temp / disk / battery
        }
    }
    private func style(for id: String) -> MenuBarStyle {
        if let s = UserDefaults.standard.string(forKey: "xico.mb.\(id).style"),
           let st = MenuBarStyle(rawValue: s) { return st }
        return defaultStyle(for: id)
    }
    /// 每项独立的彩色开关。优先 `xico.mb.<id>.colored`，回退全局 `xico.mb.colored`。
    private func colored(for id: String) -> Bool {
        if UserDefaults.standard.object(forKey: "xico.mb.\(id).colored") != nil {
            return UserDefaults.standard.bool(forKey: "xico.mb.\(id).colored")
        }
        return UserDefaults.standard.object(forKey: "xico.mb.colored") == nil ? false : UserDefaults.standard.bool(forKey: "xico.mb.colored")
    }

    private func image(for id: String, snapshot s: SystemSnapshot?) -> NSImage? {
        let style = style(for: id)
        let colored = colored(for: id)
        switch id {
        case "cpu":      return MenuBarGlyph.cpu(fraction: s?.cpuUsage ?? 0,
                                                 history: model.cpuHistory, style: style, colored: colored)
        case "memory":
            // 口径（P8）：默认「压力」（kern.memorystatus_level 连续值，与 iStat 菜单栏一致）；
            // 可在设置切回「占用」。压力读不到时自动退回占用。
            let usePressure = UserDefaults.standard.string(forKey: "xico.mb.memory.metric") != "used"
            let memFraction = usePressure ? (s?.memoryPressurePercent ?? s?.memoryUsedFraction ?? 0)
                                          : (s?.memoryUsedFraction ?? 0)
            return MenuBarGlyph.memory(fraction: memFraction,
                                       history: model.memHistory, style: style, colored: colored)
        case "network":  return MenuBarGlyph.network(down: s?.netDownBytesPerSec ?? 0,
                                                     up: s?.netUpBytesPerSec ?? 0,
                                                     history: netNormHistory(), style: style, colored: colored)
        case "temp":     return MenuBarGlyph.temperature(celsius: s?.cpuTemp, style: style, colored: colored)
        case "disk":     return MenuBarGlyph.disk(fraction: s?.diskUsedFraction ?? 0, style: style, colored: colored)
        case "gpu":      return MenuBarGlyph.gpu(fraction: s?.gpuUsage ?? 0,
                                                 history: model.gpuHistory, style: style, colored: colored)
        case "battery":  return MenuBarGlyph.battery(percent: s?.batteryPercent,
                                                     charging: s?.batteryCharging ?? false,
                                                     style: style, colored: colored)
        case "combined": return MenuBarGlyph.combined(slots: combinedSlots(s), colored: colored)
        default:         return nil
        }
    }

    /// 真 · 合并项（P3·M1）：按 `xico.mb.combined.<id>` 勾选构建槽位（默认 cpu+memory+network）。
    private func combinedSlots(_ s: SystemSnapshot?) -> [MenuCombinedSlot] {
        let showValues = isEnabled("xico.mb.combined.values", default: false)
        var slots: [MenuCombinedSlot] = []
        func value(_ f: Double) -> String? { showValues ? "\(Int((f * 100).rounded()))%" : nil }
        for id in orderedIDs() where id != "combined" && isEnabled("xico.mb.combined.\(id)", default: ["cpu", "memory", "network"].contains(id)) {
            switch id {
            case "cpu":
                slots.append(MenuCombinedSlot(viz: .histogram(model.cpuHistory), tint: XColor.metricCPU,
                                              value: value(s?.cpuUsage ?? 0)))
            case "memory":
                slots.append(MenuCombinedSlot(viz: .pie(s?.memoryUsedFraction ?? 0), tint: XColor.metricMemory,
                                              value: value(s?.memoryUsedFraction ?? 0)))
            case "gpu":
                slots.append(MenuCombinedSlot(viz: .pie(s?.gpuUsage ?? 0), tint: XColor.metricGPU,
                                              value: value(s?.gpuUsage ?? 0)))
            case "disk":
                slots.append(MenuCombinedSlot(viz: .pie(s?.diskUsedFraction ?? 0), tint: XColor.metricDisk,
                                              value: value(s?.diskUsedFraction ?? 0)))
            case "network":
                slots.append(MenuCombinedSlot(viz: .net(down: (s?.netDownBytesPerSec ?? 0).compactRate,
                                                        up: (s?.netUpBytesPerSec ?? 0).compactRate),
                                              tint: XColor.metricNetwork))
            case "temp":
                let t = s?.cpuTemp
                slots.append(MenuCombinedSlot(viz: .text((t != nil && t! > 0) ? "\(Int(t!.rounded()))°" : "—°"),
                                              tint: [XColor.warning]))
            case "battery":
                if let pct = s?.batteryPercent {
                    slots.append(MenuCombinedSlot(viz: .text("\(pct)%"), tint: [XColor.success]))
                }
            default: break
            }
        }
        return slots
    }

    /// 网络折线归一化：总吞吐（下行+上行），同基准归一。
    private func netNormHistory() -> [Double] {
        let down = model.netDownHistory
        let up = model.netUpHistory
        let maxV = max((down + up).max() ?? 1, 1)
        let n = min(down.count, up.count)
        guard n > 0 else { return down.map { $0 / maxV } }
        return zip(down.suffix(n), up.suffix(n)).map { (d, u) in (d + u) / maxV }
    }

    @objc private func handleClick(_ sender: NSStatusBarButton) {
        // 右键（或 Control 左键）→ 上下文菜单
        if let event = NSApp.currentEvent,
           event.type == .rightMouseUp || event.modifierFlags.contains(.control) {
            if let item = statusItems.first(where: { $0.value.button === sender })?.value {
                let menu = contextMenu()
                item.menu = menu
                item.button?.performClick(nil)
                item.menu = nil
            }
            return
        }
        guard let id = sender.identifier?.rawValue else { return }
        // 已钉住的面板：点图标带到前台。
        if let pinned = pinnedPanels[id] {
            pinned.makeKeyAndOrderFront(nil)
            return
        }
        // 再次点同一项 → 关闭；点其他项 → 切换。
        if cardPanel != nil, cardPanelID == id {
            closeCardPanel()
            return
        }
        closeCardPanel()
        showCardPanel(id: id, from: sender)
    }

    // MARK: 无箭头玻璃卡片浮窗（P9：替代 NSPopover 尖角）

    /// 可成为 key 的无边框面板（borderless 默认不能 key；Esc 与键盘交互需要）。
    /// cancelOperation = Esc 兜底：即使事件监视器失效（引用错位等异常态），键窗自己也能关。
    private final class KeyableCardPanel: NSPanel {
        override var canBecomeKey: Bool { true }
        override func cancelOperation(_ sender: Any?) { close() }
    }

    private func showCardPanel(id: String, from button: NSStatusBarButton) {
        let host = NSHostingController(rootView: AnyView(MenuCardContainer { self.panelContent(for: id, pinned: false) }))
        let panel = KeyableCardPanel(contentViewController: host)
        panel.styleMask = [.borderless, .nonactivatingPanel, .fullSizeContentView]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true            // 系统按内容形状投影（圆角卡片影）
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        // 关闭体系的第一防线：identifier 供孤儿清扫辨认；delegate 供失焦即关（见
        // windowDidResignKey）——与 NSPopover 同源的机制，不依赖事件监视器。
        panel.identifier = NSUserInterfaceItemIdentifier("card.\(id)")
        panel.delegate = self

        // 定位：状态项按钮正下方 6pt，水平居中并夹在屏幕可见区内。
        let size = host.view.fittingSize
        let w = max(size.width, 300), h = max(size.height, 200)
        panel.setContentSize(NSSize(width: w, height: h))
        if let btnWindow = button.window {
            let btnFrame = btnWindow.convertToScreen(button.convert(button.bounds, to: nil))
            let screen = btnWindow.screen ?? NSScreen.main
            let visible = screen?.visibleFrame ?? .zero
            var x = btnFrame.midX - w / 2
            x = min(max(x, visible.minX + 8), visible.maxX - w - 8)
            let y = btnFrame.minY - 6 - h
            panel.setFrameOrigin(NSPoint(x: x, y: y))
        }
        panel.makeKeyAndOrderFront(nil)
        cardPanel = panel
        cardPanelID = id
        installDismissMonitors()
        // 卡片打开即算「详情消费者可见」：恢复温度/风扇/GPU 等详情采样。
        model.metricsDetailConsumerVisible = true
    }

    private func closeCardPanel() {
        removeDismissMonitors()
        // 先断引用再收窗：orderOut 可能同步触发 windowDidResignKey → 重入本方法，
        // 引用已清空时重入是无害空转。
        let panel = cardPanel
        cardPanel = nil
        cardPanelID = nil
        panel?.orderOut(nil)
        // 孤儿清扫：任何仍在屏上的卡片窗一并收起——即使引用因任何异常丢失
        //（用户实测过「卡片永远关不掉」，根因就是引用与屏上窗口脱钩后监视器全部失效）。
        for w in NSApp.windows where (w.identifier?.rawValue.hasPrefix("card.") ?? false) && w.isVisible {
            w.orderOut(nil)
        }
        // 钉住的浮窗仍在时保持详情采样，否则回稳态省电。
        if pinnedPanels.isEmpty { model.metricsDetailConsumerVisible = false }
    }

    // MARK: 钉住面板（P3·M5：卡片转常驻浮动小窗，可拖动、跨重启记忆位置）

    private func pin(id: String) {
        let cardFrame = cardPanel?.frame   // 关卡片前记下位置：首钉落位用
        closeCardPanel()
        if let existing = pinnedPanels[id] {
            existing.makeKeyAndOrderFront(nil)
            return
        }
        let host = NSHostingController(rootView: AnyView(MenuCardContainer { self.panelContent(for: id, pinned: true) }))
        let panel = KeyableCardPanel(contentViewController: host)
        panel.styleMask = [.borderless, .nonactivatingPanel, .fullSizeContentView]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true   // 钉住版可整卡拖动
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        // NSPanel 默认失活即隐藏——不关掉的话，用户一切走别的 App「常驻」小窗就凭空消失、
        // 切回来又自己冒出（幽灵卡片的另一半根因，对抗审查实机复现）。
        panel.hidesOnDeactivate = false
        panel.delegate = self
        panel.identifier = NSUserInterfaceItemIdentifier("pin.\(id)")
        panel.setFrameAutosaveName("xico.mb.pin.\(id)")
        // 首次钉住没有记忆位置时，NSWindow 默认落在屏幕左下角 (0,0)——看起来像
        // 「点了图钉面板直接消失」。落到刚才卡片的位置，钉住读作「卡片转常驻」。
        if UserDefaults.standard.string(forKey: "NSWindow Frame xico.mb.pin.\(id)") == nil,
           let f = cardFrame {
            panel.setFrameOrigin(f.origin)
        }
        pinnedPanels[id] = panel
        panel.makeKeyAndOrderFront(nil)
        model.metricsDetailConsumerVisible = true
    }

    // MARK: 关闭手势（点外部 / 点本进程其他窗口 / Esc）

    private func installDismissMonitors() {
        removeDismissMonitors()
        // 代际守卫：本方法在 cardPanel 赋值后调用。主线程停顿（扫描等）时全局事件可能
        // 迟到——排队的关闭 Task 只允许关「自己那一代」的卡片，不得误杀刚切换打开的新卡。
        let owner = cardPanel
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.cardPanel === owner else { return }
                self.closeCardPanel()
            }
        }
        insideClickMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] event in
            guard let self, let card = self.cardPanel else { return event }
            let statusWindows = self.statusItems.values.compactMap { $0.button?.window }
            if event.window === card { return event }                                    // 卡片内交互
            if statusWindows.contains(where: { $0 === event.window }) { return event }   // 状态项自己管开关
            self.closeCardPanel()
            return event
        }
        escKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard let self, self.cardPanel != nil, event.keyCode == 53 else { return event }   // 53 = Esc
            // 键窗是钉住面板时放行——由面板自己的 cancelOperation 关闭钉住窗，而非误关卡片。
            if let kw = NSApp.keyWindow, kw !== self.cardPanel,
               kw.identifier?.rawValue.hasPrefix("pin.") == true { return event }
            self.closeCardPanel()
            return nil
        }
    }

    private func removeDismissMonitors() {
        for m in [outsideClickMonitor, insideClickMonitor, escKeyMonitor] {
            if let m { NSEvent.removeMonitor(m) }
        }
        outsideClickMonitor = nil
        insideClickMonitor = nil
        escKeyMonitor = nil
    }

    @ViewBuilder private func panelContent(for id: String, pinned: Bool) -> some View {
        let metric: MenuMetric? = {
            switch id {
            case "cpu": return .cpu
            case "memory": return .memory
            case "network": return .network
            case "temp": return .temperature
            case "disk": return .disk
            case "gpu": return .gpu
            case "battery": return .battery
            default: return nil
            }
        }()
        if let metric {
            MenuMetricPanel(model: model, metric: metric,
                            onPin: pinned ? nil : { [weak self] in self?.pin(id: id) },
                            onClose: pinned ? { [weak self] in self?.closePinned(id: id) } : nil)
        } else {
            MenuBarView(model: model)   // 合并总览
        }
    }

    /// 关闭钉住面板（✕ 按钮/Esc）。close() 走 windowWillClose → 清引用、必要时恢复稳态采样。
    private func closePinned(id: String) {
        pinnedPanels[id]?.close()
    }
}

// MARK: 窗口委托：失焦即关（卡片）+ 关闭清引用（钉住/卡片兜底）

extension MenuBarController: NSWindowDelegate {
    /// 卡片窗失去 key → 立即关闭。这是与 NSPopover(.transient) 同源的可靠机制：
    /// 点击本进程其他窗口、其他 App、切换 App 都会触发，不依赖事件监视器。
    /// 钉住面板同样会经过这里，但只有 cardPanel 命中判定——钉住窗失焦本就该常驻。
    func windowDidResignKey(_ notification: Notification) {
        guard let win = notification.object as? NSWindow, win === cardPanel else { return }
        closeCardPanel()
    }

    func windowWillClose(_ notification: Notification) {
        guard let win = notification.object as? NSWindow,
              let raw = win.identifier?.rawValue else { return }
        if raw.hasPrefix("pin.") {
            pinnedPanels[String(raw.dropFirst("pin.".count))] = nil
        } else if raw.hasPrefix("card."), win === cardPanel {
            // 卡片被 close() 关掉（Esc 兜底路径等）：同步清引用与监视器。
            removeDismissMonitors()
            cardPanel = nil
            cardPanelID = nil
        }
        if cardPanel == nil && pinnedPanels.isEmpty { model.metricsDetailConsumerVisible = false }
    }
}

// MARK: - 玻璃卡片容器（macOS 26 原生 Liquid Glass；低版本系统 vibrancy 弹窗材质）

private struct MenuCardContainer<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        content
            .background(GlassCardBackground())
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.10), lineWidth: 1)
            )
    }
}

/// 卡片玻璃底：macOS 26 用原生 NSGlassEffectView（真 Liquid Glass 折射），
/// 低版本回退 NSVisualEffectView 弹窗材质（vibrancy 玻璃）。
private struct GlassCardBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.cornerRadius = 16
            return glass
        }
        let v = NSVisualEffectView()
        v.material = .popover
        v.blendingMode = .behindWindow
        v.state = .active
        return v
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}
