import Foundation
import Domain
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

    private static let imageExtensions: Set<String> = [
        "jpg", "jpeg", "png", "heic", "heif", "gif", "tiff", "tif", "bmp", "webp"
    ]

    public init(fs: FileSystemService, safety: SafetyEngine,
                roots: [URL]? = nil,
                minSizeBytes: Int64 = 50 * 1024,
                distanceThreshold: Float = 0.28) {
        self.fs = fs
        self.safety = safety
        let home = FileManager.default.homeDirectoryForCurrentUser
        self.roots = roots ?? [home.appendingPathComponent("Pictures"),
                               home.appendingPathComponent("Desktop"),
                               home.appendingPathComponent("Downloads")]
        self.minSize = minSizeBytes
        self.distanceThreshold = distanceThreshold
    }

    public func scan(progress: @escaping ProgressHandler) async -> ScanResult {
        #if canImport(Vision)
        // 1. 收集候选图片
        var candidates: [(url: URL, size: Int64)] = []
        for root in roots {
            for await entry in fs.deepEnumerate(root, includeFiles: true) {
                if Task.isCancelled { break }
                guard !entry.isDirectory, entry.size >= minSize else { continue }
                guard Self.imageExtensions.contains(entry.url.pathExtension.lowercased()) else { continue }
                guard safety.verify(entry.url, intent: .trash).isAllowed else { continue }
                candidates.append((entry.url, entry.size))
            }
        }

        // 2. 计算特征指纹（并发有限）
        var prints: [(url: URL, size: Int64, print: VNFeaturePrintObservation)] = []
        let total = candidates.count
        var done = 0
        for c in candidates {
            if Task.isCancelled { break }
            done += 1
            progress(ScanProgress(fraction: total > 0 ? Double(done) / Double(total) : nil,
                                  message: c.url.lastPathComponent, bytesFound: 0))
            if let fp = Self.featurePrint(for: c.url) {
                prints.append((c.url, c.size, fp))
            }
        }

        // 3. 贪心聚类：与已有簇的代表距离 < 阈值即归入
        var clusters: [[(url: URL, size: Int64, print: VNFeaturePrintObservation)]] = []
        for item in prints {
            if Task.isCancelled { break }
            var placed = false
            for i in clusters.indices {
                if let rep = clusters[i].first {
                    // 距离默认设为「无穷远」：一旦 computeDistance 抛错（指纹不兼容/损坏），
                    // 视为不相似而非相似——出错方向必须偏向不聚类，绝不能默认把不同图片并入同组预删。
                    var distance = Float.greatestFiniteMagnitude
                    do {
                        try rep.print.computeDistance(&distance, to: item.print)
                    } catch {
                        continue   // 无法比较 → 不归入此簇
                    }
                    if distance < distanceThreshold {
                        clusters[i].append(item); placed = true; break
                    }
                }
            }
            if !placed { clusters.append([item]) }
        }

        // 4. 生成结果组（仅保留 ≥2 张的簇；保留体积最大者）
        var groups: [ScanResultGroup] = []
        for cluster in clusters where cluster.count > 1 {
            let sorted = cluster.sorted { $0.size > $1.size }   // 最大的作为"保留"
            var items: [CleanableItem] = []
            for (idx, m) in sorted.enumerated() {
                items.append(CleanableItem(url: m.url, displayName: m.url.lastPathComponent,
                                           detail: m.url.path, size: m.size, safety: .caution,
                                           isSelected: idx != 0,
                                           note: idx == 0 ? "建议保留（最大）" : nil))
            }
            let wasted = sorted.dropFirst().reduce(Int64(0)) { $0 + $1.size }
            groups.append(ScanResultGroup(
                id: "sim-\(sorted[0].url.path)",
                title: "\(sorted[0].url.lastPathComponent) · \(cluster.count) 张相似",
                description: "可释放约 \(wasted.formattedBytes)（保留最大的一张）",
                systemImage: "photo.on.rectangle.angled", safety: .caution, items: items))
        }
        groups.sort { $0.selectedSize > $1.selectedSize }
        return ScanResult(moduleID: .similarImages, groups: groups)
        #else
        return ScanResult(moduleID: .similarImages, groups: [])
        #endif
    }

    #if canImport(Vision)
    private static func featurePrint(for url: URL) -> VNFeaturePrintObservation? {
        let request = VNGenerateImageFeaturePrintRequest()
        let handler = VNImageRequestHandler(url: url, options: [:])
        do {
            try handler.perform([request])
            return request.results?.first as? VNFeaturePrintObservation
        } catch {
            XicoLog.scan.debug("图片指纹失败 \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
    #endif
}
