import SwiftUI
import AppKit
import QuickLookThumbnailing

/// 缩略图缓存（按 URL）。避免重复生成，滚动列表流畅。
public final class ThumbnailCache: @unchecked Sendable {
    public static let shared = ThumbnailCache()
    private let cache = NSCache<NSURL, NSImage>()
    private init() { cache.countLimit = 800 }
    func object(_ url: URL) -> NSImage? { cache.object(forKey: url as NSURL) }
    func set(_ img: NSImage, _ url: URL) { cache.setObject(img, forKey: url as NSURL) }
}

/// 文件缩略图：对图片/视频/PDF 等用系统 QuickLook 生成真实预览（对标 CleanMyMac/Gemini
/// 的可视化画廊），其余回退到文件类型图标。异步加载 + 缓存，绝不阻塞主线程。
public struct XThumbnail: View {
    let url: URL
    let side: CGFloat
    let corner: CGFloat
    @State private var image: NSImage?
    public init(url: URL, side: CGFloat = 40, corner: CGFloat = XRadius.chip) {
        self.url = url
        self.side = side
        self.corner = corner
    }
    public var body: some View {
        RoundedRectangle(cornerRadius: corner, style: .continuous)
            .fill(XColor.surfaceAlt)
            .overlay {
                if let image {
                    Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                } else {
                    Image(systemName: Self.icon(for: url))
                        .font(.system(size: side * 0.42, weight: .regular))
                        .foregroundStyle(XColor.textTertiary)
                }
            }
            .frame(width: side, height: side)
            .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: corner, style: .continuous)
                .strokeBorder(XColor.hairline, lineWidth: 1))
            .task(id: url) { await load() }
    }

    private func load() async {
        if let c = ThumbnailCache.shared.object(url) { image = c; return }
        guard Self.isPreviewable(url) else { return }
        if let img = await Self.generate(url: url, side: side) {
            ThumbnailCache.shared.set(img, url)
            image = img
        }
    }

    // NSImage 始终在主 actor 上生成/持有——不跨 actor 传递非 Sendable 类型。
    @MainActor private static func generate(url: URL, side: CGFloat) async -> NSImage? {
        let px = max(64, side * 2)
        let req = QLThumbnailGenerator.Request(
            fileAt: url, size: CGSize(width: px, height: px),
            scale: NSScreen.main?.backingScaleFactor ?? 2,
            representationTypes: .thumbnail)
        guard let rep = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: req) else { return nil }
        return rep.nsImage
    }

    public static func isPreviewable(_ url: URL) -> Bool {
        guard !url.hasDirectoryPath else { return false }
        return previewExts.contains(url.pathExtension.lowercased())
    }
    private static let previewExts: Set<String> = [
        "jpg","jpeg","png","gif","heic","heif","webp","bmp","tiff","tif","raw","cr2","nef","arw","dng",
        "mp4","mov","m4v","avi","mkv","webm","pdf","psd","ai","sketch","key","svg","icns"
    ]
    static func icon(for url: URL) -> String {
        if url.hasDirectoryPath { return "folder.fill" }
        let ext = url.pathExtension.lowercased()
        if ["zip","gz","tar","dmg","pkg","7z","rar"].contains(ext) { return "archivebox.fill" }
        if ["mp3","wav","aac","flac","m4a"].contains(ext) { return "music.note" }
        if ["mp4","mov","m4v","avi","mkv","webm"].contains(ext) { return "film.fill" }
        if ["app"].contains(ext) { return "app.fill" }
        return "doc.fill"
    }
}
