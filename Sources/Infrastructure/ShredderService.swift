import Foundation
import Domain

/// 文件粉碎：多次随机覆写后删除，尽量降低被恢复的可能。
///
/// 诚实说明：在 SSD / APFS（写时复制 + 磨损均衡）上，覆写**不保证**原始数据块被真正抹除；
/// 对这类卷，真正可靠的做法是全盘 FileVault 加密。本功能对机械硬盘/外置盘更有意义，
/// UI 会如实告知。每个目标删除前仍过 SafetyEngine 红线。
public struct ShredderService: Sendable {
    private let safety: SafetyEngine
    private let passes: Int

    public init(safety: SafetyEngine, passes: Int = 3) {
        self.safety = safety
        self.passes = max(1, passes)
    }

    public struct Result: Sendable {
        public let shredded: Int
        public let failed: [URL]
        public let freedBytes: Int64
    }

    public func shred(_ urls: [URL], progress: @escaping ProgressHandler = { _ in }) async -> Result {
        var shredded = 0
        var failed: [URL] = []
        var freed: Int64 = 0
        let total = urls.count
        for (idx, url) in urls.enumerated() {
            if Task.isCancelled { break }
            progress(ScanProgress(fraction: total > 0 ? Double(idx) / Double(total) : nil,
                                  message: url.lastPathComponent, bytesFound: freed))
            var freedForItem: Int64 = 0
            if overwriteAndRemove(url, freed: &freedForItem) {
                shredded += 1; freed += freedForItem
            } else {
                failed.append(url)
            }
        }
        return Result(shredded: shredded, failed: failed, freedBytes: freed)
    }

    /// 对单个文件多轮随机覆写后删除；目录则递归。
    /// 关键安全约束（对抗复核发现）：
    /// - **每一层**（包括递归子项）都过红线校验，绝不只校顶层；用 .trash 语义取基础红线
    ///   （系统区/其他用户/云同步/钥匙串/图库包/应用数据根一律拒），但允许用户显式选定并二次确认的
    ///   自有内容文件被粉碎——这正是粉碎功能的用途。
    /// - **绝不跟随符号链接**：遇到软链只删链接本身，绝不进入其目标覆写/删除（否则会穿透删掉受保护目标）。
    private func overwriteAndRemove(_ url: URL, freed: inout Int64) -> Bool {
        let fm = FileManager.default
        // 基础红线：系统/其他用户/云同步/钥匙串/图库包/数据根一律拒（用 .trash 取不含内容目录收紧的基础判定）
        guard safety.verify(url, intent: .trash).isAllowed else {
            XicoLog.clean.error("粉碎被红线拒绝: \(url.path, privacy: .public)")
            return false
        }
        let rv = try? url.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey, .fileSizeKey])
        // 符号链接：只删链接本身，绝不跟随进入目标
        if rv?.isSymbolicLink == true {
            return (try? fm.removeItem(at: url)) != nil
        }
        if rv?.isDirectory == true {
            let children = (try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil,
                                                        options: [])) ?? []
            var ok = true
            for child in children where !overwriteAndRemove(child, freed: &freed) { ok = false }
            return ok && ((try? fm.removeItem(at: url)) != nil)
        }
        overwriteFile(url)
        do {
            try fm.removeItem(at: url)
            freed += Int64(rv?.fileSize ?? 0)
            return true
        } catch {
            XicoLog.clean.error("粉碎删除失败: \(url.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    private func overwriteFile(_ url: URL) {
        guard let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size > 0,
              let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        let chunk = 1 << 20   // 1MB 随机块
        for _ in 0..<passes {
            if Task.isCancelled { return }
            try? handle.seek(toOffset: 0)
            var remaining = size
            while remaining > 0 {
                let n = min(chunk, remaining)
                var bytes = [UInt8](repeating: 0, count: n)
                for i in 0..<n { bytes[i] = UInt8.random(in: 0...255) }
                try? handle.write(contentsOf: Data(bytes))
                remaining -= n
            }
            try? handle.synchronize()
        }
    }
}
