import SwiftUI
import AppKit
import Features
import Infrastructure

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var menuBar: MenuBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
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
        if CommandLine.arguments.contains("--selftest") {
            Task { await runSelfTest(); NSApp.terminate(nil) }
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
                Button("设置…") {
                    model.selection = .settings
                    NSApp.activate(ignoringOtherApps: true)
                }
                .keyboardShortcut(",", modifiers: .command)
            }
        }
        // 菜单栏由 AppKit 的 MenuBarController 接管（见 AppDelegate）
    }
}
