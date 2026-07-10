import Foundation

// MARK: - iCloud 本地副本驱逐（P6·4 第一期：只做 iCloud，最安全的云清理形态）
//
// 语义红线：**驱逐 ≠ 删除**——`evictUbiquitousItem` 只移除本地缓存副本，文件完整保留在
// iCloud 云端，随时可重新下载。因此本操作不进删除管线、不经废纸篓、无「撤销」概念
// （重新下载即恢复）。UI 必须明确解释「文件仍在云端」。
// 第三方云盘（Dropbox/Google Drive）本期只做占用分析展示，不做任何删除/驱逐。

public struct ICloudEvictableItem: Sendable, Identifiable {
    public let id: URL
    public let name: String
    public let size: Int64
    public var url: URL { id }
}

public struct ICloudScanSummary: Sendable {
    public let items: [ICloudEvictableItem]
    public var totalBytes: Int64 { items.reduce(0) { $0 + $1.size } }
}

public final class ICloudEvictor: Sendable {
    public init() {}

    /// iCloud Drive 本地容器根（不存在 = 未启用 iCloud Drive）。
    public var containerRoot: URL? {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mobile Documents", isDirectory: true)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// 扫描「已在本机下载、可驱逐」的 iCloud 文件（>= minSize 才计入，默认 1MB——
    /// 小文件驱逐意义小且列表噪音大）。同步遍历，调用方放后台线程。
    public func scan(minSize: Int64 = 1_048_576, limit: Int = 5000) -> ICloudScanSummary? {
        guard let root = containerRoot else { return nil }
        let keys: [URLResourceKey] = [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey,
                                      .totalFileSizeKey, .isRegularFileKey, .nameKey]
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys,
                                                          options: [.skipsHiddenFiles]) else { return nil }
        var items: [ICloudEvictableItem] = []
        for case let url as URL in walker {
            guard items.count < limit else { break }
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true,
                  values.isUbiquitousItem == true,
                  values.ubiquitousItemDownloadingStatus == .current,   // 已完整下载在本机
                  let size = values.totalFileSize, Int64(size) >= minSize else { continue }
            items.append(ICloudEvictableItem(id: url, name: values.name ?? url.lastPathComponent,
                                             size: Int64(size)))
        }
        return ICloudScanSummary(items: items.sorted { $0.size > $1.size })
    }

    /// 驱逐一批本地副本。返回 (释放字节, 失败清单)。逐项进行，单项失败不拖垮整批。
    public func evict(_ items: [ICloudEvictableItem]) -> (freed: Int64, failures: [String]) {
        var freed: Int64 = 0
        var failures: [String] = []
        for item in items {
            do {
                try FileManager.default.evictUbiquitousItem(at: item.url)
                freed += item.size
            } catch {
                failures.append("\(item.name)（\(error.localizedDescription)）")
            }
        }
        return (freed, failures)
    }
}
