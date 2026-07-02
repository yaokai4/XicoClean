// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Xico",
    defaultLocalization: "zh-Hans",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "Xico", targets: ["XicoApp"]),
        .executable(name: "XicoHelper", targets: ["XicoHelper"])
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
            name: "Shared"
        ),
        // C 互操作垫片：通过 IOHIDEventSystemClient 私有 API 读取 Apple Silicon 温度传感器
        // （只读、无副作用；不可用时静默返回 0，供 Swift 侧降级）
        .target(
            name: "CSensors",
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("CoreFoundation")
            ]
        ),
        // 与系统交互的具体实现：文件系统、权限、扫描模块、指标采样
        .target(
            name: "Infrastructure",
            dependencies: ["Domain", "Shared", "CSensors"]
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
        // 功能模块：各页面的 View + ViewModel
        .target(
            name: "Features",
            dependencies: ["Domain", "Infrastructure", "DesignSystem", "Shared"]
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
