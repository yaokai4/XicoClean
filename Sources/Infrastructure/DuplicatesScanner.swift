import Foundation
import DesignSystem
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
        // 2a. 并发头尾哈希（4 路，与下方全量哈希同一条流水线）：把所有「同大小且 >1 份」桶内的
        //     文件摊平后并发读头尾，让磁盘 I/O 重叠——避免这一阶段串行读成为隐形瓶颈。
        var partialTargets: [(url: URL, size: Int64)] = []
        for (size, urls) in bySize where urls.count > 1 {
            for url in urls { partialTargets.append((url, size)) }
        }
        let partialed = await withTaskGroup(of: (URL, Int64, String?).self) { group -> [(URL, Int64, String)] in
            let lanes = 4
            var iterator = partialTargets.makeIterator()
            func addNext() {
                guard let c = iterator.next() else { return }
                group.addTask { (c.url, c.size, self.partialHash(c.url, size: c.size)) }
            }
            for _ in 0..<lanes { addNext() }
            var out: [(URL, Int64, String)] = []
            for await (url, size, hash) in group {
                if Task.isCancelled { break }
                if let hash { out.append((url, size, hash)) }
                addNext()
            }
            return out
        }
        // 按 (size, 头尾哈希) 分组，仅保留仍 >1 份的组进入全量确认（partialHash 已把 size 混入摘要，
        // 但显式带上 size 作键更稳妥）。
        var fullHashCandidates: [(url: URL, size: Int64)] = []
        var byPartialKey: [String: [(url: URL, size: Int64)]] = [:]
        for (url, size, hash) in partialed {
            byPartialKey["\(size)-\(hash)", default: []].append((url, size))
        }
        for (_, candidates) in byPartialKey where candidates.count > 1 {
            fullHashCandidates.append(contentsOf: candidates)
        }

        // 2b. 并发全量哈希（4 路），按完成计数上报进度，消除"哈希阶段像卡死"的观感。
        let total = fullHashCandidates.count
        let hashed = await withTaskGroup(of: (URL, Int64, String?).self) { group -> [(URL, Int64, String)] in
            let lanes = 4
            var iterator = fullHashCandidates.makeIterator()
            var inFlight = 0
            func addNext() {
                guard let c = iterator.next() else { return }
                inFlight += 1
                group.addTask { (c.url, c.size, self.fullHash(c.url)) }
            }
            for _ in 0..<lanes { addNext() }
            var out: [(URL, Int64, String)] = []
            var done = 0
            for await (url, size, hash) in group {
                done += 1
                progress(ScanProgress(fraction: total > 0 ? Double(done) / Double(total) : nil,
                                      message: xLocF("校验 %@", url.lastPathComponent), bytesFound: scanned))
                if let hash { out.append((url, size, hash)) }
                addNext()
            }
            return out
        }

        // 2c. 按 (size, 全量哈希) 分组：只有逐字节内容一致才算重复。
        var groups: [ScanResultGroup] = []
        var byHashKey: [String: [URL]] = [:]
        var sizeForKey: [String: Int64] = [:]
        for (url, size, hash) in hashed {
            let key = "\(size)-\(hash)"
            byHashKey[key, default: []].append(url)
            sizeForKey[key] = size
        }
        for (key, dupURLs) in byHashKey where dupURLs.count > 1 {
            let size = sizeForKey[key] ?? 0
            let hash = key
            do {
                let sorted = dupURLs.sorted { $0.path.count < $1.path.count }
                var items: [CleanableItem] = []
                for (idx, url) in sorted.enumerated() {
                    // 默认保留第一个（路径最短者），其余勾选待删
                    items.append(CleanableItem(url: url, displayName: url.lastPathComponent,
                                               detail: url.path, size: size, safety: .caution,
                                               isSelected: idx != 0))
                }
                let wasted = Int64(dupURLs.count - 1) * size
                let cloneNote = anyAreClones(dupURLs) ? xLoc(" · 含 APFS 克隆，删除可能不释放空间") : ""
                groups.append(ScanResultGroup(
                    id: hash,
                    title: xLocF("%@ · %d 份", sorted[0].lastPathComponent, dupURLs.count),
                    description: xLocF("可释放约 %@（保留 1 份）%@", wasted.formattedBytes, cloneNote),
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
