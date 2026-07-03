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
        selected = app
        lastFreed = nil
        let env = self.env
        Task {
            let targets = await Task.detached { env.uninstaller.uninstallTargets(for: app) }.value
            self.targets = targets
        }
    }

    func toggle(_ id: UUID) {
        guard let i = targets.firstIndex(where: { $0.id == id }) else { return }
        targets[i].isSelected.toggle()
    }

    var selectedSize: Int64 { targets.filter(\.isSelected).reduce(0) { $0 + $1.size } }
    var selectedCount: Int { targets.filter(\.isSelected).count }

    @Published var licenseBlocked = false

    func uninstall() {
        let items = targets.filter(\.isSelected)
        guard !items.isEmpty else { return }
        // 卸载同样是删除操作，必须过许可证门禁（与扫描/清理一致，堵住"试用到期仍可卸载"）
        guard env.license.status().state.allowsCommercialUse else { licenseBlocked = true; return }
        working = true
        let env = self.env
        let appName = selected?.name ?? "应用"
        Task {
            let report = await env.cleaningEngine.execute(CleaningPlan(items: items, intent: .trash))
            self.lastFreed = report.reclaimedBytes
            // 计入清理历史并广播刷新（此前卸载释放的空间被系统性少计）
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

    public var body: some View {
        HStack(spacing: 0) {
            appList
            Divider()
            detail
        }
        .onAppear { if model.apps.isEmpty { model.load() } }
        .confirmationDialog("确认卸载 \(model.selected?.name ?? "应用")？",
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
            XHeaderBar(title: xLoc("卸载器"), subtitle: "\(model.apps.count) 个应用") {
                if model.loading { ProgressView().controlSize(.small) }
            }
            searchField
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
        .frame(width: 330)
        .background(.ultraThinMaterial)
        .overlay(Rectangle().fill(XColor.hairline).frame(width: 1), alignment: .trailing)
    }

    private var searchField: some View {
        HStack(spacing: XSpacing.s) {
            Image(systemName: "magnifyingglass").font(.system(size: 12, weight: .semibold))
                .foregroundStyle(XColor.textTertiary)
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

                Text(xLoc("将一并移入废纸篓（已自动勾选关联文件）"))
                    .font(XFont.caption).foregroundStyle(XColor.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, XSpacing.xl)

                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(model.targets) { item in
                            ItemRowView(item: item) { model.toggle(item.id) }
                        }
                    }
                    .padding(XSpacing.l)
                }

                XActionBar(title: "已选 \(model.selectedCount) 项",
                           subtitle: xLoc("将移入废纸篓，可在访达中恢复")) {
                    if model.working {
                        ProgressView().controlSize(.small)
                    } else {
                        Button(xLocF("卸载 · %@", model.selectedSize.formattedBytes)) { confirmUninstall = true }
                            .buttonStyle(XPrimaryButtonStyle(enabled: model.selectedCount > 0))
                            .disabled(model.selectedCount == 0)
                    }
                }
            }
        } else if let freed = model.lastFreed {
            XEmptyState(systemImage: "checkmark.seal.fill", title: "已卸载，释放 \(freed.formattedBytes)",
                        subtitle: xLoc("从左侧选择另一个应用继续。"))
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
