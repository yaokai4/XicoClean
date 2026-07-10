import SwiftUI
import AppKit
import WebKit
import DesignSystem

// MARK: - 应用内浏览器（docs/14 P2 · 签名时刻 S3「零离开购买」）
// 购买 / 隐私政策等官网页面在 App 内完成，不再抛去系统浏览器。
// 导航拦截 xico://activate?key=… → 回调激活并关闭（应用内可信上下文——区别于外部深链
// XicoApp.swift 的 NSAlert 确认路径，本页面本来就是用户主动打开的购买流程）。
// 「在浏览器中打开」逃逸按钮永远保留：内嵌是便利，不是牢笼。

/// 浏览器呈现目标（sheet item）。
struct BrowserTarget: Identifiable {
    let id = UUID()
    let url: URL
    let title: String
}

struct InAppBrowserView: View {
    let target: BrowserTarget
    /// 拦截到 xico://activate?key= 时回调（已关闭浏览器后调用方负责激活流程）。
    var onActivate: ((String) -> Void)?

    @Environment(\.dismiss) private var dismiss
    @StateObject private var state = WebPageState()

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            WebViewContainer(state: state, initialURL: target.url, onActivate: { key in
                dismiss()
                onActivate?(key)
            })
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 980, height: 720)
        .background(XColor.surface)
    }

    private var toolbar: some View {
        HStack(spacing: XSpacing.s) {
            HStack(spacing: 2) {
                Button { state.webView?.goBack() } label: { Image(systemName: "chevron.left") }
                    .buttonStyle(.plain).frame(width: 26, height: 26)
                    .disabled(!state.canGoBack)
                    .accessibilityLabel(xLoc("返回"))
                Button { state.webView?.goForward() } label: { Image(systemName: "chevron.right") }
                    .buttonStyle(.plain).frame(width: 26, height: 26)
                    .disabled(!state.canGoForward)
                    .accessibilityLabel(xLoc("前进"))
                Button { state.webView?.reload() } label: {
                    Image(systemName: state.isLoading ? "xmark" : "arrow.clockwise")
                }
                .buttonStyle(.plain).frame(width: 26, height: 26)
                .accessibilityLabel(state.isLoading ? xLoc("停止") : xLoc("刷新"))
            }
            .foregroundStyle(XColor.textSecondary)

            // 地址（只读展示——购买流程不需要可编辑地址栏，降低钓鱼面）。
            HStack(spacing: XSpacing.xs) {
                Image(systemName: (state.currentURL?.scheme == "https") ? "lock.fill" : "globe")
                    .font(XFont.micro).foregroundStyle(XColor.textTertiary)
                Text(state.currentURL?.host ?? target.url.host ?? "")
                    .font(XFont.caption).foregroundStyle(XColor.textSecondary)
                    .lineLimit(1).truncationMode(.middle)
                if state.isLoading {
                    XRingGauge(progress: 0, spinning: true, colors: XColor.brandGradientColors,
                               lineWidth: 2, size: 12) { EmptyView() }
                }
            }
            .padding(.horizontal, XSpacing.m).padding(.vertical, 5)
            .frame(maxWidth: .infinity)
            .background(Capsule().fill(XColor.surfaceAlt.opacity(0.7)))
            .overlay(Capsule().stroke(XColor.hairline, lineWidth: 1))

            Button(xLoc("在浏览器中打开")) {
                if let url = state.currentURL ?? Optional(target.url) { NSWorkspace.shared.open(url) }
            }
            .buttonStyle(XSecondaryButtonStyle(compact: true))

            Button { dismiss() } label: {
                Image(systemName: "xmark").font(.system(size: 11, weight: .bold))
                    .foregroundStyle(XColor.textTertiary)
                    .frame(width: 26, height: 26).background(XColor.surfaceAlt, in: Circle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
            .accessibilityLabel(xLoc("关闭"))
        }
        .padding(.horizontal, XSpacing.l).padding(.vertical, XSpacing.s)
    }
}

/// WKWebView 的可观察状态（KVO 桥接 → SwiftUI）。
@MainActor
private final class WebPageState: ObservableObject {
    @Published var canGoBack = false
    @Published var canGoForward = false
    @Published var isLoading = false
    @Published var currentURL: URL?
    weak var webView: WKWebView?
    var observations: [NSKeyValueObservation] = []

    func attach(_ webView: WKWebView) {
        self.webView = webView
        observations = [
            webView.observe(\.canGoBack, options: [.initial, .new]) { [weak self] wv, _ in
                Task { @MainActor in self?.canGoBack = wv.canGoBack }
            },
            webView.observe(\.canGoForward, options: [.initial, .new]) { [weak self] wv, _ in
                Task { @MainActor in self?.canGoForward = wv.canGoForward }
            },
            webView.observe(\.isLoading, options: [.initial, .new]) { [weak self] wv, _ in
                Task { @MainActor in self?.isLoading = wv.isLoading }
            },
            webView.observe(\.url, options: [.initial, .new]) { [weak self] wv, _ in
                Task { @MainActor in self?.currentURL = wv.url }
            },
        ]
    }
}

private struct WebViewContainer: NSViewRepresentable {
    let state: WebPageState
    let initialURL: URL
    let onActivate: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onActivate: onActivate) }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()   // 购买会话可能跨页跳转（Stripe），保留 cookie
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true
        state.attach(webView)
        webView.load(URLRequest(url: initialURL))
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        let onActivate: (String) -> Void
        init(onActivate: @escaping (String) -> Void) { self.onActivate = onActivate }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
            guard let url = navigationAction.request.url else { return decisionHandler(.cancel) }
            // 支付成功页的回跳深链：xico://activate?key=XXXX → 拦截并转交激活流程。
            if url.scheme?.lowercased() == "xico" {
                if url.host?.lowercased() == "activate",
                   let key = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                       .queryItems?.first(where: { $0.name == "key" })?.value,
                   !key.isEmpty {
                    onActivate(key)
                }
                return decisionHandler(.cancel)
            }
            // 邮件支持链接交给系统邮件客户端；其余非 http(s) 协议一律拒绝（收紧攻击面）。
            if url.scheme?.lowercased() == "mailto" {
                NSWorkspace.shared.open(url)
                return decisionHandler(.cancel)
            }
            guard url.scheme == "https" || url.scheme == "http" else { return decisionHandler(.cancel) }
            decisionHandler(.allow)
        }

        /// target=_blank（如条款新窗口）：在当前 webview 内打开，不产生游离窗口。
        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                     for navigationAction: WKNavigationAction,
                     windowFeatures: WKWindowFeatures) -> WKWebView? {
            if let url = navigationAction.request.url { webView.load(URLRequest(url: url)) }
            return nil
        }
    }
}
