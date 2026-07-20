import Foundation

// MARK: - 扫描模块协议（所有功能模块统一实现）

public protocol ScannerModule: Sendable {
    var metadata: ModuleMetadata { get }
    /// 执行扫描，期间通过 progress 回报进度，返回统一结果
    func scan(progress: @escaping ProgressHandler) async throws -> ScanResult
}

// MARK: - 文件系统抽象（便于注入内存 mock 做单测）

public protocol FileSystemService: Sendable {
    /// 某路径是否存在
    func exists(_ url: URL) -> Bool
    /// 列出某目录的直接子项
    func contentsOfDirectory(_ url: URL) -> [URL]
    /// 某文件/目录在磁盘上的实际占用（递归）
    func allocatedSize(of url: URL) -> Int64
    /// 读取单个条目的元数据
    func entry(for url: URL) -> FileEntry?
    /// 移入废纸篓，返回废纸篓中的新位置
    func trash(_ url: URL) throws -> URL
    /// 彻底删除
    func remove(_ url: URL) throws
    /// 从废纸篓恢复到原目录；同名冲突时使用不覆盖的替代名称
    /// Restores one exact Trash receipt and returns the file URL that now contains the item.
    /// The destination may differ from `originalURL` when a collision must be preserved safely.
    func restore(_ item: RestorableItem) throws -> URL
    /// 卷容量信息
    func volumeCapacity(for url: URL) -> VolumeCapacity?
    /// 递归枚举（用于大文件 / 空间透镜），以流式返回
    func deepEnumerate(_ url: URL, includeFiles: Bool) -> AsyncStream<FileEntry>
}

// MARK: - 安全引擎协议（所有删除的唯一闸门）

public enum SafetyVerdict: Sendable, Equatable {
    case allow
    case deny(reason: String)

    public var isAllowed: Bool {
        if case .allow = self { return true }
        return false
    }
}

public protocol SafetyEngine: Sendable {
    func verify(_ url: URL, intent: DeleteIntent) -> SafetyVerdict
}

public struct PrivilegedRemovalReport: Sendable {
    public let freedBytes: Int64
    public let failures: [URL]

    public init(freedBytes: Int64, failures: [URL]) {
        self.freedBytes = freedBytes
        self.failures = failures
    }
}

public protocol PrivilegedCleaningService: Sendable {
    func removeProtected(_ urls: [URL]) async -> PrivilegedRemovalReport
}
