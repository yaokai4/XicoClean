import SwiftUI
import Infrastructure
import DesignSystem

// MARK: - 磁盘测速（对标 Sensei 存储器测速：双仪表 + 历史记录）

@MainActor
final class DiskBenchmarkViewModel: ObservableObject {
    @Published var phase: DiskBenchmarkPhase = .idle
    @Published var readMBps: Double = 0
    @Published var writeMBps: Double = 0
    @Published var history: [DiskBenchmarkResult] = []
    @Published var running = false

    private let service = DiskBenchmarkService()
    /// 跨线程取消标志：测速循环在后台线程轮询，必须线程安全（不能碰 MainActor 状态）。
    private final class CancelFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var v = false
        var value: Bool {
            get { lock.lock(); defer { lock.unlock() }; return v }
            set { lock.lock(); defer { lock.unlock() }; v = newValue }
        }
    }
    private var cancelFlag = CancelFlag()
    let device: String

    init(device: String) {
        self.device = device
        history = service.history()
    }

    /// 满量程：按历史最好成绩自适应到 1000/2000/4000/8000 档（首测按 4000 起）。
    var gaugeMax: Double {
        let best = max(history.map(\.readMBps).max() ?? 0,
                       history.map(\.writeMBps).max() ?? 0,
                       readMBps, writeMBps)
        for scale in [1000.0, 2000.0, 4000.0, 8000.0] where best <= scale * 0.95 { return scale }
        return 16000
    }

    func run() {
        guard !running else { return }
        running = true
        cancelFlag = CancelFlag()
        readMBps = 0
        writeMBps = 0
        phase = .writing(currentMBps: 0)
        let svc = service
        let dev = device
        let flag = cancelFlag
        // @MainActor 类隐式 Sendable：强捕获让 VM 在 ~10s 测速期内保活，收尾状态不丢。
        Task.detached(priority: .userInitiated) {
            _ = svc.run(device: dev, isCancelled: { flag.value }) { p in
                Task { @MainActor in self.apply(p) }
            }
            await MainActor.run {
                self.running = false
                if flag.value { self.phase = .idle }   // 被取消：回到就绪，不留半截状态
                self.history = svc.history()
            }
        }
    }

    func cancel() { cancelFlag.value = true }

    func clearHistory() {
        service.clearHistory()
        history = []
    }

    private func apply(_ p: DiskBenchmarkPhase) {
        phase = p
        switch p {
        case .writing(let mbps): writeMBps = mbps
        case .reading(let mbps): readMBps = mbps
        case .done(let r):
            writeMBps = r.writeMBps
            readMBps = r.readMBps
        default: break
        }
    }

    var phaseText: String {
        switch phase {
        case .idle:    return xLoc("就绪 · 测速约需 15 秒")
        case .writing: return xLoc("写入测试中…")
        case .reading: return xLoc("读取测试中…")
        case .done:    return xLoc("测速完成")
        case .failed:  return xLoc("测速未完成：磁盘可用空间不足或发生错误，请清理后重试。")
        }
    }
}

public struct DiskBenchmarkView: View {
    @StateObject private var vm: DiskBenchmarkViewModel
    @Environment(\.dismiss) private var dismiss
    /// true = 侧边栏独立功能页（自适应尺寸、无关闭按钮）；false = 弹出 sheet。
    private let standalone: Bool

    public init(device: String, standalone: Bool = false) {
        _vm = StateObject(wrappedValue: DiskBenchmarkViewModel(device: device))
        self.standalone = standalone
    }

    public var body: some View {
        if standalone { pageBody } else { sheetBody }
    }

    /// 独立功能页：与其它页面同语言的页头 + 居中大仪表。
    private var pageBody: some View {
        VStack(spacing: 0) {
            XHeaderBar(title: xLoc("磁盘测速"), subtitle: vm.device)
            ScrollView {
                VStack(spacing: XSpacing.l) {
                    gauges(size: 220)
                    statusRow
                    Divider().overlay(XColor.hairline)
                    historySection
                }
                .frame(maxWidth: 760)
                .padding(XSpacing.xl)
                .frame(maxWidth: .infinity)
            }
        }
    }

    private var sheetBody: some View {
        VStack(alignment: .leading, spacing: XSpacing.l) {
            sheetHeader
            gauges(size: 190)
            statusRow
            Divider().overlay(XColor.hairline)
            historySection
        }
        .padding(XSpacing.xl)
        .frame(width: 620, height: 640)
        .background(AppBackground())
    }

    private var sheetHeader: some View {
        HStack(spacing: XSpacing.m) {
            XIconTile(systemImage: "gauge.with.needle", colors: XColor.metricDisk, size: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(xLoc("磁盘测速")).xHeadline().foregroundStyle(XColor.textPrimary)
                Text(vm.device).font(XFont.caption).foregroundStyle(XColor.textSecondary)
            }
            Spacer()
            Button { vm.cancel(); dismiss() } label: {
                Image(systemName: "xmark").font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(XColor.textSecondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(xLoc("关闭"))
        }
    }

    private func gauges(size: CGFloat) -> some View {
        HStack(spacing: XSpacing.xl) {
            Spacer(minLength: 0)
            XSpeedGauge(value: vm.readMBps, maxValue: vm.gaugeMax, label: xLoc("读取"),
                        colors: [XColor.netDown, XColor.ring(2)], size: size,
                        active: activeGauge != .write)
            XSpeedGauge(value: vm.writeMBps, maxValue: vm.gaugeMax, label: xLoc("写入"),
                        colors: [XColor.netUp, XColor.ring(1)], size: size,
                        active: activeGauge != .read)
            Spacer(minLength: 0)
        }
    }

    private enum ActiveGauge { case read, write, both }
    private var activeGauge: ActiveGauge {
        switch vm.phase {
        case .writing: return .write
        case .reading: return .read
        default: return .both
        }
    }

    private var statusRow: some View {
        VStack(spacing: XSpacing.m) {
            // 状态胶囊：彗星旋转器 + 阶段文案（与扫描态同一套视觉语言）
            HStack(spacing: XSpacing.s) {
                if vm.running {
                    XCometSpinner(size: 14, colors: XColor.metricDisk)
                } else if case .done = vm.phase {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 13, weight: .semibold)).foregroundStyle(XColor.success)
                }
                Text(vm.phaseText).font(XFont.callout).foregroundStyle(XColor.textSecondary)
                    .contentTransition(.opacity)
            }
            .padding(.horizontal, XSpacing.l).padding(.vertical, 7)
            .background(Capsule().fill(XColor.surface.opacity(0.6)))
            .overlay(Capsule().stroke(XColor.hairline, lineWidth: 1))
            .animation(.easeOut(duration: 0.2), value: vm.running)
            if vm.running {
                Button(xLoc("取消")) { vm.cancel() }.buttonStyle(XSecondaryButtonStyle(compact: true))
            } else {
                Button(xLoc("运行基准测试")) { vm.run() }
                    .buttonStyle(XPrimaryButtonStyle())
                    .keyboardShortcut(.defaultAction)
            }
            Text(xLoc("测速会在系统卷写入最多 10 GB 临时文件（空间不足时自动缩小），完成后自动删除；期间请勿进行大量拷贝。"))
                .font(XFont.caption).foregroundStyle(XColor.textTertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
    }

    private var historySection: some View {
        VStack(alignment: .leading, spacing: XSpacing.s) {
            HStack {
                Text(xLoc("历史记录")).font(XFont.caption).foregroundStyle(XColor.textTertiary).tracking(0.4)
                Spacer()
                if !vm.history.isEmpty {
                    Button(xLoc("清空记录")) { vm.clearHistory() }
                        .buttonStyle(.plain)
                        .font(XFont.caption).foregroundStyle(XColor.textTertiary)
                }
            }
            if vm.history.isEmpty {
                Text(xLoc("完成一次测速后会在这里看到记录"))
                    .font(XFont.caption).foregroundStyle(XColor.textTertiary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, XSpacing.l)
            } else if standalone {
                // 独立功能页：外层已是 ScrollView，历史行直接随外层滚动，避免同轴嵌套滚动。
                VStack(spacing: XSpacing.s) {
                    ForEach(vm.history) { r in historyRow(r) }
                }
            } else {
                // 固定高度 sheet：需要内层滚动来容纳超出的历史行。
                ScrollView {
                    VStack(spacing: XSpacing.s) {
                        ForEach(vm.history) { r in historyRow(r) }
                    }
                }
            }
        }
    }

    private func historyRow(_ r: DiskBenchmarkResult) -> some View {
        HStack(spacing: XSpacing.m) {
            Image(systemName: "internaldrive").font(.system(size: 12)).foregroundStyle(XColor.accentTeal)
            VStack(alignment: .leading, spacing: 1) {
                Text(r.device).font(XFont.captionEmphasis).foregroundStyle(XColor.textPrimary)
                    .lineLimit(1).truncationMode(.middle)
                Text(Self.dateFmt.string(from: r.date)).font(XFont.caption).foregroundStyle(XColor.textTertiary)
            }
            Spacer()
            speedChip(r.readMBps, label: xLoc("读取"), color: XColor.netDown)
            speedChip(r.writeMBps, label: xLoc("写入"), color: XColor.netUp)
        }
        .padding(.horizontal, XSpacing.m).padding(.vertical, XSpacing.s)
        .background(RoundedRectangle(cornerRadius: XRadius.control, style: .continuous)
            .fill(XColor.surface.opacity(0.6)))
        .overlay(RoundedRectangle(cornerRadius: XRadius.control, style: .continuous)
            .stroke(XColor.hairline, lineWidth: 1))
    }

    private func speedChip(_ mbps: Double, label: String, color: Color) -> some View {
        VStack(alignment: .trailing, spacing: 0) {
            Text(Self.speedText(mbps)).font(XFont.mono).foregroundStyle(color)
            Text(label).font(XFont.nano).foregroundStyle(XColor.textTertiary)
        }
        .padding(.horizontal, XSpacing.s).padding(.vertical, 3)
        .background(RoundedRectangle(cornerRadius: XRadius.chip, style: .continuous).fill(color.opacity(0.10)))
    }

    static func speedText(_ mbps: Double) -> String {
        mbps >= 1000 ? String(format: "%.2f GB/s", mbps / 1024) : String(format: "%.0f MB/s", mbps)
    }

    private static let dateFmt: DateFormatter = {
        let f = DateFormatter()
        f.locale = XLocale.swiftUILocale
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f
    }()
}
