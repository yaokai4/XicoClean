# Xico — macOS 系统清理与磁盘管理工具

> 一款对标 CleanMyMac X 的高端 macOS 清理 / 优化 / 磁盘可视化工具。
> 原生 Swift + SwiftUI，深度系统集成，极致清爽的高级用户体验。

本仓库包含 **产品/工程设计文档** + 一个**真实可编译、可运行的原生 macOS App 实现**（Swift 6 + SwiftUI，SPM 分层工程）。

---

## 快速开始（运行 App）

```bash
# 1. 运行测试（24 个，含安全引擎红线测试）
swift test

# 2. 开发期直接运行
swift run Xico

# 3. 打包成标准 Xico.app（release，ad-hoc 签名）
scripts/make_app.sh release
open build/Xico.app
```

要求：macOS 13+、Xcode 26 / Swift 6.3 工具链。

### 已实现（M0–M6 主体）
- ✅ SPM 分层工程：`Domain / Infrastructure / DesignSystem / Features / Shared / XicoApp / XicoHelper`
- ✅ **安全引擎** `SafetyEngine`（保护清单 / 越界防护 / 废纸篓优先 / 可撤销）+ 17 项安全回归测试
- ✅ **清理引擎**：扫描 → 预览 → 清理（移废纸篓）→ 撤销 全闭环（端到端集成测试通过）
- ✅ **智能扫描** 仪表盘（磁盘环 + 内存/磁盘统计卡）+ 招牌扫描圆环动效 + 完成庆祝页
- ✅ **系统垃圾**（数据驱动定义库）、**大文件**、**废纸篓**
- ✅ **空间透镜**（treemap 可视化 + 逐层钻取）
- ✅ **重复文件**（大小分组 → 头尾哈希 → 去硬链接，智能保留一份）
- ✅ **卸载器**（应用本体 + 关联文件定位，一并移废纸篓）
- ✅ **隐私**（Safari/Chrome/Firefox/Edge/Arc 缓存清理）
- ✅ **优化**（运行中应用退出 + 启动项一览）
- ✅ **维护**（任务目录：释放内存/刷新DNS/重建索引/维护脚本/删快照，经特权助手）
- ✅ **特权助手** `XicoHelper`：XPC 协议 + 守护进程 + `SMAppService` 注册客户端（架构完整）
- ✅ 高端 UI：分层渐变背景、毛玻璃、语义化 Design Tokens、品牌侧边栏、深浅色双主题
- ✅ **菜单栏监控**、完全磁盘访问引导、`make_app.sh` 打包脚本

> 实测：本机扫出 **6.2 GB** 可清理系统垃圾；UI 已在深/浅色双主题下逐屏验证。

### 性能（实测，本机）
- 智能扫描 **0.9s**（系统垃圾+隐私聚合）· 卸载器列表 **0.1s**（两阶段加载）
- 大文件 **~8s**（并发遍历用户目录）· 空间透镜 Caches **0.9s**（顶层并发）
- 进度回调已节流，海量文件下 UI 不卡

### 签名与特权助手（已打通）
- `scripts/make_app.sh release` 会**嵌入并签名** `XicoHelper`（自动选用 Developer ID / Apple Development 身份），
  写入 `Contents/Library/LaunchDaemons/com.xico.app.helper.plist`，签名校验通过。
- 在「维护」页点「安装助手」即可经 `SMAppService` 注册；首次需在系统设置 › 登录项与扩展中批准。

### 待完成（对外分发相关）
- ⏳ 公证（Notarization，需 Developer ID + `notarytool`）
- ⏳ Sparkle 自动更新、商业化（FastSpring/Paddle）
- ⏳ Phase 2：恶意软件移除、相似图片查重、应用更新器

---

## 文档导航

| 文档 | 内容 |
|------|------|
| [01 · 产品定义与功能规划](docs/01-产品与功能.md) | 产品愿景、目标用户、完整功能清单、信息架构 |
| [02 · 技术选型与系统架构](docs/02-架构与技术选型.md) | 为什么用原生 Swift、分层架构、模块设计、权限模型、特权助手 |
| [03 · UI/UX 设计系统](docs/03-设计系统.md) | 设计语言、配色、排版、组件、动效、深浅色、可视化 |
| [04 · 核心技术实现要点](docs/04-技术实现要点.md) | 磁盘扫描性能、APFS、清理规则引擎、安全机制、卸载器、重复文件 |
| [05 · 开发路线图与里程碑](docs/05-路线图.md) | 分阶段交付计划、MVP、风险、合规与发布 |
| [CODEX 开发提示词](CODEX_PROMPT.md) | **可直接复制给 Codex 的全面开发提示词** |

---

## 一句话技术结论

> **用原生 Swift 6 + SwiftUI（辅以少量 AppKit 桥接），以 Developer ID 方式分发（非沙盒 / 非 App Store），通过 `SMAppService` 注册的特权助手 + XPC 完成需要 root 的清理操作。坚决不用 Electron / Tauri。**

理由、对比和细节见 [02 · 技术选型](docs/02-架构与技术选型.md)。

---

## 产品名

工作目录名为 `XicoApp`，本文档统一以 **Xico** 作为产品代号（可随时替换为正式品牌名）。
Bundle ID 建议：`com.<yourcompany>.xico`。
