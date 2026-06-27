import Foundation

/// 扫描编排：并发运行多个模块，聚合结果（用于智能扫描）。
public actor ScanCoordinator {
    private let modules: [ScannerModule]

    public init(modules: [ScannerModule]) {
        self.modules = modules
    }

    /// 运行全部模块并返回每个模块的结果（并发执行）。
    /// 转发各模块内部的细粒度进度（正在扫描的项 + 累计大小），让扫描"看得见在干活"。
    public func scanAll(progress: @escaping ProgressHandler = { _ in }) async -> [ScanResult] {
        let total = modules.count
        let counter = Counter()
        let agg = ProgressAggregator()

        return await withTaskGroup(of: ScanResult?.self) { group in
            for module in modules {
                let title = module.metadata.title
                group.addTask {
                    let result = try? await module.scan { p in
                        let running = agg.update(title, p.bytesFound)
                        progress(ScanProgress(message: p.message, bytesFound: running))
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
    }
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
