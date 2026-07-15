// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Xico",
    defaultLocalization: "zh-Hans",
    platforms: [
        // v14 起步：@Observable 主题架构、KeyframeAnimator/PhaseAnimator、symbolEffect 均需 macOS 14+。
        // （2026 年商业产品的合理支持窗口：当前系统 26，向下支持 3 个大版本。）
        .macOS(.v14)
    ],
    products: [
        .executable(name: "Xico", targets: ["XicoApp"]),
        .executable(name: "XicoHelper", targets: ["XicoHelper"])
    ],
    dependencies: [
        // —— 服务器套件（反超 ServerCat）首次引入的外部依赖。此前本包零外部依赖。
        // Citadel：纯 Swift SSH 客户端（基于 Apple swift-nio-ssh 的维护者 Joannis 分支），
        // 提供 exec/PTY/SFTP/端口转发/跳板；无 C 依赖 → 沙盒 + Hardened Runtime + 公证干净。
        // 精确锁 0.12.0：0.12.1 起把传递依赖 swift-nio-ssh 从维护者本人的 Joannis/ 分支
        // 切到第三方 Wellz26/ 分支——为供应链可信，钉在 0.12.0（用 Joannis/swift-nio-ssh 0.3.5）。
        .package(url: "https://github.com/orlandos-nl/Citadel.git", exact: "0.12.0"),
        // NIOSSH（Citadel 用的同一分支）：直接依赖以便构造 PTY 请求（SSHChannelRequestEvent.PseudoTerminalRequest
        // / SSHTerminalModes）——Citadel 未 re-export 这些类型。与 Citadel 0.12.0 的约束一致，SPM 去重到同一版本。
        .package(url: "https://github.com/Joannis/swift-nio-ssh.git", "0.3.4" ..< "0.4.0"),
        // SwiftTerm：交互式 PTY 终端仿真器（MIT）。输入走 Sendable AsyncStream、非 Sendable 的
        // TTYStdinWriter/TTYOutput 用 @unchecked Sendable box 桥接，绕开严格并发限制；withPTY 需 macOS 15+。
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", from: "1.14.0")
    ],
    targets: [
        // 纯业务核心：模型、协议、安全引擎、清理/扫描编排（零 UI/系统具体依赖）
        // 依赖 Shared 以复用唯一事实来源的删除红线（XicoSafetyRules）
        .target(
            name: "Domain",
            dependencies: ["Shared"],
            resources: [.process("Resources")]
        ),
        // 主应用与特权助手共享的 XPC 协议与常量
        .target(
            name: "Shared",
            dependencies: ["CProcessBatch"]
        ),
        .target(name: "CProcessBatch"),
        // C 互操作垫片：通过 IOHIDEventSystemClient 私有 API 读取 Apple Silicon 温度传感器
        // （只读、无副作用；不可用时静默返回 0，供 Swift 侧降级）
        .target(
            name: "CSensors",
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("CoreFoundation")
            ]
        ),
        // 与系统交互的具体实现：文件系统、权限、扫描模块、指标采样、远程 SSH（Citadel）
        .target(
            name: "Infrastructure",
            dependencies: [
                "Domain", "Shared", "CSensors", "DesignSystem",
                .product(name: "Citadel", package: "Citadel"),
                .product(name: "NIOSSH", package: "swift-nio-ssh")
            ]
        ),
        // 特权助手守护进程（root；需正式签名 + SMAppService 注册）
        .executableTarget(
            name: "XicoHelper",
            dependencies: ["Shared"]
        ),
        // 设计系统：Design Tokens、配色、字体、可复用组件、动效
        .target(
            name: "DesignSystem",
            resources: [.process("Resources")]
        ),
        // 功能模块：各页面的 View + ViewModel（终端页用 SwiftTerm）
        .target(
            name: "Features",
            dependencies: [
                "Domain", "Infrastructure", "DesignSystem", "Shared",
                .product(name: "SwiftTerm", package: "SwiftTerm")
            ]
        ),
        // 应用入口：@main、窗口、菜单栏
        .executableTarget(
            name: "XicoApp",
            dependencies: ["Features", "Domain", "Infrastructure", "DesignSystem"]
        ),
        // 测试
        .testTarget(
            name: "DomainTests",
            dependencies: ["Domain", "Shared"]
        ),
        .testTarget(
            name: "IntegrationTests",
            dependencies: ["Domain", "Infrastructure"]
        ),
        .testTarget(
            name: "FeatureTests",
            dependencies: ["Features", "Domain", "DesignSystem"]
        )
    ],
    swiftLanguageModes: [.v6]
)
