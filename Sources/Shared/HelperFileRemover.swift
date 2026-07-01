import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// 特权助手的 root 递归删除核心——从 XicoHelper/main.swift 抽出，使这段
/// 「全项目权限最高、后果最重」的代码可被单元测试覆盖（此前塞在 executableTarget 里无法 import）。
///
/// 纵深防御：删除目标必须落在注入的白名单根之下；从白名单根用 openat(O_NOFOLLOW)
/// 逐级下钻、unlinkat 锚定删除，内核保证不跟随符号链接，杜绝 TOCTOU 换链穿透。
public struct HelperFileRemover: Sendable {
    /// 允许删除的根目录（生产用 XicoHelperSecurity.deletableRoots；测试注入临时目录）。
    public let deletableRoots: [String]

    public init(deletableRoots: [String]) {
        self.deletableRoots = deletableRoots
    }

    /// 目标是否落在白名单根之下（已词法标准化的绝对路径）。
    public func isUnderDeletableRoot(_ standardizedPath: String) -> Bool {
        deletableRoots.contains { standardizedPath == $0 || standardizedPath.hasPrefix($0 + "/") }
    }

    /// 从白名单根逐级 openat(O_NOFOLLOW) 下钻到父目录，再 fd 锚定递归删除。
    /// 任一分量是符号链接 → openat 失败 → 整体拒绝；绝不删白名单根本身。
    @discardableResult
    public func safeRemove(_ path: String) -> Bool {
        guard let root = deletableRoots.first(where: { path == $0 || path.hasPrefix($0 + "/") }),
              path != root else { return false }
        let rootFD = open(root, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard rootFD >= 0 else { return false }
        defer { close(rootFD) }

        let rel = String(path.dropFirst(root.count + 1))
        let comps = rel.split(separator: "/").map(String.init)
        guard let leaf = comps.last else { return false }

        var parentFD = rootFD
        var opened: [Int32] = []
        defer { opened.forEach { close($0) } }
        for comp in comps.dropLast() {
            let fd = openat(parentFD, comp, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0 else { return false }
            opened.append(fd); parentFD = fd
        }
        return Self.removeEntry(parentFD: parentFD, name: leaf)
    }

    /// fd 相对地递归删除一个条目（不跟随符号链接）。
    /// 子项部分失败仍继续删兄弟，最终返回是否全部成功。
    @discardableResult
    public static func removeEntry(parentFD: Int32, name: String) -> Bool {
        var st = stat()
        guard fstatat(parentFD, name, &st, AT_SYMLINK_NOFOLLOW) == 0 else { return false }
        let type = st.st_mode & S_IFMT
        if type == S_IFLNK { return unlinkat(parentFD, name, 0) == 0 }   // 删软链本身，不跟随
        if type == S_IFDIR {
            let dirFD = openat(parentFD, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard dirFD >= 0, let dir = fdopendir(dirFD) else { if dirFD >= 0 { close(dirFD) }; return false }
            var ok = true
            while let ent = readdir(dir) {
                let n = withUnsafeBytes(of: ent.pointee.d_name) { raw -> String in
                    String(cString: raw.baseAddress!.assumingMemoryBound(to: CChar.self))
                }
                if n == "." || n == ".." { continue }
                if !removeEntry(parentFD: dirFD, name: n) { ok = false }
            }
            closedir(dir)   // 同时关闭 dirFD
            return ok && unlinkat(parentFD, name, AT_REMOVEDIR) == 0
        }
        return unlinkat(parentFD, name, 0) == 0
    }
}
