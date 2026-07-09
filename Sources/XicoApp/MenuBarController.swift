import AppKit
import SwiftUI
import Combine
import Features
import Infrastructure
import DesignSystem

/// 用 AppKit 接管菜单栏：NSStatusItem + 单个瞬态 NSPopover。
/// 解决 MenuBarExtra(.window) 面板「点开后不会自动消失/多个堆叠」的问题，
/// 并支持在「设置」里实时编辑显示哪些项（像 iStat 一样可自定义）。
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

    /// 各项：UserDefaults 键 + 默认是否显示。顺序即菜单栏从右到左的插入顺序。
    private let config: [(id: String, key: String, def: Bool)] = [
        ("network", "xico.mb.network", true),
        ("disk",    "xico.mb.disk",    false),
        ("temp",    "xico.mb.temp",    false),
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

    /// 按设置增删 NSStatusItem
    private func rebuild() {
        let desired = config.filter { isEnabled($0.key, default: $0.def) }.map(\.id)

        for (id, item) in statusItems where !desired.contains(id) {
            NSStatusBar.system.removeStatusItem(item)
            statusItems[id] = nil
        }
        for id in desired where statusItems[id] == nil {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            item.button?.target = self
            item.button?.action = #selector(handleClick(_:))
            // 左键打开面板，右键弹出菜单（打开/设置/退出）——退出不再只藏在弹窗电源图标里
            item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
            item.button?.identifier = NSUserInterfaceItemIdentifier(id)
            item.button?.imageScaling = .scaleNone
            statusItems[id] = item
        }
        updateImages()
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

    private func updateImages() {
        let s = model.liveSnapshot
        for (id, item) in statusItems {
            item.button?.image = image(for: id, snapshot: s)
        }
    }

    /// 每项独立的显示样式（像 iStat：CPU 用直方图、网络用折线…各自不同）。
    /// 优先读 `xico.mb.<id>.style`；未设置时用该项的默认样式（须与设置页 @AppStorage 默认一致）。
    private func defaultStyle(for id: String) -> MenuBarStyle {
        switch id {
        case "cpu", "memory", "gpu": return .rich
        case "network":              return .graph
        default:                     return .iconValue   // temp / disk / combined
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
    /// 图形恒定加框（用户拍板：不再提供开关）。框即图表坐标系，内容贴边挤满；
    /// 环形自身就是完整图形，套框反而画蛇添足，仍保持裸露。
    private func border(for id: String) -> Bool { true }

    private func image(for id: String, snapshot s: SystemSnapshot?) -> NSImage? {
        let style = style(for: id)
        let colored = colored(for: id)
        let border = border(for: id)
        switch id {
        case "cpu":      return MenuBarGlyph.cpu(fraction: s?.cpuUsage ?? 0,
                                                 history: model.cpuHistory, style: style, colored: colored, border: border)
        case "memory":   return MenuBarGlyph.memory(fraction: s?.memoryUsedFraction ?? 0,
                                                    history: model.memHistory, style: style, colored: colored, border: border)
        case "network":  return MenuBarGlyph.network(down: s?.netDownBytesPerSec ?? 0,
                                                     up: s?.netUpBytesPerSec ?? 0,
                                                     history: netNormHistory(), style: style, colored: colored, border: border)
        case "temp":     return MenuBarGlyph.temperature(celsius: s?.cpuTemp, style: style, colored: colored)
        case "disk":     return MenuBarGlyph.disk(fraction: s?.diskUsedFraction ?? 0, style: style, colored: colored, border: border)
        case "gpu":      return MenuBarGlyph.gpu(fraction: s?.gpuUsage ?? 0,
                                                 history: model.gpuHistory, style: style, colored: colored, border: border)
        case "combined": return MenuBarGlyph.combined(colored: colored)
        default:         return nil
        }
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
        let sameOpen = popover.isShown && popover.contentViewController?.identifier?.rawValue == id
        if popover.isShown { popover.performClose(nil) }
        if sameOpen { return }                       // 再次点同一项 → 关闭
        showPopover(id: id, from: sender)
    }

    private func showPopover(id: String, from button: NSStatusBarButton) {
        let host = NSHostingController(rootView: AnyView(panel(for: id)))
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
        if !popover.isShown { model.metricsDetailConsumerVisible = false }
    }

    @ViewBuilder private func panel(for id: String) -> some View {
        switch id {
        case "cpu":     MenuMetricPanel(model: model, metric: .cpu)
        case "memory":  MenuMetricPanel(model: model, metric: .memory)
        case "network": MenuMetricPanel(model: model, metric: .network)
        case "temp":    MenuMetricPanel(model: model, metric: .temperature)
        case "disk":    MenuMetricPanel(model: model, metric: .disk)
        case "gpu":     MenuMetricPanel(model: model, metric: .gpu)
        // 合并总览保持系统总览面板。
        default:        MenuBarView(model: model)
        }
    }
}
