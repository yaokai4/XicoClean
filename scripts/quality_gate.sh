#!/bin/bash
# 本地发布前质量门禁：Swift 6 Debug 构建、默认测试、Release 构建。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

echo "▶︎ Swift 6 debug build"
swift build

echo "▶︎ Default test suite"
swift test

echo "▶︎ Precision monitoring deterministic suites"
swift test --filter ProcessSnapshotProviderTests
swift test --filter ApplicationUsageAggregatorTests
swift test --filter HelperProcessSamplingTests
swift test --filter MemoryMetricsTests
swift test --filter ApplicationUsagePresentationTests

echo "▶︎ Release script checks"
bash -n scripts/make_app.sh
bash -n scripts/notarize.sh
bash -n scripts/release_preflight.sh
plutil -lint Resources/signing/Xico.entitlements Resources/signing/XicoHelper.entitlements

echo "▶︎ Definitions signing tool self-test"
swift scripts/sign_definitions.swift --self-test

echo "▶︎ License signing tool self-test"
swift scripts/sign_license.swift --self-test

echo "▶︎ Release build"
swift build -c release

echo "✓ Quality gate passed"
