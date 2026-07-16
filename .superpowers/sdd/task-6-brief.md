### Task 6: Add Typed Monitoring Preferences and Dual-Metric Row Presentation

**Files:**
- Create: `Sources/Features/MonitoringPreferences.swift`
- Create: `Sources/Features/ApplicationUsageViews.swift`
- Modify: `Sources/Features/MenuBarSettingsView.swift`
- Modify: `Sources/Domain/Models.swift`
- Test: `Tests/FeatureTests/ApplicationUsagePresentationTests.swift`

**Interfaces:**
- Produces: `MonitoringPanelDensity`, `MonitoringPreferences`, `MemoryUnitStyle`, `Int64.formattedMemory(style:)`, `ApplicationUsageFocus`, and `ApplicationUsageRowPresentation.make(...)`.
- Consumes: `ApplicationUsage` and `CPUDisplayMode`.

**Dependency/dirty-worktree resolution:** `MonitoringPreferences.swift` already
exists from Task 4 with the two minimal process settings; extend it rather than
recreating it. Canonical keys are the plan's `xico.monitor.*` names. Preserve
backward reads from Task 4's temporary `xico.monitoring.*` keys, and add/update
focused migration coverage in `MetricsGatingTests.swift` if required. Settings
writes use only canonical keys. `Domain/Models.swift` and
`MenuBarSettingsView.swift` contain pre-existing user changes; stage only Task
6 hunks and do not reformat or stage either file wholesale.

**Localization gate resolution:** selectively add only Task 6's 14 new literal
keys to every dirty locale so coverage/parity stays green. zh-Hans receives the
canonical values; the other locales may temporarily use the canonical source
values. Do not stage other pre-existing resource changes. Task 8 must replace
all placeholders with professional translations and run cross-locale visual
QA before final delivery.

- [ ] **Step 1: Write failing tests that lock the user's CPU/memory row rule**

```swift
import XCTest
@testable import Features
@testable import Infrastructure
import Domain

final class ApplicationUsagePresentationTests: XCTestCase {
    func testCPURowShowsCPUPrimaryAndMemorySecondary() {
        let row = ApplicationUsageRowPresentation.make(
            usage: .fixture(cpuRaw: 80, cpuNormalized: 10, memory: 1_073_741_824),
            focus: .cpu, cpuMode: .normalized, memoryStyle: .binary)
        XCTAssertEqual(row.primaryText, "10.0%")
        XCTAssertEqual(row.secondaryText, "1.00 GiB")
    }

    func testMemoryRowShowsMemoryPrimaryAndCPUSecondary() {
        let row = ApplicationUsageRowPresentation.make(
            usage: .fixture(cpuRaw: 80, cpuNormalized: 10, memory: 1_073_741_824),
            focus: .memory, cpuMode: .normalized, memoryStyle: .binary)
        XCTAssertEqual(row.primaryText, "1.00 GiB")
        XCTAssertEqual(row.secondaryText, "10.0%")
    }

    func testUnknownCPUIsSamplingNotZero() {
        let row = ApplicationUsageRowPresentation.make(
            usage: .fixture(cpuRaw: nil, cpuNormalized: nil, memory: 1_000_000),
            focus: .memory, cpuMode: .normalized, memoryStyle: .decimal)
        XCTAssertEqual(row.secondaryText, "采样中")
    }
}
```

Add this test-only fixture in the same file:

```swift
private extension ApplicationUsage {
    static func fixture(cpuRaw: Double?, cpuNormalized: Double?, memory: Int64) -> Self {
        let identity = ProcessIdentity(pid: 7, startTimeNanoseconds: 1)
        return ApplicationUsage(
            id: ApplicationIdentity(rawValue: "bundle:com.example.fixture"),
            displayName: "Fixture", bundleIdentifier: "com.example.fixture",
            bundlePath: "/Applications/Fixture.app", representativePID: 7,
            members: [ApplicationMemberUsage(identity: identity, name: "Fixture",
                                             cpuRawPercent: cpuRaw,
                                             physicalFootprintBytes: memory)],
            cpuRawPercent: cpuRaw, cpuNormalizedPercent: cpuNormalized,
            physicalFootprintBytes: memory, peakFootprintBytes: memory,
            trend: ApplicationUsageTrend(cpuRaw: [], memoryBytes: []))
    }
}
```

- [ ] **Step 2: Run the test and verify presentation types are absent**

Run: `swift test --filter ApplicationUsagePresentationTests`

Expected: FAIL for missing `ApplicationUsageRowPresentation` and `MemoryUnitStyle`.

- [ ] **Step 3: Add exact preferences and defaults**

```swift
public enum MonitoringPanelDensity: String, CaseIterable { case compact, balanced, detailed }

public enum MonitoringPreferences {
    public static let cpuModeKey = "xico.monitor.cpuMode"
    public static let combinesProcessesKey = "xico.monitor.combinesProcesses"
    public static let processLimitKey = "xico.monitor.processLimit"
    public static let densityKey = "xico.monitor.density"
    public static let memoryUnitKey = "xico.monitor.memoryUnit"

    public static func cpuMode(_ defaults: UserDefaults = .standard) -> CPUDisplayMode {
        CPUDisplayMode(rawValue: defaults.string(forKey: cpuModeKey) ?? "normalized") ?? .normalized
    }
    public static func combinesProcesses(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: combinesProcessesKey) == nil ? true : defaults.bool(forKey: combinesProcessesKey)
    }
    public static func processLimit(_ defaults: UserDefaults = .standard) -> Int {
        let value = defaults.integer(forKey: processLimitKey)
        return [4, 6, 10, 20].contains(value) ? value : 6
    }
    public static func density(_ defaults: UserDefaults = .standard) -> MonitoringPanelDensity {
        MonitoringPanelDensity(rawValue: defaults.string(forKey: densityKey) ?? "balanced") ?? .balanced
    }
}
```

Add `MemoryUnitStyle.decimal` and `.binary`. `formattedMemory(style:)` uses powers of 1,000 with `GB/MB` for decimal and powers of 1,024 with `GiB/MiB` for binary. Keep the existing `formattedMemory` property delegating to the current Activity Monitor-compatible behavior so unrelated screens do not change.

- [ ] **Step 4: Add pure row presentation**

```swift
public enum ApplicationUsageFocus { case cpu, memory }

public struct ApplicationUsageRowPresentation: Equatable {
    public let primaryText: String
    public let secondaryText: String
    public let fillFraction: Double

    public static func make(usage: ApplicationUsage, focus: ApplicationUsageFocus,
                            cpuMode: CPUDisplayMode, memoryStyle: MemoryUnitStyle,
                            largestMemory: Int64 = 1) -> Self {
        let cpu = usage.cpuPercent(mode: cpuMode)
        let cpuText = cpu.map { String(format: "%.1f%%", $0) } ?? xLoc("采样中")
        let memoryText = usage.physicalFootprintBytes.formattedMemory(style: memoryStyle)
        let fill = focus == .cpu
            ? min(1, (cpu ?? 0) / (cpuMode == .normalized ? 100 : 100 * Double(ProcessInfo.processInfo.activeProcessorCount)))
            : min(1, Double(usage.physicalFootprintBytes) / Double(max(1, largestMemory)))
        return focus == .cpu
            ? Self(primaryText: cpuText, secondaryText: memoryText, fillFraction: fill)
            : Self(primaryText: memoryText, secondaryText: cpuText, fillFraction: fill)
    }
}
```

- [ ] **Step 5: Add settings controls**

Under CPU/memory item details, add shared controls for CPU format, combine processes, row count, density, and memory unit. Global refresh choices become exactly 1, 2, and 5 seconds. Changing presentation preferences updates the next rendered frame; changing grouping calls `model.prepareApplicationSampling()` to rebuild ownership and baseline.

- [ ] **Step 6: Run presentation, localization, and settings compile tests**

Run: `swift test --filter ApplicationUsagePresentationTests && swift test --filter LocalizationCoverageTests && swift build`

Expected: PASS.

- [ ] **Step 7: Commit preferences and presentation**

```bash
git add Sources/Features/MonitoringPreferences.swift Sources/Features/ApplicationUsageViews.swift Sources/Features/MenuBarSettingsView.swift Sources/Domain/Models.swift Tests/FeatureTests/ApplicationUsagePresentationTests.swift
git commit -m "feat: configure application monitoring presentation"
```

---
