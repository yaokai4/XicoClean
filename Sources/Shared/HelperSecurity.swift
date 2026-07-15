import Foundation

/// 助手版本单一事实源——version() 握手用它比对，protocol 变更后能识别旧助手并自愈。
public enum XicoHelperInfo {
    public static let version = "0.4.0"
    public static let maximumProcessSampleCount = 4_096
}

/// 特权助手与主应用之间的「互信」配置。
///
/// 助手以 root 运行，绝不信任任意调用方：仅接受满足下方代码签名要求的连接
/// （由 `NSXPCConnection.setCodeSigningRequirement(_:)` 在内核层强制校验）。
public enum XicoHelperSecurity {

    /// 主应用 Bundle ID（与签名时的 identifier 一致）
    public static let mainAppBundleID = "com.xico.app"

    /// 你的 Apple Developer Team ID（10 位）。Apple Development / Developer ID 证书的
    /// 叶证书 subject.OU 即为该值。改用你自己的账号时替换此处。
    /// 查看方式：`security find-identity -v -p codesigning` 或开发者账号页面。
    public static let teamIdentifier = "P22K8NF89K"

    /// 允许连接助手的客户端代码签名要求（designated requirement 风格）。
    /// 含义：Apple 颁发的证书链 + 指定 bundle id + 指定 Team ID 的叶证书。
    /// 发布构建额外要求 **Developer ID Application** 叶证书标记 OID
    /// （1.2.840.113635.100.6.1.13），把「同 Team 的任意 Apple 证书」收紧为「正式分发证书」；
    /// DEBUG 不加该约束，否则用 Apple Development 证书签的本地调试版会被助手拒连。
    public static var clientCodeRequirement: String {
        let base = "anchor apple generic and identifier \"\(mainAppBundleID)\" "
            + "and certificate leaf[subject.OU] = \"\(teamIdentifier)\""
        #if DEBUG
        return base
        #else
        return base + " and certificate leaf[field.1.2.840.113635.100.6.1.13] exists"
        #endif
    }

    /// Team ID 是否已正确配置：必须是恰好 10 位大写字母/数字（Apple Team ID 形态）。
    /// 这样可防止被人为改成含引号/通配/空白的非法值而意外放宽匹配面。
    public static var isTeamIdentifierConfigured: Bool {
        guard teamIdentifier.count == 10 else { return false }
        return teamIdentifier.allSatisfy { $0.isASCII && ($0.isUppercase || $0.isNumber) }
    }

    // MARK: 助手可删白名单（纵深防御：root 助手只允许删这些系统级垃圾根下的内容）

    /// 经特权助手删除时，目标必须落在这些根目录之下（白名单优于黑名单）。
    /// 主程用户级清理走另一条路（SafetyEngine），不受此限制。
    public static let deletableRoots = [
        "/Library/Caches",
        "/Library/Logs",
        "/private/var/log",
        "/var/log"            // standardizingPath 会把 /private/var 砍成 /var，两形态都收
    ]

    /// 已词法标准化的绝对路径是否落在白名单根之下。
    public static func isUnderDeletableRoot(_ standardizedPath: String) -> Bool {
        deletableRoots.contains { standardizedPath == $0 || standardizedPath.hasPrefix($0 + "/") }
    }
}
