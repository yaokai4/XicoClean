import SwiftUI
import AppKit
import Domain
import Infrastructure
import DesignSystem
import Features

// 官网营销截图渲染器（QA/发布工具，#if DEBUG 门控，绝不进发布包）。
// 与 --shots 的区别：只出**白天模式**、中英双语、网站尺寸，且覆盖新功能结果态
// （智能扫描六宫格中枢 / 磁盘测速 v2 专业矩阵 + 视频适配表 / 诚实空间账本）。
// 用法：Xico --webshots  → 输出 /tmp/xico-webshots/<name>-<zh|en>.png（2x）
#if DEBUG

@MainActor
func renderWebShots() {
    let dir = URL(fileURLWithPath: "/tmp/xico-webshots")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

    // 中国区用中文截图，其他区用英文（官网按 locale 选择）。
    // 每张单独 AppModel：demoHub 会把共享 hub 置 .active，会污染同 model 的 dashboard idle 态。
    for lang in [XLang.zhHans, .en] {
        XLocale.current = lang
        let suffix = lang == .zhHans ? "zh" : "en"

        // 每张：(名字, 构造闭包(独立 model), 宽, 高)。
        let shots: [(String, () -> AnyView, CGFloat, CGFloat)] = [
            // 智能扫描：idle 仪表盘（健康环英雄图，主打「六类并行」副标题）
            ("dashboard", { AnyView(SmartScanView(model: freshModel())) }, 1080, 1000),
            // 智能扫描：六宫格结果态（新中枢，拟真数据）
            ("smartscan", { AnyView(demoHub()) }, 1180, 720),
            // 系统垃圾 idle 英雄
            ("systemjunk", { AnyView(ModuleScanView(model: freshModel(), moduleID: .systemJunk, intent: .trash)) }, 1080, 720),
            // 重复文件 idle 英雄
            ("duplicates", { AnyView(DuplicatesView(model: freshModel())) }, 1080, 720),
            // 优化 idle 英雄
            ("optimization", { AnyView(OptimizationView(env: XicoEnvironment.live(), feed: freshModel().liveMetricsFeed)) }, 1080, 720),
            // 空间透镜（旭日环）
            ("spacelens", { AnyView(SunburstView(node: synthWebDiskTree()) { _ in }) }, 1000, 1000),
            // 磁盘测速 v2：拟真完成结果（专业矩阵 + 视频适配表 + 反超 Blackmagic）
            ("diskbench", { AnyView(DiskBenchmarkView(demoDevice: "Apple SSD · 1 TB")) }, 1100, 1140),
            // 状态栏设置页（新独立页，海报态非滚动）
            ("menubar", { AnyView(MenuBarSettingsView(model: freshModel(), poster: true)) }, 1000, 900),
        ]
        for (name, make, w, h) in shots {
            renderOne(make(), name: "\(name)-\(suffix)", width: w, height: h, dir: dir)
        }
    }
    FileHandle.standardError.write("rendered webshots to \(dir.path)\n".data(using: .utf8)!)
}

@MainActor private func freshModel() -> AppModel { AppModel(env: XicoEnvironment.live()) }

@MainActor
private func demoHub() -> some View {
    let hub = freshModel().smartScanHub
    hub.loadDemoResults()
    return SmartScanHubActiveView(hub: hub, poster: true)
}

@MainActor
private func renderOne(_ view: AnyView, name: String, width: CGFloat, height: CGFloat, dir: URL) {
    let wrapped = ZStack {
        AppBackground()
        view
    }
    .frame(width: width, height: height)
    .environment(\.colorScheme, .light)   // 用户要求：官网截图全部白天模式

    let renderer = ImageRenderer(content: wrapped)
    renderer.scale = 2
    guard let img = renderer.nsImage,
          let tiff = img.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:]) else { return }
    try? png.write(to: dir.appendingPathComponent("\(name).png"))
}

/// 合成磁盘树（空间透镜环形图截图用），比 --shots 版更饱满。
@MainActor
private func synthWebDiskTree() -> DiskNode {
    func f(_ name: String, _ mb: Double) -> DiskNode {
        DiskNode(url: URL(fileURLWithPath: "/x/\(name)"), name: name, isDirectory: false, size: Int64(mb * 1_048_576))
    }
    func d(_ name: String, _ children: [DiskNode]) -> DiskNode {
        let total = children.reduce(Int64(0)) { $0 + $1.size }
        return DiskNode(url: URL(fileURLWithPath: "/x/\(name)"), name: name, isDirectory: true, size: total, children: children)
    }
    return d("yaokai", [
        d("Library", [
            d("Developer", [ f("CoreSimulator", 22_000), f("Xcode", 9_800), f("DerivedData", 6_400) ]),
            d("Caches", [ f("com.apple.dt.Xcode", 4_200), f("Google", 1_900), f("Chromium", 1_300) ]),
            d("Application Support", [ f("MobileSync", 12_000), f("Code", 2_100), f("Slack", 1_400) ]),
            f("Containers", 5_600),
        ]),
        d("Documents", [ d("Projects", [ f("XicoApp", 3_200), f("archive.zip", 2_600) ]), f("report.pdf", 420) ]),
        d("Downloads", [ f("Xcode.xip", 8_900), f("ubuntu.iso", 3_600), f("movie.mp4", 2_400) ]),
        d("Pictures", [ f("Photos Library", 18_500), f("Screenshots", 2_200) ]),
        d("Movies", [ f("recording.mov", 6_800), f("clip.mp4", 3_100) ]),
        d("Music", [ f("iTunes", 4_300), f("samples", 1_200) ]),
        d("Desktop", [ f("shot1.png", 260), f("todo.md", 60) ]),
    ])
}

#endif
