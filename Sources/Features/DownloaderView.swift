import SwiftUI
import AppKit
import Domain
import Infrastructure
import DesignSystem

/// 下载器页面（对标 Downie 4，直销版专属）：引擎自安装 + 粘贴/输入 URL + 视频/音频/图片 + 队列 + 清晰度选择。
/// 中立、用户自填 URL 姿态；yt-dlp/ffmpeg 运行时下载不打包（法务见 [[downie-downloader-legal-risk]]）。
public struct DownloaderView: View {
    @ObservedObject private var model: AppModel
    @ObservedObject private var engine: DownloadManager
    @State private var urlText = ""
    @State private var kind: DownloadKind = .video
    @State private var mode: DlMode = .queue
    @State private var showingPrefs = false
    @State private var inputError: String?
    @FocusState private var urlFocused: Bool

    enum DlMode: String, CaseIterable, Hashable { case queue, browse
        var title: String { self == .queue ? xLoc("队列") : xLoc("浏览抓取") }
    }

    public init(model: AppModel, engine: DownloadManager? = nil) {
        self.model = model
        self.engine = engine ?? model.env.downloadManager
    }

    public var body: some View {
        VStack(spacing: 0) {
            XHeaderBar(title: xLoc("下载器"), subtitle: xLoc("视频 / 音频 / 图片 · 1000+ 站点 · 浏览抓取")) {
                HStack(spacing: XSpacing.s) {
                    if !engine.jobs.filter({ $0.state.isTerminal }).isEmpty {
                        Button { engine.clearFinished() } label: { Label(xLoc("清除已完成"), systemImage: "trash") }
                            .buttonStyle(XSecondaryButtonStyle())
                    }
                    Button { showingPrefs = true } label: { Image(systemName: "gearshape") }
                        .buttonStyle(XSecondaryButtonStyle()).help(xLoc("下载偏好"))
                        .accessibilityLabel(xLoc("下载偏好"))
                }
            }
            Divider().opacity(0.25)

            XSegmentedControl(selection: $mode, options: DlMode.allCases.map {
                .init(tag: $0, label: $0.title, a11y: $0.title)
            })
            .padding(.horizontal, XSpacing.xl).padding(.top, XSpacing.s)

            if mode == .browse {
                DownloaderBrowserView(engine: engine, gate: { gate($0) })
            } else {
                ScrollView {
                    VStack(spacing: XSpacing.m) {
                        engineBanner
                        if let pending = engine.pendingClipboardURL { clipboardBanner(pending) }
                        addBar
                        if let inputError {
                            Label(inputError, systemImage: "exclamationmark.circle.fill")
                                .font(XFont.caption)
                                .foregroundStyle(XColor.danger)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .accessibilityLabel(inputError)
                        }
                        if engine.jobs.isEmpty {
                            XEmptyState(systemImage: "arrow.down.circle",
                                        title: xLoc("粘贴一个链接开始下载"),
                                        subtitle: xLoc("支持视频 / 音频 / 图片。请仅下载你拥有或已获授权的内容。"))
                                .padding(.top, XSpacing.xxl)
                        } else {
                            ForEach(engine.jobs) { job in
                                DownloadRow(job: job, engine: engine)
                            }
                        }
                    }
                    .padding(XSpacing.xl)
                }
            }
        }
        .onAppear { engine.refreshEngineStatus() }
        .sheet(isPresented: $showingPrefs) { DownloaderPreferencesView(engine: engine) { showingPrefs = false } }
    }

    private func clipboardBanner(_ url: String) -> some View {
        HStack(spacing: XSpacing.m) {
            Image(systemName: "doc.on.clipboard.fill").foregroundStyle(XColor.brand)
            VStack(alignment: .leading, spacing: 1) {
                Text(xLoc("剪贴板检测到链接")).font(XFont.bodyEmphasis).foregroundStyle(XColor.textPrimary)
                Text(url).font(XFont.micro).foregroundStyle(XColor.textSecondary).lineLimit(1)
            }
            Spacer()
            Button(xLoc("下载")) { gate { engine.add(urlString: url, kind: kind) } }.buttonStyle(XPrimaryButtonStyle())
            Button { engine.dismissClipboardSuggestion() } label: { Image(systemName: "xmark") }
                .buttonStyle(.plain).foregroundStyle(XColor.textTertiary)
                .frame(minWidth: 28, minHeight: 28)
                .contentShape(Rectangle())
                .accessibilityLabel(xLoc("关闭剪贴板建议"))
        }
        .padding(XSpacing.m)
        .background(XColor.brand.opacity(0.08), in: RoundedRectangle(cornerRadius: XRadius.card, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: XRadius.card).strokeBorder(XColor.brand.opacity(0.3)))
    }

    // MARK: 引擎状态横幅

    @ViewBuilder private var engineBanner: some View {
        switch engine.engineStatus {
        case .notInstalled:
            banner(icon: "shippingbox", tint: XColor.warning,
                   title: xLoc("媒体组件未就绪"),
                   subtitle: xLoc("首次使用需准备媒体解析组件（约 30MB，一次性，之后自动保持最新）。")) {
                Button { engine.installEngine() } label: { Label(xLoc("一键准备"), systemImage: "arrow.down.app") }
                    .buttonStyle(XPrimaryButtonStyle())
            }
        case .installing:
            banner(icon: "arrow.down.circle", tint: XColor.info,
                   title: xLoc("正在准备媒体组件…"), subtitle: xLoc("下载并校验中，请稍候")) {
                XSpinner(size: 16)
            }
        case .failed(let msg):
            banner(icon: "exclamationmark.triangle", tint: XColor.danger, title: xLoc("媒体组件准备失败"), subtitle: msg) {
                Button { engine.installEngine() } label: { Text(xLoc("重试")) }.buttonStyle(XSecondaryButtonStyle())
            }
        case .ready(let ffmpeg):
            if !ffmpeg {
                banner(icon: "checkmark.seal", tint: XColor.warning,
                       title: xLoc("媒体组件已就绪"),
                       subtitle: mergeSubtitle) {
                    if engine.componentInstall.isInstalling {
                        HStack(spacing: 6) { XSpinner(size: 14); Text(xLoc("准备中…")).font(XFont.caption).foregroundStyle(XColor.textSecondary) }
                    } else {
                        Button { engine.installMergeComponent() } label: { Label(xLoc("补齐组件"), systemImage: "arrow.down.app") }
                            .buttonStyle(XSecondaryButtonStyle())
                    }
                }
            }
        }
    }

    private var mergeSubtitle: String {
        if case .failed(let msg) = engine.componentInstall { return msg }
        return xLoc("高画质合并 / 音频提取组件未就绪，部分格式受限。")
    }

    private func banner<Trailing: View>(icon: String, tint: Color, title: String, subtitle: String,
                                        @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack(spacing: XSpacing.m) {
            Image(systemName: icon).font(.system(size: 18)).foregroundStyle(tint).frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(XFont.bodyEmphasis).foregroundStyle(XColor.textPrimary)
                Text(subtitle).font(XFont.caption).foregroundStyle(XColor.textSecondary)
            }
            Spacer()
            trailing()
        }
        .padding(XSpacing.m)
        .background(tint.opacity(0.08), in: RoundedRectangle(cornerRadius: XRadius.card, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: XRadius.card).strokeBorder(tint.opacity(0.25)))
    }

    // MARK: 添加栏

    private var addBar: some View {
        HStack(spacing: XSpacing.s) {
            XSegmentedControl(selection: $kind, options: DownloadKind.allCases.map {
                .init(tag: $0, icon: $0.symbol, label: xLoc($0.title), a11y: xLoc($0.title))
            })
            .frame(width: 220)
            XCapsuleTextField(placeholder: xLoc("粘贴链接或磁力 magnet: …"), text: $urlText, onSubmit: addAction)
                .focused($urlFocused)
                .onChange(of: urlText) { inputError = nil }
            Button { pasteAndAdd() } label: { Image(systemName: "doc.on.clipboard") }
                .buttonStyle(XSecondaryButtonStyle()).help(xLoc("从剪贴板粘贴并添加"))
                .accessibilityLabel(xLoc("从剪贴板粘贴并添加"))
            Button(action: addAction) { Label(xLoc("添加"), systemImage: "plus") }
                .buttonStyle(XPrimaryButtonStyle())
                .disabled(urlText.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }

    private func addAction() {
        let url = urlText
        guard !url.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        gate {
            if engine.add(urlString: url, kind: kind) {
                urlText = ""
                inputError = nil
                urlFocused = true
            } else {
                inputError = xLoc("请输入有效的 HTTP、HTTPS 或磁力链接")
            }
        }
    }

    private func pasteAndAdd() {
        if let s = NSPasteboard.general.string(forType: .string), s.contains("://") {
            urlText = s
            addAction()
        }
    }

    private func gate(_ action: () -> Void) {
        if model.licenseStatus?.state.allowsCommercialUse == true { action() }
        else { model.showPricing = true }
    }
}

// MARK: - 下载偏好（对标 Downie Preferences）

private struct DownloaderPreferencesView: View {
    @ObservedObject var engine: DownloadManager
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack { Text(xLoc("下载偏好")).font(XFont.title2); Spacer() }.padding(XSpacing.xl)
            Divider().opacity(0.3)
            ScrollView {
                VStack(alignment: .leading, spacing: XSpacing.l) {
                    row(xLoc("视频画质")) {
                        Picker("", selection: $engine.preferences.videoQuality) {
                            ForEach(DownloadPreferences.VideoQuality.allCases) { q in Text(xLoc(q.title)).tag(q) }
                        }.labelsHidden().pickerStyle(.menu).frame(width: 140)
                    }
                    row(xLoc("音频格式")) {
                        Picker("", selection: $engine.preferences.audioFormat) {
                            ForEach(["mp3", "m4a", "opus", "flac", "best"], id: \.self) { Text($0).tag($0) }
                        }.labelsHidden().pickerStyle(.menu).frame(width: 140)
                    }
                    row(xLoc("同时下载数")) {
                        Stepper(value: $engine.preferences.maxConcurrent, in: 1...8) {
                            Text("\(engine.preferences.maxConcurrent)").font(XFont.bodyEmphasis).monospacedDigit()
                        }.frame(width: 140)
                    }
                    Divider().opacity(0.3)
                    // Cookies —— 下载 X(Twitter)/需登录站点的关键开关。
                    VStack(alignment: .leading, spacing: XSpacing.xs) {
                        row(xLoc("从浏览器读取 Cookies")) {
                            Picker("", selection: $engine.preferences.cookiesBrowser) {
                                ForEach(DownloadPreferences.cookieBrowserOptions, id: \.self) { b in
                                    Text(b == "none" ? xLoc("不使用") : b.capitalized).tag(b)
                                }
                            }.labelsHidden().pickerStyle(.menu).frame(width: 140)
                        }
                        Text(xLoc("下载 X(Twitter)、私密或需登录的视频时开启，用所选浏览器的登录态。"))
                            .font(XFont.micro).foregroundStyle(XColor.textTertiary)
                    }
                    Divider().opacity(0.3)
                    toggle(xLoc("嵌入字幕"), xLoc("下载并嵌入字幕（需 ffmpeg）"), $engine.preferences.embedSubtitles)
                    if engine.preferences.embedSubtitles {
                        row(xLoc("字幕语言")) {
                            XCapsuleTextField(placeholder: "en.*,zh.*", text: $engine.preferences.subtitleLangs)
                                .frame(width: 180)
                        }
                    }
                    toggle(xLoc("嵌入元数据"), xLoc("标题 / 作者 / 章节（需 ffmpeg）"), $engine.preferences.embedMetadata)
                    toggle(xLoc("嵌入封面缩略图"), xLoc("需 ffmpeg"), $engine.preferences.embedThumbnail)
                    Divider().opacity(0.3)
                    toggle(xLoc("剪贴板自动捕获"), xLoc("复制视频链接时自动提示下载（Downie 同款）"), $engine.preferences.clipboardMonitor)
                    row(xLoc("磁力 / 种子加速组件")) {
                        if engine.accelReady {
                            Label(xLoc("已就绪"), systemImage: "checkmark.circle.fill").font(XFont.caption).foregroundStyle(XColor.success)
                        } else if engine.componentInstall.isInstalling {
                            HStack(spacing: 6) { XSpinner(size: 13); Text(xLoc("准备中…")).font(XFont.caption).foregroundStyle(XColor.textSecondary) }
                        } else {
                            Button(xLoc("一键准备")) { engine.installAccelComponent() }.buttonStyle(XSecondaryButtonStyle())
                        }
                    }
                    if case .failed(let msg) = engine.componentInstall {
                        Text(msg).font(XFont.micro).foregroundStyle(XColor.danger)
                    }
                    row(xLoc("保存到")) {
                        HStack(spacing: XSpacing.s) {
                            Text((engine.defaultDestination as NSString).abbreviatingWithTildeInPath)
                                .font(XFont.captionMono).foregroundStyle(XColor.textSecondary).lineLimit(1)
                            Button(xLoc("更改…")) { pickFolder() }.buttonStyle(XSecondaryButtonStyle())
                        }
                    }
                }
                .padding(XSpacing.xl)
            }
            Divider().opacity(0.3)
            HStack { Spacer(); Button(xLoc("完成")) { engine.savePreferences(); onClose() }.buttonStyle(XPrimaryButtonStyle()) }
                .padding(XSpacing.xl)
        }
        .frame(width: 480, height: 500)
    }

    private func row<Trailing: View>(_ label: String, @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack { Text(label).font(XFont.bodyEmphasis).foregroundStyle(XColor.textPrimary); Spacer(); trailing() }
    }
    private func toggle(_ title: String, _ subtitle: String, _ binding: Binding<Bool>) -> some View {
        HStack(spacing: XSpacing.m) {
            Toggle(isOn: binding) { EmptyView() }.toggleStyle(XThemeSwitchStyle()).labelsHidden()
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(XFont.bodyEmphasis).foregroundStyle(XColor.textPrimary)
                Text(subtitle).font(XFont.micro).foregroundStyle(XColor.textTertiary)
            }
            Spacer()
        }
    }
    private func pickFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { engine.defaultDestination = url.path }
    }
}

// MARK: - 下载行

private struct DownloadRow: View {
    let job: DownloadJob
    @ObservedObject var engine: DownloadManager

    private var isTorrent: Bool { DownloadManager.isTorrentURL(job.sourceURL) }

    var body: some View {
        HStack(spacing: XSpacing.m) {
            thumbnail
            VStack(alignment: .leading, spacing: 5) {
                Text(job.title).font(XFont.bodyEmphasis).foregroundStyle(XColor.textPrimary).lineLimit(1)
                HStack(spacing: XSpacing.s) {
                    stateBadge
                    if let m = job.manifest, m.isPlaylist {
                        XBadge(xLocF("播放列表 %d", m.playlistCount), color: XColor.accentPink)
                    }
                    if let m = job.manifest, let up = m.uploader {
                        Text(up).font(XFont.micro).foregroundStyle(XColor.textTertiary).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    if case .downloading(_, let speed, let eta) = job.state {
                        if !speed.isEmpty {
                            Text(eta.isEmpty ? speed : "\(speed) · \(xLocF("剩 %@", eta))")
                                .font(XFont.microMono).foregroundStyle(XColor.textSecondary).lineLimit(1)
                        }
                    }
                }
                progressBar
            }
            Spacer(minLength: XSpacing.s)

            // 清晰度选择（视频且有清单）
            if job.kind == .video, let m = job.manifest, !m.videoFormats.isEmpty {
                Menu {
                    ForEach(m.videoFormats.prefix(12)) { f in
                        Button("\(f.qualityLabel) · \(f.ext)") { engine.chooseFormat(job.id, formatID: f.formatID); engine.startOrQueue(job.id) }
                    }
                } label: {
                    Image(systemName: "slider.horizontal.3")
                }.menuStyle(.borderlessButton).frame(width: 26).help(xLoc("选择清晰度并重新下载"))
            }

            actions
        }
        .padding(XSpacing.m)
        .background(XColor.surface, in: RoundedRectangle(cornerRadius: XRadius.card, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: XRadius.card).strokeBorder(XColor.border))
    }

    @ViewBuilder private var thumbnail: some View {
        ZStack {
            RoundedRectangle(cornerRadius: XRadius.control, style: .continuous).fill(XColor.surfaceAlt)
            if let t = job.thumbnailURL, let url = URL(string: t) {
                AsyncImage(url: url) { phase in
                    if let img = phase.image {
                        img.resizable().aspectRatio(contentMode: .fill)
                    } else {
                        Image(systemName: iconName).font(.system(size: 15)).foregroundStyle(XColor.brand)
                    }
                }
            } else {
                Image(systemName: iconName).font(.system(size: 15)).foregroundStyle(XColor.brand)
            }
        }
        .frame(width: 46, height: 34)
        .clipShape(RoundedRectangle(cornerRadius: XRadius.control, style: .continuous))
    }

    private var iconName: String {
        isTorrent ? "point.3.connected.trianglepath.dotted" : job.kind.symbol
    }

    @ViewBuilder private var progressBar: some View {
        switch job.state {
        case .probing:
            XProgressBar(progress: 0, height: 5, indeterminate: true)
        case .downloading(let p, _, _):
            XProgressBar(progress: p, height: 5)
        case .postprocessing:
            XProgressBar(progress: 0.985, height: 5, colors: [XColor.info, XColor.brand])
        default:
            EmptyView()
        }
    }

    private var stateBadge: some View {
        let (color, text): (Color, String) = {
            switch job.state {
            case .completed: return (XColor.success, xLoc("已完成"))
            case .failed: return (XColor.danger, job.state.label)
            case .quarantined: return (XColor.warning, job.state.label)
            case .canceled: return (XColor.idle, xLoc("已取消"))
            case .paused: return (XColor.warning, xLoc("已暂停 · 可继续"))
            case .queued: return (XColor.textSecondary, xLoc("排队中"))
            case .downloading(let p, _, _): return (XColor.info, "\(Int(p * 100))%")
            case .postprocessing: return (XColor.brand, xLoc("后处理中…"))
            default: return (XColor.textSecondary, job.state.label)
            }
        }()
        return Text(text).font(XFont.micro.weight(.medium)).foregroundStyle(color).lineLimit(1)
    }

    @ViewBuilder private var actions: some View {
        switch job.state {
        case .downloading, .postprocessing:
            iconButton("pause.circle", XColor.textSecondary, xLoc("暂停")) { engine.pause(job.id) }
            iconButton("stop.circle", XColor.textSecondary, xLoc("取消")) { engine.cancel(job.id) }
        case .probing, .queued:
            iconButton("stop.circle", XColor.textSecondary, xLoc("取消")) { engine.cancel(job.id) }
        case .paused:
            iconButton("play.circle.fill", XColor.brand, xLoc("继续")) { engine.resume(job.id) }
        case .completed:
            iconButton("magnifyingglass.circle", XColor.brand, xLoc("在访达中显示")) { engine.revealInFinder(job) }
        case .failed, .canceled:
            iconButton("arrow.clockwise.circle", XColor.brand, xLoc("重试")) { engine.retry(job.id) }
        case .quarantined:
            Image(systemName: "shield.lefthalf.filled")
                .font(.system(size: 17)).foregroundStyle(XColor.warning)
                .help(xLoc("隔离：未交给下载引擎执行"))
        default:
            EmptyView()
        }
        iconButton("xmark.circle", XColor.textTertiary, xLoc("移除")) { engine.remove(job.id) }
    }

    private func iconButton(_ symbol: String, _ color: Color, _ help: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).font(.system(size: 17)) }
            .buttonStyle(.plain).foregroundStyle(color).help(help)
    }
}
