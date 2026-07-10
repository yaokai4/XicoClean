import Foundation
import Darwin

/// 目录条目（空间透镜扫描的最小事实单元）。
/// 一次 `getattrlistbulk` 就拿全「名字 + 类型 + 物理占用 + inode + 硬链接数 + 挂载点标志」，
/// 免去 FileManager 逐文件取属性的往返——这正是 DaisyDisk 级扫描速度的来源。
struct BulkDirEntry: Sendable {
    enum Kind: Sendable {
        case directory
        case file
        case symlink
        /// 套接字/管道/设备节点等——不占常规磁盘空间，扫描时忽略。
        case other
    }

    let name: String
    /// 名字无法无损 UTF-8 解码时的原始字节（含结尾 NUL；个别 NFS/FUSE 卷会出现）。
    /// 此时 `name` 是带 U+FFFD 修补的展示名——**路径重建必须用原始字节**，
    /// 否则子树 URL 会指向不存在的路径。nil = 名字是合法 UTF-8。
    let rawName: [CChar]?
    let kind: Kind
    /// 磁盘上的物理占用（所有 fork 的已分配字节）。稀疏/压缩文件按真实占用计，
    /// 与 `du` 口径一致；目录恒为 0（其大小由子孙累加）。
    let allocatedBytes: Int64
    /// 卷内唯一文件号（APFS 卷组内跨卷不重号）。硬链接去重的键；0 = 未知（回退路径）。
    let fileID: UInt64
    /// 硬链接数。>1 时同一份数据有多个目录项，必须按 fileID 只计一次。
    let linkCount: UInt32
    /// 本目录是否是「其它文件系统的挂载点」（DIR_MNTSTATUS_MNTPOINT）。
    /// 扫描绝不跨入子挂载点——这是掐断 /System/Volumes/Data 重复计数、
    /// 外接盘/网络盘误入的根本开关。
    let isMountPoint: Bool
}

/// 基于 `getattrlistbulk(2)` 的高速目录读取器；系统调用不可用时回退 FileManager。
/// 只读、无副作用；不跟随符号链接、不触发 iCloud 占位文件下载（仅 readdir 级元数据）。
enum BulkDirectoryReader {
    /// ATTR_*/DIR_* 常量在 Swift 里导入类型不一（Int32/UInt32 混杂），统一按位型收口。
    private static func u32(_ value: some BinaryInteger) -> UInt32 { UInt32(truncatingIfNeeded: value) }

    /// 读取目录的全部直接子项。打不开（无权限/不存在）返回空数组。
    static func read(_ path: String) -> [BulkDirEntry] {
        if let entries = readBulk(path) { return entries }
        return readViaFileManager(path)
    }

    // MARK: - getattrlistbulk 快路径

    private static func readBulk(_ path: String) -> [BulkDirEntry]? {
        // 云占位红线（TN3150；DaisyDisk 同款策略）：扫描线程禁止触发 File Provider 物化——
        // 否则枚举 iCloud 云盘会把云端内容真的下载下来。仅影响当前线程，读完即恢复。
        let previousPolicy = getiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD)
        _ = setiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD,
                           IOPOL_MATERIALIZE_DATALESS_FILES_OFF)
        defer {
            if previousPolicy >= 0 {
                _ = setiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD, previousPolicy)
            }
        }

        // O_NOFOLLOW：路径最后一段是符号链接时拒绝打开（扫描永不跟链接）。
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else {
            // EDEADLK = 未物化的云占位目录：内容不在本地、占用≈0，按空目录计——
            // 绝不能落到 FileManager 回退（Foundation 枚举会触发下载）。
            return errno == EDEADLK ? [] : nil
        }
        defer { close(fd) }

        var attrs = attrlist()
        attrs.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        attrs.commonattr = u32(ATTR_CMN_RETURNED_ATTRS)
            | u32(ATTR_CMN_NAME)
            | u32(ATTR_CMN_ERROR)
            | u32(ATTR_CMN_OBJTYPE)
            | u32(ATTR_CMN_FILEID)
        attrs.dirattr = u32(ATTR_DIR_MOUNTSTATUS)
        attrs.fileattr = u32(ATTR_FILE_LINKCOUNT)
            | u32(ATTR_FILE_ALLOCSIZE)

        let bufSize = 256 * 1024
        let buf = UnsafeMutableRawPointer.allocate(byteCount: bufSize, alignment: 8)
        defer { buf.deallocate() }

        var out: [BulkDirEntry] = []
        while true {
            let count = getattrlistbulk(fd, &attrs, buf, bufSize, 0)
            if count < 0 {
                // 云占位目录（EDEADLK）：按已读内容返回，绝不落 FileManager 回退（会触发下载）。
                if errno == EDEADLK { return out }
                // 首批就失败（如个别网络文件系统不支持）→ 整体走回退路径；
                // 中途失败则保留已读部分（比全部丢弃更接近真相）。
                return out.isEmpty ? nil : out
            }
            if count == 0 { break }
            var record = buf
            for _ in 0..<count {
                let recordLength = record.loadUnaligned(fromByteOffset: 0, as: UInt32.self)
                if let entry = parseRecord(record) { out.append(entry) }
                record = record.advanced(by: Int(recordLength))
            }
        }
        return out
    }

    /// 解析单条 getattrlistbulk 记录。字段按属性位序紧凑排列（4 字节对齐，无补齐），
    /// ATTR_CMN_ERROR 例外——紧跟 RETURNED_ATTRS 之后。u64 可能落在 4 字节边界上，
    /// 一律用非对齐读取。
    private static func parseRecord(_ record: UnsafeMutableRawPointer) -> BulkDirEntry? {
        var offset = MemoryLayout<UInt32>.size   // 跳过记录长度
        let returned = record.loadUnaligned(fromByteOffset: offset, as: attribute_set_t.self)
        offset += MemoryLayout<attribute_set_t>.size

        if returned.commonattr & u32(ATTR_CMN_ERROR) != 0 {
            let error = record.loadUnaligned(fromByteOffset: offset, as: UInt32.self)
            offset += MemoryLayout<UInt32>.size
            if error != 0 { return nil }
        }

        var name = ""
        var rawName: [CChar]?
        if returned.commonattr & u32(ATTR_CMN_NAME) != 0 {
            let ref = record.loadUnaligned(fromByteOffset: offset, as: attrreference_t.self)
            let nameStart = record.advanced(by: offset + Int(ref.attr_dataoffset))
                .assumingMemoryBound(to: CChar.self)
            if let valid = String(validatingUTF8: nameStart) {
                name = valid
            } else {
                // 非法 UTF-8（个别 NFS/FUSE 卷）：展示名带 U+FFFD 修补，原始字节另存供路径重建。
                name = String(cString: nameStart)
                rawName = Array(UnsafeBufferPointer(start: nameStart, count: Int(ref.attr_length)))
            }
            offset += MemoryLayout<attrreference_t>.size
        }

        var objType: fsobj_type_t = 0
        if returned.commonattr & u32(ATTR_CMN_OBJTYPE) != 0 {
            objType = record.loadUnaligned(fromByteOffset: offset, as: fsobj_type_t.self)
            offset += MemoryLayout<fsobj_type_t>.size
        }

        var fileID: UInt64 = 0
        if returned.commonattr & u32(ATTR_CMN_FILEID) != 0 {
            fileID = record.loadUnaligned(fromByteOffset: offset, as: UInt64.self)
            offset += MemoryLayout<UInt64>.size
        }

        var isMountPoint = false
        if returned.dirattr & u32(ATTR_DIR_MOUNTSTATUS) != 0 {
            let status = record.loadUnaligned(fromByteOffset: offset, as: UInt32.self)
            offset += MemoryLayout<UInt32>.size
            // TRIGGER = 尚未挂载的自动挂载点（autofs）：读它会真的把网络卷挂上来（挂载风暴），
            // 与已挂载的子挂载点一样整体跳过。
            isMountPoint = status & (u32(DIR_MNTSTATUS_MNTPOINT) | u32(DIR_MNTSTATUS_TRIGGER)) != 0
        }

        var linkCount: UInt32 = 1
        if returned.fileattr & u32(ATTR_FILE_LINKCOUNT) != 0 {
            linkCount = record.loadUnaligned(fromByteOffset: offset, as: UInt32.self)
            offset += MemoryLayout<UInt32>.size
        }

        var allocated: Int64 = 0
        if returned.fileattr & u32(ATTR_FILE_ALLOCSIZE) != 0 {
            allocated = record.loadUnaligned(fromByteOffset: offset, as: Int64.self)
            offset += MemoryLayout<Int64>.size
        }

        guard !name.isEmpty else { return nil }
        let kind: BulkDirEntry.Kind
        switch objType {
        case fsobj_type_t(VDIR.rawValue): kind = .directory
        case fsobj_type_t(VREG.rawValue): kind = .file
        case fsobj_type_t(VLNK.rawValue): kind = .symlink
        default: kind = .other
        }
        return BulkDirEntry(name: name, rawName: rawName, kind: kind, allocatedBytes: max(0, allocated),
                            fileID: fileID, linkCount: linkCount, isMountPoint: isMountPoint)
    }

    // MARK: - FileManager 回退路径（个别不支持 getattrlistbulk 的文件系统）

    private static func readViaFileManager(_ path: String) -> [BulkDirEntry] {
        let url = URL(fileURLWithPath: path, isDirectory: true)
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey, .isVolumeKey,
                                         .totalFileAllocatedSizeKey, .fileSizeKey]
        guard let children = try? FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: Array(keys), options: []) else { return [] }
        return children.compactMap { child in
            guard let rv = try? child.resourceValues(forKeys: keys) else { return nil }
            let kind: BulkDirEntry.Kind
            // 先判符号链接——isDirectoryKey 会穿透链接，顺序颠倒就会误跟链接进目录。
            if rv.isSymbolicLink == true { kind = .symlink }
            else if rv.isDirectory == true { kind = .directory }
            else { kind = .file }
            let size = kind == .directory ? 0 : Int64(rv.totalFileAllocatedSize ?? rv.fileSize ?? 0)
            return BulkDirEntry(name: child.lastPathComponent, rawName: nil, kind: kind,
                                allocatedBytes: size, fileID: 0, linkCount: 1,
                                isMountPoint: kind == .directory && rv.isVolume == true)
        }
    }
}
