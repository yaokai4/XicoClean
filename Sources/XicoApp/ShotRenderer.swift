import SwiftUI
import AppKit
import Domain
import Infrastructure
import DesignSystem
import Features

// 约 600 行离屏渲染脚手架（QA/调试专用）绝不随发布包出货，整体 #if DEBUG 门控，
// 对齐 LiveShotRenderer；调度入口（XicoApp.swift 的 --shots 分支）需同样 #if DEBUG 门控。
#if DEBUG

/// 离屏渲染各页面为 PNG（用于在无法点击驱动时验证 UI）。用法：Xico --shots
@MainActor
func renderShots() {
    let env = XicoEnvironment.live()
    let model = AppModel(env: env)
    let dir = URL(fileURLWithPath: "/tmp/xico-shots")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

    let shots: [(String, AnyView)] = [
        ("01-systemjunk-idle", AnyView(ModuleScanView(model: model, moduleID: .systemJunk, intent: .trash))),
        ("02-duplicates-idle", AnyView(DuplicatesView(env: env))),
        ("03-uninstaller",     AnyView(UninstallerView(env: env))),
        ("04-optimization",    AnyView(OptimizationView(env: env))),
        ("05-maintenance",     AnyView(MaintenanceView(env: env))),
        ("06-privacy-idle",    AnyView(ModuleScanView(model: model, moduleID: .privacy, intent: .trash))),
        ("07-spacelens",       AnyView(SunburstView(node: synthDiskTree()) { _ in }))
    ]

    for scheme in [ColorScheme.dark, .light] {
        for (name, view) in shots {
            let wrapped = ZStack {
                AppBackground()
                view
            }
            .frame(width: 1080, height: 720)
            .environment(\.colorScheme, scheme)

            let renderer = ImageRenderer(content: wrapped)
            renderer.scale = 2
            guard let img = renderer.nsImage,
                  let tiff = img.tiffRepresentation,
                  let rep = NSBitmapImageRep(data: tiff),
                  let png = rep.representation(using: .png, properties: [:]) else { continue }
            let suffix = scheme == .dark ? "dark" : "light"
            try? png.write(to: dir.appendingPathComponent("\(name)-\(suffix).png"))
        }
    }
    FileHandle.standardError.write("rendered shots to \(dir.path)\n".data(using: .utf8)!)
}

/// 合成一棵磁盘树，用于离屏验证空间透镜环形图（无需真实扫描）。
@MainActor
private func synthDiskTree() -> DiskNode {
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
            d("Caches", [ f("com.apple.dt.Xcode", 4_200), f("Google", 1_900), f("Chromium", 1_300), f("Homebrew", 900) ]),
            d("Application Support", [ f("MobileSync", 12_000), f("Code", 2_100), f("Slack", 1_400), f("discord", 1_100) ]),
            f("Containers", 5_600),
        ]),
        d("Documents", [ d("Projects", [ f("XicoApp", 3_200), f("archive.zip", 2_600), f("design.sketch", 1_400) ]), f("report.pdf", 420), f("notes", 260) ]),
        d("Downloads", [ f("Xcode.xip", 8_900), f("ubuntu.iso", 3_600), f("movie.mp4", 2_400), f("dataset.csv", 800) ]),
        d("Pictures", [ f("Photos Library", 18_500), f("Screenshots", 2_200), f("wallpapers", 900) ]),
        d("Movies", [ f("recording.mov", 6_800), f("clip.mp4", 3_100) ]),
        d("Music", [ f("iTunes", 4_300), f("samples", 1_200) ]),
        d(".Trash", [ f("old-build.app", 3_400), f("junk", 1_100) ]),
        d("Desktop", [ f("shot1.png", 260), f("shot2.png", 240), f("todo.md", 60) ]),
    ])
}

#endif
