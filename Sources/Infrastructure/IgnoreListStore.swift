import Foundation

/// 用户级「忽略清单」：被加入的路径永不出现在扫描结果、永不被清理。
/// 对标 CleanMyMac 的排除列表——让用户能对否决过的项一次性自保，不必每次取消勾选。
public final class IgnoreListStore: @unchecked Sendable {
    private let key = "xico.ignoreList"
    private let defaults: UserDefaults
    private let lock = NSLock()
    private var paths: Set<String>

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.paths = Set(defaults.stringArray(forKey: key) ?? [])
    }

    /// 该路径是否被忽略（精确路径或位于某个被忽略目录之下）。
    public func isIgnored(_ url: URL) -> Bool {
        let p = url.standardizedFileURL.path
        lock.lock(); defer { lock.unlock() }
        return paths.contains(p) || paths.contains { p.hasPrefix($0 + "/") }
    }

    public func add(_ url: URL) {
        lock.lock(); paths.insert(url.standardizedFileURL.path); persist(); lock.unlock()
    }

    public func remove(_ path: String) {
        lock.lock(); paths.remove(path); persist(); lock.unlock()
    }

    public func all() -> [String] {
        lock.lock(); defer { lock.unlock() }
        return paths.sorted()
    }

    private func persist() { defaults.set(Array(paths), forKey: key) }
}
