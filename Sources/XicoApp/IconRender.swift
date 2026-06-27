import SwiftUI
import AppKit
import DesignSystem
import Features

/// 渲染 1024×1024 App 图标主图到 /tmp/xico-icon/icon-master.png。用法：Xico --icon
@MainActor
func renderIcon() {
    let dir = URL(fileURLWithPath: "/tmp/xico-icon")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let renderer = ImageRenderer(content: XAppIcon())
    renderer.scale = 1
    if let img = renderer.nsImage,
       let tiff = img.tiffRepresentation,
       let rep = NSBitmapImageRep(data: tiff),
       let png = rep.representation(using: .png, properties: [:]) {
        try? png.write(to: dir.appendingPathComponent("icon-master.png"))
        FileHandle.standardError.write("icon rendered to \(dir.path)/icon-master.png\n".data(using: .utf8)!)
    }
}

/// 渲染菜单栏状态面板（含真实采样数据）到 /tmp/xico-icon/menubar.png。用法：Xico --menubar
@MainActor
func renderMenuBar() {
    let dir = URL(fileURLWithPath: "/tmp/xico-icon")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let model = AppModel()
    model.refreshMetrics()
    model.refreshMetrics()
    // 离屏演示用合成历史（真实运行时为实时采样）
    model.cpuHistory = (0..<44).map { (i: Int) -> Double in
        let x = Double(i)
        return 0.35 + 0.28 * sin(x * 0.35) + 0.06 * sin(x * 1.7)
    }
    model.memHistory = (0..<44).map { (i: Int) -> Double in 0.72 + 0.07 * sin(Double(i) * 0.3) }
    model.netDownHistory = (0..<44).map { (i: Int) -> Double in max(0.0, 250_000.0 + 220_000.0 * sin(Double(i) * 0.5)) }
    model.netUpHistory = (0..<44).map { (i: Int) -> Double in max(0.0, 90_000.0 + 70_000.0 * sin(Double(i) * 0.7 + 1.0)) }

    func write(_ view: some View, _ name: String) {
        let wrapped = view.padding(8).background(XColor.surface).environment(\.colorScheme, .dark)
        let renderer = ImageRenderer(content: wrapped)
        renderer.scale = 2
        if let img = renderer.nsImage, let tiff = img.tiffRepresentation,
           let rep = NSBitmapImageRep(data: tiff), let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: dir.appendingPathComponent(name))
        }
    }
    write(MenuBarView(model: model).frame(width: 300), "menubar-dark.png")
    write(MenuMetricPanel(model: model, metric: .cpu).frame(width: 260), "mb-cpu.png")
    write(MenuMetricPanel(model: model, metric: .memory).frame(width: 260), "mb-memory.png")
    write(MenuMetricPanel(model: model, metric: .network).frame(width: 260), "mb-network.png")
    FileHandle.standardError.write("menubar panels rendered to \(dir.path)\n".data(using: .utf8)!)
}

/// 渲染菜单栏图形化字形预览（浅/深两种菜单栏背景），用于离屏验证外观。用法：Xico --glyphs
@MainActor
func renderGlyphs() {
    let dir = URL(fileURLWithPath: "/tmp/xico-icon")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

    let cpuH = (0..<16).map { (i: Int) -> Double in 0.4 + 0.3 * sin(Double(i) * 0.6) }
    let netH = (0..<16).map { (i: Int) -> Double in 0.3 + 0.4 * abs(sin(Double(i) * 0.5)) }
    func strip(dark: Bool, style: MenuBarStyle, _ name: String) {
        NSApp.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let cpu = MenuBarGlyph.cpu(fraction: 0.62, history: cpuH, style: style)
        let mem = MenuBarGlyph.memory(fraction: 0.71, history: cpuH, style: style)
        let net = MenuBarGlyph.network(down: 1_250_000, up: 386_000, history: netH, style: style)
        let comb = MenuBarGlyph.combined()
        func tinted(_ img: NSImage) -> some View {
            Image(nsImage: img).renderingMode(.template).foregroundStyle(dark ? .white : .black)
        }
        let view = HStack(spacing: 18) {
            tinted(cpu); tinted(mem); tinted(net); tinted(comb)
        }
        .padding(.horizontal, 18).padding(.vertical, 4)
        .background(dark ? Color(white: 0.15) : Color(white: 0.96))
        let renderer = ImageRenderer(content: view)
        renderer.scale = 3
        if let img = renderer.nsImage, let tiff = img.tiffRepresentation,
           let rep = NSBitmapImageRep(data: tiff), let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: dir.appendingPathComponent(name))
        }
    }
    strip(dark: true, style: .iconValue, "glyphs-dark.png")
    strip(dark: false, style: .iconValue, "glyphs-light.png")
    strip(dark: true, style: .valueOnly, "glyphs-valueonly.png")
    strip(dark: true, style: .graph, "glyphs-graph.png")
    FileHandle.standardError.write("glyphs rendered to \(dir.path)\n".data(using: .utf8)!)
}
