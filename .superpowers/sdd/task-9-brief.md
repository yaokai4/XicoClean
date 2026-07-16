### Task 9: Prove Accuracy, Coverage, Performance, and Regression Safety

**Files:**
- Create: `Tests/IntegrationTests/ProcessAccuracyBenchmarkTests.swift`
- Modify: `scripts/quality_gate.sh`
- Modify: `docs/superpowers/specs/2026-07-15-xico-precision-monitoring-design.md` only to mark the first implementation slice complete after every acceptance check passes.

**Interfaces:**
- Consumes: the finished local/hybrid provider and application sampler.
- Produces: opt-in real-machine accuracy tests and release-gate regression coverage.

- [ ] **Step 1: Add opt-in real-machine accuracy tests**

Gate the suite with `XICO_RUN_PROCESS_ACCURACY=1`. Add these exact assertions:

1. `PIDEnumerator().allPIDs().count >= Int(proc_listallpids(nil, 0)) - 32` to allow normal churn while rejecting the old quarter-count bug.
2. For the current test process, convert `/usr/bin/top -l 2 -pid <pid> -stats pid,mem` memory to bytes and require relative difference from `ri_phys_footprint` ≤ 5%.
3. Spawn `/usr/bin/yes`, take two samples one second apart, require raw CPU in 70–130%, and require normalized CPU to equal raw divided by active logical CPUs within 0.5 percentage points.
4. Create 1,200 fake records and require aggregation equality for CPU and footprint with no dropped members.
5. Run 20 local captures, sort durations, and require P95 < 15 ms on the current M1 acceptance machine.

Always terminate the `yes` process in `defer`, including assertion failures.

- [ ] **Step 2: Run ordinary tests first**

Run: `swift test`

Expected: all non-hardware-gated suites PASS.

- [ ] **Step 3: Run the real-machine accuracy suite**

Run: `XICO_RUN_PROCESS_ACCURACY=1 swift test --filter ProcessAccuracyBenchmarkTests`

Expected: all five acceptance tests PASS.

- [ ] **Step 4: Measure app-level runtime overhead**

Run the debug app with the CPU or memory panel visible for 60 seconds and use the existing performance probe to compare visible-detail sampling against steady state. Acceptance:

- additional Xico CPU < 1.5 percentage points at 1 Hz;
- trend/ranking cache allocation < 12 MB;
- memory rows appear < 150 ms after opening;
- valid CPU values appear by the next configured sampling interval;
- helper timeout never blocks the main thread.

Record the measured values in the test log emitted by `ProcessAccuracyBenchmarkTests`; do not hard-code machine-specific numbers into UI copy.

- [ ] **Step 5: Add stable suites to the quality gate**

Add the deterministic suites to `scripts/quality_gate.sh`:

```bash
swift test --filter ProcessSnapshotProviderTests
swift test --filter ApplicationUsageAggregatorTests
swift test --filter HelperProcessSamplingTests
swift test --filter MemoryMetricsTests
swift test --filter ApplicationUsagePresentationTests
```

Keep the opt-in real-machine suite outside default CI.

- [ ] **Step 6: Run the full quality gate and final screenshots**

Run: `bash scripts/quality_gate.sh && .build/debug/Xico --monitoring-shots`

Expected: quality gate exits 0; six monitoring screenshots regenerate successfully.

- [ ] **Step 7: Compare live stable processes against Activity Monitor/iStat**

For at least Xico, Chrome/Codex, and one system daemon:

- confirm application grouping contains the expected member count;
- compare physical footprint to the sum of corresponding Activity Monitor child rows;
- compare normalized CPU using iStat 0–100% mode;
- expand the inspector and verify member totals equal the application row after display rounding;
- verify partial coverage is visible if the helper is deliberately disabled.

- [ ] **Step 8: Mark the first spec slice complete and commit acceptance evidence**

Update the spec status from `待用户书面复核` to `首个实施切片完成` only after Steps 2–7 pass.

```bash
git add Tests/IntegrationTests/ProcessAccuracyBenchmarkTests.swift scripts/quality_gate.sh docs/superpowers/specs/2026-07-15-xico-precision-monitoring-design.md
git commit -m "test: verify application monitoring accuracy"
```

---

## Final Acceptance Checklist

- [ ] All PID enumeration uses count semantics and survives buffer saturation.
- [ ] PID reuse and long sample gaps cannot create false CPU spikes.
- [ ] Chrome/Electron/XPC child processes aggregate under the outer application.
- [ ] Helper enrichment is bounded, signed, read-only, and optional.
- [ ] CPU defaults to normalized 0–100%; raw mode is selectable.
- [ ] Per-app memory is summed `ri_phys_footprint` and verified against `top`.
- [ ] CPU panel contains CPU primary information only.
- [ ] Memory panel contains memory primary information only.
- [ ] Every application row in both panels displays CPU and memory.
- [ ] First CPU sample says `采样中`; unavailable data never appears as fabricated zero.
- [ ] Memory pressure state is distinct from the explicitly named Xico pressure index.
- [ ] CPU/memory application rows open the same live application inspector.
- [ ] Dark/light, warming, and partial screenshots pass visual review.
- [ ] Deterministic tests, real-machine accuracy tests, and performance budgets pass.
