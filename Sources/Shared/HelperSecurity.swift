import Foundation

/// 特权助手与主应用之间的「互信」配置。
///
/// 助手以 root 运行，绝不信任任意调用方：仅接受满足下方代码签名要求的连接
/// （由 `NSXPCConnection.setCodeSigningRequirement(_:)` 在内核层强制校验）。
public enum XicoHelperSecurity {

    /// 主应用 Bundle ID（与签名时的 identifier 一致）
    public static let mainAppBundleID = "com.xico.app"

    /// 你的 Apple Developer Team ID（10 位）。务必替换为真实值，否则任何连接都将被拒绝。
    /// 查看方式：`security find-identity -v -p codesigning` 或开发者账号页面。
    public static let teamIdentifier = "REPLACE_WITH_YOUR_TEAM_ID"

    /// 允许连接助手的客户端代码签名要求（designated requirement 风格）。
    /// 含义：Apple 颁发的证书链 + 指定 bundle id + 指定 Team ID 的叶证书。
    public static var clientCodeRequirement: String {
        "anchor apple generic and identifier \"\(mainAppBundleID)\" "
        + "and certificate leaf[subject.OU] = \"\(teamIdentifier)\""
    }

    /// Team ID 是否已正确配置（未替换占位符时为 false）。
    public static var isTeamIdentifierConfigured: Bool {
        teamIdentifier != "REPLACE_WITH_YOUR_TEAM_ID" && teamIdentifier.count == 10
    }
}
