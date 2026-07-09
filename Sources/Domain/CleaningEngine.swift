import Foundation
import os

/// 清理引擎：执行清理计划。
/// 默认所有删除走废纸篓（可恢复）；每一项删除前都经过 SafetyEngine 校验。
public actor CleaningEngine {
    private static let log = Logger(subsystem: "com.xico.app", category: "clean")
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

            // 清空废纸篓的特例（对抗复核 P3）：废纸篓内的叶子符号链接（含悬空链）——直接删链接本身，
            // 绝不解析/跟随其目标。通用红线会先把软链解析到目标再判定，从而把「指向内容目录/红线区的
            // 废纸篓软链」误拒，导致废纸篓清不空；而删链接本身（removeItem 不跟随）从不触及目标，是安全的。
            // 授权门槛：路径字面量确实位于 .Trash/.Trashes 之内（未解析，不可被软链伪造）——这本就是
            // 家目录 .permanent 白名单区。仅此特例，普通清理/卸载的叶子软链仍走下方从严红线。
            if plan.intent == .permanent, Self.isInsideTrash(item.url), Self.isSymlink(item.url) {
                do {
                    try fs.remove(item.url)   // removeItem 删软链本身，不跟随目标
                    reclaimed += item.size
                    removed += 1
                } catch {
                    Self.log.error("清空废纸篓删除软链失败 \(item.url.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
                    failures.append(CleaningFailure(url: item.url, reason: error.localizedDescription))
                }
                progress(ScanProgress(
                    fraction: total > 0 ? Double(index + 1) / Double(total) : nil,
                    message: item.displayName,
                    bytesFound: reclaimed
                ))
                continue
            }

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

            // TOCTOU 收窄：扫描→清理可能间隔数分钟，删除前紧邻再校一次红线，
            // 若期间该路径变成受保护目标（如中途被换成指向红线区的链接）即拒绝。
            //
            // 与 HelperFileRemover 的非对称说明：root 助手用 openat(O_NOFOLLOW) 从白名单根
            // 逐级锚定下钻、unlinkat 锚定删除，内核级杜绝「把父目录换成软链」的 TOCTOU 穿透；
            // 用户级删除经 FileSystemService（NSFileManager / trash API）执行，拿不到父目录 fd
            // 做锚定。故这里以「紧邻复校 + 解析符号链接后再校一次 + 叶子若已变成软链则拒绝彻底删除」
            // 把窗口收到最小——宁可漏删，也绝不顺链误删链外目标（fail-closed）。
            let resolved = item.url.resolvingSymlinksInPath()
            guard safety.verify(item.url, intent: plan.intent).isAllowed,
                  safety.verify(resolved, intent: plan.intent).isAllowed else {
                Self.log.error("清理前复校被拒（路径已变化）: \(item.url.path, privacy: .public)")
                failures.append(CleaningFailure(url: item.url, reason: "删除前安全复校未通过（路径可能已变化）"))
                continue
            }
            // 彻底删除额外从严：叶子在复校后若已是符号链接（可能是刚被换入的换链攻击），一律拒绝。
            if plan.intent == .permanent, Self.isSymlink(item.url) {
                Self.log.error("彻底删除前检测到路径已变为符号链接，拒绝: \(item.url.path, privacy: .public)")
                failures.append(CleaningFailure(url: item.url, reason: "删除前检测到路径已变为符号链接，已拒绝彻底删除"))
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
                Self.log.error("删除失败 \(item.url.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
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

    /// 撤销上一次清理：把废纸篓中的项移回原位。
    /// 返回已恢复数与**未能恢复的清单**——废纸篓被清空 / 文件被移动 / 卷已卸载时，
    /// 上层据此保留可重试入口并如实告知用户，绝不静默假装成功。
    public func undo(_ report: CleaningReport) async -> UndoResult {
        var restored = 0
        var failed: [RestorableItem] = []
        for item in report.restorable {
            do {
                try fs.restore(item)
                restored += 1
            } catch {
                Self.log.error("撤销恢复失败 \(item.originalURL.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
                failed.append(item)
            }
        }
        return UndoResult(restored: restored, failed: failed)
    }

    /// 叶子自身是否为符号链接（lstat 语义，不跟随）。
    private static func isSymlink(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink ?? false
    }

    /// 路径字面量是否**锚定**于真正的废纸篓根内：家目录 `~/.Trash`，或卷级 `/Volumes/<卷>/.Trashes/<uid>`，
    /// 或启动卷根 `/.Trashes/<uid>`。**刻意不解析符号链接**——用未解析的字面分量判定「这一项本身住在
    /// 废纸篓里」，软链无法把自身字面路径伪造成锚定于这些根之下。
    ///
    /// 收紧（对抗复核 P3）：此前仅要求分量中**含**任一名为 `.trash`/`.trashes` 的段，于是任意位置一个
    /// 自造的 `.Trash/` 目录即可命中，从而触达上方「废纸篓软链直接删链接」的 verify 豁免分支。现改为要求
    /// 路径锚定于上述真实废纸篓根之下，杜绝该豁免被任意命名目录触发（fail-closed，宁可漏删不误开豁免）。
    private static func isInsideTrash(_ url: URL) -> Bool {
        let comps = url.standardizedFileURL.pathComponents.map { $0.lowercased() }
        // 家目录废纸篓：<home>/.Trash/<项> —— home 之后紧邻的分量必须是 .trash。
        let home = FileManager.default.homeDirectoryForCurrentUser
            .standardizedFileURL.pathComponents.map { $0.lowercased() }
        if comps.count > home.count,
           Array(comps.prefix(home.count)) == home,
           comps[home.count] == ".trash" {
            return true
        }
        // 卷级废纸篓：/Volumes/<卷>/.Trashes/<uid>/<项>，或启动卷 /.Trashes/<uid>/<项>。
        // .trashes 必须紧邻卷根（/Volumes/<卷> 之后，即 index 3）或文件系统根（index 1），
        // 且其后至少还有一段 uid，方才认定——防止 a/b/.trashes/... 这类任意深度的自造目录命中。
        if let ti = comps.firstIndex(of: ".trashes") {
            let validAnchor = (ti == 1) || (ti == 3 && comps[1] == "volumes")
            if validAnchor && comps.count > ti + 1 { return true }
        }
        return false
    }
}
