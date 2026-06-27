import SwiftUI
import AppKit

/// 毛玻璃背景（高级感的关键）：把窗体后的内容做真实模糊。
public struct VisualEffectBackground: NSViewRepresentable {
    private let material: NSVisualEffectView.Material
    private let blending: NSVisualEffectView.BlendingMode

    public init(material: NSVisualEffectView.Material = .underWindowBackground,
                blending: NSVisualEffectView.BlendingMode = .behindWindow) {
        self.material = material
        self.blending = blending
    }

    public func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blending
        view.state = .active
        return view
    }

    public func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blending
    }
}
