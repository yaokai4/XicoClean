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

    /// 递归/下钻深度上限（fail-safe）：正常目录树远达不到，仅用于兜住病态深度——
    /// 超限即中止删除（返回 false），同时把「同时打开的 fd 数」（每层一个 dirFD）封在此上限内，
    /// 杜绝无界递归耗尽 fd / 爆栈。对正常树行为完全一致。
    public static let maxRecursionDepth = 256

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
        // 下钻分量数即同时打开的 fd 数——病态超长路径直接拒绝（fail-safe）。
        guard comps.count <= Self.maxRecursionDepth else { return false }

        var parentFD = rootFD
        var opened: [Int32] = []
        for comp in comps.dropLast() {
            let fd = openat(parentFD, comp, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0 else { opened.forEach { close($0) }; return false }
            opened.append(fd); parentFD = fd
        }
        // 下钻已抵叶子的父目录，递归删除只需 parentFD(=opened.last)——其上的祖先下钻 fd 不再需要。
        // 在开始子树递归**之前**就关掉这些祖先 fd，使「下钻 fd 预算」与「子树递归 fd 预算」互不重叠：
        // 否则二者各自可达 maxRecursionDepth，峰值同开 fd 数会翻倍越过默认 256 的软上限。
        for fd in opened.dropLast() { close(fd) }
        let result = Self.removeEntry(parentFD: parentFD, name: leaf)
        if let leafParentFD = opened.last { close(leafParentFD) }   // 保留至递归结束才关（rootFD 无中间下钻时由其 defer 关闭）
        return result
    }

    /// fd 相对地递归删除一个条目（不跟随符号链接）。
    /// 子项部分失败仍继续删兄弟，最终返回是否全部成功。
    /// `depth` 为当前递归深度，超过 `maxRecursionDepth` 即中止删除（fail-safe，同时封顶同开 fd 数）。
    @discardableResult
    public static func removeEntry(parentFD: Int32, name: String, depth: Int = 0) -> Bool {
        // 病态深度兜底：中止而非继续，宁可漏删也不无界递归耗尽 fd / 爆栈。
        guard depth < maxRecursionDepth else { return false }
        var st = stat()
        guard fstatat(parentFD, name, &st, AT_SYMLINK_NOFOLLOW) == 0 else { return false }
        let type = st.st_mode & S_IFMT
        if type == S_IFLNK { return unlinkat(parentFD, name, 0) == 0 }   // 删软链本身，不跟随
        if type == S_IFDIR {
            let dirFD = openat(parentFD, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard dirFD >= 0 else { return false }
            // 绝不在同一 readdir 流「进行中」删除条目：POSIX 未规定边遍历边修改目录的行为
            // （可能漏项或重复枚举）。标准稳妥做法（rm -rf / fts 同构）：先把子项名整趟读全（drain）、
            // closedir，再在快照上递归/unlink。用 dirFD 的一个副本喂给 fdopendir 只做枚举，
            // dirFD 本身保留作 unlinkat/递归的锚点 fd（fd 锚定，杜绝按路径重开的 TOCTOU）。
            let streamFD = fcntl(dirFD, F_DUPFD_CLOEXEC, 0)
            guard streamFD >= 0, let dir = fdopendir(streamFD) else {
                if streamFD >= 0 { close(streamFD) }
                close(dirFD)
                return false
            }
            var names: [String] = []
            while let ent = readdir(dir) {
                let n = withUnsafeBytes(of: ent.pointee.d_name) { raw -> String in
                    String(cString: raw.baseAddress!.assumingMemoryBound(to: CChar.self))
                }
                if n == "." || n == ".." { continue }
                names.append(n)
            }
            closedir(dir)   // 关闭枚举用的副本 fd；dirFD 仍开着，作后续 unlink/递归的锚点
            var ok = true
            for n in names where !removeEntry(parentFD: dirFD, name: n, depth: depth + 1) { ok = false }
            close(dirFD)
            return ok && unlinkat(parentFD, name, AT_REMOVEDIR) == 0
        }
        return unlinkat(parentFD, name, 0) == 0
    }
}
