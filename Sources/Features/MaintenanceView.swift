import SwiftUI
import Infrastructure
import DesignSystem
import Shared

public struct MaintenanceView: View {
    private let env: XicoEnvironment
    @State private var userResults: [String: (Bool, String)] = [:]
    @State private var rootResults: [String: (Bool, String)] = [:]
    @State private var running: String?
    @State private var status: HelperProxy.Status = .notInstalled
    @State private var confirmTask: MaintenanceTask?
    @State private var installError: String?
    @State private var batchRunning = false
    @State private var maintDone: Int?     // 批量执行完成的任务数（触发计数庆祝）

    public init(env: XicoEnvironment) { self.env = env }

    public var body: some View {
        VStack(spacing: 0) {
            XHeaderBar(title: xLoc("维护"), subtitle: xLoc("让 Mac 保持顺畅"))
            if let n = maintDone {
                TaskCompletionView(
                    animateTo: Int64(n),
                    metricText: { xLocF("完成 %d 项维护", Int($0)) },
                    detail: xLoc("免管理员维护任务已全部执行。"),
                    doneTitle: xLoc("完成"),
                    onDone: { maintDone = nil })
            } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: XSpacing.m) {
                    HStack {
                        sectionLabel(xLoc("立即可用 · 无需管理员"))
                        Spacer()
                        if batchRunning { XSpinner() }
                        else {
                            Button(xLoc("全部执行")) { runAllUser() }
                                .buttonStyle(XSecondaryButtonStyle(compact: true))
                        }
                    }
                    ForEach(UserMaintenanceTask.allCases) { task in userCard(task) }

                    sectionLabel(xLoc("需要管理员权限"))
                    if status != .installed { helperBanner }
                    ForEach(MaintenanceTask.allCases, id: \.self) { task in rootCard(task) }
                }
                .padding(XSpacing.xl)
            }
            }
        }
        .onAppear { status = env.helper.status() }
        .confirmationDialog(confirmTask?.title ?? "", isPresented: confirmBinding, titleVisibility: .visible) {
            if let task = confirmTask {
                Button(xLoc("确认执行"), role: .destructive) { performRoot(task) }
                Button(xLoc("取消"), role: .cancel) {}
            }
        } message: {
            if let task = confirmTask, let msg = task.confirmationMessage { Text(msg) }
        }
        .alert(xLoc("安装助手失败"), isPresented: Binding(get: { installError != nil }, set: { if !$0 { installError = nil } })) {
            Button(xLoc("好"), role: .cancel) {}
        } message: {
            Text(installError ?? "")
        }
    }

    private var confirmBinding: Binding<Bool> {
        Binding(get: { confirmTask != nil }, set: { if !$0 { confirmTask = nil } })
    }

    private func sectionLabel(_ t: String) -> some View {
        Text(t).xSectionLabel().foregroundStyle(XColor.textTertiary)
            .padding(.top, XSpacing.s)
    }

    private var helperBanner: some View {
        HStack(spacing: XSpacing.m) {
            Image(systemName: "lock.shield.fill").foregroundStyle(XColor.warning)
            Text(bannerText).font(XFont.caption).foregroundStyle(XColor.textSecondary)
            Spacer()
            if status == .requiresApproval {
                Button(xLoc("去系统设置批准")) { env.helper.openLoginItemsSettings() }.buttonStyle(XPrimaryButtonStyle(compact: true))
            } else {
                Button(xLoc("安装助手")) { installHelper() }.buttonStyle(XPrimaryButtonStyle(compact: true))
            }
        }
        .padding(XSpacing.m)
        .background(XColor.warning.opacity(0.12), in: RoundedRectangle(cornerRadius: XRadius.tile))
    }

    private func installHelper() {
        do {
            try env.helper.install()
            status = env.helper.status()
            if status == .requiresApproval { env.helper.openLoginItemsSettings() }
        } catch {
            // 不再静默吞掉：把失败原因显示给用户（此前 try? 让"装不上"毫无反馈）
            installError = xLocF("安装助手失败：%@", error.localizedDescription)
        }
    }

    private var bannerText: String {
        switch status {
        case .requiresApproval: return xLoc("助手已注册，请在「登录项与扩展」中打开开关即可执行以下任务。")
        case .unavailable: return xLoc("当前为开发签名版本，正式签名后可安装一次性助手执行以下任务。")
        default: return xLoc("以下任务需 root 权限，安装一次性后台助手即可执行。")
        }
    }

    // MARK: 用户级任务（真实执行）

    private func userCard(_ task: UserMaintenanceTask) -> some View {
        XCard {
            VStack(alignment: .leading, spacing: XSpacing.s) {
                HStack(spacing: XSpacing.m) {
                    XIconTile(systemImage: task.systemImage, colors: XColor.brandGradientColors, size: 34)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(xLoc(task.title)).xHeadline().foregroundStyle(XColor.textPrimary)
                        Text(xLoc(task.detail)).font(XFont.caption).foregroundStyle(XColor.textSecondary).lineLimit(2)
                    }
                    Spacer()
                    if running == "u-" + task.rawValue {
                        XSpinner()
                    } else {
                        Button(xLoc("执行")) { runUser(task) }.buttonStyle(XSecondaryButtonStyle(compact: true))
                    }
                }
                resultLine(userResults[task.rawValue])
            }
        }
    }

    private func rootCard(_ task: MaintenanceTask) -> some View {
        XCard {
            VStack(alignment: .leading, spacing: XSpacing.s) {
                HStack(spacing: XSpacing.m) {
                    XIconTile(systemImage: task.systemImage, colors: [XColor.warning, XColor.accentPink], size: 34)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(xLoc(task.title)).xHeadline().foregroundStyle(XColor.textPrimary)
                        Text(xLoc(task.detail)).font(XFont.caption).foregroundStyle(XColor.textSecondary).lineLimit(2)
                    }
                    Spacer()
                    if running == "r-" + task.rawValue {
                        XSpinner()
                    } else {
                        Button(xLoc("执行")) { runRoot(task) }.buttonStyle(XSecondaryButtonStyle(compact: true))
                            .disabled(status != .installed)
                    }
                }
                resultLine(rootResults[task.rawValue])
            }
        }
    }

    @ViewBuilder private func resultLine(_ r: (Bool, String)?) -> some View {
        if let (ok, msg) = r {
            HStack(spacing: XSpacing.xs) {
                Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(ok ? XColor.success : XColor.warning)
                Text(msg).font(XFont.caption).foregroundStyle(XColor.textSecondary).lineLimit(2)
            }
        }
    }

    private func runUser(_ task: UserMaintenanceTask) {
        running = "u-" + task.rawValue
        Task {
            let (ok, msg) = await env.maintenanceRunner.run(task)
            userResults[task.rawValue] = (ok, msg)
            running = nil
        }
    }

    /// 批量执行全部「免管理员」维护任务，逐项写回结果，完成后计数庆祝。
    private func runAllUser() {
        guard !batchRunning else { return }
        batchRunning = true
        Task {
            var done = 0
            for task in UserMaintenanceTask.allCases {
                let (ok, msg) = await env.maintenanceRunner.run(task)
                userResults[task.rawValue] = (ok, msg)
                done += 1
            }
            batchRunning = false
            maintDone = done
        }
    }

    private func runRoot(_ task: MaintenanceTask) {
        if task.needsConfirmation {
            confirmTask = task
        } else {
            performRoot(task)
        }
    }

    private func performRoot(_ task: MaintenanceTask) {
        confirmTask = nil
        running = "r-" + task.rawValue
        Task {
            let (ok, out) = await env.helper.runMaintenance(task)
            rootResults[task.rawValue] = (ok, ok ? xLoc("完成") : (out ?? xLoc("执行失败")))
            running = nil
        }
    }
}
