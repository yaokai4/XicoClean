import SwiftUI
import Domain
import Infrastructure
import DesignSystem

// MARK: - ⌘K 命令面板（docs/16 P2 · Raycast 式）
//
// 「专业工具 vs 消费级向导流」的段位分水岭：模糊搜索模块与动作并直接执行。
// 键盘全程可达：⌘K 唤出 / ↑↓ 选择 / ⏎ 执行 / Esc 关闭；玻璃浮层走 xFloatingGlass
//（导航层，符合「内容层禁上玻璃」铁律）。

/// 一条可执行命令。
private struct PaletteCommand: Identifiable {
    let id: String
    let title: String
    let subtitle: String
    let icon: String
    let run: () -> Void
}

/// 宿主：持有 ⌘K 快捷键与浮层展示（挂在 DetailView overlay 上）。
struct CommandPaletteHost: View {
    @ObservedObject var model: AppModel

    var body: some View {
        ZStack {
            // 隐形快捷键载体：⌘K 唤出/收起。开合状态上提到 AppModel（终审 P1）：
            // RootView 的 ⌘⏎/⌘Z 隐藏按钮据此在面板打开时解除挂载，不吞面板输入框的按键。
            Button("") { withAnimation(XMotion.snappy) { model.commandPaletteOpen.toggle() } }
                .keyboardShortcut("k", modifiers: .command)
                .hidden()
            if model.commandPaletteOpen {
                CommandPaletteView(model: model) {
                    withAnimation(XMotion.crossfade) { model.commandPaletteOpen = false }
                }
                .transition(.opacity.combined(with: .scale(scale: 0.98)))
            }
        }
    }
}

private struct CommandPaletteView: View {
    @ObservedObject var model: AppModel
    let dismiss: () -> Void
    @State private var query = ""
    @State private var highlighted = 0
    @FocusState private var searchFocused: Bool

    /// 全部命令：可见模块导航 + 高频动作 + 主题切换。
    private var allCommands: [PaletteCommand] {
        var out: [PaletteCommand] = []
        // 高频动作在前。
        out.append(PaletteCommand(id: "act.scan", title: xLoc("开始智能扫描"),
                                  subtitle: xLoc("六类并行 · ⌘R"), icon: "sparkles") {
            model.selection = .smartScan
            model.smartScanHub.start()
        })
        out.append(PaletteCommand(id: "act.lens", title: xLoc("打开空间透镜"),
                                  subtitle: xLoc("放射环形图 · 逐层钻取"), icon: "circle.hexagongrid.fill") {
            model.selection = .spaceLens
        })
        out.append(PaletteCommand(id: "act.settings", title: xLoc("打开设置"),
                                  subtitle: xLoc("通用 · 授权 · 规则库"), icon: "gearshape.fill") {
            model.selection = .settings
        })
        // 侧栏可见模块。
        for (_, modules) in ModuleCatalog.grouped() {
            for meta in modules {
                out.append(PaletteCommand(id: "nav.\(meta.id.rawValue)", title: xLoc(meta.title),
                                          subtitle: xLoc(meta.subtitle), icon: meta.systemImage) {
                    model.selection = meta.id
                })
            }
        }
        // 主题切换。
        for theme in XTheme.all {
            out.append(PaletteCommand(id: "theme.\(theme.id)",
                                      title: xLocF("切换主题：%@", xLoc(theme.name)),
                                      subtitle: xLoc("全局配色即时生效"), icon: "paintpalette.fill") {
                model.themeID = theme.id
            })
        }
        return out
    }

    private var matches: [PaletteCommand] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return allCommands }
        return allCommands.filter {
            $0.title.localizedCaseInsensitiveContains(q)
                || $0.subtitle.localizedCaseInsensitiveContains(q)
        }
    }

    var body: some View {
        ZStack(alignment: .top) {
            // 点背景关闭（模糊压暗，聚焦面板）。
            Color.black.opacity(0.25)
                .ignoresSafeArea()
                .onTapGesture { dismiss() }
            palette
                .padding(.top, 90)
        }
        .onExitCommand { dismiss() }
    }

    private var palette: some View {
        let items = matches
        return VStack(spacing: 0) {
            HStack(spacing: XSpacing.s) {
                Image(systemName: "magnifyingglass")
                    .font(XFont.bodyEmphasis).foregroundStyle(XColor.textTertiary)
                TextField(xLoc("搜索模块、动作或主题…"), text: $query)
                    .textFieldStyle(.plain)
                    .font(XFont.headline)
                    .focused($searchFocused)
                    .onSubmit { runHighlighted(items) }
                Text("esc").font(XFont.nano).foregroundStyle(XColor.textTertiary)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(XColor.surfaceAlt.opacity(0.7), in: RoundedRectangle(cornerRadius: 5))
            }
            .padding(.horizontal, XSpacing.l).padding(.vertical, XSpacing.m)
            Divider().opacity(0.5)
            if items.isEmpty {
                Text(xLoc("没有匹配的命令"))
                    .font(XFont.body).foregroundStyle(XColor.textTertiary)
                    .frame(maxWidth: .infinity).padding(XSpacing.xl)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(spacing: 2) {
                            ForEach(Array(items.enumerated()), id: \.element.id) { i, cmd in
                                row(cmd, active: i == highlighted)
                                    .id(cmd.id)
                                    .onTapGesture { cmd.run(); dismiss() }
                                    .onHover { if $0 { highlighted = i } }
                            }
                        }
                        .padding(XSpacing.s)
                    }
                    .frame(maxHeight: 340)
                    .onChange(of: highlighted) {
                        guard highlighted < items.count else { return }
                        proxy.scrollTo(items[highlighted].id)
                    }
                }
            }
        }
        .frame(width: 560)
        .xFloatingGlass(cornerRadius: XRadius.card)
        .xElevation(.overlay)
        .onAppear { searchFocused = true; highlighted = 0 }
        .onChange(of: query) { highlighted = 0 }
        .onKeyPress(.downArrow) {
            highlighted = min(highlighted + 1, max(matches.count - 1, 0)); return .handled
        }
        .onKeyPress(.upArrow) {
            highlighted = max(highlighted - 1, 0); return .handled
        }
        .accessibilityLabel(xLoc("命令面板"))
    }

    private func runHighlighted(_ items: [PaletteCommand]) {
        guard !items.isEmpty else { return }
        items[min(highlighted, items.count - 1)].run()
        dismiss()
    }

    private func row(_ cmd: PaletteCommand, active: Bool) -> some View {
        HStack(spacing: XSpacing.m) {
            XIconTile(systemImage: cmd.icon,
                      colors: active ? XColor.brandGradientColors : [XColor.textSecondary],
                      size: 26)
            VStack(alignment: .leading, spacing: 1) {
                Text(cmd.title).font(XFont.bodyEmphasis)
                    .foregroundStyle(XColor.textPrimary)
                Text(cmd.subtitle).font(XFont.caption)
                    .foregroundStyle(XColor.textTertiary).lineLimit(1)
            }
            Spacer()
            if active {
                Image(systemName: "return")
                    .font(XFont.caption).foregroundStyle(XColor.textTertiary)
            }
        }
        .padding(.horizontal, XSpacing.m).padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: XRadius.control, style: .continuous)
            .fill(active ? XColor.brand.opacity(XAlpha.tint) : .clear))
        .contentShape(Rectangle())
    }
}
