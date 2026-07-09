import SwiftUI
import AppKit
import Domain
import Infrastructure
import DesignSystem

@MainActor
final class ShredderModel: ObservableObject {
    struct Completion { let freed: Int64; let count: Int }

    @Published var files: [URL] = []
    @Published var working = false
    @Published var resultText: String?
    @Published var completion: Completion?   // 全部成功时的计数庆祝数据
    @Published var licenseBlocked = false

    private let env: XicoEnvironment
    init(env: XicoEnvironment) { self.env = env }

    var totalSize: Int64 {
        files.reduce(0) { $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0) }
    }

    func pickFiles() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        if panel.runModal() == .OK {
            for url in panel.urls where !files.contains(url) { files.append(url) }
        }
    }

    func remove(_ url: URL) { files.removeAll { $0 == url } }
    func clear() { files = []; resultText = nil; completion = nil }

    func shred() {
        guard !files.isEmpty, !working else { return }
        // 执行时刻实时复核许可证——粉碎是不可恢复的删除类付费功能，防试用到期绕过（对齐 clean/uninstall 门禁）
        guard env.license.status().state.allowsCommercialUse else { licenseBlocked = true; return }
        working = true
        resultText = nil
        completion = nil
        let env = self.env
        let targets = files
        Task {
            let result = await env.shredderService().shred(targets)
            env.history.record(module: "文件粉碎", reclaimedBytes: result.freedBytes, removedCount: result.shredded)
            NotificationCenter.default.post(name: .xicoDidClean, object: nil)
            self.working = false
            self.files = result.failed   // 只保留失败的
            if result.failed.isEmpty {
                // 全部成功：走统一的计数庆祝完成页。
                self.completion = Completion(freed: result.freedBytes, count: result.shredded)
                self.resultText = nil
            } else {
                self.resultText = xLocF("已粉碎 %d 项；%d 项失败（可能受保护或无权限）。", result.shredded, result.failed.count)
            }
        }
    }
}

public struct ShredderView: View {
    @StateObject private var model: ShredderModel
    @State private var confirm = false
    @State private var dropTargeted = false
    public init(env: XicoEnvironment) { _model = StateObject(wrappedValue: ShredderModel(env: env)) }

    public var body: some View {
        VStack(spacing: 0) {
            XHeaderBar(title: xLoc("文件粉碎"), subtitle: xLoc("多次覆写后彻底删除，难以恢复")) {
                Button(xLoc("添加文件")) { model.pickFiles() }.buttonStyle(XSecondaryButtonStyle(compact: true))
            }
            noticeBar
            content
            if !model.files.isEmpty {
                // 部分失败后 files 只剩失败项，content 走文件列表分支不再显示 resultText——
                // 故把失败摘要提到常显的操作条副标题，用户才看得到「X 项失败」的反馈（审计 P2）。
                XActionBar(title: xLocF("已选 %d 项", model.files.count),
                           subtitle: model.resultText ?? xLoc("粉碎不可恢复，请谨慎")) {
                    if model.working { XSpinner() }
                    else {
                        Button(xLocF("粉碎 · %@", model.totalSize.formattedBytes)) { confirm = true }
                            .buttonStyle(XPrimaryButtonStyle(enabled: true))
                    }
                }
            }
        }
        .confirmationDialog(xLocF("确认粉碎 %d 项？", model.files.count), isPresented: $confirm, titleVisibility: .visible) {
            Button(xLoc("彻底粉碎（不可恢复）"), role: .destructive) { model.shred() }
            Button(xLoc("取消"), role: .cancel) {}
        } message: {
            Text(xLoc("将对每个文件多次随机覆写后删除，无法从废纸篓恢复、也难以用恢复工具找回。请确认这些文件确实不再需要。"))
        }
        .alert(xLoc("需要有效许可证"), isPresented: $model.licenseBlocked) {
            Button(xLoc("升级")) { NotificationCenter.default.post(name: .xicoShowPricing, object: nil) }
            Button(xLoc("好"), role: .cancel) {}
        } message: {
            Text(xLoc("试用已结束或许可证无效。升级后即可继续使用文件粉碎。"))
        }
    }

    private var noticeBar: some View {
        HStack(spacing: XSpacing.s) {
            Image(systemName: "info.circle").foregroundStyle(XColor.textTertiary)
            Text(xLoc("提示：在 SSD/APFS 上，覆写不保证物理抹除（写时复制 + 磨损均衡）；对敏感数据，全盘 FileVault 加密才是最可靠的保护。"))
                .font(XFont.caption).foregroundStyle(XColor.textSecondary)
            Spacer()
        }
        .padding(.horizontal, XSpacing.xl).padding(.vertical, XSpacing.s)
        .background(XColor.surfaceAlt.opacity(0.5))
    }

    @ViewBuilder private var content: some View {
        if model.files.isEmpty {
            Group {
                if let c = model.completion {
                    // 全部成功：统一计数庆祝（粉碎不可恢复，故无「撤销」）。
                    TaskCompletionView(
                        animateTo: c.freed,
                        metricText: { xLocF("已释放 %@", $0.formattedBytes) },
                        detail: xLocF("已粉碎 %d 项", c.count),
                        doneTitle: xLoc("完成"),
                        onDone: { model.clear() })
                } else if let r = model.resultText {
                    XEmptyState(systemImage: "checkmark.seal.fill", title: xLoc("完成"), subtitle: r)
                } else {
                    XEmptyState(systemImage: "flame", title: xLoc("拖入或添加要粉碎的文件"),
                                subtitle: xLoc("选择确实不想被任何人恢复的文件。粉碎前会二次确认。"))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // 拖入反馈：文件悬停于投放区时点亮品牌色虚线边框 + 淡染底，呼应全局悬停语言。
            .overlay {
                if dropTargeted {
                    RoundedRectangle(cornerRadius: XRadius.card, style: .continuous)
                        .strokeBorder(XColor.brand, style: StrokeStyle(lineWidth: 2, dash: [8, 5]))
                        .background(RoundedRectangle(cornerRadius: XRadius.card, style: .continuous)
                            .fill(XColor.brand.opacity(0.06)))
                        .padding(XSpacing.l)
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }
            }
            .animation(XMotion.hover, value: dropTargeted)
            .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in handleDrop(providers) }
        } else {
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(model.files, id: \.self) { url in
                        HStack(spacing: XSpacing.m) {
                            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                                .resizable().frame(width: 24, height: 24)
                            Text(url.lastPathComponent).font(XFont.body).foregroundStyle(XColor.textPrimary).lineLimit(1)
                            Spacer()
                            Button { model.remove(url) } label: { Image(systemName: "xmark.circle.fill") }
                                .buttonStyle(.plain).foregroundStyle(XColor.textTertiary)
                                .accessibilityLabel(xLocF("从列表移除 %@", url.lastPathComponent))
                        }
                        .padding(.horizontal, XSpacing.s).padding(.vertical, 5)
                    }
                }
                .padding(XSpacing.xl)
            }
            .onDrop(of: [.fileURL], isTargeted: nil) { providers in handleDrop(providers) }
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        for provider in providers {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url { Task { @MainActor in if !model.files.contains(url) { model.files.append(url) } } }
            }
        }
        return true
    }
}
