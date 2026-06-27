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

        // 2. 同大小者先做头尾哈希快速筛，命中再做全量哈希确认（杜绝中段不同被误判 → 防删错）
        var groups: [ScanResultGroup] = []
        for (size, urls) in bySize where urls.count > 1 {
            if Task.isCancelled { break }
            // 2a. 头尾哈希快速分桶
            var byPartial: [String: [URL]] = [:]
            for url in urls {
                if let h = partialHash(url, size: size) {
                    byPartial[h, default: []].append(url)
                }
            }
            // 2b. 仅对头尾相同者做全量哈希确认（只有逐字节内容一致才算重复）
            var byHash: [String: [URL]] = [:]
            for (_, candidates) in byPartial where candidates.count > 1 {
                for url in candidates {
                    if Task.isCancelled { break }
                    if let full = fullHash(url) {
                        byHash[full, default: []].append(url)
                    }
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
                let cloneNote = anyAreClones(dupURLs) ? " · 含 APFS 克隆，删除可能不释放空间" : ""
                groups.append(ScanResultGroup(
                    id: hash,
                    title: "\(sorted[0].lastPathComponent) · \(dupURLs.count) 份",
                    description: "可释放约 \(wasted.formattedBytes)（保留 1 份）\(cloneNote)",
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

    /// 全量逐块哈希：只有内容逐字节一致才判为重复，杜绝头尾相同中段不同的误删。
    private func fullHash(_ url: URL, chunk: Int = 1 << 20) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            if Task.isCancelled { return nil }
            guard let data = try? handle.read(upToCount: chunk), !data.isEmpty else { break }
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// 这组内是否存在 APFS 克隆（写时复制）：克隆彼此 fileResourceIdentifier 不同但共享底层存储，
    /// 删除其一通常不立刻释放空间。用「分配大小远小于逻辑大小」作保守启发式提示。
    private func anyAreClones(_ urls: [URL]) -> Bool {
        for url in urls {
            guard let vals = try? url.resourceValues(forKeys: [.fileSizeKey, .totalFileAllocatedSizeKey]),
                  let logical = vals.fileSize, logical > 0,
                  let allocated = vals.totalFileAllocatedSize else { continue }
            // 克隆/稀疏文件：实际分配明显小于逻辑大小
            if allocated < logical / 2 { return true }
        }
        return false
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
