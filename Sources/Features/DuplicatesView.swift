import SwiftUI
import AppKit
import Domain
import Infrastructure
import DesignSystem

/// 线程安全的可变 URL 盒子：主线程（选文件夹）写、后台扫描闭包读，
/// 必须加锁——URL 是多字结构，跨线程无同步读写是未定义行为（TSan 必报）。
final class PathBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _url: URL
    var url: URL {
        get { lock.lock(); defer { lock.unlock() }; return _url }
        set { lock.lock(); _url = newValue; lock.unlock() }
    }
    init(_ u: URL) { _url = u }
}

public struct DuplicatesView: View {
    private let env: XicoEnvironment
    private let box: PathBox
    // 与 SmartScanView/ModuleScanView 一致：AppModel 缓存的会话用 @ObservedObject 观察（生命周期归 AppModel），
    // 不再用 @StateObject 伪装「视图自持」——统一所有权语义，避免缓存会话被误当作视图私有状态。
    @ObservedObject private var vm: ModuleSessionViewModel
    @State private var rootLabel: String

    public init(env: XicoEnvironment) {
        let start = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
        let box = PathBox(start)
        self.env = env
        self.box = box
        _rootLabel = State(initialValue: start.lastPathComponent)
        self.vm = ModuleSessionViewModel(
            env: env, title: xLoc("重复文件"), intent: .trash,
            scanProvider: { handler in
                let result = await env.duplicatesScanner(root: box.url).scan(progress: handler)
                return [result]
            })
    }

    /// 从 AppModel 注入缓存的会话与共享 PathBox：跨 tab 保留所选目录与扫描结果（审计 P2 RootView:249）。
    /// box 复用 AppModel.duplicatesFolderBox——换文件夹写入同一 box，缓存会话据其重扫新目录。
    public init(model: AppModel) {
        self.env = model.env
        self.box = model.duplicatesFolderBox
        _rootLabel = State(initialValue: model.duplicatesFolderBox.url.lastPathComponent)
        self.vm = model.duplicatesSession
    }

    public var body: some View {
        VStack(spacing: 0) {
            folderBar
            SessionScaffold(vm: vm, cleanButtonTitle: xLoc("删除重复")) {
                ModuleIdleHero(
                    icon: "doc.on.doc", colors: [XColor.accentTeal, XColor.brand],
                    title: xLoc("重复文件"),
                    subtitle: xLoc("在所选文件夹中按内容（大小 + 头尾哈希）查找重复文件，每组智能保留一份、勾选其余。已自动忽略硬链接。"),
                    buttonTitle: xLocF("扫描「%@」", rootLabel),
                    action: { vm.start() })
            }
        }
    }

    private var folderBar: some View {
        HStack(spacing: XSpacing.s) {
            Image(systemName: "folder.fill").foregroundStyle(XColor.brand)
            Text(xLoc("扫描位置：")).font(XFont.caption).foregroundStyle(XColor.textSecondary)
            Text(box.url.path).font(XFont.caption).foregroundStyle(XColor.textPrimary)
                .lineLimit(1).truncationMode(.middle)
            Spacer()
            Button(xLoc("选择文件夹")) { pickFolder() }.buttonStyle(XSecondaryButtonStyle(compact: true))
        }
        .padding(.horizontal, XSpacing.xl)
        .padding(.vertical, XSpacing.s)
        .background(.ultraThinMaterial)
    }

    private func pickFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            box.url = url
            rootLabel = url.lastPathComponent
            vm.start()
        }
    }
}
