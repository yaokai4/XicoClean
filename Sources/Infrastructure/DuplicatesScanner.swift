import Foundation
import CryptoKit
import Domain

/// 重复文件查找：按大小分组 → 头尾哈希确认 → 输出重复组。
/// 去重硬链接（同 inode），降低误判；每组默认保留一个、勾选其余待删。
public struct DuplicatesScanner: Sendable {
    private let fs: FileSystemService
    private let safety: SafetyEngine
    public let root: URL
    private let minSize: Int64
    private let maxGroups: Int

    public init(fs: FileSystemService, safety: SafetyEngine, root: URL,
                minSizeBytes: Int64 = 1 * 1024 * 1024, maxGroups: Int = 200) {
        self.fs = fs
        self.safety = safety
        self.root = root
        self.minSize = minSizeBytes
        self.maxGroups = maxGroups
    }

    public func scan(progress: @escaping ProgressHandler) async -> ScanResult {
        // 1. 按大小分组（同时按 inode 去重硬链接）
        var bySize: [Int64: [URL]] = [:]
        var seenInodes = Set<String>()
        var scanned: Int64 = 0

        for await entry in fs.deepEnumerate(root, includeFiles: true) {
            if Task.isCancelled { break }
            guard !entry.isDirectory, entry.size >= minSize else { continue }
            guard safety.verify(entry.url, intent: .trash).isAllowed else { continue }
            if let id = inodeKey(entry.url) {
                if seenInodes.contains(id) { continue }
                seenInodes.insert(id)
            }
            bySize[entry.size, default: []].append(entry.url)
            scanned += entry.size
            progress(ScanProgress(message: entry.url.lastPathComponent, bytesFound: 0))
        }

        // 2. 同大小者做头尾哈希
        var groups: [ScanResultGroup] = []
        for (size, urls) in bySize where urls.count > 1 {
            if Task.isCancelled { break }
            var byHash: [String: [URL]] = [:]
            for url in urls {
                if let h = partialHash(url, size: size) {
                    byHash[h, default: []].append(url)
                }
            }
            for (hash, dupURLs) in byHash where dupURLs.count > 1 {
                let sorted = dupURLs.sorted { $0.path.count < $1.path.count }
                var items: [CleanableItem] = []
                for (idx, url) in sorted.enumerated() {
                    // 默认保留第一个（路径最短者），其余勾选待删
                    items.append(CleanableItem(url: url, displayName: url.lastPathComponent,
                                               detail: url.path, size: size, safety: .caution,
                                               isSelected: idx != 0))
                }
                let wasted = Int64(dupURLs.count - 1) * size
                groups.append(ScanResultGroup(
                    id: hash,
                    title: "\(sorted[0].lastPathComponent) · \(dupURLs.count) 份",
                    description: "可释放 \(wasted.formattedBytes)（保留 1 份）",
                    systemImage: "doc.on.doc", safety: .caution, items: items))
            }
        }

        groups.sort { $0.selectedSize > $1.selectedSize }
        if groups.count > maxGroups { groups = Array(groups.prefix(maxGroups)) }
        return ScanResult(moduleID: .duplicates, groups: groups)
    }

    private func inodeKey(_ url: URL) -> String? {
        guard let vals = try? url.resourceValues(forKeys: [.fileResourceIdentifierKey]),
              let id = vals.fileResourceIdentifier else { return nil }
        return "\(id)"
    }

    private func partialHash(_ url: URL, size: Int64) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let chunk = 16 * 1024
        var hasher = SHA256()
        let head = (try? handle.read(upToCount: chunk)) ?? Data()
        hasher.update(data: head)
        if size > Int64(chunk * 2) {
            try? handle.seek(toOffset: UInt64(size) - UInt64(chunk))
            let tail = (try? handle.read(upToCount: chunk)) ?? Data()
            hasher.update(data: tail)
        }
        withUnsafeBytes(of: size) { hasher.update(data: Data($0)) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
