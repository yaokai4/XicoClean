import Foundation
import Domain

/// 空间透镜的磁盘树扫描器。
/// 关键：只为「目录」和「较大文件」建节点，小文件聚合进父节点，避免在海量文件的主目录上 OOM 闪退。
/// 顶部两层并发遍历，显著提速。
public struct DiskTreeScanner: Sendable {
    private let fs: FileSystemService
    private let maxChildrenPerNode: Int
    private let minVisibleFraction: Double
    private let minFileNodeBytes: Int64
    private let maxDepth: Int
    private let parallelDepth: Int

    public init(fs: FileSystemService, maxChildrenPerNode: Int = 12, minVisibleFraction: Double = 0.005) {
        self.fs = fs
        self.maxChildrenPerNode = maxChildrenPerNode
        self.minVisibleFraction = minVisibleFraction
        self.minFileNodeBytes = 8 * 1024 * 1024   // 小于 8MB 的文件不单独建节点
        self.maxDepth = 6
        self.parallelDepth = 2                     // 顶部两层并发
    }

    public func scan(_ root: URL, progress: @escaping ProgressHandler = { _ in }) async -> DiskNode {
        let isDir = (try? root.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
        guard isDir else {
            return DiskNode(url: root, name: root.lastPathComponent, isDirectory: false, size: fs.allocatedSize(of: root))
        }
        let node = await buildDir(root, depth: 0, progress: progress)
        let collapsed = collapse(node, parentSize: node.size)
        // 至此扫描相构建完成、定型：本函数返回后不再有任何后台任务改动此树（见 DiskNode 不变式）。
        return collapsed
    }

    /// 并发构建（用于顶部 parallelDepth 层）
    private func buildDir(_ url: URL, depth: Int, progress: @escaping ProgressHandler) async -> DiskNode {
        let fs = self.fs
        let minBytes = self.minFileNodeBytes
        let maxDepth = self.maxDepth
        let parallelDepth = self.parallelDepth
        let counter = AtomicInt()
        let childURLs = fs.contentsOfDirectory(url)

        let builtChildren: [DiskNode] = await withTaskGroup(of: DiskNode.self) { group in
            for child in childURLs {
                group.addTask {
                    if Task.isCancelled {
                        return DiskNode(url: child, name: child.lastPathComponent, isDirectory: false, size: 0)
                    }
                    let childIsDir = (try? child.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
                    let node: DiskNode
                    if childIsDir {
                        if depth + 1 < parallelDepth {
                            node = await self.buildDir(child, depth: depth + 1, progress: { _ in })
                        } else {
                            node = Self.build(child, fs: fs, depth: depth + 1, minBytes: minBytes, maxDepth: maxDepth)
                        }
                    } else {
                        node = DiskNode(url: child, name: child.lastPathComponent, isDirectory: false, size: fs.allocatedSize(of: child))
                    }
                    if depth == 0 {
                        progress(ScanProgress(message: child.lastPathComponent, bytesFound: counter.add(node.size)))
                    }
                    return node
                }
            }
            var r: [DiskNode] = []
            for await n in group { r.append(n) }
            return r
        }

        return Self.aggregate(url: url, builtChildren: builtChildren, minBytes: minBytes)
    }

    /// 同步递归构建（用于较深层）
    private static func build(_ url: URL, fs: FileSystemService, depth: Int,
                             minBytes: Int64, maxDepth: Int) -> DiskNode {
        if Task.isCancelled {
            return DiskNode(url: url, name: url.lastPathComponent, isDirectory: true, size: 0)
        }
        var built: [DiskNode] = []
        for child in fs.contentsOfDirectory(url) {
            if Task.isCancelled { break }
            let childIsDir = (try? child.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            if childIsDir {
                if depth >= maxDepth {
                    built.append(DiskNode(url: child, name: child.lastPathComponent, isDirectory: false,
                                          size: fs.allocatedSize(of: child)))
                } else {
                    built.append(build(child, fs: fs, depth: depth + 1, minBytes: minBytes, maxDepth: maxDepth))
                }
            } else {
                built.append(DiskNode(url: child, name: child.lastPathComponent, isDirectory: false,
                                      size: fs.allocatedSize(of: child)))
            }
        }
        return aggregate(url: url, builtChildren: built, minBytes: minBytes)
    }

    /// 把小文件/小目录聚合进「其他文件」，控制节点数
    private static func aggregate(url: URL, builtChildren: [DiskNode], minBytes: Int64) -> DiskNode {
        var children: [DiskNode] = []
        var total: Int64 = 0
        var otherSize: Int64 = 0
        for node in builtChildren {
            total += node.size
            if node.size >= minBytes {
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
            if index < maxChildrenPerNode && child.size >= threshold && child.name != "其他文件" {
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
            (child.isDirectory && child.name != "其他" && child.name != "其他文件")
                ? collapse(child, parentSize: child.size)
                : child
        }
        return DiskNode(url: node.url, name: node.name, isDirectory: node.isDirectory,
                        size: node.size, children: collapsedChildren)
    }
}
