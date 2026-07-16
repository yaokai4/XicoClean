import Foundation
import DesignSystem
import Domain
import ImageIO
import CoreGraphics
#if canImport(Vision)
import Vision
#endif

/// 相似图片查找：用 Vision 的特征指纹（VNGenerateImageFeaturePrint）对图片做感知比对，
/// 把视觉相近的图片聚为一组，每组智能保留一张（分辨率/体积最大者），其余勾选待删。
/// 全本地计算，不上传任何图片——契合 Xico 的隐私定位。
public struct SimilarImagesScanner: Sendable {
    private let fs: FileSystemService
    private let safety: SafetyEngine
    public let roots: [URL]
    private let minSize: Int64
    private let distanceThreshold: Float
    private let maxGroups: Int
    private let snapshotStore: ScanSnapshotStore?
    private let workLimiter: ScanWorkLimiter?

    private static let imageExtensions: Set<String> = [
        "jpg", "jpeg", "png", "heic", "heif", "gif", "tiff", "tif", "bmp", "webp"
    ]

    /// 指纹前降采样的最大边长：VNGenerateImageFeaturePrint 用固定小网格，
    /// 全分辨率解码纯属浪费——限制到此尺寸即可，解码从「整幅」降到「缩略」。
    private static let thumbnailMaxPixel = 256

    public init(fs: FileSystemService, safety: SafetyEngine,
                roots: [URL]? = nil,
                minSizeBytes: Int64 = 50 * 1024,
                distanceThreshold: Float = 0.28,
                maxGroups: Int = 200,
                snapshotStore: ScanSnapshotStore? = nil,
                workLimiter: ScanWorkLimiter? = nil) {
        self.fs = fs
        self.safety = safety
        let home = FileManager.default.homeDirectoryForCurrentUser
        self.roots = roots ?? [home.appendingPathComponent("Pictures"),
                               home.appendingPathComponent("Desktop"),
                               home.appendingPathComponent("Downloads")]
        self.minSize = minSizeBytes
        self.distanceThreshold = distanceThreshold
        self.maxGroups = maxGroups
        self.snapshotStore = snapshotStore
        self.workLimiter = workLimiter
    }

    public func scan(progress: @escaping ProgressHandler) async -> ScanResult {
        #if canImport(Vision)
        // 1. 收集候选图片
        var candidates: [(url: URL, size: Int64, reclaimable: Int64)] = []
        var coverageReports: [ScanCoverage] = []
        var seenPaths = Set<String>()
        if let snapshotStore {
            let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL
            let allInsideHome = roots.allSatisfy {
                $0.standardizedFileURL.path.hasPrefix(home.path + "/")
            }
            let snapshotRoots = allInsideHome ? [home] : roots
            for snapshotRoot in snapshotRoots {
                let snapshot = await snapshotStore.snapshot(for: snapshotRoot, progress: progress)
                coverageReports.append(snapshot.coverage)
                for entry in snapshot.entries {
                    if Task.isCancelled { break }
                    if allInsideHome {
                        let insideConfiguredRoot = roots.contains {
                            let path = $0.standardizedFileURL.path
                            return entry.url.path == path || entry.url.path.hasPrefix(path + "/")
                        }
                        guard insideConfiguredRoot else { continue }
                    }
                    guard !entry.isHidden(relativeTo: snapshot.root),
                          !entry.isInsideRebuildableDirectory(relativeTo: snapshot.root),
                          entry.logicalBytes >= minSize,
                          Self.imageExtensions.contains(entry.url.pathExtension.lowercased()),
                          safety.verify(entry.url, intent: .trash).isAllowed,
                          seenPaths.insert(entry.url.path).inserted else { continue }
                    let allocated = entry.allocatedBytes > 0 ? entry.allocatedBytes : entry.logicalBytes
                    candidates.append((entry.url, allocated, entry.estimatedReclaimableBytes))
                }
            }
        } else {
            for root in roots {
                for await entry in fs.deepEnumerate(root, includeFiles: true) {
                    if Task.isCancelled { break }
                    guard !entry.isDirectory, entry.size >= minSize else { continue }
                    guard Self.imageExtensions.contains(entry.url.pathExtension.lowercased()) else { continue }
                    guard safety.verify(entry.url, intent: .trash).isAllowed else { continue }
                    let physical = DuplicatesScanner.physicalSize(entry.url) ?? entry.size
                    candidates.append((entry.url, physical, physical))
                }
            }
        }

        // 2. 计算特征指纹（4 路并发 + 降采样解码；镜像 DuplicatesScanner 的哈希并发流水线）。
        //    旧实现串行 + 全分辨率解码（注释谎称并发），指纹阶段是纯 CPU 瓶颈；此处并发解码缩略图。
        let total = candidates.count
        let prints: [FeaturePrintBox] = await withTaskGroup(of: FeaturePrintBox?.self) { group -> [FeaturePrintBox] in
            let lanes = 4
            var iterator = candidates.makeIterator()
            func addNext() {
                guard let c = iterator.next() else { return }
                group.addTask {
                    if let limiter = self.workLimiter {
                        return await limiter.withPermit {
                            Self.featureBox(url: c.url, size: c.size,
                                            reclaimable: c.reclaimable)
                        }
                    }
                    return Self.featureBox(url: c.url, size: c.size,
                                           reclaimable: c.reclaimable)
                }
            }
            for _ in 0..<lanes { addNext() }
            var out: [FeaturePrintBox] = []
            var done = 0
            for await box in group {
                if Task.isCancelled { break }
                done += 1
                progress(ScanProgress(fraction: total > 0 ? Double(done) / Double(total) : nil,
                                      message: box?.url.lastPathComponent ?? "", bytesFound: 0))
                if let box { out.append(box) }
                addNext()
            }
            return out
        }

        // 3. 图聚类：先按纵横比分桶，再在桶内建立“距离 < 阈值”的无向边，取连通分量。
        //    相比只看首张代表图的贪心算法，结果不再受文件枚举顺序影响。
        var byAspect: [Int: [FeaturePrintBox]] = [:]
        for p in prints { byAspect[Self.aspectBucket(p.aspect), default: []].append(p) }
        var clustersByBucket: [Int: [[FeaturePrintBox]]] = [:]
        for (bucket, bucketItems) in byAspect {
            if Task.isCancelled { break }
            var unionFind = UnionFind(count: bucketItems.count)
            if bucketItems.count > 1 {
                for left in 0..<(bucketItems.count - 1) {
                    for right in (left + 1)..<bucketItems.count {
                        if Task.isCancelled { break }
                        var distance = Float.greatestFiniteMagnitude
                        do {
                            try bucketItems[left].print.computeDistance(
                                &distance, to: bucketItems[right].print)
                        } catch {
                            continue
                        }
                        if distance < distanceThreshold { unionFind.union(left, right) }
                    }
                }
            }
            var components: [Int: [FeaturePrintBox]] = [:]
            for index in bucketItems.indices {
                components[unionFind.find(index), default: []].append(bucketItems[index])
            }
            clustersByBucket[bucket] = Array(components.values)
        }
        let clusters = clustersByBucket.values.flatMap { $0 }

        // 4. 生成结果组（仅保留 ≥2 张的簇；保留体积最大者）
        var groups: [ScanResultGroup] = []
        for cluster in clusters where cluster.count > 1 {
            let sorted = cluster.sorted {
                $0.pixelCount == $1.pixelCount ? $0.size > $1.size : $0.pixelCount > $1.pixelCount
            }
            var items: [CleanableItem] = []
            var wasted: Int64 = 0
            for (idx, m) in sorted.enumerated() {
                // 体积口径 = 物理已分配字节（P0）；默认全不勾——相似照片是用户的照片，
                // 「删哪张」交回用户（P0 默认勾选纪律，比 CMM 更克制）。
                let phys = m.size
                items.append(CleanableItem(url: m.url, displayName: m.url.lastPathComponent,
                                           detail: m.url.path, size: phys, safety: .caution,
                                           isSelected: false,
                                           note: idx == 0 ? "建议保留（分辨率最高）" : nil,
                                           assessment: FindingAssessment(
                                            ruleID: "vision-similar-image",
                                            confidence: 0.85,
                                            evidence: [
                                                ScanEvidence(code: "vision-feature-print",
                                                             kind: .visualSimilarity,
                                                             title: "Vision 视觉特征相似", strength: 0.9),
                                                ScanEvidence(code: "aspect-ratio-bucket",
                                                             kind: .size,
                                                             title: "图片宽高比相近", strength: 0.75)
                                            ],
                                            reclaimableBytes: m.reclaimable,
                                            recovery: .trash,
                                            regenerationCost: .high,
                                            impact: "相似不等于重复，必须人工确认"
                                           )))
                if idx != 0 { wasted += m.reclaimable }
            }
            groups.append(ScanResultGroup(
                id: "sim-\(sorted[0].url.path)",
                title: xLocF("%@ · %d 张相似", sorted[0].url.lastPathComponent, cluster.count),
                description: xLocF("预计可释放约 %@（建议保留分辨率最高的一张）", wasted.formattedBytes),
                systemImage: "photo.on.rectangle.angled", safety: .caution, items: items))
        }
        // 相似照片默认全不勾选，不能用恒为 0 的 selectedSize 排序。
        groups.sort { $0.reclaimableSize > $1.reclaimableSize }
        // 结果组封顶（对齐 DuplicatesScanner.maxGroups）：病态输入下也不会无上限地堆结果/占内存。
        if groups.count > maxGroups { groups = Array(groups.prefix(maxGroups)) }
        return ScanResult(moduleID: .similarImages, groups: groups,
                          coverage: ScanCoverage.merged(coverageReports))
        #else
        return ScanResult(moduleID: .similarImages, groups: [])
        #endif
    }

    #if canImport(Vision)
    /// 指纹 + 纵横比载体。VNFeaturePrintObservation 是不可跨并发边界的类，
    /// 用 @unchecked Sendable 包装以便从 TaskGroup 子任务安全带出——每个盒子只由单个任务产出、
    /// 收集后单线程使用，无共享可变状态。
    private struct FeaturePrintBox: @unchecked Sendable {
        let url: URL
        let size: Int64
        let reclaimable: Int64
        let aspect: Double
        let pixelCount: Int64
        let print: VNFeaturePrintObservation
    }

    /// 对单张图：先用 CGImageSourceCreateThumbnailAtIndex 限制最大边到 thumbnailMaxPixel 解码缩略图，
    /// 再在缩略图上算 Vision 指纹（指纹本就用固定小网格，全分辨率解码是浪费）。保留取消支持。
    private static func featureBox(url: URL, size: Int64,
                                   reclaimable: Int64) -> FeaturePrintBox? {
        if Task.isCancelled { return nil }
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        // 纵横比用轻量属性读取（不解码像素），用于聚类前分桶。
        var aspect = 0.0
        var pixelCount: Int64 = 0
        if let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
           let w = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue,
           let h = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue, h > 0 {
            aspect = w / h
            pixelCount = Int64(w * h)
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: thumbnailMaxPixel
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, options as CFDictionary) else { return nil }
        let request = VNGenerateImageFeaturePrintRequest()
        let handler = VNImageRequestHandler(cgImage: cg, options: [:])
        do {
            try handler.perform([request])
            guard let fp = request.results?.first as? VNFeaturePrintObservation else { return nil }
            return FeaturePrintBox(url: url, size: size, reclaimable: reclaimable,
                                   aspect: aspect, pixelCount: pixelCount, print: fp)
        } catch {
            XicoLog.scan.debug("图片指纹失败 \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// 纵横比分桶：把宽高比按对数量化到离散桶（每 ~6% 比例差一个桶，对横竖图都均匀）。
    /// 只有同桶（比例相近）的图才进入两两距离比较，将贪心聚类从全局 O(n²) 降为各桶内 O(k²)。
    private static func aspectBucket(_ aspect: Double) -> Int {
        guard aspect > 0 else { return 0 }
        return Int((log(aspect) / 0.06).rounded())
    }

    private struct UnionFind {
        private var parent: [Int]
        private var rank: [UInt8]

        init(count: Int) {
            parent = Array(0..<count)
            rank = Array(repeating: 0, count: count)
        }

        mutating func find(_ value: Int) -> Int {
            if parent[value] != value { parent[value] = find(parent[value]) }
            return parent[value]
        }

        mutating func union(_ left: Int, _ right: Int) {
            let a = find(left)
            let b = find(right)
            guard a != b else { return }
            if rank[a] < rank[b] {
                parent[a] = b
            } else if rank[a] > rank[b] {
                parent[b] = a
            } else {
                parent[b] = a
                rank[a] += 1
            }
        }
    }
    #endif
}
