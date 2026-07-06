import SwiftUI
import Domain
import Infrastructure
import DesignSystem

@MainActor
final class SpaceLensModel: ObservableObject {
    @Published var root: DiskNode?
    @Published var stack: [DiskNode] = []
    @Published var isScanning = false
    @Published var scannedBytes: Int64 = 0
    @Published var scanMessage: String = ""
    @Published var scanRoot: URL = FileManager.default.homeDirectoryForCurrentUser

    private let env: XicoEnvironment
    private var task: Task<Void, Never>?

    init(env: XicoEnvironment) {
        self.env = env
        if let arg = CommandLine.arguments.first(where: { $0.hasPrefix("--scanpath=") }) {
            scanRoot = URL(fileURLWithPath: String(arg.dropFirst("--scanpath=".count)))
        }
    }

    var current: DiskNode? { stack.last ?? root }

    func scan() {
        task?.cancel()
        isScanning = true
        scannedBytes = 0
        scanMessage = ""
        root = nil
        stack = []
        let target = scanRoot
        let handler: ProgressHandler = { [weak self] p in
            Task { @MainActor in
                self?.scannedBytes = p.bytesFound
                if !p.message.isEmpty { self?.scanMessage = p.message }
            }
        }
        task = Task {
            let tree = await env.diskTreeScanner.scan(target, progress: handler)
            if Task.isCancelled { return }
            self.root = tree
            self.isScanning = false
        }
    }

    func cancel() {
        task?.cancel()
        isScanning = false
    }

    func drill(into node: DiskNode) {
        guard node.isDirectory, !node.children.isEmpty else { return }
        stack.append(node)
    }

    func pop(to index: Int) {
        if index < 0 { stack = [] } else { stack = Array(stack.prefix(index + 1)) }
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            scanRoot = url
            scan()
        }
    }
}

public struct SpaceLensView: View {
    @StateObject private var model: SpaceLensModel
    /// 可视化方式：放射环形（ring）/ 方块 treemap（blocks），持久化记住偏好。
    @AppStorage("xico.spacelens.viz") private var viz = "ring"

    public init(env: XicoEnvironment) {
        _model = StateObject(wrappedValue: SpaceLensModel(env: env))
    }

    public var body: some View {
        VStack(spacing: 0) {
            XHeaderBar(title: xLoc("空间透镜"), subtitle: headerSubtitle) { headerActions }
            if model.current != nil && !model.isScanning { breadcrumbChips }
            content
        }
        .onAppear {
            if CommandLine.arguments.contains("--autoscan"), model.root == nil, !model.isScanning {
                model.scan()
            }
        }
    }

    private var headerSubtitle: String {
        if model.isScanning { return xLoc("正在分析空间") }
        if model.current != nil { return model.scanRoot.path }
        return xLoc("放射环形图 · 逐层钻取 · 只读分析")
    }

    /// 头部动作区：与其它页面同语言（无材质条、无分割线），有结果时才出现视图切换。
    @ViewBuilder private var headerActions: some View {
        HStack(spacing: XSpacing.m) {
            if model.current != nil && !model.isScanning {
                Picker("", selection: $viz) {
                    Image(systemName: "circle.hexagongrid").tag("ring")
                    Image(systemName: "square.grid.2x2").tag("blocks")
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
                Button { model.chooseFolder() } label: {
                    Label(xLoc("选择文件夹"), systemImage: "folder")
                }
                .buttonStyle(XSecondaryButtonStyle(compact: true))
                Button { model.scan() } label: {
                    Label(xLoc("重新扫描"), systemImage: "arrow.clockwise")
                }
                .buttonStyle(XPrimaryButtonStyle(compact: true))
            }
        }
    }

    /// 面包屑胶囊：钻取路径可视 + 一键回跳任意层。
    private var breadcrumbChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: XSpacing.xs) {
                chip(model.scanRoot.lastPathComponent.isEmpty ? xLoc("磁盘") : model.scanRoot.lastPathComponent,
                     icon: "internaldrive", active: model.stack.isEmpty) { model.pop(to: -1) }
                ForEach(Array(model.stack.enumerated()), id: \.offset) { idx, node in
                    Image(systemName: "chevron.compact.right")
                        .font(.system(size: 11)).foregroundStyle(XColor.textTertiary)
                    chip(node.name, icon: "folder", active: idx == model.stack.count - 1) { model.pop(to: idx) }
                }
            }
            .padding(.horizontal, XSpacing.xl)
        }
        .padding(.bottom, XSpacing.s)
    }

    private func chip(_ title: String, icon: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon).font(.system(size: 10, weight: .medium))
                Text(title).font(XFont.captionEmphasis).lineLimit(1)
            }
            .foregroundStyle(active ? XColor.brand : XColor.textSecondary)
            .padding(.horizontal, XSpacing.m).padding(.vertical, 5)
            .background(Capsule().fill(active ? XColor.brand.opacity(0.12) : XColor.surface.opacity(0.6)))
            .overlay(Capsule().stroke(active ? XColor.brand.opacity(0.35) : XColor.hairline, lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder private var content: some View {
        if model.isScanning {
            scanning
        } else if let node = model.current {
            Group {
                if viz == "blocks" {
                    TreemapView(node: node) { child in model.drill(into: child) }
                        .padding(XSpacing.xl)
                } else {
                    SunburstView(node: node,
                                 onDrill: { child in model.drill(into: child) },
                                 onUp: model.stack.isEmpty ? nil : { model.pop(to: model.stack.count - 2) })
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ModuleIdleHero(
                icon: "circle.hexagongrid.fill",
                colors: XColor.brandGradientColors,
                title: xLoc("空间透镜"),
                subtitle: xLoc("把文件夹（或整个磁盘）的空间占用画成放射环形图，一眼看清谁在占地方，点击可逐层钻取。"),
                buttonTitle: xLoc("扫描主目录"),
                facts: [.init(icon: "eye", text: xLoc("只读分析 · 不修改任何文件"), tint: XColor.success),
                        .init(icon: "hand.tap", text: xLoc("点击环层钻取 · 点击中心返回"))],
                secondaryTitle: xLoc("选择文件夹"),
                secondaryAction: { model.chooseFolder() },
                action: { model.scan() })
        }
    }

    /// 扫描态：招牌彗星环 + 滚动字节数 + 当前目录胶囊 + 取消。
    private var scanning: some View {
        VStack(spacing: XSpacing.l) {
            XScanOrb(value: model.scannedBytes.formattedBytes, label: xLoc("正在分析空间"), size: 260)
            HStack(spacing: 6) {
                Image(systemName: "folder").font(.system(size: 10, weight: .medium))
                    .foregroundStyle(XColor.textTertiary)
                Text(model.scanMessage.isEmpty ? model.scanRoot.path : model.scanMessage)
                    .font(XFont.captionMono).foregroundStyle(XColor.textSecondary)
                    .lineLimit(1).truncationMode(.middle)
            }
            .padding(.horizontal, XSpacing.m).padding(.vertical, 6)
            .background(Capsule().fill(XColor.surface.opacity(0.6)))
            .overlay(Capsule().stroke(XColor.hairline, lineWidth: 1))
            .frame(maxWidth: 420)
            .animation(.easeOut(duration: 0.2), value: model.scanMessage)
            Button(xLoc("取消")) { model.cancel() }
                .buttonStyle(XSecondaryButtonStyle())
                .padding(.top, XSpacing.xs)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
