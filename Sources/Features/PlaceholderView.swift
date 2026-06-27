import SwiftUI
import Domain
import DesignSystem

/// 尚未实现模块的占位页（清晰说明将提供的能力）。
public struct PlaceholderView: View {
    let meta: ModuleMetadata?
    public init(meta: ModuleMetadata?) { self.meta = meta }

    public var body: some View {
        VStack(spacing: XSpacing.l) {
            Image(systemName: meta?.systemImage ?? "hammer")
                .font(.system(size: 56, weight: .light))
                .foregroundStyle(XColor.brandGradient)
            Text(meta?.title ?? "模块").font(XFont.title).foregroundStyle(XColor.textPrimary)
            XBadge("即将推出", color: XColor.warning)
            Text(detail)
                .font(XFont.body).foregroundStyle(XColor.textSecondary)
                .multilineTextAlignment(.center).frame(maxWidth: 460)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var detail: String {
        switch meta?.id {
        case .some(.duplicates):
            return "内容级重复文件查找：按大小分组 → 头部哈希 → 全量比对，识别 APFS 克隆避免误判，并给出智能保留建议。"
        case .some(.uninstaller):
            return "彻底卸载应用：连同 Application Support、缓存、偏好、容器、登录项与收据一并清除，并扫描已删应用的孤儿残留。"
        case .some(.optimization):
            return "性能优化：管理登录项与启动代理、识别高资源占用进程、一键释放内存。"
        case .some(.maintenance):
            return "系统维护：运行维护脚本、重建 Spotlight 索引、刷新 DNS、释放可清除空间（需特权助手）。"
        case .some(.privacy):
            return "隐私清理：清除浏览器历史 / Cookie / 缓存（Safari、Chrome、Firefox、Edge、Arc）与最近项目记录。"
        default:
            return "该模块将在后续里程碑中实现，详见路线图文档。"
        }
    }
}
