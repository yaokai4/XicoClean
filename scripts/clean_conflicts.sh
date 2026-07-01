#!/bin/bash
# 显式清理 iCloud 同步产生的 Swift/JSON 冲突副本（例如 "File 2.swift"）。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

find Sources Tests \( -name "* [0-9].swift" -o -name "* [0-9].json" \) -print -delete
