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
    public func scanAll(progress: @escaping ProgressHandler = { _ in }) async throws -> [ScanResult] {
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
                    }
                    let done = await counter.increment()
                    progress(ScanProgress(
                        fraction: total > 0 ? Double(done) / Double(total) : nil,
                        message: title,
                        bytesFound: agg.update(title, result?.totalReclaimable ?? 0)
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
/// 去重时保留更具体的路径，避免同一批文件在总量和清理计划里被重复计算。
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
        for candidate in candidates.sorted(by: sort) {
            if accepted.contains(where: { overlaps(candidate.path, $0.path) }) { continue }
            accepted.append(candidate)
        }

        let acceptedIDs = Set(accepted.map(\.id))
        return results.compactMap { result in
            var result = result
            result.groups = result.groups.compactMap { group in
                var group = group
                group.items.removeAll { !acceptedIDs.contains($0.id) }
                return group.items.isEmpty ? nil : group
            }
            return result.groups.isEmpty ? nil : result
        }
    }

    private static func sort(_ lhs: Candidate, _ rhs: Candidate) -> Bool {
        if lhs.depth != rhs.depth { return lhs.depth > rhs.depth }
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

    private static func overlaps(_ a: String, _ b: String) -> Bool {
        isInsideOrEqual(a, b) || isInsideOrEqual(b, a)
    }

    private static func isInsideOrEqual(_ target: String, _ root: String) -> Bool {
        target == root || target.hasPrefix(root + "/")
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
}
