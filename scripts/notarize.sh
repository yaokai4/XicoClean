#!/bin/bash
# 公证 + 打 DMG 的发布流程（对外分发）。
#
# 一次性准备（用你的 Apple 开发者账号）：
#   1) 在 https://developer.apple.com 安装「Developer ID Application」证书到钥匙串。
#   2) 生成 App 专用密码：https://account.apple.com → 登录与安全 → App 专用密码。
#   3) 存一次 notarytool 凭证（之后复用）：
#        xcrun notarytool store-credentials "XicoNotary" \
#          --apple-id "hi@yaokai.me" --team-id "AQ5TMWUPMH" --password "App专用密码"
#
# 之后每次发布只需：scripts/notarize.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
APP="$HOME/Applications/Xico.app"
PROFILE="${XICO_NOTARY_PROFILE:-XicoNotary}"
DIST="$ROOT/dist"

# 1. 必须有 Developer ID（公证只认这个，开发签名不行）
if ! security find-identity -v -p codesigning | grep -q "Developer ID Application"; then
  echo "✗ 未找到 Developer ID Application 证书。"
  echo "  请先在 developer.apple.com 申请并安装该证书后重试。"
  echo "  （本机目前只有 Apple Development 证书，仅供本机调试，无法对外公证。）"
  exit 1
fi

# 2. 构建并用 Developer ID 签名（make_app 会自动优先选用 Developer ID）
echo "▶︎ 构建并签名"
scripts/make_app.sh release >/dev/null
codesign -dvvv "$APP" 2>&1 | grep -q "Developer ID Application" \
  || { echo "✗ 签名身份不是 Developer ID，无法公证。"; exit 1; }
codesign --verify --strict --deep "$APP" && echo "✓ 代码签名校验通过"

# 3. 压缩后提交公证
mkdir -p "$DIST"
ZIP="$DIST/Xico.zip"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
echo "▶︎ 提交公证（notarytool，等待完成）"
xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait

# 4. 装订（staple），让离线也能验证
echo "▶︎ stapler staple"
xcrun stapler staple "$APP"
xcrun stapler validate "$APP" && echo "✓ 公证装订完成"
spctl -a -vv "$APP" 2>&1 | head -3 || true   # 应显示 accepted / Developer ID

# 5. 打 DMG（含已公证的 App）
DMG="$DIST/Xico.dmg"
rm -f "$DMG"
STAGE="$(mktemp -d)/Xico"
mkdir -p "$STAGE"
ditto "$APP" "$STAGE/Xico.app"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "Xico" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"
echo "✓ 发布完成: $DMG"
echo "  该 DMG 可直接分发；他人下载打开拖入「应用程序」即可，Gatekeeper 放行。"
