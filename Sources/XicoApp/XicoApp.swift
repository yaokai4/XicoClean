import SwiftUI
import AppKit
import Darwin
import UserNotifications
import Features
import Domain
import Infrastructure
import DesignSystem

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var menuBar: MenuBarController?
    /// 全应用唯一的 AppModel 实例（构造一次，显式注入 AppKit 侧 `MenuBarController` 与 SwiftUI 侧
    /// `RootView`——见 `XicoMain`）。对抗复核 P3：此前 AppKit / SwiftUI 两层各自伸手取 `AppModel.shared`，
    /// 所有权与初始化次序都藏在全局单例里；现由 AppDelegate 持有一个具名引用作为单一注入点，
    /// 所有权与注入路径显式可见。`AppModel.shared` 作为便利单例保留（本属性即指向它），跨层仍是同一实例。
    let model = AppModel.shared
    /// 单实例独占锁，持有到进程退出（flock 随其 fd 释放）。见 applicationDidFinishLaunching 的守卫。
    private var singletonLock: SingletonLock?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        // 截图/调试用：--lang=ja|en|zh-Hans 强制界面语言（离屏验证多语言）
        if let arg = CommandLine.arguments.first(where: { $0.hasPrefix("--lang=") }),
           let lang = XLang(rawValue: String(arg.dropFirst("--lang=".count))) {
            XLocale.current = lang
        }
        // --icon 是打包期「生成 App 自身图标」的构建工具（make_app.sh 调用），发布构建亦可用——
        // 必须放在 #if DEBUG 之外，否则 release 下 renderIcon 被编译掉、此分支落入 GUI 启动令打包卡死。
        if CommandLine.arguments.contains("--icon") {
            renderIcon()
            NSApp.terminate(nil)
            return
        }
        #if DEBUG
        // 以下离屏截图工具（--shots/--menubar/--glyphs/--layout）仅供 QA/调试，随
        // ShotRenderer/IconRender/LayoutRender 一起编译进 DEBUG，绝不进发布包——
        // 发布构建里这些 render 符号不存在，故调度分支必须同样 #if DEBUG 门控。
        if CommandLine.arguments.contains("--shots") {
            renderShots()
            NSApp.terminate(nil)
            return
        }
        if CommandLine.arguments.contains("--webshots") {
            renderWebShots()
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
        #endif
        // --selftest 保留在发布构建：CI 用它对发布二进制做冒烟自检。
        if CommandLine.arguments.contains("--selftest") {
            Task { let ok = await runSelfTest(); exit(ok ? 0 : 1) }
            return
        }
        #if DEBUG
        // 以下 QA/开发者 CLI 入口（--probe-sensors/--deepscan/--diskbench）仅供调试，
        // 门控进 DEBUG，绝不随发布二进制分发（对齐上方 render 工具的 #if DEBUG 处置）。
        if CommandLine.arguments.contains("--probe-sensors") {
            probeSensors()
            NSApp.terminate(nil)
            return
        }
        if CommandLine.arguments.contains("--deepscan") {
            // 深度全盘扫描自检：真实走查家目录，打印命中组与耗时。
            let svc = DeepScanner(fs: LocalFileSystemService(), safety: DefaultSafetyEngine())
            let start = Date()
            Task {
                do {
                    let lastMsg = AtomicMessage()
                    let result = try await svc.scan { p in lastMsg.set(p.message) }
                    let secs = Date().timeIntervalSince(start)
                    print(String(format: "deepscan done in %.1fs · %@", secs, lastMsg.get()))
                    for g in result.groups {
                        print("== \(g.title): \(g.items.count) 项 · \(g.items.reduce(Int64(0)) { $0 + $1.size }.formattedBytes)")
                        for i in g.items.prefix(5) { print("   \(i.displayName) · \(i.size.formattedBytes) · selected=\(i.isSelected)") }
                    }
                    exit(0)
                } catch {
                    // 抛错不能被吞掉后卡死 RunLoop——如实报错并以非零码退出（对齐 --diskbench/--selftest）
                    FileHandle.standardError.write("deepscan failed: \(error.localizedDescription)\n".data(using: .utf8)!)
                    exit(1)
                }
            }
            RunLoop.main.run()
        }
        if CommandLine.arguments.contains("--diskbench") {
            // 磁盘测速引擎自检：完整基准（SEQ QD2 + RND4K 矩阵），打印全指标（验证 v2 引擎与清理）。
            let svc = DiskBenchmarkService()
            let r = svc.run(device: "selftest") { p in
                switch p {
                case .writing(let m): FileHandle.standardError.write("w \(Int(m)) MB/s\n".data(using: .utf8)!)
                case .reading(let m): FileHandle.standardError.write("r \(Int(m)) MB/s\n".data(using: .utf8)!)
                case .random(let stage, let iops):
                    FileHandle.standardError.write("\(stage) \(Int(iops)) IOPS\n".data(using: .utf8)!)
                default: break
                }
            }
            if let r {
                print("done seq: read=\(Int(r.readMBps)) write=\(Int(r.writeMBps)) MB/s"
                      + (r.burstWriteMBps.map { " burst=\(Int($0))" } ?? "")
                      + (r.flushSeconds.map { String(format: " flush=%.2fs", $0) } ?? ""))
                print("rnd4k QD1: read=\(Int(r.rnd4kReadIOPS ?? 0)) IOPS avg=\(Int(r.rnd4kReadAvgUS ?? 0))µs p99=\(Int(r.rnd4kReadP99US ?? 0))µs · write=\(Int(r.rnd4kWriteIOPS ?? 0)) IOPS avg=\(Int(r.rnd4kWriteAvgUS ?? 0))µs")
                print("rnd4k QD32: read=\(Int(r.rnd4kQD32ReadIOPS ?? 0)) IOPS · write=\(Int(r.rnd4kQD32WriteIOPS ?? 0)) IOPS")
            } else {
                print("failed")
            }
            exit(r == nil ? 1 : 0)
        }
        #endif
        #if DEBUG
        // 离屏实时快照工具仅供 QA/调试，随 LiveShotRenderer 一起编译进 DEBUG，绝不进发布包。
        if CommandLine.arguments.contains("--liveshots") {
            renderLiveShots()
            NSApp.terminate(nil)
            return
        }
        #endif
        // 单实例守卫：更新替换 App 或多路径安装时旧实例可能仍在运行——两个进程会各画一套
        // 菜单栏状态项（用户报告的「莫名冒出两个一样的监控」）。
        // 仅靠「枚举同 bundle 的其他实例」在两进程近乎同时启动时会竞态：两边都看见对方便一起退出
        // （剩 0 个）、或都没看见对方便并存（剩 2 个）。因此以 Application Support 里的一把独占
        // flock 作权威裁决——内核原子，恰好一个进程能拿到锁；拿不到的用「更早启动 / 更小 PID」的
        // 确定性次序挑出既有实例，激活并交棒后退出自己，绝不并存。
        if let bid = Bundle.main.bundleIdentifier, !bid.isEmpty {
            let lock = SingletonLock(bundleID: bid)
            if lock.acquire() {
                singletonLock = lock   // 持有到进程退出
            } else {
                let incumbent = NSRunningApplication.runningApplications(withBundleIdentifier: bid)
                    .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
                    .min { a, b in
                        switch (a.launchDate, b.launchDate) {
                        case let (da?, db?) where da != db: return da < db
                        default: return a.processIdentifier < b.processIdentifier
                        }
                    }
                incumbent?.activate()
                NSApp.terminate(nil)
                return
            }
        }
        // 正常启动：用 AppKit 接管菜单栏（瞬态弹窗，自动消失 + 可在设置里编辑）——注入唯一 AppModel。
        menuBar = MenuBarController(model: model)
        // 废纸篓哨兵通知的点击路由（P4）：identifier 前缀 xico.sentinel. → 打开卸载器。
        UNUserNotificationCenter.current().delegate = self
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
            let host = url.host?.lowercased()
            if host == "download" {
                handleDownloadURL(url)
            } else {
                handleActivationURL(url)
            }
        }
    }

    /// 自动化深链：`xico://download?url=<encoded>&kind=video|audio|image`——供 Shortcuts / 命令行
    /// `open "xico://download?url=…"` / 其他 App 驱动下载（「不只是桌面点点点」）。仍受授权门禁约束。
    @MainActor
    private func handleDownloadURL(_ url: URL) {
        guard model.env.license.status().state.allowsCommercialUse else {
            NSApp.activate(ignoringOtherApps: true); model.showPricing = true; return
        }
        let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
        guard let raw = comps?.queryItems?.first(where: { $0.name == "url" })?.value,
              let target = raw.removingPercentEncoding, target.contains("://") else { return }
        let kindStr = comps?.queryItems?.first(where: { $0.name == "kind" })?.value ?? "video"
        let kind = DownloadKind(rawValue: kindStr) ?? .video
        NSApp.activate(ignoringOtherApps: true)
        for w in NSApp.windows where w.canBecomeMain { w.makeKeyAndOrderFront(nil) }
        model.selection = .downloader
        model.env.downloadManager.add(urlString: target, kind: kind)
    }

    /// 上次深链激活时刻——用于对深链激活做速率限制，抵御恶意页面反复唤起。
    private var lastDeepLinkActivation = Date.distantPast

    @MainActor
    private func handleActivationURL(_ url: URL) {
        let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let isActivate = (url.host == "activate") || comps?.path.contains("activate") == true
        guard isActivate,
              let key = comps?.queryItems?.first(where: { $0.name == "key" })?.value,
              !key.isEmpty else { return }
        // 速率限制：两次深链激活至少间隔 3 秒，防止恶意网页用连续 xico://activate 轰炸弹窗。
        let now = Date()
        guard now.timeIntervalSince(lastDeepLinkActivation) > 3 else { return }
        lastDeepLinkActivation = now
        // 绝不静默激活来路不明的深链激活码（攻击者可构造 xico://activate?key=…）：
        // 先激活窗口并弹窗展示激活码，要求用户显式确认后才真正激活。
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = xLoc("确认激活 Xico？")
        alert.informativeText = xLocF("检测到来自网页的激活请求，激活码：%@\n仅在你本人刚从官网购买后再继续。", key)
        alert.addButton(withTitle: xLoc("激活"))
        alert.addButton(withTitle: xLoc("取消"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        model.selection = .settings
        Task { _ = await model.activateLicense(key: key) }
    }
}

// MARK: 通知点击路由（P4 废纸篓哨兵：点通知直达卸载器清残留）

extension AppDelegate: UNUserNotificationCenterDelegate {
    // 通知代理回调不保证主线程——nonisolated 接收，内部跳主 actor 再碰 UI/模型。
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let identifier = response.notification.request.identifier
        if identifier.hasPrefix("xico.sentinel.") {
            Task { @MainActor in
                self.model.selection = .uninstaller
                NSApp.setActivationPolicy(.regular)
                NSApp.activate(ignoringOtherApps: true)
                for window in NSApp.windows where window.canBecomeMain {
                    window.makeKeyAndOrderFront(nil)
                }
            }
        }
        completionHandler()
    }
}

@main
struct XicoMain: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    /// 与 `AppDelegate.model` 指向的**同一** AppModel（便利单例 `AppModel.shared`）——SwiftUI 侧由此
    /// `@StateObject` 持有其生命周期并注入 `RootView`，AppKit 侧经 `AppDelegate` 注入 `MenuBarController`，
    /// 两层共享一份状态。见 AppDelegate.model 的所有权说明。
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

/// --deepscan 自检用的跨线程消息盒（进度回调在后台线程触发）。
final class AtomicMessage: @unchecked Sendable {
    private let lock = NSLock()
    private var v = ""
    func set(_ s: String) { lock.lock(); v = s; lock.unlock() }
    func get() -> String { lock.lock(); defer { lock.unlock() }; return v }
}

/// 单实例独占锁：在 Application Support 建一个锁文件并 `flock(LOCK_EX|LOCK_NB)`。
/// 拿到锁=本进程是唯一实例；拿不到=已有实例持锁。fd 一直持有到进程退出，锁随 fd 关闭/进程结束自动释放。
final class SingletonLock: @unchecked Sendable {
    private var fd: Int32 = -1
    private let path: String

    init(bundleID: String) {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let dir = base.appendingPathComponent("Xico", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        path = dir.appendingPathComponent("\(bundleID).lock").path
    }

    /// 尝试独占加锁。true=本进程独占（锁文件无法创建时保守放行，绝不误杀正常启动）；false=已有实例持锁。
    func acquire() -> Bool {
        fd = open(path, O_CREAT | O_RDWR, 0o644)
        guard fd >= 0 else { return true }              // 建不了锁文件就别拦启动
        if flock(fd, LOCK_EX | LOCK_NB) == 0 { return true }
        close(fd); fd = -1
        return false
    }
}
