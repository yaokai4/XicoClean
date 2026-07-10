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
    /// 当前选中项（DaisyDisk 式：单击任意环段/图例行——含文件——先选中看详情，再击进入）。
    @Published var selected: DiskNode?
    /// 深层「粒度边界」目录的现场子扫描进行中（钻取时的短暂状态，UI 显示轻提示）。
    @Published var isExpanding = false
    @Published var isScanning = false
    /// 是否已完成过一次扫描——用于区分「尚未扫描（引导页）」与「扫描完但空/无权限（空状态）」。
    @Published var didScan = false
    @Published var scannedBytes: Int64 = 0
    @Published var scanMessage: String = ""
    // 默认从整盘根目录扫描（DaisyDisk 同款完整视角）；用户可换主目录/任意文件夹。
    @Published var scanRoot: URL = URL(fileURLWithPath: "/")
    /// 「移到废纸篓」失败或被删除红线拒绝时的提示文案。
    @Published var trashError: String?

    /// 色相锚定表：扫描完成时按「大小降序的一级子目录」记录 色阶索引（与环图/图例的
    /// 分配顺序一致），此后即使剪枝导致大小变化，颜色分配保持稳定、返回时可追（P2·D4）。
    @Published private(set) var topHueIndex: [UUID: Int] = [:]

    private let env: XicoEnvironment
    private var task: Task<Void, Never>?
    /// 扫描代际：换根/重扫递增。旧扫描被取消后仍可能有迟到的进度/结果回调，
    /// 一律凭代际闸拒收——否则旧任务的 ~200GB 计数会踩掉新扫描刚清零的进度（审查确认）。
    private var scanGeneration = 0

    /// 收集篮（两段式删除）。随会话缓存共存亡——切侧栏 tab 再回来，篮里的东西还在。
    lazy var basket: BasketModel = BasketModel(
        deny: { [weak self] url in self?.denyReason(for: url) },
        performTrash: { [weak self] nodes in await self?.trashMany(nodes) ?? (0, []) })

    init(env: XicoEnvironment) {
        self.env = env
        if let arg = CommandLine.arguments.first(where: { $0.hasPrefix("--scanpath=") }) {
            scanRoot = URL(fileURLWithPath: String(arg.dropFirst("--scanpath=".count)))
        }
    }

    var current: DiskNode? { stack.last ?? root }

    /// 深层明细的现场子扫描器：粒度比首扫细得多（256KB 起建文件节点），
    /// 子树体量小、bulk 读取快，钻到哪里扫到哪里——每个文件夹/文件都能看到。
    private lazy var detailScanner = DiskTreeScanner(fs: env.fs, maxChildrenPerNode: 64,
                                                     minVisibleFraction: 1.0 / 360.0,
                                                     minFileNodeBytes: 128 * 1024)

    /// 当前视图根的家族色相：钻取后整个子树锚定其「扫描根下一级祖先」的色相（nil = 在扫描根，彩虹分配）。
    var familyHue: Color? {
        guard let first = stack.first, let i = topHueIndex[first.id] else { return nil }
        return SunburstView.vividPalette[((i % SunburstView.vividPalette.count) + SunburstView.vividPalette.count) % SunburstView.vividPalette.count]
    }

    func scan() {
        task?.cancel()
        scanGeneration += 1
        let generation = scanGeneration
        isScanning = true
        didScan = false
        scannedBytes = 0
        scanMessage = ""
        root = nil
        stack = []
        let target = scanRoot
        let handler: ProgressHandler = { [weak self] p in
            Task { @MainActor in
                // 代际闸 + 单调不回退：旧扫描的迟到进度、并发线程的乱序进度都不会让数字倒着跳。
                guard let self, self.scanGeneration == generation else { return }
                self.scannedBytes = max(self.scannedBytes, p.bytesFound)
                if !p.message.isEmpty { self.scanMessage = p.message }
            }
        }
        task = Task {
            let tree = await env.diskTreeScanner.scan(target, progress: handler)
            if Task.isCancelled || self.scanGeneration != generation { return }
            self.root = tree
            // 锚定色相分配：与 SunburstView 的展示序（真实条目降序在前、聚合段钉尾）一致，扫描时定格。
            let sorted = SunburstView.displayOrder(tree.children)
            self.topHueIndex = Dictionary(uniqueKeysWithValues: sorted.enumerated().map { ($0.element.id, $0.offset) })
            self.isScanning = false
            self.didScan = true
        }
    }

    func cancel() {
        task?.cancel()
        isScanning = false
    }

    func select(_ node: DiskNode?) {
        selected = node
    }

    /// 进入目录。深层「粒度边界」节点（isDirectory 但首扫未建子节点）先现场子扫描、
    /// 嫁接明细再进入——空间透镜由此可无限钻取（DaisyDisk 口径）。
    /// `animatedBy`：宿主的「绽放」动画包装（现场扫描完成后的异步入栈也要走它）。
    func drill(into node: DiskNode, animatedBy animate: @escaping (@escaping () -> Void) -> Void = { $0() }) {
        guard node.isDirectory, !node.isAggregate else { return }
        selected = nil
        if node.children.isEmpty {
            expandThenDrill(node, animatedBy: animate)
        } else {
            enter(node, animatedBy: animate)
        }
    }

    /// 进入节点的统一收口：面包屑补全整条祖先链（深层环段直跳也不断链）+
    /// 单链自动下钻（唯一非聚合子目录占比 ≥99% 时直落到有内容的层级——
    /// 「旁边只有一个文件夹」的空壳层不值得停留）+ 背景细化当前层明细。
    private func enter(_ node: DiskNode, animatedBy animate: @escaping (@escaping () -> Void) -> Void) {
        var path = ancestors(of: node)
        if path.first?.id == root?.id { path.removeFirst() }   // root 是隐含栈底，不入栈
        path.append(node)
        var cursor = node
        var hops = 0
        while hops < 16, let sole = soleDominantChild(of: cursor) {
            path.append(sole)
            cursor = sole
            hops += 1
        }
        let landing = cursor
        animate { self.stack = path }
        refineIfCoarse(landing)
    }

    /// 单链判定：唯一的非聚合子项是个有明细的目录、且占本层 ≥99% → 值得直落。
    private func soleDominantChild(of node: DiskNode) -> DiskNode? {
        let real = node.children.filter { !$0.isAggregate }
        guard real.count == 1, let only = real.first,
              only.isDirectory, !only.children.isEmpty,
              node.size > 0, Double(only.size) / Double(node.size) >= 0.99 else { return nil }
        return only
    }

    /// 进入的层级若还是「粗粒度」（带灰色聚合桶）且体量不大（≤5GB），后台细化扫描
    ///（128KB 粒度）就地嫁接——灰桶溶解成真实条目，「每一个文件都能查看到」。
    /// 大目录不细化（等用户继续往下钻，越深越小，自然落入阈值内）。
    private func refineIfCoarse(_ node: DiskNode) {
        guard !isExpanding,
              node.size <= 5 << 30,
              node.children.contains(where: { $0.isAggregate }) else { return }
        isExpanding = true
        let generation = scanGeneration
        let scanner = detailScanner
        let url = node.url
        Task { [weak self] in
            let fresh = await scanner.scan(url)
            guard let self else { return }
            self.isExpanding = false
            guard self.scanGeneration == generation, !Task.isCancelled else { return }
            guard !fresh.children.isEmpty else { return }
            self.objectWillChange.send()
            let delta = node.adoptChildren(from: fresh)
            if delta != 0 {
                for ancestor in self.ancestors(of: node) { ancestor.adjustSize(by: delta) }
            }
        }
    }

    /// 现场子扫描 + 嫁接 + 进入。代际闸：扫描期间用户若重扫/换根，旧树的嫁接与入栈一律作废。
    private func expandThenDrill(_ node: DiskNode,
                                 animatedBy animate: @escaping (@escaping () -> Void) -> Void) {
        guard !isExpanding else { return }
        isExpanding = true
        let generation = scanGeneration
        let scanner = detailScanner
        let url = node.url
        Task { [weak self] in
            let fresh = await scanner.scan(url)
            guard let self else { return }
            self.isExpanding = false
            guard self.scanGeneration == generation, !Task.isCancelled else { return }
            guard !fresh.children.isEmpty else { return }   // 真空目录/无权限：原地不动
            self.objectWillChange.send()
            let delta = node.adoptChildren(from: fresh)
            if delta != 0 {
                for ancestor in self.ancestors(of: node) { ancestor.adjustSize(by: delta) }
            }
            self.enter(node, animatedBy: animate)
        }
    }

    /// 祖先链（root…直接父级），按 URL 前缀自根下行——嫁接后的尺寸差沿链回填，
    /// 保持每一层「children 之和 ≤ size」（环形几何不溢出的前提）。
    private func ancestors(of node: DiskNode) -> [DiskNode] {
        guard let root, root.id != node.id else { return [] }
        var chain: [DiskNode] = []
        var cursor = root
        let targetPath = node.url.path
        descend: while cursor.id != node.id {
            chain.append(cursor)
            for child in cursor.children where !child.isAggregate {
                if child.id == node.id { break descend }
                if targetPath == child.url.path || targetPath.hasPrefix(child.url.path + "/") {
                    cursor = child
                    continue descend
                }
            }
            return []   // 路径链断裂（不应发生）：放弃回填，宁可总量略偏也不误改无关节点
        }
        return chain
    }

    func pop(to index: Int) {
        selected = nil
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

    /// 删除红线预检（全应用唯一口径 env.safety）：返回拒绝原因，nil = 放行。
    /// SunburstView / TreemapView / 收集篮的预检全部注入本方法——Features 层不再自建规则实例。
    func denyReason(for url: URL) -> String? {
        if case let .deny(reason) = env.safety.verify(url, intent: .trash) { return xLoc(reason) }
        return nil
    }

    /// 批量移废纸篓（收集篮执行段）：逐项复检红线 → 回收 → 剪枝，返回释放量与失败清单。
    /// 逐项而非整批 recycle：单项失败不拖垮整篮，且成功项可精确剪枝/计量。
    func trashMany(_ nodes: [DiskNode]) async -> (freed: Int64, failures: [String]) {
        var freed: Int64 = 0
        var failures: [String] = []
        for node in nodes {
            guard !node.isAggregate else { failures.append(node.name); continue }
            if case let .deny(reason) = env.safety.verify(node.url, intent: .trash) {
                failures.append("\(node.name)（\(xLoc(reason))）")
                continue
            }
            let error = await withCheckedContinuation { (cont: CheckedContinuation<String?, Never>) in
                NSWorkspace.shared.recycle([node.url]) { _, error in
                    cont.resume(returning: error?.localizedDescription)
                }
            }
            if let error {
                failures.append("\(node.name)（\(error)）")
            } else {
                // 已知近似：硬链接文件按首见路径全额计量，删除其一并不真正释放磁盘
                //（其余链接仍持有数据）——与 Finder「显示文件大小」同口径，不为罕见病例引入链接表查询。
                freed += node.size
                pruneFromTree(node)
            }
        }
        return (freed, failures)
    }

    /// 拖放入篮：把文件 URL 解析回当前树中的节点（按路径精确匹配，深度有限、可接受）。
    func findNode(url: URL) -> DiskNode? {
        guard let root else { return nil }
        let path = url.path
        func find(_ n: DiskNode) -> DiskNode? {
            if n.url.path == path && !n.isAggregate { return n }
            guard path.hasPrefix(n.url.path) else { return nil }
            for child in n.children {
                if let hit = find(child) { return hit }
            }
            return nil
        }
        return find(root)
    }
}

public struct SpaceLensView: View {
    @StateObject private var model: SpaceLensModel
    /// 可视化方式：放射环形（ring）/ 方块 treemap（blocks），持久化记住偏好。
    @AppStorage("xico.spacelens.viz") private var viz = "ring"
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(env: XicoEnvironment) {
        _model = StateObject(wrappedValue: SpaceLensModel(env: env))
    }

    /// 从 AppModel 注入缓存的会话模型：跨侧栏 tab 切换保留全盘扫描结果（审计 P2 RootView:249）。
    /// StateObject 包裹 AppModel 持有的缓存实例——AppModel 长期持有，视图重建时重新包裹同一实例即恢复结果。
    public init(model appModel: AppModel) {
        _model = StateObject(wrappedValue: appModel.spaceLensModel)
    }

    /// 「绽放」钻取的动画入口：宿主在 withAnimation 中改层级，SunburstView 的 Animatable 弧
    /// 随之连续形变（Reduce Motion 下直接换层，无过渡）。
    private func blossom(_ change: @escaping () -> Void) {
        if reduceMotion {
            change()
        } else {
            withAnimation(XMotion.settle) { change() }
        }
    }

    /// 单击激活（环段/图例行/瓦片统一语义，DaisyDisk 口径的分型响应）：
    /// 文件夹 → 直接绽放进入（谁都不想点两次才能进，薄外环段二次点击还容易点偏）；
    /// 文件/聚合段 → 选中看详情卡（文件本就无处可进，选中即是它的「打开」）。
    private func activate(_ child: DiskNode) {
        if child.isDirectory && !child.isAggregate {
            model.drill(into: child, animatedBy: blossom)
        } else {
            withAnimation(XMotion.hover) { model.select(child) }
        }
    }

    public var body: some View {
        VStack(spacing: 0) {
            XHeaderBar(title: xLoc("空间透镜"), subtitle: headerSubtitle) { headerActions }
            if hasResult && !model.isScanning { breadcrumbChips }
            content
                .overlay(alignment: .bottom) {
                    if hasResult && !model.isScanning {
                        CollectionBasketBar(basket: model.basket, resolve: { model.findNode(url: $0) })
                            .padding(.bottom, XSpacing.l)
                    }
                }
                .overlay { BasketCompletionHost(basket: model.basket) }
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
                XSegmentedControl(selection: $viz, options: [
                    .init(tag: "ring", icon: "circle.hexagongrid", a11y: xLoc("放射环形图")),
                    .init(tag: "blocks", icon: "square.grid.2x2", a11y: xLoc("方块图")),
                ])
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
                     icon: "internaldrive", active: model.stack.isEmpty) { blossom { model.pop(to: -1) } }
                ForEach(Array(model.stack.enumerated()), id: \.offset) { idx, node in
                    Image(systemName: "chevron.compact.right")
                        .font(XFont.caption).foregroundStyle(XColor.textTertiary)
                    // 面包屑染家族色相：钻进哪一族，路径胶囊就是哪一族的颜色——返回时颜色可追（P2·D4）。
                    chip(node.name, icon: "folder", active: idx == model.stack.count - 1,
                         tint: model.familyHue) { blossom { model.pop(to: idx) } }
                }
            }
            .padding(.horizontal, XSpacing.xl)
        }
        .padding(.bottom, XSpacing.s)
    }

    private func chip(_ title: String, icon: String, active: Bool, tint: Color? = nil,
                      action: @escaping () -> Void) -> some View {
        let accent = tint ?? XColor.brand
        return Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon).font(XFont.micro)
                Text(title).font(XFont.captionEmphasis).lineLimit(1)
            }
            .foregroundStyle(active ? accent : XColor.textSecondary)
            .padding(.horizontal, XSpacing.m).padding(.vertical, 5)
            .background(Capsule().fill(active ? accent.opacity(0.12) : XColor.surface.opacity(0.6)))
            .overlay(Capsule().stroke(active ? accent.opacity(0.35) : XColor.hairline, lineWidth: 1))
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
                                selectedID: model.selected?.id,
                                onTrash: { child in model.trash(child) },
                                onCollect: { child in model.basket.add(child) },
                                denyReason: { model.denyReason(for: $0) }) { child in
                        activate(child)
                    }
                        .padding(XSpacing.xl)
                } else {
                    SunburstView(node: node,
                                 selected: model.selected,
                                 onActivate: { child in activate(child) },
                                 onUp: model.stack.isEmpty ? nil : { blossom { model.pop(to: model.stack.count - 2) } },
                                 onDeselect: { withAnimation(XMotion.hover) { model.select(nil) } },
                                 onTrash: { child in model.trash(child) },
                                 onCollect: { child in model.basket.add(child) },
                                 denyReason: { model.denyReason(for: $0) },
                                 familyHue: model.familyHue)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(alignment: .top) {
                if model.isExpanding {
                    HStack(spacing: XSpacing.s) {
                        ProgressView().controlSize(.small)
                        Text(xLoc("正在深入扫描…")).font(XFont.caption).foregroundStyle(XColor.textSecondary)
                    }
                    .padding(.horizontal, XSpacing.m).padding(.vertical, 6)
                    .background(Capsule().fill(XColor.surface.opacity(0.9)))
                    .overlay(Capsule().stroke(XColor.hairline, lineWidth: 1))
                    .padding(.top, XSpacing.s)
                    .transition(.opacity)
                }
            }
            .animation(XMotion.crossfade, value: model.isExpanding)
        } else if model.didScan {
            emptyResult
        } else {
            ModuleIdleHero(
                icon: "circle.hexagongrid.fill",
                colors: XColor.brandGradientColors,
                title: xLoc("空间透镜"),
                subtitle: xLoc("把文件夹（或整个磁盘）的空间占用画成放射环形图，一眼看清谁在占地方，点击可逐层钻取。"),
                buttonTitle: xLoc("扫描整个磁盘"),
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
            .animation(XMotion.crossfade, value: model.scanMessage)
            Button(xLoc("取消")) { model.cancel() }
                .buttonStyle(XSecondaryButtonStyle())
                .padding(.top, XSpacing.xs)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
