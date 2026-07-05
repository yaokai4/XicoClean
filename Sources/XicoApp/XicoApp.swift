import SwiftUI
import AppKit
import Features
import Infrastructure
import DesignSystem

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var menuBar: MenuBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        // 截图/调试用：--lang=ja|en|zh-Hans 强制界面语言（离屏验证多语言）
        if let arg = CommandLine.arguments.first(where: { $0.hasPrefix("--lang=") }),
           let lang = XLang(rawValue: String(arg.dropFirst("--lang=".count))) {
            XLocale.current = lang
        }
        if CommandLine.arguments.contains("--shots") {
            renderShots()
            NSApp.terminate(nil)
            return
        }
        if CommandLine.arguments.contains("--icon") {
            renderIcon()
            NSApp.terminate(nil)
            return
        }
        if CommandLine.arguments.contains("--menubar") {
            renderMenuBar()
            NSApp.terminate(nil)
            return
        }
        if CommandLine.arguments.contains("--glyphs") {
            renderGlyphs()
            NSApp.terminate(nil)
            return
        }
        if CommandLine.arguments.contains("--layout") {
            renderLayout()
            NSApp.terminate(nil)
            return
        }
        if CommandLine.arguments.contains("--selftest") {
            Task { let ok = await runSelfTest(); exit(ok ? 0 : 1) }
            return
        }
        if CommandLine.arguments.contains("--probe-sensors") {
            probeSensors()
            NSApp.terminate(nil)
            return
        }
        if CommandLine.arguments.contains("--liveshots") {
            renderLiveShots()
            NSApp.terminate(nil)
            return
        }
        // 正常启动：用 AppKit 接管菜单栏（瞬态弹窗，自动消失 + 可在设置里编辑）
        menuBar = MenuBarController(model: .shared)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            for window in sender.windows where window.canBecomeMain {
                window.makeKeyAndOrderFront(nil)
            }
        }
        return true
    }
}

@main
struct XicoMain: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel.shared

    var body: some Scene {
        WindowGroup {
            RootView(model: model)
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            // 单窗口应用：禁掉 ⌘N 开出共享同一 AppModel 的第二个主窗口
            CommandGroup(replacing: .newItem) {}
            // ⌘, 路由到应用内设置页（无独立 Settings 场景）
            CommandGroup(replacing: .appSettings) {
                Button(xLoc("设置…")) {
                    model.selection = .settings
                    NSApp.activate(ignoringOtherApps: true)
                }
                .keyboardShortcut(",", modifiers: .command)
            }
        }
        // 菜单栏由 AppKit 的 MenuBarController 接管（见 AppDelegate）
    }
}
