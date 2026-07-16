#!/usr/bin/env bash
#
# make-icons.sh — 把 icons/icon.svg 转成 MV3 需要的 PNG（16/32/48/128）。
#
# 优先级：rsvg-convert（最清晰） > cairosvg > sips（macOS 自带，SVG 支持有限）
#          > qlmanage（macOS 自带，QuickLook 缩略图，兜底）。
#
# 用法：
#   cd chrome && ./make-icons.sh
#
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
SVG="$DIR/icons/icon.svg"
OUT="$DIR/icons"
SIZES=(16 32 48 128)

if [[ ! -f "$SVG" ]]; then
  echo "找不到 $SVG" >&2
  exit 1
fi

have() { command -v "$1" >/dev/null 2>&1; }

gen_one() {
  local size="$1"
  local out="$OUT/icon${size}.png"

  if have rsvg-convert; then
    rsvg-convert -w "$size" -h "$size" "$SVG" -o "$out"
  elif have cairosvg; then
    cairosvg "$SVG" -W "$size" -H "$size" -o "$out"
  elif have sips; then
    # sips 对 SVG 支持不稳；失败则落到 qlmanage。
    if ! sips -s format png -z "$size" "$size" "$SVG" --out "$out" >/dev/null 2>&1; then
      return 1
    fi
  else
    return 1
  fi
  return 0
}

gen_qlmanage() {
  # qlmanage 生成 QuickLook 缩略图，再用 sips 精确缩放到目标尺寸。
  have qlmanage || return 1
  local tmp
  tmp="$(mktemp -d)"
  # 生成一个较大的基准图（256）保证清晰度
  qlmanage -t -s 256 -o "$tmp" "$SVG" >/dev/null 2>&1 || { rm -rf "$tmp"; return 1; }
  local base
  base="$(find "$tmp" -name '*.png' | head -n1)"
  [[ -n "$base" ]] || { rm -rf "$tmp"; return 1; }
  for size in "${SIZES[@]}"; do
    sips -s format png -z "$size" "$size" "$base" --out "$OUT/icon${size}.png" >/dev/null 2>&1
  done
  rm -rf "$tmp"
  return 0
}

ok=1
for size in "${SIZES[@]}"; do
  if ! gen_one "$size"; then
    ok=0
    break
  fi
  echo "  ✓ icon${size}.png"
done

if [[ "$ok" -ne 1 ]]; then
  echo "主转换器不可用/失败，改用 qlmanage 兜底…"
  if gen_qlmanage; then
    for size in "${SIZES[@]}"; do echo "  ✓ icon${size}.png (qlmanage)"; done
  else
    echo "！无法生成 PNG。请安装 librsvg：brew install librsvg，然后重跑本脚本。" >&2
    echo "  在此之前，manifest 里的 icons 若加载失败不影响扩展主功能。" >&2
    exit 1
  fi
fi

echo "完成，PNG 已写入 $OUT"
