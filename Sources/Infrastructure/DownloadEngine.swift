import Foundation
import Combine
import CommonCrypto
import Domain
import DesignSystem

// 下载引擎：yt-dlp（1000+ 站点抽取）+ 可选 ffmpeg（合并/音频提取）。
// 二进制**不打包**——运行时按需下载到 App Support/Xico/Engines/（法务见 [[downie-downloader-legal-risk]]）。
// 整个文件属于「直销版专属」能力；沙盒 MAS 版可用编译开关排除（XICO_APPSTORE）。

// MARK: 引擎路径与安装

public final class EngineInstaller: @unchecked Sendable {
    // 上游获取端点（用户选定「运行时从上游获取」）。集中成常量，便于将来切换为自有代理。
    // UI 全程只显示「媒体组件」，不露这些地址；归属放 About/许可证页。
    public static let ytDlpDownloadURL = "https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp_macos"
    public static let ytDlpSumsURL = "https://github.com/yt-dlp/yt-dlp/releases/latest/download/SHA2-256SUMS"
    /// 静态 macOS ffmpeg（zip）。优先用 make_app.sh 内置的 LGPL 构建；无内置时按需拉取。
    public static let ffmpegDownloadURL = "https://evermeet.cx/ffmpeg/getrelease/zip"

    public init() {}

    public static func enginesDir() -> URL {
        let base = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        let dir = base.appendingPathComponent("Xico/Engines", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    public static func ytDlpURL() -> URL { enginesDir().appendingPathComponent("yt-dlp") }

    /// 探测 ffmpeg：优先 **App 内置**（make_app.sh 嵌入的 LGPL ffmpeg——完全可合法内置），
    /// 其次 App Support（用户/运行时补齐），最后系统常见路径（Homebrew）。
    public static func ffmpegPath() -> String? {
        var candidates: [String] = []
        // 内置：Contents/Resources/Engines/ffmpeg（LGPL 动态构建、remux-only、无 x264/x265）
        if let res = Bundle.main.resourceURL?.appendingPathComponent("Engines/ffmpeg").path {
            candidates.append(res)
        }
        candidates += [
            enginesDir().appendingPathComponent("ffmpeg").path,
            "/opt/homebrew/bin/ffmpeg",
            "/usr/local/bin/ffmpeg",
            "/opt/local/bin/ffmpeg"
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    // MARK: aria2（磁力 / 种子 / 多线程直链——迅雷式加速下载）

    /// 静态 macOS aria2c（社区构建，按架构选）。同 yt-dlp 的运行时上游获取模型；亦可 brew install aria2。
    public static var aria2DownloadURL: String {
        #if arch(arm64)
        return "https://github.com/q741451/aria2c-macos-standalone-binary/releases/download/v1.0.0/aria2c-macos-arm64.tar.gz"
        #else
        return "https://github.com/q741451/aria2c-macos-standalone-binary/releases/download/v1.0.0/aria2c-macos-x86_64.tar.gz"
        #endif
    }

    public static func aria2Path() -> String? {
        var candidates: [String] = []
        if let res = Bundle.main.resourceURL?.appendingPathComponent("Engines/aria2c").path { candidates.append(res) }
        candidates += [
            enginesDir().appendingPathComponent("aria2c").path,
            "/opt/homebrew/bin/aria2c",
            "/usr/local/bin/aria2c",
            "/opt/local/bin/aria2c"
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }
    public static var hasAria2: Bool { aria2Path() != nil }

    public static func status() -> DownloadEngineStatus {
        FileManager.default.isExecutableFile(atPath: ytDlpURL().path)
            ? .ready(ffmpeg: ffmpegPath() != nil)
            : .notInstalled
    }

    /// 下载 yt-dlp 官方 macOS 二进制到 App Support，校验 SHA-256，chmod +x。
    /// 由用户在 App 内显式点击「安装引擎」触发（不自动、不打包）。
    public func installYtDlp(onProgress: @escaping @Sendable (Double) -> Void) async throws {
        let dest = Self.ytDlpURL()
        guard let url = URL(string: Self.ytDlpDownloadURL) else { throw DownloadError.badURL }
        // 下载
        let (tmp, response) = try await URLSession.shared.download(from: url)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw DownloadError.engine("下载 yt-dlp 失败（HTTP \(http.statusCode)）")
        }
        onProgress(0.7)
        // 校验 SHA-256（尽力而为：拿到官方 SUMS 就严格比对）
        if let sums = try? await fetchString(Self.ytDlpSumsURL) {
            let data = try Data(contentsOf: tmp)
            let digest = Self.sha256Hex(data)
            let expected = sums.split(separator: "\n").first { $0.contains("yt-dlp_macos") && !$0.contains("legacy") }?
                .split(separator: " ").first.map(String.init)
            if let expected, expected.lowercased() != digest.lowercased() {
                throw DownloadError.engine("yt-dlp 校验失败（SHA-256 不匹配），已中止")
            }
        }
        onProgress(0.9)
        // 落盘 + 可执行
        if FileManager.default.fileExists(atPath: dest.path) { try? FileManager.default.removeItem(at: dest) }
        try FileManager.default.moveItem(at: tmp, to: dest)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dest.path)
        onProgress(1.0)
    }

    /// 按需拉取静态 ffmpeg（zip → ditto 解压 → chmod）。best-effort：失败不阻断 yt-dlp。
    public func installFFmpeg() async throws {
        // 已内置（make_app.sh）或系统已有则跳过。
        if let p = Self.ffmpegPath(), p.hasPrefix(Bundle.main.bundleURL.path) || p.contains("/homebrew/") || p.contains("/usr/local/") {
            return
        }
        guard let url = URL(string: Self.ffmpegDownloadURL) else { throw DownloadError.badURL }
        let (tmp, response) = try await URLSession.shared.download(from: url)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw DownloadError.engine("媒体合并组件下载失败（HTTP \(http.statusCode)）")
        }
        let dir = Self.enginesDir()
        let zipPath = dir.appendingPathComponent("ffmpeg.zip")
        try? FileManager.default.removeItem(at: zipPath)
        try FileManager.default.moveItem(at: tmp, to: zipPath)
        // ditto 解压（macOS 原生、稳）
        let code: Int32 = await withCheckedContinuation { cont in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            p.arguments = ["-x", "-k", zipPath.path, dir.path]
            p.terminationHandler = { cont.resume(returning: $0.terminationStatus) }
            do { try p.run() } catch { cont.resume(returning: -1) }
        }
        try? FileManager.default.removeItem(at: zipPath)
        let ff = dir.appendingPathComponent("ffmpeg")
        guard code == 0, FileManager.default.fileExists(atPath: ff.path) else {
            throw DownloadError.engine("媒体合并组件解压失败")
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: ff.path)
    }

    /// 按需拉取静态 aria2c（tar.gz → tar 解压 → chmod）。best-effort。
    public func installAria2() async throws {
        if let p = Self.aria2Path(), p.contains("/homebrew/") || p.contains("/usr/local/") || p.hasPrefix(Bundle.main.bundleURL.path) {
            return
        }
        guard let url = URL(string: Self.aria2DownloadURL) else { throw DownloadError.badURL }
        let (tmp, response) = try await URLSession.shared.download(from: url)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw DownloadError.engine("下载加速组件失败（HTTP \(http.statusCode)）")
        }
        let dir = Self.enginesDir()
        let tarPath = dir.appendingPathComponent("aria2c.tar.gz")
        try? FileManager.default.removeItem(at: tarPath)
        try FileManager.default.moveItem(at: tmp, to: tarPath)
        let code: Int32 = await withCheckedContinuation { cont in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
            p.arguments = ["-xzf", tarPath.path, "-C", dir.path]
            p.terminationHandler = { cont.resume(returning: $0.terminationStatus) }
            do { try p.run() } catch { cont.resume(returning: -1) }
        }
        try? FileManager.default.removeItem(at: tarPath)
        // 解压产物可能是 dir/aria2c 或嵌套一层——找出来放到 dir/aria2c。
        let target = dir.appendingPathComponent("aria2c")
        if !FileManager.default.isExecutableFile(atPath: target.path) {
            if let items = try? FileManager.default.contentsOfDirectory(atPath: dir.path) {
                for item in items {
                    let sub = dir.appendingPathComponent(item)
                    let nested = sub.appendingPathComponent("aria2c")
                    if FileManager.default.fileExists(atPath: nested.path) {
                        try? FileManager.default.moveItem(at: nested, to: target); break
                    }
                }
            }
        }
        guard code == 0, FileManager.default.fileExists(atPath: target.path) else {
            throw DownloadError.engine("加速组件解压失败——可改用 brew install aria2")
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: target.path)
    }

    private func fetchString(_ urlString: String) async throws -> String {
        guard let url = URL(string: urlString) else { throw DownloadError.badURL }
        let (data, _) = try await URLSession.shared.data(from: url)
        return String(data: data, encoding: .utf8) ?? ""
    }

    static func sha256Hex(_ data: Data) -> String {
        var hash = [UInt8](repeating: 0, count: 32)
        data.withUnsafeBytes { _ = CC_SHA256($0.baseAddress, CC_LONG(data.count), &hash) }
        return hash.map { String(format: "%02x", $0) }.joined()
    }
}

public enum DownloadError: Error, LocalizedError {
    case badURL
    case engineNotReady
    case engine(String)
    public var errorDescription: String? {
        switch self {
        case .badURL: return "无效链接"
        case .engineNotReady: return "下载引擎未安装：请先在页面顶部安装引擎"
        case .engine(let m): return m
        }
    }
}

// MARK: yt-dlp 调用

/// 供取消：持有正在运行的 Process。
public final class ProcessHandle: @unchecked Sendable {
    private let lock = NSLock()
    private var _process: Process?
    public init() {}
    func set(_ p: Process?) { lock.lock(); _process = p; lock.unlock() }
    public func terminate() { lock.lock(); let p = _process; lock.unlock(); p?.terminate() }
}

public enum YtDlpRunner {

    // yt-dlp -J 的最小 JSON 结构
    private struct RawFormat: Decodable {
        let format_id: String?
        let ext: String?
        let height: Int?
        let fps: Double?
        let vcodec: String?
        let acodec: String?
        let filesize: Int64?
        let filesize_approx: Int64?
        let format_note: String?
    }
    private struct RawInfo: Decodable {
        let _type: String?
        let title: String?
        let uploader: String?
        let duration: Double?
        let thumbnail: String?
        let webpage_url: String?
        let extractor: String?
        let playlist_count: Int?
        let formats: [RawFormat]?
    }

    /// 探测（yt-dlp -J）。返回媒体清单。handle 便于取消。
    public static func probe(url: String, handle: ProcessHandle? = nil) async throws -> MediaManifest {
        let ytdlp = EngineInstaller.ytDlpURL()
        guard FileManager.default.isExecutableFile(atPath: ytdlp.path) else { throw DownloadError.engineNotReady }
        var (code, out) = await runCollecting(executable: ytdlp, args: ["-J", "--no-warnings", "--socket-timeout", "20", "--flat-playlist", url], handle: handle)
        if Task.isCancelled { throw CancellationError() }
        if code != 0 || out.isEmpty {
            // 退回非 flat（部分单视频 flat 会缺 formats）
            (code, out) = await runCollecting(executable: ytdlp, args: ["-J", "--no-warnings", "--socket-timeout", "20", url], handle: handle)
        }
        guard let info = try? JSONDecoder().decode(RawInfo.self, from: out) else {
            let msg = String(data: out, encoding: .utf8).map { String($0.prefix(160)) } ?? ""
            throw DownloadError.engine("解析失败：\(msg.isEmpty ? "无法读取媒体信息" : msg)")
        }
        let isPlaylist = (info._type == "playlist")
        let formats: [MediaFormat] = (info.formats ?? []).compactMap { f in
            guard let fid = f.format_id else { return nil }
            return MediaFormat(formatID: fid, ext: f.ext ?? "mp4", height: f.height, fps: f.fps,
                               vcodec: f.vcodec, acodec: f.acodec,
                               filesizeApprox: f.filesize ?? f.filesize_approx, note: f.format_note)
        }
        return MediaManifest(
            title: info.title ?? url, uploader: info.uploader, durationSeconds: info.duration,
            thumbnailURL: info.thumbnail, webpageURL: info.webpage_url ?? url, extractor: info.extractor,
            isPlaylist: isPlaylist, playlistCount: info.playlist_count ?? 1, formats: formats)
    }

    /// 下载。progress 回调发出 DownloadState；返回最终文件路径。
    public static func download(job: DownloadJob, formatID: String?, kind: DownloadKind,
                                prefs: DownloadPreferences,
                                handle: ProcessHandle,
                                onProgress: @escaping @Sendable (DownloadState) -> Void) async throws -> String {
        let ytdlp = EngineInstaller.ytDlpURL()
        guard FileManager.default.isExecutableFile(atPath: ytdlp.path) else { throw DownloadError.engineNotReady }
        let hasFFmpeg = EngineInstaller.ffmpegPath() != nil
        let outTemplate = job.destinationDir + "/%(title).200B [%(id)s].%(ext)s"
        var args: [String] = [job.sourceURL, "-o", outTemplate, "--newline", "--no-warnings", "--no-part",
                              "--progress-template", "download:@@P|%(progress._percent_str)s|%(progress._speed_str)s|%(progress._eta_str)s",
                              "--print", "after_move:@@FILE|%(filepath)s"]
        if let ff = EngineInstaller.ffmpegPath() {
            args += ["--ffmpeg-location", (ff as NSString).deletingLastPathComponent]
        }
        switch kind {
        case .audio:
            args += ["-f", "bestaudio/best", "-x", "--audio-format", prefs.audioFormat]
        case .video, .image:
            if let f = formatID {
                args += ["-f", hasFFmpeg ? "\(f)+bestaudio/best" : f]
            } else if let h = prefs.videoQuality.height {
                // 画质上限：优先最佳 ≤H 的视频+音频（有 ffmpeg 合并），否则单一渐进流。
                args += ["-f", hasFFmpeg ? "bv*[height<=\(h)]+ba/b[height<=\(h)]/b" : "b[height<=\(h)]/best"]
            } else {
                args += ["-f", hasFFmpeg ? "bv*+ba/b" : "best"]
            }
            // 后处理（需 ffmpeg）：字幕 / 元数据 / 缩略图。
            if prefs.embedSubtitles {
                args += ["--write-subs", "--sub-langs", prefs.subtitleLangs]
                if hasFFmpeg { args += ["--embed-subs"] }
            }
            if hasFFmpeg && prefs.embedMetadata { args += ["--embed-metadata"] }
            if hasFFmpeg && prefs.embedThumbnail { args += ["--embed-thumbnail"] }
        }

        let finalPath = ValueBox<String?>(nil)
        let code = await runCollectingLines(executable: ytdlp, args: args, handle: handle) { line in
            if line.hasPrefix("@@P|") {
                let parts = line.dropFirst(4).split(separator: "|", omittingEmptySubsequences: false).map(String.init)
                let pct = parts.first.flatMap { parsePercent($0) } ?? 0
                let speed = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespaces) : ""
                let eta = parts.count > 2 ? parts[2].trimmingCharacters(in: .whitespaces) : ""
                onProgress(.downloading(progress: pct, speed: speed, eta: eta == "NA" ? "" : eta))
            } else if line.hasPrefix("@@FILE|") {
                finalPath.value = String(line.dropFirst(7)).trimmingCharacters(in: .whitespaces)
            } else if line.contains("[Merger]") || line.contains("[ExtractAudio]") || line.contains("Merging") {
                onProgress(.postprocessing)
            }
        }
        if code != 0 { throw DownloadError.engine("下载失败（yt-dlp 退出码 \(code)）") }
        return finalPath.value ?? job.destinationDir
    }

    private static func parsePercent(_ s: String) -> Double? {
        let cleaned = s.replacingOccurrences(of: "%", with: "").trimmingCharacters(in: .whitespaces)
        return Double(cleaned).map { $0 / 100 }
    }

    // MARK: Process 执行（nonisolated，跑在后台）
    // readabilityHandler 是 @Sendable 且在后台队列串行调用——用引用型 pump（@unchecked Sendable + 锁）
    // 承载可变缓冲与回调，绕开「@Sendable 闭包捕获可变 var / 非 Sendable 闭包」的严格并发限制。

    private static func runCollecting(executable: URL, args: [String], handle: ProcessHandle?) async -> (Int32, Data) {
        let pump = DataPump()
        let code: Int32 = await withCheckedContinuation { cont in
            let proc = Process()
            proc.executableURL = executable
            proc.arguments = args
            let outPipe = Pipe()
            proc.standardOutput = outPipe
            proc.standardError = outPipe   // stderr 也走同一被排空的管道，避免 stderr 写满缓冲区阻塞不退出
            outPipe.fileHandleForReading.readabilityHandler = { fh in pump.feed(fh.availableData) }
            proc.terminationHandler = { p in
                outPipe.fileHandleForReading.readabilityHandler = nil
                let trailing = outPipe.fileHandleForReading.readDataToEndOfFile()  // 排空尾部残留
                if !trailing.isEmpty { pump.feed(trailing) }
                cont.resume(returning: p.terminationStatus)
            }
            do { try proc.run(); handle?.set(proc) }
            catch { cont.resume(returning: -1) }
        }
        return (code, pump.collected())
    }

    private static func runCollectingLines(executable: URL, args: [String], handle: ProcessHandle?,
                                           onLine: @escaping @Sendable (String) -> Void) async -> Int32 {
        let pump = LinePump(onLine: onLine)
        return await withCheckedContinuation { cont in
            let proc = Process()
            proc.executableURL = executable
            proc.arguments = args
            let outPipe = Pipe()
            proc.standardOutput = outPipe
            proc.standardError = outPipe
            outPipe.fileHandleForReading.readabilityHandler = { fh in pump.feed(fh.availableData) }
            proc.terminationHandler = { p in
                outPipe.fileHandleForReading.readabilityHandler = nil
                let trailing = outPipe.fileHandleForReading.readDataToEndOfFile()  // 排空尾部（含 --print 的 @@FILE 行）
                if !trailing.isEmpty { pump.feed(trailing) }
                cont.resume(returning: p.terminationStatus)
            }
            do { try proc.run(); handle?.set(proc) }
            catch { cont.resume(returning: -1) }
        }
    }
}

// MARK: - Process 输出泵（@unchecked Sendable + 锁）

private final class DataPump: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    func feed(_ d: Data) { lock.lock(); data.append(d); lock.unlock() }
    func collected() -> Data { lock.lock(); defer { lock.unlock() }; return data }
}

private final class LinePump: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()
    private let onLine: @Sendable (String) -> Void
    init(onLine: @escaping @Sendable (String) -> Void) { self.onLine = onLine }
    func feed(_ d: Data) {
        lock.lock(); defer { lock.unlock() }
        buffer.append(d)
        while let idx = buffer.firstIndex(where: { $0 == 0x0A || $0 == 0x0D }) {
            let lineData = buffer.subdata(in: buffer.startIndex..<idx)
            buffer.removeSubrange(buffer.startIndex...idx)
            if let line = String(data: lineData, encoding: .utf8), !line.isEmpty { onLine(line) }
        }
    }
}

/// 简单的引用型可变盒子（@unchecked Sendable），供 @Sendable 回调里累积单值。
private final class ValueBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: T
    init(_ v: T) { _value = v }
    var value: T { get { lock.lock(); defer { lock.unlock() }; return _value } set { lock.lock(); _value = newValue; lock.unlock() } }
}

// MARK: - aria2 磁力 / 种子 / 加速直链下载（迅雷式）

public enum Aria2Runner {
    public static func download(job: DownloadJob, handle: ProcessHandle,
                                onProgress: @escaping @Sendable (DownloadState) -> Void) async throws -> String {
        guard let aria2 = EngineInstaller.aria2Path() else {
            throw DownloadError.engine("磁力 / 种子下载需要加速组件——请在下载器偏好中一键准备，或 brew install aria2")
        }
        let args = ["--dir", job.destinationDir, "--seed-time=0", "--summary-interval=1",
                    "--console-log-level=notice", "--bt-save-metadata=true", "--enable-color=false",
                    "--allow-overwrite=true", "--auto-file-renaming=false",
                    "--max-connection-per-server=8", "--split=8", "--continue=true",
                    "--bt-max-peers=100", "--follow-torrent=true", job.sourceURL]
        let code = await spawnProcessLines(executable: URL(fileURLWithPath: aria2), args: args, handle: handle) { line in
            guard let pctStr = firstCapture(line, #"\((\d+)%\)"#), let pct = Double(pctStr) else {
                if line.contains("(OK)") || line.lowercased().contains("download complete") { onProgress(.postprocessing) }
                return
            }
            let speed = firstCapture(line, #"DL:([0-9.]+[A-Za-z]+)"#) ?? ""
            let eta = firstCapture(line, #"ETA:([0-9smhd]+)"#) ?? ""
            onProgress(.downloading(progress: min(1, pct / 100), speed: speed, eta: eta))
        }
        if code != 0 { throw DownloadError.engine("磁力下载失败（引擎退出码 \(code)）") }
        return job.destinationDir
    }
}

private func firstCapture(_ s: String, _ pattern: String) -> String? {
    guard let re = try? NSRegularExpression(pattern: pattern) else { return nil }
    let ns = s as NSString
    guard let m = re.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)), m.numberOfRanges > 1 else { return nil }
    let r = m.range(at: 1)
    return r.location == NSNotFound ? nil : ns.substring(with: r)
}

private func spawnProcessLines(executable: URL, args: [String], handle: ProcessHandle?,
                               onLine: @escaping @Sendable (String) -> Void) async -> Int32 {
    let pump = LinePump(onLine: onLine)
    return await withCheckedContinuation { cont in
        let proc = Process()
        proc.executableURL = executable
        proc.arguments = args
        let outPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = outPipe
        outPipe.fileHandleForReading.readabilityHandler = { fh in pump.feed(fh.availableData) }
        proc.terminationHandler = { p in
            outPipe.fileHandleForReading.readabilityHandler = nil
            let trailing = outPipe.fileHandleForReading.readDataToEndOfFile()
            if !trailing.isEmpty { pump.feed(trailing) }
            cont.resume(returning: p.terminationStatus)
        }
        do { try proc.run(); handle?.set(proc) }
        catch { cont.resume(returning: -1) }
    }
}
