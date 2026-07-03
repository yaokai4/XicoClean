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
    @StateObject private var vm: ModuleSessionViewModel
    @State private var rootLabel: String

    public init(env: XicoEnvironment) {
        let start = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
        let box = PathBox(start)
        self.env = env
        self.box = box
        _rootLabel = State(initialValue: start.lastPathComponent)
        _vm = StateObject(wrappedValue: ModuleSessionViewModel(
            env: env, title: xLoc("重复文件"), intent: .trash,
            scanProvider: { handler in
                let result = await env.duplicatesScanner(root: box.url).scan(progress: handler)
                return [result]
            }))
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
            Button(xLoc("选择文件夹")) { pickFolder() }.buttonStyle(.bordered)
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
