# Xico Phase 0 Operation Facts Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 实现 OUT-01…10 的统一操作事实层，把 CleaningEngine、CleaningReport、清理历史和成功副作用迁移到 reducer 生成的 success/partial/failure/cancelled 事实，消除“按循环次数或回调次数算成功”。

**Architecture:** Domain 新增不可由 feature 任意构造的 `OperationOutcome` 与纯 reducer；每个执行器返回逐项 `OperationItemOutcome`，强类型业务报告只携带 payload；Infrastructure 只持久化 reducer 事实；Features 通过 `OutcomeSideEffectPolicy` 决定历史、通知和庆祝。迁移期间保留只读计算属性兼容现有展示，但旧聚合初始化器在本计划结束前删除。

**Tech Stack:** Swift 6、SwiftPM、Foundation、Swift Concurrency、SwiftUI、XCTest。

## Global Constraints

- 覆盖 requirement：OUT-01…10、UI-OUT-01…02、UI-OUT-05…06，以及工作包 P0-01、P0-02、P0-06、WF-01、WF-10。
- `OperationOutcome` 的业务初始化器不得 public；feature 不能手工写 status/counts/issues。
- `requested == 0` 必须返回显式 reducer error，不得产生 success。
- reducer 必须把缺失、重复和意外 subject 变成 `internalInvariant`，不得丢弃或默认为成功。
- 一旦取消被接受，终态固定为 cancelled；已完成 disposition 和恢复 receipt 仍保留。
- `unchanged` 是目标已满足，不是副作用；不能触发清理通知、庆祝或成功次数。
- partial/failure/cancelled 不发送成功通知、不播放成功声触/粒子。
- 迁移旧 history 时使用 `legacyUnknown`，不得倒推为 success。
- 日志只记录 issue code 和数量；路径、URL、host 和 `localizedDescription` 默认 private。
- 每个 commit 只暂存该 Task 的精确文件。

## File Structure

### Domain facts

- Create `Sources/Domain/OperationOutcome.swift`: operation identifiers、disposition、counts、outcome、reducer、merge 和 lifecycle。
- Modify `Sources/Domain/Models.swift`: `CleaningItemResult` 与基于 outcome/items 的 `CleaningReport`。
- Modify `Sources/Domain/CleaningEngine.swift`: 每个请求项恰好产生一个 disposition，取消诚实终态。

### Infrastructure facts

- Modify `Sources/Infrastructure/HistoryStore.swift`: `HistoryOutcomeStatus`、operation/counts、legacyUnknown 解码和真实成功次数。
- Modify `Sources/Infrastructure/Notifier.swift`: 只接受 policy 已批准的 success+changed 通知请求。

### Feature policy and consumers

- Create `Sources/Features/OutcomeSideEffectPolicy.swift`: 纯策略与 operation-ID 一次消费门。
- Modify `Sources/Features/ModuleSessionViewModel.swift`: reducer merge、只移除 succeeded/unchanged、真实历史/通知。
- Modify `Sources/Features/SmartScanHub.swift`: 同上，保留混合 intent restorable。
- Modify `Sources/Features/SharedViews.swift`: `TaskOutcomeView` 和状态语义；`CompletionView` 只消费 `CleaningReport.operation`。
- Modify `Sources/Features/ScanViews.swift`、`SettingsView.swift`: 历史撤销不伪造 CleaningReport。

### Tests

- Create `Tests/DomainTests/OperationOutcomeReducerTests.swift`.
- Modify `Tests/DomainTests/CleaningEngineTests.swift`.
- Modify `Tests/IntegrationTests/CleaningRoundTripTests.swift`.
- Modify `Tests/IntegrationTests/HistoryStoreTests.swift`.
- Create `Tests/FeatureTests/OutcomeSideEffectPolicyTests.swift`.
- Create `Tests/FeatureTests/TaskOutcomePresentationTests.swift`.
- Modify `Tests/FeatureTests/LocalizationCoverageTests.swift` only through normal key discovery; do not suppress missing keys.

---

### Task 1: Add the Pure Operation Outcome Reducer

**Files:**
- Create: `Sources/Domain/OperationOutcome.swift`
- Create: `Tests/DomainTests/OperationOutcomeReducerTests.swift`

**Interfaces:**
- Produces: `OperationKind`, `OperationTerminalStatus`, `OperationIssueCategory`, `OperationRecoveryHint`, `OperationIssue`, `OperationDisposition`, `OperationItemOutcome`, `OperationCounts`, `OperationOutcome`, `OperationResult`, `OperationProgress`, `OperationLifecycle`, `OperationReductionError`, `OperationOutcomeReducer`.
- Consumes: no Infrastructure, SwiftUI, localized strings, OSLog, filesystem or network APIs.

- [ ] **Step 1: Write reducer tests that cover every OUT invariant**

Create `Tests/DomainTests/OperationOutcomeReducerTests.swift` with these test cases and a shared `reduce` helper:

```swift
import XCTest
@testable import Domain

final class OperationOutcomeReducerTests: XCTestCase {
    private let kind = OperationKind("test.operation")
    private let start = Date(timeIntervalSince1970: 100)
    private let finish = Date(timeIntervalSince1970: 101)

    private func item(_ id: String, _ disposition: OperationDisposition,
                      bytes: Int64 = 0) -> OperationItemOutcome {
        OperationItemOutcome(subjectID: id, disposition: disposition, affectedBytes: bytes)
    }

    private func reduce(_ requested: [String], _ items: [OperationItemOutcome],
                        cancelled: Bool = false, parentID: UUID? = nil) throws -> OperationOutcome {
        try OperationOutcomeReducer.reduce(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            parentID: parentID,
            kind: kind,
            requestedSubjectIDs: requested,
            itemOutcomes: items,
            cancellationAccepted: cancelled,
            startedAt: start,
            finishedAt: finish)
    }

    func testAllSucceededIsSuccess() throws {
        let outcome = try reduce(["a", "b"], [item("a", .succeeded), item("b", .succeeded)])
        XCTAssertEqual(outcome.status, .success)
        XCTAssertEqual(outcome.counts, OperationCounts(requested: 2, succeeded: 2,
                                                       unchanged: 0, skipped: 0,
                                                       failed: 0, cancelled: 0))
    }

    func testSucceededAndUnchangedIsSuccessButTracksChangedCount() throws {
        let outcome = try reduce(["a", "b"], [item("a", .succeeded), item("b", .unchanged)])
        XCTAssertEqual(outcome.status, .success)
        XCTAssertEqual(outcome.counts.succeeded, 1)
        XCTAssertEqual(outcome.counts.unchanged, 1)
        XCTAssertTrue(outcome.hasChanges)
    }

    func testAllUnchangedIsSuccessWithoutChanges() throws {
        let outcome = try reduce(["a"], [item("a", .unchanged)])
        XCTAssertEqual(outcome.status, .success)
        XCTAssertFalse(outcome.hasChanges)
    }

    func testSuccessAndFailureIsPartial() throws {
        let issue = OperationIssue(code: "io.write", category: .io,
                                   subjectID: "b", recovery: .retry, retryable: true)
        let outcome = try reduce(["a", "b"], [item("a", .succeeded), item("b", .failed(issue))])
        XCTAssertEqual(outcome.status, .partial)
        XCTAssertEqual(outcome.counts.failed, 1)
    }

    func testOnlyFailuresAndSkipsIsFailure() throws {
        let issue = OperationIssue(code: "permission.denied", category: .permission,
                                   subjectID: nil, recovery: .grantPermission, retryable: true)
        let outcome = try reduce(["a", "b"], [item("a", .failed(issue)), item("b", .skipped(issue))])
        XCTAssertEqual(outcome.status, .failure)
    }

    func testAcceptedCancellationWinsAndPreservesCompletedItems() throws {
        let outcome = try reduce(["a", "b"], [item("a", .succeeded)], cancelled: true)
        XCTAssertEqual(outcome.status, .cancelled)
        XCTAssertEqual(outcome.counts.succeeded, 1)
        XCTAssertEqual(outcome.counts.cancelled, 1)
    }

    func testMissingResultFailsClosed() throws {
        let outcome = try reduce(["a", "b"], [item("a", .succeeded)])
        XCTAssertEqual(outcome.status, .partial)
        XCTAssertEqual(outcome.counts.failed, 1)
        XCTAssertTrue(outcome.issues.contains { $0.code == "operation.result.missing" && $0.subjectID == "b" })
    }

    func testDuplicateResultFailsThatSubjectClosed() throws {
        let outcome = try reduce(["a"], [item("a", .succeeded), item("a", .succeeded)])
        XCTAssertEqual(outcome.status, .failure)
        XCTAssertEqual(outcome.counts.failed, 1)
        XCTAssertTrue(outcome.issues.contains { $0.code == "operation.result.duplicate" })
    }

    func testUnexpectedSubjectCannotMakeRequestSuccessful() throws {
        let outcome = try reduce(["a"], [item("a", .succeeded), item("outside", .succeeded)])
        XCTAssertEqual(outcome.status, .partial)
        XCTAssertTrue(outcome.issues.contains { $0.code == "operation.result.unexpected" })
    }

    func testEmptyRequestIsRejected() {
        XCTAssertThrowsError(try reduce([], [])) { error in
            XCTAssertEqual(error as? OperationReductionError, .emptyRequest)
        }
    }

    func testDuplicateRequestedSubjectIsRejected() {
        XCTAssertThrowsError(try reduce(["a", "a"], [])) { error in
            XCTAssertEqual(error as? OperationReductionError, .duplicateRequestedSubject("a"))
        }
    }

    func testFinishBeforeStartIsRejected() {
        XCTAssertThrowsError(try OperationOutcomeReducer.reduce(
            kind: kind, requestedSubjectIDs: ["a"], itemOutcomes: [item("a", .succeeded)],
            cancellationAccepted: false, startedAt: finish, finishedAt: start))
    }

    func testRetryKeepsNewIDAndParentID() throws {
        let parent = UUID(uuidString: "00000000-0000-0000-0000-000000000099")!
        let outcome = try reduce(["a"], [item("a", .succeeded)], parentID: parent)
        XCTAssertNotEqual(outcome.id, parent)
        XCTAssertEqual(outcome.parentID, parent)
    }
}
```

- [ ] **Step 2: Run the focused test and confirm the types do not exist**

Run: `swift test --filter OperationOutcomeReducerTests`

Expected: FAIL with compiler errors for `OperationKind`, `OperationDisposition`, and `OperationOutcomeReducer`.

- [ ] **Step 3: Implement the exact Domain contract and reducer**

Create `Sources/Domain/OperationOutcome.swift`. Use public value initializers only for inputs; keep the `OperationOutcome` initializer `fileprivate` so the reducer remains the only constructor in this file.

```swift
import Foundation

public struct OperationKind: RawRepresentable, Hashable, Codable, Sendable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ rawValue: String) { self.rawValue = rawValue }
}

public enum OperationTerminalStatus: String, Codable, Hashable, Sendable {
    case success, partial, failure, cancelled
}

public enum OperationIssueCategory: String, Codable, Hashable, Sendable {
    case permission, safetyPolicy, notFound, identityChanged, io, network
    case authentication, validation, timeout, unavailable, internalInvariant
}

public enum OperationRecoveryHint: String, Codable, Hashable, Sendable {
    case retry, grantPermission, installHelper, reauthenticate, chooseAnotherTarget
    case revealInFinder, openSettings, manualAction, none
}

public struct OperationIssue: Codable, Hashable, Sendable {
    public let code: String
    public let category: OperationIssueCategory
    public let subjectID: String?
    public let recovery: OperationRecoveryHint
    public let retryable: Bool
    public init(code: String, category: OperationIssueCategory, subjectID: String?,
                recovery: OperationRecoveryHint, retryable: Bool) {
        self.code = code
        self.category = category
        self.subjectID = subjectID
        self.recovery = recovery
        self.retryable = retryable
    }
}

public enum OperationDisposition: Sendable, Equatable {
    case succeeded
    case unchanged
    case skipped(OperationIssue)
    case failed(OperationIssue)
    case cancelled(OperationIssue?)
}

public struct OperationItemOutcome: Sendable, Equatable {
    public let subjectID: String
    public let disposition: OperationDisposition
    public let affectedBytes: Int64
    public init(subjectID: String, disposition: OperationDisposition, affectedBytes: Int64 = 0) {
        self.subjectID = subjectID
        self.disposition = disposition
        self.affectedBytes = max(0, affectedBytes)
    }
}

public struct OperationCounts: Codable, Equatable, Sendable {
    public let requested: Int
    public let succeeded: Int
    public let unchanged: Int
    public let skipped: Int
    public let failed: Int
    public let cancelled: Int
    public init(requested: Int, succeeded: Int, unchanged: Int,
                skipped: Int, failed: Int, cancelled: Int) {
        self.requested = requested
        self.succeeded = succeeded
        self.unchanged = unchanged
        self.skipped = skipped
        self.failed = failed
        self.cancelled = cancelled
    }
}

public struct OperationOutcome: Codable, Identifiable, Sendable {
    public let id: UUID
    public let parentID: UUID?
    public let kind: OperationKind
    public let status: OperationTerminalStatus
    public let counts: OperationCounts
    public let startedAt: Date
    public let finishedAt: Date
    public let issues: [OperationIssue]
    public var hasChanges: Bool { counts.succeeded > 0 }

    fileprivate init(id: UUID, parentID: UUID?, kind: OperationKind,
                     status: OperationTerminalStatus, counts: OperationCounts,
                     startedAt: Date, finishedAt: Date, issues: [OperationIssue]) {
        self.id = id
        self.parentID = parentID
        self.kind = kind
        self.status = status
        self.counts = counts
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.issues = issues
    }
}

public struct OperationResult<Payload: Sendable>: Sendable {
    public let outcome: OperationOutcome
    public let payload: Payload
    public init(outcome: OperationOutcome, payload: Payload) {
        self.outcome = outcome
        self.payload = payload
    }
}

public struct OperationProgress: Sendable, Equatable {
    public let completed: Int
    public let requested: Int
    public let affectedBytes: Int64
    public init(completed: Int, requested: Int, affectedBytes: Int64) {
        self.completed = completed
        self.requested = requested
        self.affectedBytes = max(0, affectedBytes)
    }
}

public enum OperationLifecycle<Payload: Sendable>: Sendable {
    case idle
    case running(OperationProgress)
    case cancelling(OperationProgress)
    case terminal(OperationResult<Payload>)
}

public enum OperationReductionError: Error, Equatable, Sendable {
    case emptyRequest
    case duplicateRequestedSubject(String)
    case invalidTimeRange
}

public enum OperationOutcomeReducer {
    public static func reduce(
        id: UUID = UUID(), parentID: UUID? = nil, kind: OperationKind,
        requestedSubjectIDs: [String], itemOutcomes: [OperationItemOutcome],
        cancellationAccepted: Bool, startedAt: Date, finishedAt: Date
    ) throws -> OperationOutcome {
        guard !requestedSubjectIDs.isEmpty else { throw OperationReductionError.emptyRequest }
        guard finishedAt >= startedAt else { throw OperationReductionError.invalidTimeRange }

        var requestedSet = Set<String>()
        for subjectID in requestedSubjectIDs {
            guard requestedSet.insert(subjectID).inserted else {
                throw OperationReductionError.duplicateRequestedSubject(subjectID)
            }
        }

        let grouped = Dictionary(grouping: itemOutcomes, by: \.subjectID)
        var normalized: [OperationDisposition] = []
        var issues: [OperationIssue] = []
        var hasInvariantViolation = false

        for subjectID in requestedSubjectIDs {
            let values = grouped[subjectID] ?? []
            if values.isEmpty {
                if cancellationAccepted {
                    normalized.append(.cancelled(nil))
                } else {
                    let issue = OperationIssue(code: "operation.result.missing",
                                               category: .internalInvariant,
                                               subjectID: subjectID,
                                               recovery: .retry, retryable: true)
                    normalized.append(.failed(issue))
                    issues.append(issue)
                    hasInvariantViolation = true
                }
            } else if values.count > 1 {
                let issue = OperationIssue(code: "operation.result.duplicate",
                                           category: .internalInvariant,
                                           subjectID: subjectID,
                                           recovery: .retry, retryable: true)
                normalized.append(.failed(issue))
                issues.append(issue)
                hasInvariantViolation = true
            } else {
                normalized.append(values[0].disposition)
            }
        }

        for subjectID in grouped.keys where !requestedSet.contains(subjectID) {
            issues.append(OperationIssue(code: "operation.result.unexpected",
                                         category: .internalInvariant,
                                         subjectID: subjectID,
                                         recovery: .none, retryable: false))
            hasInvariantViolation = true
        }

        var succeeded = 0, unchanged = 0, skipped = 0, failed = 0, cancelled = 0
        for disposition in normalized {
            switch disposition {
            case .succeeded: succeeded += 1
            case .unchanged: unchanged += 1
            case let .skipped(issue): skipped += 1; issues.append(issue)
            case let .failed(issue): failed += 1; issues.append(issue)
            case let .cancelled(issue): cancelled += 1; if let issue { issues.append(issue) }
            }
        }

        let counts = OperationCounts(requested: requestedSubjectIDs.count,
                                     succeeded: succeeded, unchanged: unchanged,
                                     skipped: skipped, failed: failed, cancelled: cancelled)
        let status: OperationTerminalStatus
        if cancellationAccepted {
            status = .cancelled
        } else if hasInvariantViolation && succeeded + unchanged == requestedSubjectIDs.count {
            status = .partial
        } else if failed + skipped + cancelled == 0 {
            status = .success
        } else if succeeded + unchanged > 0 {
            status = .partial
        } else {
            status = .failure
        }

        return OperationOutcome(id: id, parentID: parentID, kind: kind, status: status,
                                counts: counts, startedAt: startedAt, finishedAt: finishedAt,
                                issues: Array(Set(issues)).sorted {
                                    ($0.subjectID ?? "", $0.code) < ($1.subjectID ?? "", $1.code)
                                })
    }
}
```

- [ ] **Step 4: Run focused reducer tests**

Run: `swift test --filter OperationOutcomeReducerTests`

Expected: PASS, 13 tests, 0 failures.

- [ ] **Step 5: Run Domain regression and commit**

Run: `swift test --filter DomainTests`

Expected: all DomainTests pass, 0 failures.

Commit:

```bash
git add Sources/Domain/OperationOutcome.swift Tests/DomainTests/OperationOutcomeReducerTests.swift
git commit -m "feat: add operation outcome reducer"
```

---

### Task 2: Migrate CleaningReport to Item Facts

**Files:**
- Modify: `Sources/Domain/Models.swift`
- Modify: `Sources/Domain/CleaningEngine.swift`
- Modify: `Tests/DomainTests/CleaningEngineTests.swift`
- Modify: `Tests/IntegrationTests/CleaningRoundTripTests.swift`

- [ ] **Step 1: Add failing assertions for success, unchanged, skip, failure and cancellation**

Extend `Tests/DomainTests/CleaningEngineTests.swift` with injectable filesystem behavior and these exact behavioral assertions:

```swift
func testMissingPathIsUnchangedRatherThanSilentlyDropped() async {
    let url = URL(fileURLWithPath: "/tmp/missing")
    let engine = CleaningEngine(safety: AllowAllSafety(), fs: MemoryFS(existing: []))
    let item = CleanableItem(url: url, displayName: "missing", size: 10)
    let report = await engine.execute(CleaningPlan(items: [item], intent: .trash))
    XCTAssertEqual(report.operation.status, .success)
    XCTAssertEqual(report.operation.counts.unchanged, 1)
    XCTAssertEqual(report.items.single?.disposition, .unchanged)
}

func testSafetyDenialIsSkippedAndFailsSingleItemOperation() async {
    let url = URL(fileURLWithPath: "/tmp/denied")
    let engine = CleaningEngine(safety: DenyAllSafety(), fs: MemoryFS(existing: [url.path]))
    let report = await engine.execute(CleaningPlan(
        items: [CleanableItem(url: url, displayName: "denied", size: 10)], intent: .trash))
    XCTAssertEqual(report.operation.status, .failure)
    XCTAssertEqual(report.operation.counts.skipped, 1)
}

func testFilesystemErrorIsFailedAndRetainsItem() async {
    let url = URL(fileURLWithPath: "/tmp/io-error")
    let engine = CleaningEngine(safety: AllowAllSafety(),
                                fs: ThrowingFS(existing: [url.path], failing: [url.path]))
    let report = await engine.execute(CleaningPlan(
        items: [CleanableItem(url: url, displayName: "io", size: 10)], intent: .trash))
    XCTAssertEqual(report.operation.status, .failure)
    XCTAssertEqual(report.operation.counts.failed, 1)
    XCTAssertEqual(report.items.single?.url, url)
}

func testCancellationProducesDispositionForEveryRequestedItem() async {
    let urls = (0..<3).map { URL(fileURLWithPath: "/tmp/cancel-\($0)") }
    let fs = SuspendingFS(existing: Set(urls.map(\.path)))
    let engine = CleaningEngine(safety: AllowAllSafety(), fs: fs)
    let task = Task { await engine.execute(CleaningPlan(items: urls.map {
        CleanableItem(url: $0, displayName: $0.lastPathComponent, size: 10)
    }, intent: .trash)) }
    await fs.waitUntilFirstMutation()
    task.cancel()
    await fs.resume()
    let report = await task.value
    XCTAssertEqual(report.operation.status, .cancelled)
    XCTAssertEqual(report.operation.counts.requested, 3)
    XCTAssertEqual(report.items.count, 3)
    XCTAssertGreaterThan(report.operation.counts.cancelled, 0)
}
```

Add a private `Array.single` test helper that returns the only element or nil. The fake filesystems must record attempted paths and never access the real user Trash.

- [ ] **Step 2: Run focused tests and confirm the new report API is absent**

Run: `swift test --filter CleaningEngineTests`

Expected: FAIL because `CleaningReport.operation`, `CleaningReport.items`, `DenyAllSafety`, and deterministic cancellation fakes do not exist.

- [ ] **Step 3: Replace CleaningReport storage with operation plus items**

In `Sources/Domain/Models.swift`, replace stored aggregates with:

```swift
public struct CleaningItemResult: Sendable {
    public let itemID: UUID
    public let url: URL
    public let disposition: OperationDisposition
    public let reclaimedBytes: Int64
    public let restorable: RestorableItem?
    public init(itemID: UUID, url: URL, disposition: OperationDisposition,
                reclaimedBytes: Int64, restorable: RestorableItem?) {
        self.itemID = itemID
        self.url = url
        self.disposition = disposition
        self.reclaimedBytes = max(0, reclaimedBytes)
        self.restorable = restorable
    }
}

public struct CleaningReport: Sendable {
    public let operation: OperationOutcome
    public let items: [CleaningItemResult]
    public init(operation: OperationOutcome, items: [CleaningItemResult]) {
        self.operation = operation
        self.items = items
    }
    public var removedCount: Int { operation.counts.succeeded }
    public var reclaimedBytes: Int64 {
        items.reduce(0) { $0 + ($1.disposition == .succeeded ? $1.reclaimedBytes : 0) }
    }
    public var failures: [CleaningFailure] {
        items.compactMap { item in
            switch item.disposition {
            case let .failed(issue), let .skipped(issue):
                return CleaningFailure(url: item.url, reason: issue.code)
            default: return nil
            }
        }
    }
    public var restorable: [RestorableItem] {
        items.compactMap { $0.disposition == .succeeded ? $0.restorable : nil }
    }
}
```

Do not retain the old `CleaningReport(removedCount:reclaimedBytes:failures:restorable:)` initializer after all compile errors in Tasks 3–5 are migrated.

- [ ] **Step 4: Make CleaningEngine append exactly one item result per requested item**

Refactor `CleaningEngine.execute` around a private `executeItem` method. Use `item.id.uuidString` as the reducer subject ID. Map outcomes exactly:

- informational or SafetyEngine denial → `.skipped` with stable nonlocalized code;
- target absent immediately before execution → `.unchanged`;
- helper missing/intent mismatch/helper failure → `.failed`;
- successful trash/permanent removal → `.succeeded` with measured/estimated bytes and receipt;
- thrown filesystem error → `.failed`;
- after accepted `Task.isCancelled`, every not-yet-started requested item → `.cancelled(nil)`.

At method entry capture `startedAt`; at exit call exactly:

```swift
let operationItems = results.map {
    OperationItemOutcome(subjectID: $0.itemID.uuidString,
                         disposition: $0.disposition,
                         affectedBytes: $0.reclaimedBytes)
}
let operation = try! OperationOutcomeReducer.reduce(
    kind: OperationKind("cleaning.execute"),
    requestedSubjectIDs: plan.items.map { $0.id.uuidString },
    itemOutcomes: operationItems,
    cancellationAccepted: cancellationAccepted,
    startedAt: startedAt,
    finishedAt: Date())
return CleaningReport(operation: operation, items: results)
```

The `try!` is permitted only because `CleaningPlan` construction and one-result-per-item are internal invariants enforced in the same function; add `precondition(Set(ids).count == ids.count)` before the loop. If `CleanableItem.id` can collide through copying, replace this with a nonthrowing internal invariant factory that returns failure rather than trapping.

- [ ] **Step 5: Run focused and round-trip tests**

Run: `swift test --filter CleaningEngineTests`

Expected: PASS, including cancellation and no real Trash mutation.

Run: `swift test --filter CleaningRoundTripTests`

Expected: PASS, 0 failures; real user Trash is never used by the new deterministic cancellation tests.

- [ ] **Step 6: Commit the report and engine facts**

```bash
git add Sources/Domain/Models.swift Sources/Domain/CleaningEngine.swift Tests/DomainTests/CleaningEngineTests.swift Tests/IntegrationTests/CleaningRoundTripTests.swift
git commit -m "fix: make cleaning outcomes item-complete"
```

---

### Task 3: Add Outcome Side-Effect Policy and One-Time Feedback

**Files:**
- Create: `Sources/Features/OutcomeSideEffectPolicy.swift`
- Create: `Tests/FeatureTests/OutcomeSideEffectPolicyTests.swift`

- [ ] **Step 1: Write the policy matrix as failing tests**

Create outcomes through the reducer; never add a test-only `OperationOutcome` initializer. Assert:

```swift
func testOnlyChangedSuccessAllowsSuccessFeedback() throws {
    XCTAssertEqual(policy(for: successChanged).successFeedback, .allowed)
    XCTAssertEqual(policy(for: successUnchanged).successFeedback, .suppressed)
    XCTAssertEqual(policy(for: partial).successFeedback, .suppressed)
    XCTAssertEqual(policy(for: failure).successFeedback, .suppressed)
    XCTAssertEqual(policy(for: cancelled).successFeedback, .suppressed)
}

func testPartialWithChangesWritesPartialHistoryAndAllowsRetry() throws {
    let decision = OutcomeSideEffectPolicy.evaluate(partial)
    XCTAssertEqual(decision.history, .record(status: .partial))
    XCTAssertTrue(decision.allowsRetry)
    XCTAssertTrue(decision.broadcastsInternalInvalidation)
}

func testFeedbackGateConsumesOperationOnlyOnce() async {
    let gate = OutcomeFeedbackGate()
    XCTAssertTrue(await gate.consume(successChanged.id))
    XCTAssertFalse(await gate.consume(successChanged.id))
}
```

- [ ] **Step 2: Confirm RED**

Run: `swift test --filter OutcomeSideEffectPolicyTests`

Expected: FAIL because `OutcomeSideEffectPolicy` and `OutcomeFeedbackGate` do not exist.

- [ ] **Step 3: Implement a pure policy and actor gate**

Create `Sources/Features/OutcomeSideEffectPolicy.swift`:

```swift
import Foundation
import Domain

enum OutcomeFeedbackPermission: Equatable { case allowed, suppressed }
enum OutcomeHistoryDecision: Equatable {
    case none
    case record(status: OperationTerminalStatus)
}

struct OutcomeSideEffectDecision: Equatable {
    let history: OutcomeHistoryDecision
    let successFeedback: OutcomeFeedbackPermission
    let allowsRetry: Bool
    let broadcastsInternalInvalidation: Bool
}

enum OutcomeSideEffectPolicy {
    static func evaluate(_ outcome: OperationOutcome) -> OutcomeSideEffectDecision {
        let changed = outcome.hasChanges
        return OutcomeSideEffectDecision(
            history: changed ? .record(status: outcome.status) : .none,
            successFeedback: outcome.status == .success && changed ? .allowed : .suppressed,
            allowsRetry: outcome.status == .partial || outcome.status == .failure || outcome.status == .cancelled,
            broadcastsInternalInvalidation: changed)
    }
}

actor OutcomeFeedbackGate {
    private var consumed: Set<UUID> = []
    func consume(_ operationID: UUID) -> Bool { consumed.insert(operationID).inserted }
}
```

- [ ] **Step 4: Run tests and commit**

Run: `swift test --filter OutcomeSideEffectPolicyTests`

Expected: PASS.

```bash
git add Sources/Features/OutcomeSideEffectPolicy.swift Tests/FeatureTests/OutcomeSideEffectPolicyTests.swift
git commit -m "feat: centralize operation side effects"
```

---

### Task 4: Persist Honest History and Migrate Legacy Records

**Files:**
- Modify: `Sources/Infrastructure/HistoryStore.swift`
- Modify: `Tests/IntegrationTests/HistoryStoreTests.swift`

- [ ] **Step 1: Add failing history migration and counting tests**

Add exact tests for:

```swift
func testLegacyRecordDecodesAsLegacyUnknownAndDoesNotCountAsSuccess() throws
func testPartialRecordPersistsCountsAndRestorableReceipts() throws
func testCancelledRecordWithChangesPersistsButDoesNotCountAsSuccessfulCleanup() throws
func testAllUnchangedOutcomeIsNotRecorded() throws
func testTotalSuccessfulCleanupsExcludesLegacyPartialFailureAndCancelled() throws
```

The legacy fixture must omit all new keys and include the current `id/date/module/reclaimedBytes/removedCount/restorable` fields. Assert byte totals remain readable while `totalSuccessfulCleanups == 0`.

- [ ] **Step 2: Confirm RED**

Run: `swift test --filter HistoryStoreTests`

Expected: FAIL because `HistoryOutcomeStatus`, counts and outcome-aware `record` do not exist.

- [ ] **Step 3: Add versioned history facts**

Add:

```swift
public enum HistoryOutcomeStatus: String, Codable, Sendable {
    case success, partial, failure, cancelled, legacyUnknown

    public init(_ status: OperationTerminalStatus) {
        switch status {
        case .success: self = .success
        case .partial: self = .partial
        case .failure: self = .failure
        case .cancelled: self = .cancelled
        }
    }
}
```

Extend `CleaningRecord` with `operationID`, `parentOperationID`, `operationKind`, `outcomeStatus`, and `counts`. Decode missing `outcomeStatus` as `.legacyUnknown`, missing IDs/kind/counts as nil. Add:

```swift
@discardableResult
public func record(module: String, report: CleaningReport, date: Date = Date()) -> UUID? {
    guard report.operation.hasChanges else { return nil }
    return insert(CleaningRecord(
        date: date, module: module,
        reclaimedBytes: report.reclaimedBytes,
        removedCount: report.removedCount,
        restorable: report.restorable,
        operationID: report.operation.id,
        parentOperationID: report.operation.parentID,
        operationKind: report.operation.kind.rawValue,
        outcomeStatus: HistoryOutcomeStatus(report.operation.status),
        counts: report.operation.counts))
}
```

Keep the old scalar `record` overload only for unrelated historical fixtures in this Task; mark it `@available(*, deprecated, message: "Use record(module:report:date:)")` and make it write `.legacyUnknown`. Remove production call sites in Task 5.

Change successful cleanup counting to `outcomeStatus == .success`; keep `totalReclaimedAllTime` as factual bytes changed across success/partial/cancelled.

- [ ] **Step 4: Run focused tests and commit**

Run: `swift test --filter HistoryStoreTests`

Expected: PASS, legacy fixture remains readable and does not count as success.

```bash
git add Sources/Infrastructure/HistoryStore.swift Tests/IntegrationTests/HistoryStoreTests.swift
git commit -m "fix: persist honest operation history"
```

---

### Task 5: Migrate Cleaning Consumers and Remove Aggregate Constructors

**Files:**
- Modify: `Sources/Features/ModuleSessionViewModel.swift`
- Modify: `Sources/Features/SmartScanHub.swift`
- Modify: `Sources/Features/ScanViews.swift`
- Modify: `Sources/Features/SettingsView.swift`
- Modify: `Sources/Domain/CleaningEngine.swift`
- Modify: `Sources/Domain/Models.swift`
- Modify: `Tests/FeatureTests/OutcomeSideEffectPolicyTests.swift`
- Modify: `Tests/IntegrationTests/CleaningRoundTripTests.swift`

- [ ] **Step 1: Add failing aggregation and consumer tests**

Test these behaviors through public view-model actions with injected `XicoEnvironment` fakes:

```swift
func testPartialCleaningRetainsFailedSelectionsAndRemovesOnlySucceededItems() async
func testPartialCleaningWritesPartialHistoryWithoutSuccessNotification() async
func testAllUnchangedCleaningDoesNotEnterCelebratoryCompletion() async
func testCancelledCleaningKeepsReceiptsForCompletedTrashItems() async
func testMixedIntentSmartScanMergesEveryRequestedDispositionExactlyOnce() async
```

Inject notification and history sinks; do not inspect global NotificationCenter side effects by timing sleeps.

- [ ] **Step 2: Confirm RED**

Run the new focused test class with `swift test --filter CleaningOutcomeConsumerTests`.

Expected: FAIL because consumers merge stored aggregates, remove all non-failure paths and notify whenever reclaimed bytes are positive.

- [ ] **Step 3: Add a reducer-backed report merge**

Add `CleaningReport.merging(_ reports: [CleaningReport], kind: OperationKind, parentID: UUID? = nil) throws`. It must concatenate `items`, reduce using all item IDs, set requested to the sum of child requested counts, and reject duplicate item IDs. `ModuleSessionViewModel` and `SmartScanHub` must call this API rather than summing `removedCount` and `failures`.

- [ ] **Step 4: Apply the side-effect decision at both consumers**

For both view models:

- set `lastReport` for every non-empty terminal outcome;
- remove only items whose disposition is `.succeeded` or `.unchanged`;
- call `history.record(module:report:)` only when policy says record;
- call `Notifier.notifyCleaningDone` and allow signature completion only after `OutcomeFeedbackGate.consume(operationID)` and `.allowed`;
- broadcast `.xicoDidClean` when policy says internal invalidation, independent of user success notification;
- retain failed/skipped/cancelled selections and expose only retryable subjects to retry;
- preserve successful trash receipts across partial/cancelled undo.

- [ ] **Step 5: Stop fabricating reports for historical undo**

Add `CleaningEngine.undo(_ items: [RestorableItem]) async -> UndoResult` and make `undo(_ report:)` delegate to it. `ScanViews` and `SettingsView` pass `CleaningRecord.restorable` directly; delete their `CleaningReport(removedCount:...)` construction.

- [ ] **Step 6: Remove every legacy CleaningReport constructor**

Run:

```bash
rg -n 'CleaningReport\(removedCount:' Sources Tests
```

Expected: no output.

Delete the compatibility initializer from `Models.swift`. Keep only reducer-backed `init(operation:items:)` and `merging`.

- [ ] **Step 7: Run focused, feature and full regressions**

Run:

```bash
swift test --filter CleaningOutcomeConsumerTests
swift test --filter CleaningRoundTripTests
swift test --filter HistoryStoreTests
swift test
swift build -c debug
swift build -c release
```

Expected: all pass, 0 failures.

- [ ] **Step 8: Commit consumer migration**

```bash
git add Sources/Domain/Models.swift Sources/Domain/CleaningEngine.swift Sources/Features/ModuleSessionViewModel.swift Sources/Features/SmartScanHub.swift Sources/Features/ScanViews.swift Sources/Features/SettingsView.swift Tests/FeatureTests/OutcomeSideEffectPolicyTests.swift Tests/IntegrationTests/CleaningRoundTripTests.swift
git commit -m "fix: consume reducer-backed cleaning facts"
```

---

### Task 6: Replace Cleaning Completion with Honest TaskOutcomeView

**Files:**
- Modify: `Sources/Features/SharedViews.swift`
- Create: `Tests/FeatureTests/TaskOutcomePresentationTests.swift`
- Modify: all `Sources/DesignSystem/Resources/*.lproj/Localizable.strings`

- [ ] **Step 1: Write failing pure presentation tests**

Extract `TaskOutcomePresentation` from an `OperationOutcome` and test status icon, title key, metric, actions and celebration permission for success changed、success unchanged、partial、failure、cancelled. Tests must assert partial/failure/cancelled use distinct icon plus text and never a checkmark-only/color-only state.

- [ ] **Step 2: Confirm RED**

Run: `swift test --filter TaskOutcomePresentationTests`

Expected: FAIL because the presentation type and `TaskOutcomeView` do not exist.

- [ ] **Step 3: Implement presentation and view**

Add a pure `TaskOutcomePresentation.make(outcome:affectedBytes:)` that returns localization keys and SF Symbol names. Replace `CompletionView`'s direct `TaskCompletionView` call with `TaskOutcomeView`:

- success+changed: `checkmark.circle.fill`, success semantic, optional signature animation;
- success+unchanged: `checkmark.circle`, neutral info semantic, static;
- partial: `exclamationmark.circle.fill`, warning semantic, retry/details/undo;
- failure: `xmark.octagon.fill`, error semantic, retry/recovery/details;
- cancelled: `stop.circle.fill`, neutral semantic, return/details/undo.

Gate `XAnnihilationBurst`, `XCelebrationBurst`, `XSound` and `XHaptic` behind `presentation.allowsCelebration && !reduceMotion`. With Reduce Motion, render the final state synchronously and do not create animation Tasks.

- [ ] **Step 4: Add exact strings to all 11 locales**

Add localized keys for four statuses, changed/unchanged detail, failed/skipped/cancelled counts, retry failed items, details, recovery and undo completed items. Preserve format placeholder parity across every locale.

- [ ] **Step 5: Run presentation, localization and accessibility regression**

Run:

```bash
swift test --filter TaskOutcomePresentationTests
swift test --filter LocalizationCoverageTests
swift test --filter TypeScaleTokenGuardTests
```

Expected: all pass, 0 failures.

- [ ] **Step 6: Commit the truthful outcome UI**

```bash
git add Sources/Features/SharedViews.swift Tests/FeatureTests/TaskOutcomePresentationTests.swift Sources/DesignSystem/Resources
git commit -m "feat: present honest operation outcomes"
```

---

### Task 7: Operation Facts Static Gates and Final Verification

**Files:**
- Create: `Tests/FeatureTests/OperationOutcomeArchitectureTests.swift`
- Modify: `docs/20-全量文档任务台账与95分验收矩阵-2026-07-16.md`

- [ ] **Step 1: Add source architecture tests**

The test scans production Swift sources and fails when:

- a feature constructs `OperationOutcome`;
- `CleaningReport(removedCount:` exists;
- a business page calls `TaskCompletionView` without a reducer-backed adapter;
- cleaning consumers call `Notifier.notifyCleaningDone` without `OutcomeSideEffectPolicy` in the same function;
- production history calls the deprecated scalar `record(module:reclaimedBytes:removedCount:)`.

- [ ] **Step 2: Run and fix every violation**

Run: `swift test --filter OperationOutcomeArchitectureTests`

Expected: PASS with zero ignored paths except the architecture test fixture strings themselves.

- [ ] **Step 3: Run the complete quality gate**

Run:

```bash
swift build -c debug
swift test
swift build -c release
scripts/quality_gate.sh
```

Expected: 0 failures; test count must be greater than the 373-test audit baseline; any skip is listed with its explicit environment reason.

- [ ] **Step 4: Self-review requirement coverage**

Verify and record:

- OUT-01…10 each map to at least one passing test.
- UI-OUT-01/02/05/06 each map to presentation or side-effect tests.
- `rg -n 'CleaningReport\(removedCount:|TaskCompletionView\(' Sources` contains no unreviewed business call site.
- No `TODO`, `TBD`, placeholder body or `fatalError` was introduced.
- All new public Sendable types compile under Swift 6 strict concurrency.

- [ ] **Step 5: Update the ledger with evidence, request code review and commit**

Update only the Operation Facts-related rows; mark `verified` only when all commands above pass. Request independent review, resolve all Critical/Important findings, rerun the complete gate, then commit:

```bash
git add Tests/FeatureTests/OperationOutcomeArchitectureTests.swift docs/20-全量文档任务台账与95分验收矩阵-2026-07-16.md
git commit -m "test: enforce operation outcome facts"
```
