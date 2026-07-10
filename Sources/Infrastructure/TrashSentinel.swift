import Foundation
import Domain

// MARK: - 废纸篓哨兵（docs/14 P4 · 借鉴 Pearcleaner Sentinel 的交互，检测更保守）
// 监听 ~/.Trash：检测到 .app 被扔进废纸篓 → 读取其 bundle id → 用孤儿引擎同一口径
// （OrphanScanner.artifactURLs）定位残留 → 回调上层（AppModel 发系统通知，点击直达卸载器）。
//
// 保守设计：只报告、绝不自动删除；bundle id 读不到/属于系统前缀就沉默；
// 1 秒去抖（拖一批文件进废纸篓只触发一次检查）；开关默认开（设置页可关）。

public final class TrashSentinel: @unchecked Sendable {
    public struct Finding: Sendable {
        public let appName: String
        public let bundleID: String
        public let leftoverCount: Int
        public let leftoverBytes: Int64
    }

    private let fs: FileSystemService
    private let home: URL
    private let onAppTrashed: @Sendable (Finding) -> Void

    private let queue = DispatchQueue(label: "com.xico.trash-sentinel", qos: .utility)
    private var source: DispatchSourceFileSystemObject?
    private var fd: Int32 = -1
    private var knownApps = Set<String>()
    private var pending: DispatchWorkItem?

    public init(fs: FileSystemService,
                home: URL = FileManager.default.homeDirectoryForCurrentUser,
                onAppTrashed: @escaping @Sendable (Finding) -> Void) {
        self.fs = fs
        self.home = home
        self.onAppTrashed = onAppTrashed
    }

    deinit { stop() }

    private var trashURL: URL { home.appendingPathComponent(".Trash") }

    public func start() {
        queue.async { [weak self] in
            guard let self, self.source == nil else { return }
            self.knownApps = self.currentTrashedApps()
            self.fd = open(self.trashURL.path, O_EVTONLY)
            guard self.fd >= 0 else { return }   // 无 FDA 等原因打不开：静默不监听（不打扰不报错）
            let src = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: self.fd, eventMask: .write, queue: self.queue)
            src.setEventHandler { [weak self] in self?.scheduleCheck() }
            src.setCancelHandler { [weak self] in
                if let fd = self?.fd, fd >= 0 { close(fd) }
                self?.fd = -1
            }
            self.source = src
            src.resume()
        }
    }

    public func stop() {
        queue.async { [weak self] in
            self?.pending?.cancel()
            self?.pending = nil
            self?.source?.cancel()
            self?.source = nil
        }
    }

    /// 1s 去抖：拖一批文件进废纸篓只做一次差分检查。
    private func scheduleCheck() {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.checkForNewApps() }
        pending = work
        queue.asyncAfter(deadline: .now() + 1.0, execute: work)
    }

    private func currentTrashedApps() -> Set<String> {
        Set(fs.contentsOfDirectory(trashURL)
            .filter { $0.pathExtension == "app" }
            .map { $0.lastPathComponent })
    }

    private func checkForNewApps() {
        let current = currentTrashedApps()
        let added = current.subtracting(knownApps)
        knownApps = current
        for name in added {
            let appURL = trashURL.appendingPathComponent(name)
            // 废纸篓里的 .app 本体仍完整，Info.plist 可读。
            guard let bundle = Bundle(url: appURL),
                  let bid = bundle.bundleIdentifier,
                  !bid.lowercased().hasPrefix("com.apple") else { continue }
            let displayName = (bundle.infoDictionary?["CFBundleDisplayName"] as? String)
                ?? (bundle.infoDictionary?["CFBundleName"] as? String)
                ?? (name as NSString).deletingPathExtension
            let leftovers = OrphanScanner.artifactURLs(for: bid, home: home, fs: fs)
            guard !leftovers.isEmpty else { continue }
            let bytes = leftovers.reduce(Int64(0)) { $0 + fs.allocatedSize(of: $1) }
            guard bytes > 0 else { continue }
            onAppTrashed(Finding(appName: displayName, bundleID: bid,
                                 leftoverCount: leftovers.count, leftoverBytes: bytes))
        }
    }
}
