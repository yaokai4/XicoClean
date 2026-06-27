import Foundation
import Domain

public struct SystemMetrics: Sendable {
    public let memoryUsedBytes: Int64
    public let memoryTotalBytes: Int64
    public let diskFreeBytes: Int64
    public let diskTotalBytes: Int64

    public var memoryUsedFraction: Double {
        memoryTotalBytes > 0 ? Double(memoryUsedBytes) / Double(memoryTotalBytes) : 0
    }
    public var diskUsedFraction: Double {
        diskTotalBytes > 0 ? Double(diskTotalBytes - diskFreeBytes) / Double(diskTotalBytes) : 0
    }
}

/// 采样系统指标（用于菜单栏监控）
public struct MetricsSampler: Sendable {
    private let fs: FileSystemService
    public init(fs: FileSystemService = LocalFileSystemService()) {
        self.fs = fs
    }

    public func sample() -> SystemMetrics {
        let mem = Self.sampleMemory()
        let cap = fs.volumeCapacity(for: FileManager.default.homeDirectoryForCurrentUser)
        return SystemMetrics(
            memoryUsedBytes: mem.used,
            memoryTotalBytes: mem.total,
            diskFreeBytes: cap?.available ?? 0,
            diskTotalBytes: cap?.total ?? 0
        )
    }

    static func sampleMemory() -> (used: Int64, total: Int64) {
        let total = Int64(ProcessInfo.processInfo.physicalMemory)
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &stats) { ptr -> kern_return_t in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPtr in
                host_statistics64(mach_host_self(), HOST_VM_INFO64, intPtr, &count)
            }
        }
        guard result == KERN_SUCCESS else { return (0, total) }
        let pageSize = Int64(vm_kernel_page_size)
        let active = Int64(stats.active_count) * pageSize
        let wired = Int64(stats.wire_count) * pageSize
        let compressed = Int64(stats.compressor_page_count) * pageSize
        return (active + wired + compressed, total)
    }
}
