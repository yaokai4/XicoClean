import SwiftUI
import AppKit
import Domain
import Infrastructure
import DesignSystem
import SwiftTerm

/// 终端标签：真正的交互式终端（vim / htop / top 都能跑）。用 SwiftTerm 的 `LocalProcessTerminalView`
/// 直接托管本地 `/usr/bin/ssh -tt` 进程——原生 rsa-sha2、任意 `.pem` 私钥、任意现代密钥交换，
/// 且不再需要 macOS 15（旧实现依赖 Citadel `withPTY`）。打开终端会另起一条独立 SSH 会话——需授权（门禁）。
struct ServerTerminalTab: View {
    @ObservedObject var vm: ServersViewModel
    let host: ServerHost
    @ObservedObject var engine: ServerMonitorEngine
    @Binding var broadcast: Bool
    let gate: (() -> Void) -> Void
    @State private var opened = false

    var body: some View {
        if opened {
            InteractiveTerminalView(host: host, credential: vm.credential(for: host))
                .id(host.id)
                .background(Color.black.opacity(0.92))
        } else {
            terminalStart
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

struct InteractiveTerminalView: NSViewRepresentable {
    let host: ServerHost
    let credential: SSHCredential?

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> LocalProcessTerminalView {
        let tv = LocalProcessTerminalView(frame: CGRect(x: 0, y: 0, width: 800, height: 460))
        tv.processDelegate = context.coordinator
        context.coordinator.start(on: tv, host: host, credential: credential)
        return tv
    }

    func updateNSView(_ nsView: LocalProcessTerminalView, context: Context) {}

    static func dismantleNSView(_ nsView: LocalProcessTerminalView, coordinator: Coordinator) {
        coordinator.stop()
    }

    @MainActor
    final class Coordinator: NSObject, @preconcurrency LocalProcessTerminalViewDelegate {
        private var ctx: SSHContext?
        private var started = false

        func start(on tv: LocalProcessTerminalView, host: ServerHost, credential: SSHCredential?) {
            guard !started else { return }
            started = true
            guard let credential else {
                tv.feed(text: "\r\n\u{001b}[33m\(xLoc("缺少凭据：请先在主机设置中填写密码或私钥"))\u{001b}[0m\r\n")
                return
            }
            do {
                // 专用连接（终端独占，不走 ControlMaster 复用）。
                let context = try SSHContext(host: host, credential: credential, multiplexed: false)
                self.ctx = context
                let inv = context.terminalInvocation()
                tv.feed(text: "\u{001b}[2m\(xLocF("正在连接 %@…", host.endpointLabel))\u{001b}[0m\r\n")
                tv.startProcess(executable: inv.executable, args: inv.args, environment: inv.env)
            } catch {
                let msg = (error as? LocalizedError)?.errorDescription ?? "\(error)"
                tv.feed(text: "\r\n\u{001b}[31m[\(msg)]\u{001b}[0m\r\n")
            }
        }

        func stop() {
            ctx?.close()
            ctx = nil
        }

        // MARK: LocalProcessTerminalViewDelegate
        func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
        func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
        func processTerminated(source: TerminalView, exitCode: Int32?) {
            if let tv = source as? LocalProcessTerminalView {
                let code = exitCode ?? 0
                let note = code == 0 ? xLoc("连接已关闭") : xLocF("连接已关闭（退出码 %d）", Int(code))
                tv.feed(text: "\r\n\u{001b}[2m[\(note)]\u{001b}[0m\r\n")
            }
            stop()
        }
    }
}
