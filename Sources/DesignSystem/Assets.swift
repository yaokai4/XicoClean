import Foundation

/// DesignSystem 资源包的对外访问口（音效等非本地化资产）。
/// SPM 的 `Bundle.module` 是 target 私有——其它模块（如 Infrastructure 的 XSound）经此取资源。
public enum XAssets {
    /// 签名音效资产 URL（docs/16 P0-2：定制音色替换系统占位）。找不到返回 nil，调用方回退系统音。
    public static func soundURL(_ name: String) -> URL? {
        Bundle.module.url(forResource: name, withExtension: "wav")
    }
}
