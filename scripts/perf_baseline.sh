#!/bin/bash
# 性能基准：菜单栏稳态 CPU / 内存常驻 / 扫描首结果与总耗时 / 庆祝页 GPU。
# 用法：先正常运行 Xico，再执行本脚本。可设置 XICO_SCAN_BENCH_PATH=/稳定样本目录。
set -euo pipefail

PID=$(pgrep -x Xico | head -1 || true)
if [[ -z "$PID" ]]; then echo "Xico 未在运行"; exit 1; fi

echo "== 内存常驻（目标 < 80MB）=="
footprint "$PID" 2>/dev/null | tail -3 || ps -o rss= -p "$PID" | awk '{printf "RSS: %.1f MB\n", $1/1024}'

echo "== 菜单栏稳态 CPU（60s 均值，目标 < 0.5%）=="
sudo powermetrics --samplers tasks -n 12 -i 5000 2>/dev/null | grep -i "xico" | awk '{sum+=$4; n++} END { if (n>0) printf "平均 CPU: %.2f%%（%d 个采样）\n", sum/n, n; else print "未采到 Xico 样本" }'

if [[ -n "${XICO_SCAN_BENCH_PATH:-}" ]]; then
  echo "== 共享文件索引真机基准（首批进度 < 2s）=="
  ROOT="$(cd "$(dirname "$0")/.." && pwd)"
  (cd "$ROOT" && swift test --filter ScanRealWorldBenchmarkTests/testRealWorldSnapshotBudget)
else
  echo "== 扫描基准未运行 =="
  echo "设置 XICO_SCAN_BENCH_PATH=/稳定样本目录 后重跑，可输出文件数、目录数、首结果与吞吐。"
fi

echo "== 提示 =="
echo "庆祝页 GPU：打开一次清理完成页并停留 30s，另开终端跑："
echo "  sudo powermetrics --samplers gpu_power -n 6 -i 5000   # 粒子自停后 GPU 应回落至基线"
