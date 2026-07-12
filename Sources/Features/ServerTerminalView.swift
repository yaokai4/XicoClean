import SwiftUI
import AppKit
import Domain
import Infrastructure
import DesignSystem
import SwiftTerm

/// 终端标签：macOS 15+ 用真正的交互式 SwiftTerm PTY（vim/htop/top 都能跑）；macOS 14 回退到命令控制台。
/// 打开终端会另起一条独立 SSH 连接——需授权（门禁）。
struct ServerTerminalTab: View {
    @ObservedObject var vm: ServersViewModel
    let host: ServerHost
    @ObservedObject var engine: ServerMonitorEngine
    @Binding var broadcast: Bool
    let gate: (() -> Void) -> Void
    @State private var opened = false

    var body: some View {
        if #available(macOS 15.0, *) {
            if opened {
                InteractiveTerminalView(host: host, credential: vm.credential(for: host))
                    .id(host.id)
                    .background(Color.black.opacity(0.92))
            } else {
                terminalStart
            }
        } else {
            // macOS 14：无 withPTY，回退命令控制台（需监控连接在线）。
            ServerConsoleView(vm: vm, host: host, engine: engine, broadcast: $broadcast, gate: gate)
        }
    }

    private var terminalStart: some View {
        VStack(spacing: XSpacing.l) {
            XEmptyState(systemImage: "apple.terminal",
                        title: xLoc("交互式终端"),
                        subtitle: xLoc("真正的远程 shell——vim / htop / top 都能用。将新建一条独立 SSH 会话。"))
            Button { gate { opened = true } } label: {
                Label(xLoc("打开终端"), systemImage: "bolt.fill")
            }.buttonStyle(XPrimaryButtonStyle())
            if vm.credential(for: host) == nil {
                Text(xLoc("提示：请先在主机设置中填写密码或私钥")).font(XFont.caption).foregroundStyle(XColor.warning)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// 把非 Sendable 的 TerminalView 弱引用装进盒子，供 @Sendable 输出回调在主线程 feed（只在主线程访问 view）。
private final class TerminalFeedBox: @unchecked Sendable {
    weak var view: TerminalView?
}

@available(macOS 15.0, *)
struct InteractiveTerminalView: NSViewRepresentable {
    let host: ServerHost
    let credential: SSHCredential?

    func makeCoordinator() -> Coordinator { Coordinator(host: host, credential: credential) }

    func makeNSView(context: Context) -> TerminalView {
        let tv = TerminalView(frame: CGRect(x: 0, y: 0, width: 800, height: 460), font: nil)
        tv.terminalDelegate = context.coordinator
        context.coordinator.attach(tv)
        return tv
    }

    func updateNSView(_ nsView: TerminalView, context: Context) {}

    static func dismantleNSView(_ nsView: TerminalView, coordinator: Coordinator) {
        coordinator.stop()
    }

    final class Coordinator: NSObject, TerminalViewDelegate {
        private let host: ServerHost
        private let credential: SSHCredential?
        private let feedBox = TerminalFeedBox()
        private var session: TerminalSession?
        private var started = false

        init(host: ServerHost, credential: SSHCredential?) {
            self.host = host
            self.credential = credential
        }

        func attach(_ tv: TerminalView) {
            feedBox.view = tv
            guard !started else { return }
            started = true
            guard let cred = credential else {
                tv.feed(text: "\r\n\u{001b}[33m\(xLoc("缺少凭据：请先在主机设置中填写密码或私钥"))\u{001b}[0m\r\n")
                return
            }
            let box = feedBox
            let session = TerminalSession(
                host: host,
                onOutput: { data in
                    let slice = ArraySlice(data)
                    DispatchQueue.main.async { box.view?.feed(byteArray: slice) }
                },
                onClosed: { reason in
                    DispatchQueue.main.async {
                        let msg = reason ?? "连接已关闭"
                        box.view?.feed(text: "\r\n\u{001b}[31m[\(msg)]\u{001b}[0m\r\n")
                    }
                })
            self.session = session
            // 初始尺寸用 80×24；布局后 SwiftTerm 会立即回调 sizeChanged 校正到真实列/行。
            session.start(credential: cred, cols: 80, rows: 24)
        }

        func stop() { session?.stop(); session = nil }

        // MARK: TerminalViewDelegate
        func send(source: TerminalView, data: ArraySlice<UInt8>) { session?.send(Data(data)) }
        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) { session?.resize(cols: newCols, rows: newRows) }
        func setTerminalTitle(source: TerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
        func scrolled(source: TerminalView, position: Double) {}
        func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {}
        func bell(source: TerminalView) {}
        func clipboardCopy(source: TerminalView, content: Data) {
            if let s = String(data: content, encoding: .utf8) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(s, forType: .string)
            }
        }
        func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
        func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
    }
}
