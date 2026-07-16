# Task 9 Report — Accuracy, Performance, and Regression Safety

## Scope

- Added an opt-in real-machine accuracy/performance suite gated by `XICO_RUN_PROCESS_ACCURACY=1`.
- Batched local `proc_pid_rusage` reads through `CProcessBatch`, cached stable process/application metadata, and removed redundant aggregation/ranking work.
- Split menu-bar snapshot delivery from global SwiftUI invalidation and narrowed CPU/memory detail sampling to the fields each card consumes.
- Cached slow hardware readings and process-lifetime IOReport setup while preserving real two-sample frequency reads.
- Fixed hidden `NSPanel` ownership so Swift ARC, rather than AppKit release-on-close, controls destruction.
- Regenerated and visually checked all six focused monitoring screenshots with a real warmed snapshot and production process sampling.
- Preserved unrelated dirty-worktree changes through selective index-only staging.

## Real-Machine Accuracy Evidence

`XICO_RUN_PROCESS_ACCURACY=1 swift test --filter ProcessAccuracyBenchmarkTests` passed 8/8 on the acceptance Mac:

- PID coverage: 840 enumerated versus 860 reported by the kernel, within the 32-process churn allowance.
- Current-process footprint: `/usr/bin/top` relative difference 1.257% (limit 5%).
- Controlled `/usr/bin/yes`: raw CPU 77.735%; normalized CPU 9.717% on 8 active logical CPUs.
- 1,200-record fixture: all 1,200 members retained with exact CPU and footprint totals.
- Local capture: P95 4.700 ms (limit 15 ms).
- Application sampler: 60 samples over 60.876 s, 1.402% absolute sampler CPU (diagnostic only), 0-byte positive footprint growth, first memory rows in 8.234 ms, valid CPU rows in 1.070 s.
- Delayed helper: first local capture returned in 0.124 ms without waiting for the one-second helper delay.
- Stable live groups: Xico, ChatGPT, and a system daemon matched member totals; top-footprint differences were 0.357%, 0.034%, and 0.002% respectively. CPU raw/normalized conversion matched the 8-CPU formula.

The application-row footprint is the sum of member `ri_phys_footprint` values. It is intentionally not asserted equal to the system-wide “application memory” VM category, whose shared/compressed accounting differs.

## Runtime Performance Evidence

A same-process `steady → memory → cpu` comparison, 60 seconds per scope, produced:

- memory detail additional CPU: +0.982 percentage points;
- CPU detail additional CPU: +1.093 percentage points.

Both are below the +1.5 percentage-point acceptance limit. The real-machine suite also verified trend/ranking footprint growth below 12 MiB, memory rows below 150 ms, CPU rows by the next configured interval, and non-blocking helper fallback.

## Review Follow-up: Helper Freshness

The independent review found that a completed asynchronous helper response could survive a closed-panel gap and be relabeled with a newer local frame. The first fixed TTL was then found too short for the supported five-second refresh setting. The final implementation:

- timestamps completed helper batches and consumes each result at most once;
- attaches a request generation so superseded work cannot publish;
- derives freshness dynamically from the current 1/2/5-second user setting plus one second of scheduling allowance;
- immediately tightens freshness if the setting changes from five seconds back to one second;
- retains honest local/partial coverage when a result expires.

The regression suite first failed for the missing freshness API, then passed 8/8. It explicitly verifies acceptance at the next five-second tick, rejection after a long gap/possible PID reuse, and immediate rejection after changing the configured interval from five seconds to one second.

## Live Product Comparison

- iStat Menus 7 was inspected in its running configuration: the CPU process format is explicitly `0–100%`, matching Xico's default normalized mode.
- Xico's live processor view was inspected at one-second refresh with current per-core, user/system, P/E frequency, load, temperature, and process rows populated.
- `/usr/bin/top` supplied the machine-readable Activity Monitor-equivalent footprint comparison for the current process and the Xico/Chrome/system-daemon live groups.
- Inspector arithmetic is covered by the same live-group capture plus deterministic presentation tests: member footprint and CPU totals equal the application row before display rounding. The 76% partial fixture and `采样中` state were visually inspected in the final focused screenshots.

The XCTest sampler CPU figure is intentionally emitted as an isolated diagnostic: it scales with the host's process count and concurrent load. The separate same-process 60-second probe above is the app-level steady-to-detail acceptance evidence for the +1.5 percentage-point budget; the report does not conflate the two.

## Lifecycle Regression

The full test suite originally exposed a SIGSEGV after repeatedly closing hidden monitoring cards. LLDB plus Zombies identified `-[NSPanel release]: message sent to deallocated instance`: `isReleasedWhenClosed=true` conflicted with a Swift-held panel reference. New panels now use `isReleasedWhenClosed=false`; the centralized close path detaches hosted content before closing. A regression test creates and closes ten hidden panels, drains the run loop, and verifies both controller deallocation and removal from `NSApp.windows`.

## Screenshot QA

All final files were generated under `/tmp/xico-monitoring-shots` and inspected at original resolution:

- `cpu-dark.png` — 672×1472, 178,527 bytes
- `cpu-light.png` — 672×1472, 175,273 bytes
- `memory-dark.png` — 672×1640, 217,082 bytes
- `memory-light.png` — 672×1640, 215,084 bytes
- `cpu-warming-dark.png` — 672×1040, 103,290 bytes
- `memory-partial-dark.png` — 672×1640, 242,164 bytes

The live CPU/memory shots contain real application rows rather than a spinner-only state. Warming shows explicit `采样中`; partial coverage shows 76% and fixture rows. Light/dark layouts remain legible and unclipped at the 336 pt card width.

## Verification

- Focused deterministic monitoring suites — PASS, including helper freshness 8/8.
- `swift test --disable-sandbox` — PASS (371 tests, 15 skipped, 0 failures).
- Full test from an archive of the exact staged Git tree — PASS (326 tests, 13 skipped, 0 failures); unstaged SSH/scan/browser-extension work was absent.
- Opt-in real-machine suite — PASS (8/8).
- `bash scripts/quality_gate.sh` — PASS, including debug/release builds and all deterministic gates.
- `.build/debug/Xico --monitoring-shots` — PASS; exactly 6/6 non-empty PNGs, visually inspected.
- `git diff --check` — PASS.

## Packaging Evidence and Limitation

`scripts/make_app.sh release` could not produce the default Universal binary because this Mac's Xcode installation lacks the Metal Toolchain (`metal` is unavailable). The documented native fallback succeeded with `XICO_ARCHS='' scripts/make_app.sh release`:

- installed app: `/Users/yaokai/Applications/Xico.app`;
- architecture: arm64;
- strict/deep code-sign verification: PASS;
- bundle identifier: `com.xico.app`;
- TeamIdentifier: `P22K8NF89K`;
- embedded helper validation and 20-second startup smoke: PASS.

This evidence does **not** claim a Universal build or notarization. Universal packaging still requires installing the Xcode Metal Toolchain (for example, `xcodebuild -downloadComponent MetalToolchain`) and rerunning the normal release flow.

## Review and Commit

- Independent Task 9 review: Ready; 0 Critical and 0 Important after the helper freshness fixes. Three non-blocking hardening notes remain for future QA failure signaling, transient IOReport retry, and keeping isolated/app-level CPU evidence distinct.
- `4f7127f` — `test: verify application monitoring accuracy`.
- `989b90d` — `test: distinguish sampler CPU diagnostics`.
