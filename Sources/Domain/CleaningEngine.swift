import Foundation

/// 清理引擎：执行清理计划。
/// 默认所有删除走废纸篓（可恢复）；每一项删除前都经过 SafetyEngine 校验。
public actor CleaningEngine {
    private let safety: SafetyEngine
    private let fs: FileSystemService

    public init(safety: SafetyEngine, fs: FileSystemService) {
        self.safety = safety
        self.fs = fs
    }

    public func execute(_ plan: CleaningPlan, progress: @escaping ProgressHandler = { _ in }) async -> CleaningReport {
        var reclaimed: Int64 = 0
        var removed = 0
        var failures: [CleaningFailure] = []
        var restorable: [RestorableItem] = []

        let total = plan.items.count
        for (index, item) in plan.items.enumerated() {
            if Task.isCancelled { break }

            // 安全闸门：任何删除前必过
            let verdict = safety.verify(item.url, intent: plan.intent)
            guard verdict.isAllowed else {
                if case let .deny(reason) = verdict {
                    failures.append(CleaningFailure(url: item.url, reason: reason))
                }
                continue
            }

            guard fs.exists(item.url) else { continue }

            do {
                switch plan.intent {
                case .trash:
                    let trashed = try fs.trash(item.url)
                    restorable.append(RestorableItem(originalURL: item.url, trashedURL: trashed))
                case .permanent:
                    try fs.remove(item.url)
                }
                reclaimed += item.size
                removed += 1
            } catch {
                failures.append(CleaningFailure(url: item.url, reason: error.localizedDescription))
            }

            progress(ScanProgress(
                fraction: total > 0 ? Double(index + 1) / Double(total) : nil,
                message: item.displayName,
                bytesFound: reclaimed
            ))
        }

        return CleaningReport(removedCount: removed, reclaimedBytes: reclaimed, failures: failures, restorable: restorable)
    }

    /// 撤销上一次清理：把废纸篓中的项移回原位
    public func undo(_ report: CleaningReport) async -> Int {
        var restored = 0
        for item in report.restorable {
            do {
                try fs.restore(item)
                restored += 1
            } catch {
                continue
            }
        }
        return restored
    }
}
