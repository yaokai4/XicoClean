import Foundation
import Security
import Domain

/// 威胁防护：四层真实检测（不做「安全剧场」，每条命中都给出可核实的理由）。
/// 1. 特征库：启动项命中已知广告软件 / PUP 标识（内置 + 签名通道下发）；
/// 2. 代码签名：登录自启动的载荷未签名 / ad-hoc / 签名破损——正规软件极少如此；
/// 3. 系统伪装：用户目录里的 com.apple.* 启动项——Apple 从不把自家 LaunchAgent 装进用户目录；
/// 4. 危险路径：载荷位于 /tmp、Downloads、/Users/Shared 等一次性目录——经典恶意驻留手法。
/// 命中标记为高风险、默认不勾选，供用户审阅后移除（移入废纸篓，可恢复）。
public struct ThreatScanner: ScannerModule {
    public let metadata = ModuleMetadata(
        id: .malware, title: "威胁防护", subtitle: "特征库 · 签名校验 · 伪装与危险路径",
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
            home.appendingPathComponent("Library/LaunchDaemons"),   // 用户目录本不该有 Daemons——有即可疑
            URL(fileURLWithPath: "/Library/LaunchAgents"),
            URL(fileURLWithPath: "/Library/LaunchDaemons")
        ]
        var signatureHits: [CleanableItem] = []
        var heuristicHits: [CleanableItem] = []

        let sigs = allSignatures
        var seen = Set<String>()

        /// 把 plist + 其载荷加入结果组（去重、安全红线校验统一走这里）。
        func appendFinding(_ url: URL, _ dict: NSDictionary, note: String, to bucket: inout [CleanableItem]) {
            guard safety.verify(url, intent: .trash).isAllowed, seen.insert(url.path).inserted else { return }
            bucket.append(CleanableItem(url: url, displayName: url.lastPathComponent,
                                        detail: url.path, size: max(fs.allocatedSize(of: url), 1),
                                        safety: .risky, isSelected: false, note: note))
            progress(ScanProgress(message: url.lastPathComponent, bytesFound: 0))
            // 载荷本体：只删 plist 会留下磁盘上的可执行文件。
            // 但 plist 的 ProgramArguments 是攻击者可控字段——可指向任意用户文件
            // （如 ~/Documents/tax.pdf）。只把「经核验」的载荷列为可删除：命中特征库，
            // 或位于启动项可执行文件的常规位置；否则不列入删除候选（fail closed），
            // 绝不把 vetted 集合之外的路径当作可删除项呈现。移除 plist 已足以断掉自启动。
            for payload in payloadPaths(dict) where isVettedPayload(payload) {
                let p = URL(fileURLWithPath: payload)
                guard fs.exists(p), safety.verify(p, intent: .trash).isAllowed,
                      seen.insert(p.path).inserted else { continue }
                bucket.append(CleanableItem(url: p, displayName: p.lastPathComponent,
                                            detail: p.path, size: max(fs.allocatedSize(of: p), 1),
                                            safety: .risky, isSelected: false,
                                            note: "关联载荷"))
            }
        }

        for dir in dirs {
            let isUserDir = dir.path.hasPrefix(home.path)
            for url in fs.contentsOfDirectory(dir) where url.pathExtension == "plist" {
                if Task.isCancelled { break }
                guard let dict = NSDictionary(contentsOf: url) else { continue }
                let haystack = buildHaystack(dict, fileName: url.lastPathComponent).lowercased()

                // —— 第 1 层：已知特征库 ——
                if sigs.contains(where: { haystack.contains($0) }) {
                    appendFinding(url, dict, note: "命中已知广告软件特征 · 请审阅", to: &signatureHits)
                    continue
                }

                // —— 第 3 层：系统伪装（Apple 从不把自家启动项装进用户目录）——
                let name = url.lastPathComponent.lowercased()
                let label = (dict["Label"] as? String ?? "").lowercased()
                if isUserDir, name.hasPrefix("com.apple.") || label.hasPrefix("com.apple.") {
                    appendFinding(url, dict, note: "伪装成系统组件的启动项 · 高度可疑", to: &heuristicHits)
                    continue
                }

                // —— 第 4 层：危险路径载荷 ——
                let payloads = payloadPaths(dict)
                if payloads.contains(where: { isDangerousPath($0) }) {
                    // 固定文案（不插值）——note 是 xLoc 查表键，动态拼接会漏翻
                    appendFinding(url, dict, note: "载荷位于一次性目录 · 典型恶意驻留", to: &heuristicHits)
                    continue
                }

                // —— 第 2 层：代码签名校验（只查非系统解释器的真实二进制）——
                if let payload = payloads.first, !isSystemBinary(payload), fs.exists(URL(fileURLWithPath: payload)) {
                    switch codeSignState(URL(fileURLWithPath: payload)) {
                    case .unsigned:
                        appendFinding(url, dict, note: "登录自启动的载荷未签名 · 请确认来源", to: &heuristicHits)
                    case .invalid:
                        appendFinding(url, dict, note: "载荷签名已破损（内容被篡改过）· 请审阅", to: &heuristicHits)
                    case .adhoc:
                        appendFinding(url, dict, note: "载荷为临时签名（无开发者身份）· 请确认来源", to: &heuristicHits)
                    case .valid:
                        break
                    }
                }
            }
        }

        var groups: [ScanResultGroup] = []
        if !signatureHits.isEmpty {
            groups.append(ScanResultGroup(
                id: "threats", title: "已知威胁",
                // 单条字面量（不拼接）——description 会整串走 xLoc 查表，拼接会漏翻成中文
                description: "命中已知广告软件 / PUP 特征，含其磁盘载荷。移除将移入废纸篓（可恢复）；已在运行的进程会在你注销或重启后停止。",
                systemImage: "exclamationmark.shield", safety: .risky, items: signatureHits))
        }
        if !heuristicHits.isEmpty {
            groups.append(ScanResultGroup(
                id: "suspicious", title: "可疑启动项",
                // 单条字面量（不拼接）——同上，整串走 xLoc 查表
                description: "未命中特征库，但存在真实可疑迹象：伪装系统名 / 载荷未签名或签名破损 / 驻留危险路径。逐条给出理由，请核对来源后再决定移除。",
                systemImage: "questionmark.diamond", safety: .risky, items: heuristicHits))
        }
        return ScanResult(moduleID: .malware, groups: groups)
    }

    // MARK: 检测助手

    /// 载荷是否位于「正规软件绝不会驻留」的一次性目录。
    /// 仅匹配真正的一次性根：/tmp、/private/var/tmp、/Users/Shared，以及**本用户家目录**的 Downloads。
    /// 刻意不再用宽泛子串 `/library/caches/`（正规助手载荷常驻此处，会误报）与裸 `/downloads/`
    /// （任意路径含该分量即命中，误伤面大）——收窄为前缀/家目录锚定匹配。
    private func isDangerousPath(_ path: String) -> Bool {
        let p = path.lowercased()
        let downloads = home.appendingPathComponent("Downloads").path.lowercased() + "/"
        return p.hasPrefix("/tmp/") || p.hasPrefix("/private/tmp/") || p.hasPrefix("/var/tmp/")
            || p.hasPrefix("/private/var/tmp/") || p.hasPrefix("/users/shared/")
            || p.hasPrefix(downloads)
    }

    /// 载荷是否「经核验」可作为删除候选。plist 的载荷路径由攻击者可控，绝不能凭
    /// plist 可疑就删其指向的任意文件（可能是用户文档）。仅当满足其一才列为可删除：
    /// (a) 路径本身命中已知特征库；(b) 位于启动项可执行文件的常规安置位置
    /// （应用包 / Library / /usr/local / /opt）——刻意排除 文稿/桌面/下载/图片 等用户数据目录。
    private func isVettedPayload(_ path: String) -> Bool {
        let p = path.lowercased()
        // (a) 路径自带已知广告软件 / PUP 特征
        if allSignatures.contains(where: { p.contains($0) }) { return true }
        // (b) 启动项可执行文件的常规安置位置
        let appsUser = home.appendingPathComponent("Applications").path.lowercased() + "/"
        let libUser = home.appendingPathComponent("Library").path.lowercased() + "/"
        return p.hasPrefix("/applications/") || p.hasPrefix(appsUser)
            || p.hasPrefix("/library/") || p.hasPrefix(libUser)
            || p.hasPrefix("/usr/local/") || p.hasPrefix("/opt/")
    }

    /// 系统自带解释器/工具（bash、python、launchctl 等）：由 Apple 签名，无需校验，
    /// 且大量正规工具用它们做启动脚本——校验它们只会制造噪音。
    private func isSystemBinary(_ path: String) -> Bool {
        path.hasPrefix("/bin/") || path.hasPrefix("/usr/bin/") || path.hasPrefix("/usr/sbin/")
            || path.hasPrefix("/sbin/") || path.hasPrefix("/usr/libexec/") || path.hasPrefix("/System/")
    }

    enum CodeSignState { case valid, adhoc, unsigned, invalid }

    /// 静态代码签名校验（Security.framework，与 codesign --verify 同源）。
    func codeSignState(_ url: URL) -> CodeSignState {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &staticCode) == errSecSuccess,
              let code = staticCode else { return .unsigned }
        let status = SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSBasicValidateOnly), nil)
        if status == errSecCSUnsigned { return .unsigned }
        guard status == errSecSuccess else { return .invalid }
        // 有效签名：区分 ad-hoc（无开发者身份）与正规签名
        var infoRef: CFDictionary?
        if SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &infoRef) == errSecSuccess,
           let info = infoRef as? [String: Any],
           let flags = info[kSecCodeInfoFlags as String] as? UInt32,
           flags & SecCodeSignatureFlags.adhoc.rawValue != 0 {
            return .adhoc
        }
        return .valid
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
