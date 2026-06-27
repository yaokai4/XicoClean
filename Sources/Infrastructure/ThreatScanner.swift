import Foundation
import Domain

/// 威胁防护：基于内置特征库，扫描启动项中已知的广告软件 / 潜在有害程序（PUP）。
/// 命中即标记为高风险，供用户审阅后移除（移入废纸篓，可恢复）。
public struct ThreatScanner: ScannerModule {
    public let metadata = ModuleMetadata(
        id: .malware, title: "威胁防护", subtitle: "扫描已知广告软件与可疑启动项",
        systemImage: "shield.lefthalf.filled", category: .performance)

    private let fs: FileSystemService
    private let safety: SafetyEngine
    private let home: URL

    /// 内置特征（已知 macOS 广告软件 / 劫持 / PUP 的标识子串，小写匹配）
    static let signatures: [String] = [
        "genieo", "installmac", "vsearch", "conduit", "trovi", "spigot",
        "mackeeper", "advancedmaccleaner", "pcvark", "macpremiumbundle",
        "searchmine", "searchprotect", "mybrowser", "weknow", "chumsearch",
        "geneo", "omnibox", "bundlore", "shlayer", "adload", "pirrit",
        "mughthesec", "crossrider", "cleanupbuddy", "advancedmac"
    ]

    public init(fs: FileSystemService, safety: SafetyEngine,
                home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.fs = fs
        self.safety = safety
        self.home = home
    }

    public func scan(progress: @escaping ProgressHandler) async throws -> ScanResult {
        let dirs = [
            home.appendingPathComponent("Library/LaunchAgents"),
            URL(fileURLWithPath: "/Library/LaunchAgents"),
            URL(fileURLWithPath: "/Library/LaunchDaemons")
        ]
        var items: [CleanableItem] = []

        for dir in dirs {
            for url in fs.contentsOfDirectory(dir) where url.pathExtension == "plist" {
                if Task.isCancelled { break }
                guard let dict = NSDictionary(contentsOf: url) else { continue }
                let haystack = buildHaystack(dict, fileName: url.lastPathComponent).lowercased()
                guard Self.signatures.contains(where: { haystack.contains($0) }) else { continue }
                guard safety.verify(url, intent: .trash).isAllowed else { continue }
                let size = fs.allocatedSize(of: url)
                items.append(CleanableItem(url: url, displayName: url.lastPathComponent,
                                           detail: url.path, size: max(size, 1),
                                           safety: .risky, isSelected: true))
                progress(ScanProgress(message: url.lastPathComponent, bytesFound: 0))
            }
        }

        let group = ScanResultGroup(
            id: "threats", title: "可疑启动项",
            description: "命中已知广告软件 / PUP 特征。移除将停用并移入废纸篓，可恢复。",
            systemImage: "exclamationmark.shield", safety: .risky, items: items)
        return ScanResult(moduleID: .malware, groups: items.isEmpty ? [] : [group])
    }

    private func buildHaystack(_ dict: NSDictionary, fileName: String) -> String {
        var parts: [String] = [fileName]
        if let label = dict["Label"] as? String { parts.append(label) }
        if let program = dict["Program"] as? String { parts.append(program) }
        if let args = dict["ProgramArguments"] as? [String] { parts.append(contentsOf: args) }
        return parts.joined(separator: " ")
    }
}
