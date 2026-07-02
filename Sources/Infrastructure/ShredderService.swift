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
            // 粉碎是彻底删除：必须过 permanent 红线（内容目录内的文件因此会被拒——安全）
            guard safety.verify(url, intent: .permanent).isAllowed else {
                XicoLog.clean.error("粉碎被红线拒绝: \(url.path, privacy: .public)")
                failed.append(url); continue
            }
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            if overwriteAndRemove(url) {
                shredded += 1; freed += Int64(size)
            } else {
                failed.append(url)
            }
        }
        return Result(shredded: shredded, failed: failed, freedBytes: freed)
    }

    /// 对单个文件多轮随机覆写后删除；目录则递归对其中文件覆写后整体删除。
    private func overwriteAndRemove(_ url: URL) -> Bool {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { return false }
        if isDir.boolValue {
            let children = (try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? []
            var ok = true
            for child in children where !overwriteAndRemove(child) { ok = false }
            return ok && ((try? fm.removeItem(at: url)) != nil)
        }
        overwriteFile(url)
        do { try fm.removeItem(at: url); return true }
        catch {
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
