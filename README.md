# Xico — macOS 系统清理与磁盘管理工具

> 一款对标 CleanMyMac X 的高端 macOS 清理 / 优化 / 磁盘可视化工具。
> 原生 Swift + SwiftUI，深度系统集成，极致清爽的高级用户体验。

本仓库包含 **产品/工程设计文档** + 一个**真实可编译、可运行的原生 macOS App 实现**（Swift 6 + SwiftUI，SPM 分层工程）。

---

## 快速开始（运行 App）

```bash
# 1. 运行测试
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
- ✅ **重复文件**（大小分组 → 头尾哈希 → 全量哈希并发确认 → 去硬链接，智能保留一份）
- ✅ **相似图片**（Vision 感知指纹聚类，保留最佳一张；全本地、不上传）
- ✅ **卸载器**（应用本体 + 关联文件定位；空名防护 + 深度断言 + 二次确认）
- ✅ **应用更新**（读取带 Sparkle 源的应用，比对 appcast 列出可更新项）
- ✅ **隐私**（Safari/Chrome/Firefox/Edge/Arc/Brave 缓存清理）
- ✅ **优化**（运行中应用退出 + 启动项一览）
- ✅ **维护**（任务目录：释放内存/刷新DNS/重建索引/维护脚本/删快照，删快照带强确认，经特权助手）
- ✅ **威胁防护**：命中即连同磁盘载荷一并移除；特征库经签名通道下发（免发版更新）
- ✅ **特权助手** `XicoHelper`：XPC 连接级签名校验 + 版本握手自愈 + 30s 超时 + 空闲退出 + root 删除核心已抽出可测
- ✅ 高端 UI：分层渐变背景、毛玻璃、语义化 Design Tokens、品牌侧边栏、深浅色双主题
- ✅ **菜单栏监控**（CPU/内存/网络曲线 + 右键菜单）、完全磁盘访问引导、`make_app.sh` 打包脚本
- ✅ **信任基建**：忽略清单、Quick Look 预览、清理完成通知、每组「这是什么/为何可删」解释、持久化可追溯撤销

> 实测：本机扫出 **11+ GB** 可清理系统垃圾（含 Electron 系代码缓存）；UI 已在深/浅色双主题下逐屏验证。
> 详见 [docs/06-全面审计报告-2026-07.md](docs/06-全面审计报告-2026-07.md) 与本轮修复清单（Phase 0–3，全部单测通过）。

### 性能（实测，本机）
- 智能扫描 **0.9s**（系统垃圾+隐私聚合）· 卸载器列表 **0.1s**（两阶段加载）
- 大文件 **~8s**（并发遍历用户目录）· 空间透镜 Caches **0.9s**（顶层并发）
- 进度回调已节流，海量文件下 UI 不卡

### 签名与特权助手（已打通）
- `scripts/make_app.sh release` 会**嵌入并签名** `XicoHelper`（自动选用 Developer ID / Apple Development 身份），
  写入 `Contents/Library/LaunchDaemons/com.xico.app.helper.plist`，签名校验通过。
- 在「维护」页点「安装助手」即可经 `SMAppService` 注册；首次需在系统设置 › 登录项与扩展中批准。
- 发布构建可通过 `XICO_DEFINITIONS_URL`、`XICO_DEFINITIONS_PUBLIC_KEYS`、`XICO_LICENSE_PUBLIC_KEYS`
  将在线规则库与许可证信任配置写入 App 的 `Info.plist`。

### 待完成（对外分发相关）
- ⏳ 公证实机放行（`scripts/notarize.sh` 已具备并校验发布键、签名+公证 DMG；需 Developer ID + `notarytool` 凭证）
- ⏳ 支付履约后端（App 内购买按钮已就位，指向 `XicoPurchaseURL`；接 Paddle/Lemon Squeezy 托管结账 + 发码 webhook）
- ⏳ Sparkle 完整自更新（当前内置 appcast 检查器已可提示 + 跳转下载；升级到 Sparkle 可获静默增量更新，`notarize.sh` 已备 generate_appcast 钩子）
- ⏳ 国际化全量抽取（基建 + 侧栏英文已就绪，其余界面字符串逐步接入 `xLoc`）

### 规则库在线更新（已具备签名链路）

Xico 的清理规则库支持「内置离线规则 + 已签名缓存 + HTTPS 在线更新」三层模式。在线规则必须用 Ed25519 签名 envelope，App 只接受配置过可信公钥且版本号更高的规则库；签名失败、密钥不受信任或版本回退都会拒绝并保留当前规则。

```bash
# 生成发布用密钥对（私钥只放 CI/发布机密钥库，不提交仓库）
scripts/sign_definitions.swift --generate-keypair

# 用私钥签名规则库，产出可放到 HTTPS/CDN 的 definitions.signed.json
XICO_DEFINITIONS_PRIVATE_KEY="<private-base64>" \
  scripts/sign_definitions.swift \
  --input Sources/Domain/Resources/definitions.json \
  --output dist/definitions.signed.json \
  --key-id release-v1

# 本地/CI 自检签名工具
scripts/sign_definitions.swift --self-test
```

开发期可通过 `XICO_DEFINITIONS_URL` 与 `XICO_DEFINITIONS_PUBLIC_KEYS` 试跑在线更新；格式为 `key-id:public-key-base64`，多个 key 用逗号分隔。

### 商业授权与试用（已具备签名许可证链路）

Xico 内置 14 天试用期；试用结束或许可证无效时，清理/扫描会被功能门禁拦截，并引导用户到设置页导入许可证。许可证同样使用 Ed25519 签名 envelope，App 只接受配置过可信公钥、产品 ID 匹配且未过期的许可证。

```bash
# 生成许可证发布密钥对
scripts/sign_license.swift --generate-keypair

# 签发许可证
XICO_LICENSE_PRIVATE_KEY="<private-base64>" \
  scripts/sign_license.swift \
  --license-id customer-2026-001 \
  --customer "Customer Name" \
  --output dist/customer.xico-license \
  --key-id release-v1 \
  --expires-at 2027-12-31

# 本地/CI 自检签名工具
scripts/sign_license.swift --self-test
```

开发期可通过 `XICO_LICENSE_PUBLIC_KEYS` 或 UserDefaults `xico.license.publicKeys` 配置信任公钥；格式同样为 `key-id:public-key-base64`，多个 key 用逗号分隔。

### 发布预检

```bash
# 检查冲突副本、签名脚本、发布公钥、Developer ID、公证凭证，并跑完整质量门禁
XICO_DEFINITIONS_URL="https://example.com/definitions.signed.json" \
XICO_DEFINITIONS_PUBLIC_KEYS="release-v1:<definitions-public-base64>" \
XICO_LICENSE_PUBLIC_KEYS="release-v1:<license-public-base64>" \
scripts/release_preflight.sh

# 发布机预检通过后再公证打包
scripts/notarize.sh
```

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
