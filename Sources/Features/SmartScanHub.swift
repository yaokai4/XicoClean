import SwiftUI
import AppKit
import Domain
import Infrastructure
import DesignSystem

// MARK: - 智能扫描中枢（docs/14 P1）
// 对标并超越 CleanMyMac 5 Smart Care：六类目并行、**逐类到达（先到先亮，签名时刻 S1）**、
// tile 卡片总览 + 整卡跳过 + Review 下钻、混合意图一键清理（废纸篓 .permanent，其余 .trash）。
// 删除红线不在此层：每一项仍经 CleaningEngine（SafetyEngine verify + TOCTOU 复查）与许可闸门。

/// 中枢的六个扫描类目。顺序即 tile 网格顺序，也是跨类目去重的优先级（前者先占 URL）。
public enum SmartCategory: String, CaseIterable, Identifiable, Sendable {
    case junk           // 系统垃圾（系统垃圾 + 浏览器隐私 + 深度全盘走查三件套聚合）
    case trash          // 废纸篓（含外置盘 .Trashes；清理 = .permanent 清空）
    case threats        // 威胁防护（四层检测；清理前 launchctl bootout）
    case duplicates     // 重复文件（内容级查重，默认 ~/Downloads 可换根）
    case similarImages  // 相似图片（感知查重）
    case largeFiles     // 大文件与旧文件（个人数据——永不自动勾选）

    public var id: String { rawValue }

    /// 中文字面量即 i18n key（与 ModuleCatalog 复用同一批既有键）。
    var title: String {
        switch self {
        case .junk: return "系统垃圾"
        case .trash: return "废纸篓"
        case .largeFiles: return "大文件与旧文件"
        case .duplicates: return "重复文件"
        case .similarImages: return "相似图片"
        case .threats: return "威胁防护"
        }
    }

    var subtitle: String {
        switch self {
        case .junk: return "缓存 / 日志 / 开发者残余"
        case .trash: return "清空释放空间"
        case .largeFiles: return "找出大块头"
        case .duplicates: return "内容级查重"
        case .similarImages: return "感知查重 · 保留最佳"
        case .threats: return "签名校验 / 可疑启动项"
        }
    }

    var icon: String {
        switch self {
        case .junk: return "trash"
        case .trash: return "trash.circle"
        case .largeFiles: return "doc.viewfinder"
        case .duplicates: return "doc.on.doc"
        case .similarImages: return "photo.on.rectangle.angled"
        case .threats: return "shield.lefthalf.filled"
        }
    }

    var colors: [Color] {
        switch self {
        case .junk: return [Color(red: 0.09, green: 0.72, blue: 0.65), XColor.accentTeal]
        case .trash: return [Color(red: 0.24, green: 0.48, blue: 0.95), XColor.accentTeal]
        case .threats: return [XColor.warning, XColor.accentPink]
        case .duplicates: return [Color(red: 0.55, green: 0.36, blue: 0.96), XColor.accentPink]
        case .similarImages: return [XColor.accentPink, Color(red: 0.55, green: 0.36, blue: 0.96)]
        case .largeFiles: return [Color(red: 0.96, green: 0.55, blue: 0.11), XColor.warning]
        }
    }

    /// 清理意图：废纸篓 = 清空（.permanent，UI 必须二次确认）；其余移入废纸篓可撤销。
    var intent: DeleteIntent { self == .trash ? .permanent : .trash }

    /// 永不自动勾选的类目（个人数据 / 高危项）——扫描结果到达后强制全不选，只能人工 Review 勾选。
    var neverAutoSelect: Bool { self == .largeFiles || self == .threats }
}

// MARK: - 中枢 ViewModel

@MainActor
public final class SmartScanHubViewModel: ObservableObject {
    public enum Phase: Equatable { case idle, active, finished }

    public struct CategoryState {
        public enum Status: Equatable { case pending, scanning, done, failed(String) }
        public var status: Status = .pending
        public var groups: [ScanResultGroup] = []
        /// 整卡纳入/跳过（CleanMyMac tile 左上角勾选的对应物）。
        public var included = true
        public var bytesFound: Int64 = 0
        public var message: String = ""
    }

    @Published public private(set) var phase: Phase = .idle
    @Published public private(set) var states: [SmartCategory: CategoryState] = [:]
    /// 正在下钻 Review 的类目（放 VM 而非 @State：切侧栏再回来不丢导航位置）。
    @Published public var reviewing: SmartCategory?
    @Published public private(set) var cleaning = false
    @Published public var lastReport: CleaningReport?
    @Published public private(set) var permissionIssue = false
    @Published public private(set) var needsPurchaseToClean = false
    @Published public var undoFailedItems: [RestorableItem] = []
    public var undoFailedAlert: Bool {
        get { !undoFailedItems.isEmpty }
        set { if !newValue { undoFailedItems = [] } }
    }
    /// 系统垃圾类目内部（三件套聚合）的部分失败降级提示。
    @Published public private(set) var junkWarning: String?
    /// 诚实空间账本（P3 · S2）：全类目落定后采集一次；nil = 尚未采集。
    @Published public private(set) var ledger: SpaceLedger?
    /// 删后空间解释（P3）：删除量明显大于实际空间增长时的快照暂存说明，随完成页展示。
    @Published public private(set) var spaceNote: String?

    private let env: XicoEnvironment
    private let duplicatesRoot: PathBox
    private var tasks: [SmartCategory: Task<Void, Never>] = [:]
    private var lastHistoryID: UUID?
    private let junkFailures = FailureBox()

    nonisolated(unsafe) private var didCleanObserver: NSObjectProtocol?
    nonisolated(unsafe) private var licenseChangedObserver: NSObjectProtocol?

    init(env: XicoEnvironment, duplicatesRoot: PathBox) {
        self.env = env
        self.duplicatesRoot = duplicatesRoot
        for c in SmartCategory.allCases { states[c] = CategoryState() }
        let refresh: @Sendable (Notification) -> Void = { [weak self] _ in
            Task { @MainActor in self?.refreshPurchaseGate() }
        }
        didCleanObserver = NotificationCenter.default.addObserver(
            forName: .xicoDidClean, object: nil, queue: nil, using: refresh)
        licenseChangedObserver = NotificationCenter.default.addObserver(
            forName: .xicoLicenseChanged, object: nil, queue: nil, using: refresh)
    }

    deinit {
        if let didCleanObserver { NotificationCenter.default.removeObserver(didCleanObserver) }
        if let licenseChangedObserver { NotificationCenter.default.removeObserver(licenseChangedObserver) }
    }

    // MARK: 派生数据（只读遍历内存态，不触发磁盘/验签）

    public func state(_ c: SmartCategory) -> CategoryState { states[c] ?? CategoryState() }

    public var anyScanning: Bool { states.values.contains { $0.status == .scanning } }
    public var allDone: Bool { !states.values.contains { $0.status == .scanning || $0.status == .pending } }
    public var scanningCount: Int { states.values.filter { $0.status == .scanning }.count }

    /// 全部类目发现总量（含未纳入的卡——「发现」是事实陈述，「纳入」才影响清理）。
    public var totalFound: Int64 {
        SmartCategory.allCases.reduce(0) { $0 + state($1).groups.reduce(0) { $0 + $1.totalSize } }
    }
    public var totalItemCount: Int {
        SmartCategory.allCases.reduce(0) { $0 + state($1).groups.reduce(0) { $0 + $1.items.count } }
    }

    public func selectedItems(_ c: SmartCategory) -> [CleanableItem] {
        let st = state(c)
        guard st.included, st.status == .done else { return [] }
        return st.groups.flatMap { $0.items.filter(\.isSelected) }
    }
    public var selectedSize: Int64 {
        SmartCategory.allCases.reduce(0) { $0 + selectedItems($1).reduce(0) { $0 + $1.size } }
    }
    public var selectedCount: Int {
        SmartCategory.allCases.reduce(0) { $0 + selectedItems($1).count }
    }
    /// 已选中项里是否含「彻底删除」语义（废纸篓清空 / 特权助手项）——决定是否需要二次确认。
    public var selectionNeedsConfirm: Bool {
        !selectedItems(.trash).isEmpty ||
            SmartCategory.allCases.contains { selectedItems($0).contains(where: \.requiresHelper) }
    }
    /// 结果是否为「全类目扫完且一无所获」。
    public var isSpotless: Bool { allDone && totalItemCount == 0 }

    private func refreshPurchaseGate() {
        needsPurchaseToClean = !env.license.status().state.allowsCommercialUse
    }

    // MARK: 扫描（六类目并行，逐类到达）

    public func start() {
        refreshPurchaseGate()
        cancelTasks()
        phase = .active
        reviewing = nil
        lastReport = nil
        permissionIssue = false
        junkWarning = nil
        junkFailures.reset()
        for c in SmartCategory.allCases {
            var st = states[c] ?? CategoryState()
            st.status = .scanning
            st.groups = []
            st.bytesFound = 0
            st.message = ""
            states[c] = st
        }
        for c in SmartCategory.allCases {
            tasks[c] = Task { [weak self] in await self?.run(c) }
        }
    }

    /// 单类目重扫（失败卡重试 / 重复文件换根后）。
    public func rescan(_ c: SmartCategory) {
        guard phase == .active, !cleaning else { return }
        tasks[c]?.cancel()
        var st = states[c] ?? CategoryState()
        st.status = .scanning
        st.groups = []
        st.bytesFound = 0
        states[c] = st
        tasks[c] = Task { [weak self] in await self?.run(c) }
    }

    public func cancel() {
        cancelTasks()
        // 已有任何结果就停在结果页（把「先到」的类目标 done、未完的标失败-取消），否则回 idle。
        if totalItemCount > 0 || allDone {
            for c in SmartCategory.allCases where state(c).status == .scanning {
                states[c]?.status = .failed(xLoc("已取消"))
            }
        } else {
            phase = .idle
        }
    }

    private func cancelTasks() {
        for t in tasks.values { t.cancel() }
        tasks.removeAll()
    }

    private func run(_ c: SmartCategory) async {
        let throttle = ProgressThrottle()
        let handler: ProgressHandler = { [weak self] p in
            guard throttle.shouldFire() else { return }
            Task { @MainActor in
                guard let self else { return }
                self.states[c]?.bytesFound = p.bytesFound
                if !p.message.isEmpty { self.states[c]?.message = p.message }
            }
        }
        do {
            let results = try await provider(for: c)(handler)
            if Task.isCancelled { return }
            var merged = results.flatMap(\.groups).sorted { $0.totalSize > $1.totalSize }
            // 用户忽略清单（与单模块页同一套排除机制）
            let ignore = env.ignoreList
            for i in merged.indices { merged[i].items.removeAll { ignore.isIgnored($0.url) } }
            merged.removeAll { $0.items.isEmpty }
            // 个人数据 / 高危类目：永不自动勾选（CleanMyMac 同策略，见 docs/14 §4.1）
            if c.neverAutoSelect {
                for gi in merged.indices {
                    for ii in merged[gi].items.indices { merged[gi].items[ii].isSelected = false }
                }
            }
            states[c]?.groups = merged
            states[c]?.status = .done
            if c == .junk { junkWarning = junkFailures.summary() }
            applyCrossDedup()
            onCategorySettled()
        } catch is CancellationError {
            // 取消由 cancel() 统一处理状态
        } catch {
            if Task.isCancelled { return }
            XicoLog.scan.error("智能扫描类目失败 [\(c.rawValue, privacy: .public)]: \(error.localizedDescription, privacy: .public)")
            states[c]?.status = .failed(error.localizedDescription)
            onCategorySettled()
        }
    }

    private func provider(for c: SmartCategory) -> @Sendable (@escaping ProgressHandler) async throws -> [ScanResult] {
        let e = env
        switch c {
        case .junk:
            let failures = junkFailures
            return { handler in
                try await e.smartScanCoordinator().scanAll(progress: handler,
                                                           onModuleFailure: { failures.add($0) })
            }
        case .trash:
            return { handler in
                guard let s = e.scanner(for: .trash) else { return [] }
                return [try await s.scan(progress: handler)]
            }
        case .largeFiles:
            return { handler in
                guard let s = e.scanner(for: .largeFiles) else { return [] }
                return [try await s.scan(progress: handler)]
            }
        case .duplicates:
            let box = duplicatesRoot
            return { handler in [await e.duplicatesScanner(root: box.url).scan(progress: handler)] }
        case .similarImages:
            return { handler in [await e.similarImagesScanner().scan(progress: handler)] }
        case .threats:
            return { handler in
                guard let s = e.scanner(for: .malware) else { return [] }
                return [try await s.scan(progress: handler)]
            }
        }
    }

    /// 跨类目去重优先级（高 → 低）：**威胁最先**——同一 LaunchAgent plist 可能同时被孤儿引擎
    /// （系统垃圾类目）与威胁检测命中，安全语境（.risky + 检出原因 + bootout 钩子）必须胜出，
    /// 绝不能被「残留」的中性外衣吞掉。其后系统垃圾 > 废纸篓 > 重复 > 相似 > 大文件
    /// （重复文件组携带成组语境，信息量高于大文件平铺）。
    private static let dedupPrecedence: [SmartCategory] =
        [.threats, .junk, .trash, .duplicates, .similarImages, .largeFiles]

    /// 跨类目按「完全相同 URL」去重。父子路径重叠不在此处理
    /// （系统垃圾内部已由 ScanResultDeduper 处理；跨类目父子极罕见，宁可多列不误合并）。
    private func applyCrossDedup() {
        var claimed = Set<String>()
        for c in Self.dedupPrecedence {
            guard var st = states[c], st.status == .done else { continue }
            for gi in st.groups.indices {
                st.groups[gi].items.removeAll { claimed.contains($0.url.path) }
            }
            st.groups.removeAll { $0.items.isEmpty }
            for g in st.groups { for it in g.items { claimed.insert(it.url.path) } }
            states[c] = st
        }
    }

    private func onCategorySettled() {
        guard allDone else { return }
        XSound.play(.scanDone)   // 签名音效①：全类目落定
        refreshPurchaseGate()
        // 权限诚实：未授 FDA 时受保护位置根本没被扫到——显式标注，绝不静默装作「很干净」。
        permissionIssue = !env.permissions.hasFullDiskAccess()
        // 诚实空间账本（P3）：落定后采集一次 purgeable/快照——展示与解释，绝不计入「可回收」。
        Task { [weak self] in
            let ledger = await SpaceLedger.collect()
            self?.ledger = ledger
        }
    }

    public func openPermissionSettings() { env.permissions.openFullDiskAccessSettings() }

    // MARK: 选择

    public func toggleItem(_ c: SmartCategory, groupID: String, itemID: UUID) {
        guard var st = states[c],
              let gi = st.groups.firstIndex(where: { $0.id == groupID }),
              let ii = st.groups[gi].items.firstIndex(where: { $0.id == itemID }) else { return }
        st.groups[gi].items[ii].isSelected.toggle()
        states[c] = st
    }

    public func setGroup(_ c: SmartCategory, groupID: String, selected: Bool) {
        guard var st = states[c], let gi = st.groups.firstIndex(where: { $0.id == groupID }) else { return }
        for i in st.groups[gi].items.indices { st.groups[gi].items[i].isSelected = selected }
        states[c] = st
    }

    public func groupSelectionState(_ c: SmartCategory, group: ScanResultGroup) -> Bool {
        !group.items.isEmpty && group.items.allSatisfy(\.isSelected)
    }

    public func ignore(_ c: SmartCategory, groupID: String, itemID: UUID) {
        guard var st = states[c],
              let gi = st.groups.firstIndex(where: { $0.id == groupID }),
              let item = st.groups[gi].items.first(where: { $0.id == itemID }) else { return }
        env.ignoreList.add(item.url)
        st.groups[gi].items.removeAll { $0.id == itemID }
        if st.groups[gi].items.isEmpty { st.groups.remove(at: gi) }
        states[c] = st
    }

    public func setIncluded(_ c: SmartCategory, included: Bool) {
        states[c]?.included = included
    }

    // MARK: 清理（混合意图分批执行；红线全部由 CleaningEngine 内部保证）

    public func clean() {
        guard !cleaning, selectedCount > 0 else { return }
        // 许可闸门：扫描免费可见价值，破坏性动作需有效授权（与 ModuleSessionViewModel.ensureLicensed 同线）。
        guard env.license.status().state.allowsCommercialUse else {
            needsPurchaseToClean = true
            NotificationCenter.default.post(name: .xicoShowPricing, object: nil)
            return
        }
        cleaning = true
        spaceNote = nil
        // 删后空间解释（P3）：记录清理前的实际可用容量，完成后对比。
        let volumeBefore = env.fs.volumeCapacity(for: FileManager.default.homeDirectoryForCurrentUser)?.available
        let perCategory = SmartCategory.allCases.map { ($0, selectedItems($0)) }.filter { !$0.1.isEmpty }
        Task { [weak self] in
            guard let self else { return }
            defer { self.cleaning = false }
            // 威胁类目：删 plist 前先 bootout 停用已加载 agent（ThreatRemediation 自带
            // ~/Library/LaunchAgents 限定 + Label 白名单校验——中枢缺口修复，docs/14 §4.2.3）。
            if let threatItems = perCategory.first(where: { $0.0 == .threats })?.1 {
                await ThreatRemediation.bootoutUserAgents(threatItems.map(\.url))
            }
            var reports: [CleaningReport] = []
            var trashRestorables: [RestorableItem] = []
            for (category, items) in perCategory {
                let normal = items.filter { !$0.requiresHelper }
                let privileged = items.filter(\.requiresHelper)
                if !normal.isEmpty {
                    let report = await self.env.cleaningEngine.execute(
                        CleaningPlan(items: normal, intent: category.intent))
                    if category.intent == .trash { trashRestorables += report.restorable }
                    reports.append(report)
                }
                if !privileged.isEmpty {
                    reports.append(await self.env.cleaningEngine.execute(
                        CleaningPlan(items: privileged, intent: .permanent)))
                }
                self.removeCleaned(category, reports: reports)
            }
            let merged = CleaningReport(
                removedCount: reports.reduce(0) { $0 + $1.removedCount },
                reclaimedBytes: reports.reduce(0) { $0 + $1.reclaimedBytes },
                failures: reports.flatMap(\.failures),
                restorable: trashRestorables)   // 撤销仅覆盖 .trash 部分（废纸篓清空/特权删除不可逆，诚实）
            self.lastReport = merged
            self.lastHistoryID = self.env.history.record(module: xLoc("智能扫描"),
                                                         reclaimedBytes: merged.reclaimedBytes,
                                                         removedCount: merged.removedCount,
                                                         restorable: trashRestorables)
            self.phase = .finished
            XSound.play(.cleanDone)   // 签名音效②：清理完成
            if merged.reclaimedBytes > 0 {
                Notifier.notifyCleaningDone(reclaimed: merged.reclaimedBytes.formattedBytes,
                                            count: merged.removedCount)
            }
            NotificationCenter.default.post(name: .xicoDidClean, object: nil)
            // 删后空间解释（P3）：删了 5GB 但可用只涨 1GB？主动解释 APFS 快照暂存，
            // 而不是让用户怀疑「清了个寂寞」（CleanMyMac 被骂点反着做）。
            if let before = volumeBefore,
               let after = self.env.fs.volumeCapacity(for: FileManager.default.homeDirectoryForCurrentUser)?.available,
               merged.reclaimedBytes - max(0, after - before) > 512 * 1_048_576 {
                self.spaceNote = xLoc("部分已释放空间可能被 APFS 本地快照暂存，系统通常会在 24 小时内自动归还；也可在「维护」页立即瘦身快照。")
            }
        }
    }

    private func removeCleaned(_ c: SmartCategory, reports: [CleaningReport]) {
        let failedPaths = Set(reports.flatMap(\.failures).map { $0.url.path })
        guard var st = states[c] else { return }
        for gi in st.groups.indices {
            st.groups[gi].items.removeAll { $0.isSelected && !failedPaths.contains($0.url.path) }
        }
        st.groups.removeAll { $0.items.isEmpty }
        states[c] = st
    }

    private var isUndoing = false

    public func undo() {
        guard let report = lastReport, !report.restorable.isEmpty, !isUndoing else { return }
        isUndoing = true
        Task {
            defer { self.isUndoing = false }
            let result = await env.cleaningEngine.undo(report)
            if result.allSucceeded {
                if let id = lastHistoryID { env.history.remove(id: id); lastHistoryID = nil }
                self.lastReport = nil
                NotificationCenter.default.post(name: .xicoDidClean, object: nil)
                self.start()
            } else {
                let remaining = report.restorable.filter { result.failed.contains($0) }
                self.lastReport = CleaningReport(
                    removedCount: report.removedCount, reclaimedBytes: report.reclaimedBytes,
                    failures: report.failures, restorable: remaining)
                if let id = lastHistoryID { env.history.updateRestorable(id: id, to: remaining) }
                self.undoFailedItems = result.failed
                NotificationCenter.default.post(name: .xicoDidClean, object: nil)
            }
        }
    }

    public func revealUndoFailuresInTrash() {
        for item in undoFailedItems { revealInFinder(item.trashedURL) }
    }

    public func reset() {
        cancelTasks()
        phase = .idle
        reviewing = nil
        lastReport = nil
        for c in SmartCategory.allCases { states[c] = CategoryState(included: state(c).included) }
    }

    /// 更换重复文件扫描根目录并重扫该类目。
    public func setDuplicatesRoot(_ url: URL) {
        duplicatesRoot.url = url
        rescan(.duplicates)
    }
    public var duplicatesRootURL: URL { duplicatesRoot.url }
}

// MARK: - 中枢活动视图（tile 网格 / Review 下钻 / 底部行动条）

struct SmartScanHubActiveView: View {
    @ObservedObject var hub: SmartScanHubViewModel
    @State private var confirmClean = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if let reviewing = hub.reviewing {
                CategoryReviewView(hub: hub, category: reviewing)
                    .transition(reduceMotion ? .opacity : .move(edge: .trailing).combined(with: .opacity))
            } else if hub.isSpotless {
                spotlessView
            } else {
                overview
                    .transition(.opacity)
            }
        }
        .animation(reduceMotion ? XMotion.crossfade : XMotion.settle, value: hub.reviewing)
        .confirmationDialog(xLoc("确认清理？"), isPresented: $confirmClean, titleVisibility: .visible) {
            Button(xLocF("确认清理 %d 项", hub.selectedCount), role: .destructive) { hub.clean() }
            Button(xLoc("取消"), role: .cancel) {}
        } message: {
            Text(xLoc("废纸篓与管理员项目将彻底删除（不可恢复）；其余项目移入废纸篓，可随时撤销。"))
        }
    }

    // MARK: 总览（六卡网格）

    private var overview: some View {
        VStack(spacing: 0) {
            header
            // 诚实空间账本（P3 · S2）：三本账分开陈述，purgeable/快照只解释不计入可回收。
            if hub.ledger != nil, !hub.anyScanning {
                LedgerStrip(hub: hub)
            }
            if let warning = warningText {
                warningBanner(warning)
            }
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: XSpacing.m)],
                          spacing: XSpacing.m) {
                    ForEach(Array(SmartCategory.allCases.enumerated()), id: \.element) { index, category in
                        CategoryTile(hub: hub, category: category, index: index)
                    }
                }
                .padding(XSpacing.xl)
            }
            actionBar
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: XSpacing.l) {
            XMiniRing(fraction: hub.totalFound > 0 ? Double(hub.selectedSize) / Double(max(hub.totalFound, 1)) : 0,
                      colors: XColor.brandGradientColors, size: 52, lineWidth: 5) {
                Image(systemName: "sparkles")
                    .font(XFont.bodyEmphasis)
                    .foregroundStyle(XColor.brandGradient)
            }
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: XSpacing.xs) {
                    Text(xLoc("智能扫描")).font(XFont.captionEmphasis).foregroundStyle(XColor.brand).tracking(0.2)
                    Text("·").font(XFont.caption).foregroundStyle(XColor.textTertiary)
                    if hub.anyScanning {
                        Text(xLocF("正在扫描 %d 个类目 · 先到先亮", hub.scanningCount))
                            .font(XFont.caption).foregroundStyle(XColor.textSecondary)
                    } else {
                        Text(xLocF("共发现 %d 项 · 可清理", hub.totalItemCount))
                            .font(XFont.caption).foregroundStyle(XColor.textSecondary)
                    }
                }
                Text(hub.totalFound.formattedBytes).xLargeTitle().foregroundStyle(XColor.textPrimary)
                    .contentTransition(.numericText())
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 3) {
                Text(xLocF("已选 %d 项", hub.selectedCount)).font(XFont.caption).foregroundStyle(XColor.textSecondary)
                Text(hub.selectedSize.formattedBytes).xTitle().foregroundStyle(XColor.brand)
                    .contentTransition(.numericText())
            }
            if hub.anyScanning {
                Button(xLoc("取消")) { hub.cancel() }
                    .buttonStyle(XSecondaryButtonStyle(compact: true))
                    .padding(.leading, XSpacing.m)
            } else {
                Button { hub.start() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.plain).foregroundStyle(XColor.textSecondary)
                    .padding(.leading, XSpacing.m)
                    .accessibilityLabel(xLoc("重新扫描"))
            }
        }
        .padding(.horizontal, XSpacing.xl)
        .padding(.vertical, XSpacing.l)
    }

    private var warningText: String? {
        var parts: [String] = []
        if let junk = hub.junkWarning { parts.append(junk) }
        if hub.permissionIssue {
            parts.append(xLoc("未获完全磁盘访问权限，部分位置无法扫描。授权后可发现更多可清理项。"))
        }
        return parts.isEmpty ? nil : parts.joined(separator: "\n")
    }

    private func warningBanner(_ text: String) -> some View {
        HStack(spacing: XSpacing.s) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(XColor.warning)
            Text(text).font(XFont.caption).foregroundStyle(XColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: XSpacing.s)
            if hub.permissionIssue {
                Button(xLoc("开启完全磁盘访问")) { hub.openPermissionSettings() }
                    .buttonStyle(XSecondaryButtonStyle(compact: true))
            }
        }
        .padding(.horizontal, XSpacing.xl).padding(.vertical, XSpacing.s)
        .background(XColor.warning.opacity(0.12))
    }

    private var actionBar: some View {
        XActionBar(
            title: xLocF("已选 %d 项", hub.selectedCount),
            subtitle: xLoc("废纸篓清空为彻底删除；其余项目移入废纸篓，可随时撤销")
        ) {
            if hub.cleaning {
                HStack(spacing: XSpacing.s) {
                    XRingGauge(progress: 0, spinning: true, colors: XColor.brandGradientColors, lineWidth: 2.5, size: 16) { EmptyView() }
                    Text(xLoc("清理中…")).font(XFont.caption).foregroundStyle(XColor.textSecondary)
                }
            } else if hub.needsPurchaseToClean {
                Button(xLoc("购买后清理") + " · " + hub.selectedSize.formattedBytes) {
                    NotificationCenter.default.post(name: .xicoShowPricing, object: nil)
                }
                .buttonStyle(XPrimaryButtonStyle())
                .accessibilityLabel(xLoc("购买后清理"))
            } else {
                Button(xLoc("一键清理") + " · " + hub.selectedSize.formattedBytes) {
                    if hub.selectionNeedsConfirm { confirmClean = true } else { hub.clean() }
                }
                .buttonStyle(XPrimaryButtonStyle(enabled: hub.selectedCount > 0))
                .disabled(hub.selectedCount == 0)
            }
        }
    }

    private var spotlessView: some View {
        VStack(spacing: XSpacing.l) {
            XEmptyState(systemImage: "checkmark.seal.fill",
                        title: xLoc("太棒了，这里很干净 ✨"),
                        subtitle: xLoc("没有发现可清理的项目。"), kind: .success)
                .frame(maxHeight: 340)
            if hub.permissionIssue {
                Button(xLoc("开启完全磁盘访问")) { hub.openPermissionSettings() }
                    .buttonStyle(XPrimaryButtonStyle())
            }
            Button(xLoc("重新扫描")) { hub.start() }.buttonStyle(XSecondaryButtonStyle())
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - 诚实空间账本条（P3 · S2：永久回收 / purgeable / 本地快照 三本账分开陈述）

private struct LedgerStrip: View {
    @ObservedObject var hub: SmartScanHubViewModel

    var body: some View {
        HStack(spacing: XSpacing.s) {
            chip(color: XColor.accentTeal,
                 label: xLoc("点清理立即回收"),
                 value: hub.selectedSize.formattedBytes,
                 explain: xLoc("已勾选项清理后立即、永久释放的空间。体积为磁盘实测分配大小，不掺水分。"))
            chip(color: XColor.textTertiary,
                 label: xLoc("系统自管 purgeable"),
                 value: hub.ledger?.purgeableBytes.map { $0.formattedBytes } ?? xLoc("无法读取"),
                 explain: xLoc("macOS 标记为「可清除」的空间（本地快照、系统缓存等），系统在需要时自动回收。手动清理它除了数字好看没有实际作用——Xico 不把它计入可回收。"))
            chip(color: Color(red: 0.24, green: 0.48, blue: 0.95),
                 label: xLoc("本地快照"),
                 value: snapshotValue,
                 explain: xLoc("Time Machine 本地快照是「删了文件空间却没涨」的头号原因。逐个快照的体积需要系统特权才能估算——估不准就不显示。可在「维护」页请求系统立即瘦身快照。"))
            Spacer(minLength: 0)
        }
        .padding(.horizontal, XSpacing.xl)
        .padding(.bottom, XSpacing.s)
    }

    private var snapshotValue: String {
        guard let count = hub.ledger?.snapshotCount else { return xLoc("无法读取") }
        return count == 0 ? xLoc("无") : xLocF("%d 个 · 体积需特权估算", count)
    }

    private func chip(color: Color, label: String, value: String, explain: String) -> some View {
        LedgerChip(color: color, label: label, value: value, explain: explain)
    }
}

private struct LedgerChip: View {
    let color: Color
    let label: String
    let value: String
    let explain: String
    @State private var showInfo = false

    var body: some View {
        Button { showInfo.toggle() } label: {
            HStack(spacing: 5) {
                Circle().fill(color).frame(width: 7, height: 7)
                Text(label).font(XFont.caption).foregroundStyle(XColor.textSecondary)
                Text(value).font(XFont.captionEmphasis).foregroundStyle(XColor.textPrimary)
                    .monospacedDigit()
            }
            .padding(.horizontal, XSpacing.m).padding(.vertical, 5)
            .background(Capsule().fill(XColor.surface.opacity(0.7)))
            .overlay(Capsule().stroke(XColor.hairline, lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label + " · " + value)
        .popover(isPresented: $showInfo, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: XSpacing.s) {
                HStack(spacing: 6) {
                    Circle().fill(color).frame(width: 8, height: 8)
                    Text(label).xHeadline().foregroundStyle(XColor.textPrimary)
                }
                Text(explain).font(XFont.caption).foregroundStyle(XColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(XSpacing.m).frame(width: 320)
        }
    }
}

// MARK: - 类目 tile 卡

private struct CategoryTile: View {
    @ObservedObject var hub: SmartScanHubViewModel
    let category: SmartCategory
    /// 网格序号：全完成波次弹跳的 stagger 延迟（40ms/卡）依此计算（P6 · S1）。
    let index: Int
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false
    /// done 弹入（settle 弹簧自带过冲——先到先亮的「亮」）。
    @State private var pop = false
    /// 扫描中低饱和呼吸。
    @State private var breathe = false
    /// 全完成波次微弹跳。
    @State private var wave = false

    private var st: SmartScanHubViewModel.CategoryState { hub.state(category) }
    private var totalSize: Int64 { st.groups.reduce(0) { $0 + $1.totalSize } }
    private var itemCount: Int { st.groups.reduce(0) { $0 + $1.items.count } }
    private var selectedSize: Int64 { hub.selectedItems(category).reduce(0) { $0 + $1.size } }
    private var isScanning: Bool { st.status == .scanning || st.status == .pending }

    var body: some View {
        XCard {
            VStack(alignment: .leading, spacing: XSpacing.s) {
                HStack(alignment: .top, spacing: XSpacing.m) {
                    XIconTile(systemImage: category.icon, colors: category.colors, size: 40)
                        .opacity(st.included ? 1 : 0.35)
                        // 扫描中：低饱和呼吸（P6）；Reduce Motion 不呼吸。
                        .saturation(isScanning && !reduceMotion ? (breathe ? 0.55 : 0.85) : 1)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(xLoc(category.title)).xHeadline()
                            .foregroundStyle(st.included ? XColor.textPrimary : XColor.textTertiary)
                        Text(xLoc(category.subtitle)).font(XFont.caption).foregroundStyle(XColor.textTertiary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    // 整卡纳入/跳过（对标 CMM tile 勾选；跳过的卡不参与一键清理，但结果保留可再纳入）。
                    XCheckbox(isOn: st.included,
                              accessibilityLabel: xLocF("纳入一键清理：%@", xLoc(category.title))) {
                        withAnimation(XMotion.snappy) { hub.setIncluded(category, included: !st.included) }
                    }
                }
                Divider().opacity(0.6)
                statusBody
                    // done 时体积数字滚动到位（contentTransition 需要动画上下文才生效）。
                    .animation(reduceMotion ? nil : XMotion.settle, value: totalSize)
            }
        }
        .opacity(st.included ? 1 : 0.72)
        .scaleEffect(tileScale)
        .onAppear {
            withAnimation(XMotion.settle) { appeared = true }
            startBreathingIfNeeded()
        }
        .onChange(of: st.status) { syncMotion() }
        .onChange(of: hub.allDone) { waveIfAllDone() }
    }

    /// 三层缩放合成：入场 0.96→1；done 弹入由 settle 弹簧带过冲；波次 +0.03 微弹跳。
    private var tileScale: CGFloat {
        guard !reduceMotion else { return 1 }
        if !appeared { return 0.96 }
        if wave { return 1.03 }
        if st.status == .done && !pop { return 0.97 }   // 弹入起点（settle 动画驱动到 1）
        return 1
    }

    /// 状态变迁 → 动效同步：done 弹入一次；scanning 重启呼吸。
    private func syncMotion() {
        if st.status == .done, !pop, !reduceMotion {
            withAnimation(XMotion.settle) { pop = true }
        }
        if isScanning { pop = false }
        startBreathingIfNeeded()
    }

    private func startBreathingIfNeeded() {
        guard isScanning, !reduceMotion else { return }
        breathe = false
        withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) { breathe = true }
    }

    /// 全类目完成：六卡按序 40ms stagger 微弹跳（S1 的收束句点）。Reduce Motion 完全跳过。
    private func waveIfAllDone() {
        guard hub.allDone, !reduceMotion else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + Double(index) * 0.04) {
            withAnimation(XMotion.snappy) { wave = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.16) {
                withAnimation(XMotion.settle) { wave = false }
            }
        }
    }

    @ViewBuilder private var statusBody: some View {
        switch st.status {
        case .pending, .scanning:
            HStack(spacing: XSpacing.s) {
                XRingGauge(progress: 0, spinning: true, colors: category.colors, lineWidth: 2.5, size: 18) { EmptyView() }
                VStack(alignment: .leading, spacing: 1) {
                    Text(st.bytesFound > 0 ? st.bytesFound.formattedBytes : xLoc("正在扫描…"))
                        .font(XFont.bodyEmphasis).foregroundStyle(XColor.textPrimary)
                        .contentTransition(.numericText())
                    if !st.message.isEmpty {
                        Text(st.message).font(XFont.micro).foregroundStyle(XColor.textTertiary)
                            .lineLimit(1).truncationMode(.middle)
                    }
                }
                Spacer()
            }
            .frame(minHeight: 34)
        case .done:
            HStack(alignment: .firstTextBaseline, spacing: XSpacing.s) {
                if itemCount == 0 {
                    Image(systemName: "checkmark.seal.fill").foregroundStyle(XColor.success)
                    Text(xLoc("很干净")).font(XFont.bodyEmphasis).foregroundStyle(XColor.textSecondary)
                    Spacer()
                } else {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(totalSize.formattedBytes).xTitle().foregroundStyle(XColor.textPrimary)
                            .contentTransition(.numericText())
                        Text(selectedDetail)
                            .font(XFont.caption).foregroundStyle(XColor.textSecondary)
                    }
                    Spacer()
                    Button(xLoc("查看")) {
                        withAnimation(XMotion.settle) { hub.reviewing = category }
                    }
                    .buttonStyle(XSecondaryButtonStyle(compact: true))
                    .accessibilityLabel(xLocF("查看 %@ 结果", xLoc(category.title)))
                }
            }
            .frame(minHeight: 34)
        case let .failed(message):
            HStack(spacing: XSpacing.s) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(XColor.warning)
                Text(message).font(XFont.caption).foregroundStyle(XColor.textSecondary)
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button(xLoc("重试")) { hub.rescan(category) }
                    .buttonStyle(XSecondaryButtonStyle(compact: true))
            }
            .frame(minHeight: 34)
        }
    }

    private var selectedDetail: String {
        let sel = selectedSize
        if category.neverAutoSelect && sel == 0 {
            return xLocF("共 %d 项 · 请查看后手动勾选", itemCount)
        }
        return xLocF("共 %d 项", itemCount) + " · " + xLocF("已选 %@", sel.formattedBytes)
    }
}

// MARK: - 类目 Review 下钻（复用 ResultGroupCard 全套列表交互）

private struct CategoryReviewView: View {
    @ObservedObject var hub: SmartScanHubViewModel
    let category: SmartCategory

    private var st: SmartScanHubViewModel.CategoryState { hub.state(category) }
    private var totalSize: Int64 { st.groups.reduce(0) { $0 + $1.totalSize } }

    var body: some View {
        VStack(spacing: 0) {
            reviewHeader
            if st.groups.isEmpty {
                XEmptyState(systemImage: "checkmark.seal.fill",
                            title: xLoc("很干净"),
                            subtitle: xLoc("没有发现可清理的项目。"), kind: .success)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: XSpacing.m) {
                        ForEach(Array(st.groups.enumerated()), id: \.element.id) { idx, group in
                            ResultGroupCard(
                                group: group,
                                index: idx,
                                allSelected: hub.groupSelectionState(category, group: group),
                                onToggleGroup: { hub.setGroup(category, groupID: group.id, selected: $0) },
                                onToggleItem: { hub.toggleItem(category, groupID: group.id, itemID: $0) },
                                onIgnoreItem: { hub.ignore(category, groupID: group.id, itemID: $0) })
                        }
                    }
                    .padding(XSpacing.xl)
                }
            }
        }
    }

    private var reviewHeader: some View {
        HStack(spacing: XSpacing.m) {
            Button {
                withAnimation(XMotion.settle) { hub.reviewing = nil }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left")
                    Text(xLoc("返回总览"))
                }
            }
            .buttonStyle(XSecondaryButtonStyle(compact: true))
            .keyboardShortcut(.cancelAction)
            XIconTile(systemImage: category.icon, colors: category.colors, size: 32)
            VStack(alignment: .leading, spacing: 1) {
                Text(xLoc(category.title)).xHeadline().foregroundStyle(XColor.textPrimary)
                Text(xLocF("共发现 %d 项 · 可清理", st.groups.reduce(0) { $0 + $1.items.count }) + " · " + totalSize.formattedBytes)
                    .font(XFont.caption).foregroundStyle(XColor.textSecondary)
            }
            Spacer()
            if category == .duplicates {
                // 重复文件带换根入口（与独立页 PathBox 同源，换根即重扫该类目）。
                Button(xLoc("更换文件夹…")) { pickDuplicatesFolder() }
                    .buttonStyle(XSecondaryButtonStyle(compact: true))
                Text(hub.duplicatesRootURL.lastPathComponent)
                    .font(XFont.caption).foregroundStyle(XColor.textTertiary)
                    .lineLimit(1)
            }
            Button { hub.rescan(category) } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.plain).foregroundStyle(XColor.textSecondary)
                .accessibilityLabel(xLoc("重新扫描"))
                .disabled(st.status == .scanning)
        }
        .padding(.horizontal, XSpacing.xl)
        .padding(.vertical, XSpacing.l)
    }

    private func pickDuplicatesFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = hub.duplicatesRootURL
        if panel.runModal() == .OK, let url = panel.url {
            hub.setDuplicatesRoot(url)
        }
    }
}
