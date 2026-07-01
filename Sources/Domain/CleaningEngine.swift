import Foundation

/// 清理引擎：执行清理计划。
/// 默认所有删除走废纸篓（可恢复）；每一项删除前都经过 SafetyEngine 校验。
public actor CleaningEngine {
    private let safety: SafetyEngine
    private let fs: FileSystemService
    private let privileged: PrivilegedCleaningService?

    public init(safety: SafetyEngine, fs: FileSystemService, privileged: PrivilegedCleaningService? = nil) {
        self.safety = safety
        self.fs = fs
        self.privileged = privileged
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

            if item.requiresHelper {
                guard let privileged else {
                    failures.append(CleaningFailure(url: item.url, reason: "需要安装并批准特权助手"))
                    continue
                }
                guard plan.intent == .permanent else {
                    failures.append(CleaningFailure(url: item.url, reason: "管理员权限项目当前仅支持明确确认后的彻底删除"))
                    continue
                }
                let report = await privileged.removeProtected([item.url])
                // 按 path 字符串比较，避免目录尾斜杠/directory-hint 差异导致 URL== 失配、
                // 把"部分成功但已消失"的失败误记为成功。
                let failedPaths = Set(report.failures.map { $0.standardizedFileURL.path })
                if failedPaths.contains(item.url.standardizedFileURL.path) {
                    failures.append(CleaningFailure(url: item.url, reason: "特权助手拒绝或删除失败"))
                } else {
                    // 直接采用助手实测释放字节，避免用扫描期估算 max() 虚高统计。
                    reclaimed += report.freedBytes > 0 ? report.freedBytes : item.size
                    removed += 1
                }
                progress(ScanProgress(
                    fraction: total > 0 ? Double(index + 1) / Double(total) : nil,
                    message: item.displayName,
                    bytesFound: reclaimed
                ))
                continue
            }

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
