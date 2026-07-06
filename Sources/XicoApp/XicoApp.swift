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
        if CommandLine.arguments.contains("--diskbench") {
            // 磁盘测速引擎自检：真实写读一轮，打印结果（验证 F_NOCACHE 路径与清理）。
            let svc = DiskBenchmarkService()
            let r = svc.run(device: "selftest") { p in
                if case .writing(let m) = p { FileHandle.standardError.write("w \(Int(m)) MB/s\n".data(using: .utf8)!) }
                if case .reading(let m) = p { FileHandle.standardError.write("r \(Int(m)) MB/s\n".data(using: .utf8)!) }
            }
            print(r.map { "done read=\(Int($0.readMBps)) write=\(Int($0.writeMBps)) MB/s" } ?? "failed")
            exit(r == nil ? 1 : 0)
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

    /// 处理 `xico://activate?key=…` 深链——官网购买成功页「打开 App 激活」按钮触发，
    /// 免去用户手动复制粘贴激活码。需要 Info.plist 注册 CFBundleURLTypes（见 make_app.sh）。
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.scheme?.lowercased() == "xico" {
            handleActivationURL(url)
        }
    }

    private func handleActivationURL(_ url: URL) {
        let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let isActivate = (url.host == "activate") || comps?.path.contains("activate") == true
        guard isActivate,
              let key = comps?.queryItems?.first(where: { $0.name == "key" })?.value,
              !key.isEmpty else { return }
        Task { @MainActor in
            let model = AppModel.shared
            model.selection = .settings
            NSApp.activate(ignoringOtherApps: true)
            _ = await model.activateLicense(key: key)
        }
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
