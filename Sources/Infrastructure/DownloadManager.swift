import Foundation
import Combine
import Domain
import DesignSystem

/// 下载队列管理器（对标 Downie 的队列）。@MainActor 发布，进度经 Sendable 的 AsyncStream 从后台桥回主线程。
@MainActor
public final class DownloadManager: ObservableObject {
    @Published public private(set) var jobs: [DownloadJob] = [] {
        didSet { scheduleJobsPersistence() }
    }
    @Published public private(set) var engineStatus: DownloadEngineStatus = .notInstalled
    @Published public var defaultDestination: String
    @Published public var preferences: DownloadPreferences
    /// 剪贴板监听命中的待确认链接（对标 Downie 的自动捕获）。
    @Published public var pendingClipboardURL: String?

    private let installer = EngineInstaller()
    private var handles: [UUID: ProcessHandle] = [:]
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private let prefsKey = "xico.download.prefs.v1"
    private let defaults: UserDefaults
    private let queueURL: URL
    private var persistenceTask: Task<Void, Never>?
    private var clipboardTimer: Timer?
    private var lastClipboardChange: Int = -1

    public init(defaults: UserDefaults = .standard, persistenceDirectory: URL? = nil) {
        self.defaults = defaults
        let base = persistenceDirectory ?? ((try? FileManager.default.url(for: .applicationSupportDirectory,
                                                                           in: .userDomainMask,
                                                                           appropriateFor: nil, create: true))
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support"))
            .appendingPathComponent("Xico", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: NSNumber(value: Int16(0o700))])
        try? FileManager.default.setAttributes([.posixPermissions: NSNumber(value: Int16(0o700))], ofItemAtPath: base.path)
        self.queueURL = base.appendingPathComponent("download-queue-v1.json")
        defaultDestination = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Downloads").path
        if let data = defaults.data(forKey: "xico.download.prefs.v1"),
           let p = try? JSONDecoder().decode(DownloadPreferences.self, from: data) {
            preferences = p
        } else {
            preferences = DownloadPreferences()
        }
        if let data = try? Data(contentsOf: queueURL), data.count <= 16 * 1_024 * 1_024,
           let restored = try? JSONDecoder().decode([DownloadJob].self, from: data) {
            jobs = restored.prefix(500).compactMap(Self.validRestoredJob)
        }
        engineStatus = EngineInstaller.status()
        if preferences.clipboardMonitor { startClipboardMonitor() }
    }

    public func savePreferences() {
        if let data = try? JSONEncoder().encode(preferences) { defaults.set(data, forKey: prefsKey) }
        if preferences.clipboardMonitor { startClipboardMonitor() } else { stopClipboardMonitor() }
        pumpQueue()   // 并发上限可能被调高，补跑排队任务
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

    private static func validRestoredJob(_ value: DownloadJob) -> DownloadJob? {
        guard !value.sourceURL.isEmpty, value.sourceURL.utf8.count <= 32_768,
              !value.destinationDir.isEmpty, value.destinationDir.utf8.count <= 16_384,
              value.title.utf8.count <= 8_192 else { return nil }
        var job = value
        // 应用退出时子进程已经不存在；把中断态恢复成明确、可继续的暂停态，绝不伪装为仍在下载。
        switch job.state {
        case .probing, .downloading, .postprocessing, .queued: job.state = .paused
        default: break
        }
        return job
    }

    private func scheduleJobsPersistence() {
        persistenceTask?.cancel()
        let snapshot = Array(jobs.prefix(500))
        let url = queueURL
        persistenceTask = Task {
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled, let data = try? JSONEncoder().encode(snapshot) else { return }
            try? data.write(to: url, options: [.atomic, .completeFileProtection])
            try? FileManager.default.setAttributes([.posixPermissions: NSNumber(value: Int16(0o600))],
                                                    ofItemAtPath: url.path)
        }
    }

    public func prepareForTermination() {
        stopClipboardMonitor()
        for handle in handles.values { handle.terminate() }
        for task in tasks.values { task.cancel() }
        persistenceTask?.cancel()
        persistJobsNow()
    }

    private func persistJobsNow() {
        guard let data = try? JSONEncoder().encode(Array(jobs.prefix(500))) else { return }
        try? data.write(to: queueURL, options: [.atomic, .completeFileProtection])
        try? FileManager.default.setAttributes([.posixPermissions: NSNumber(value: Int16(0o600))],
                                                ofItemAtPath: queueURL.path)
    }

    private func pollClipboard() {
        #if canImport(AppKit)
        let pb = NSPasteboard.general
        guard pb.changeCount != lastClipboardChange else { return }
        lastClipboardChange = pb.changeCount
        guard let raw = pb.string(forType: .string),
              let s = Self.normalizedSource(raw, kind: .video),
              Self.looksLikeMedia(s),
              !jobs.contains(where: { $0.sourceURL == s }) else { return }
        pendingClipboardURL = s
        #endif
    }

    nonisolated static func looksLikeMedia(_ url: String) -> Bool {
        let hosts = ["youtube.com", "youtu.be", "vimeo.com", "bilibili.com", "b23.tv", "twitter.com", "x.com",
                     "tiktok.com", "instagram.com", "twitch.tv", "dailymotion.com", "soundcloud.com", "facebook.com"]
        guard let parsed = URL(string: url) else { return false }
        if let host = parsed.host?.lowercased(),
           hosts.contains(where: { host == $0 || host.hasSuffix(".\($0)") }) { return true }
        return ["m3u8", "mp4", "mp3", "m4a", "webm", "mov"]
            .contains(parsed.pathExtension.lowercased())
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

    @discardableResult
    public func add(urlString: String, kind: DownloadKind = .video, autoStart: Bool = true) -> Bool {
        let received = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !received.isEmpty else { return false }
        guard let trimmed = Self.normalizedSource(received, kind: kind) else {
            // “接收但不执行”：输入仍进入队列供用户看见/移除，不会静默丢失；同时绝不把
            // file/javascript/带凭据 URL/畸形 magnet 传给 yt-dlp、aria2 或系统进程。
            let display = String(received.prefix(2_048))
            let job = DownloadJob(sourceURL: display, title: xLoc("已隔离的输入"), kind: kind,
                                  state: .quarantined(reason: xLoc("已接收但未执行 · 请改用 HTTP、HTTPS 或有效磁力链接")),
                                  destinationDir: defaultDestination)
            jobs.insert(job, at: 0)
            return true
        }
        if pendingClipboardURL == trimmed { pendingClipboardURL = nil }

        // 磁力 / 种子 → aria2 加速引擎（迅雷式）
        if Self.isTorrentURL(trimmed) {
            addTorrent(trimmed)
            return true
        }
        if kind == .image {
            addImageScrape(pageURL: trimmed)
            return true
        }
        guard engineStatus.isReady else {
            let job = DownloadJob(sourceURL: trimmed, kind: kind,
                                  state: .failed(reason: DownloadError.engineNotReady.errorDescription ?? "引擎未安装"),
                                  destinationDir: defaultDestination)
            jobs.insert(job, at: 0)
            return true
        }
        let job = DownloadJob(sourceURL: trimmed, kind: kind, state: .probing, destinationDir: defaultDestination)
        jobs.insert(job, at: 0)
        let id = job.id
        let probeHandle = ProcessHandle()
        handles[id] = probeHandle   // 让 .probing 期间的 cancel/remove 能真正终止探测进程
        let cookies = preferences.cookiesBrowser
        Task {
            do {
                let manifest = try await YtDlpRunner.probe(url: trimmed, handle: probeHandle, cookiesBrowser: cookies)
                // 探测期间被取消/移除 → 不覆盖终态
                guard let cur = self.jobs.first(where: { $0.id == id }), !cur.state.isTerminal, !Task.isCancelled else { return }
                update(id) {
                    $0.manifest = manifest
                    $0.title = manifest.title
                    $0.thumbnailURL = manifest.thumbnailURL
                    $0.state = .ready
                }
                if autoStart { startOrQueue(id) } else { self.handles[id] = nil }   // 并发受限则排队
            } catch {
                guard let cur = self.jobs.first(where: { $0.id == id }), !cur.state.isTerminal else { self.handles[id] = nil; return }
                update(id) { $0.state = .failed(reason: (error as? LocalizedError)?.errorDescription ?? "\(error)") }
                self.handles[id] = nil
            }
        }
        return true
    }

    /// 所有入口（手填、剪贴板、深链、浏览器扩展）共用的链接闸门。
    /// 只接受 http(s) 与结构完整的 magnet，拒绝 file/javascript/任意自定义 scheme，
    /// 同时限制长度，避免恶意深链把超长参数灌进任务队列或外部进程。
    nonisolated public static func normalizedSource(_ raw: String, kind: DownloadKind) -> String? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.utf8.count <= 32_768 else { return nil }
        if value.lowercased().hasPrefix("magnet:") {
            guard kind != .image,
                  let c = URLComponents(string: value), c.scheme?.lowercased() == "magnet",
                  c.queryItems?.contains(where: {
                      $0.name.lowercased() == "xt" && ($0.value?.lowercased().hasPrefix("urn:btih:") == true)
                  }) == true else { return nil }
            return value
        }
        guard let c = URLComponents(string: value),
              let scheme = c.scheme?.lowercased(), scheme == "https" || scheme == "http",
              let host = c.host, !host.isEmpty,
              c.user == nil, c.password == nil else { return nil }
        return c.url?.absoluteString
    }

    // MARK: 并发队列（对标 Downie 的并发下载）

    /// 正在实际下载（占用并发槽）的任务数。probing 不计（探测很快）。
    public var downloadingCount: Int {
        jobs.filter { if case .downloading = $0.state { return true }; if case .postprocessing = $0.state { return true }; return false }.count
    }

    /// 有空槽就开始下载，否则排队。torrent 与普通任务共用同一并发上限。
    public func startOrQueue(_ id: UUID) {
        guard let job = jobs.first(where: { $0.id == id }) else { return }
        guard tasks[id] == nil else { return }
        switch job.state {
        case .ready, .queued, .paused, .failed, .canceled: break
        default: return
        }
        if downloadingCount < preferences.maxConcurrent {
            if job.kind == .image { startImage(id) }
            else if Self.isTorrentURL(job.sourceURL) { startTorrent(id) }
            else { start(id) }
        } else {
            handles[id] = nil
            update(id) { $0.state = .queued }
        }
    }

    /// 有空槽时把排队中的任务补上（在任一任务结束/暂停/取消/移除后调用）。
    private func pumpQueue() {
        while downloadingCount < preferences.maxConcurrent {
            // FIFO：先入队的（列表末尾，因新任务插在最前）优先。
            guard let next = jobs.last(where: { if case .queued = $0.state { return true }; return false }) else { break }
            if next.kind == .image { startImage(next.id) }
            else if Self.isTorrentURL(next.sourceURL) { startTorrent(next.id) }
            else { start(next.id) }
        }
    }

    // MARK: 开始下载

    public func start(_ id: UUID) {
        guard let job = jobs.first(where: { $0.id == id }) else { return }
        guard tasks[id] == nil, job.kind != .image, !Self.isTorrentURL(job.sourceURL) else { return }
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
                let cur = self.jobs.first(where: { $0.id == id })?.state ?? .queued
                if case .canceled = cur { /* 用户取消：保留 */ }
                else if case .paused = cur { /* 用户暂停：保留 */ }
                else { self.update(id) { $0.state = .completed(path: path); $0.outputPath = path } }
            } catch {
                cont.finish(); _ = await consumer.value
                let cur = self.jobs.first(where: { $0.id == id })?.state ?? .queued
                if case .canceled = cur { /* 保留取消 */ }
                else if case .paused = cur { /* 保留暂停（可续传） */ }
                else { self.update(id) { $0.state = .failed(reason: (error as? LocalizedError)?.errorDescription ?? "\(error)") } }
            }
            self.handles[id] = nil
            self.tasks[id] = nil
            self.pumpQueue()
        }
    }

    private func applyState(_ id: UUID, _ st: DownloadState) {
        guard let cur = jobs.first(where: { $0.id == id })?.state, !cur.isTerminal else { return }
        if case .paused = cur { return }   // 暂停后忽略缓冲的进度回调
        update(id) { $0.state = st }
    }

    // MARK: 控制

    public func cancel(_ id: UUID) {
        handles[id]?.terminate()
        tasks[id]?.cancel()
        update(id) { if !$0.state.isTerminal { $0.state = .canceled } }
        pumpQueue()
    }

    /// 暂停（保留 .part，可续传）。仅对进行中的下载有意义。
    public func pause(_ id: UUID) {
        guard let st = jobs.first(where: { $0.id == id })?.state else { return }
        switch st {
        case .downloading, .postprocessing, .probing:
            update(id) { $0.state = .paused }   // 先置状态，让完成回调识别为「暂停」而非「失败」
            handles[id]?.terminate()
            tasks[id]?.cancel()
            pumpQueue()
        case .queued:
            update(id) { $0.state = .paused }   // 排队中直接转暂停
        default: break
        }
    }

    /// 继续（有空槽即续传，否则排队）。yt-dlp/aria2 的 --continue 会从 .part 续起。
    public func resume(_ id: UUID) {
        guard let st = jobs.first(where: { $0.id == id })?.state, case .paused = st else { return }
        startOrQueue(id)
    }

    public func retry(_ id: UUID) {
        guard let job = jobs.first(where: { $0.id == id }) else { return }
        if job.kind == .image { startOrQueue(id) }
        else if Self.isTorrentURL(job.sourceURL) { startOrQueue(id) }
        else if job.manifest != nil { startOrQueue(id) }
        else { let url = job.sourceURL; let k = job.kind; remove(id); add(urlString: url, kind: k) }
    }

    public func remove(_ id: UUID) {
        handles[id]?.terminate()
        tasks[id]?.cancel()
        handles[id] = nil; tasks[id] = nil
        jobs.removeAll { $0.id == id }
        pumpQueue()
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
        startOrQueue(id)
    }

    private func startTorrent(_ id: UUID) {
        guard let job = jobs.first(where: { $0.id == id }) else { return }
        guard tasks[id] == nil, Self.isTorrentURL(job.sourceURL) else { return }
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
                let cur = self.jobs.first(where: { $0.id == id })?.state ?? .queued
                if case .canceled = cur {} else if case .paused = cur {}
                else { self.update(id) { $0.state = .completed(path: path); $0.outputPath = path } }
            } catch {
                cont.finish(); _ = await consumer.value
                let cur = self.jobs.first(where: { $0.id == id })?.state ?? .queued
                if case .canceled = cur {} else if case .paused = cur {}
                else { self.update(id) { $0.state = .failed(reason: (error as? LocalizedError)?.errorDescription ?? "\(error)") } }
            }
            self.handles[id] = nil
            self.tasks[id] = nil
            self.pumpQueue()
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
        let job = DownloadJob(sourceURL: pageURL, title: pageURL, kind: .image, state: .queued, destinationDir: defaultDestination)
        jobs.insert(job, at: 0)
        startOrQueue(job.id)
    }

    /// 图片抓取纳入与视频/磁力相同的并发与取消状态机。旧实现未保存 Task：暂停/取消后
    /// URLSession 仍继续跑，最后还会把状态覆盖成“已完成”；恢复时更会误走 yt-dlp。
    private func startImage(_ id: UUID) {
        guard let job = jobs.first(where: { $0.id == id }), job.kind == .image, tasks[id] == nil else { return }
        update(id) { $0.state = .downloading(progress: 0, speed: xLoc("正在解析页面"), eta: "") }
        let pageURL = job.sourceURL
        let dest = job.destinationDir
        tasks[id] = Task {
            do {
                let urls = try await ImageScraper.scrape(pageURL: pageURL)
                try Task.checkCancellation()
                guard !urls.isEmpty else { throw DownloadError.engine("未在页面找到图片") }
                update(id) { $0.title = "图片 · \(urls.count) 张"; $0.state = .downloading(progress: 0, speed: "", eta: "") }
                let (pstream, pcont) = AsyncStream<(Int, Int)>.makeStream()
                let pcb: @Sendable (Int, Int) -> Void = { pcont.yield(($0, $1)) }
                let consumer = Task { @MainActor in
                    for await (done, total) in pstream {
                        self.applyState(id, .downloading(progress: Double(done) / Double(max(1, total)), speed: "\(done)/\(total)", eta: ""))
                    }
                }
                let saved: String
                do {
                    saved = try await ImageScraper.downloadAll(urls, to: dest, onProgress: pcb)
                } catch {
                    pcont.finish(); _ = await consumer.value
                    throw error
                }
                pcont.finish(); _ = await consumer.value
                let current = jobs.first(where: { $0.id == id })?.state
                if case .paused = current {} else if case .canceled = current {}
                else { update(id) { $0.state = .completed(path: saved); $0.outputPath = saved } }
            } catch is CancellationError {
                // pause/cancel 已先写入用户可理解的状态，不让取消异常覆盖它。
            } catch {
                let current = jobs.first(where: { $0.id == id })?.state
                if case .paused = current {} else if case .canceled = current {}
                else { update(id) { $0.state = .failed(reason: (error as? LocalizedError)?.errorDescription ?? "\(error)") } }
            }
            tasks[id] = nil
            pumpQueue()
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
        req.timeoutInterval = 30
        req.cachePolicy = .reloadIgnoringLocalCacheData
        req.setValue("Mozilla/5.0 (Macintosh) XicoDownloader", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw DownloadError.engine("页面读取失败")
        }
        guard http.expectedContentLength <= 8_388_608 || http.expectedContentLength < 0,
              data.count <= 8_388_608 else {
            throw DownloadError.engine("页面过大，已停止解析")
        }
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
        var saved = 0
        let total = urls.count
        for (i, u) in urls.enumerated() {
            try Task.checkCancellation()
            do {
                let (tmp, response) = try await URLSession.shared.download(from: u)
                guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
                      http.expectedContentLength < 0 || http.expectedContentLength <= 209_715_200 else { continue }
                let actualSize = ((try? fm.attributesOfItem(atPath: tmp.path)[.size]) as? NSNumber)?.int64Value ?? -1
                guard actualSize > 0, actualSize <= 209_715_200 else { continue }
                var name = safeFileName(response.suggestedFilename ?? u.lastPathComponent)
                if name.isEmpty || !name.contains(".") { name = "image_\(i).jpg" }
                var dest = URL(fileURLWithPath: dir).appendingPathComponent(name)
                var n = 1
                while fm.fileExists(atPath: dest.path) {
                    dest = URL(fileURLWithPath: dir).appendingPathComponent("\(n)_\(name)"); n += 1
                }
                try fm.moveItem(at: tmp, to: dest)
                saved += 1
            } catch is CancellationError {
                throw CancellationError()
            } catch { /* 单张失败不拖垮整批，但最终必须至少成功一张 */ }
            done += 1
            onProgress(done, total)
        }
        guard saved > 0 else { throw DownloadError.engine("图片下载失败：没有文件成功保存") }
        return dir
    }

    private static func safeFileName(_ raw: String) -> String {
        let forbidden = CharacterSet.controlCharacters.union(CharacterSet(charactersIn: "/\\:"))
        let pieces = raw.unicodeScalars.map { forbidden.contains($0) ? "_" : String($0) }
        let name = pieces.joined().trimmingCharacters(in: .whitespacesAndNewlines)
        if name == "." || name == ".." || name.hasPrefix(".") { return "image_\(name.replacingOccurrences(of: ".", with: "_"))" }
        return String(name.prefix(180))
    }
}
