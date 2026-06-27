import SwiftUI
import Domain
import Infrastructure

public extension Notification.Name {
    /// 清理完成后广播，便于各处刷新磁盘占用
    static let xicoDidClean = Notification.Name("xicoDidClean")
}

/// 外观偏好：跟随系统 / 浅色 / 深色
public enum AppAppearance: String, CaseIterable, Identifiable, Sendable {
    case system, light, dark
    public var id: String { rawValue }
    public var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
    public var icon: String {
        switch self {
        case .system: return "circle.lefthalf.filled"
        case .light: return "sun.max.fill"
        case .dark: return "moon.fill"
        }
    }
}

/// 应用级状态：环境、当前选中模块、权限、实时指标。
@MainActor
public final class AppModel: ObservableObject {
    /// 共享实例：主窗口与菜单栏控制器（AppKit）共用同一份状态
    public static let shared = AppModel()

    public let env: XicoEnvironment

    @Published public var selection: ModuleID? = .smartScan
    @Published public var hasFullDiskAccess: Bool = false
    @Published public var permissionBannerDismissed: Bool = false {
        didSet { UserDefaults.standard.set(permissionBannerDismissed, forKey: "xico.fdaDismissed") }
    }
    @Published public var liveSnapshot: SystemSnapshot?
    @Published public var capacity: VolumeCapacity?
    @Published public var macInfo: MacInfo?

    // 滚动历史（用于菜单栏折线图）
    @Published public var cpuHistory: [Double] = []
    @Published public var memHistory: [Double] = []
    @Published public var netDownHistory: [Double] = []
    @Published public var netUpHistory: [Double] = []
    private let historyCap = 60
    @Published public var appearance: AppAppearance = .system {
        didSet { UserDefaults.standard.set(appearance.rawValue, forKey: "xico.appearance") }
    }
    @Published public var showOnboarding: Bool = false

    private var timer: Timer?

    public init(env: XicoEnvironment = .live()) {
        self.env = env
        if let raw = UserDefaults.standard.string(forKey: "xico.appearance"),
           let a = AppAppearance(rawValue: raw) {
            appearance = a
        }
        permissionBannerDismissed = UserDefaults.standard.bool(forKey: "xico.fdaDismissed")
        showOnboarding = !UserDefaults.standard.bool(forKey: "xico.onboarded")
        if CommandLine.arguments.contains("--onboarding") { showOnboarding = true }
        if CommandLine.arguments.contains(where: { $0.hasPrefix("--open=") }) { showOnboarding = false }
        if let arg = CommandLine.arguments.first(where: { $0.hasPrefix("--open=") }) {
            selection = ModuleID(String(arg.dropFirst("--open=".count)))
        }
        if let arg = CommandLine.arguments.first(where: { $0.hasPrefix("--appearance=") }),
           let a = AppAppearance(rawValue: String(arg.dropFirst("--appearance=".count))) {
            appearance = a
        }
        refreshPermissions()
        refreshMetrics()
        NotificationCenter.default.addObserver(forName: .xicoDidClean, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refreshMetrics() }
        }
    }

    public func refreshPermissions() {
        hasFullDiskAccess = env.permissions.hasFullDiskAccess()
    }

    public func refreshMetrics() {
        let s = env.liveMetrics.sample()
        liveSnapshot = s
        capacity = env.fs.volumeCapacity(for: FileManager.default.homeDirectoryForCurrentUser)
        if macInfo == nil { macInfo = env.liveMetrics.macInfo() }
        push(&cpuHistory, s.cpuUsage)
        push(&memHistory, s.memoryUsedFraction)
        push(&netDownHistory, s.netDownBytesPerSec)
        push(&netUpHistory, s.netUpBytesPerSec)
    }

    private func push(_ arr: inout [Double], _ v: Double) {
        arr.append(v)
        if arr.count > historyCap { arr.removeFirst(arr.count - historyCap) }
    }

    public func startMetricsTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshMetrics() }
        }
    }

    public func openFullDiskAccessSettings() {
        env.permissions.openFullDiskAccessSettings()
    }

    public func completeOnboarding() {
        UserDefaults.standard.set(true, forKey: "xico.onboarded")
        withAnimation(.spring(response: 0.45, dampingFraction: 0.85)) { showOnboarding = false }
        refreshPermissions()
    }

    var showPermissionBanner: Bool { !hasFullDiskAccess && !permissionBannerDismissed }
}
