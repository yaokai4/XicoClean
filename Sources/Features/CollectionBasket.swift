import SwiftUI
import Domain
import Infrastructure
import DesignSystem
import AppKit

// MARK: - 收集篮（两段式删除 · 签名时刻 S2）
//
// DaisyDisk Collector 的 Xico 化：先收集（可预览、可移出、危险项拒收）→ 非模态 5 秒
// 倒计时（可撤销 / 可立即执行）→ 归零才批量移废纸篓（可恢复）→ 大数字庆祝。
// 「Undo 优于 Are-you-sure」：高频删除不再弹确认框，靠倒计时 + 撤销制造安全网。
// 红线双闸：入篮时预检（deny 闭包 = env.safety）+ 执行时宿主复检——两道都走全应用唯一红线。

@MainActor
final class BasketModel: ObservableObject {
    @Published private(set) var items: [DiskNode] = []
    /// 非模态倒计时剩余秒数；nil = 未在倒计时。
    @Published var countdownRemaining: Double?
    /// 执行完成后的释放字节数（非 nil → 宿主展示庆祝页）。
    @Published var completedBytes: Int64?
    /// 轻提示（拒收原因 / 部分失败），宿主用 xToast 展示。
    @Published var toast: String?
    /// 篮内清单浮层是否展开。
    @Published var showList = false

    static let countdownSeconds = 5.0

    private let deny: (URL) -> String?
    private let performTrash: ([DiskNode]) async -> (freed: Int64, failures: [String])
    private var countdownTask: Task<Void, Never>?
    /// 应用内撤销（P0-f KILLER-2）：宿主注入 CleaningEngine.undo 通路；nil = 宿主不支持。
    /// 返回用户可读结果文案（toast 展示）。
    var performUndo: (() async -> String)?
    @Published var undoing = false

    init(deny: @escaping (URL) -> String?,
         performTrash: @escaping ([DiskNode]) async -> (freed: Int64, failures: [String])) {
        self.deny = deny
        self.performTrash = performTrash
    }

    /// 庆祝页「撤销」：从废纸篓恢复整篮到原位。
    func undoLast() {
        guard let performUndo, !undoing else { return }
        undoing = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            let message = await performUndo()
            self.undoing = false
            withAnimation(XMotion.crossfade) { self.completedBytes = nil }
            self.toast = message
        }
    }

    var totalBytes: Int64 { items.reduce(0) { $0 + $1.size } }

    /// 第一段：入篮。合成聚合桶拒收（P0 红线：复用父目录 URL 绝不可删）；安全规则命中即拒收并说明。
    func add(_ node: DiskNode) {
        guard !node.isAggregate else {
            toast = xLoc("「其他」是多个小项的合计视图，并非单个文件，无法移到废纸篓。")
            return
        }
        guard !items.contains(where: { $0.id == node.id || $0.url == node.url }) else { return }
        if let reason = deny(node.url) {
            toast = xLocF("已被安全规则拦下：%@", reason)
            return
        }
        withAnimation(XMotion.snappy) { items.append(node) }
    }

    func remove(_ node: DiskNode) {
        withAnimation(XMotion.snappy) { items.removeAll { $0.id == node.id } }
    }

    func clear() {
        withAnimation(XMotion.snappy) { items.removeAll() }
        showList = false
    }

    /// 第二段：非模态倒计时（可撤销 / 可立即执行），归零才真正执行。
    func beginCountdown() {
        guard !items.isEmpty, countdownTask == nil else { return }
        showList = false
        withAnimation(XMotion.snappy) { countdownRemaining = Self.countdownSeconds }
        countdownTask = Task { @MainActor [weak self] in
            let start = Date()
            while !Task.isCancelled {
                let left = Self.countdownSeconds - Date().timeIntervalSince(start)
                if left <= 0 { break }
                self?.countdownRemaining = left
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            guard !Task.isCancelled, let self else { return }
            await self.execute()
        }
    }

    func cancelCountdown() {
        countdownTask?.cancel()
        countdownTask = nil
        withAnimation(XMotion.snappy) { countdownRemaining = nil }
    }

    func executeNow() {
        countdownTask?.cancel()
        countdownTask = nil
        Task { @MainActor in await execute() }
    }

    private func execute() async {
        countdownTask = nil
        withAnimation(XMotion.snappy) { countdownRemaining = nil }
        let batch = items
        guard !batch.isEmpty else { return }
        XSound.play(.countdownDone)   // 签名音效③：倒计时归零执行（P4）
        let result = await performTrash(batch)
        withAnimation(XMotion.snappy) { items.removeAll() }
        if !result.failures.isEmpty {
            toast = xLocF("%d 项未能移入废纸篓", result.failures.count)
        }
        if result.freed > 0 {
            withAnimation(XMotion.celebrate) { completedBytes = result.freed }
        }
    }
}

// MARK: - 幽默换算（克制的完成彩蛋：只在 ≥2GB 时出现，避免小数字尴尬）

func spaceFunLine(_ bytes: Int64) -> String? {
    let gb = Double(bytes) / 1_073_741_824
    guard gb >= 2 else { return nil }
    switch bytes % 3 {
    case 0:  return xLocF("这些空间够装 %d 部 4K 电影", max(1, Int(gb / 15)))
    case 1:  return xLocF("相当于 %d 张 RAW 照片的容量", max(1, Int(gb * 1024 / 30)))
    default: return xLocF("能塞下 %d 张无损音乐专辑", max(1, Int(gb * 1024 / 300)))
    }
}

// MARK: - 底部浮动收集篮条

struct CollectionBasketBar: View {
    @ObservedObject var basket: BasketModel
    /// 拖放入篮时把文件 URL 解析回树节点（宿主提供）。
    let resolve: (URL) -> DiskNode?

    var body: some View {
        Group {
            if let remaining = basket.countdownRemaining {
                countdownBar(remaining)
            } else if basket.items.isEmpty {
                emptyHint
            } else {
                filledBar
            }
        }
        .animation(XMotion.settle, value: basket.items.count)
        .animation(XMotion.settle, value: basket.countdownRemaining != nil)
    }

    /// 空态：收窄的提示胶囊（常驻可见 = 功能可发现；同时是拖放目标）。
    private var emptyHint: some View {
        HStack(spacing: XSpacing.s) {
            Image(systemName: "basket").font(XFont.bodyEmphasis).foregroundStyle(XColor.textTertiary)
            Text(xLoc("右键或拖到这里，先收集、再删除"))
                .font(XFont.caption).foregroundStyle(XColor.textTertiary)
        }
        .padding(.horizontal, XSpacing.l).padding(.vertical, XSpacing.s)
        .xFloatingGlassCapsule()
        .opacity(0.85)
        .dropDestination(for: URL.self) { urls, _ in dropURLs(urls) }
        .accessibilityLabel(xLoc("收集篮"))
    }

    /// 有货态：计数 + 容量 + 查看/删除。整个胶囊即拖放目标。
    private var filledBar: some View {
        HStack(spacing: XSpacing.m) {
            Button {
                basket.showList.toggle()
            } label: {
                HStack(spacing: XSpacing.s) {
                    Image(systemName: "basket.fill").font(XFont.bodyEmphasis).foregroundStyle(XColor.brand)
                    Text(xLocF("已收集 %d 项", basket.items.count))
                        .font(XFont.bodyEmphasis).foregroundStyle(XColor.textPrimary)
                        .contentTransition(.numericText())
                    Text(basket.totalBytes.formattedBytes)
                        .font(XFont.mono).foregroundStyle(XColor.brand)
                        .contentTransition(.numericText())
                    Image(systemName: "chevron.up")
                        .font(XFont.micro).foregroundStyle(XColor.textTertiary)
                        .rotationEffect(.degrees(basket.showList ? 180 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(xLocF("已收集 %d 项", basket.items.count) + " · \(basket.totalBytes.formattedBytes)")
            .popover(isPresented: $basket.showList, arrowEdge: .top) { listPopover }

            Button(xLocF("删除 %d 项", basket.items.count)) { basket.beginCountdown() }
                .buttonStyle(XDestructiveButtonStyle(compact: true))
        }
        .padding(.horizontal, XSpacing.l).padding(.vertical, XSpacing.s + 2)
        .xFloatingGlassCapsule()
        .xElevation(.overlay)
        .dropDestination(for: URL.self) { urls, _ in dropURLs(urls) }
    }

    /// 倒计时态：进度递减条 + 撤销 / 立即执行——非模态，不打断浏览。
    private func countdownBar(_ remaining: Double) -> some View {
        let fraction = max(0, min(1, remaining / BasketModel.countdownSeconds))
        return HStack(spacing: XSpacing.m) {
            ZStack(alignment: .leading) {
                Capsule().fill(XColor.surfaceAlt).frame(width: 120, height: 6)
                Capsule().fill(LinearGradient(colors: [XColor.danger, XColor.accentPink],
                                              startPoint: .leading, endPoint: .trailing))
                    .frame(width: 120 * fraction, height: 6)
            }
            .accessibilityHidden(true)
            Text(xLocF("%d 秒后删除 %d 项", Int(remaining.rounded(.up)), basket.items.count))
                .font(XFont.bodyEmphasis).foregroundStyle(XColor.textPrimary)
                .monospacedDigit()
            Button(xLoc("撤销")) { basket.cancelCountdown() }
                .buttonStyle(XSecondaryButtonStyle(compact: true))
                .keyboardShortcut(.cancelAction)
            Button(xLoc("立即执行")) { basket.executeNow() }
                .buttonStyle(XDestructiveButtonStyle(compact: true))
        }
        .padding(.horizontal, XSpacing.l).padding(.vertical, XSpacing.s + 2)
        .xFloatingGlassCapsule()
        .xElevation(.overlay)
    }

    /// 篮内清单：删除前必须「看得见收集了什么」——逐项可移出、可在 Finder 中显示。
    private var listPopover: some View {
        VStack(alignment: .leading, spacing: XSpacing.s) {
            HStack {
                Text(xLoc("收集篮")).font(XFont.headline).foregroundStyle(XColor.textPrimary)
                Spacer()
                Text(basket.totalBytes.formattedBytes).font(XFont.mono).foregroundStyle(XColor.brand)
            }
            Text(xLoc("删除前可逐项查看，随时移出。执行后移入废纸篓，可恢复。"))
                .font(XFont.caption).foregroundStyle(XColor.textTertiary)
            Divider()
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(basket.items) { item in
                        HStack(spacing: XSpacing.s) {
                            Image(systemName: item.isDirectory ? "folder.fill" : "doc")
                                .font(XFont.nano).foregroundStyle(XColor.textTertiary)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(item.name).font(XFont.bodyEmphasis)
                                    .foregroundStyle(XColor.textPrimary)
                                    .lineLimit(1).truncationMode(.middle)
                                Text(item.url.deletingLastPathComponent().path)
                                    .font(XFont.micro).foregroundStyle(XColor.textTertiary)
                                    .lineLimit(1).truncationMode(.middle)
                            }
                            Spacer()
                            Text(item.size.formattedBytes).font(XFont.caption)
                                .foregroundStyle(XColor.textSecondary).monospacedDigit()
                            Button {
                                basket.remove(item)
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(XFont.bodyEmphasis).foregroundStyle(XColor.textTertiary)
                            }
                            .buttonStyle(.plain)
                            .help(xLoc("从收集篮移除"))
                            .accessibilityLabel(xLoc("从收集篮移除"))
                        }
                        .padding(.vertical, 4).padding(.horizontal, XSpacing.s)
                        .contentShape(Rectangle())
                        .contextMenu {
                            Button(xLoc("在 Finder 中显示")) {
                                NSWorkspace.shared.activateFileViewerSelecting([item.url])
                            }
                            Button(xLoc("从收集篮移除")) { basket.remove(item) }
                        }
                    }
                }
            }
            .frame(maxHeight: 320)
            Divider()
            HStack {
                Button(xLoc("清空收集篮")) { basket.clear() }
                    .buttonStyle(XSecondaryButtonStyle(compact: true))
                Spacer()
                Button(xLocF("删除 %d 项", basket.items.count)) { basket.beginCountdown() }
                    .buttonStyle(XDestructiveButtonStyle(compact: true))
            }
        }
        .padding(XSpacing.l)
        .frame(width: 420)
    }

    private func dropURLs(_ urls: [URL]) -> Bool {
        var accepted = false
        for url in urls {
            if let node = resolve(url) {
                basket.add(node)
                accepted = true
            }
        }
        // 拖拽吸附触感（docs/16 P0-1 收尾）：文件落进篮那一下 .alignment——收口在 dropURLs
        // 而非 add()，右键/按钮加入不震（触感只属于「拖拽对准」这个物理动作）。
        if accepted { XHaptic.perform(.alignment) }
        return accepted
    }
}

// MARK: - 收集篮完成庆祝（覆盖宿主内容区）

struct BasketCompletionHost: View {
    @ObservedObject var basket: BasketModel

    var body: some View {
        Group {
            if let freed = basket.completedBytes {
                ZStack {
                    AppBackground()
                    TaskCompletionView(
                        animateTo: freed,
                        metricText: { xLocF("已释放 %@", $0.formattedBytes) },
                        detail: completionDetail(freed),
                        doneTitle: xLoc("完成"),
                        onDone: { withAnimation(XMotion.crossfade) { basket.completedBytes = nil } })
                }
                // 一键撤销（KILLER-2）：删完还能整篮回原位——DaisyDisk 永久删除结构上做不到。
                .overlay(alignment: .bottomTrailing) {
                    if basket.performUndo != nil {
                        Button {
                            basket.undoLast()
                        } label: {
                            Label(basket.undoing ? xLoc("恢复中…") : xLoc("撤销（恢复到原位）"),
                                  systemImage: "arrow.uturn.backward")
                        }
                        .buttonStyle(XSecondaryButtonStyle(compact: true))
                        .disabled(basket.undoing)
                        .padding(XSpacing.xl)
                    }
                }
                .transition(.opacity)
            }
        }
        .xToast(Binding(get: { basket.toast }, set: { basket.toast = $0 }))
    }

    private func completionDetail(_ freed: Int64) -> String {
        let base = xLoc("已移入废纸篓，可随时恢复。")
        if let fun = spaceFunLine(freed) { return base + "\n" + fun }
        return base
    }
}
