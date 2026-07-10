import Foundation
import DesignSystem
import Domain

/// 基于 FileManager 的文件系统实现
public struct LocalFileSystemService: FileSystemService {
    private var fm: FileManager { .default }

    public init() {}

    public func exists(_ url: URL) -> Bool {
        fm.fileExists(atPath: url.path)
    }

    public func contentsOfDirectory(_ url: URL) -> [URL] {
        do {
            return try fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil, options: [])
        } catch {
            // 权限不足/不存在是常态（无 FDA 时大量目录读不到），用 debug 级别避免刷屏，
            // 但保留可诊断线索——不再完全静默。
            XicoLog.fs.debug("列目录失败 \(url.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return []
        }
    }

    public func allocatedSize(of url: URL) -> Int64 {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isVolumeKey,
                                         .totalFileAllocatedSizeKey, .fileSizeKey]
        guard let rv = try? url.resourceValues(forKeys: keys) else { return 0 }

        if rv.isDirectory == true {
            var total: Int64 = 0
            guard let en = fm.enumerator(at: url,
                                         includingPropertiesForKeys: Array(keys),
                                         options: [],
                                         errorHandler: { _, _ in true }) else { return 0 }
            var seen = 0
            for case let f as URL in en {
                // 取消传播：巨型目录（几十 GB 容器）逐文件递归可达分钟级，
                // 每 256 项检查一次取消，用户点「取消」后立刻返回已累计值，不再空转占死线程。
                seen += 1
                if seen & 0xFF == 0 && Task.isCancelled { return total }
                guard let r = try? f.resourceValues(forKeys: keys) else { continue }
                if r.isDirectory == true {
                    // 绝不跨入子挂载点：挂载在此的其它卷不属于本目录的占用。
                    if r.isVolume == true { en.skipDescendants() }
                    continue
                }
                total += Int64(r.totalFileAllocatedSize ?? r.fileSize ?? 0)
            }
            return total
        } else {
            return Int64(rv.totalFileAllocatedSize ?? rv.fileSize ?? 0)
        }
    }

    public func entry(for url: URL) -> FileEntry? {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .totalFileAllocatedSizeKey, .fileSizeKey,
                                         .contentModificationDateKey, .contentAccessDateKey]
        guard let rv = try? url.resourceValues(forKeys: keys) else { return nil }
        let isDir = rv.isDirectory ?? false
        let size = isDir ? allocatedSize(of: url) : Int64(rv.totalFileAllocatedSize ?? rv.fileSize ?? 0)
        return FileEntry(url: url, size: size, isDirectory: isDir,
                         modificationDate: rv.contentModificationDate, accessDate: rv.contentAccessDate)
    }

    public func trash(_ url: URL) throws -> URL {
        var resulting: NSURL?
        try fm.trashItem(at: url, resultingItemURL: &resulting)
        return (resulting as URL?) ?? url
    }

    public func remove(_ url: URL) throws {
        try fm.removeItem(at: url)
    }

    public func restore(_ item: RestorableItem) throws {
        let parent = item.originalURL.deletingLastPathComponent()
        try? fm.createDirectory(at: parent, withIntermediateDirectories: true)
        var dest = item.originalURL
        // 原位已存在同名项：恢复到不冲突的名字，避免覆盖或静默失败（撤销绝不丢数据）
        if fm.fileExists(atPath: dest.path) {
            let base = item.originalURL.deletingPathExtension().lastPathComponent
            let ext = item.originalURL.pathExtension
            var i = 1
            repeat {
                let name = ext.isEmpty ? xLocF("%@ (恢复 %d)", base, i) : xLocF("%@ (恢复 %d).%@", base, i, ext)
                dest = parent.appendingPathComponent(name)
                i += 1
            } while fm.fileExists(atPath: dest.path)
        }
        try fm.moveItem(at: item.trashedURL, to: dest)
    }

    public func volumeCapacity(for url: URL) -> VolumeCapacity? {
        let keys: Set<URLResourceKey> = [.volumeTotalCapacityKey,
                                         .volumeAvailableCapacityForImportantUsageKey,
                                         .volumeAvailableCapacityKey]
        guard let rv = try? url.resourceValues(forKeys: keys) else { return nil }
        let total = Int64(rv.volumeTotalCapacity ?? 0)
        let avail = rv.volumeAvailableCapacityForImportantUsage ?? Int64(rv.volumeAvailableCapacity ?? 0)
        return VolumeCapacity(total: total, available: avail)
    }

    public func deepEnumerate(_ url: URL, includeFiles: Bool) -> AsyncStream<FileEntry> {
        AsyncStream { continuation in
            let task = Task.detached(priority: .utility) {
                // 仅取逻辑大小（大文件/重复文件够用），省去 totalFileAllocatedSize 的额外开销
                let keys: [URLResourceKey] = [.isDirectoryKey, .isVolumeKey, .fileSizeKey,
                                              .contentModificationDateKey, .contentAccessDateKey]
                guard let en = self.fm.enumerator(at: url,
                                                  includingPropertiesForKeys: keys,
                                                  options: [.skipsHiddenFiles],
                                                  errorHandler: { _, _ in true }) else {
                    continuation.finish(); return
                }
                // 非隐藏的「可再生」目录：含海量小文件但无用户级大文件，整棵跳过以提速
                // （隐藏的 .git/.cache/.gradle 等已被 skipsHiddenFiles 跳过）
                let pruneDirs: Set<String> = ["node_modules", "Pods", "Carthage",
                                              "__pycache__", "DerivedData", ".build"]
                while let next = en.nextObject() {
                    guard let fileURL = next as? URL else { continue }
                    if Task.isCancelled { break }
                    guard let rv = try? fileURL.resourceValues(forKeys: Set(keys)) else { continue }
                    let isDir = rv.isDirectory ?? false
                    // 绝不跨入子挂载点（/System/Volumes/Data、外接盘、网络盘）：
                    // firmlink 入口已计一次，跨入即整卷重复计数（512GB 盘扫出 1.79TB 的元凶之一）。
                    if isDir && rv.isVolume == true {
                        en.skipDescendants()
                        continue
                    }
                    if isDir && pruneDirs.contains(fileURL.lastPathComponent) {
                        en.skipDescendants()
                        continue
                    }
                    if isDir && !includeFiles { continue }
                    let size = Int64(rv.fileSize ?? 0)
                    continuation.yield(FileEntry(url: fileURL, size: size, isDirectory: isDir,
                                                 modificationDate: rv.contentModificationDate,
                                                 accessDate: rv.contentAccessDate))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
