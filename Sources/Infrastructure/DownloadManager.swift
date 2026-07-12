import Foundation
import Combine
import Domain
import DesignSystem

/// 下载队列管理器（对标 Downie 的队列）。@MainActor 发布，进度经 Sendable 的 AsyncStream 从后台桥回主线程。
@MainActor
public final class DownloadManager: ObservableObject {
    @Published public private(set) var jobs: [DownloadJob] = []
    @Published public private(set) var engineStatus: DownloadEngineStatus = .notInstalled
    @Published public var defaultDestination: String
    @Published public var preferences: DownloadPreferences
    /// 剪贴板监听命中的待确认链接（对标 Downie 的自动捕获）。
    @Published public var pendingClipboardURL: String?

    private let installer = EngineInstaller()
    private var handles: [UUID: ProcessHandle] = [:]
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private let prefsKey = "xico.download.prefs.v1"
    private var clipboardTimer: Timer?
    private var lastClipboardChange: Int = -1

    public init() {
        defaultDestination = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Downloads").path
        if let data = UserDefaults.standard.data(forKey: "xico.download.prefs.v1"),
           let p = try? JSONDecoder().decode(DownloadPreferences.self, from: data) {
            preferences = p
        } else {
            preferences = DownloadPreferences()
        }
        engineStatus = EngineInstaller.status()
        if preferences.clipboardMonitor { startClipboardMonitor() }
    }

    public func savePreferences() {
        if let data = try? JSONEncoder().encode(preferences) { UserDefaults.standard.set(data, forKey: prefsKey) }
        if preferences.clipboardMonitor { startClipboardMonitor() } else { stopClipboardMonitor() }
    }

    // MARK: 剪贴板自动捕获

    private func startClipboardMonitor() {
        guard clipboardTimer == nil else { return }
        #if canImport(AppKit)
        lastClipboardChange = NSPasteboard.general.changeCount
        let t = Timer(timeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.pollClipboard() }
        }
        RunLoop.main.add(t, forMode: .common)
        clipboardTimer = t
        #endif
    }
    private func stopClipboardMonitor() { clipboardTimer?.invalidate(); clipboardTimer = nil }

    private func pollClipboard() {
        #if canImport(AppKit)
        let pb = NSPasteboard.general
        guard pb.changeCount != lastClipboardChange else { return }
        lastClipboardChange = pb.changeCount
        guard let s = pb.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines),
              s.hasPrefix("http"), Self.looksLikeMedia(s),
              !jobs.contains(where: { $0.sourceURL == s }) else { return }
        pendingClipboardURL = s
        #endif
    }

    static func looksLikeMedia(_ url: String) -> Bool {
        let hosts = ["youtube.com", "youtu.be", "vimeo.com", "bilibili.com", "b23.tv", "twitter.com", "x.com",
                     "tiktok.com", "instagram.com", "twitch.tv", "dailymotion.com", "soundcloud.com", "facebook.com"]
        let lower = url.lowercased()
        if hosts.contains(where: { lower.contains($0) }) { return true }
        if lower.contains("/watch") || lower.contains("/video/") || lower.contains("/v/") { return true }
        for ext in [".m3u8", ".mp4", ".mp3", ".m4a", ".webm", ".mov"] where lower.contains(ext) { return true }
        return false
    }
    public func dismissClipboardSuggestion() { pendingClipboardURL = nil }

    public func refreshEngineStatus() {
        engineStatus = EngineInstaller.status()
        accelReady = EngineInstaller.hasAria2
    }

    public func installEngine() {
        engineStatus = .installing(0)
        Task {
            do {
                try await installer.installYtDlp(onProgress: { _ in })
                // 合并/音频组件 best-effort（失败不阻断主组件就绪）。
                try? await installer.installFFmpeg()
                refreshEngineStatus()
            } catch {
                engineStatus = .failed((error as? LocalizedError)?.errorDescription ?? "\(error)")
            }
        }
    }

    /// 组件安装可视状态（修复「点补齐组件无反应」——原来 try? 吞错、无 loading）。
    @Published public var componentInstall: ComponentInstall = .idle

    /// 单独补齐合并/音频组件（ffmpeg）。
    public func installMergeComponent() {
        if componentInstall.isInstalling { return }
        componentInstall = .installing(xLoc("合并 / 音频组件"))
        Task {
            do {
                try await installer.installFFmpeg()
                componentInstall = .idle
            } catch {
                componentInstall = .failed((error as? LocalizedError)?.errorDescription ?? "\(error)")
            }
            refreshEngineStatus()
        }
    }

    // MARK: 添加 / 探测

    public func add(urlString: String, kind: DownloadKind = .video, autoStart: Bool = true) {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, (trimmed.contains("://") || trimmed.hasPrefix("magnet:")) else { return }
        if pendingClipboardURL == trimmed { pendingClipboardURL = nil }

        // 磁力 / 种子 → aria2 加速引擎（迅雷式）
        if Self.isTorrentURL(trimmed) {
            addTorrent(trimmed)
            return
        }
        if kind == .image {
            addImageScrape(pageURL: trimmed)
            return
        }
        guard engineStatus.isReady else {
            let job = DownloadJob(sourceURL: trimmed, kind: kind,
                                  state: .failed(reason: DownloadError.engineNotReady.errorDescription ?? "引擎未安装"),
                                  destinationDir: defaultDestination)
            jobs.insert(job, at: 0)
            return
        }
        let job = DownloadJob(sourceURL: trimmed, kind: kind, state: .probing, destinationDir: defaultDestination)
        jobs.insert(job, at: 0)
        let id = job.id
        let probeHandle = ProcessHandle()
        handles[id] = probeHandle   // 让 .probing 期间的 cancel/remove 能真正终止探测进程
        Task {
            do {
                let manifest = try await YtDlpRunner.probe(url: trimmed, handle: probeHandle)
                // 探测期间被取消/移除 → 不覆盖终态
                guard let cur = self.jobs.first(where: { $0.id == id }), !cur.state.isTerminal, !Task.isCancelled else { return }
                update(id) {
                    $0.manifest = manifest
                    $0.title = manifest.title
                    $0.thumbnailURL = manifest.thumbnailURL
                    $0.state = .ready
                }
                if autoStart { start(id) } else { self.handles[id] = nil }   // start() 接管 handles[id]
            } catch {
                guard let cur = self.jobs.first(where: { $0.id == id }), !cur.state.isTerminal else { self.handles[id] = nil; return }
                update(id) { $0.state = .failed(reason: (error as? LocalizedError)?.errorDescription ?? "\(error)") }
                self.handles[id] = nil
            }
        }
    }

    // MARK: 开始下载

    public func start(_ id: UUID) {
        guard let job = jobs.first(where: { $0.id == id }) else { return }
        guard engineStatus.isReady else { update(id) { $0.state = .failed(reason: "请先安装下载引擎") }; return }
        let handle = ProcessHandle()
        handles[id] = handle
        update(id) { $0.state = .downloading(progress: 0, speed: "", eta: "") }
        let fmt = job.chosenFormatID
        let kind = job.kind
        let prefs = preferences

        let (stream, cont) = AsyncStream<DownloadState>.makeStream()
        let cb: @Sendable (DownloadState) -> Void = { cont.yield($0) }

        tasks[id] = Task {
            let consumer = Task { @MainActor in
                for await st in stream { self.applyState(id, st) }
            }
            do {
                let path = try await YtDlpRunner.download(job: job, formatID: fmt, kind: kind, prefs: prefs, handle: handle, onProgress: cb)
                cont.finish(); _ = await consumer.value
                if !(self.jobs.first(where: { $0.id == id })?.state.label == "已取消") {
                    self.update(id) { $0.state = .completed(path: path); $0.outputPath = path }
                }
            } catch {
                cont.finish(); _ = await consumer.value
                if case .canceled = self.jobs.first(where: { $0.id == id })?.state ?? .queued {
                    // 用户取消：保留 canceled
                } else {
                    self.update(id) { $0.state = .failed(reason: (error as? LocalizedError)?.errorDescription ?? "\(error)") }
                }
            }
            self.handles[id] = nil
            self.tasks[id] = nil
        }
    }

    private func applyState(_ id: UUID, _ st: DownloadState) {
        guard let cur = jobs.first(where: { $0.id == id })?.state, !cur.isTerminal else { return }
        update(id) { $0.state = st }
    }

    // MARK: 控制

    public func cancel(_ id: UUID) {
        handles[id]?.terminate()
        tasks[id]?.cancel()
        update(id) { if !$0.state.isTerminal { $0.state = .canceled } }
    }

    public func retry(_ id: UUID) {
        guard let job = jobs.first(where: { $0.id == id }) else { return }
        if Self.isTorrentURL(job.sourceURL) { startTorrent(id) }
        else if job.manifest != nil { start(id) }
        else { let url = job.sourceURL; let k = job.kind; remove(id); add(urlString: url, kind: k) }
    }

    public func remove(_ id: UUID) {
        handles[id]?.terminate()
        tasks[id]?.cancel()
        handles[id] = nil; tasks[id] = nil
        jobs.removeAll { $0.id == id }
    }

    public func chooseFormat(_ id: UUID, formatID: String) { update(id) { $0.chosenFormatID = formatID } }
    public func clearFinished() { jobs.removeAll { $0.state.isTerminal } }
    public func revealInFinder(_ job: DownloadJob) {
        guard let p = job.outputPath else { return }
        #if canImport(AppKit)
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: p)])
        #endif
    }

    // MARK: 磁力 / 种子（aria2）

    public static func isTorrentURL(_ s: String) -> Bool {
        let l = s.lowercased()
        return l.hasPrefix("magnet:") || l.hasSuffix(".torrent")
    }

    private func magnetTitle(_ url: String) -> String {
        if url.hasPrefix("magnet:"), let comps = URLComponents(string: url),
           let dn = comps.queryItems?.first(where: { $0.name == "dn" })?.value, !dn.isEmpty {
            return dn.removingPercentEncoding ?? dn
        }
        if url.lowercased().hasSuffix(".torrent") { return (url as NSString).lastPathComponent }
        return xLoc("磁力任务")
    }

    private func addTorrent(_ url: String) {
        let job = DownloadJob(sourceURL: url, title: magnetTitle(url), kind: .video,
                              state: .queued, destinationDir: defaultDestination)
        jobs.insert(job, at: 0)
        let id = job.id
        guard EngineInstaller.hasAria2 else {
            update(id) { $0.state = .failed(reason: xLoc("磁力 / 种子需要加速组件——请在偏好中一键准备，或 brew install aria2")) }
            return
        }
        startTorrent(id)
    }

    private func startTorrent(_ id: UUID) {
        guard let job = jobs.first(where: { $0.id == id }) else { return }
        let handle = ProcessHandle()
        handles[id] = handle
        update(id) { $0.state = .downloading(progress: 0, speed: "", eta: "") }
        let (stream, cont) = AsyncStream<DownloadState>.makeStream()
        let cb: @Sendable (DownloadState) -> Void = { cont.yield($0) }
        tasks[id] = Task {
            let consumer = Task { @MainActor in for await st in stream { self.applyState(id, st) } }
            do {
                let path = try await Aria2Runner.download(job: job, handle: handle, onProgress: cb)
                cont.finish(); _ = await consumer.value
                self.update(id) { $0.state = .completed(path: path); $0.outputPath = path }
            } catch {
                cont.finish(); _ = await consumer.value
                if case .canceled = self.jobs.first(where: { $0.id == id })?.state ?? .queued {
                } else {
                    self.update(id) { $0.state = .failed(reason: (error as? LocalizedError)?.errorDescription ?? "\(error)") }
                }
            }
            self.handles[id] = nil
            self.tasks[id] = nil
        }
    }

    // 加速组件（aria2）就绪状态 + 安装
    @Published public var accelReady: Bool = EngineInstaller.hasAria2
    public func installAccelComponent() {
        if componentInstall.isInstalling { return }
        componentInstall = .installing(xLoc("磁力 / 种子加速组件"))
        Task {
            do {
                try await installer.installAria2()
                componentInstall = .idle
            } catch {
                componentInstall = .failed((error as? LocalizedError)?.errorDescription ?? "\(error)")
            }
            accelReady = EngineInstaller.hasAria2
        }
    }

    // MARK: 图片抓取（纯 Swift，无外部进程 → 两版都可用）

    private func addImageScrape(pageURL: String) {
        let job = DownloadJob(sourceURL: pageURL, title: pageURL, kind: .image, state: .probing, destinationDir: defaultDestination)
        jobs.insert(job, at: 0)
        let id = job.id
        let dest = defaultDestination
        Task {
            do {
                let urls = try await ImageScraper.scrape(pageURL: pageURL)
                guard !urls.isEmpty else { update(id) { $0.state = .failed(reason: "未在页面找到图片") }; return }
                update(id) { $0.title = "图片 · \(urls.count) 张"; $0.state = .downloading(progress: 0, speed: "", eta: "") }
                let (pstream, pcont) = AsyncStream<(Int, Int)>.makeStream()
                let pcb: @Sendable (Int, Int) -> Void = { pcont.yield(($0, $1)) }
                let consumer = Task { @MainActor in
                    for await (done, total) in pstream {
                        self.applyState(id, .downloading(progress: Double(done) / Double(max(1, total)), speed: "\(done)/\(total)", eta: ""))
                    }
                }
                let saved = try await ImageScraper.downloadAll(urls, to: dest, onProgress: pcb)
                pcont.finish(); _ = await consumer.value
                update(id) { $0.state = .completed(path: saved); $0.outputPath = saved }
            } catch {
                update(id) { $0.state = .failed(reason: (error as? LocalizedError)?.errorDescription ?? "\(error)") }
            }
        }
    }

    private func update(_ id: UUID, _ mutate: (inout DownloadJob) -> Void) {
        guard let idx = jobs.firstIndex(where: { $0.id == id }) else { return }
        var j = jobs[idx]; mutate(&j); jobs[idx] = j
    }
}

#if canImport(AppKit)
import AppKit
#endif

/// 纯 Swift 图片抓取器：srcset / og:image / <img src> / JSON-LD image。无外部进程，沙盒安全。
public enum ImageScraper {
    public static func scrape(pageURL: String) async throws -> [URL] {
        guard let url = URL(string: pageURL) else { throw DownloadError.badURL }
        // 若本身就是图片直链，直接返回。
        if ["jpg", "jpeg", "png", "gif", "webp", "bmp", "svg", "heic", "avif"].contains(url.pathExtension.lowercased()) {
            return [url]
        }
        var req = URLRequest(url: url)
        req.setValue("Mozilla/5.0 (Macintosh) XicoDownloader", forHTTPHeaderField: "User-Agent")
        let (data, _) = try await URLSession.shared.data(for: req)
        guard let html = String(data: data, encoding: .utf8) else { return [] }
        var found = Set<String>()

        func collect(_ pattern: String, group: Int) {
            guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return }
            let ns = html as NSString
            for m in re.matches(in: html, range: NSRange(location: 0, length: ns.length)) where m.numberOfRanges > group {
                let r = m.range(at: group)
                if r.location != NSNotFound { found.insert(ns.substring(with: r)) }
            }
        }
        collect(#"<meta[^>]+property=["']og:image["'][^>]+content=["']([^"']+)["']"#, group: 1)
        collect(#"<meta[^>]+name=["']twitter:image["'][^>]+content=["']([^"']+)["']"#, group: 1)
        collect(#"<img[^>]+src=["']([^"']+\.(?:jpg|jpeg|png|gif|webp|bmp))[^"']*["']"#, group: 1)
        collect(#"srcset=["']([^"']+)["']"#, group: 1)

        var urls: [URL] = []
        for raw in found {
            // srcset 可能是 "a.jpg 1x, b.jpg 2x" —— 取每段第一个 token
            for token in raw.split(separator: ",") {
                let candidate = token.trimmingCharacters(in: .whitespaces).split(separator: " ").first.map(String.init) ?? ""
                if let abs = URL(string: candidate, relativeTo: url)?.absoluteURL, abs.scheme?.hasPrefix("http") == true {
                    urls.append(abs)
                }
            }
        }
        // 去重保序
        var seen = Set<String>()
        return urls.filter { seen.insert($0.absoluteString).inserted }
    }

    public static func downloadAll(_ urls: [URL], to dir: String,
                                   onProgress: @escaping @Sendable (Int, Int) -> Void) async throws -> String {
        let fm = FileManager.default
        try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        var done = 0
        let total = urls.count
        for (i, u) in urls.enumerated() {
            do {
                let (tmp, _) = try await URLSession.shared.download(from: u)
                var name = u.lastPathComponent
                if name.isEmpty || !name.contains(".") { name = "image_\(i).jpg" }
                var dest = URL(fileURLWithPath: dir).appendingPathComponent(name)
                var n = 1
                while fm.fileExists(atPath: dest.path) {
                    dest = URL(fileURLWithPath: dir).appendingPathComponent("\(n)_\(name)"); n += 1
                }
                try? fm.moveItem(at: tmp, to: dest)
            } catch { /* 跳过失败的单张 */ }
            done += 1
            onProgress(done, total)
        }
        return dir
    }
}
