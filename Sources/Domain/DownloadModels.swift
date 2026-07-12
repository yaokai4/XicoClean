import Foundation

// MARK: - 下载器（对标 Downie 4）领域模型
//
// 法务姿态（见记忆 downie-downloader-legal-risk）：中立、用户自填 URL 的通用下载器。
// 引擎（yt-dlp + ffmpeg）**不打包**进签名包，运行时按需下载到 App Support（Downie 的成熟做法，
// 规避 §1201 与 App Store 5.2.3）。整个下载能力用编译开关排除出沙盒 MAS 版。

public enum DownloadKind: String, Codable, Sendable, CaseIterable {
    case video, audio, image
    public var title: String {
        switch self {
        case .video: return "视频"
        case .audio: return "音频"
        case .image: return "图片"
        }
    }
    public var symbol: String {
        switch self {
        case .video: return "film"
        case .audio: return "music.note"
        case .image: return "photo"
        }
    }
}

/// 一个可选格式/清晰度（来自 yt-dlp -J 探测）。
public struct MediaFormat: Sendable, Identifiable, Equatable, Codable {
    public var formatID: String
    public var ext: String
    public var height: Int?          // 视频高度（1080/720…）
    public var fps: Double?
    public var vcodec: String?
    public var acodec: String?
    public var filesizeApprox: Int64?
    public var note: String?
    public var id: String { formatID }

    public var isAudioOnly: Bool { (vcodec == nil || vcodec == "none") && (acodec != nil && acodec != "none") }
    public var isVideoOnly: Bool { (acodec == nil || acodec == "none") && (vcodec != nil && vcodec != "none") }

    public var qualityLabel: String {
        if isAudioOnly { return note ?? "\(ext) 音频" }
        if let h = height { return "\(h)p" + (fps.map { $0 >= 50 ? " \(Int($0))" : "" } ?? "") }
        return note ?? ext
    }

    public init(formatID: String, ext: String, height: Int? = nil, fps: Double? = nil,
                vcodec: String? = nil, acodec: String? = nil, filesizeApprox: Int64? = nil, note: String? = nil) {
        self.formatID = formatID; self.ext = ext; self.height = height; self.fps = fps
        self.vcodec = vcodec; self.acodec = acodec; self.filesizeApprox = filesizeApprox; self.note = note
    }
}

/// 探测结果：一个页面/链接解析出的媒体清单。
public struct MediaManifest: Sendable, Equatable {
    public var title: String
    public var uploader: String?
    public var durationSeconds: Double?
    public var thumbnailURL: String?
    public var webpageURL: String
    public var extractor: String?
    public var isPlaylist: Bool
    public var playlistCount: Int
    public var formats: [MediaFormat]

    public init(title: String, uploader: String? = nil, durationSeconds: Double? = nil,
                thumbnailURL: String? = nil, webpageURL: String, extractor: String? = nil,
                isPlaylist: Bool = false, playlistCount: Int = 1, formats: [MediaFormat] = []) {
        self.title = title; self.uploader = uploader; self.durationSeconds = durationSeconds
        self.thumbnailURL = thumbnailURL; self.webpageURL = webpageURL; self.extractor = extractor
        self.isPlaylist = isPlaylist; self.playlistCount = playlistCount; self.formats = formats
    }

    /// 供清晰度菜单：视频格式（去音频-only），按高度降序。
    public var videoFormats: [MediaFormat] {
        formats.filter { !$0.isAudioOnly }.sorted { ($0.height ?? 0) > ($1.height ?? 0) }
    }
    public var audioFormats: [MediaFormat] {
        formats.filter { $0.isAudioOnly }.sorted { ($0.filesizeApprox ?? 0) > ($1.filesizeApprox ?? 0) }
    }
}

public enum DownloadState: Sendable, Equatable {
    case queued
    case probing
    case ready                       // 已探测，待选格式/开始
    case downloading(progress: Double, speed: String, eta: String)
    case postprocessing
    case completed(path: String)
    case failed(reason: String)
    case paused
    case canceled

    public var isActive: Bool {
        switch self { case .probing, .downloading, .postprocessing: return true; default: return false }
    }
    public var isTerminal: Bool {
        switch self { case .completed, .failed, .canceled: return true; default: return false }
    }
    public var progressValue: Double {
        switch self {
        case .downloading(let p, _, _): return p
        case .completed: return 1
        case .postprocessing: return 0.99
        default: return 0
        }
    }
    public var label: String {
        switch self {
        case .queued: return "排队中"
        case .probing: return "解析中…"
        case .ready: return "待开始"
        case .downloading(_, let speed, let eta): return eta.isEmpty ? speed : "\(speed) · 剩 \(eta)"
        case .postprocessing: return "后处理中…"
        case .completed: return "已完成"
        case .failed(let r): return r
        case .paused: return "已暂停"
        case .canceled: return "已取消"
        }
    }
}

/// 一个下载任务。
public struct DownloadJob: Sendable, Identifiable, Equatable {
    public var id: UUID
    public var sourceURL: String
    public var title: String
    public var kind: DownloadKind
    public var state: DownloadState
    public var manifest: MediaManifest?
    public var chosenFormatID: String?
    public var thumbnailURL: String?
    public var destinationDir: String
    public var outputPath: String?

    public init(id: UUID = UUID(), sourceURL: String, title: String = "", kind: DownloadKind = .video,
                state: DownloadState = .queued, manifest: MediaManifest? = nil,
                chosenFormatID: String? = nil, thumbnailURL: String? = nil,
                destinationDir: String, outputPath: String? = nil) {
        self.id = id; self.sourceURL = sourceURL
        self.title = title.isEmpty ? sourceURL : title
        self.kind = kind; self.state = state; self.manifest = manifest
        self.chosenFormatID = chosenFormatID; self.thumbnailURL = thumbnailURL
        self.destinationDir = destinationDir; self.outputPath = outputPath
    }
}

/// 下载偏好（对标 Downie 的 Preferences：画质 / 音频格式 / 字幕 / 元数据 / 缩略图 / 目标 / 剪贴板监听）。
public struct DownloadPreferences: Codable, Sendable, Equatable {
    public enum VideoQuality: String, Codable, Sendable, CaseIterable, Identifiable {
        case best, p2160, p1440, p1080, p720, p480
        public var id: String { rawValue }
        public var height: Int? {
            switch self {
            case .best: return nil
            case .p2160: return 2160
            case .p1440: return 1440
            case .p1080: return 1080
            case .p720: return 720
            case .p480: return 480
            }
        }
        public var title: String { self == .best ? "最佳" : rawValue.dropFirst().description + "p" }
    }
    public var videoQuality: VideoQuality
    public var audioFormat: String        // mp3 / m4a / opus / best
    public var embedSubtitles: Bool
    public var subtitleLangs: String       // "en.*,zh.*"
    public var embedMetadata: Bool
    public var embedThumbnail: Bool
    public var clipboardMonitor: Bool

    public init(videoQuality: VideoQuality = .best, audioFormat: String = "mp3",
                embedSubtitles: Bool = false, subtitleLangs: String = "en.*,zh.*",
                embedMetadata: Bool = true, embedThumbnail: Bool = true, clipboardMonitor: Bool = false) {
        self.videoQuality = videoQuality; self.audioFormat = audioFormat
        self.embedSubtitles = embedSubtitles; self.subtitleLangs = subtitleLangs
        self.embedMetadata = embedMetadata; self.embedThumbnail = embedThumbnail
        self.clipboardMonitor = clipboardMonitor
    }
}

/// 组件（ffmpeg / aria2）按需安装的可视状态——修复「点补齐组件无反应」。
public enum ComponentInstall: Equatable, Sendable {
    case idle
    case installing(String)   // 组件名
    case failed(String)       // 错误
    public var isInstalling: Bool { if case .installing = self { return true }; return false }
}

/// 引擎（yt-dlp/ffmpeg）就绪状态。
public enum DownloadEngineStatus: Sendable, Equatable {
    case notInstalled           // 未安装 yt-dlp
    case installing(Double)     // 下载中（进度）
    case ready(ffmpeg: Bool)    // 就绪；ffmpeg 是否可用（决定高画质合并/音频提取）
    case failed(String)

    public var isReady: Bool { if case .ready = self { return true }; return false }
}
