import SwiftUI
import AppKit
import Domain
import Infrastructure
import DesignSystem

@MainActor
final class AppUpdaterModel: ObservableObject {
    @Published var candidates: [AppUpdateCandidate] = []
    @Published var updates: [AppUpdateCandidate] = []
    @Published var checking = false
    @Published var progress = ""
    @Published var checked = false

    private let env: XicoEnvironment
    init(env: XicoEnvironment) { self.env = env }

    func load() {
        let service = env.appUpdateService()
        Task.detached {
            let list = service.candidates()
            await MainActor.run { self.candidates = list }
        }
    }

    func check() {
        guard !checking else { return }
        checking = true
        checked = false
        let service = env.appUpdateService()
        let list = candidates
        Task { @MainActor in
            let found = await service.checkForUpdates(list) { done, total in
                Task { @MainActor in self.progress = xLocF("检查中 %d/%d", done, total) }
            }
            self.updates = found
            self.checking = false
            self.checked = true
        }
    }
}

public struct AppUpdaterView: View {
    @StateObject private var model: AppUpdaterModel
    public init(env: XicoEnvironment) { _model = StateObject(wrappedValue: AppUpdaterModel(env: env)) }

    public var body: some View {
        VStack(spacing: 0) {
            XHeaderBar(title: xLoc("应用更新"), subtitle: xLocF("%d 个应用支持自更新", model.candidates.count)) {
                if model.checking { XSpinner() }
                else { Button(xLoc("检查更新")) { model.check() }.buttonStyle(XPrimaryButtonStyle(compact: true)) }
            }
            content
        }
        .onAppear { if model.candidates.isEmpty { model.load() } }
    }

    @ViewBuilder private var content: some View {
        if model.checking {
            XEmptyState(systemImage: "arrow.triangle.2.circlepath", title: xLoc("正在检查更新"), subtitle: model.progress, kind: .loading)
        } else if !model.updates.isEmpty {
            ScrollView {
                LazyVStack(spacing: XSpacing.s) {
                    ForEach(model.updates) { app in updateRow(app) }
                }
                .padding(XSpacing.xl)
            }
        } else if model.checked {
            // 统一庆祝：已检查的应用数从 0 数起 + 「全部为最新」。
            TaskCompletionView(
                animateTo: Int64(model.candidates.count),
                metricText: { xLocF("已检查 %d 个应用", Int($0)) },
                detail: xLoc("全部为最新版本，没有发现新版本。"))
        } else {
            XEmptyState(systemImage: "arrow.triangle.2.circlepath", title: xLoc("检查应用更新"),
                        subtitle: xLoc("Xico 会读取带 Sparkle 自更新源的应用，比对各自最新版本。App Store 应用请在 App Store 更新。"))
        }
    }

    private func updateRow(_ app: AppUpdateCandidate) -> some View {
        XCard {
            HStack(spacing: XSpacing.m) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: app.url.path))
                    .resizable().frame(width: 40, height: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text(app.name).font(XFont.bodyEmphasis).foregroundStyle(XColor.textPrimary)
                    Text("\(app.currentVersion) → \(app.latestVersion ?? "?")")
                        .font(XFont.caption).foregroundStyle(XColor.success)
                }
                Spacer()
                if let dl = app.downloadURL {
                    Button(xLoc("下载")) { NSWorkspace.shared.open(dl) }.buttonStyle(XPrimaryButtonStyle(compact: true))
                }
            }
        }
    }
}
