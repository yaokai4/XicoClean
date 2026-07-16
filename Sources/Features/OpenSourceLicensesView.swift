import SwiftUI
import AppKit
import DesignSystem

/// 开源组件与许可证（GPL/LGPL 要求把所用组件的许可证「传递」给用户——合规必需）。
/// 含库依赖（编译进 App）与运行时组件（yt-dlp/ffmpeg/aria2，用户设备上按需获取）。
struct OpenSourceLicensesView: View {
    let onClose: () -> Void

    struct Component: Identifiable {
        let id = UUID()
        let name: String
        let license: String
        let usage: String        // 如何被使用
        let url: String
    }

    private let libraries: [Component] = [
        .init(name: "SwiftTerm", license: "MIT", usage: "交互式终端仿真", url: "https://github.com/migueldeicaza/SwiftTerm")
    ]

    private let runtime: [Component] = [
        .init(name: "yt-dlp", license: "Unlicense（源）/ GPLv3+（预编译）", usage: "媒体解析组件——在你的设备上按需从上游获取，未随本 App 打包", url: "https://github.com/yt-dlp/yt-dlp"),
        .init(name: "FFmpeg", license: "LGPL-2.1+", usage: "媒体合并 / 音频提取组件", url: "https://ffmpeg.org"),
        .init(name: "aria2", license: "GPLv2+", usage: "磁力 / 种子 / 加速下载组件——按需从上游获取", url: "https://aria2.github.io")
    ]

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(xLoc("开源许可与致谢")).font(XFont.title2)
                    Text(xLoc("本产品基于以下优秀开源项目构建")).font(XFont.caption).foregroundStyle(XColor.textSecondary)
                }
                Spacer()
            }
            .padding(XSpacing.xl)
            Divider().opacity(0.3)

            ScrollView {
                VStack(alignment: .leading, spacing: XSpacing.l) {
                    section(xLoc("内置库依赖"), libraries)
                    section(xLoc("运行时组件（在你的设备上按需获取，未随 App 打包）"), runtime)
                    Text(xLoc("各组件版权归其各自作者所有，依其许可证条款分发。点击名称查看项目主页与完整许可证。"))
                        .font(XFont.micro).foregroundStyle(XColor.textTertiary)
                }
                .padding(XSpacing.xl)
            }

            Divider().opacity(0.3)
            HStack { Spacer(); Button(xLoc("完成"), action: onClose).buttonStyle(XPrimaryButtonStyle()) }
                .padding(XSpacing.xl)
        }
        .frame(width: 560, height: 560)
    }

    private func section(_ title: String, _ items: [Component]) -> some View {
        VStack(alignment: .leading, spacing: XSpacing.s) {
            Text(title).font(XFont.captionEmphasis).foregroundStyle(XColor.textSecondary)
            ForEach(items) { c in
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Button(c.name) { NSWorkspace.shared.open(URL(string: c.url)!) }
                            .buttonStyle(.link).font(XFont.bodyEmphasis)
                        Spacer()
                        XBadge(c.license, color: XColor.info)
                    }
                    Text(c.usage).font(XFont.micro).foregroundStyle(XColor.textTertiary)
                }
                .padding(XSpacing.m)
                .background(XColor.surfaceAlt.opacity(0.5), in: RoundedRectangle(cornerRadius: XRadius.card, style: .continuous))
            }
        }
    }
}
