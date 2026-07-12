import SwiftUI
import AppKit
import WebKit
import Domain
import Infrastructure
import DesignSystem

/// 内置「浏览抓取」浏览器——对标 Downie 的 coffee-mug 抓取：浏览任意站点，一键把当前页交给引擎解析下载，
/// 并用 JS 侦测页面里的直链媒体（video/source/og:video/.m3u8）。
struct DownloaderBrowserView: View {
    @ObservedObject var engine: DownloadManager
    let gate: (() -> Void) -> Void
    @StateObject private var state = CaptureWebState()
    @State private var address = "https://"

    var body: some View {
        VStack(spacing: XSpacing.s) {
            // 地址栏 + 导航
            HStack(spacing: XSpacing.s) {
                Button { state.webView?.goBack() } label: { Image(systemName: "chevron.left") }
                    .buttonStyle(XSecondaryButtonStyle()).disabled(!state.canGoBack)
                Button { state.webView?.goForward() } label: { Image(systemName: "chevron.right") }
                    .buttonStyle(XSecondaryButtonStyle()).disabled(!state.canGoForward)
                Button { state.webView?.reload() } label: { Image(systemName: state.isLoading ? "xmark" : "arrow.clockwise") }
                    .buttonStyle(XSecondaryButtonStyle())
                XCapsuleTextField(placeholder: xLoc("搜索或输入网址…"), text: $address, onSubmit: navigate)
                capture
            }
            if state.isLoading { XDiskBar(usedFraction: 0.35, label: "", height: 3) }

            CaptureWebContainer(state: state)
                .clipShape(RoundedRectangle(cornerRadius: XRadius.card, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: XRadius.card).strokeBorder(XColor.border))
        }
        .padding(XSpacing.xl)
        .onChange(of: state.currentURL) { _, new in if let u = new { address = u.absoluteString } }
    }

    @ViewBuilder private var capture: some View {
        let hasDirect = !state.detectedMedia.isEmpty
        Menu {
            Button { grabPage(.video) } label: { Label(xLoc("抓取此页 · 视频"), systemImage: "film") }
            Button { grabPage(.audio) } label: { Label(xLoc("抓取此页 · 音频"), systemImage: "music.note") }
            Button { grabPage(.image) } label: { Label(xLoc("抓取此页图片"), systemImage: "photo") }
            if hasDirect {
                Divider()
                Text(xLoc("侦测到的直链媒体"))
                ForEach(Array(state.detectedMedia.prefix(8)), id: \.self) { m in
                    Button(m) { gate { engine.add(urlString: m, kind: .video) } }
                }
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "square.and.arrow.down.on.square")
                Text(xLoc("抓取"))
                if hasDirect { Text("\(state.detectedMedia.count)").font(XFont.microMono)
                    .padding(.horizontal, 5).background(XColor.brand.opacity(0.2), in: Capsule()) }
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .padding(.horizontal, XSpacing.m).padding(.vertical, XSpacing.s)
        .background(XColor.brandGradient, in: Capsule())
        .foregroundStyle(XColor.onAccent)
    }

    private func navigate() {
        var s = address.trimmingCharacters(in: .whitespaces)
        if !s.contains("://") {
            if s.contains(".") && !s.contains(" ") { s = "https://" + s }
            else { s = "https://duckduckgo.com/?q=" + (s.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? s) }
        }
        if let url = URL(string: s) { state.webView?.load(URLRequest(url: url)) }
    }

    private func grabPage(_ kind: DownloadKind) {
        guard let u = state.currentURL?.absoluteString else { return }
        gate { engine.add(urlString: u, kind: kind) }
    }
}

@MainActor
final class CaptureWebState: ObservableObject {
    @Published var canGoBack = false
    @Published var canGoForward = false
    @Published var isLoading = false
    @Published var currentURL: URL?
    @Published var detectedMedia: [String] = []
    weak var webView: WKWebView?
    var observations: [NSKeyValueObservation] = []

    func attach(_ wv: WKWebView) {
        webView = wv
        observations = [
            wv.observe(\.canGoBack, options: [.initial, .new]) { [weak self] w, _ in Task { @MainActor in self?.canGoBack = w.canGoBack } },
            wv.observe(\.canGoForward, options: [.initial, .new]) { [weak self] w, _ in Task { @MainActor in self?.canGoForward = w.canGoForward } },
            wv.observe(\.isLoading, options: [.initial, .new]) { [weak self] w, _ in Task { @MainActor in self?.isLoading = w.isLoading } },
            wv.observe(\.url, options: [.initial, .new]) { [weak self] w, _ in Task { @MainActor in self?.currentURL = w.url } },
        ]
    }

    func sniffMedia() {
        let js = """
        (function(){var s=new Set();
        document.querySelectorAll('video, source, video source').forEach(function(e){if(e.src)s.add(e.src);if(e.currentSrc)s.add(e.currentSrc);});
        var og=document.querySelector('meta[property=\\"og:video\\"],meta[property=\\"og:video:url\\"]');if(og&&og.content)s.add(og.content);
        var m=document.documentElement.innerHTML.match(/https?:[^\\"'\\s]+\\.m3u8[^\\"'\\s]*/g);if(m)m.forEach(function(u){s.add(u);});
        return Array.from(s).slice(0,20);})();
        """
        webView?.evaluateJavaScript(js) { [weak self] result, _ in
            Task { @MainActor in
                self?.detectedMedia = (result as? [String])?.filter { $0.hasPrefix("http") } ?? []
            }
        }
    }
}

struct CaptureWebContainer: NSViewRepresentable {
    let state: CaptureWebState

    func makeCoordinator() -> Coordinator { Coordinator(state: state) }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true
        webView.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"
        state.attach(webView)
        webView.load(URLRequest(url: URL(string: "https://www.youtube.com")!))
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        let state: CaptureWebState
        init(state: CaptureWebState) { self.state = state }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            state.sniffMedia()
        }
        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                     for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            if let url = navigationAction.request.url { webView.load(URLRequest(url: url)) }
            return nil
        }
    }
}
