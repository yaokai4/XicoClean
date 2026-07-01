#!/bin/bash
# 发布预检：在真正公证/分发前检查商业化硬条件。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

RUN_QUALITY=1
ALLOW_MISSING_SECRETS=0
PROFILE="${XICO_NOTARY_PROFILE:-XicoNotary}"

for arg in "$@"; do
  case "$arg" in
    --skip-quality) RUN_QUALITY=0 ;;
    --allow-missing-secrets) ALLOW_MISSING_SECRETS=1 ;;
    *)
      echo "未知参数: $arg"
      echo "用法: scripts/release_preflight.sh [--skip-quality] [--allow-missing-secrets]"
      exit 2
      ;;
  esac
done

failures=0
warnings=0

pass() { echo "✓ $1"; }
warn() { echo "⚠︎ $1"; warnings=$((warnings + 1)); }
fail() { echo "✗ $1"; failures=$((failures + 1)); }

need_exec() {
  if [ -x "$1" ]; then pass "$1 可执行"; else fail "$1 不可执行或不存在"; fi
}

need_file() {
  if [ -f "$1" ]; then pass "$1 存在"; else fail "$1 不存在"; fi
}

need_secret() {
  local name="$1"
  if [ -n "${!name:-}" ]; then
    pass "$name 已配置"
  elif [ "$ALLOW_MISSING_SECRETS" -eq 1 ]; then
    warn "$name 未配置（已按参数允许缺失）"
  else
    fail "$name 未配置"
  fi
}

echo "▶︎ 检查源码冲突副本"
if find Sources Tests \( -name "* [0-9].swift" -o -name "* [0-9].json" \) -print -quit | grep -q .; then
  fail "发现疑似 iCloud 冲突副本，请先运行 scripts/clean_conflicts.sh 并人工复核"
else
  pass "未发现冲突副本"
fi

echo "▶︎ 检查脚本与签名资源"
need_exec "scripts/make_app.sh"
need_exec "scripts/notarize.sh"
need_exec "scripts/sign_definitions.swift"
need_exec "scripts/sign_license.swift"
need_exec "scripts/quality_gate.sh"
need_file "Resources/signing/Xico.entitlements"
need_file "Resources/signing/XicoHelper.entitlements"

echo "▶︎ 检查发布配置"
need_secret "XICO_DEFINITIONS_URL"
need_secret "XICO_DEFINITIONS_PUBLIC_KEYS"
need_secret "XICO_LICENSE_PUBLIC_KEYS"

if security find-identity -v -p codesigning | grep -q "Developer ID Application"; then
  pass "已安装 Developer ID Application 证书"
else
  fail "未找到 Developer ID Application 证书，无法对外公证分发"
fi

if xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1; then
  pass "notarytool profile 可用：$PROFILE"
else
  if [ "$ALLOW_MISSING_SECRETS" -eq 1 ]; then
    warn "notarytool profile 不可用：$PROFILE"
  else
    fail "notarytool profile 不可用：$PROFILE"
  fi
fi

if [ "$RUN_QUALITY" -eq 1 ]; then
  echo "▶︎ 运行质量门禁"
  scripts/quality_gate.sh
else
  warn "按参数跳过质量门禁"
fi

echo "▶︎ 结果"
if [ "$failures" -gt 0 ]; then
  echo "✗ 发布预检未通过：$failures 个阻塞，$warnings 个警告"
  exit 1
fi

echo "✓ 发布预检通过：$warnings 个警告"
