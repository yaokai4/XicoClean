#!/bin/bash
# 打包 Xico.app：嵌入并签名特权助手（XicoHelper），使其可经 SMAppService 注册。
# 在临时目录组装+签名（避开 iCloud 同步反复加的扩展属性），再 ditto 回 build/。
# 用法: scripts/make_app.sh [debug|release]
set -euo pipefail

CONFIG="${1:-release}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

# 构建配置（许可公钥 / 各类 URL 等）持久化在 gitignore 的 scripts/build.env，
# 避免「忘记 export XICO_LICENSE_PUBLIC_KEYS」而打出「无法验签任何许可」的坏包——
# 这正是 0.3.0 b83「输入官网激活码显示无效」的根因（Info.plist 里根本没有公钥）。
# 已在环境里显式导出的同名变量优先级更高（build.env 只补空缺，不覆盖）。
if [ -f "$ROOT/scripts/build.env" ]; then
  # shellcheck disable=SC1090,SC1091
  while IFS= read -r _line || [ -n "$_line" ]; do
    case "$_line" in ''|\#*) continue ;; esac
    _k="${_line%%=*}"
    if [ -z "$(eval "printf '%s' \"\${$_k:-}\"")" ]; then export "$_line"; fi
  done < "$ROOT/scripts/build.env"
  echo "▶︎ 已加载 scripts/build.env（仅补齐未导出的变量）"
fi

# iCloud 同步产生的冲突副本（"* 2.swift" 等）会导致重复声明编译失败。
# 发布脚本只检测并失败，不自动删除源码；需要时显式运行 scripts/clean_conflicts.sh。
if find Sources Tests \( -name "* [0-9].swift" -o -name "* [0-9].json" \) -print -quit | grep -q .; then
  echo "✗ 发现疑似 iCloud 冲突副本。请先检查并运行 scripts/clean_conflicts.sh。"
  exit 1
fi

APP_BUNDLE_ID="com.xico.app"
HELPER_LABEL="com.xico.app.helper"

verify_helper_identifier() {
  local helper_path="$1"
  local actual_identifier
  actual_identifier="$(codesign -dv "$helper_path" 2>&1 | sed -n 's/^Identifier=//p' | head -1)"
  if [ "$actual_identifier" != "$HELPER_LABEL" ]; then
    echo "✗ 助手签名标识错误：期望 $HELPER_LABEL，实际 ${actual_identifier:-未读取到}"
    exit 1
  fi
  echo "✓ 助手签名标识: $actual_identifier"
}

# 版本单一事实源：优先 git tag（形如 v1.2.0 → 1.2.0），回落到 0.2.0；
# build 号取提交计数，保证单调递增。可用环境变量 XICO_VERSION 覆盖。
VERSION="${XICO_VERSION:-$(git describe --tags --abbrev=0 2>/dev/null | sed 's/^v//' || true)}"
[ -z "$VERSION" ] && VERSION="0.2.0"
BUILD="${XICO_BUILD:-$(git rev-list --count HEAD 2>/dev/null || echo 1)}"
echo "▶︎ 版本 $VERSION (build $BUILD)"

xml_escape() {
  printf '%s' "$1" \
    | sed -e 's/&/\&amp;/g' \
          -e 's/</\&lt;/g' \
          -e 's/>/\&gt;/g' \
          -e 's/"/\&quot;/g' \
          -e "s/'/\&apos;/g"
}

append_info_string() {
  local key="$1"
  local value="$2"
  if [ -n "$value" ]; then
    printf '    <key>%s</key><string>%s</string>\n' "$key" "$(xml_escape "$value")"
  fi
}

# 许可公钥自检（fail-fast，在昂贵的通用构建之前）：没有它，App 无法离线验签官网签发的
# 许可信封，任何激活码都会显示「无效」。因此 release 构建必须带上；确需打不含验签的调试包时
# 显式设 XICO_ALLOW_UNVERIFIED_LICENSE=1。值格式：keyID:base64公钥（keyID 须与官网
# XICO_LICENSE_KEY_ID 一致，公钥须由官网 XICO_LICENSE_PRIVATE_KEY 派生——见 scripts/print_license_pubkey.mjs）。
LICKEYS="${XICO_LICENSE_PUBLIC_KEYS:-}"
if [ -z "$LICKEYS" ]; then
  if [ "$CONFIG" = "release" ] && [ "${XICO_ALLOW_UNVERIFIED_LICENSE:-0}" != "1" ]; then
    echo "✗ 未设置 XICO_LICENSE_PUBLIC_KEYS——打出的包无法验签任何许可，激活必然显示「无效」。"
    echo "  修复：在 scripts/build.env 写入 XICO_LICENSE_PUBLIC_KEYS=<keyID>:<base64公钥>"
    echo "       （用 scripts/print_license_pubkey.mjs 从官网私钥派生；必须与生产环境同一对密钥）。"
    echo "  确需打无验签调试包：XICO_ALLOW_UNVERIFIED_LICENSE=1 scripts/make_app.sh $CONFIG"
    exit 1
  fi
  echo "⚠︎ XICO_LICENSE_PUBLIC_KEYS 为空：本包无法验签许可，激活会失败（仅供无授权调试）。"
elif ! printf '%s' "$LICKEYS" | grep -q ':'; then
  echo "✗ XICO_LICENSE_PUBLIC_KEYS 格式应为 keyID:base64公钥（缺少冒号）：$LICKEYS"
  exit 1
else
  echo "▶︎ 许可公钥已就绪：keyID=${LICKEYS%%:*}"
fi

# Universal Binary（arm64 + x86_64），让 Intel 与 Apple Silicon 都能运行。
# 可用 XICO_ARCHS 覆盖（如 macOS 26 Metal 工具链缺失导致 --arch 通用构建失败时，设 XICO_ARCHS="" 走原生 arm64）。
ARCHS="${XICO_ARCHS---arch arm64 --arch x86_64}"
echo "▶︎ swift build -c $CONFIG $ARCHS (Xico + XicoHelper, Universal)"
swift build -c "$CONFIG" $ARCHS --product Xico
swift build -c "$CONFIG" $ARCHS --product XicoHelper

# Universal 构建时产物在 .build/apple/Products/<Config>；单架构兜底到 .build/<Config>
case "$CONFIG" in
  release) PROD_DIR="Release" ;;
  debug)   PROD_DIR="Debug" ;;
  *)       PROD_DIR="$CONFIG" ;;
esac
BIN_DIR=".build/apple/Products/$PROD_DIR"
[ -x "$BIN_DIR/Xico" ] || BIN_DIR=".build/$CONFIG"
echo "  产物目录: $BIN_DIR"
lipo -info "$BIN_DIR/Xico" 2>/dev/null || true
WORK="$(mktemp -d)"
APP="$WORK/Xico.app"
CONTENTS="$APP/Contents"

mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources" "$CONTENTS/Library/LaunchDaemons"
cp "$BIN_DIR/Xico" "$CONTENTS/MacOS/Xico"
cp "$BIN_DIR/XicoHelper" "$CONTENTS/MacOS/XicoHelper"
# 拷贝全部 SPM 资源包（Xico_Domain.bundle=规则库、Xico_DesignSystem.bundle=本地化 等）。
# 漏拷任何一个都会导致 Bundle.module 运行时断言崩溃——这是启动闪退的根因。
bundle_count=0
for b in "$BIN_DIR"/*.bundle; do
  [ -e "$b" ] || continue
  cp -R "$b" "$CONTENTS/Resources/"
  echo "  ✓ 嵌入资源包 $(basename "$b")"
  bundle_count=$((bundle_count + 1))
done
echo "▶︎ 已嵌入 $bundle_count 个资源包"

# —— 可选：内置 LGPL ffmpeg（下载器的合并/音频提取组件）。
# 用户选定「yt-dlp 运行时上游获取」，但 ffmpeg 是 LGPL、可合法内置——若仓库放了
# Resources/engines/ffmpeg（LGPL 动态构建、不带 x264/x265），这里嵌入并随 App 一起深签名。
# 没有则跳过（App 会在需要时按需拉取，见 EngineInstaller.installFFmpeg）。
if [ -x "$ROOT/Resources/engines/ffmpeg" ]; then
  mkdir -p "$CONTENTS/Resources/Engines"
  cp "$ROOT/Resources/engines/ffmpeg" "$CONTENTS/Resources/Engines/ffmpeg"
  chmod +x "$CONTENTS/Resources/Engines/ffmpeg"
  # 内置可执行文件的签名在下方签名阶段做（inside-out，用真正的 $IDENTITY）。
  [ -f "$ROOT/Resources/engines/ffmpeg-LICENSE.txt" ] && cp "$ROOT/Resources/engines/ffmpeg-LICENSE.txt" "$CONTENTS/Resources/Engines/"
  echo "  ✓ 内置 ffmpeg（LGPL）"
fi

{
cat <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Xico</string>
    <key>CFBundleDisplayName</key><string>Xico</string>
    <key>CFBundleIdentifier</key><string>${APP_BUNDLE_ID}</string>
    <key>CFBundleExecutable</key><string>Xico</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
    <key>CFBundleVersion</key><string>${BUILD}</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>LSUIElement</key><false/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>CFBundleIconFile</key><string>Xico</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>CFBundleDevelopmentRegion</key><string>zh_CN</string>
    <key>CFBundleLocalizations</key><array><string>zh-Hans</string><string>zh-Hant</string><string>en</string><string>ja</string><string>ko</string><string>de</string><string>fr</string><string>es</string><string>ru</string><string>pt-BR</string><string>it</string></array>
    <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
    <key>NSHumanReadableCopyright</key><string>© 2026 Xico. 保留所有权利。</string>
    <key>NSSupportsSuddenTermination</key><true/>
    <key>NSSupportsAutomaticTermination</key><true/>
    <key>CFBundleURLTypes</key>
    <array>
      <dict>
        <key>CFBundleURLName</key><string>${APP_BUNDLE_ID}.activate</string>
        <key>CFBundleURLSchemes</key><array><string>xico</string></array>
      </dict>
    </array>
PLIST
append_info_string "XicoDefinitionsURL" "${XICO_DEFINITIONS_URL:-}"
append_info_string "XicoDefinitionsPublicKeys" "${XICO_DEFINITIONS_PUBLIC_KEYS:-}"
append_info_string "XicoComponentsURL" "${XICO_COMPONENTS_URL:-}"
append_info_string "XicoComponentsPublicKeys" "${XICO_COMPONENTS_PUBLIC_KEYS:-}"
append_info_string "XicoUpdatePublicKeys" "${XICO_UPDATE_PUBLIC_KEYS:-}"
append_info_string "XicoLicensePublicKeys" "${XICO_LICENSE_PUBLIC_KEYS:-}"
append_info_string "XicoPurchaseURL" "${XICO_PURCHASE_URL:-https://mac.xicoai.com/buy}"
# 在线激活服务地址（软件把激活码 POST 到 <此地址>/api/license/activate）
append_info_string "XicoActivationURL" "${XICO_ACTIVATION_URL:-https://mac.xicoai.com}"
# 更新源（Sparkle 兼容的 appcast 键；内置更新检查器也读它）
append_info_string "SUFeedURL" "${XICO_FEED_URL:-https://mac.xicoai.com/appcast.xml}"
cat <<PLIST
</dict>
</plist>
PLIST
} > "$CONTENTS/Info.plist"

# 生成 App 图标（用刚构建的二进制渲染主图，再转 icns）
echo "▶︎ 生成 App 图标"
"$BIN_DIR/Xico" --icon >/dev/null 2>&1 || true
MASTER="/tmp/xico-icon/icon-master.png"
if [ -f "$MASTER" ]; then
  ICONSET="$WORK/Xico.iconset"; mkdir -p "$ICONSET"
  for s in 16 32 128 256 512; do
    sips -z $s $s "$MASTER" --out "$ICONSET/icon_${s}x${s}.png" >/dev/null 2>&1
    d=$((s * 2)); sips -z $d $d "$MASTER" --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null 2>&1
  done
  iconutil -c icns "$ICONSET" -o "$CONTENTS/Resources/Xico.icns" 2>/dev/null \
    && echo "  ✓ Xico.icns" || echo "  ⚠︎ iconutil 失败，跳过图标"
else
  echo "  ⚠︎ 未生成图标主图"
fi

cat > "$CONTENTS/Library/LaunchDaemons/${HELPER_LABEL}.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>${HELPER_LABEL}</string>
    <key>BundleProgram</key><string>Contents/MacOS/XicoHelper</string>
    <key>MachServices</key>
    <dict><key>${HELPER_LABEL}</key><true/></dict>
    <key>AssociatedBundleIdentifiers</key>
    <array><string>${APP_BUNDLE_ID}</string></array>
</dict>
</plist>
PLIST

# 选择签名身份：优先 Developer ID（分发），否则 Apple Development（本机测试），否则 ad-hoc
IDENTITY="$(security find-identity -v -p codesigning | grep -m1 'Developer ID Application' | awk '{print $2}' || true)"
[ -z "${IDENTITY:-}" ] && IDENTITY="$(security find-identity -v -p codesigning | grep -m1 'Apple Development' | awk '{print $2}' || true)"
[ -z "${IDENTITY:-}" ] && IDENTITY="-"
echo "▶︎ 签名身份: ${IDENTITY}"

APP_ENT="$ROOT/Resources/signing/Xico.entitlements"
HELPER_ENT="$ROOT/Resources/signing/XicoHelper.entitlements"

xattr -cr "$APP" 2>/dev/null || true
# 公证要求安全时间戳；ad-hoc(-) 不支持时间戳服务器，故仅在真实身份下加 --timestamp
TS=""
[ "$IDENTITY" != "-" ] && TS="--timestamp"
# 先签内嵌助手（带 Hardened Runtime + entitlements），再签主程（含其内嵌资源）
# 内置 ffmpeg 须先于外层 App 签名（inside-out）；无内置则跳过（运行时按需拉取）。
if [ -x "$CONTENTS/Resources/Engines/ffmpeg" ]; then
  codesign --force --options runtime $TS --sign "$IDENTITY" "$CONTENTS/Resources/Engines/ffmpeg"
  echo "▶︎ 已签名内置 ffmpeg"
fi
codesign --force --identifier "$HELPER_LABEL" --options runtime $TS --entitlements "$HELPER_ENT" --sign "$IDENTITY" "$CONTENTS/MacOS/XicoHelper"
verify_helper_identifier "$CONTENTS/MacOS/XicoHelper"
codesign --force --options runtime $TS --entitlements "$APP_ENT" --sign "$IDENTITY" "$APP"
codesign --verify --strict "$APP" && echo "✓ 签名校验通过"

# 输出到 ~/Applications（非 iCloud 同步，避免 FinderInfo 反复污染签名）
DEST="$HOME/Applications/Xico.app"
rm -rf "$DEST"; mkdir -p "$HOME/Applications"
ditto "$APP" "$DEST"
rm -rf "$WORK"
codesign --verify --strict "$DEST" && echo "✓ 落盘后签名仍校验通过"
verify_helper_identifier "$DEST/Contents/MacOS/XicoHelper"

echo "✓ 已生成: $DEST"
TEAM="$(codesign -dvvv "$DEST" 2>&1 | grep TeamIdentifier | cut -d= -f2 || true)"
echo "  TeamIdentifier: ${TEAM:-未签名}"

# 启动冒烟测试：--selftest 会真实初始化 XicoEnvironment（含 Bundle.module 本地化查表），
# 若漏嵌资源包等会在启动 ~1s 内断言崩溃。但 --selftest 随后还会真跑全功能自检
# （全盘 largeFiles/malware 扫描），在满盘机器上可达 10+ 分钟——不该阻塞打包。
# 故给它时间预算：只要撑过启动崩溃窗口即视为通过，随后主动结束它。
echo "▶︎ 启动冒烟测试（启动存活检测，最多 ${SMOKE_BUDGET:=20}s）"
"$DEST/Contents/MacOS/Xico" --selftest >/dev/null 2>&1 &
SMOKE_PID=$!
smoke_done=""
for _ in $(seq 1 "$SMOKE_BUDGET"); do
  if kill -0 "$SMOKE_PID" 2>/dev/null; then
    sleep 1
  else
    wait "$SMOKE_PID"; rc=$?
    if [ "$rc" -eq 0 ]; then smoke_done="ok"; else
      echo "✗ 冒烟测试失败：App 启动即异常（退出码 $rc，可能漏嵌资源包/签名问题）。请勿分发此包。"
      exit 1
    fi
    break
  fi
done
if [ -z "$smoke_done" ]; then
  # 仍在运行 = 已越过启动崩溃窗口、正在跑全功能自检；结束它并视为通过。
  kill "$SMOKE_PID" 2>/dev/null; wait "$SMOKE_PID" 2>/dev/null || true
  echo "✓ 冒烟测试通过：App 已成功初始化（越过 ${SMOKE_BUDGET}s 启动窗口，提前结束全量自检）"
else
  echo "✓ 冒烟测试通过：App 可正常初始化并完成自检"
fi
echo ""
echo "启用特权助手以执行维护任务："
echo "  1) open ~/Applications/Xico.app"
echo "  2) 进入「维护」页 → 点「安装助手」"
echo "  3) 在系统设置 › 通用 › 登录项与扩展 中批准 Xico 的后台项目"
echo "  注：本机测试用 Apple Development 身份即可；对外分发需 Developer ID + 公证(notarytool)。"
