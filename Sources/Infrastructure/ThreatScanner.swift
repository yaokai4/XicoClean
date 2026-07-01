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
    private let extraSignatures: [String]

    /// 内置特征（已知 macOS 广告软件 / 劫持 / PUP 的标识子串，小写匹配）
    static let signatures: [String] = [
        "genieo", "installmac", "vsearch", "conduit", "trovi", "spigot",
        "mackeeper", "advancedmaccleaner", "pcvark", "macpremiumbundle",
        "searchmine", "searchprotect", "mybrowser", "weknow", "chumsearch",
        "geneo", "omnibox", "bundlore", "shlayer", "adload", "pirrit",
        "mughthesec", "crossrider", "cleanupbuddy", "advancedmac"
    ]

    /// 内置 + 经签名通道下发的特征合集
    var allSignatures: [String] { (Self.signatures + extraSignatures).map { $0.lowercased() } }

    public init(fs: FileSystemService, safety: SafetyEngine,
                home: URL = FileManager.default.homeDirectoryForCurrentUser,
                extraSignatures: [String] = []) {
        self.fs = fs
        self.safety = safety
        self.home = home
        self.extraSignatures = extraSignatures
    }

    public func scan(progress: @escaping ProgressHandler) async throws -> ScanResult {
        let dirs = [
            home.appendingPathComponent("Library/LaunchAgents"),
            URL(fileURLWithPath: "/Library/LaunchAgents"),
            URL(fileURLWithPath: "/Library/LaunchDaemons")
        ]
        var items: [CleanableItem] = []

        let sigs = allSignatures
        var seen = Set<String>()
        for dir in dirs {
            for url in fs.contentsOfDirectory(dir) where url.pathExtension == "plist" {
                if Task.isCancelled { break }
                guard let dict = NSDictionary(contentsOf: url) else { continue }
                let haystack = buildHaystack(dict, fileName: url.lastPathComponent).lowercased()
                guard sigs.contains(where: { haystack.contains($0) }) else { continue }
                guard safety.verify(url, intent: .trash).isAllowed, seen.insert(url.path).inserted else { continue }
                // 1) plist 本身
                items.append(CleanableItem(url: url, displayName: url.lastPathComponent,
                                           detail: url.path, size: max(fs.allocatedSize(of: url), 1),
                                           safety: .risky, isSelected: false,
                                           note: "高风险启动项 · 请审阅"))
                progress(ScanProgress(message: url.lastPathComponent, bytesFound: 0))
                // 2) 载荷本体：Program / ProgramArguments[0] 指向的可执行文件也一并列入删除，
                //    只删 plist 会留下磁盘上的恶意二进制。
                for payload in payloadPaths(dict) {
                    let p = URL(fileURLWithPath: payload)
                    guard fs.exists(p), safety.verify(p, intent: .trash).isAllowed,
                          seen.insert(p.path).inserted else { continue }
                    items.append(CleanableItem(url: p, displayName: p.lastPathComponent,
                                               detail: p.path, size: max(fs.allocatedSize(of: p), 1),
                                               safety: .risky, isSelected: false,
                                               note: "关联恶意载荷"))
                }
            }
        }

        let group = ScanResultGroup(
            id: "threats", title: "可疑启动项与载荷",
            description: "命中已知广告软件 / PUP 特征，含其磁盘载荷。移除将移入废纸篓（可恢复）；"
                       + "已在运行的进程会在你注销或重启后停止。",
            systemImage: "exclamationmark.shield", safety: .risky, items: items)
        return ScanResult(moduleID: .malware, groups: items.isEmpty ? [] : [group])
    }

    /// 从 launchd plist 提取磁盘载荷路径（Program 或 ProgramArguments 首元素）。
    private func payloadPaths(_ dict: NSDictionary) -> [String] {
        var paths: [String] = []
        if let program = dict["Program"] as? String, program.hasPrefix("/") { paths.append(program) }
        if let args = dict["ProgramArguments"] as? [String], let first = args.first, first.hasPrefix("/") {
            paths.append(first)
        }
        return paths
    }

    private func buildHaystack(_ dict: NSDictionary, fileName: String) -> String {
        var parts: [String] = [fileName]
        if let label = dict["Label"] as? String { parts.append(label) }
        if let program = dict["Program"] as? String { parts.append(program) }
        if let args = dict["ProgramArguments"] as? [String] { parts.append(contentsOf: args) }
        return parts.joined(separator: " ")
    }
}
