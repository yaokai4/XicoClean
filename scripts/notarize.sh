#!/bin/bash
# 公证 + 打 DMG 的发布流程（对外分发）。
#
# 一次性准备（用你的 Apple 开发者账号）：
#   1) 在 https://developer.apple.com 安装「Developer ID Application」证书到钥匙串。
#   2) 生成 App 专用密码：https://account.apple.com → 登录与安全 → App 专用密码。
#   3) 存一次 notarytool 凭证（之后复用）：
#        xcrun notarytool store-credentials "XicoNotary" \
#          --apple-id "hi@yaokai.me" --team-id "P22K8NF89K" --password "App专用密码"
#
# 重要：--team-id 必须是拥有 Developer ID 证书的团队 ID = P22K8NF89K（个人账号只有这一个团队）。
#       核对方法（证书 OU 字段才是权威 Team ID）：
#         security find-certificate -c "Developer ID Application" -p | openssl x509 -noout -subject  → OU=P22K8NF89K
#       ⚠︎ 曾误填 AQ5TMWUPMH——那只是 Apple Development 调试证书 CN 括号里的“个人标识符”，不是 Team ID，
#          会让公证返回 statusCode 7000 "Team is not yet configured for notarization"（并非 Apple 账号被限制）。
#       ⚠︎ --password 用「App 专用密码」(格式 xxxx-xxxx-xxxx-xxxx)，不是 App Store Connect 那个 32 位十六进制的
#          「App 专用共享密钥」(后者是内购收据校验用的，公证用不上)。
#       运行期特权助手 XPC 校验用的 teamIdentifier 见 Sources/Shared/HelperSecurity.swift，同样是 P22K8NF89K。
#
# 之后每次发布只需：scripts/notarize.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
APP="$HOME/Applications/Xico.app"
PROFILE="${XICO_NOTARY_PROFILE:-XicoNotary}"
DIST="$ROOT/dist"

# 1. 必须有 Developer ID（公证只认这个，开发签名不行）。先完整捕获输出，避免
# pipefail + grep -q 提前退出令上游收到 SIGPIPE，从而把有效证书误判为缺失。
SIGNING_IDENTITIES="$(security find-identity -v -p codesigning)"
if ! grep -q "Developer ID Application" <<<"$SIGNING_IDENTITIES"; then
  echo "✗ 未找到 Developer ID Application 证书。"
  echo "  请先在 developer.apple.com 申请并安装该证书后重试。"
  echo "  （本机目前只有 Apple Development 证书，仅供本机调试，无法对外公证。）"
  exit 1
fi

# 2. 构建并用 Developer ID 签名（make_app 会自动优先选用 Developer ID）
echo "▶︎ 构建并签名"
scripts/make_app.sh release >/dev/null
APP_SIGNATURE="$(codesign -dvvv "$APP" 2>&1)"
grep -q "Authority=Developer ID Application:" <<<"$APP_SIGNATURE" \
  || { echo "✗ 签名身份不是 Developer ID，无法公证。"; exit 1; }
codesign --verify --strict --deep "$APP" && echo "✓ 代码签名校验通过"

# 2.5 校验发布关键 Info.plist 键非空——否则会产出「拒收一切正版许可证 / 无法在线更新」的坏包。
echo "▶︎ 校验发布 Info.plist 键"
PLIST="$APP/Contents/Info.plist"
for key in XicoLicensePublicKeys XicoDefinitionsURL XicoDefinitionsPublicKeys XicoComponentsURL XicoComponentsPublicKeys XicoUpdatePublicKeys SUFeedURL; do
  val="$(plutil -extract "$key" raw -o - "$PLIST" 2>/dev/null || true)"
  if [ -z "$val" ]; then
    echo "✗ Info.plist 缺少或为空: $key"
    echo "  发布前必须设置对应环境变量（见 scripts/release_preflight.sh）后重跑。"
    exit 1
  fi
done
echo "✓ 发布 Info.plist 键齐备"

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

# 5.5 签名并公证 DMG 本身（此前 DMG 未签未公证，安装体验差一档）
DMG_IDENTITY="$(awk '/Developer ID Application/ && !found { print $2; found = 1 }' <<<"$SIGNING_IDENTITIES")"
codesign --force --timestamp --sign "$DMG_IDENTITY" "$DMG" && echo "✓ DMG 已签名"
echo "▶︎ 公证 DMG"
xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$DMG" && echo "✓ DMG 公证装订完成"

# 6. 生成 / 更新 appcast（Sparkle 兼容；有 Sparkle 工具链时自动，否则给出手工提示）
if command -v generate_appcast >/dev/null 2>&1; then
  echo "▶︎ generate_appcast $DIST"
  generate_appcast "$DIST" && echo "✓ 已更新 $DIST/appcast.xml（上传到 SUFeedURL 对应位置）"
else
  echo "ℹ︎ 未安装 Sparkle 的 generate_appcast；如需自动更新，请生成 appcast.xml 并发布到 SUFeedURL。"
fi

echo "✓ 发布完成: $DMG"
echo "  该 DMG 可直接分发；他人下载打开拖入「应用程序」即可，Gatekeeper 放行。"
