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

        model.startMetricsTimer()            // 即使主窗口未开，菜单栏也持续刷新
        rebuild()

        // 指标变化 → 刷新图标
        model.$liveSnapshot
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateImages() }
            .store(in: &cancellables)

        // 设置里的开关变化 → 重建菜单栏项（实时增删）
        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .debounce(for: .milliseconds(150), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.rebuild() }
            .store(in: &cancellables)
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
    /// 每项独立的「图形加框」开关（`xico.mb.<id>.border`）。只圈动态图形，数值永远在框外。
    /// 默认按图形类型校准：图表区图形（CPU 直方图 / 网络折线）加框读感最佳；环/条裸露更干净（对齐 Sensei）。
    private func border(for id: String) -> Bool {
        let key = "xico.mb.\(id).border"
        if UserDefaults.standard.object(forKey: key) != nil {
            return UserDefaults.standard.bool(forKey: key)
        }
        switch id {
        case "cpu", "network": return true    // 直方图 / 折线：图表区，加框
        default:               return false   // memory·gpu（环）· disk（条）：裸露
        }
    }

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

    /// 网络折线归一化（下行 + 上行的最大值）
    private func netNormHistory() -> [Double] {
        let maxV = max((model.netDownHistory + model.netUpHistory).max() ?? 1, 1)
        return model.netDownHistory.map { $0 / maxV }
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
    }

    @ViewBuilder private func panel(for id: String) -> some View {
        switch id {
        case "cpu", "temp", "gpu": MenuMetricPanel(model: model, metric: .cpu)
        case "memory":  MenuMetricPanel(model: model, metric: .memory)
        case "network": MenuMetricPanel(model: model, metric: .network)
        default:        MenuBarView(model: model)
        }
    }
}
