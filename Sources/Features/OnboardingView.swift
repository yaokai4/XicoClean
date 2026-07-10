import SwiftUI
import DesignSystem

// MARK: - Onboarding（P4·C1：付费产品的第一印象 = 4 步分页 + 活演示 + FDA 实时反馈）
//
// ① 欢迎（徽标 KeyframeAnimator 入场）→ ② 功能活演示（真组件缩影，stagger 入场）
// → ③ 完全磁盘访问（轮询真实权限探针，授权成功卡片变绿 + bounce；附「我们承诺不做什么」）
// → ④ 完成（直接给「开始首次扫描」——首扫 5 分钟内给出可行动成果是清理类产品的转化关键）。
// 曲线全走 XMotion；Reduce Motion 全降级；可随时跳过。

public struct OnboardingView: View {
    @ObservedObject var model: AppModel
    @State private var step = 0
    @State private var fdaPoll: Task<Void, Never>?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let stepCount = 4

    public init(model: AppModel) { self.model = model }

    public var body: some View {
        ZStack {
            AppBackground()
            GeometryReader { geo in
                ScrollView {
                    VStack(spacing: XSpacing.xl) {
                        Spacer(minLength: 0)
                        stepBody
                            .frame(maxWidth: 520)
                        Spacer(minLength: 0)
                        controls
                    }
                    .padding(XSpacing.xxxl)
                    .frame(maxWidth: .infinity, minHeight: geo.size.height)
                }
            }
        }
        .onAppear { if step == 2 { startFDAPolling() } }
        .onChange(of: step) {
            if step == 2 { startFDAPolling() } else { stopFDAPolling() }
        }
        .onDisappear { stopFDAPolling() }
    }

    // MARK: 步骤内容

    @ViewBuilder private var stepBody: some View {
        Group {
            switch step {
            case 0:  welcomeStep
            case 1:  demoStep
            case 2:  fdaStep
            default: readyStep
            }
        }
        .transition(reduceMotion ? .opacity : .asymmetric(
            insertion: .move(edge: .trailing).combined(with: .opacity),
            removal: .move(edge: .leading).combined(with: .opacity)))
        .id(step)
    }

    /// ① 欢迎：徽标多轨道入场（缩放 + 微旋 + 辉光呼吸），定位句。
    private var welcomeStep: some View {
        VStack(spacing: XSpacing.xl) {
            if reduceMotion {
                XBrandMark(size: 88).xGlow(XColor.brand, radius: 32)
            } else {
                KeyframeAnimator(initialValue: LogoPose(), trigger: step) { pose in
                    XBrandMark(size: 88)
                        .scaleEffect(pose.scale)
                        .rotationEffect(.degrees(pose.rotation))
                        .xGlow(XColor.brand, radius: pose.glow)
                } keyframes: { _ in
                    KeyframeTrack(\.scale) {
                        CubicKeyframe(0.6, duration: 0.01)
                        SpringKeyframe(1.10, duration: 0.45, spring: .bouncy)
                        SpringKeyframe(1.0, duration: 0.35, spring: .smooth)
                    }
                    KeyframeTrack(\.rotation) {
                        CubicKeyframe(-8, duration: 0.01)
                        SpringKeyframe(2, duration: 0.5, spring: .smooth)
                        SpringKeyframe(0, duration: 0.3, spring: .smooth)
                    }
                    KeyframeTrack(\.glow) {
                        CubicKeyframe(0, duration: 0.01)
                        LinearKeyframe(44, duration: 0.5)
                        LinearKeyframe(30, duration: 0.4)
                    }
                }
            }
            VStack(spacing: XSpacing.s) {
                Text(xLoc("欢迎使用 Xico")).xLargeTitle().foregroundStyle(XColor.textPrimary)
                Text(xLoc("诚实的精密仪表：清理、监控、硬件，一件工具做好三件事"))
                    .font(XFont.body).foregroundStyle(XColor.textSecondary)
                    .multilineTextAlignment(.center)
            }
        }
    }

    /// ② 功能活演示：三张卡各嵌一个真组件缩影（不是贴图），stagger 入场。
    private var demoStep: some View {
        VStack(spacing: XSpacing.m) {
            Text(xLoc("三件事，每件都做到位")).xTitle().foregroundStyle(XColor.textPrimary)
            demoCard(index: 0, title: xLoc("智能清理"), sub: xLoc("一键扫描系统垃圾、缓存与应用残留")) {
                XScanOrb(value: "4.8 GB", label: xLoc("正在扫描"), size: 92)
            }
            demoCard(index: 1, title: xLoc("空间透镜"), sub: xLoc("可视化磁盘占用，快速定位大文件")) {
                MiniSunburstDemo().frame(width: 92, height: 92)
            }
            demoCard(index: 2, title: xLoc("常驻监控"), sub: xLoc("菜单栏实时仪表：CPU / 内存 / 网络 / 温度")) {
                Image(nsImage: MenuBarGlyph.combined(slots: [
                    MenuCombinedSlot(viz: .histogram([0.3, 0.5, 0.4, 0.7, 0.6, 0.8, 0.5, 0.9, 0.7, 0.6, 0.8, 0.7, 0.62]),
                                     tint: XColor.metricCPU),
                    MenuCombinedSlot(viz: .pie(0.71), tint: XColor.metricMemory),
                    MenuCombinedSlot(viz: .net(down: "1.2M", up: "386K"), tint: XColor.metricNetwork),
                ]))
                .renderingMode(.template)
                .foregroundStyle(XColor.textPrimary)
            }
        }
    }

    @State private var demoAppeared = false

    private func demoCard<Demo: View>(index: Int, title: String, sub: String,
                                      @ViewBuilder demo: () -> Demo) -> some View {
        XCard {
            HStack(spacing: XSpacing.l) {
                demo()
                    .frame(minWidth: 100)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).xHeadline().foregroundStyle(XColor.textPrimary)
                    Text(sub).font(XFont.caption).foregroundStyle(XColor.textSecondary)
                }
                Spacer()
            }
        }
        .opacity(demoAppeared || reduceMotion ? 1 : 0)
        .offset(y: demoAppeared || reduceMotion ? 0 : 14)
        .animation(XMotion.settle.delay(Double(index) * 0.08), value: demoAppeared)
        .onAppear { demoAppeared = true }
    }

    /// ③ 完全磁盘访问：轮询真实探针（env.permissions.hasFullDiskAccess，Safari 书签/TCC 强阳性），
    /// 授权成功即变绿 + bounce。绝不用 AXIsProcessTrusted（那是辅助功能权限）。
    private var fdaStep: some View {
        VStack(spacing: XSpacing.l) {
            ZStack {
                Circle().fill((model.hasFullDiskAccess ? XColor.success : XColor.brand).opacity(XAlpha.tint))
                    .frame(width: 108, height: 108)
                Image(systemName: model.hasFullDiskAccess ? "checkmark.shield.fill" : "externaldrive.fill.badge.person.crop")
                    .font(.system(size: 46, weight: .light))
                    .foregroundStyle(model.hasFullDiskAccess
                                     ? AnyShapeStyle(XColor.successGradient)
                                     : AnyShapeStyle(XColor.brandGradient))
                    .symbolEffect(.bounce, value: model.hasFullDiskAccess)
            }
            .animation(XMotion.celebrate, value: model.hasFullDiskAccess)

            VStack(spacing: XSpacing.s) {
                Text(model.hasFullDiskAccess ? xLoc("已授权，可以扫描全部垃圾了") : xLoc("开启完全磁盘访问权限"))
                    .xTitle().foregroundStyle(XColor.textPrimary)
                Text(xLoc("扫描全部垃圾需要此权限，一次授权长期有效。"))
                    .font(XFont.body).foregroundStyle(XColor.textSecondary)
            }

            if !model.hasFullDiskAccess {
                Button(xLoc("去系统设置开启")) { model.openFullDiskAccessSettings() }
                    .buttonStyle(XPrimaryButtonStyle())
            }

            // 信任叙事：要什么权限，就说清楚不拿什么。
            XCard(padding: XSpacing.m) {
                VStack(alignment: .leading, spacing: XSpacing.s) {
                    Text(xLoc("我们承诺不做什么")).font(XFont.captionEmphasis).foregroundStyle(XColor.textSecondary)
                    promiseRow("icloud.slash", xLoc("你的文件与统计永远只在本机，绝不上传"))
                    promiseRow("trash.slash", xLoc("删除默认进废纸篓，可撤销；系统关键路径被红线保护"))
                    promiseRow("eye.slash", xLoc("不读取文件内容，只统计名称与大小"))
                }
            }
            .frame(maxWidth: 460)
        }
    }

    private func promiseRow(_ icon: String, _ text: String) -> some View {
        HStack(spacing: XSpacing.s) {
            Image(systemName: icon).font(XFont.caption).foregroundStyle(XColor.success).frame(width: 16)
            Text(text).font(XFont.caption).foregroundStyle(XColor.textSecondary)
            Spacer(minLength: 0)
        }
    }

    /// ④ 完成：直接把「首扫成果」端到面前。
    private var readyStep: some View {
        VStack(spacing: XSpacing.xl) {
            XBrandMark(size: 64).xGlow(XColor.brand, radius: 24)
            VStack(spacing: XSpacing.s) {
                Text(xLoc("一切就绪")).xLargeTitle().foregroundStyle(XColor.textPrimary)
                Text(xLoc("第一次扫描通常能找回好几 GB 空间——现在就试试。"))
                    .font(XFont.body).foregroundStyle(XColor.textSecondary)
            }
            Button(xLoc("开始首次扫描")) {
                model.completeOnboarding()
                model.selection = .smartScan
                if model.smartScanSession.phase == .idle { model.smartScanSession.start() }
            }
            .buttonStyle(XPrimaryButtonStyle(large: true))
            Button(xLoc("稍后再说")) { model.completeOnboarding() }
                .buttonStyle(.plain)
                .font(XFont.caption).foregroundStyle(XColor.textTertiary)
        }
    }

    // MARK: 导航（指示点 + 继续/跳过）

    private var controls: some View {
        VStack(spacing: XSpacing.l) {
            HStack(spacing: 6) {
                ForEach(0..<stepCount, id: \.self) { i in
                    Capsule()
                        .fill(i == step ? AnyShapeStyle(XColor.brandGradient) : AnyShapeStyle(XColor.idle.opacity(0.6)))
                        .frame(width: i == step ? 18 : 6, height: 6)
                }
            }
            .animation(XMotion.snappy, value: step)
            .accessibilityLabel(xLocF("第 %d 步，共 %d 步", step + 1, stepCount))

            if step < stepCount - 1 {
                HStack(spacing: XSpacing.m) {
                    Button(xLoc("跳过")) { model.completeOnboarding() }
                        .buttonStyle(.plain)
                        .font(XFont.body).foregroundStyle(XColor.textTertiary)
                    Button(step == 2 && !model.hasFullDiskAccess ? xLoc("先跳过这一步") : xLoc("继续")) {
                        advance()
                    }
                    .buttonStyle(XPrimaryButtonStyle())
                    .keyboardShortcut(.defaultAction)
                }
            }
        }
    }

    private func advance() {
        if reduceMotion {
            step = min(step + 1, stepCount - 1)
        } else {
            withAnimation(XMotion.settle) { step = min(step + 1, stepCount - 1) }
        }
    }

    // MARK: FDA 轮询（仅第 3 步期间；授权成功自动停）

    private func startFDAPolling() {
        stopFDAPolling()
        model.refreshPermissions()
        fdaPoll = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard !Task.isCancelled else { return }
                model.refreshPermissions()
                if model.hasFullDiskAccess { return }   // 变绿后停轮询（图标 bounce 由状态变化驱动）
            }
        }
    }

    private func stopFDAPolling() {
        fdaPoll?.cancel()
        fdaPoll = nil
    }
}

/// 徽标入场的多轨道姿态（KeyframeAnimator 值类型）。
private struct LogoPose {
    var scale: CGFloat = 0.6
    var rotation: Double = -8
    var glow: CGFloat = 0
}

/// 空间透镜缩影：三层同心弧的静态示意（真形状绘制，非贴图）。
private struct MiniSunburstDemo: View {
    var body: some View {
        Canvas { ctx, size in
            let c = CGPoint(x: size.width / 2, y: size.height / 2)
            let maxR = min(size.width, size.height) / 2
            // (环序, 起角, 扫角, 色阶, 透明度)
            let arcs: [(Int, Double, Double, Int, Double)] = [
                (0, -90, 150, 0, 0.95), (0, 62, 90, 1, 0.95), (0, 154, 116, 2, 0.95),
                (1, -90, 95, 0, 0.8), (1, 7, 52, 0, 0.7), (1, 62, 58, 1, 0.8), (1, 154, 70, 2, 0.8),
                (2, -90, 60, 0, 0.62), (2, 62, 34, 1, 0.62), (2, 154, 40, 2, 0.62),
            ]
            for (ringIdx, start, sweep, hue, alpha) in arcs {
                let inner = maxR * (0.32 + 0.22 * Double(ringIdx))
                let outer = inner + maxR * 0.20
                var p = Path()
                let a0 = Angle.degrees(start).radians
                let a1 = Angle.degrees(start + sweep - 4).radians
                p.addArc(center: c, radius: outer, startAngle: .radians(a0), endAngle: .radians(a1), clockwise: false)
                p.addArc(center: c, radius: inner, startAngle: .radians(a1), endAngle: .radians(a0), clockwise: true)
                p.closeSubpath()
                ctx.fill(p, with: .color(XColor.ring(hue).opacity(alpha)))
            }
        }
        .accessibilityHidden(true)
    }
}
