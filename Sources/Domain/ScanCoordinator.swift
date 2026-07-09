import Foundation

/// 扫描编排：并发运行多个模块，聚合结果（用于智能扫描）。
public actor ScanCoordinator {
    private let modules: [ScannerModule]

    public init(modules: [ScannerModule]) {
        self.modules = modules
    }

    /// 运行全部模块并返回每个模块的结果（并发执行）。
    /// 转发各模块内部的细粒度进度（正在扫描的项 + 累计大小），让扫描"看得见在干活"。
    /// 若**所有**模块都失败，则抛出首个错误——绝不把失败静默成空结果（避免伪装成"很干净"）。
    public func scanAll(progress: @escaping ProgressHandler = { _ in },
                        onModuleFailure: @escaping @Sendable (String) -> Void = { _ in }) async throws -> [ScanResult] {
        let total = modules.count
        let counter = Counter()
        let agg = ProgressAggregator()
        let errors = ErrorCollector()

        let results = await withTaskGroup(of: ScanResult?.self) { group in
            for module in modules {
                let title = module.metadata.title
                group.addTask {
                    var result: ScanResult?
                    do {
                        result = try await module.scan { p in
                            let running = agg.update(title, p.bytesFound)
                            progress(ScanProgress(message: p.message, bytesFound: running))
                        }
                    } catch {
                        await errors.add(error)
                        onModuleFailure(title)   // 部分模块失败：上报模块名，供 UI 降级横幅提示
                    }
                    let done = await counter.increment()
                    progress(ScanProgress(
                        fraction: total > 0 ? Double(done) / Double(total) : nil,
                        message: title,
                        // 完成时提交取 max：失败模块（final=0）或最终汇总小于流式峰值时，
                        // 都不会把该模块槽位下调，聚合总量因此单调不回退。
                        bytesFound: agg.commit(title, result?.totalReclaimable ?? 0)
                    ))
                    return result
                }
            }
            var results: [ScanResult] = []
            for await result in group {
                if let result { results.append(result) }
            }
            return results
        }
        // 部分成功就返回部分结果；全部失败才上抛错误（让上层显示失败态而非空态）
        if results.isEmpty, let first = await errors.first {
            throw first
        }
        return ScanResultDeduper.deduplicate(results)
    }
}

/// 智能扫描会聚合多个模块；不同模块可能命中同一路径或父子路径。
/// 去重原则：真父子重叠时保留**父级**（超集），让整棵子树只被计量/清理一次——
/// 保父而非保子，避免少算可释放空间、漏清子树里的其它文件；
/// 仅当路径**完全相同**时，才让更具体 / 更高风险的记录胜出。
private enum ScanResultDeduper {
    private struct Candidate {
        let id: UUID
        let path: String
        let depth: Int
        let risk: Int
        let order: Int
    }

    static func deduplicate(_ results: [ScanResult]) -> [ScanResult] {
        var candidates: [Candidate] = []
        var order = 0
        for result in results {
            for group in result.groups {
                for item in group.items {
                    let path = normalizedPath(item.url)
                    candidates.append(Candidate(
                        id: item.id,
                        path: path,
                        depth: URL(fileURLWithPath: path).pathComponents.count,
                        risk: riskRank(item.safety),
                        order: order
                    ))
                    order += 1
                }
            }
        }

        var accepted: [Candidate] = []
        // 按路径索引已接受项：因候选按 depth 升序处理，任何已接受项都不比当前更深，
        // 故「重叠」必为「某已接受项是当前项的祖先（或同路径）」——沿当前项的父链上溯查表即可，
        // 每候选 O(depth) 而非 O(accepted)，去掉了对全体已接受项的线性扫描（原 O(n²)）。
        var acceptedByPath: [String: Candidate] = [:]
        // 被父超集吞掉的子项，若风险更高，则把父项的默认勾选「提级」到该风险——
        // 记录 父id → 被吞子项的最高风险（仅在高于父项自身风险时）。
        var elevatedRisk: [UUID: Int] = [:]
        for candidate in candidates.sorted(by: sort) {
            // 父级（更浅）先入选；其下任一子项与已接受的父级重叠 → 跳过，被父超集覆盖。
            // 完全同路径由 sort 排定的更具体 / 更高风险者先到并胜出，重复者在此被跳过。
            if let parent = nearestAcceptedAncestor(of: candidate.path, in: acceptedByPath) {
                // 对抗复核 P3：更高风险的子树绝不能被「安全父」静默扫入而不被展示/确认。
                // 保留「保父超集」的去重策略，但把父项的默认勾选下调到子项风险，
                // 使 .caution/.risky 子树至少不再被默认勾选、需用户显式确认。
                if candidate.risk > parent.risk {
                    elevatedRisk[parent.id] = max(elevatedRisk[parent.id] ?? parent.risk, candidate.risk)
                }
                continue
            }
            accepted.append(candidate)
            acceptedByPath[candidate.path] = candidate
        }

        let acceptedIDs = Set(accepted.map(\.id))
        return results.compactMap { result in
            var result = result
            result.groups = result.groups.compactMap { group in
                var group = group
                group.items = group.items.compactMap { item -> CleanableItem? in
                    guard acceptedIDs.contains(item.id) else { return nil }
                    if let rank = elevatedRisk[item.id], rank > riskRank(item.safety) {
                        return elevate(item, to: level(forRank: rank))
                    }
                    return item
                }
                return group.items.isEmpty ? nil : group
            }
            return result.groups.isEmpty ? nil : result
        }
    }

    /// 以提级后的风险重建同一项：保留 id/尺寸/路径等，仅提升 safety 并**取消默认勾选**，
    /// 强制用户对被吞入的更高风险子树显式确认（提级绝不改变去重后的计量对象，只改默认选择）。
    private static func elevate(_ item: CleanableItem, to level: SafetyLevel) -> CleanableItem {
        CleanableItem(id: item.id, url: item.url, displayName: item.displayName,
                      detail: item.detail, size: item.size, safety: level,
                      isSelected: false, requiresHelper: item.requiresHelper, note: item.note)
    }

    private static func level(forRank rank: Int) -> SafetyLevel {
        switch rank {
        case 0: return .safe
        case 1: return .caution
        default: return .risky
        }
    }

    private static func sort(_ lhs: Candidate, _ rhs: Candidate) -> Bool {
        // 父级（更浅）优先入选：真父子重叠时保留父超集，子项被其覆盖而跳过（不再丢父保子）。
        if lhs.depth != rhs.depth { return lhs.depth < rhs.depth }
        // 同深度（含完全同路径）：更高风险的记录胜出，再按发现顺序稳定排序。
        if lhs.risk != rhs.risk { return lhs.risk > rhs.risk }
        return lhs.order < rhs.order
    }

    private static func riskRank(_ level: SafetyLevel) -> Int {
        switch level {
        case .safe: return 0
        case .caution: return 1
        case .risky: return 2
        }
    }

    private static func normalizedPath(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }

    /// 沿 `path` 的父链自身而上逐级查表，返回最近的已接受祖先（含同路径），无则 nil。
    /// 每级 O(1) 字典命中，整体 O(depth)。上溯到形如 "/Users" 即止——与旧 `isInsideOrEqual`
    /// 对根 "/" 的处理一致（根 "/" 因拼接 "//" 从不被视作祖先），行为不变。
    private static func nearestAcceptedAncestor(of path: String, in accepted: [String: Candidate]) -> Candidate? {
        var current = path
        while true {
            if let c = accepted[current] { return c }
            guard let slash = current.lastIndex(of: "/"), slash != current.startIndex else { return nil }
            current = String(current[current.startIndex..<slash])
        }
    }
}

/// 收集并发模块的错误
private actor ErrorCollector {
    private(set) var first: Error?
    func add(_ error: Error) { if first == nil { first = error } }
}

/// 并发安全的计数器
private actor Counter {
    private var value = 0
    func increment() -> Int { value += 1; return value }
}

/// 跨并发模块聚合"已发现字节"：各模块上报自己的累计值，求和即全局累计（单调增长）。
private final class ProgressAggregator: @unchecked Sendable {
    private let lock = NSLock()
    private var perModule: [String: Int64] = [:]
    func update(_ module: String, _ value: Int64) -> Int64 {
        lock.lock(); defer { lock.unlock() }
        perModule[module] = value
        return perModule.values.reduce(0, +)
    }
    /// 完成时提交模块最终值：对既有槽位取 max，绝不下调——避免失败模块把流式已上报的
    /// 累计值清零、或最终汇总小于扫描峰值时，聚合字节数中途回跳（非单调）。
    func commit(_ module: String, _ value: Int64) -> Int64 {
        lock.lock(); defer { lock.unlock() }
        perModule[module] = max(perModule[module] ?? 0, value)
        return perModule.values.reduce(0, +)
    }
}
