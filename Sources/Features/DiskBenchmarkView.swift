import SwiftUI
import Domain
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
    /// 最近一次完成的完整结果（RND4K 矩阵 / 爆发 / 刷新耗时等专业指标来源）。
    @Published var lastResult: DiskBenchmarkResult?
    /// 测试目标卷（nil = 系统卷）。外置盘测速：测试文件必须写在被测卷上。
    @Published var targetVolume: URL?
    @Published var targetVolumeName: String?

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
        lastResult = nil
        phase = .writing(currentMBps: 0)
        let svc = service
        let dev = targetVolumeName ?? device
        let vol = targetVolume
        let flag = cancelFlag
        // @MainActor 类隐式 Sendable：强捕获让 VM 在 ~20s 测速期内保活，收尾状态不丢。
        Task.detached(priority: .userInitiated) {
            _ = svc.run(device: dev, volume: vol, isCancelled: { flag.value }) { p in
                Task { @MainActor in self.apply(p) }
            }
            await MainActor.run {
                self.running = false
                if flag.value { self.phase = .idle }   // 被取消：回到就绪，不留半截状态
                self.history = svc.history()
            }
        }
    }

    /// 选择测试卷（外置盘测速入口）：任选目标卷上的一个文件夹，测试文件写在该卷根可写处。
    func pickVolume() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: "/Volumes")
        panel.message = xLoc("选择要测速的磁盘（其上任意可写文件夹）")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let values = try? url.resourceValues(forKeys: [.volumeNameKey, .volumeIsReadOnlyKey, .volumeIsRootFileSystemKey])
        guard values?.volumeIsReadOnly != true else { return }
        // 系统卷选回来 = 恢复默认（临时目录，避免把测试文件散落在用户目录）。
        if values?.volumeIsRootFileSystem == true {
            targetVolume = nil
            targetVolumeName = nil
        } else {
            targetVolume = url   // 用用户选的文件夹（对该处有写权限），而非卷根（可能不可写）
            targetVolumeName = values?.volumeName
        }
    }

    func resetVolume() {
        targetVolume = nil
        targetVolumeName = nil
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
            lastResult = r
        default: break
        }
    }

    var phaseText: String {
        switch phase {
        case .idle:    return xLoc("就绪 · 完整基准约需 20 秒")
        case .writing: return xLoc("顺序写入测试中…")
        case .reading: return xLoc("顺序读取测试中…")
        case let .random(stage, iops):
            return xLoc(stage) + String(format: " · %.0f IOPS", iops)
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

    /// 独立功能页：与其它页面同语言的页头 + 居中大仪表 + 专业指标矩阵。
    private var pageBody: some View {
        VStack(spacing: 0) {
            XHeaderBar(title: xLoc("磁盘测速"), subtitle: vm.targetVolumeName ?? vm.device)
            ScrollView {
                VStack(spacing: XSpacing.l) {
                    volumeRow
                    gauges(size: 220)
                    statusRow
                    proMetricsSection
                    videoFitSection
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

    // MARK: 测试卷选择（外置盘测速：Blackmagic 有而我们此前没有的关键能力）

    private var volumeRow: some View {
        HStack(spacing: XSpacing.s) {
            Image(systemName: "externaldrive").font(XFont.caption).foregroundStyle(XColor.textSecondary)
            Text(xLoc("测试目标：")).font(XFont.caption).foregroundStyle(XColor.textSecondary)
            Text(vm.targetVolumeName ?? xLoc("系统卷"))
                .font(XFont.captionEmphasis).foregroundStyle(XColor.textPrimary)
            if vm.targetVolume != nil {
                Button(xLoc("恢复系统卷")) { vm.resetVolume() }
                    .buttonStyle(.plain).font(XFont.caption).foregroundStyle(XColor.brand)
                    .disabled(vm.running)
            }
            Spacer()
            Button(xLoc("更换测试卷…")) { vm.pickVolume() }
                .buttonStyle(XSecondaryButtonStyle(compact: true))
                .disabled(vm.running)
        }
        .padding(.horizontal, XSpacing.m).padding(.vertical, XSpacing.s)
        .background(RoundedRectangle(cornerRadius: XRadius.control, style: .continuous)
            .fill(XColor.surface.opacity(0.6)))
        .overlay(RoundedRectangle(cornerRadius: XRadius.control, style: .continuous)
            .stroke(XColor.hairline, lineWidth: 1))
    }

    // MARK: 专业指标矩阵（RND4K QD1/QD32 + 爆发/落盘——Blackmagic 没有的一层）

    @ViewBuilder private var proMetricsSection: some View {
        if let r = vm.lastResult, r.rnd4kReadIOPS != nil, !vm.running {
            VStack(alignment: .leading, spacing: XSpacing.s) {
                Text(xLoc("随机 4K 性能（系统响应手感的决定项）"))
                    .font(XFont.caption).foregroundStyle(XColor.textTertiary).tracking(0.4)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 168), spacing: XSpacing.s)],
                          spacing: XSpacing.s) {
                    if let iops = r.rnd4kReadIOPS {
                        rndCell(title: xLoc("随机读 · 单队列"), iops: iops,
                                latency: r.rnd4kReadAvgUS, p99: r.rnd4kReadP99US, color: XColor.netDown)
                    }
                    if let iops = r.rnd4kWriteIOPS {
                        rndCell(title: xLoc("随机写 · 单队列"), iops: iops,
                                latency: r.rnd4kWriteAvgUS, p99: nil, color: XColor.netUp)
                    }
                    if let iops = r.rnd4kQD32ReadIOPS {
                        rndCell(title: xLoc("随机读 · 深队列 ×32"), iops: iops,
                                latency: nil, p99: nil, color: XColor.netDown)
                    }
                    if let iops = r.rnd4kQD32WriteIOPS {
                        rndCell(title: xLoc("随机写 · 深队列 ×32"), iops: iops,
                                latency: nil, p99: nil, color: XColor.netUp)
                    }
                }
                honestyFootnote(r)
            }
            .transition(.opacity)
        }
    }

    private func rndCell(title: String, iops: Double, latency: Double?, p99: Double?, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(XFont.caption).foregroundStyle(XColor.textSecondary)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(iops >= 10_000 ? String(format: "%.1fK", iops / 1000) : String(format: "%.0f", iops))
                    .font(XFont.monoLarge).foregroundStyle(color)
                Text("IOPS").font(XFont.nano).foregroundStyle(XColor.textTertiary)
            }
            if let latency {
                Text(String(format: xLoc("平均 %.0f µs"), latency)
                     + (p99.map { String(format: " · p99 %.0f µs", $0) } ?? ""))
                    .font(XFont.nano).foregroundStyle(XColor.textTertiary)
            }
        }
        .padding(XSpacing.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: XRadius.control, style: .continuous)
            .fill(XColor.surface.opacity(0.6)))
        .overlay(RoundedRectangle(cornerRadius: XRadius.control, style: .continuous)
            .stroke(XColor.hairline, lineWidth: 1))
    }

    // MARK: 视频格式适配表（对标 Blackmagic「Will it Work」，三态判定更聪明）

    @ViewBuilder private var videoFitSection: some View {
        if vm.writeMBps > 0, vm.readMBps > 0, !vm.running {
            VStack(alignment: .leading, spacing: XSpacing.s) {
                Text(xLoc("视频工作流适配（录制 = 写 · 回放 = 读）"))
                    .font(XFont.caption).foregroundStyle(XColor.textTertiary).tracking(0.4)
                Grid(alignment: .leading, horizontalSpacing: XSpacing.s, verticalSpacing: 6) {
                    GridRow {
                        Text(xLoc("格式")).font(XFont.nano).foregroundStyle(XColor.textTertiary)
                            .gridColumnAlignment(.leading)
                        ForEach(VideoFitReference.codecTitles, id: \.self) { codec in
                            VStack(spacing: 0) {
                                Text(codec).font(XFont.nano).foregroundStyle(XColor.textTertiary)
                                HStack(spacing: XSpacing.m) {
                                    Text(xLoc("写")).font(XFont.nano).foregroundStyle(XColor.textTertiary)
                                    Text(xLoc("读")).font(XFont.nano).foregroundStyle(XColor.textTertiary)
                                }
                            }
                            .gridColumnAlignment(.center)
                        }
                    }
                    ForEach(VideoFitReference.rows) { row in
                        GridRow {
                            Text(row.title).font(XFont.captionMono).foregroundStyle(XColor.textSecondary)
                            fitCellPair(row.h265)
                            fitCellPair(row.proRes422HQ)
                            fitCellPair(row.proRes4444XQ)
                            fitCellPair(row.brawFiveToOne)
                        }
                    }
                }
                .padding(XSpacing.m)
                .frame(maxWidth: .infinity)
                .background(RoundedRectangle(cornerRadius: XRadius.control, style: .continuous)
                    .fill(XColor.surface.opacity(0.6)))
                .overlay(RoundedRectangle(cornerRadius: XRadius.control, style: .continuous)
                    .stroke(XColor.hairline, lineWidth: 1))
                Text(xLoc("✓ 稳（实测 ≥ 码率 ×1.2）· ⚠ 边缘（刚好够，掉帧风险）· ✗ 不足。码率参考：Apple ProRes 白皮书 2022 / Blackmagic RAW 官方公式。"))
                    .font(XFont.nano).foregroundStyle(XColor.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .transition(.opacity)
        }
    }

    /// 一格「写/读」双判定：✓/⚠/✗ 并排（BMDST 同构，但多了边缘态）。nil = 该档不存在（—）。
    @ViewBuilder private func fitCellPair(_ requiredMBps: Double?) -> some View {
        if let required = requiredMBps {
            HStack(spacing: XSpacing.m) {
                fitMark(VideoFitVerdict.judge(measuredMBps: vm.writeMBps, requiredMBps: required))
                fitMark(VideoFitVerdict.judge(measuredMBps: vm.readMBps, requiredMBps: required))
            }
            .gridColumnAlignment(.center)
            .help(String(format: xLoc("需要 %.0f MB/s"), required))
        } else {
            Text("—").font(XFont.caption).foregroundStyle(XColor.textTertiary)
                .gridColumnAlignment(.center)
        }
    }

    private func fitMark(_ verdict: VideoFitVerdict) -> some View {
        switch verdict {
        case .ok:
            return Image(systemName: "checkmark.circle.fill").font(.system(size: 12))
                .foregroundStyle(XColor.success)
        case .marginal:
            return Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 12))
                .foregroundStyle(XColor.warning)
        case .no:
            return Image(systemName: "xmark.circle").font(.system(size: 12))
                .foregroundStyle(XColor.textTertiary)
        }
    }

    /// 方法学与诚实附注：测了什么、怎么测的、爆发与落盘各是多少——可核查性即专业性。
    private func honestyFootnote(_ r: DiskBenchmarkResult) -> some View {
        var parts: [String] = []
        if let bytes = r.fileBytes {
            parts.append(xLocF("测试文件 %@", bytes.formattedBytes))
        }
        if let burst = r.burstWriteMBps, r.writeMBps > 0 {
            // 爆发 vs 持续差距 >15% 时点名 SLC 缓存效应，否则夸盘稳。
            if burst > r.writeMBps * 1.15 {
                parts.append(xLocF("首秒写入爆发 %@（SLC 缓存效应，持续值更真实）", Self.speedText(burst)))
            } else {
                parts.append(xLoc("写入全程稳定 · 无明显缓存爆发"))
            }
        }
        if let flush = r.flushSeconds, flush > 0.005 {
            parts.append(String(format: xLoc("落盘刷新 %.2fs（未计入吞吐，单列诚实展示）"), flush))
        }
        parts.append(xLoc("方法：64MB 块 ×2 并发顺序 + 4K 随机 · F_NOCACHE 直读介质 · 不可压缩数据"))
        return Text(parts.joined(separator: "\n"))
            .font(XFont.nano).foregroundStyle(XColor.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
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
            .animation(XMotion.crossfade, value: vm.running)
            if vm.running {
                Button(xLoc("取消")) { vm.cancel() }.buttonStyle(XSecondaryButtonStyle(compact: true))
            } else {
                Button(xLoc("运行基准测试")) { vm.run() }
                    .buttonStyle(XPrimaryButtonStyle())
                    .keyboardShortcut(.defaultAction)
            }
            // 评级徽章（P5·H4）：按接口代际参考区间给当前成绩一个语境（正向评级 + 参考值脚注）。
            if !vm.running, vm.readMBps > 0, let key = DiskSpeedReference.ratingKey(readMBps: vm.readMBps) {
                VStack(spacing: 2) {
                    XBadge(xLoc(key), color: XColor.success)
                    Text(xLoc("按接口代际典型顺序读速评级 · 参考值"))
                        .font(XFont.nano).foregroundStyle(XColor.textTertiary)
                }
                .transition(.opacity)
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

    /// 历史行（P5·H4）：横向对比条（同基准归一，历次成绩一眼可比）+ 最好成绩星标 + 相对时间。
    private func historyRow(_ r: DiskBenchmarkResult) -> some View {
        let maxV = max(vm.history.map { max($0.readMBps, $0.writeMBps) }.max() ?? 1, 1)
        let bestRead = vm.history.map(\.readMBps).max() ?? 0
        let isBest = r.readMBps >= bestRead && bestRead > 0
        let fmt = Self.relativeFmt
        fmt.locale = XLocale.swiftUILocale
        return HStack(spacing: XSpacing.m) {
            Image(systemName: isBest ? "star.fill" : "internaldrive")
                .font(.system(size: 12))
                .foregroundStyle(isBest ? XColor.warning : XColor.accentTeal)
                .help(isBest ? xLoc("最好成绩") : "")
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(r.device).font(XFont.captionEmphasis).foregroundStyle(XColor.textPrimary)
                        .lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Text(fmt.localizedString(for: r.date, relativeTo: Date()))
                        .font(XFont.caption).foregroundStyle(XColor.textTertiary)
                }
                comparisonBar(r.readMBps, maxV: maxV, color: XColor.netDown)
                comparisonBar(r.writeMBps, maxV: maxV, color: XColor.netUp)
            }
            VStack(alignment: .trailing, spacing: 2) {
                speedChip(r.readMBps, label: xLoc("读取"), color: XColor.netDown)
                speedChip(r.writeMBps, label: xLoc("写入"), color: XColor.netUp)
            }
        }
        .padding(.horizontal, XSpacing.m).padding(.vertical, XSpacing.s)
        .background(RoundedRectangle(cornerRadius: XRadius.control, style: .continuous)
            .fill(XColor.surface.opacity(0.6)))
        .overlay(RoundedRectangle(cornerRadius: XRadius.control, style: .continuous)
            .stroke(isBest ? XColor.warning.opacity(0.4) : XColor.hairline, lineWidth: 1))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(r.device) · \(Self.speedText(r.readMBps)) / \(Self.speedText(r.writeMBps))" + (isBest ? " · " + xLoc("最好成绩") : ""))
    }

    private func comparisonBar(_ v: Double, maxV: Double, color: Color) -> some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(XColor.surfaceAlt)
                Capsule().fill(color.opacity(0.8))
                    .frame(width: max(2, g.size.width * CGFloat(min(v / maxV, 1))))
            }
        }
        .frame(height: 4)
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

    /// 相对时间（与 ModuleScanView 同法），跟随应用语言——不再硬编码 "yyyy-MM-dd HH:mm" 与他处格式打架。
    private static let relativeFmt: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f
    }()
}
