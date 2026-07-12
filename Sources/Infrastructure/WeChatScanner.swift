import Foundation
import DesignSystem
import Domain

// MARK: - 微信专清（docs/15 P0-e · 中国区最大差异化）
//
// CleanMyMac 没做、腾讯柠檬做了 6 粒度——Xico 对齐柠檬粒度并叠加自己的安全纪律：
//   · 头像/临时/小程序缓存 = safe（删除自动重建）；
//   · 聊天图片/视频/文件/语音 = caution **默认不勾**，且只列出「N 天前」的旧媒体
//     （默认 90 天，`xico.wechat.daysThreshold` 可调）——聊天媒体是用户数据，
//     「删哪些」必须交回用户（对齐柠檬 recommend=NO 的正确范式）；
//   · 聊天记录数据库（*.db）= risky **仅提示永不代删**（删了聊天记录直接丢失）。
//
// 路径**动态枚举**（硬编码具体版本目录会随微信更新失效——这是柠檬的痛点也是机会）：
//   · 4.0+：~/Library/Containers/com.tencent.xinWeChat/Data/Documents/xwechat_files/wxid_*/
//     （同时探测非沙盒 ~/Documents/xwechat_files/）
//   · 3.x：~/Library/Containers/com.tencent.xinWeChat/Data/Library/Application Support/
//     com.tencent.xinWeChat/<版本>/<账号哈希>/（Message/MessageTemp 树）
// 账号根之下按**目录名关键词**归类（video/file/image/voice/applet/avatar/temp/cache），
// 不依赖任何具体层级结构——版本变更时仍能自愈发现。
public struct WeChatScanner: ScannerModule, Sendable {
    public let metadata = ModuleMetadata(
        id: ModuleID("wechat"), title: "微信专清", subtitle: "缓存 / 旧聊天媒体（默认不勾）",
        systemImage: "message.badge.filled.fill", category: .cleanup)

    private let fs: FileSystemService
    private let safety: SafetyEngine
    private let home: URL

    /// 「仅清 N 天前」阈值（聊天媒体只列出早于该天数的旧项）。默认 90 天。
    public static var daysThreshold: Int {
        let v = UserDefaults.standard.integer(forKey: "xico.wechat.daysThreshold")
        return v > 0 ? v : 90
    }

    public init(fs: FileSystemService, safety: SafetyEngine,
                home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.fs = fs
        self.safety = safety
        self.home = home
    }

    /// 媒体/缓存类别：目录名关键词 → 类别（小写包含匹配，跨版本自愈）。
    private enum Category: String, CaseIterable {
        case tempCache, applet, avatar, images, videos, files, voice

        static func classify(_ dirName: String) -> Category? {
            let n = dirName.lowercased()
            // 顺序即优先级：明确的媒体类先判，泛化的 temp/cache 兜底。
            if n.contains("video") { return .videos }
            if n.contains("voice") || n.contains("audio") { return .voice }
            if n.contains("applet") || n.contains("wxapp") { return .applet }
            if n.contains("avatar") || n.contains("headimg") || n.contains("head_img") { return .avatar }
            if n.contains("image") || n.contains("attach") || n == "img" { return .images }
            if n == "file" || n == "files" || n.contains("opendata") { return .files }
            if n.contains("temp") || n.contains("cache") { return .tempCache }
            return nil
        }

        var groupID: String { "wechat-\(rawValue)" }
        var title: String {
            switch self {
            case .tempCache: return "微信 · 临时缓存"
            case .applet:    return "微信 · 小程序缓存"
            case .avatar:    return "微信 · 头像缓存"
            case .images:    return "微信 · 聊天图片（旧）"
            case .videos:    return "微信 · 聊天视频（旧）"
            case .files:     return "微信 · 聊天文件（旧）"
            case .voice:     return "微信 · 聊天语音（旧）"
            }
        }
        var icon: String {
            switch self {
            case .tempCache: return "message.badge.filled.fill"
            case .applet:    return "app.badge"
            case .avatar:    return "person.crop.circle"
            case .images:    return "photo"
            case .videos:    return "video"
            case .files:     return "doc"
            case .voice:     return "waveform"
            }
        }
        /// safe = 删除自动重建；媒体 = caution 默认不勾（用户数据）。
        var safety: SafetyLevel {
            switch self {
            case .tempCache, .applet, .avatar: return .safe
            default: return .caution
            }
        }
        var isChatMedia: Bool { self.safety == .caution }
        var explanation: String {
            switch self {
            case .tempCache:
                return "微信运行产生的临时与缓存数据，删除后自动重建，不影响聊天记录与登录状态。"
            case .applet:
                return "小程序的本地缓存包，删除后再次打开对应小程序时自动重新下载。"
            case .avatar:
                return "联系人头像的本地缓存，删除后查看会话时自动重新拉取。"
            case .images, .videos, .files, .voice:
                return "聊天中收发的媒体文件本体。删除后聊天记录里的对应内容将无法再打开（对方或云端可能仍有副本）——因此默认不勾选、且只列出超过阈值天数的旧项，请逐项确认。"
            }
        }
    }

    public func scan(progress: @escaping ProgressHandler) async throws -> ScanResult {
        var itemsByCategory: [Category: [CleanableItem]] = [:]
        var dbItems: [CleanableItem] = []
        var total: Int64 = 0
        let cutoff = Date().addingTimeInterval(-Double(Self.daysThreshold) * 86_400)

        for accountRoot in accountRoots() {
            if Task.isCancelled { break }
            await walk(accountRoot, depth: 0, cutoff: cutoff,
                       into: &itemsByCategory, dbItems: &dbItems, total: &total, progress: progress)
        }

        var groups: [ScanResultGroup] = []
        for category in Category.allCases {
            guard var items = itemsByCategory[category], !items.isEmpty else { continue }
            items.sort { $0.size > $1.size }
            let desc = category.isChatMedia
                ? xLocF("仅列出 %d 天前的旧项 · 默认不勾选，请逐项确认", Self.daysThreshold)
                : "删除安全，自动重建。"
            groups.append(ScanResultGroup(id: category.groupID, title: category.title,
                                          description: desc, systemImage: category.icon,
                                          safety: category.safety,
                                          explanation: category.explanation, items: items))
        }
        if !dbItems.isEmpty {
            groups.append(ScanResultGroup(
                id: "wechat-db", title: "微信 · 聊天记录数据库（仅提示）",
                description: "聊天记录本体。Xico 永不代删——删除等于清空聊天记录。",
                systemImage: "externaldrive.badge.exclamationmark", safety: .risky,
                explanation: "微信把聊天记录存在这些数据库文件里。它们体积可能很大，但删除会直接丢失聊天记录且无法恢复，因此 Xico 只展示体积、绝不代删；如需瘦身请用微信内置的「存储空间管理」。",
                items: dbItems))
        }
        groups.sort { $0.totalSize > $1.totalSize }
        return ScanResult(moduleID: ModuleID("wechat"), groups: groups)
    }

    /// 账号根动态枚举（4.0 xwechat_files/wxid_* + 3.x 版本目录/账号哈希 + 非沙盒变体）。
    private func accountRoots() -> [URL] {
        var roots: [URL] = []
        let container = home.appendingPathComponent("Library/Containers/com.tencent.xinWeChat/Data")
        // 4.0+：xwechat_files/wxid_*（container 与非沙盒两处都探测）
        for base in [container.appendingPathComponent("Documents/xwechat_files"),
                     home.appendingPathComponent("Documents/xwechat_files")] {
            guard fs.exists(base) else { continue }
            for child in fs.contentsOfDirectory(base)
            where child.lastPathComponent.lowercased().hasPrefix("wxid_")
                || child.lastPathComponent.lowercased() == "all_users" {
                roots.append(child)
            }
        }
        // 3.x：Application Support/com.tencent.xinWeChat/<版本>/<账号哈希 32 位十六进制>
        let legacy = container.appendingPathComponent("Library/Application Support/com.tencent.xinWeChat")
        if fs.exists(legacy) {
            for versionDir in fs.contentsOfDirectory(legacy) {
                for account in fs.contentsOfDirectory(versionDir) {
                    let name = account.lastPathComponent
                    if name.count == 32, name.allSatisfy({ $0.isHexDigit }) {
                        roots.append(account)
                    }
                }
            }
        }
        return roots
    }

    /// 账号根下浅递归（≤3 层）找类别目录：命中类别 → 其直接子项作为可清理项。
    private func walk(_ dir: URL, depth: Int, cutoff: Date,
                      into itemsByCategory: inout [Category: [CleanableItem]],
                      dbItems: inout [CleanableItem], total: inout Int64,
                      progress: @escaping ProgressHandler) async {
        guard depth <= 3 else { return }
        for child in fs.contentsOfDirectory(dir) {
            if Task.isCancelled { return }
            await Task.yield()
            let name = child.lastPathComponent
            // 聊天记录数据库：仅提示，永不入可删组。
            if name.lowercased().hasSuffix(".db"), let e = fs.entry(for: child), !e.isDirectory {
                if e.size > 10 << 20 {   // 只列 ≥10MB 的大库
                    dbItems.append(CleanableItem(url: child, displayName: name, detail: child.path,
                                                 size: e.size, safety: .risky,
                                                 note: "聊天记录本体 · 请用微信内置的存储空间管理瘦身",
                                                 isInformational: true))
                }
                continue
            }
            guard (try? child.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { continue }
            if let category = Category.classify(name) {
                collectItems(in: child, category: category, cutoff: cutoff,
                             into: &itemsByCategory, total: &total, progress: progress)
            } else {
                await walk(child, depth: depth + 1, cutoff: cutoff,
                           into: &itemsByCategory, dbItems: &dbItems, total: &total, progress: progress)
            }
        }
    }

    /// 类别目录的直接子项 → 可清理项。聊天媒体只收「早于 cutoff」的旧项（时间轴分档）；
    /// 每一项都过删除红线（SafetyEngine.verify），媒体默认不勾。
    private func collectItems(in dir: URL, category: Category, cutoff: Date,
                              into itemsByCategory: inout [Category: [CleanableItem]],
                              total: inout Int64, progress: @escaping ProgressHandler) {
        for item in fs.contentsOfDirectory(dir) {
            if Task.isCancelled { return }
            guard safety.verify(item, intent: .trash).isAllowed else { continue }
            let entry = fs.entry(for: item)
            if category.isChatMedia {
                let modified = entry?.modificationDate ?? .distantPast
                guard modified < cutoff else { continue }   // 近期媒体完全不列——时间轴保护
            }
            let size = fs.allocatedSize(of: item)
            guard size > 64 * 1024 else { continue }   // 碎渣不值得列
            itemsByCategory[category, default: []].append(CleanableItem(
                url: item, displayName: item.lastPathComponent, detail: item.path,
                size: size, safety: category.safety,
                isSelected: category.isChatMedia ? false : nil,
                note: category.isChatMedia ? xLocF("早于 %d 天", Self.daysThreshold) : nil))
            total += size
            progress(ScanProgress(message: item.lastPathComponent, bytesFound: total))
        }
    }
}
