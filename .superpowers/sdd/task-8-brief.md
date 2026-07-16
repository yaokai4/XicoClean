### Task 8: Complete Localization, Accessibility, and Focused Screenshot QA

**Files:**
- Modify: `Sources/DesignSystem/Resources/de.lproj/Localizable.strings`
- Modify: `Sources/DesignSystem/Resources/en.lproj/Localizable.strings`
- Modify: `Sources/DesignSystem/Resources/es.lproj/Localizable.strings`
- Modify: `Sources/DesignSystem/Resources/fr.lproj/Localizable.strings`
- Modify: `Sources/DesignSystem/Resources/it.lproj/Localizable.strings`
- Modify: `Sources/DesignSystem/Resources/ja.lproj/Localizable.strings`
- Modify: `Sources/DesignSystem/Resources/ko.lproj/Localizable.strings`
- Modify: `Sources/DesignSystem/Resources/pt-BR.lproj/Localizable.strings`
- Modify: `Sources/DesignSystem/Resources/ru.lproj/Localizable.strings`
- Modify: `Sources/DesignSystem/Resources/zh-Hans.lproj/Localizable.strings`
- Modify: `Sources/DesignSystem/Resources/zh-Hant.lproj/Localizable.strings`
- Modify: `Sources/XicoApp/LiveShotRenderer.swift`
- Modify: `Sources/XicoApp/XicoApp.swift`
- Test: `Tests/FeatureTests/LocalizationCoverageTests.swift`

**Interfaces:**
- Produces: localized monitoring copy, complete VoiceOver values, and `Xico --monitoring-shots`.

- [ ] **Step 1: Add the exact new key inventory to localization coverage expectations**

The new keys are:

```text
Xico 压力指数
采样中
实时
部分数据
数据已过期
数据不可用
数据覆盖 %d%%
应用检查器
物理内存
峰值内存
应用聚合
独立进程
%d 个进程
采样来源
本地采样
助手增强
已退出
十进制 GB
二进制 GiB
合并子进程
```

Use professional native translations in all 11 localization files; preserve format specifiers exactly (`%d`, `%%`).

- [ ] **Step 2: Run localization tests and verify missing-key failure**

Run: `swift test --filter LocalizationCoverageTests`

Expected: FAIL listing the new keys until every localization file is updated.

- [ ] **Step 3: Add translations and VoiceOver composition**

Every application row accessibility value must read application name, process count, CPU state/value, and memory value in that order. Charts expose a concise label and latest value; decorative fill bars and glows are hidden. Sampling pills expose both state and coverage. Apply `.monospacedDigit()` to every changing numeric column.

- [ ] **Step 4: Add focused monitoring screenshot mode**

Add `renderMonitoringShots()` that renders only:

```text
/tmp/xico-monitoring-shots/cpu-dark.png
/tmp/xico-monitoring-shots/cpu-light.png
/tmp/xico-monitoring-shots/memory-dark.png
/tmp/xico-monitoring-shots/memory-light.png
/tmp/xico-monitoring-shots/cpu-warming-dark.png
/tmp/xico-monitoring-shots/memory-partial-dark.png
```

It must attach the views to an off-screen `NSWindow`, call `model.prepareApplicationSampling()`, allow at least two sampling intervals for live images, and use deterministic injected fixture snapshots for warming/partial images. Add the `--monitoring-shots` dispatch next to `--liveshots`.

- [ ] **Step 5: Run localization tests and render screenshots**

Run: `swift test --filter LocalizationCoverageTests && swift build && .build/debug/Xico --monitoring-shots`

Expected: tests PASS and all six PNG files exist with non-zero size.

- [ ] **Step 6: Inspect all six images**

Verify: no clipped text at 336 pt; CPU panel contains no GPU primary block; memory panel contains no CPU primary block; every application row has both numeric columns; light/dark contrast remains legible; warming/partial states are explicit.

- [ ] **Step 7: Commit localization and screenshot QA**

```bash
git add Sources/DesignSystem/Resources Sources/XicoApp/LiveShotRenderer.swift Sources/XicoApp/XicoApp.swift Tests/FeatureTests/LocalizationCoverageTests.swift
git commit -m "test: cover precision monitoring presentation"
```

---

