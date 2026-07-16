import Foundation
import Combine
import CommonCrypto
import Darwin
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
    private let componentCatalog: ComponentManifestService

    public init(componentCatalog: ComponentManifestService = .live()) {
        self.componentCatalog = componentCatalog
    }

    public static func enginesDir() -> URL {
        let fm = FileManager.default
        let base = (try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        let dir = base.appendingPathComponent("Xico/Engines", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true,
                                attributes: [.posixPermissions: 0o700])
        try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
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
        let tmp: URL
        if componentCatalog.isConfigured {
            let descriptor = try await componentCatalog.descriptor(for: .ytDlp)
            tmp = try await Self.downloadVerified(descriptor, label: "yt-dlp")
        } else {
            // 迁移兼容：尚未部署 Xico 签名组件目录的构建，只允许 yt-dlp 官方二进制，
            // 且官方 SHA2-256SUMS 必须可用并匹配。ffmpeg/aria2 不提供这种降级。
            guard let url = URL(string: Self.ytDlpDownloadURL) else { throw DownloadError.badURL }
            let result = try await URLSession.shared.download(from: url)
            try Self.validateDownload(response: result.1, file: result.0, maxBytes: 200 * 1_024 * 1_024,
                                      label: "yt-dlp")
            let sums = try await fetchString(Self.ytDlpSumsURL)
            guard let expected = Self.checksum(named: "yt-dlp_macos", in: sums) else {
                throw DownloadError.engine("yt-dlp 官方校验清单无有效条目，已中止")
            }
            let data = try Data(contentsOf: result.0, options: .mappedIfSafe)
            guard expected.caseInsensitiveCompare(Self.sha256Hex(data)) == .orderedSame else {
                throw DownloadError.engine("yt-dlp 校验失败（SHA-256 不匹配），已中止")
            }
            tmp = result.0
        }
        guard await Self.isCompatibleMachO(tmp) else {
            throw DownloadError.engine("yt-dlp 不是适用于本机架构的 Mach-O，已中止")
        }
        onProgress(0.7)
        onProgress(0.9)
        // 落盘 + 可执行
        if FileManager.default.fileExists(atPath: dest.path) { try? FileManager.default.removeItem(at: dest) }
        try FileManager.default.moveItem(at: tmp, to: dest)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dest.path)
        Self.clearQuarantine(dest)
        onProgress(1.0)
    }

    /// 按需拉取静态 ffmpeg（zip → ditto 解压 → chmod）。best-effort：失败不阻断 yt-dlp。
    public func installFFmpeg() async throws {
        // 已内置（make_app.sh）或系统已有则跳过。
        if let p = Self.ffmpegPath(), p.hasPrefix(Bundle.main.bundleURL.path) || p.contains("/homebrew/") || p.contains("/usr/local/") {
            return
        }
        let descriptor = try await componentCatalog.descriptor(for: .ffmpeg)
        let tmp = try await Self.downloadVerified(descriptor, label: "媒体合并组件")
        let workspace = try Self.makePrivateWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let zipPath = workspace.appendingPathComponent("ffmpeg.zip")
        try FileManager.default.moveItem(at: tmp, to: zipPath)
        let listing = await Self.runTool("/usr/bin/unzip", ["-Z1", zipPath.path])
        guard listing.code == 0,
              ArchiveSafety.entriesAreSafe(listing.out.split(whereSeparator: \.isNewline).map(String.init)) else {
            throw DownloadError.engine("媒体合并组件压缩包结构不安全，已中止")
        }
        let extracted = workspace.appendingPathComponent("extracted", isDirectory: true)
        try FileManager.default.createDirectory(at: extracted, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let result = await Self.runTool("/usr/bin/ditto", ["-x", "-k", zipPath.path, extracted.path])
        guard result.code == 0,
              let source = try Self.singleSafeMachOBinary(named: "ffmpeg", under: extracted) else {
            throw DownloadError.engine("媒体合并组件解压失败")
        }
        guard await Self.isCompatibleMachO(source) else {
            throw DownloadError.engine("媒体合并组件架构不适用于本机")
        }
        try Self.installBinary(source, named: "ffmpeg")
    }

    /// 按需拉取静态 aria2c（tar.gz → tar 解压 → chmod）。best-effort。
    public func installAria2() async throws {
        if let p = Self.aria2Path(), p.contains("/homebrew/") || p.contains("/usr/local/") || p.hasPrefix(Bundle.main.bundleURL.path) {
            return
        }
        let descriptor = try await componentCatalog.descriptor(for: .aria2)
        let tmp = try await Self.downloadVerified(descriptor, label: "下载加速组件")
        let workspace = try Self.makePrivateWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let tarPath = workspace.appendingPathComponent("aria2c.tar.gz")
        try FileManager.default.moveItem(at: tmp, to: tarPath)
        let listing = await Self.runTool("/usr/bin/tar", ["-tzf", tarPath.path])
        guard listing.code == 0,
              ArchiveSafety.entriesAreSafe(listing.out.split(whereSeparator: \.isNewline).map(String.init)) else {
            throw DownloadError.engine("下载加速组件压缩包结构不安全，已中止")
        }
        let extracted = workspace.appendingPathComponent("extracted", isDirectory: true)
        try FileManager.default.createDirectory(at: extracted, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let result = await Self.runTool("/usr/bin/tar", ["-xzf", tarPath.path, "-C", extracted.path])
        guard result.code == 0,
              let source = try Self.singleSafeMachOBinary(named: "aria2c", under: extracted) else {
            throw DownloadError.engine("加速组件解压失败——可改用 brew install aria2")
        }
        guard await Self.isCompatibleMachO(source) else {
            throw DownloadError.engine("下载加速组件架构不适用于本机")
        }
        try Self.installBinary(source, named: "aria2c")
    }

    private static func downloadVerified(_ descriptor: DownloadComponentDescriptor,
                                         label: String) async throws -> URL {
        let (tmp, response) = try await URLSession.shared.download(from: descriptor.downloadURL)
        try validateDownload(response: response, file: tmp,
                             maxBytes: min(descriptor.size, 500 * 1_024 * 1_024), label: label)
        let size = ((try? FileManager.default.attributesOfItem(atPath: tmp.path)[.size]) as? NSNumber)?.int64Value ?? -1
        guard size == descriptor.size else {
            throw DownloadError.engine("\(label)大小与签名清单不一致，已中止")
        }
        let data = try Data(contentsOf: tmp, options: .mappedIfSafe)
        guard descriptor.sha256.caseInsensitiveCompare(sha256Hex(data)) == .orderedSame else {
            throw DownloadError.engine("\(label)的 SHA-256 与签名清单不一致，已中止")
        }
        return tmp
    }

    private func fetchString(_ urlString: String) async throws -> String {
        guard let url = URL(string: urlString) else { throw DownloadError.badURL }
        let (data, response) = try await URLSession.shared.data(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              http.url?.scheme?.lowercased() == "https", data.count <= 2 * 1_024 * 1_024,
              let string = String(data: data, encoding: .utf8), !string.isEmpty else {
            throw DownloadError.engine("官方校验清单读取失败")
        }
        return string
    }

    private static func validateDownload(response: URLResponse, file: URL, maxBytes: Int64,
                                         label: String) throws {
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              http.url?.scheme?.lowercased() == "https" else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw DownloadError.engine("\(label)下载失败（HTTP \(status)）")
        }
        let size = ((try? FileManager.default.attributesOfItem(atPath: file.path)[.size]) as? NSNumber)?.int64Value ?? -1
        guard size > 0, size <= maxBytes else {
            throw DownloadError.engine("\(label)文件大小异常，已中止")
        }
    }

    private static func checksum(named fileName: String, in manifest: String) -> String? {
        for line in manifest.split(whereSeparator: \.isNewline) {
            let fields = line.split(whereSeparator: \.isWhitespace)
            guard fields.count >= 2 else { continue }
            let hash = String(fields[0])
            let name = String(fields[fields.count - 1]).trimmingCharacters(in: CharacterSet(charactersIn: "*"))
            guard name == fileName, hash.count == 64,
                  hash.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "0123456789abcdefABCDEF").contains($0) }) else { continue }
            return hash
        }
        return nil
    }

    private static func makePrivateWorkspace() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("XicoEngine-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        return url
    }

    private static func runTool(_ executable: String, _ args: [String]) async -> (code: Int32, out: String) {
        await withCheckedContinuation { continuation in
            let process = Process()
            let pipe = Pipe()
            let output = EngineToolOutput(maxBytes: 16 * 1_024 * 1_024)
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = args
            process.standardOutput = pipe
            process.standardError = pipe
            // 持续排空管道，避免超大/恶意目录清单填满 pipe 后让子进程永远等待读取。
            // 超过上限仍继续排空但标记 overflow，最终 fail-closed。
            pipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if !data.isEmpty { output.append(data) }
            }
            process.terminationHandler = { p in
                pipe.fileHandleForReading.readabilityHandler = nil
                let tail = pipe.fileHandleForReading.readDataToEndOfFile()
                if !tail.isEmpty { output.append(tail) }
                let code: Int32 = output.overflowed ? -2 : p.terminationStatus
                continuation.resume(returning: (code, String(decoding: output.data, as: UTF8.self)))
            }
            do { try process.run() }
            catch { continuation.resume(returning: (-1, "")) }
        }
    }

    private static func singleSafeMachOBinary(named name: String, under root: URL) throws -> URL? {
        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey]
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys,
                                                               options: [.skipsHiddenFiles]) else { return nil }
        var matches: [URL] = []
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: Set(keys))
            guard values.isSymbolicLink != true else {
                throw DownloadError.engine("组件包包含符号链接，已中止")
            }
            if values.isRegularFile == true, url.lastPathComponent == name { matches.append(url) }
        }
        guard matches.count == 1, isMachO(matches[0]) else { return nil }
        return matches[0]
    }

    private static func isMachO(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 4), data.count == 4 else { return false }
        let magic = [UInt8](data)
        return [[0xfe,0xed,0xfa,0xce], [0xce,0xfa,0xed,0xfe], [0xfe,0xed,0xfa,0xcf],
                [0xcf,0xfa,0xed,0xfe], [0xca,0xfe,0xba,0xbe], [0xbe,0xba,0xfe,0xca],
                [0xca,0xfe,0xba,0xbf], [0xbf,0xba,0xfe,0xca]].contains(magic)
    }

    private static func isCompatibleMachO(_ url: URL) async -> Bool {
        guard isMachO(url) else { return false }
        #if arch(arm64)
        let arch = "arm64"
        #else
        let arch = "x86_64"
        #endif
        let result = await runTool("/usr/bin/lipo", ["-verify_arch", arch, url.path])
        return result.code == 0
    }

    private static func installBinary(_ source: URL, named name: String) throws {
        let fm = FileManager.default
        let dir = enginesDir()
        let staged = dir.appendingPathComponent(".\(name)-\(UUID().uuidString)")
        let target = dir.appendingPathComponent(name)
        try fm.copyItem(at: source, to: staged)
        do {
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: staged.path)
            // 只有通过 Xico Ed25519 清单 + SHA-256 + Mach-O/架构验证的组件才能走到这里。
            clearQuarantine(staged)
            if fm.fileExists(atPath: target.path) { try fm.removeItem(at: target) }
            try fm.moveItem(at: staged, to: target)
        } catch {
            try? fm.removeItem(at: staged)
            throw error
        }
    }

    /// 去除 com.apple.quarantine——否则硬化运行时的 App 无法执行「下载来的」二进制（Gatekeeper 拦截），
    /// 会表现为「装了却下载不动/无反应」。用 removexattr（无需再 spawn 进程）。
    static func clearQuarantine(_ url: URL) {
        url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return }
            _ = removexattr(path, "com.apple.quarantine", 0)
        }
    }

    static func sha256Hex(_ data: Data) -> String {
        var hash = [UInt8](repeating: 0, count: 32)
        data.withUnsafeBytes { _ = CC_SHA256($0.baseAddress, CC_LONG(data.count), &hash) }
        return hash.map { String(format: "%02x", $0) }.joined()
    }
}

/// 压缩包目录安全闸门：拒绝绝对路径、父级逃逸、控制字符与 Windows 路径分隔符。
/// 解压仍只发生在 0700 随机临时目录中，最终只复制唯一的 Mach-O 可执行文件。
public enum ArchiveSafety {
    nonisolated public static func entriesAreSafe(_ entries: [String]) -> Bool {
        !entries.isEmpty && entries.allSatisfy { entry in
            guard !entry.isEmpty, !entry.hasPrefix("/"), !entry.hasPrefix("~"),
                  !entry.contains("\\"),
                  entry.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else { return false }
            let components = entry.split(separator: "/", omittingEmptySubsequences: false)
            return !components.contains(where: { $0 == ".." })
        }
    }
}

private final class EngineToolOutput: @unchecked Sendable {
    private let lock = NSLock()
    private let maxBytes: Int
    private var storage = Data()
    private var overflow = false

    init(maxBytes: Int) { self.maxBytes = maxBytes }

    func append(_ data: Data) {
        lock.lock(); defer { lock.unlock() }
        let room = max(0, maxBytes - storage.count)
        if data.count > room { overflow = true }
        if room > 0 { storage.append(data.prefix(room)) }
    }

    var data: Data { lock.lock(); defer { lock.unlock() }; return storage }
    var overflowed: Bool { lock.lock(); defer { lock.unlock() }; return overflow }
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
    private var terminationRequested = false
    public init() {}
    func set(_ p: Process?) {
        lock.lock()
        if terminationRequested {
            lock.unlock()
            if let p, p.isRunning { Self.stop(p) }
            return
        }
        _process = p
        lock.unlock()
    }
    public func terminate() {
        lock.lock(); terminationRequested = true; let p = _process; _process = nil; lock.unlock()
        guard let p, p.isRunning else { return }
        Self.stop(p)
    }

    var isTerminationRequested: Bool { lock.lock(); defer { lock.unlock() }; return terminationRequested }

    fileprivate static func stop(_ process: Process) {
        let pid = process.processIdentifier
        process.terminate()
        // 下载组件可能忽略 SIGTERM。750ms 后仍存活即硬停止，确保暂停/取消及时兑现。
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.75) {
            if process.isRunning { _ = Darwin.kill(pid, SIGKILL) }
        }
    }
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

    /// 从浏览器读取 Cookies 的 yt-dlp 参数——对 X(Twitter)/需登录站点是能否解析下载的关键。
    static func cookieArgs(_ browser: String?) -> [String] {
        guard let b = browser, b != "none", !b.isEmpty else { return [] }
        return ["--cookies-from-browser", b]
    }

    /// 探测（yt-dlp -J）。返回媒体清单。handle 便于取消。cookiesBrowser 用于登录站点（如 X）。
    public static func probe(url: String, handle: ProcessHandle? = nil,
                             cookiesBrowser: String? = nil) async throws -> MediaManifest {
        let ytdlp = EngineInstaller.ytDlpURL()
        guard FileManager.default.isExecutableFile(atPath: ytdlp.path) else { throw DownloadError.engineNotReady }
        let cookies = cookieArgs(cookiesBrowser)
        var (code, out) = await runCollecting(executable: ytdlp, args: ["-J", "--no-warnings", "--socket-timeout", "20", "--flat-playlist"] + cookies + [url], handle: handle)
        if Task.isCancelled { throw CancellationError() }
        if code != 0 || out.isEmpty {
            // 退回非 flat（部分单视频 flat 会缺 formats）
            (code, out) = await runCollecting(executable: ytdlp, args: ["-J", "--no-warnings", "--socket-timeout", "20"] + cookies + [url], handle: handle)
        }
        guard let info = try? JSONDecoder().decode(RawInfo.self, from: out) else {
            let raw = String(data: out, encoding: .utf8) ?? ""
            let msg = String(raw.prefix(160))
            let lower = raw.lowercased()
            // 需登录/受限内容（X、私密视频、年龄限制）——提示用启用 Cookies 或用浏览器插件抓直链。
            let needsAuth = lower.contains("no video could be found") || lower.contains("nsfw")
                || lower.contains("log in") || lower.contains("login required") || lower.contains("private")
                || lower.contains("sign in") || lower.contains("age")
            var text = "解析失败：\(msg.isEmpty ? "无法读取媒体信息" : msg)"
            if needsAuth {
                text += "\n提示：该内容可能需要登录——请在「下载偏好」开启「从浏览器读取 Cookies」，或用 Xico 浏览器插件抓取直链。"
            }
            throw DownloadError.engine(text)
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
        // 断点续传：保留 .part（去掉 --no-part）+ --continue；失败自动重试，稳定性反超 Downie。
        var args: [String] = [job.sourceURL, "-o", outTemplate, "--newline", "--no-warnings",
                              "--continue", "--retries", "10", "--fragment-retries", "10",
                              "--progress-template", "download:@@P|%(progress._percent_str)s|%(progress._speed_str)s|%(progress._eta_str)s",
                              "--print", "after_move:@@FILE|%(filepath)s"]
        args += cookieArgs(prefs.cookiesBrowser)
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
        if Task.isCancelled || handle?.isTerminationRequested == true { return (-1, Data()) }
        let pump = DataPump(maxBytes: 32 * 1_024 * 1_024)
        let code: Int32 = await withCheckedContinuation { cont in
            let proc = Process()
            proc.executableURL = executable
            proc.arguments = args
            let outPipe = Pipe()
            proc.standardOutput = outPipe
            proc.standardError = outPipe   // stderr 也走同一被排空的管道，避免 stderr 写满缓冲区阻塞不退出
            outPipe.fileHandleForReading.readabilityHandler = { fh in
                if pump.feed(fh.availableData), proc.isRunning { ProcessHandle.stop(proc) }
            }
            proc.terminationHandler = { p in
                outPipe.fileHandleForReading.readabilityHandler = nil
                let trailing = outPipe.fileHandleForReading.readDataToEndOfFile()  // 排空尾部残留
                if !trailing.isEmpty { _ = pump.feed(trailing) }
                cont.resume(returning: p.terminationStatus)
            }
            do { try proc.run(); handle?.set(proc) }
            catch { cont.resume(returning: -1) }
        }
        return (code, pump.collected())
    }

    private static func runCollectingLines(executable: URL, args: [String], handle: ProcessHandle?,
                                           onLine: @escaping @Sendable (String) -> Void) async -> Int32 {
        if Task.isCancelled || handle?.isTerminationRequested == true { return -1 }
        let pump = LinePump(onLine: onLine)
        return await withCheckedContinuation { cont in
            let proc = Process()
            proc.executableURL = executable
            proc.arguments = args
            let outPipe = Pipe()
            proc.standardOutput = outPipe
            proc.standardError = outPipe
            outPipe.fileHandleForReading.readabilityHandler = { fh in
                if pump.feed(fh.availableData), proc.isRunning { ProcessHandle.stop(proc) }
            }
            proc.terminationHandler = { p in
                outPipe.fileHandleForReading.readabilityHandler = nil
                let trailing = outPipe.fileHandleForReading.readDataToEndOfFile()  // 排空尾部（含 --print 的 @@FILE 行）
                if !trailing.isEmpty { _ = pump.feed(trailing) }
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
    private let maxBytes: Int
    private var overflow = false
    init(maxBytes: Int) { self.maxBytes = maxBytes }
    @discardableResult func feed(_ d: Data) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !overflow else { return true }
        let room = max(0, maxBytes - data.count)
        if d.count > room { overflow = true }
        if room > 0 { data.append(d.prefix(room)) }
        return overflow
    }
    func collected() -> Data { lock.lock(); defer { lock.unlock() }; return data }
}

private final class LinePump: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()
    private var overflow = false
    private let maxBufferedBytes = 1_048_576
    private let onLine: @Sendable (String) -> Void
    init(onLine: @escaping @Sendable (String) -> Void) { self.onLine = onLine }
    @discardableResult func feed(_ d: Data) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !overflow else { return true }
        if buffer.count + d.count > maxBufferedBytes {
            overflow = true
            buffer.removeAll(keepingCapacity: false)
            return true
        }
        buffer.append(d)
        while let idx = buffer.firstIndex(where: { $0 == 0x0A || $0 == 0x0D }) {
            let lineData = buffer.subdata(in: buffer.startIndex..<idx)
            buffer.removeSubrange(buffer.startIndex...idx)
            if let line = String(data: lineData, encoding: .utf8), !line.isEmpty { onLine(line) }
        }
        return false
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
    if Task.isCancelled || handle?.isTerminationRequested == true { return -1 }
    let pump = LinePump(onLine: onLine)
    return await withCheckedContinuation { cont in
        let proc = Process()
        proc.executableURL = executable
        proc.arguments = args
        let outPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = outPipe
        outPipe.fileHandleForReading.readabilityHandler = { fh in
            if pump.feed(fh.availableData), proc.isRunning { ProcessHandle.stop(proc) }
        }
        proc.terminationHandler = { p in
            outPipe.fileHandleForReading.readabilityHandler = nil
            let trailing = outPipe.fileHandleForReading.readDataToEndOfFile()
            if !trailing.isEmpty { _ = pump.feed(trailing) }
            cont.resume(returning: p.terminationStatus)
        }
        do { try proc.run(); handle?.set(proc) }
        catch { cont.resume(returning: -1) }
    }
}
