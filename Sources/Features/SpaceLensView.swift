import SwiftUI
import Domain
import Infrastructure
import DesignSystem
import Shared
import AppKit

@MainActor
final class SpaceLensModel: ObservableObject {
    @Published var root: DiskNode?
    @Published var stack: [DiskNode] = []
    @Published var isScanning = false
    /// 是否已完成过一次扫描——用于区分「尚未扫描（引导页）」与「扫描完但空/无权限（空状态）」。
    @Published var didScan = false
    @Published var scannedBytes: Int64 = 0
    @Published var scanMessage: String = ""
    @Published var scanRoot: URL = FileManager.default.homeDirectoryForCurrentUser
    /// 「移到废纸篓」失败或被删除红线拒绝时的提示文案。
    @Published var trashError: String?

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
        didScan = false
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
            self.didScan = true
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

    /// 是否缺少完全磁盘访问权限——空状态据此在「无权限」与「空目录」两种文案间切换。
    var lacksFullDiskAccess: Bool { !env.permissions.hasFullDiskAccess() }

    func openFullDiskAccessSettings() { env.permissions.openFullDiskAccessSettings() }

    /// 就地把某项移到废纸篓（可恢复，绝不永久删除）。
    /// 纵深防御：即便可视化视图已自检过，这里再走**全应用统一的删除红线**复检一次，命中即拒绝。
    /// 关键：改用 `env.safety.verify`（DefaultSafetyEngine）而非裸 `XicoSafetyRules`——前者在
    /// 通用红线之外还兜底拦下凭证/密钥/云配置点目录（~/.aws、~/.kube、~/.docker…），
    /// 与扫描器/清理器/卸载器等每一处删除面共用同一条红线，杜绝空间透镜删除面口径偏软。
    func trash(_ node: DiskNode) {
        // 兜底红线：合成聚合桶（「其他」/「其他文件」）复用父目录 URL，绝不可删——否则会把
        // 整个当前文件夹误移废纸篓（审计 P0 wrong-target deletion）。UI 已隐藏其删除入口，此处再拦一层。
        guard !node.isAggregate else {
            trashError = xLoc("「其他」是多个小项的合计视图，并非单个文件，无法移到废纸篓。")
            return
        }
        if case let .deny(reason) = env.safety.verify(node.url, intent: .trash) {
            trashError = xLoc(reason)
            return
        }
        NSWorkspace.shared.recycle([node.url]) { [weak self] _, error in
            let message = error?.localizedDescription
            Task { @MainActor in
                guard let self else { return }
                if let message {
                    self.trashError = message
                } else {
                    self.pruneFromTree(node)   // 成功后就地剪除，无需整棵重扫
                }
            }
        }
    }

    /// 成功回收后，从内存树中剪除该节点并回收其占用（DiskNode 为引用类型，就地更新；
    /// 手动 objectWillChange 触发重绘——面包屑栈与 root 共享同一批实例，故一并同步）。
    /// 剪枝走 DiskNode 上 `@MainActor` 隔离的 `pruneSubtree(removingID:)`——本方法处于
    /// `@MainActor` 的 SpaceLensModel 内，编译器据此保证「展示相写入 = 主 actor 单写」。
    private func pruneFromTree(_ target: DiskNode) {
        guard let root else { return }
        objectWillChange.send()
        root.pruneSubtree(removingID: target.id)
    }
}

public struct SpaceLensView: View {
    @StateObject private var model: SpaceLensModel
    /// 可视化方式：放射环形（ring）/ 方块 treemap（blocks），持久化记住偏好。
    @AppStorage("xico.spacelens.viz") private var viz = "ring"

    public init(env: XicoEnvironment) {
        _model = StateObject(wrappedValue: SpaceLensModel(env: env))
    }

    /// 从 AppModel 注入缓存的会话模型：跨侧栏 tab 切换保留全盘扫描结果（审计 P2 RootView:249）。
    /// StateObject 包裹 AppModel 持有的缓存实例——AppModel 长期持有，视图重建时重新包裹同一实例即恢复结果。
    public init(model appModel: AppModel) {
        _model = StateObject(wrappedValue: appModel.spaceLensModel)
    }

    public var body: some View {
        VStack(spacing: 0) {
            XHeaderBar(title: xLoc("空间透镜"), subtitle: headerSubtitle) { headerActions }
            if hasResult && !model.isScanning { breadcrumbChips }
            content
        }
        .onAppear {
            if CommandLine.arguments.contains("--autoscan"), model.root == nil, !model.isScanning {
                model.scan()
            }
        }
        .alert(xLoc("无法移到废纸篓"),
               isPresented: Binding(get: { model.trashError != nil },
                                    set: { if !$0 { model.trashError = nil } })) {
            Button(xLoc("好"), role: .cancel) { model.trashError = nil }
        } message: {
            Text(model.trashError ?? "")
        }
    }

    /// 是否有可展示的扫描结果（根为非空树）——控制头部动作、面包屑与主视图的出现时机。
    /// 以「根」而非「当前层」判定：即便钻进某个（或就地清空后的）空子目录，面包屑仍在、可回退。
    private var hasResult: Bool {
        guard let root = model.root else { return false }
        return !root.children.isEmpty
    }

    private var headerSubtitle: String {
        if model.isScanning { return xLoc("正在分析空间") }
        if model.current != nil { return model.scanRoot.path }
        return xLoc("放射环形图 · 逐层钻取 · 只读分析")
    }

    /// 头部动作区：与其它页面同语言（无材质条、无分割线），有结果时才出现视图切换。
    @ViewBuilder private var headerActions: some View {
        HStack(spacing: XSpacing.m) {
            if hasResult && !model.isScanning {
                Picker("", selection: $viz) {
                    Image(systemName: "circle.hexagongrid").tag("ring")
                    Image(systemName: "square.grid.2x2").tag("blocks")
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
                .accessibilityLabel(xLoc("可视化方式"))
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
                        .font(XFont.caption).foregroundStyle(XColor.textTertiary)
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
                Image(systemName: icon).font(XFont.micro)
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
        } else if hasResult, let node = model.current {
            Group {
                if viz == "blocks" {
                    TreemapView(node: node,
                                onTrash: { child in model.trash(child) }) { child in model.drill(into: child) }
                        .padding(XSpacing.xl)
                } else {
                    SunburstView(node: node,
                                 onDrill: { child in model.drill(into: child) },
                                 onUp: model.stack.isEmpty ? nil : { model.pop(to: model.stack.count - 2) },
                                 onTrash: { child in model.trash(child) })
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.didScan {
            emptyResult
        } else {
            ModuleIdleHero(
                icon: "circle.hexagongrid.fill",
                colors: XColor.brandGradientColors,
                title: xLoc("空间透镜"),
                subtitle: xLoc("把文件夹（或整个磁盘）的空间占用画成放射环形图，一眼看清谁在占地方，点击可逐层钻取。"),
                buttonTitle: xLoc("扫描主目录"),
                facts: [.init(icon: "eye", text: xLoc("只读扫描 · 可右键将项目移到废纸篓（可恢复）"), tint: XColor.success),
                        .init(icon: "hand.tap", text: xLoc("点击环层钻取 · 点击中心返回"))],
                secondaryTitle: xLoc("选择文件夹"),
                secondaryAction: { model.chooseFolder() },
                action: { model.scan() })
        }
    }

    /// 扫描完成但结果为空 / 无法访问（多为缺少完全磁盘访问权限）——镜像 SessionScaffold 的失败态：
    /// 给出成因文案与「开启完全磁盘访问」入口，而非误导性地退回引导页。
    private var emptyResult: some View {
        let needsFDA = model.lacksFullDiskAccess
        return VStack(spacing: XSpacing.l) {
            XEmptyState(systemImage: needsFDA ? "lock.shield" : "tray",
                        title: needsFDA ? xLoc("需要完全磁盘访问权限") : xLoc("未找到可显示的内容"),
                        subtitle: needsFDA
                            ? xLoc("Xico 无法读取该位置的内容。请在系统设置中开启完全磁盘访问权限，然后重新扫描。")
                            : xLoc("该位置为空，或其中的文件无法访问。可换一个文件夹再试。"),
                        kind: .error)
                .frame(maxHeight: 320)
            HStack(spacing: XSpacing.m) {
                if needsFDA {
                    Button(xLoc("开启完全磁盘访问")) { model.openFullDiskAccessSettings() }
                        .buttonStyle(XPrimaryButtonStyle())
                    Button(xLoc("重新扫描")) { model.scan() }
                        .buttonStyle(XSecondaryButtonStyle())
                } else {
                    Button(xLoc("选择文件夹")) { model.chooseFolder() }
                        .buttonStyle(XSecondaryButtonStyle())
                    Button(xLoc("重新扫描")) { model.scan() }
                        .buttonStyle(XPrimaryButtonStyle())
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// 扫描态：招牌彗星环 + 滚动字节数 + 当前目录胶囊 + 取消。
    private var scanning: some View {
        VStack(spacing: XSpacing.l) {
            XScanOrb(value: model.scannedBytes.formattedBytes, label: xLoc("正在分析空间"), size: 260)
            HStack(spacing: 6) {
                Image(systemName: "folder").font(XFont.micro)
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
