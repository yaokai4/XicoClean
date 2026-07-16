# 把 Xico 下载助手转成 Safari 扩展

Chrome 版（`../chrome/`）是标准的 Manifest V3 扩展。Apple 提供官方工具，可以把它
一键转换成 **Safari Web Extension**（一个包住扩展的 Xcode 工程）。

## 一、转换

在仓库根目录执行（需要已安装 Xcode 命令行工具）：

```bash
xcrun safari-web-extension-converter XicoBrowserExtension/chrome \
  --project-location XicoBrowserExtension/safari/XicoSafari \
  --app-name "Xico 下载助手" \
  --bundle-identifier com.xico.mac.downloader-helper \
  --macos-only
```

参数说明：
- `--project-location`：生成的 Xcode 工程放这里。
- `--app-name` / `--bundle-identifier`：容器 App 的名字与 Bundle ID（建议与 Xico 主 App
  同一开发者前缀 `com.xico.mac`，便于统一签名/公证）。
- `--macos-only`：Xico 是 macOS 应用，只做 macOS 扩展即可（去掉则同时生成 iOS 目标）。

转换完成后：

```bash
open XicoBrowserExtension/safari/XicoSafari/*.xcodeproj
```

在 Xcode 里选中容器 App 目标 → **Signing & Capabilities** → 选你的开发者团队自动签名，
然后 **Run（⌘R）**。首次运行会打开容器 App，按提示到 **Safari → 设置 → 扩展** 里勾选
“Xico 下载助手”。开发调试期间还需在 Safari **开发** 菜单里打开
“允许未签名的扩展”（每次重启 Safari 需重开）。

## 二、Safari 的关键差异与注意事项

1. **必须签名 / 走 Xcode。**
   Safari 不支持像 Chrome 那样直接“加载已解压的扩展文件夹”。它必须被打包进一个容器 App，
   由 Xcode 构建并用开发者证书签名。要上架还需公证 + 提交 Mac App Store（或以 Developer ID
   分发容器 App）。

2. **`webRequest` 受限。**
   Safari 对 `webRequest` 的支持比 Chrome 弱：**观察式**的 `chrome.webRequest.onBeforeRequest`
   在较新 Safari 上可用于**读取**请求（我们只做观察、不阻断，正好落在被支持的范围内），
   但阻断式 `blocking` 用法不被支持，且不同 Safari 版本能力有差异。因此在 Safari 上，
   本扩展的**主力应放在 `content.js` 的 `<video>`/`<source>` 直链嗅探 + 页面地址交接**，
   把网络层捕获视为“能用则加分、不能用也不致命”的增强。
   - 好消息：本扩展的 popup 已经是“网络捕获 + DOM 重扫”合并的架构。即便 Safari 完全拿不到
     网络捕获，DOM 嗅探 + “下载此页面”兜底仍可工作。

3. **X / Twitter 视频在 Safari 上的策略。**
   若该 Safari 版本能观察到 `video.twimg.com` 的 `.mp4/.m3u8` 请求，行为与 Chrome 一致；
   若不能，则依赖页面里 `<video currentSrc>`（X 播放时通常会有 blob:/MSE，直链可能拿不到）——
   这种情况下回退到把**推文页面地址**交给 Xico，由其内置解析器尝试。

4. **深链交接一致。**
   打开 `xico://download?url=...&kind=video` 的方式在 Safari 里同样有效。转换后 `popup.js` 里
   `chrome.tabs.create({url: deepLink, active:false})` 走 `browser.*` 兼容层无需改动
   （转换器会注入 `browser`↔`chrome` 兼容 shim）。

5. **权限提示。**
   Safari 会把 `<all_urls>` 呈现为“在所有网站上读取内容”的授权，用户需在扩展设置里
   显式允许。首启后引导用户到 Safari 设置勾选并授予网站权限。

## 三、维护建议

- 逻辑改动只在 `../chrome/` 里做，Safari 侧每次重新跑一遍 `safari-web-extension-converter`
  覆盖生成（或用 `--rebuild-project`）。不要在生成的 Xcode 工程里手改 JS，避免两份代码漂移。
- 图标沿用 `../chrome/icons/` 的 PNG，转换器会自动带过去。
