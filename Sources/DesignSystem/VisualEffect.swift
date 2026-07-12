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

// MARK: - 表面材质令牌（真实材质分层：材质只属于导航层，内容层用不透明 surface）

/// 三档表面材质。铁律：`.thin`/`.sidebar` 只用于导航层（侧栏/浮层/操作条/菜单栏面板），
/// 内容卡片一律 `.opaque`；禁止材质叠材质。Reduce Transparency 时系统自动退化为磨砂/实底。
public enum XSurface {
    /// 不透明内容表面（卡片、列表）——高程感知请配 `XColor.surface(at:)`。
    case opaque
    /// 浮层薄材质（操作条、收集篮、toast、菜单栏面板）。
    case thin
    /// 侧栏 vibrancy（behindWindow：透出桌面壁纸，与 Finder/系统设置同质感）。
    case sidebar
}

public extension View {
    /// 按材质令牌铺表面底。`.sidebar` 会 `ignoresSafeArea`（侧栏通顶）。
    @ViewBuilder func xSurface(_ surface: XSurface) -> some View {
        switch surface {
        case .opaque:
            background(XColor.surface)
        case .thin:
            background(.ultraThinMaterial)
        case .sidebar:
            background(VisualEffectBackground(material: .sidebar, blending: .behindWindow).ignoresSafeArea())
        }
    }

    /// 浮层玻璃：macOS 26 走系统 Liquid Glass，低版本退化为薄材质。
    /// 仅用于悬浮导航元素（收集篮、钉住面板、浮动工具条）——内容层禁止上玻璃。
    /// 低版本描边升级为**方向性内高光**（上亮下暗，与 XCard 同语言）——真实玻璃的边缘
    /// 是受光的，单色描边是「贴纸」；macOS 15 用户也拿到「受光边缘」（docs/16）。
    @ViewBuilder func xFloatingGlass(cornerRadius: CGFloat = XRadius.card) -> some View {
        if #available(macOS 26.0, *) {
            self.glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
        } else {
            self
                .background(.ultraThinMaterial,
                            in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(
                            LinearGradient(colors: [.white.opacity(0.16), .white.opacity(0.03)],
                                           startPoint: .top, endPoint: .bottom),
                            lineWidth: 1)
                )
        }
    }

    /// 胶囊形浮层玻璃（收集篮空态等）。
    @ViewBuilder func xFloatingGlassCapsule() -> some View {
        if #available(macOS 26.0, *) {
            self.glassEffect(.regular, in: .capsule)
        } else {
            self
                .background(.ultraThinMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(
                    LinearGradient(colors: [.white.opacity(0.16), .white.opacity(0.03)],
                                   startPoint: .top, endPoint: .bottom),
                    lineWidth: 1))
        }
    }

    /// 数据密集工具类的正确滚动边缘：macOS 26 用 .hard 分割线式硬边（内容不被渐进模糊吃掉），
    /// 低版本 no-op。
    @ViewBuilder func xHardScrollEdges() -> some View {
        if #available(macOS 26.0, *) {
            self.scrollEdgeEffectStyle(.hard, for: .all)
        } else {
            self
        }
    }
}
