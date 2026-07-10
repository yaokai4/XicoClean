import AppKit
import SwiftUI
import Combine
import Features
import Infrastructure
import DesignSystem

/// 用 AppKit 接管菜单栏：NSStatusItem + 单个瞬态 NSPopover。
/// 解决 MenuBarExtra(.window) 面板「点开后不会自动消失/多个堆叠」的问题，
/// 并支持在「设置」里实时编辑显示哪些项（像 iStat 一样可自定义）。
///
/// P3 升级：字形渲染换血为 CG 直绘（见 MenuBarGlyph）、真 · 合并项（多迷你图并排）、
/// 电池项、项目可排序（xico.mb.order）、每项独立刷新率、面板可钉住为浮动小窗。
@MainActor
final class MenuBarController: NSObject, NSPopoverDelegate {
    private let model: AppModel
    private var statusItems: [String: NSStatusItem] = [:]
    private let popover = NSPopover()
    private var cancellables = Set<AnyCancellable>()
    /// 面板打开期间监听「面板之外」的鼠标点击，点到别处即关闭。
    /// `.transient` 在 accessory（菜单栏）App 里对「点其他 App」不总生效，故显式补一层监听。
    private var outsideClickMonitor: Any?
    /// 上一次 `xico.mb.*` 配置快照——UserDefaults.didChange 是全局广播，
    /// 仅当菜单栏相关键真的变了才重建，避免任意无关写入都触发全量重建（审计 P3）。
    private var lastMBDefaults: [String: String] = [:]
    /// 每项上次真正重绘的时刻——每项独立刷新率（P3·M7）的跳拍依据。
    private var lastImageUpdate: [String: Date] = [:]
    /// 钉住的浮动面板（P3·M5）：id → NSPanel。钉住期间保持详情采样。
    private var pinnedPanels: [String: NSPanel] = [:]

    /// 各项：UserDefaults 键 + 默认是否显示。默认顺序（用户可在设置里拖拽重排，存 xico.mb.order）。
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
        popover.behavior = .transient        // 点击外部自动关闭
        popover.animates = true
        popover.delegate = self              // popoverDidClose → 清理点击监听

        model.startMetricsTimer()            // 即使主窗口未开，菜单栏也持续刷新
        lastMBDefaults = Self.mbDefaultsSnapshot()
        rebuild()

        // 指标变化 → 刷新图标（liveSnapshot 已从 AppModel 迁入 MetricsFeed，改订阅 feed）
        model.liveMetricsFeed.$liveSnapshot
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateImages() }
            .store(in: &cancellables)

        // 设置里的开关变化 → 重建菜单栏项（实时增删）。
        // 先比对 xico.mb.* 快照：无关键（如其它偏好写入）变化时直接 no-op，不重建。
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

    /// 用户排序（设置页拖拽，左→右显示顺序）；未重排过则用 config 默认顺序。
    /// 新增的项（老版本存的 order 里没有）追加到末尾，绝不因升级而消失。
    private func orderedIDs() -> [String] {
        let all = config.map(\.id)
        guard let saved = UserDefaults.standard.string(forKey: "xico.mb.order")?
            .split(separator: ",").map(String.init), !saved.isEmpty else { return all }
        let known = saved.filter { all.contains($0) }
        let missing = all.filter { !known.contains($0) }
        return known + missing
    }

    /// 按设置增删 NSStatusItem。顺序或集合变化 → 整体重排（按用户顺序倒序插入：
    /// AppKit 后插入者靠左，故「显示顺序左→右」= 倒序 add）。
    private func rebuild() {
        let desired = orderedIDs().filter { id in
            guard let c = config.first(where: { $0.id == id }) else { return false }
            return isEnabled(c.key, default: c.def)
        }
        let currentOrder = Array(statusItems.keys)

        // 集合相同且无顺序诉求差异时走增量；否则全量重排。
        let needFullRebuild = Set(desired) != Set(currentOrder)
            || UserDefaults.standard.string(forKey: "xico.mb.order") != nil

        if needFullRebuild {
            for (_, item) in statusItems { NSStatusBar.system.removeStatusItem(item) }
            statusItems.removeAll()
            for id in desired.reversed() {   // 倒序插入 → 视觉左→右 = 用户顺序
                let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
                item.button?.target = self
                item.button?.action = #selector(handleClick(_:))
                item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
                item.button?.identifier = NSUserInterfaceItemIdentifier(id)
                item.button?.imageScaling = .scaleNone
                statusItems[id] = item
            }
        }
        lastImageUpdate.removeAll()   // 重建后全部立即重绘一次
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

    /// 每项独立刷新率（秒）。未设置 → 跟随全局采样节拍（返回 nil = 每 tick 都刷）。
    private func itemInterval(_ id: String) -> Double? {
        let v = UserDefaults.standard.double(forKey: "xico.mb.\(id).interval")
        return v > 0 ? v : nil
    }

    private func updateImages(force: Bool = false) {
        let s = model.liveSnapshot
        let now = Date()
        for (id, item) in statusItems {
            // 每项跳拍：设定了独立刷新率的项，距上次重绘不足间隔则跳过本 tick（P3·M7）。
            if !force, let interval = itemInterval(id), let last = lastImageUpdate[id],
               now.timeIntervalSince(last) < interval - 0.05 {
                continue
            }
            lastImageUpdate[id] = now
            item.button?.image = image(for: id, snapshot: s)
        }
    }

    /// 每项独立的显示样式（像 iStat：CPU 用直方图、网络用折线…各自不同）。
    /// 优先读 `xico.mb.<id>.style`；未设置时用该项的默认样式（须与设置页 @AppStorage 默认一致）。
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
    /// 每项独立的彩色开关。优先 `xico.mb.<id>.colored`，回退全局 `xico.mb.colored`，再回退单色。
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
        case "memory":   return MenuBarGlyph.memory(fraction: s?.memoryUsedFraction ?? 0,
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

    /// 真 · 合并项（P3·M1）：按 `xico.mb.combined.<id>` 勾选构建槽位（默认 cpu+memory+network），
    /// 每槽位用该指标的紧凑可视化；`xico.mb.combined.values` 开关控制是否随图形显示数值。
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

    /// 网络折线归一化：绘制**总吞吐（下行 + 上行）**，以同一「下行+上行」峰值为基准归一。
    /// 此前只画下行，上行流量在菜单栏折线里完全不可见（审计 P3 MenuBarController:178）；
    /// 现按样本逐点相加，令上行也计入折线高度。两序列长度不齐时以较短尾部对齐，避免错位。
    private func netNormHistory() -> [Double] {
        let down = model.netDownHistory
        let up = model.netUpHistory
        let maxV = max((down + up).max() ?? 1, 1)
        let n = min(down.count, up.count)
        guard n > 0 else { return down.map { $0 / maxV } }
        return zip(down.suffix(n), up.suffix(n)).map { (d, u) in (d + u) / maxV }
    }

    @objc private func handleClick(_ sender: NSStatusBarButton) {
        // 右键（或按住 Control 左键）→ 上下文菜单
        if let event = NSApp.currentEvent,
           event.type == .rightMouseUp || event.modifierFlags.contains(.control) {
            if let item = statusItems.first(where: { $0.value.button === sender })?.value {
                let menu = contextMenu()
                item.menu = menu
                item.button?.performClick(nil)   // 弹出菜单
                item.menu = nil                  // 立即摘除，恢复左键打开面板
            }
            return
        }
        guard let id = sender.identifier?.rawValue else { return }
        // 已钉住的面板：点图标把它带到前台，不再开重复 popover。
        if let pinned = pinnedPanels[id] {
            pinned.makeKeyAndOrderFront(nil)
            return
        }
        let sameOpen = popover.isShown && popover.contentViewController?.identifier?.rawValue == id
        if popover.isShown { popover.performClose(nil) }
        if sameOpen { return }                       // 再次点同一项 → 关闭
        showPopover(id: id, from: sender)
    }

    private func showPopover(id: String, from button: NSStatusBarButton) {
        let host = NSHostingController(rootView: AnyView(panel(for: id, pinned: false)))
        host.identifier = NSUserInterfaceItemIdentifier(id)
        popover.contentViewController = host
        let fitting = host.view.fittingSize
        popover.contentSize = NSSize(width: fitting.width > 0 ? fitting.width : 280,
                                     height: fitting.height > 0 ? fitting.height : 360)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
        installOutsideClickMonitor()
        // 弹窗打开即算「详情消费者可见」：即便无前台主窗口，也让 AppModel 恢复温度/风扇/GPU 等详情采样
        // （审计 P1 回归——此前该标志无人置位，常驻菜单栏弹窗里的详情面板会停采）。
        model.metricsDetailConsumerVisible = true
    }

    // MARK: 钉住面板（P3·M5：popover 转独立浮动小窗，可拖动、跨重启记忆位置）

    private func pin(id: String) {
        popover.performClose(nil)
        if let existing = pinnedPanels[id] {
            existing.makeKeyAndOrderFront(nil)
            return
        }
        let host = NSHostingController(rootView: AnyView(panel(for: id, pinned: true)))
        let panel = NSPanel(contentViewController: host)
        panel.styleMask = [.titled, .closable, .fullSizeContentView, .nonactivatingPanel, .utilityWindow]
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.setFrameAutosaveName("xico.mb.pin.\(id)")
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        panel.identifier = NSUserInterfaceItemIdentifier("pin.\(id)")
        pinnedPanels[id] = panel
        panel.makeKeyAndOrderFront(nil)
        model.metricsDetailConsumerVisible = true
    }

    private func unpin(id: String) {
        pinnedPanels[id]?.close()
        // 收尾在 windowWillClose 统一处理（点关闭按钮也走那里）。
    }

    // MARK: 点击面板之外即关闭（补齐 .transient 在菜单栏 App 里的漏网）

    private func installOutsideClickMonitor() {
        removeOutsideClickMonitor()
        // 全局监听：点其他 App 的窗口 / 桌面 → 关闭面板。
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] _ in
            self?.popover.performClose(nil)
        }
    }

    private func removeOutsideClickMonitor() {
        if let m = outsideClickMonitor {
            NSEvent.removeMonitor(m)
            outsideClickMonitor = nil
        }
    }

    /// 面板关闭（点外部、再次点同项、Esc 等任意途径）→ 摘除监听，避免泄漏与误触发。
    func popoverDidClose(_ notification: Notification) {
        removeOutsideClickMonitor()
        // 详情消费者随弹窗关闭而消失，恢复常驻低耗采样（仅图标折线所需的 cpu/mem/net/gpu）。
        // 防切换面板竞态：切面板时会先 performClose 再立即 show，此刻 isShown 已为 true → 保持置位不误清。
        // 钉住的浮窗仍在时也保持详情采样。
        if !popover.isShown && pinnedPanels.isEmpty { model.metricsDetailConsumerVisible = false }
    }

    @ViewBuilder private func panel(for id: String, pinned: Bool) -> some View {
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
                            onPin: pinned ? nil : { [weak self] in self?.pin(id: id) })
        } else {
            // 合并总览保持系统总览面板。
            MenuBarView(model: model)
        }
    }
}

// MARK: 钉住浮窗关闭 → 清引用、必要时恢复稳态采样

extension MenuBarController: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        guard let win = notification.object as? NSWindow,
              let raw = win.identifier?.rawValue, raw.hasPrefix("pin.") else { return }
        let id = String(raw.dropFirst("pin.".count))
        pinnedPanels[id] = nil
        if !popover.isShown && pinnedPanels.isEmpty { model.metricsDetailConsumerVisible = false }
    }
}
