import SwiftUI
import Domain
import Infrastructure
import DesignSystem

public struct SimilarImagesView: View {
    private let env: XicoEnvironment
    @StateObject private var vm: ModuleSessionViewModel

    public init(env: XicoEnvironment) {
        self.env = env
        _vm = StateObject(wrappedValue: ModuleSessionViewModel(
            env: env, title: xLoc("相似图片"), intent: .trash,
            scanProvider: { handler in
                let result = await env.similarImagesScanner().scan(progress: handler)
                return [result]
            }))
    }

    /// 从 AppModel 注入缓存的会话：跨 tab 保留昂贵的 Vision 扫描结果（审计 P2，与 DuplicatesView 等一致）。
    public init(model: AppModel) {
        self.env = model.env
        _vm = StateObject(wrappedValue: model.similarImagesSession)
    }

    public var body: some View {
        SessionScaffold(vm: vm, cleanButtonTitle: xLoc("删除所选")) {
            ModuleIdleHero(
                icon: "photo.on.rectangle.angled", colors: [XColor.auroraViolet, XColor.auroraRose],
                title: xLoc("相似图片"),
                subtitle: xLoc("用本地 Vision 感知比对图片/截图（图片、桌面、下载），把视觉相近的聚为一组，每组自动保留最大的一张。全程本地计算，不上传任何图片。"),
                buttonTitle: xLoc("开始扫描"),
                action: { vm.start() })
        }
    }
}
