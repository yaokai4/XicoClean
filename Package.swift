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
        // —— 服务器套件（反超 ServerCat）。
        // SSH 传输改走系统 `/usr/bin/ssh` · `/usr/bin/sftp`（见 Infrastructure/SystemSSH.swift）：
        // 原生支持 rsa-sha2、任意 `.pem`（PKCS#1 / PKCS#8 / OpenSSH / 加密 / PuTTY）与现代密钥交换。
        // 由此彻底移除 Citadel（其 RSA 只签 SHA-1、被现代 OpenSSH 拒绝，是 .pem 连接失败的根因）
        // 及其传递依赖（swift-nio-ssh / SwiftNIO / BigInt / swift-crypto）——本包除 SwiftTerm 外回到零 SSH 依赖，
        // 供应链、签名与公证更干净。加解密仍用系统 CryptoKit（无需外部包）。
        // SwiftTerm：交互式终端仿真器（MIT）。用其 `LocalProcessTerminalView` 直接托管本地 `ssh -tt` 进程，
        // 不再依赖 Citadel 的 withPTY，因而真正的交互式终端在 macOS 14 上也可用。
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
                "Domain", "Shared", "CSensors", "DesignSystem"
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
