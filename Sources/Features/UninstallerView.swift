import SwiftUI
import AppKit
import Domain
import Infrastructure
import DesignSystem

@MainActor
final class UninstallerModel: ObservableObject {
    @Published var apps: [InstalledApp] = []
    @Published var selected: InstalledApp?
    @Published var targets: [CleanableItem] = []
    @Published var loading = false
    @Published var working = false
    @Published var lastFreed: Int64?
    @Published var lastRemovedCount: Int = 0
    @Published var query = ""

    var filteredApps: [InstalledApp] {
        query.isEmpty ? apps : apps.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    private let env: XicoEnvironment
    init(env: XicoEnvironment) { self.env = env }

    func load() {
        loading = true
        let env = self.env
        Task {
            // 第一阶段：秒级出列表（无体积）
            let apps = await Task.detached { env.uninstaller.listApps() }.value
            self.apps = apps
            self.loading = false
            // 第二阶段：后台补齐体积并按大小重排
            let sized = await Task.detached { () -> [InstalledApp] in
                apps.map { app in
                    InstalledApp(id: app.id, name: app.name, bundleID: app.bundleID,
                                 url: app.url, size: env.uninstaller.appSize(app))
                }.sorted { $0.size > $1.size }
            }.value
            self.apps = sized
        }
    }

    func select(_ app: InstalledApp) {
        // 立即清空上一应用的列表——避免 A→B 快切时 B 的头部仍绑着 A 的旧文件列表，
        // 用户此刻确认就会误删「另一应用」的文件（P2 数据安全）。
        targets = []
        selected = app
        lastFreed = nil
        let env = self.env
        let appID = app.id
        Task {
            let targets = await Task.detached { env.uninstaller.uninstallTargets(for: app) }.value
            // 慢扫描回来时若选择已切走，丢弃这批陈旧结果，绝不覆盖更新选择的列表。
            guard self.selected?.id == appID else { return }
            self.targets = targets
        }
    }

    func toggle(_ id: UUID) {
        guard let i = targets.firstIndex(where: { $0.id == id }) else { return }
        targets[i].isSelected.toggle()
    }

    var allTargetsSelected: Bool { !targets.isEmpty && targets.allSatisfy(\.isSelected) }
    func toggleAllTargets(_ on: Bool) { for i in targets.indices { targets[i].isSelected = on } }

    var selectedSize: Int64 { targets.filter(\.isSelected).reduce(0) { $0 + $1.size } }
    var selectedCount: Int { targets.filter(\.isSelected).count }

    @Published var licenseBlocked = false

    func uninstall() {
        // 二次确认：当前展示的关联文件必须确实属于此刻选中的应用。
        // uninstallTargets 总把应用本体（url == app.url）作为首项加入，故据此校验；
        // 一旦对不上（快切时序错配的兜底），直接放弃本次卸载，绝不删「另一应用」的文件。
        guard let app = selected, targets.contains(where: { $0.url == app.url }) else { return }
        let items = targets.filter(\.isSelected)
        guard !items.isEmpty else { return }
        // 卸载同样是删除操作，必须过许可证门禁（与扫描/清理一致，堵住"试用到期仍可卸载"）
        guard env.license.status().state.allowsCommercialUse else { licenseBlocked = true; return }
        working = true
        let env = self.env
        let appName = selected?.name ?? xLoc("应用")
        Task {
            let report = await env.cleaningEngine.execute(CleaningPlan(items: items, intent: .trash))
            self.lastFreed = report.reclaimedBytes
            self.lastRemovedCount = report.removedCount
            // 计入清理历史并广播刷新（此前卸载释放的空间被系统性少计）。
            // 存规范中文键「卸载 · <名>」而非记录时已本地化的串——由展示层按当前语言重排前缀，
            // 避免历史行冻结在卸载时的语言（与其他历史模块「显示时本地化」的口径一致）。
            env.history.record(module: "卸载 · \(appName)",
                               reclaimedBytes: report.reclaimedBytes, removedCount: report.removedCount)
            NotificationCenter.default.post(name: .xicoDidClean, object: nil)
            self.working = false
            self.selected = nil
            self.targets = []
            self.load()
        }
    }
}

public struct UninstallerView: View {
    @StateObject private var model: UninstallerModel
    @State private var confirmUninstall = false
    public init(env: XicoEnvironment) {
        _model = StateObject(wrappedValue: UninstallerModel(env: env))
    }

    /// 从 AppModel 注入缓存的卸载器模型：跨 tab 保留已加载的应用清单与所选残留项（审计 P2 RootView:249）。
    public init(model appModel: AppModel) {
        _model = StateObject(wrappedValue: appModel.uninstallerModel)
    }

    public var body: some View {
        HStack(spacing: 0) {
            appList
            Divider()
            detail
        }
        .onAppear { if model.apps.isEmpty { model.load() } }
        .confirmationDialog(xLocF("确认卸载 %@？", model.selected?.name ?? xLoc("应用")),
                            isPresented: $confirmUninstall, titleVisibility: .visible) {
            Button(xLocF("卸载并移入废纸篓（%d 项）", model.selectedCount), role: .destructive) { model.uninstall() }
            Button(xLoc("取消"), role: .cancel) {}
        } message: {
            Text(xLocF("将把应用本体与已勾选的 %d 项关联文件移入废纸篓（%@），可在访达废纸篓中恢复。请确认勾选项中没有你仍需要的数据。", model.selectedCount, model.selectedSize.formattedBytes))
        }
        .alert(xLoc("需要有效许可证"), isPresented: $model.licenseBlocked) {
            Button(xLoc("升级")) { NotificationCenter.default.post(name: .xicoShowPricing, object: nil) }
            Button(xLoc("好"), role: .cancel) {}
        } message: {
            Text(xLoc("试用已结束或许可证无效。购买后即可继续使用卸载功能。"))
        }
    }

    private var appList: some View {
        VStack(spacing: 0) {
            XHeaderBar(title: xLoc("卸载器"), subtitle: xLocF("%d 个应用", model.apps.count)) {
                if model.loading { XSpinner() }
            }
            searchField
            if model.loading && model.apps.isEmpty {
                // 首次加载应用清单时，列表主体给出骨架行（而非仅头部小转圈的空白），
                // 与监视器进程/核心列表的骨架处理一致。
                ScrollView {
                    XSkeletonRows(count: 10)
                        .padding(.horizontal, XSpacing.m)
                        .padding(.top, XSpacing.s)
                }
            } else if model.filteredApps.isEmpty && !model.query.isEmpty {
                // 搜索无命中时给出明确的空态，避免用户误以为列表加载失败。
                VStack(spacing: XSpacing.s) {
                    Image(systemName: "magnifyingglass")
                        .font(XFont.title)
                        .foregroundStyle(XColor.textTertiary)
                    Text(xLoc("未找到匹配的应用"))
                        .font(XFont.body)
                        .foregroundStyle(XColor.textSecondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(XSpacing.l)
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(model.filteredApps) { app in
                            AppRow(app: app, selected: model.selected?.id == app.id) { model.select(app) }
                        }
                    }
                    .padding(.horizontal, XSpacing.s)
                    .padding(.bottom, XSpacing.l)
                }
            }
        }
        .frame(width: 330)
        .background(.ultraThinMaterial)
        .overlay(Rectangle().fill(XColor.hairline).frame(width: 1), alignment: .trailing)
    }

    private var searchField: some View {
        HStack(spacing: XSpacing.s) {
            Image(systemName: "magnifyingglass").font(XFont.callout)
                .foregroundStyle(XColor.textTertiary)
                .accessibilityHidden(true)
            TextField(xLoc("搜索应用"), text: $model.query)
                .textFieldStyle(.plain)
                .font(XFont.body)
        }
        .padding(.horizontal, XSpacing.m)
        .padding(.vertical, 7)
        .background(XColor.surfaceAlt.opacity(0.7), in: Capsule())
        .overlay(Capsule().strokeBorder(XColor.border.opacity(0.6), lineWidth: 1))
        .padding(.horizontal, XSpacing.m)
        .padding(.bottom, XSpacing.s)
    }

    @ViewBuilder private var detail: some View {
        if let app = model.selected {
            VStack(spacing: 0) {
                HStack(spacing: XSpacing.m) {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: app.url.path))
                        .resizable().frame(width: 54, height: 54)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(app.name).font(XFont.title).foregroundStyle(XColor.textPrimary)
                        Text(app.bundleID).font(XFont.caption).foregroundStyle(XColor.textSecondary)
                    }
                    Spacer()
                }
                .padding(XSpacing.xl)

                // 全选/全不选关联文件 + 实时体积——批量卸载更顺手。
                HStack(spacing: XSpacing.s) {
                    XCheckbox(isOn: model.allTargetsSelected) { model.toggleAllTargets(!model.allTargetsSelected) }
                        .accessibilityLabel(xLoc("全选关联文件"))
                    Text(xLoc("关联文件")).font(XFont.captionEmphasis).foregroundStyle(XColor.textSecondary)
                    Spacer()
                    Text(xLocF("已选 %d 项 · %@", model.selectedCount, model.selectedSize.formattedBytes))
                        .font(XFont.caption).foregroundStyle(XColor.textTertiary)
                }
                .padding(.horizontal, XSpacing.xl).padding(.top, XSpacing.xs)

                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(model.targets) { item in
                            ItemRowView(item: item) { model.toggle(item.id) }
                        }
                    }
                    .padding(XSpacing.l)
                }

                XActionBar(title: xLocF("已选 %d 项", model.selectedCount),
                           subtitle: xLoc("将移入废纸篓，可在访达中恢复")) {
                    if model.working {
                        XSpinner()
                    } else {
                        Button(xLocF("卸载 · %@", model.selectedSize.formattedBytes)) { confirmUninstall = true }
                            .buttonStyle(XPrimaryButtonStyle(enabled: model.selectedCount > 0))
                            .disabled(model.selectedCount == 0)
                    }
                }
            }
        } else if let freed = model.lastFreed {
            // 统一计数庆祝：释放字节数从 0 数起 + 卸载项数（文件已入废纸篓，可在访达恢复）。
            TaskCompletionView(
                animateTo: freed,
                metricText: { xLocF("已释放 %@", $0.formattedBytes) },
                detail: xLocF("已卸载 %d 项 · 可在废纸篓恢复", model.lastRemovedCount))
        } else {
            XEmptyState(systemImage: "xmark.bin", title: xLoc("选择要卸载的应用"),
                        subtitle: xLoc("从左侧列表选择一个应用，Xico 会找出它的全部关联文件供你一并清除。"))
        }
    }
}

private struct AppRow: View {
    let app: InstalledApp
    let selected: Bool
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            HStack(spacing: XSpacing.s) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: app.url.path))
                    .resizable().frame(width: 28, height: 28)
                VStack(alignment: .leading, spacing: 1) {
                    Text(app.name).font(XFont.bodyEmphasis)
                        .foregroundStyle(selected ? .white : XColor.textPrimary).lineLimit(1)
                    Text(app.size > 0 ? app.size.formattedBytes : xLoc("计算中…")).font(XFont.caption)
                        .foregroundStyle(selected ? .white.opacity(0.85) : XColor.textSecondary)
                }
                Spacer()
            }
            .padding(.horizontal, XSpacing.s)
            .padding(.vertical, 6)
            .background(
                Group {
                    if selected { RoundedRectangle(cornerRadius: XRadius.tile).fill(XColor.brandGradient) }
                    else if hover { RoundedRectangle(cornerRadius: XRadius.tile).fill(XColor.surfaceHover) }
                }
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .accessibilityLabel(app.name)
        .accessibilityValue(app.size > 0 ? app.size.formattedBytes : "")
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}
