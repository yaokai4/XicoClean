import SwiftUI
import AppKit
import Domain
import Infrastructure
import DesignSystem
import Features

/// 离屏渲染各页面为 PNG（用于在无法点击驱动时验证 UI）。用法：Xico --shots
@MainActor
func renderShots() {
    let env = XicoEnvironment.live()
    let dir = URL(fileURLWithPath: "/tmp/xico-shots")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

    let shots: [(String, AnyView)] = [
        ("01-systemjunk-idle", AnyView(ModuleScanView(env: env, moduleID: .systemJunk, intent: .trash))),
        ("02-duplicates-idle", AnyView(DuplicatesView(env: env))),
        ("03-uninstaller",     AnyView(UninstallerView(env: env))),
        ("04-optimization",    AnyView(OptimizationView(env: env))),
        ("05-maintenance",     AnyView(MaintenanceView(env: env))),
        ("06-privacy-idle",    AnyView(ModuleScanView(env: env, moduleID: .privacy, intent: .trash)))
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
