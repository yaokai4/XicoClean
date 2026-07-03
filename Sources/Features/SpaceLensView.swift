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
        root = nil
        stack = []
        let target = scanRoot
        let handler: ProgressHandler = { [weak self] p in
            Task { @MainActor in self?.scannedBytes = p.bytesFound }
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

    public init(env: XicoEnvironment) {
        _model = StateObject(wrappedValue: SpaceLensModel(env: env))
    }

    public var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .onAppear {
            if CommandLine.arguments.contains("--autoscan"), model.root == nil, !model.isScanning {
                model.scan()
            }
        }
    }

    private var header: some View {
        HStack(spacing: XSpacing.m) {
            breadcrumb
            Spacer()
            Button { model.chooseFolder() } label: {
                Label(xLoc("选择文件夹"), systemImage: "folder")
            }
            Button { model.scan() } label: {
                Label(xLoc("扫描"), systemImage: "arrow.clockwise")
            }
            .buttonStyle(XPrimaryButtonStyle())
        }
        .padding(.horizontal, XSpacing.xl)
        .padding(.vertical, XSpacing.m)
        .background(.ultraThinMaterial)
    }

    private var breadcrumb: some View {
        HStack(spacing: XSpacing.xs) {
            Button(model.scanRoot.lastPathComponent.isEmpty ? xLoc("磁盘") : model.scanRoot.lastPathComponent) {
                model.pop(to: -1)
            }
            .buttonStyle(.plain)
            .foregroundStyle(XColor.brand)
            ForEach(Array(model.stack.enumerated()), id: \.offset) { idx, node in
                Image(systemName: "chevron.right").font(.caption2).foregroundStyle(XColor.textSecondary)
                Button(node.name) { model.pop(to: idx) }
                    .buttonStyle(.plain)
                    .foregroundStyle(idx == model.stack.count - 1 ? XColor.textPrimary : XColor.brand)
            }
        }
        .lineLimit(1)
    }

    @ViewBuilder private var content: some View {
        if model.isScanning {
            VStack(spacing: XSpacing.xl) {
                XScanOrb(value: model.scannedBytes.formattedBytes, label: xLoc("正在分析空间"), size: 280)
                Button(xLoc("取消")) { model.cancel() }.buttonStyle(XSecondaryButtonStyle())
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let node = model.current {
            SunburstView(node: node) { child in model.drill(into: child) }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            // 空态：整组垂直+水平居中，按钮紧跟说明文字（不再被撑到下方）
            VStack(spacing: XSpacing.l) {
                XEmptyState(systemImage: "circle.hexagongrid.fill",
                            title: xLoc("空间透镜"),
                            subtitle: xLoc("把文件夹（或整个磁盘）的空间占用画成放射环形图，一眼看清谁在占地方，点击可逐层钻取。"))
                Button(xLoc("扫描主目录")) { model.scan() }
                    .buttonStyle(XPrimaryButtonStyle(large: true))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
