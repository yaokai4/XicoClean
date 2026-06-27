import Foundation

/// 空间透镜的磁盘树节点
public final class DiskNode: Identifiable, @unchecked Sendable {
    public let id = UUID()
    public let url: URL
    public let name: String
    public let isDirectory: Bool
    public var size: Int64
    public var children: [DiskNode]

    public init(url: URL, name: String, isDirectory: Bool, size: Int64, children: [DiskNode] = []) {
        self.url = url
        self.name = name
        self.isDirectory = isDirectory
        self.size = size
        self.children = children
    }
}
