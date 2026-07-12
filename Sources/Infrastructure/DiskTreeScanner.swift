import Foundation
import Domain

/// 空间透镜的磁盘树扫描器（DaisyDisk 级口径）。
///
/// **速度**：底层用 `getattrlistbulk(2)`（见 BulkDirectoryReader）一次拉取整目录元数据，
/// 顶部若干层并发遍历；深层只累加字节不建节点，全深度精确统计且内存有界。
///
/// **正确性四红线**（512GB 盘扫出 1.79TB 的事故复盘，缺一不可）：
/// 1. **绝不跨入子挂载点**——`/System/Volumes/Data` 上的数据卷经根目录 firmlink
///    （/Users、/Applications、/Library…）已经计过一次，再进挂载点就是整卷重复计数；
///    外接盘/网络盘/`/dev` 同理被这道闸拦下。
/// 2. **绝不跟随符号链接**——`/tmp → /private/tmp` 等链接按链接本体（几十字节）计。
/// 3. **跳过根目录魔法项**——`readdir(/.nofollow)` 会返回根目录自身的全部内容
///    （实测），递归进去等于把整块盘再扫一遍；`/.vol`、`/.resolve` 同族。
/// 4. **硬链接按 fileID 只计一次**——`nlink > 1` 的文件多个目录项共享同一份数据。
///
/// 尺寸口径 = 物理已分配字节（稀疏/压缩文件按盘上真实占用），与 `du` 一致。
/// 扫整卷时补「隐藏空间」灰段 =（卷已用量 − 可见总量），涵盖快照与无权限读取的部分，
/// 让中心数字与磁盘真实已用量对得上（DaisyDisk 同款诚实口径）。
public struct DiskTreeScanner: Sendable {
    private let fs: FileSystemService
    private let maxChildrenPerNode: Int
    private let minVisibleFraction: Double
    private let minFileNodeBytes: Int64
    private let maxDepth: Int
    private let parallelDepth: Int

    /// 默认粒度对标 DaisyDisk：每层最多 48 个可见子节点、角度阈值 1/240 圆（1.5°，DaisyDisk
    /// 反汇编实证的 smaller-objects 阈值）；文件节点下限 8MB（更小的进「其他文件」桶）。
    /// 深层明细靠「钻取时现场子扫描」（SpaceLens 的嫁接机制）补齐——首扫内存有界、明细无限。
    public init(fs: FileSystemService, maxChildrenPerNode: Int = 48,
                minVisibleFraction: Double = 1.0 / 240.0,
                minFileNodeBytes: Int64 = 8 * 1024 * 1024) {
        self.fs = fs
        self.maxChildrenPerNode = maxChildrenPerNode
        self.minVisibleFraction = minVisibleFraction
        self.minFileNodeBytes = minFileNodeBytes
        self.maxDepth = 6
        self.parallelDepth = 3                     // 顶部三层并发：/Users/yaokai 一级的大子树各占一个任务
    }

    public func scan(_ root: URL, progress: @escaping ProgressHandler = { _ in }) async -> DiskNode {
        // 先用 realpath(3) 解掉根路径上的所有符号链接，扫描过程中则绝不跟链接。
        // 不用 resolvingSymlinksInPath：它对 /tmp、/var、/etc 有「去 /private 前缀」怪癖
        //（返回值仍是符号链接本身），会让这三个根扫成 0 字节的单文件节点（审查确认）。
        var targetPath = root.path
        if let rp = realpath(targetPath, nil) {
            targetPath = String(cString: rp)
            free(rp)
        }
        let target = URL(fileURLWithPath: targetPath, isDirectory: true)
        let isDir = (try? target.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
        guard isDir else {
            return DiskNode(url: root, name: root.lastPathComponent, isDirectory: false, size: fs.allocatedSize(of: root))
        }
        let fsService = fs
        let ctx = ScanContext(progress: progress,
                              fallbackDirSize: { fsService.allocatedSize(of: $0) })
        let node = await buildDir(target, depth: 0, ctx: ctx)
        let collapsed = collapse(node, parentSize: node.size)
        // 至此扫描相构建完成、定型：本函数返回后不再有任何后台任务改动此树（见 DiskNode 不变式）。
        if !Task.isCancelled,
           let hidden = await hiddenSpaceNode(for: target, scanned: node.size, deniedDirs: ctx.deniedDirs) {
            return DiskNode(url: collapsed.url, name: collapsed.name, isDirectory: true,
                            size: collapsed.size + hidden.size,
                            children: collapsed.children + [hidden])
        }
        return collapsed
    }

    // MARK: - 跳过红线

    /// 是否整体跳过该子项（子挂载点 / 根目录魔法项）。
    private static func shouldSkip(_ entry: BulkDirEntry, parentPath: String) -> Bool {
        if entry.kind == .directory && entry.isMountPoint { return true }
        if parentPath == "/" {
            // readdir(/.nofollow) 返回根目录自身内容（整盘重复计数的元凶）；.vol/.resolve 同族魔法目录。
            switch entry.name {
            case ".vol", ".nofollow", ".resolve": return true
            default: break
            }
        }
        return false
    }

    // MARK: - 构建

    /// 并发构建（用于顶部 parallelDepth 层）
    private func buildDir(_ url: URL, depth: Int, ctx: ScanContext) async -> DiskNode {
        if Task.isCancelled {
            return DiskNode(url: url, name: url.lastPathComponent, isDirectory: true, size: 0)
        }
        let path = url.path
        let entries = BulkDirectoryReader.read(path, onDenied: { ctx.noteDenied() })

        var children: [DiskNode] = []
        var dirEntries: [BulkDirEntry] = []
        var localBytes: Int64 = 0
        for entry in entries {
            guard !Self.shouldSkip(entry, parentPath: path) else { continue }
            switch entry.kind {
            case .directory:
                if entry.rawName != nil {
                    // 名字含非法 UTF-8（个别 NFS/FUSE 卷）：字符串路径无法无损重建，
                    // 走 FileManager 慢路径整树计量，作叶子目录节点。
                    let child = Self.resolvedChildURL(of: entry, in: url, isDirectory: true)
                    children.append(DiskNode(url: child, name: entry.name, isDirectory: true,
                                             size: ctx.fallbackDirSize(child)))
                } else {
                    dirEntries.append(entry)
                }
            case .file, .symlink:
                if entry.linkCount > 1 && !ctx.countFirstSighting(of: entry.fileID) { continue }
                let bytes = ctx.effectiveBytes(of: entry)   // P0-c 克隆去重口径
                localBytes += bytes
                children.append(DiskNode(url: Self.resolvedChildURL(of: entry, in: url, isDirectory: false),
                                         name: entry.name, isDirectory: false, size: bytes))
            case .other:
                break
            }
        }
        if ctx.add(localBytes, at: path) { await Task.yield() }

        let minBytes = self.minFileNodeBytes
        let maxDepth = self.maxDepth
        let builtDirs: [DiskNode] = await withTaskGroup(of: DiskNode.self) { group in
            for entry in dirEntries {
                let childURL = url.appendingPathComponent(entry.name, isDirectory: true)
                group.addTask {
                    if Task.isCancelled {
                        return DiskNode(url: childURL, name: entry.name, isDirectory: true, size: 0)
                    }
                    let node: DiskNode
                    if depth + 1 < self.parallelDepth {
                        node = await self.buildDir(childURL, depth: depth + 1, ctx: ctx)
                    } else {
                        // 深层构建限流（P1-4）：浅层调度不持有信号量、深层独占递归才持有——
                        // 无嵌套持有故无死锁；并发上限 = 2×核数，IO 重叠够用又不挤爆线程池。
                        await ctx.buildSemaphore.wait()
                        node = await Self.build(childURL, depth: depth + 1, minBytes: minBytes,
                                                maxDepth: maxDepth, ctx: ctx)
                        await ctx.buildSemaphore.signal()
                    }
                    if depth == 0 {
                        ctx.emit(message: entry.name)
                    }
                    return node
                }
            }
            var r: [DiskNode] = []
            for await n in group { r.append(n) }
            return r
        }

        return Self.aggregate(url: url, builtChildren: children + builtDirs, minBytes: minBytes)
    }

    /// 深层递归构建。async 而非同步：每处理若干目录便让出协作线程（ctx.add 计数触发 yield），
    /// 全盘扫描的长递归不再饿死同池的其它异步任务（菜单栏采样等）。
    private static func build(_ url: URL, depth: Int, minBytes: Int64, maxDepth: Int,
                              ctx: ScanContext) async -> DiskNode {
        if Task.isCancelled {
            return DiskNode(url: url, name: url.lastPathComponent, isDirectory: true, size: 0)
        }
        let path = url.path
        var built: [DiskNode] = []
        var localBytes: Int64 = 0
        for entry in BulkDirectoryReader.read(path, onDenied: { ctx.noteDenied() }) {
            guard !shouldSkip(entry, parentPath: path) else { continue }
            switch entry.kind {
            case .directory:
                let childURL = resolvedChildURL(of: entry, in: url, isDirectory: true)
                if entry.rawName != nil {
                    // 非法 UTF-8 名字：字符串路径无法无损重建，走 FileManager 慢路径整树计量。
                    built.append(DiskNode(url: childURL, name: entry.name, isDirectory: true,
                                          size: ctx.fallbackDirSize(childURL)))
                } else if depth >= maxDepth {
                    // 节点粒度到此为止，但字节统计继续全深度精确累加。
                    built.append(DiskNode(url: childURL, name: entry.name, isDirectory: true,
                                          size: await sizeOnly(childURL.path, ctx: ctx)))
                } else {
                    built.append(await build(childURL, depth: depth + 1, minBytes: minBytes,
                                             maxDepth: maxDepth, ctx: ctx))
                }
            case .file, .symlink:
                if entry.linkCount > 1 && !ctx.countFirstSighting(of: entry.fileID) { continue }
                let bytes = ctx.effectiveBytes(of: entry)   // P0-c 克隆去重口径
                localBytes += bytes
                built.append(DiskNode(url: resolvedChildURL(of: entry, in: url, isDirectory: false),
                                      name: entry.name, isDirectory: false, size: bytes))
            case .other:
                break
            }
        }
        if ctx.add(localBytes, at: path) { await Task.yield() }
        return aggregate(url: url, builtChildren: built, minBytes: minBytes)
    }

    /// 只累加字节、不建节点（maxDepth 之下的深层）——全深度精确且内存 O(1)。
    private static func sizeOnly(_ path: String, ctx: ScanContext) async -> Int64 {
        if Task.isCancelled { return 0 }
        var total: Int64 = 0
        var localBytes: Int64 = 0
        var subdirs: [String] = []
        for entry in BulkDirectoryReader.read(path, onDenied: { ctx.noteDenied() }) {
            guard !shouldSkip(entry, parentPath: path) else { continue }
            switch entry.kind {
            case .directory:
                if entry.rawName != nil {
                    let child = resolvedChildURL(of: entry,
                                                 in: URL(fileURLWithPath: path, isDirectory: true),
                                                 isDirectory: true)
                    total += ctx.fallbackDirSize(child)
                } else {
                    subdirs.append(entry.name)
                }
            case .file, .symlink:
                if entry.linkCount > 1 && !ctx.countFirstSighting(of: entry.fileID) { continue }
                localBytes += ctx.effectiveBytes(of: entry)   // P0-c 克隆去重口径
            case .other:
                break
            }
        }
        if ctx.add(localBytes, at: path) { await Task.yield() }
        total += localBytes
        let base = path == "/" ? "/" : path + "/"
        for name in subdirs {
            if Task.isCancelled { break }
            total += await sizeOnly(base + name, ctx: ctx)
        }
        return total
    }

    /// 子项 URL 构建：名字含非法 UTF-8 时用原始字节经 fileSystemRepresentation 无损重建，
    /// 否则整棵子树的 URL 会指向不存在的路径（审查确认）。
    private static func resolvedChildURL(of entry: BulkDirEntry, in parent: URL, isDirectory: Bool) -> URL {
        if let raw = entry.rawName {
            return raw.withUnsafeBufferPointer {
                URL(fileURLWithFileSystemRepresentation: $0.baseAddress!,
                    isDirectory: isDirectory, relativeTo: parent)
            }
        }
        return parent.appendingPathComponent(entry.name, isDirectory: isDirectory)
    }

    /// 把小项聚合进「其他文件」，控制节点数。
    /// 双阈值（DaisyDisk 口径）：绝对阈值 minBytes 之外，还保留「占父目录 ≥1/64 的主导项」
    ///（按大小取前 32 名）——3MB 的文件夹里 3MB 的子目录是 100%，绝不该被埋进「其他文件」；
    /// 否则小分支钻进去永远只有一个灰桶，什么都看不见。前 32 名上限保证节点数有界。
    private static func aggregate(url: URL, builtChildren: [DiskNode], minBytes: Int64) -> DiskNode {
        let total = builtChildren.reduce(Int64(0)) { $0 + $1.size }
        let relativeFloor = max(total / 64, 64 * 1024)
        let sorted = builtChildren.sorted { $0.size > $1.size }
        var children: [DiskNode] = []
        var otherSize: Int64 = 0
        for (rank, node) in sorted.enumerated() {
            if node.size >= minBytes || (rank < 32 && node.size >= relativeFloor) {
                children.append(node)
            } else {
                otherSize += node.size
            }
        }
        if otherSize > 0 {
            // 合成聚合桶：复用父 URL 仅供展示占比，isAggregate=true 使其绝不可被删除（审计 P0）。
            children.append(DiskNode(url: url, name: "其他文件", isDirectory: true, size: otherSize, isAggregate: true))
        }
        return DiskNode(url: url, name: url.lastPathComponent, isDirectory: true, size: total, children: children)
    }

    /// 显示前裁剪：按大小排序、截断过多/过小子节点。
    /// 纯函数——自底向上返回**全新**的裁剪树，不就地改动传入节点（`DiskNode.children`/`size`
    /// 对本模块只读；单写不变式见 DiskNode 文档）。`size` 沿用原节点，仅重组 `children`。
    private func collapse(_ node: DiskNode, parentSize: Int64) -> DiskNode {
        guard !node.children.isEmpty else { return node }
        let sorted = node.children.sorted { $0.size > $1.size }

        let threshold = Int64(Double(max(parentSize, 1)) * minVisibleFraction)
        var visible: [DiskNode] = []
        var otherSize: Int64 = 0
        for (index, child) in sorted.enumerated() {
            if index < maxChildrenPerNode && child.size >= threshold && !child.isAggregate {
                visible.append(child)
            } else {
                otherSize += child.size
            }
        }
        if otherSize > 0 {
            // 合成聚合桶：复用父 URL 仅供展示占比，isAggregate=true 使其绝不可被删除（审计 P0）。
            visible.append(DiskNode(url: node.url, name: "其他", isDirectory: true, size: otherSize, isAggregate: true))
        }
        let collapsedChildren = visible.map { child -> DiskNode in
            (child.isDirectory && !child.isAggregate)
                ? collapse(child, parentSize: child.size)
                : child
        }
        return DiskNode(url: node.url, name: node.name, isDirectory: node.isDirectory,
                        size: node.size, children: collapsedChildren)
    }

    // MARK: - 隐藏空间（扫整卷时的诚实口径，P0-d 三本账拆分）

    /// 卷已用量 − 可见总量 = 快照/purgeable/无权限区等「看得见用量、看不见明细」的部分。
    /// P0-d：从单块灰升级为**可展开账本**——
    ///   · 可清除（purgeable）：真实 API 值（importantUsage 差），只解释不代删；
    ///   · 本地快照：tmutil 枚举个数与名字；体积无特权拿不到，用「差额 − purgeable」诚实标注「≈」，
    ///     可经透镜的 tmutil 独立通道删除（二次确认）；
    ///   · 无权限读取区：deniedDirs>0 时列出，引导开启完全磁盘访问（体积并入快照段之外的残差）。
    /// 阈值（>1GB 且 >已用 2%）以下不展示——克隆/云占位造成的小误差不值得画上环。
    private func hiddenSpaceNode(for root: URL, scanned: Int64, deniedDirs: Int) async -> DiskNode? {
        guard (try? root.resourceValues(forKeys: [.isVolumeKey]))?.isVolume == true,
              let cap = fs.volumeCapacity(for: root), cap.total > 0 else { return nil }
        let used = cap.total - cap.available
        let delta = used - scanned
        guard delta > max(1 << 30, used / 50) else { return nil }

        let ledger = await SpaceLedger.collect(volume: root)
        var children: [DiskNode] = []
        var accounted: Int64 = 0
        if let purgeable = ledger.purgeableBytes, purgeable > 0 {
            let p = min(purgeable, delta)
            children.append(DiskNode(url: root, name: "可清除（系统自管）", isDirectory: false,
                                     size: p, isAggregate: true, ledgerKind: .purgeable))
            accounted += p
        }
        let remainder = max(0, delta - accounted)
        if let count = ledger.snapshotCount, count > 0 {
            children.append(DiskNode(url: root, name: "本地快照 · \(count) 个", isDirectory: false,
                                     size: remainder, isAggregate: true, ledgerKind: .snapshots))
        } else if deniedDirs > 0 {
            children.append(DiskNode(url: root, name: "无权限读取区 · \(deniedDirs) 处未读",
                                     isDirectory: false, size: remainder,
                                     isAggregate: true, ledgerKind: .unreadable))
        } else if remainder > 0 {
            children.append(DiskNode(url: root, name: "其他系统占用", isDirectory: false,
                                     size: remainder, isAggregate: true))
        }
        guard !children.isEmpty else {
            return DiskNode(url: root, name: "隐藏空间", isDirectory: false, size: delta, isAggregate: true)
        }
        return DiskNode(url: root, name: "隐藏空间", isDirectory: true, size: delta,
                        children: children, isAggregate: true)
    }
}

/// 简单异步信号量（P1-4 并发限流）：深层子树构建的并发上限，
/// 防止几十个大目录同时深递归把线程池占满、反拖菜单栏采样。
/// 只在「浅层调度不持有、深层构建才持有」的模式下使用——无嵌套持有，无死锁。
actor AsyncSemaphore {
    private var available: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []
    init(_ n: Int) { available = max(1, n) }
    func wait() async {
        if available > 0 { available -= 1; return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func signal() {
        if let w = waiters.first { waiters.removeFirst(); w.resume() }
        else { available += 1 }
    }
}

/// 扫描全程共享的上下文：硬链接/克隆去重表（分片锁）+ 节流的进度上报 + 未读区统计。
/// `@unchecked Sendable` 安全前提：全部可变状态由内部锁串行化。
private final class ScanContext: @unchecked Sendable {
    private let lock = NSLock()
    /// 去重表分片（P1-5）：百万文件并发下单锁是热点——按 id 低位分 16 片，各片独立锁。
    private static let shardCount = 16
    private var linkShards = (0..<shardCount).map { _ in (lock: NSLock(), set: Set<UInt64>()) }
    private var cloneShards = (0..<shardCount).map { _ in (lock: NSLock(), set: Set<UInt64>()) }
    private var bytes: Int64 = 0
    private var lastEmit: TimeInterval = 0
    private var dirsSinceYield = 0
    /// 无权限而未读的目录数（P1-6）：>0 且缺 FDA 时结果页显式引导，不静默少算。
    private let deniedLock = NSLock()
    private var denied = 0
    private let progress: ProgressHandler
    /// 深层构建并发限流（P1-4）。
    let buildSemaphore: AsyncSemaphore
    /// 罕见病例回退（非法 UTF-8 名字的目录）：FileManager 慢路径整树计量。
    let fallbackDirSize: @Sendable (URL) -> Int64

    init(progress: @escaping ProgressHandler,
         fallbackDirSize: @escaping @Sendable (URL) -> Int64) {
        self.progress = progress
        self.fallbackDirSize = fallbackDirSize
        self.buildSemaphore = AsyncSemaphore(ProcessInfo.processInfo.activeProcessorCount * 2)
    }

    /// 硬链接去重：首见返回 true（计数），重见返回 false（跳过）。fileID 未知时保守计数。
    func countFirstSighting(of fileID: UInt64) -> Bool {
        guard fileID != 0 else { return true }
        let i = Int(fileID) & (Self.shardCount - 1)
        linkShards[i].lock.lock(); defer { linkShards[i].lock.unlock() }
        return linkShards[i].set.insert(fileID).inserted
    }

    /// 文件的有效计量字节（P0-c 克隆去重·混合口径）：
    /// - 无共享块（private == alloc 或无 CMNEXT 信息）→ 计全量物理占用；
    /// - 有共享块（CoW 克隆家族成员）→ **家族首见计全量**（共享块恰好计一次），
    ///   **再见只计独占字节**（删除它真实能释放的量）。
    /// Σ = 精确物理占用：共享块一次 + 各成员独占——总量与卷已用对账，单文件数字也诚实。
    func effectiveBytes(of entry: BulkDirEntry) -> Int64 {
        guard let priv = entry.privateBytes, priv < entry.allocatedBytes, entry.cloneID != 0 else {
            return entry.allocatedBytes
        }
        let i = Int(entry.cloneID) & (Self.shardCount - 1)
        cloneShards[i].lock.lock()
        let first = cloneShards[i].set.insert(entry.cloneID).inserted
        cloneShards[i].lock.unlock()
        return first ? entry.allocatedBytes : priv
    }

    /// 无权限目录 +1（BulkDirectoryReader onDenied 回调）。
    func noteDenied() { deniedLock.lock(); denied += 1; deniedLock.unlock() }
    var deniedDirs: Int { deniedLock.lock(); defer { deniedLock.unlock() }; return denied }

    /// 累加字节并节流上报进度（每 0.1s 至多一次，消息 = 当前目录路径）。
    /// 返回「该让出协作线程了」（每 128 个目录一次）——调用方随即 Task.yield()，
    /// 长递归不再饿死同池的其它异步任务。
    @discardableResult
    func add(_ n: Int64, at dir: String) -> Bool {
        lock.lock()
        bytes += n
        dirsSinceYield += 1
        let shouldYield = dirsSinceYield >= 128
        if shouldYield { dirsSinceYield = 0 }
        let now = Date.timeIntervalSinceReferenceDate
        let shouldEmit = now - lastEmit > 0.1
        if shouldEmit { lastEmit = now }
        let snapshot = bytes
        lock.unlock()
        // 已取消的扫描绝不再上报——旧任务的迟到进度会踩掉新扫描刚清零的计数（审查确认）。
        if shouldEmit && !Task.isCancelled {
            progress(ScanProgress(message: dir, bytesFound: snapshot))
        }
        return shouldYield
    }

    /// 强制上报一次（顶层子目录完成时，让用户看到「正在收尾哪一块」）。
    func emit(message: String) {
        lock.lock()
        lastEmit = Date.timeIntervalSinceReferenceDate
        let snapshot = bytes
        lock.unlock()
        if !Task.isCancelled {
            progress(ScanProgress(message: message, bytesFound: snapshot))
        }
    }
}
