# Xico Phase 0 Operation Facts Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 实现 OUT-01…10 的统一操作事实层，把 CleaningEngine、CleaningReport、清理历史和成功副作用迁移到 reducer 生成的 success/partial/failure/cancelled 事实，消除“按循环次数或回调次数算成功”。

**Architecture:** Domain 新增不可由 feature 任意构造的 `OperationOutcome` 与纯 reducer；每个执行器返回逐项 `OperationItemOutcome`，强类型业务报告只携带 payload；Infrastructure 只持久化 reducer 事实；Features 通过 `OutcomeSideEffectPolicy` 决定历史、通知和庆祝。迁移期间保留只读计算属性兼容现有展示，但旧聚合初始化器在本计划结束前删除。

**Tech Stack:** Swift 6、SwiftPM、Foundation、Swift Concurrency、SwiftUI、XCTest。

## Global Constraints

- 覆盖 requirement：OUT-01…10、UI-OUT-01…02、UI-OUT-05…06，以及工作包 P0-01、P0-02、P0-06、WF-01、WF-10。
- `OperationOutcome` 的业务初始化器不得 public；feature 不能手工写 status/counts/issues。
- `OperationOutcome` 只能 `Encodable`，不得通过 public/synthesized `Decodable` 边界重新构造；Infrastructure 的历史读取必须先解码 versioned DTO，再用 reducer 重建并交叉验证事实。
- “是否发生副作用”是 reducer-owned `OperationMutationFact`（`none/changed/possiblyChanged`），不得从状态、释放字节或回调次数倒推；失败/取消中的破坏性操作若无法证明未改变，必须保留 `possiblyChanged`。
- `requested == 0` 必须返回显式 reducer error，不得产生 success。
- reducer 必须把缺失、重复和意外 subject 变成 `internalInvariant`，不得丢弃或默认为成功。
- 一旦取消被接受，终态固定为 cancelled；已完成 disposition 和恢复 receipt 仍保留。
- `unchanged` 是目标已满足，不是副作用；不能触发清理通知、庆祝或成功次数。
- partial/failure/cancelled 不发送成功通知、不播放成功声触/粒子。
- 迁移旧 history 时使用 `legacyUnknown`，不得倒推为 success。
- 日志只记录 issue code 和数量；路径、URL、host 和 `localizedDescription` 默认 private。
- 每个 commit 只暂存该 Task 的精确文件。
- 本计划中的每条 `swift test` / `swift build` 命令都必须直接携带 `--disable-automatic-resolution --skip-update`；只使用已锁定且已缓存的 `Package.resolved`，缺缓存时标记 blocked，禁止联网解析或改写 lockfile。

**Migration release boundary:** Tasks 2–4 are compile/test checkpoints, not releasable product states: the still-unmigrated feature consumers can only use their compatibility surface to keep the package buildable. Do not package, install, deploy, notarize, publish or score this Phase until `2026-07-16-xico-phase0-outcome-workflows.md` Tasks 1–13 have migrated every sink/consumer and its Task 14 full gate passes. This boundary does not permit any new/modified execution path to fabricate success or lose item facts.

Task 3's policy/gate and Task 4's history schema are also non-releasable until **every** direct outcome consumer (`ModuleSessionViewModel`, `SmartScanHub`, `UninstallerModel`, `ShredderModel`, basket cleanup, maintenance, optimization, app-update checking, historical undo and every direct `TaskCompletionView` call site) has an explicit reducer-backed workflow. A compile-only compatibility path, a scalar history/notification overload, or a direct completion view is never release evidence.

## File Structure

### Domain facts

- Create `Sources/Domain/OperationOutcome.swift`: operation identifiers、disposition、reducer-owned `OperationMutationFact`、counts、outcome、reducer、merge 和 lifecycle；只编码，不直接解码。
- Modify `Sources/Domain/Models.swift`: `CleaningItemResult` 与基于 outcome/items 的 `CleaningReport`。
- Modify `Sources/Domain/CleaningEngine.swift`: 每个请求项恰好产生一个 disposition，取消诚实终态。

### Infrastructure facts

- Create `Sources/Infrastructure/HistoryPersistence.swift`: 同目录 `0600` staging + fsync + atomic replace + parent fsync、revision/CAS 与同 URL 多 store 协调。
- Modify `Sources/Infrastructure/HistoryStore.swift`: per-record schema v0/v1 DTO、degraded read-only preservation、operation/item/receipt validation、operationID idempotency 和拆分后的真实聚合 API。
- Modify `Sources/Infrastructure/Notifier.swift`: 只接受由 `OperationOutcome` 验证的 success+changed 通知请求；无 scalar overload。
- Modify `Sources/Infrastructure/XicoEnvironment.swift`: 注入 history/notifier sinks，测试不触达真实通知或历史目录。

### Feature policy and consumers

- Create `Sources/Features/OutcomeSideEffectPolicy.swift`: notification/celebration 分离的纯策略，以及 view-model-owned、per-channel、常量空间 operation-ID 消费门。
- Modify `Sources/Features/ModuleSessionViewModel.swift`: reducer merge、只移除 succeeded/unchanged、真实历史/通知。
- Modify `Sources/Features/SmartScanHub.swift`: 同上，保留混合 intent restorable。
- Modify `Sources/Features/SharedViews.swift` and every direct completion consumer: `TaskOutcomeView` 和状态语义；所有完成页只消费 reducer-backed workflow，零 direct `TaskCompletionView`。
- Modify `Sources/Features/ScanViews.swift`、`SettingsView.swift`: 历史撤销不伪造 CleaningReport。

### Tests

- Create `Tests/DomainTests/OperationOutcomeReducerTests.swift`.
- Modify `Tests/DomainTests/CleaningEngineTests.swift`.
- Modify `Tests/IntegrationTests/CleaningRoundTripTests.swift`.
- Modify `Tests/IntegrationTests/HistoryStoreTests.swift`.
- Create `Tests/IntegrationTests/NotifierTests.swift`.
- Create `Tests/FeatureTests/OutcomeSideEffectPolicyTests.swift`.
- Create `Tests/FeatureTests/CleaningOutcomeConsumerTests.swift`.
- Create `Tests/FeatureTests/TaskOutcomePresentationTests.swift`.
- Create `Tests/FeatureTests/OutcomeWorkflowAdapterTests.swift`.
- Modify `Tests/FeatureTests/LocalizationCoverageTests.swift` only through normal key discovery; do not suppress missing keys.

---

### Task 1: Add the Pure Operation Outcome Reducer

**Files:**
- Create: `Sources/Domain/OperationOutcome.swift`
- Create: `Tests/DomainTests/OperationOutcomeReducerTests.swift`

**Interfaces:**
- Produces: `OperationKind`, `OperationTerminalStatus`, `OperationIssueCategory`, `OperationRecoveryHint`, `OperationIssue`, `OperationDisposition`, `OperationItemOutcome`, `OperationCounts`, `OperationOutcome`, `OperationResult`, `OperationProgress`, `OperationLifecycle`, `OperationReductionError`, `OperationOutcomeReducer`.
- Consumes: no Infrastructure, SwiftUI, localized strings, OSLog, filesystem or network APIs.

- [x] **Step 1: Write reducer tests that cover every OUT invariant**

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

- [x] **Step 2: Run the focused test and confirm the types do not exist**

Run: `swift test --filter OperationOutcomeReducerTests --disable-automatic-resolution --skip-update`

Expected: FAIL with compiler errors for `OperationKind`, `OperationDisposition`, and `OperationOutcomeReducer`.

- [x] **Step 3: Implement the exact Domain contract and reducer**

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
                                issues: Array(Set(issues)).sorted { lhs, rhs in
                                    switch (lhs.subjectID, rhs.subjectID) {
                                    case (nil, .some): return true
                                    case (.some, nil): return false
                                    case let (.some(l), .some(r)) where l != r: return l < r
                                    default: break
                                    }
                                    if lhs.code != rhs.code { return lhs.code < rhs.code }
                                    if lhs.category.rawValue != rhs.category.rawValue {
                                        return lhs.category.rawValue < rhs.category.rawValue
                                    }
                                    if lhs.recovery.rawValue != rhs.recovery.rawValue {
                                        return lhs.recovery.rawValue < rhs.recovery.rawValue
                                    }
                                    return !lhs.retryable && rhs.retryable
                                })
    }
}
```

- [x] **Step 4: Run focused reducer tests**

Run: `swift test --filter OperationOutcomeReducerTests --disable-automatic-resolution --skip-update`

Expected: PASS, 13 tests, 0 failures.

- [x] **Step 5: Run Domain regression and commit**

Run: `swift test --filter DomainTests --disable-automatic-resolution --skip-update`

Expected: all DomainTests pass, 0 failures.

Commit:

```bash
git add Sources/Domain/OperationOutcome.swift Tests/DomainTests/OperationOutcomeReducerTests.swift
git commit -m "feat: add operation outcome reducer"
```

---

### Task 2: Migrate CleaningReport to Item Facts

**Files:**
- Modify: `Sources/Domain/OperationOutcome.swift`
- Modify: `Sources/Domain/Models.swift`
- Modify: `Sources/Domain/CleaningEngine.swift`
- Modify: `Tests/DomainTests/OperationOutcomeReducerTests.swift`
- Modify: `Tests/DomainTests/CleaningEngineTests.swift`
- Modify: `Tests/IntegrationTests/CleaningRoundTripTests.swift`

- [x] **Step 1: Add failing assertions for every item disposition, malformed plans and privileged postconditions**

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
    XCTAssertEqual(report.operation.counts.succeeded, 1)
    XCTAssertEqual(report.operation.counts.cancelled, 2)
    XCTAssertEqual(report.items.count, 3)
    XCTAssertEqual(report.items.map(\.disposition), [.succeeded, .cancelled(nil), .cancelled(nil)])
}

func testDuplicateTargetFailsClosedWithoutFilesystemMutation() async {
    let firstURL = URL(fileURLWithPath: "/tmp/duplicate-a")
    let secondURL = URL(fileURLWithPath: "/tmp/duplicate-b")
    let duplicateID = UUID()
    let fs = RecordingFS(existing: [firstURL.path, secondURL.path])
    let engine = CleaningEngine(safety: AllowAllSafety(), fs: fs)
    let report = await engine.execute(CleaningPlan(items: [
        CleanableItem(id: duplicateID, url: firstURL, displayName: "first", size: 10),
        CleanableItem(id: duplicateID, url: secondURL, displayName: "second", size: 10)
    ], intent: .trash))
    XCTAssertEqual(report.operation.status, .failure)
    XCTAssertEqual(report.operation.counts.requested, 2)
    XCTAssertEqual(report.operation.counts.failed, 2)
    XCTAssertEqual(report.items.count, 2)
    XCTAssertTrue(fs.mutatedPaths.isEmpty)
}

func testSameNormalizedPathWithDistinctItemIDsFailsClosed() async {
    let direct = URL(fileURLWithPath: "/tmp/duplicate-path")
    let equivalent = URL(fileURLWithPath: "/tmp/xico-parent/../duplicate-path")
    XCTAssertNotEqual(direct.path, equivalent.path)
    XCTAssertEqual(direct.standardizedFileURL.path, equivalent.standardizedFileURL.path)
    let fs = RecordingFS(existing: [direct.standardizedFileURL.path])
    let engine = CleaningEngine(safety: AllowAllSafety(), fs: fs)
    let report = await engine.execute(CleaningPlan(items: [
        CleanableItem(url: direct, displayName: "first", size: 10),
        CleanableItem(url: equivalent, displayName: "second", size: 10)
    ], intent: .trash))
    XCTAssertEqual(report.operation.status, .failure)
    XCTAssertEqual(report.operation.counts.failed, 2)
    XCTAssertTrue(fs.mutatedPaths.isEmpty)
}
```

Add these RED cases in the same file; each must assert the exact disposition, stable issue code, item count and absence/presence of mutation rather than only legacy aggregate fields:

- `testInformationalItemIsSkippedWithoutFilesystemMutation` → `cleaning.item.informational`.
- `testEmptyPlanFailsClosedWithoutFilesystemMutation` → failure, requested/failed/items all zero, issue `cleaning.request.empty`.
- `testMissingHelperFailsRequestedItem` → `cleaning.helper.unavailable`; helper and filesystem mutation counts stay zero.
- `testHelperIntentMismatchFailsWithoutCallingHelper` → `cleaning.helper.intentMismatch`.
- `testHelperReportedTargetFailureIsFailed` → `cleaning.helper.removalFailed`.
- `testHelperUnexpectedFailurePathFailsClosed` → `cleaning.helper.unexpectedFailurePath`.
- `testHelperTargetAndUnexpectedFailuresPreferInvariantFailure` → `cleaning.helper.unexpectedFailurePath`, with no reclaimed bytes or receipt.
- `testHelperClaimedSuccessWhileTargetExistsIsFailed` → `cleaning.helper.targetStillExists`.
- `testHelperVerifiedSuccessUsesExactZeroMeasuredBytes` → success, succeeded 1, reclaimed bytes exactly zero even when the scan estimate is nonzero.
- `testHelperVerifiedSuccessClampsNegativeMeasuredBytesToZero` → success with zero reclaimed bytes, never a negative aggregate.
- `testOverlappingDuplicateGroupsFailOnlyDuplicateMembersBeforeAnyDependencyCall` → three transitive duplicate members fail without `exists`/mutation/helper calls, one independent item executes once, and all four results remain in input order.

Migrate the three existing privileged tests to assert `operation` plus `items` and make their fakes model the real postcondition: a successful helper removes the requested target from the shared in-memory filesystem before returning. Add a two-item ordinary trash/permanent success assertion that proves results preserve input order, each carries its original `itemID`, request IDs are unique and distinct from the caller item IDs, and receipts attach only to the corresponding successful trash item. Add two separate executions reusing the same caller `itemID` and assert their per-occurrence request IDs differ. For failed/skipped results, assert each issue `subjectID` equals that result's request ID; code review must verify the same request ID is passed to `OperationItemOutcome` without adding a test-only production accessor.

Add a private `Array.single` test helper that returns the only element or nil. All filesystem fakes must be stateful, synchronized `Sendable` test doubles that record attempted paths and never access the real user Trash. Because `FileSystemService` mutation methods are synchronous, deterministic cancellation may use a private locked `@unchecked Sendable` test double with an `NSCondition`/checked-continuation handshake; document the lock invariant, handle waiter-first and mutation-first ordering, resume continuations outside the lock, and keep `NSCondition.lock()` calls in synchronous helpers to satisfy Swift 6 `noasync` checking. Make the test-facing `resume()` genuinely async so the required `await` is not redundant. Do not use sleeps, timing races, or test-only production APIs.

The two independent Task 2 reviews add these mandatory RED regressions before further production edits; do not weaken them to aggregate-only assertions:

- `testInternalFailureDuplicateRequestedSubjectsCannotDoubleCountSingleOutcome`: `requestedSubjectIDs == ["a", "a"]` plus one succeeded `a` must yield two failed occurrences, zero succeeded, issue `operation.request.duplicate`, and never reuse one fact twice.
- `testIssueOrderingUsesFullStableTuple`: issues use an Optional-tag total order (`nil` before every `.some`, including `.some("")`), then compare subject string, code, category, recovery and finally retryable with `false` before `true`.
- `testExternalClientCanReadFactsAndEncodeOutcome`: a real normal-import client compiled with local `swiftc -typecheck` can read `CleaningReport`/`CleaningItemResult` facts and encode `OperationOutcome`.
- `testExternalClientCannotConstructCleaningItemResult`: the same external client boundary cannot call the Domain-internal item-fact initializer.
- `testExternalClientCannotConstructFactBackedCleaningReport`: the same external client boundary cannot call `CleaningReport(operation:items:)`.
- `testExternalClientCannotRequireOperationOutcomeDecodable`: `OperationOutcome` satisfies the external `Encodable` use case but cannot satisfy a `Decodable` generic constraint; Task 4 owns DTO decoding and reducer rehydration.
- `testLegacyCompatibilityUsesFixedSentinelRatherThanAggregateSizedIDs`: a 4,097-count legacy report preserves the four display values while allocating one sentinel requested ID rather than count-proportional storage.
- `testLegacyAggregateSubjectIDsStayBoundedAtExtremeCounts`: `CleaningReport.legacyAggregateSubjectIDs` returns zero or one sentinel for `Int.max`/`Int64.max` inputs without overflow or proportional allocation.
- `testReclaimedByteTotalsSaturateAfterEverySuccessfulMutation`: two `Int64.max` successful items finish without trapping, keep both mutations/facts, and saturate progress/report totals at `Int64.max`.
- `testCancellationDuringLastPrivilegedItemWinsAfterHelperReturns`, `testCancellationDuringLastOrdinaryMutationWinsAfterMutationReturns`, and `testCancellationFromLastProgressCallbackWinsBeforeReduction`: a cancellation observed before terminal reduction wins even when the last item already succeeded; the succeeded disposition/receipt remains intact.
- `testConcurrentExecutionsOfSameTargetFailSecondBeforeAnyDependencyCall`: while the first helper call owns a standardized target path, a second execution fails with `cleaning.request.inFlight` before safety/filesystem/helper calls; releasing the first execution still returns its honest success.

- [x] **Step 2: Run focused tests and confirm the new report API is absent**

Run: `swift test --filter CleaningEngineTests --disable-automatic-resolution --skip-update`

Expected: FAIL for the intended missing report/item-fact APIs and behavior, not for malformed test helpers. Capture the relevant failing compiler/assertion output in the Task report before production edits.

- [x] **Step 3: Replace CleaningReport storage with operation plus items**

In `Sources/Domain/Models.swift`, replace stored aggregates with the following. The two fact-backed initializers intentionally have internal access; feature targets can inspect facts but cannot forge a report. Use one shared nonnegative saturating byte helper in both `CleaningReport` and `CleaningEngine` so aggregation cannot trap after a destructive side effect:

```swift
func saturatedNonnegativeSum(_ lhs: Int64, _ rhs: Int64) -> Int64 {
    let (sum, overflow) = max(0, lhs).addingReportingOverflow(max(0, rhs))
    return overflow ? .max : sum
}

public struct CleaningItemResult: Sendable {
    public let requestID: UUID
    public let itemID: UUID
    public let url: URL
    public let disposition: OperationDisposition
    public let reclaimedBytes: Int64
    public let restorable: RestorableItem?
    init(requestID: UUID, itemID: UUID, url: URL,
         disposition: OperationDisposition, reclaimedBytes: Int64,
         restorable: RestorableItem?) {
        self.requestID = requestID
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
    private let legacy: LegacyCleaningCompatibility?

    init(operation: OperationOutcome, items: [CleaningItemResult]) {
        self.operation = operation
        self.items = items
        self.legacy = nil
    }

    public var removedCount: Int { legacy?.removedCount ?? operation.counts.succeeded }
    public var reclaimedBytes: Int64 {
        if let legacy { return legacy.reclaimedBytes }
        return items.reduce(0) {
            saturatedNonnegativeSum(
                $0, $1.disposition == .succeeded ? $1.reclaimedBytes : 0)
        }
    }
    public var failures: [CleaningFailure] {
        if let legacy { return legacy.failures }
        return items.compactMap { item in
            switch item.disposition {
            case let .failed(issue), let .skipped(issue):
                return CleaningFailure(url: item.url, reason: issue.code)
            default: return nil
            }
        }
    }
    public var restorable: [RestorableItem] {
        if let legacy { return legacy.restorable }
        return items.compactMap { $0.disposition == .succeeded ? $0.restorable : nil }
    }

    // Transitional only; remove in outcome-workflows Task 4 after every production constructor is migrated.
    public init(removedCount: Int, reclaimedBytes: Int64,
                failures: [CleaningFailure], restorable: [RestorableItem]) {
        let startedAt = Date()
        let subjectIDs = Self.legacyAggregateSubjectIDs(
            removedCount: removedCount,
            reclaimedBytes: reclaimedBytes,
            failureCount: failures.count,
            restorableCount: restorable.count)
        self.operation = OperationOutcomeReducer.internalFailure(
            kind: OperationKind("cleaning.legacyAggregate"),
            requestedSubjectIDs: subjectIDs,
            code: "operation.legacy.unknown",
            startedAt: startedAt,
            finishedAt: startedAt)
        self.items = []
        self.legacy = LegacyCleaningCompatibility(
            removedCount: max(0, removedCount),
            reclaimedBytes: max(0, reclaimedBytes),
            failures: failures,
            restorable: restorable)
    }

    static func legacyAggregateSubjectIDs(
        removedCount: Int,
        reclaimedBytes: Int64,
        failureCount: Int,
        restorableCount: Int
    ) -> [String] {
        guard removedCount > 0
                || reclaimedBytes > 0
                || failureCount > 0
                || restorableCount > 0 else { return [] }
        return ["legacy-aggregate"]
    }
}

private struct LegacyCleaningCompatibility: Sendable {
    let removedCount: Int
    let reclaimedBytes: Int64
    let failures: [CleaningFailure]
    let restorable: [RestorableItem]
}
```

Because SwiftPM builds downstream targets even for a focused test, keep a **temporary compatibility initializer** for the still-unmigrated constructors in `ModuleSessionViewModel`, `SmartScanHub`, `ScanViews` and `SettingsView`. It must create an `operation.status == .failure` with issue code `operation.legacy.unknown`; it must never infer success. Preserve the four legacy display aggregates in a private compatibility payload so unchanged screens continue to compile until outcome-workflows Task 4 migrates them. Add a source comment naming that exact plan/task as the removal point. Do not annotate it with `@available(*, deprecated)` during the temporary migration because every unchanged Swift call site would emit a build warning; outcome-workflows Task 14's source architecture gate enforces its removal instead. Do not let new engine code or new tests call this initializer. Remove the compatibility payload and initializer in outcome-workflows Task 4 after the multiline source gate has no production matches.

Add an internal fail-closed constructor to `OperationOutcomeReducer` in `OperationOutcome.swift`; it remains inaccessible outside Domain and is the only fallback when Domain itself violates an invariant. Its exact parameters are `id: UUID = UUID()`, `parentID: UUID? = nil`, `kind: OperationKind`, `requestedSubjectIDs: [String]`, `itemOutcomes: [OperationItemOutcome] = []`, `cancellationAccepted: Bool = false`, `code: String`, `startedAt: Date`, and `finishedAt: Date`; it returns `OperationOutcome`.

Use the same private normalization/count/issue helpers as `reduce`. Preserve every uniquely matched disposition; missing/duplicate results fail closed. Before normalization, compute requested-ID frequencies without reducing them to a `Set`: every occurrence of a duplicated requested ID becomes `.failed` with `OperationIssue(code: "operation.request.duplicate", category: .internalInvariant, subjectID: duplicatedID, recovery: .retry, retryable: true)`, and no matching item outcome may be reused for those occurrences. Add `code` as an `internalInvariant` issue and clamp `finishedAt` to `startedAt`. Accepted cancellation wins; otherwise any uniquely preserved succeeded/unchanged fact yields partial, and zero completed facts yields failure. This factory can never return success.

Issue collection must deduplicate exact `OperationIssue` values and then apply a total deterministic order that first compares the Optional tag (`nil < .some`, so `nil` remains distinct from `.some("")`), then the present subject string, `code`, `category.rawValue`, `recovery.rawValue`, and finally `retryable` with an explicit `false`-before-`true` comparison (`Bool` is not `Comparable`). Never coalesce the Optional with `?? ""` and never sort only by subject/code after `Set` enumeration, because both forms lose the reviewed total order.

Refactor the existing reducer's normalization, counting and issue collection into private same-file helpers so `reduce` and `internalFailure` do not duplicate the business logic. Add focused reducer tests proving:

- a zero-request internal failure is `.failure`, has `requested == 0`, carries the supplied issue code and never becomes success;
- a nonempty invariant fallback preserves succeeded/unchanged/failed counts and the original disposition issues, adds `cleaning.reducer.invariant`, and returns `.partial` rather than erasing completed facts;
- accepted cancellation still wins in the fallback while preserving pre-cancellation succeeded/cancelled counts;
- `finishedAt` is clamped to `startedAt` rather than trapping or throwing;
- duplicate requested IDs cannot double-count one outcome, and issue ordering is stable across the full issue tuple.

Receipts stay in `CleaningItemResult`; the engine fallback must return those unchanged alongside the preserved outcome counts. This is the non-crashing fallback for an accidentally empty or internally inconsistent plan; callers still keep empty UI state idle/empty as required by OUT-03.

Change `OperationOutcome` conformance from `Codable` to `Encodable`. Its fileprivate business initializer remains the only direct construction boundary; do not add a custom/public `init(from:)`. Task 4 defines Infrastructure-owned DTOs, validates their schema and item facts, then calls the reducer with the persisted operation ID/timestamps. This closes the synthesized `Decodable` construction path without coupling Domain to persistence.

- [x] **Step 4: Make CleaningEngine append exactly one item result per requested item**

Refactor `CleaningEngine.execute` around a private `executeItem` method. At invocation start, wrap every plan occurrence in a private request value with a fresh `requestID`; retain `itemID` separately for UI correlation. Use `requestID.uuidString` as the reducer subject ID. Map outcomes exactly:

- informational or SafetyEngine denial → `.skipped` with stable nonlocalized code;
- target absent immediately before execution → `.unchanged`;
- helper missing/intent mismatch/helper failure → `.failed`;
- successful trash/permanent removal → `.succeeded` with measured/estimated bytes and receipt;
- thrown filesystem error → `.failed`;
- after accepted `Task.isCancelled`, every not-yet-started requested item → `.cancelled(nil)`.

At this accepted Task 2 checkpoint, `CleaningItemResult` does **not** yet store `DeleteIntent`. `CleaningEngine` still enforces that only a successful `.trash` execution may attach a receipt; permanent, failed, skipped, unchanged and cancelled results carry no receipt. The explicit per-item intent carrier and its no-default initializer migration are owned by the still-unchecked Task 3 below and must land before Task 4 history validation.

Use this exact issue contract; every non-nil `subjectID` is the private per-occurrence `requestID.uuidString`, never a path or display name:

| Condition | Code | Category | Recovery | Retryable |
|---|---|---|---|---:|
| informational item | `cleaning.item.informational` | `safetyPolicy` | `manualAction` | false |
| initial safety denial | `cleaning.safety.denied` | `safetyPolicy` | `chooseAnotherTarget` | false |
| safety recheck or permanent symlink identity change | `cleaning.safety.identityChanged` | `identityChanged` | `retry` | true |
| duplicate caller ID or normalized path | `cleaning.request.duplicateTarget` | `internalInvariant` | `chooseAnotherTarget` | false |
| target already owned by another in-flight execution | `cleaning.request.inFlight` | `internalInvariant` | `retry` | true |
| helper not installed | `cleaning.helper.unavailable` | `unavailable` | `installHelper` | true |
| helper used with non-permanent intent | `cleaning.helper.intentMismatch` | `validation` | `chooseAnotherTarget` | false |
| helper reports the requested target failed | `cleaning.helper.removalFailed` | `io` | `retry` | true |
| helper reports any unrequested path | `cleaning.helper.unexpectedFailurePath` | `internalInvariant` | `retry` | true |
| helper reports success but target still exists | `cleaning.helper.targetStillExists` | `io` | `retry` | true |
| local trash/remove throws | `cleaning.filesystem.operationFailed` | `io` | `retry` | true |

Before mutation, group requests by both `item.id` and `url.standardizedFileURL.path`. Any request participating in either duplicate group receives `.failed(OperationIssue(code: "cleaning.request.duplicateTarget", category: .internalInvariant, subjectID: request.requestID.uuidString, recovery: .chooseAnotherTarget, retryable: false))`; none of those targets reaches `FileSystemService`. This avoids both double deletion and a crash from caller-constructible duplicate UUIDs/paths.

Also reserve every non-duplicate standardized target path in actor-isolated `activeNormalizedPaths` before the first safety/filesystem/helper dependency. Reservation is per execution occurrence and released with `defer` on every terminal path. If a concurrent `execute` reaches an already-reserved path while the first execution is suspended in the helper, return the exact `cleaning.request.inFlight` failure above without calling safety, `exists`, mutation or helper. The actor's reentrancy at `await privileged.removeProtected` must never permit two success facts for one deletion.

For privileged deletion, first reject any failure URL whose standardized path is not the one requested, then reject a reported failure of the requested target, then require the target to be absent immediately after the helper returns. Only an empty failure list plus an absent target is success. Use `report.freedBytes` exactly after nonnegative normalization, including zero; never replace a zero measurement with the scan estimate.

Keep `results` in the same order and cardinality as `plan.items`. Precompute duplicate membership before the first filesystem/helper mutation. A duplicated occurrence is failed without reaching `exists`, `trash`, `remove`, or the helper; non-duplicated occurrences continue normally and still receive exactly one result.

After every item execution returns, after the progress callback, and immediately before reducer invocation, observe `Task.isCancelled`. Once observed, set `cancellationAccepted = true`; do not rewrite an already completed item's disposition. This makes cancellation win the terminal status even for the last ordinary mutation, the last suspended helper call, or cancellation initiated by the final progress callback, while preserving all completed receipts and byte facts.

Accumulate `reclaimedForProgress` with `saturatedNonnegativeSum`. A report containing multiple maximum-size successful facts must saturate to `Int64.max`, never trap after the filesystem/helper already mutated state.

Generate request IDs into a local set before any dependency call, regenerating on collision until every per-occurrence ID is unique; never assume caller item IDs are unique and never trap on a collision. Before generating requests, handle `plan.items.isEmpty` with an explicit early `CleaningReport(operation:items:)` whose `internalFailure` code is `cleaning.request.empty`; it must not call safety, filesystem, helper or progress dependencies.

At method entry capture `startedAt`; at exit call exactly:

```swift
let operationItems = results.map {
    OperationItemOutcome(subjectID: $0.requestID.uuidString,
                         disposition: $0.disposition,
                         affectedBytes: $0.reclaimedBytes)
}
let requestIDs = requests.map { $0.requestID.uuidString }
let finishedAt = Date()
let operation: OperationOutcome
do {
    operation = try OperationOutcomeReducer.reduce(
        kind: OperationKind("cleaning.execute"),
        requestedSubjectIDs: requestIDs,
        itemOutcomes: operationItems,
        cancellationAccepted: cancellationAccepted,
        startedAt: startedAt,
        finishedAt: finishedAt)
} catch {
    operation = OperationOutcomeReducer.internalFailure(
        kind: OperationKind("cleaning.execute"),
        requestedSubjectIDs: requestIDs,
        itemOutcomes: operationItems,
        cancellationAccepted: cancellationAccepted,
        code: "cleaning.reducer.invariant",
        startedAt: startedAt,
        finishedAt: finishedAt)
}
return CleaningReport(operation: operation, items: results)
```

No `try!`, `precondition`, `fatalError` or force unwrap is allowed in this path. An empty plan returns `internalFailure` with zero requested items, issue code `cleaning.request.empty`, and no side effects; feature callers continue to guard empty selections and must not present that internal result as a user-visible terminal state.

Replace the current public-path and public-`localizedDescription` OSLog statements in `CleaningEngine` with stable issue-code/count logging. Do not log paths, URLs, display names, denial reasons or localized error text from execute/undo; this Task touches the file and must satisfy the plan's privacy constraint rather than carrying the existing violation forward.

- [x] **Step 5: Run focused and round-trip tests**

Run: `swift test --filter CleaningEngineTests --disable-automatic-resolution --skip-update`

Expected: PASS, including cancellation and no real Trash mutation.

Run: `swift test --filter CleaningRoundTripTests --disable-automatic-resolution --skip-update`

Expected: PASS, 0 failures; real user Trash is never used by the new deterministic cancellation tests.

Run: `swift test --filter OperationOutcomeReducerTests --disable-automatic-resolution --skip-update`

Expected: PASS, including zero-request fallback, duplicate-request fallback, total issue ordering, bounded legacy compatibility and the real normal-import external compile boundaries.

Run: `swift test --filter OperationOutcomeReducerTests/testExternalClient --disable-automatic-resolution --skip-update`

Expected: PASS, 4 tests, proving external read/encode access remains available while external fact construction and `OperationOutcome: Decodable` remain unavailable. The fixtures compile as normal `import Domain` clients against the locally built module; source-text regex is not accepted as evidence for these type boundaries.

Run: `swift test --filter OperationOutcomeReducerTests/testLegacyAggregateSubjectIDsStayBoundedAtExtremeCounts --disable-automatic-resolution --skip-update`

Expected: PASS, 1 test; extreme legacy counts still produce at most one sentinel ID.

Run once before commit: `swift test --disable-automatic-resolution --skip-update`

Expected: the complete suite passes with no new warning; every skip retains an explicit environment reason.

Run: `rg -n 'Self\.log.*(\.path|displayName|localizedDescription|reason|privacy: \.public)' Sources/Domain/CleaningEngine.swift`

Expected: no output. Review every remaining `Self.log` call and confirm it contains only a stable issue code and aggregate count.

Run:

```bash
rg -n 'reclaimedForProgress \+=|items\.reduce\(0\).*reclaimedBytes' Sources/Domain
git diff --check
```

Expected: the `rg` command has no output and `git diff --check` exits 0. Re-run `swift test --filter CleaningEngineTests --disable-automatic-resolution --skip-update` after the cancellation/in-flight RED additions and confirm all last-item cancellation cases, concurrent ownership and saturating totals pass without sleeps. The external compile tests above, not a source-text regex, are the construction/`Decodable` boundary gate.

**Task 2 independent-review acceptance note:** the Task is not accepted merely because the original 22/7/17 focused counts pass. The current Task 2 report records 26 `OperationOutcomeReducerTests`, 28 `CleaningEngineTests`, 7 `CleaningRoundTripTests`, and a 423-test full suite with 15 explicit environment skips and 0 failures on HEAD `2dbfe87`. The final evidence includes all four real normal-import external compile tests plus the bounded extreme-count helper test above; the deleted source-regex fixtures are not acceptance evidence. All post-commit Critical/Important review regressions listed in Step 1 were RED before their fixes and are GREEN afterward. Before execution, read `.superpowers/sdd/xico-opfacts-task-2-report.md`; if a newer HEAD/report has higher counts, that newer evidence becomes the non-regression baseline and counts must never decrease. The report records exact commands/output and states that Tasks 3–4 remain non-releasable.

- [x] **Step 6: Commit the report and engine facts**

```bash
git add Sources/Domain/OperationOutcome.swift Sources/Domain/Models.swift Sources/Domain/CleaningEngine.swift Tests/DomainTests/OperationOutcomeReducerTests.swift Tests/DomainTests/CleaningEngineTests.swift Tests/IntegrationTests/CleaningRoundTripTests.swift
git commit -m "fix: make cleaning outcomes item-complete"
```

---

### Task 3: Add Outcome Side-Effect Policy and One-Time Feedback

**Files:**
- Modify: `Sources/Domain/OperationOutcome.swift`
- Modify: `Sources/Domain/Models.swift`
- Modify: `Sources/Domain/CleaningEngine.swift`
- Create: `Sources/Features/OutcomeSideEffectPolicy.swift`
- Modify: `Tests/DomainTests/OperationOutcomeReducerTests.swift`
- Modify: `Tests/DomainTests/CleaningEngineTests.swift`
- Create: `Tests/FeatureTests/OutcomeSideEffectPolicyTests.swift`

- [ ] **Step 1: Write reducer-owned mutation facts as failing tests**

Add Domain RED tests before production edits:

```swift
func testReducerAggregatesNoMutationAsNone() throws
func testReducerAggregatesConfirmedMutationAsChanged() throws
func testPossiblyChangedDominatesChangedAndCannotBeLostByFailure() throws
func testCancelledOutcomePreservesCompletedAndPossiblyChangedFacts() throws
func testCleaningThrownMutationAndAmbiguousHelperFailureArePossiblyChanged() async
func testCleaningItemResultCarriesExactDeleteIntentWithoutDefault() throws
func testOnlySucceededTrashFactCanCarryReceipt() async
```

`OperationItemOutcome` and `CleaningItemResult` must carry an explicit mutation fact; do not add a default that silently treats an unmigrated producer as safe. In the same RED/GREEN migration, add `public let intent: DeleteIntent` to `CleaningItemResult` and require `intent` in its Domain-internal initializer with **no default**. `CleaningEngine` passes the originating `CleaningPlan.intent` into every succeeded/unchanged/skipped/failed/cancelled fact from the same request occurrence. Map pre-dependency validation/skips/unchanged/unattempted cancellation to `.none`, verified successful trash/remove/helper deletion to `.changed`, and an error after a destructive dependency was invoked when post-state is not proven to `.possiblyChanged`. A receipt is accepted only for `intent == .trash && disposition == .succeeded`; every other intent/disposition combination must have `restorable == nil`.

- [ ] **Step 2: Write the complete policy and gate matrix as failing tests**

Create every `OperationOutcome` through `OperationOutcomeReducer`; never add a test-only business initializer. In `OutcomeSideEffectPolicyTests`, define one typed `evaluate(status:mutation:profile:recordsHistory:allowsSuccessNotification:hasInvariant:)` helper so every matrix row uses the same reducer setup. Add these exact policy tests:

```swift
func testSuccessChangedCelebratoryRecordsNotifiesCelebratesAndInvalidates() throws
func testSuccessChangedNotificationEligibleNeutralRecordsAndNotifiesWithoutCelebration() throws
func testSuccessChangedNotificationIneligibleNeutralNeverNotifiesOrCelebrates() throws
func testChangedHistoryIneligibleWorkflowDoesNotRecord() throws
func testSuccessUnchangedProducesNoSideEffects() throws
func testPartialChangedRecordsPartialWithoutFeedbackAndInvalidates() throws
func testPartialWithoutChangeProducesNoSideEffects() throws
func testFailureWithoutChangeProducesNoSideEffects() throws
func testCancelledChangedRecordsCancelledWithoutFeedbackAndInvalidates() throws
func testCancelledWithoutChangeProducesNoSideEffects() throws
func testInvariantChangedRecordsPartialWithoutFeedbackAndInvalidates() throws
func testInvariantWithoutChangeProducesNoSideEffects() throws
func testPossiblyChangedNeverCelebratesOrSendsSuccessNotification() throws
```

`history`, `successNotification` and `celebration` are separate decisions. `.neutral` controls celebration only; it never grants history or notification eligibility. A full changed neutral workflow may record or notify only when the corresponding explicit reviewed capability allows it. Cleaning/uninstall/shred may be history-capable; optimization, remote/server and other registry-ineligible work must not be forced into cleaning history merely because mutation is known or possible. Partial/failure/cancelled/invariant outcomes never send a **success** notification and never celebrate. Known/possible mutation records only when `recordsHistory == true`, while internal invalidation remains independent. These explicit capability arguments are non-releasable policy primitives; outcome-workflows Task 1 replaces all caller-selected semantics with a registry-only `evaluate(_ outcome:)` entry point.

Do not put `allowsRetry: Bool` on the policy decision. Retry is per occurrence and is derived by outcome-workflows Tasks 1 and 4 from `CleaningReport.items` plus the original ordered request list; a terminal status cannot answer which items are safe/retryable.

Add these exact actor-gate tests:

```swift
func testConcurrentConsumptionOfSameChannelSucceedsExactlyOnce() async
func testNotificationAndCelebrationChannelsEachConsumeOnce() async
func testHistoryCelebrationSoundAndInvalidationChannelsRemainIndependent() async
func testReregisteringSameOperationIDDoesNotResetConsumedChannels() async
func testRegisteringNewOperationRejectsOldOperationID() async
func testGateStorageRemainsConstantAcrossManyTerminalOperations() async
func testAppearanceCannotRegisterAnOperationOrReplayEffects() async
func testHistoricalOutcomeCannotRegisterOrConsumeLiveEffects() async
```

In async tests, bind every awaited value before passing it to an XCTest autoclosure; never write `XCTAssertTrue(await ...)`, which is rejected under Swift 6. Race the same-channel calls with a task group and assert the bound result contains exactly one `true`.

- [ ] **Step 3: Confirm RED**

Run:

```bash
swift test --filter OperationOutcomeReducerTests --disable-automatic-resolution --skip-update
swift test --filter CleaningEngineTests --disable-automatic-resolution --skip-update
swift test --filter OutcomeSideEffectPolicyTests --disable-automatic-resolution --skip-update
```

Expected: FAIL for the missing mutation fact, split policy fields and terminal-registration gate APIs—not for malformed test builders or Swift concurrency/autoclosure errors. Capture the failing symbols/assertions in the Task report.

- [ ] **Step 4: Add the reducer-owned mutation fact**

In Domain add:

```swift
public enum OperationMutationFact: String, Encodable, Hashable, Sendable {
    case none
    case changed
    case possiblyChanged
}
```

`OperationItemOutcome` requires `mutation: OperationMutationFact`. Add the same public read-only `mutation` property and the Step 1 `intent: DeleteIntent` property to `CleaningItemResult`; its Domain-internal initializer requires both arguments and gives neither a default. `OperationOutcome` stores the reducer result as `public let mutation`; aggregation precedence is `possiblyChanged > changed > none`. `hasChanges` remains a compatibility read and returns `mutation != .none`; new policy code reads `mutation` directly. The reducer must preserve `.possiblyChanged` through partial/failure/cancelled and invariant fallback. Update `CleaningEngine.result(for:intent:disposition:mutation:reclaimedBytes:restorable:)` so intent and mutation come from the same request execution, validate the receipt rule before construction, and pass the same mutation from `CleaningItemResult` into `OperationItemOutcome`—never derive intent/mutation later from bytes, receipt presence or disposition.

- [ ] **Step 5: Implement the pure split-channel policy**

Create `Sources/Features/OutcomeSideEffectPolicy.swift`:

```swift
import Foundation
import Domain

enum OutcomeWorkflowProfile: Equatable, Sendable { case celebratory, neutral }
enum OutcomeEffectPermission: Equatable, Sendable { case allowed, suppressed }
enum OutcomeHistoryDecision: Equatable, Sendable {
    case none
    case record(status: OperationTerminalStatus)
}

struct OutcomeSideEffectDecision: Equatable, Sendable {
    let history: OutcomeHistoryDecision
    let successNotification: OutcomeEffectPermission
    let celebration: OutcomeEffectPermission
    let broadcastsInternalInvalidation: Bool

    fileprivate init(history: OutcomeHistoryDecision,
                     successNotification: OutcomeEffectPermission,
                     celebration: OutcomeEffectPermission,
                     broadcastsInternalInvalidation: Bool) {
        self.history = history
        self.successNotification = successNotification
        self.celebration = celebration
        self.broadcastsInternalInvalidation = broadcastsInternalInvalidation
    }
}

enum OutcomeSideEffectPolicy: Sendable {
    static func evaluate(_ outcome: OperationOutcome,
                         profile: OutcomeWorkflowProfile,
                         recordsHistory: Bool,
                         allowsSuccessNotification: Bool) -> OutcomeSideEffectDecision {
        let mutated = outcome.mutation != .none
        let invariant = outcome.issues.contains { $0.category == .internalInvariant }
        let feedbackSafe = outcome.status == .success
            && outcome.mutation == .changed && !invariant
        return OutcomeSideEffectDecision(
            history: mutated && recordsHistory
                ? .record(status: invariant ? .partial : outcome.status) : .none,
            successNotification: feedbackSafe && allowsSuccessNotification ? .allowed : .suppressed,
            celebration: feedbackSafe && profile == .celebratory ? .allowed : .suppressed,
            broadcastsInternalInvalidation: mutated)
    }
}
```

All policy enums/structs are `Sendable`; `OutcomeSideEffectDecision` construction stays `fileprivate` so consumers cannot bypass evaluation. A history-capable `.possiblyChanged` outcome records and every `.possiblyChanged` invalidates, but none is notification/celebration safe. History-ineligible kinds never acquire a cleaning-history write from mutation alone.

- [ ] **Step 6: Implement a bounded view-model-owned per-channel gate**

Add to the same file:

```swift
enum OutcomeEffectChannel: Hashable, Sendable {
    case history
    case successNotification
    case celebration
    case successSoundHaptic
    case internalInvalidation
}

actor OutcomeFeedbackGate {
    private var currentOperationID: UUID?
    private var consumedChannels: Set<OutcomeEffectChannel> = []

    func registerTerminal(_ operationID: UUID) {
        guard currentOperationID != operationID else { return }
        currentOperationID = operationID
        consumedChannels.removeAll(keepingCapacity: true)
    }

    func consume(_ channel: OutcomeEffectChannel, for operationID: UUID) -> Bool {
        guard currentOperationID == operationID else { return false }
        return consumedChannels.insert(channel).inserted
    }
}
```

Each live view model owns one long-lived gate. It calls `registerTerminal` exactly when a newly executed operation transitions into terminal state—not in `onAppear`, not while rendering, not when loading historical records. Re-registering the same ID preserves consumed channels; registering a new ID drops the old ID and its bounded channel set, so storage remains one UUID plus the finite channel enum. History display/appearance never registers; a historical outcome never receives the live gate. Consumer execution may consume history/internal-invalidation channels, while TaskOutcomeView consumes celebration and successSoundHaptic before starting effects. No channel may register or reset the gate itself.

- [ ] **Step 7: Run focused and full tests, then commit**

Run:

```bash
swift test --filter OperationOutcomeReducerTests --disable-automatic-resolution --skip-update
swift test --filter CleaningEngineTests --disable-automatic-resolution --skip-update
swift test --filter OutcomeSideEffectPolicyTests --disable-automatic-resolution --skip-update
swift test --disable-automatic-resolution --skip-update
```

Expected: all pass with zero failures and zero new warnings. The complete policy matrix and concurrent gate tests are mandatory; Tasks 3–4 remain non-releasable even after this checkpoint.

```bash
git add Sources/Domain/OperationOutcome.swift Sources/Domain/Models.swift Sources/Domain/CleaningEngine.swift Sources/Features/OutcomeSideEffectPolicy.swift Tests/DomainTests/OperationOutcomeReducerTests.swift Tests/DomainTests/CleaningEngineTests.swift Tests/FeatureTests/OutcomeSideEffectPolicyTests.swift
git commit -m "feat: centralize operation side effects"
```

---

### Task 4: Persist Honest History and Migrate Legacy Records

**Files:**
- Create: `Sources/Infrastructure/HistoryPersistence.swift`
- Modify: `Sources/Infrastructure/HistoryStore.swift`
- Modify: `Tests/IntegrationTests/HistoryStoreTests.swift`

- [ ] **Step 1: Add failing schema/load-state and preservation tests**

Keep the existing no-`restorable` legacy fixture and add these exact RED tests before production edits:

```swift
func testLegacyRecordDecodesAsLegacyUnknownAndDoesNotCountAsSuccess() throws
func testPartiallyMigratedRecordNeverCountsAsSuccess() throws
func testUnknownFutureOutcomeStatusDoesNotDropOtherRecordsOrCountAsSuccess() throws
func testCorruptElementDoesNotEraseValidRecordsOrPermitArchiveOverwrite() throws
func testMalformedTopLevelArchiveRemainsByteForByteIntactAfterRejectedMutation() throws
func testUnsupportedFutureSchemaIsReadOnlyAndPreserved() throws
func testLoadingLegacyArchiveDoesNotEagerlyRewriteBytes() throws
func testV1PartialRecordMissingRequiredKeysIsCorrupt() throws
func testV1MalformedUUIDCountsNegativeFactsAndInconsistentStatusAreCorrupt() throws
func testDuplicateOperationIDsOnDiskNeverDoubleSuccessOrBytes() throws
```

The legacy fixture omits `schemaVersion` and all operation keys, so it is schema 0; it retains current `id/date/module/reclaimedBytes/removedCount/restorable` fields. Schema 0 remains displayable as `.legacyUnknown`, its nonnegative factual bytes remain readable, and it never counts as success. A missing archive is empty and writable. Any malformed top level, corrupt element, partially migrated element, unsupported future per-record schema, unknown future outcome status or duplicate operation ID makes the loaded store explicitly degraded read-only; preserve the original archive bytes, keep every independently valid/displayable record, reject mutations, and never rewrite on init.

Schema 1 is per record, not a single unvalidated top-level flag. `schemaVersion == 1` requires all v1 operation/item fields. Absent means legacy schema 0; greater than 1 is unsupported. Unknown future outcome values display as `.legacyUnknown` but are not trusted for success/bytes and put the archive in degraded read-only mode so a current binary cannot destroy future data.

- [ ] **Step 2: Add failing transaction, idempotency, aggregate and privacy tests**

Add these exact RED tests:

```swift
func testFailedWriteDoesNotMutateMemoryOrReturnCommittedID() throws
func testParentDirectoryFsyncFailureEntersDegradedReadOnlyAndReloadsVisibleArchive() throws
func testSuccessfulMutationIsImmediatelyVisibleAfterReload() throws
func testAtomicMigrationFailureLeavesLegacyArchiveUnchanged() throws
func testRecordingSameOperationIDTwiceIsIdempotent() throws
func testConflictingDuplicateOperationIDIsRejectedWithoutOverwrite() throws
func testConcurrentDuplicateOperationIDCommitsExactlyOnce() async throws
func testConcurrentSingleStoreMutationsPersistEveryCommittedRecord() async throws
func testTwoStoresForSameURLCannotLoseCommittedRecords() async throws
func testSucceededZeroByteChangeIsRecordedAndCountsAsSuccessfulCleanup() throws
func testCancelledWithoutChangesIsNotRecorded() throws
func testDecodedAllUnchangedSuccessCannotInflateSuccessfulCount() throws
func testPartialRecordPersistsCountsAndRestorableReceipts() throws
func testCancelledRecordWithChangesPersistsButDoesNotCountAsSuccessfulCleanup() throws
func testTotalSuccessfulCleanupsExcludesLegacyPartialFailureAndCancelled() throws
func testUpdateRestorablePreservesOperationFactsAcrossReload() throws
func testUpdateRestorableRejectsForgedChangedOrExpandedReceiptSet() throws
func testFirstUndoablePruningPreservesOperationFactsAcrossReload() throws
func testHistoryArchiveAndRecoveryFilesUsePrivatePermissions() throws
func testReceiptPathsAppearOnlyInProtectedReceiptFields() throws
func testPermanentAndOrdinaryMetadataPersistNoPaths() throws
```

Use injected persistence doubles for deterministic failed-write, compare-and-swap conflict and migration-failure tests. Tests must inspect both the current instance and a freshly loaded store. Never depend on timing sleeps or the real Application Support history.

- [ ] **Step 3: Confirm RED**

Run: `swift test --filter HistoryStoreTests --disable-automatic-resolution --skip-update`

Expected: FAIL for missing schema/load-state/transaction/idempotency APIs and assertions, not because the fixture or persistence double is malformed. Capture exact failures before implementation.

- [ ] **Step 4: Define per-record DTOs and fail-closed load states**

Add:

```swift
public enum HistoryOutcomeStatus: String, Codable, Sendable {
    case success, partial, failure, cancelled, legacyUnknown

    init(_ status: OperationTerminalStatus) {
        switch status {
        case .success: self = .success
        case .partial: self = .partial
        case .failure: self = .failure
        case .cancelled: self = .cancelled
        }
    }
}

enum HistoryArchiveState: Equatable, Sendable {
    case writable
    case degradedReadOnly(code: String)
}

private struct CleaningRecordDTO: Codable {
    let schemaVersion: Int?
    let id: String
    let date: Date
    let module: String
    let reclaimedBytes: Int64
    let removedCount: Int
    let restorable: [RestorableItem]? // schema 0 legacy field only; encode nil for schema 1
    let operation: HistoryOperationDTO?
    let items: [HistoryItemFactDTO]?
}
```

`HistoryOperationDTO` and `HistoryItemFactDTO` are Infrastructure-only `Codable` transport values. `HistoryItemFactDTO` persists request ID, delete intent, disposition/issue DTO, mutation fact, nonnegative affected bytes and one optional receipt; it does not persist a path for non-restorable permanent deletion. `CleaningRecordDTO.restorable` is decoded only for schema-0 compatibility and is always encoded as `nil` for schema 1; the public schema-1 `CleaningRecord.restorable` view is derived from validated item receipts, so the same URL pair is never duplicated into a second JSON path. The dedicated history archive is private storage (`0700` directory, archive/recovery/staging/lock files `0600`). Exact `originalURL`/`trashedURL` values are allowed only inside that canonical validated receipt field needed for undo (or the preserved schema-0 legacy `restorable` field while degraded/read-only); they are forbidden in ordinary metadata, issue text, logs, notifications and invalidation events. Do not add encryption or a new dependency in this phase; record encrypted receipt storage as a future hardening option only. `HistoryOperationDTO` persists ID/parent/kind/status/mutation/counts/issues/timestamps. Decode DTO strings manually so unknown enum values do not make `JSONDecoder` discard the entire array. Parse the top-level JSON array into raw elements first, then decode/validate each element independently; one corrupt element must not cause an all-or-nothing `[CleaningRecordDTO]` decode that erases valid siblings.

For schema 1, rebuild the operation with `OperationOutcomeReducer` using the decoded item DTOs and persisted IDs/timestamps, then require exact equality with DTO status/mutation/counts/issues. Reject malformed UUIDs, negative counts/bytes, count sums that differ from requested, duplicate/missing/unexpected request IDs, status/count inconsistencies, `removedCount != counts.succeeded`, bytes on any non-succeeded item, aggregate bytes that differ from the checked/saturating succeeded-item sum, and receipts not attached to the corresponding succeeded trash fact. `OperationOutcome` itself remains non-`Decodable`.

Extend the public read model `CleaningRecord` with schema version, operation ID/parent/kind, outcome status, mutation, counts and the validated item facts needed for audit/receipt cross-checking. Its full initializer, DTO-to-domain status mapping and generic insert path remain internal. Preserve raw input bytes and every valid record when load is degraded; no mutating API may silently replace corrupt/unsupported input with `[]`.

Define a public read-only `HistoryItemFact: Sendable, Equatable` for the validated per-item request ID, delete intent, disposition, mutation, affected bytes and optional receipt. Its initializer remains internal; `CleaningRecord.itemFacts` exposes `[HistoryItemFact]`, never the private DTO type.

- [ ] **Step 5: Implement injected durable persistence and serialized transactions**

Create `Sources/Infrastructure/HistoryPersistence.swift` with an injected protocol and a live same-directory atomic implementation:

```swift
struct HistoryRevision: Equatable, Sendable {
    let sha256: Data?       // nil means the archive did not exist
}

struct HistoryPersistenceSnapshot: Sendable {
    let data: Data?
    let revision: HistoryRevision
}

protocol HistoryPersistence: Sendable {
    func load() -> HistoryPersistenceSnapshot
    func commit(_ data: Data, expectedRevision: HistoryRevision) -> HistoryCommitResult
}

enum HistoryCommitResult: Sendable {
    case committed(newRevision: HistoryRevision)
    case conflict(latest: HistoryPersistenceSnapshot)
    case indeterminate(latest: HistoryPersistenceSnapshot?, code: String)
    case failed(code: String)
}
```

The live writer creates/corrects the history directory to POSIX `0700`; creates archive, lock, staging and recovery files as `0600`; writes a complete candidate to a uniquely named staging file in the same directory; loops until all bytes are written; `fsync`s the staging fd; atomically replaces/renames the archive; and `fsync`s the parent directory before returning committed. Encode/write/staging-fsync/replace failures that occur **before** the rename commit point return `.failed` and leave the original archive byte-for-byte unchanged. A parent-directory `fsync` failure occurs after the namespace may already expose the new archive and therefore must never claim the original is unchanged: reload under the same lock and return `.indeterminate(latest:code:)`, with the observed snapshot when readable. Remove or preserve any recovery artifact with mode `0600`. Log only stable code/count values; never log a path or `localizedDescription` as public.

Coordinate by canonical archive URL, not by `HistoryStore` object identity. Use the lock file/advisory lock plus revision compare-and-swap so concurrent calls in one store and two separately constructed stores for the same URL reload/reapply instead of last-writer-wins data loss. Do not hold the in-memory record lock while blocking on disk I/O.

Every mutation follows one transaction: derive candidate from the latest revision → validate/encode → persist/fsync candidate → publish candidate to in-memory state. Never publish the candidate or return a committed ID before `.committed`. On revision conflict, reload, reapply the operation-ID-aware mutation and retry at most 8 times; exhaustion returns `history.persistence.conflictExhausted` without changing memory. On `.indeterminate`, never retry or report success: if the returned snapshot validates, replace the read model with that exact observed disk snapshot (not the unverified candidate); otherwise retain the prior read model. In both cases transition the store to `degradedReadOnly(code: "history.persistence.durabilityUnknown")`, reject the mutation without a committed ID, and block later writes until an explicit successful reload/recovery. This makes current reads honest without pretending crash durability or rollback that POSIX cannot guarantee.

- [ ] **Step 6: Add explicit mutation results and operation-ID idempotency**

Use exact result types rather than nullable UUID/void ambiguity:

```swift
public enum HistoryRecordResult: Equatable, Sendable {
    case inserted(recordID: UUID)
    case alreadyRecorded(recordID: UUID)
    case notRecordedNoChanges
    case rejected(code: String)
}

public enum HistoryUpdateResult: Equatable, Sendable {
    case committed
    case notFound
    case rejected(code: String)
}
```

All typed adapters feed this Infrastructure-internal candidate; its initializer and transaction entry point are never public:

```swift
struct ValidatedHistoryRecordCandidate: Sendable {
    let module: String
    let date: Date
    let operation: OperationOutcome
    let itemFacts: [HistoryItemFact]
    let reclaimedBytes: Int64
    let removedCount: Int
}

private func recordValidated(
    _ candidate: ValidatedHistoryRecordCandidate
) -> HistoryRecordResult
```

`recordValidated` reruns the Task 4 count/status/mutation/bytes/receipt cross-check before the candidate→persist→publish transaction. At the Task 4 checkpoint, the only public record adapter is:

```swift
public func record(module: String, report: CleaningReport,
                   date: Date = Date()) -> HistoryRecordResult
```

Every typed adapter converts into one Infrastructure-internal `ValidatedHistoryRecordCandidate` and calls the same private candidate→persist→publish transaction; no public generic candidate/insert initializer exists. Outcome-workflows Task 2 may add the reviewed public `OperationResult<ShredderPayload>` adapter after defining that payload, but it must be a typed protocol witness that feeds this exact internal transaction rather than a second persistence path.

It returns `.notRecordedNoChanges` only for reducer mutation `.none`; zero-byte `.changed` is still a real record. Define idempotent equality over module plus every operation/item/receipt fact, excluding only the history record UUID and insertion `date`, so retrying the same report with a new default date is still identical. An existing identical operation ID returns its existing record ID as `.alreadyRecorded` without writing. The same operation ID with different immutable facts is `.rejected(code: "history.operation.conflict")`. Concurrent duplicates commit exactly once. Duplicate IDs loaded from disk make the archive degraded; identical duplicates contribute at most one canonical record to aggregates, while conflicting duplicates are untrusted `.legacyUnknown` and contribute no success/bytes.

`remove(id:)`, `updateRestorable(id:to:)`, `clearRestorable(id:)` and `clear()` return `HistoryUpdateResult` and use the same durable transaction. `updateRestorable` is remove-only: every supplied receipt must exactly equal one receipt already attached to that record's validated succeeded-trash item fact, duplicates/additions/changed URL pairs are rejected, and the method may only retain a subset or clear it. Keep any temporary scalar record overload only until outcome-workflows Tasks 4, 6 and 7 migrate all direct consumers; it always writes schema 0/`.legacyUnknown`, is not deprecated while compile compatibility is needed, and outcome-workflows Task 14 owns removal of the overload declaration after the last caller is gone. No public full-record initializer or generic `insert` is allowed.

- [ ] **Step 7: Split aggregates and preserve immutable facts during receipt updates**

Expose distinct APIs:

- `totalHistoryRecords`: number of displayable canonical records, independent of success semantics;
- `totalSuccessfulCleanups`: trusted schema-1 `.success` records with `mutation == .changed`, `counts.succeeded > 0`, a consistent item distribution and `removedCount == succeeded`;
- `totalReclaimedAllTime`: checked, nonnegative, saturating factual bytes from validated changed/possibly-changed v1 item facts plus readable nonnegative schema-0 legacy bytes. Unknown/corrupt/future/conflicting facts contribute zero.

An all-unchanged decoded “success” cannot increment successful cleanup count. A succeeded zero-byte mutation is recorded and counts as one successful cleanup. Cancelled-without-change is not recorded; cancelled-after-change is recorded as cancelled but never counts as success.

Implement one internal `CleaningRecord.updatingRestorable(_:)` copy method that copies every schema/operation/status/mutation/count/item field and changes only the exact remove-only validated receipt subset described above. Both explicit update and `firstUndoable` pruning must call it; reconstructing records through a shorter initializer is forbidden because it drops newly added facts. Pruning persists synchronously through the same transaction before returning the updated undoable record.

- [ ] **Step 8: Run focused, full and build gates**

Run:

```bash
swift test --filter HistoryStoreTests --disable-automatic-resolution --skip-update
swift test --disable-automatic-resolution --skip-update
swift build -c debug --disable-automatic-resolution --skip-update
rg -n 'localizedDescription.*privacy: \.public|history.*\.path.*privacy: \.public' Sources/Infrastructure/HistoryStore.swift Sources/Infrastructure/HistoryPersistence.swift
git diff --check
```

Expected: focused, full and debug build pass with zero failures and zero new warnings; privacy `rg` has no output; every schema/preservation/transaction/idempotency/two-store/permission test above is GREEN. Inspect temporary-directory modes and original bytes in the tests rather than trusting `.atomic` by name.

Task 4 remains a non-releasable persistence checkpoint. Do not package/install/deploy/notarize/publish, and do not call a partial Task 4 GREEN a completed Phase while scalar consumers or direct outcome UI remain.

- [ ] **Step 9: Commit the complete history transaction**

```bash
git add Sources/Infrastructure/HistoryPersistence.swift Sources/Infrastructure/HistoryStore.swift Tests/IntegrationTests/HistoryStoreTests.swift
git commit -m "fix: persist honest operation history"
```

---

## Consumer handoff and unique execution ownership

Tasks 1–4 above are the sole executable authority in this file. They own `OperationOutcome`, `OperationMutationFact`, reducer invariants, the base `OutcomeSideEffectPolicy`, the bounded long-lived `OutcomeFeedbackGate`, and durable history types. In particular, Task 3 is the only code owner for `OutcomeEffectChannel` and `OutcomeFeedbackGate`; outcome-workflows may test and consume that gate and add the kind registry around policy evaluation, but must not redeclare or replace the enum/actor.

Tasks 5–7 below are retained only as a **non-executable contract/trace handoff**. Do not edit production consumers, stage files or create the listed commits from this plan. The sole execution owner for every consumer/UI/static-gate item is `docs/superpowers/plans/2026-07-16-xico-phase0-outcome-workflows.md`:

- former Task 5 requirements execute in outcome-workflows Tasks 1, 2, 4, 6 and 7;
- former Task 6 requirements execute in outcome-workflows Tasks 3–13, including Task 4's two cleaning `CompletionView` consumers;
- former Task 7 requirements execute in outcome-workflows Task 14.

If the handoff text below conflicts with Tasks 1–4, Tasks 1–4 win for types/invariants. If it conflicts with outcome-workflows, outcome-workflows wins for consumer file scope, commands and commits. There is exactly one implementation/commit path; the checkboxes and commit snippets below are trace evidence only and must not be executed here.

### Task 5: Consumer Contract Handoff — Cleaning, Uninstaller and Shredder (Non-Executable Here)

**Files:**
- Modify: `Sources/Features/ModuleSessionViewModel.swift`
- Modify: `Sources/Features/SmartScanHub.swift`
- Modify: `Sources/Features/UninstallerView.swift`
- Modify: `Sources/Features/ShredderView.swift`
- Modify: `Sources/Features/ScanViews.swift`
- Modify: `Sources/Features/SettingsView.swift`
- Modify: `Sources/Domain/CleaningEngine.swift`
- Modify: `Sources/Domain/Models.swift`
- Modify: `Sources/Infrastructure/ShredderService.swift`
- Modify: `Sources/Infrastructure/HistoryStore.swift`
- Modify: `Sources/Infrastructure/Notifier.swift`
- Modify: `Sources/Infrastructure/XicoEnvironment.swift`
- Modify: `Tests/FeatureTests/OutcomeSideEffectPolicyTests.swift`
- Create: `Tests/FeatureTests/CleaningOutcomeConsumerTests.swift`
- Create: `Tests/IntegrationTests/NotifierTests.swift`
- Modify: `Tests/IntegrationTests/HistoryStoreTests.swift`
- Modify: `Tests/IntegrationTests/CleaningRoundTripTests.swift`

- [ ] **Step 1: Add failing aggregation and consumer tests**

Test these behaviors through public view-model actions with injected `XicoEnvironment` fakes:

```swift
func testPartialCleaningRetainsFailedSelectionsAndRemovesOnlySucceededItems() async
func testPartialCleaningWritesPartialHistoryWithoutSuccessNotification() async
func testAllUnchangedCleaningDoesNotEnterCelebratoryCompletion() async
func testCancelledCleaningKeepsReceiptsForCompletedTrashItems() async
func testMixedIntentSmartScanMergesEveryRequestedDispositionExactlyOnce() async
func testReportMergeRejectsPurposeMismatchAndCannotRelabelFacts() throws
func testUninstallerUsesReportFactsAndDoesNotClearFailedTargets() async
func testShredderSuccessUsesNeutralProfileAndNeverCelebrates() async
func testHistoricalUndoNeverRegistersOrConsumesLiveFeedback() async
```

Inject notification and history sinks; do not inspect global NotificationCenter side effects by timing sleeps.

Add a table-driven `retrySelection(original:report:)` suite with these exact cases:

```swift
func testRetrySelectionIncludesRetryableFailedItem() throws
func testRetrySelectionExcludesNonretryableSafetyDenial() throws
func testRetrySelectionIncludesMissingAndDuplicateInvariantOccurrences() throws
func testRetrySelectionExcludesUnexpectedUnrequestedSubject() throws
func testRetrySelectionIncludesCancelledUnattemptedOccurrences() throws
func testRetrySelectionIsEmptyWhenCancelledAfterAllOccurrencesCompleted() throws
```

Selection is per original occurrence and report item, never a terminal `allowsRetry` Boolean. Preserve original order; retry only failed/skipped issues marked retryable, requested missing/duplicate invariants that were not safely completed, and `.cancelled` unattempted occurrences. Exclude nonretryable safety policy items, unexpected subjects that were never requested, and every succeeded/unchanged occurrence even when the terminal outcome is cancelled.

Implement this as `CleaningRetrySelector.select(original: [CleanableItem], report: CleaningReport) -> [CleanableItem]`. Join each ordered original occurrence to the same-position/report correlation fact before consulting issue codes; never collapse by caller `itemID`. Missing/duplicate requested invariants retain their original occurrence, while an unexpected result with no original occurrence cannot create a retry target.

Add pure Infrastructure tests for notification validation:

```swift
func testValidatedCleaningNotificationAcceptsOnlySuccessChangedOutcome() throws
func testValidatedCleaningNotificationRejectsUnchangedPartialFailureCancelledAndInvariant() throws
func testValidatedCleaningNotificationRejectsShredRemoteAndUnknownKinds() throws
func testValidatedCleaningNotificationDerivesCountsAndBytesFromReport() throws
func testNotifierHasNoScalarReclaimedCountOverload() throws
```

- [ ] **Step 2: Confirm RED**

Run:

```bash
swift test --filter CleaningOutcomeConsumerTests --disable-automatic-resolution --skip-update
swift test --filter NotifierTests --disable-automatic-resolution --skip-update
swift test --filter HistoryStoreTests --disable-automatic-resolution --skip-update
```

Expected: FAIL because consumers merge stored aggregates, remove all non-failure paths, notify from scalar bytes/counts, and do not expose injected sinks/explicit mutation results. The failure must not come from a malformed environment fake.

- [ ] **Step 3: Add a reducer-backed report merge**

After outcome-workflows Task 1 defines the closed `CleaningOperationPurpose`, add `CleaningReport.merging(_ reports: [CleaningReport], purpose: CleaningOperationPurpose, parentID: UUID? = nil) throws`; do not expose a raw `OperationKind` parameter. It must require every child `report.operation.kind == purpose.operationKind` before concatenating facts, so standard cleaning cannot be relabeled as Space Trash/uninstall or vice versa. It then concatenates `items` in child/report order, reduces using every per-occurrence `requestID`, preserves each item's delete intent and mutation fact, sets requested to the sum of child requested counts, and rejects a purpose mismatch, duplicate request IDs or any fact/report inconsistency. Caller `itemID` is display/correlation metadata and may repeat; it is never reducer identity. Before launching any child execution, the consumer must run one parent-wide preflight over every standardized target path and fail every duplicate-path occurrence before any safety/filesystem/helper dependency. Merge preserves already-produced facts and is never an authorization, relabeling or duplicate-path safety boundary. `ModuleSessionViewModel` and `SmartScanHub` call it with `.standard` rather than summing `removedCount` and `failures`.

Outcome-workflows Task 2 creates these explicit shredder payload types once in `Sources/Infrastructure/ShredderPayload.swift`; outcome Task 7 makes `ShredderService` produce them and must not introduce `ShredReport` or another payload:

```swift
public struct ShredderItemResult: Sendable {
    public let requestID: UUID
    public let url: URL
    public let disposition: OperationDisposition
    public let mutation: OperationMutationFact
    public let freedBytes: Int64
}

public struct ShredderPayload: Sendable {
    public let items: [ShredderItemResult]
    public let freedBytes: Int64

    init(items: [ShredderItemResult]) {
        self.items = items
        self.freedBytes = items.reduce(0) { lhs, item in
            let (sum, overflow) = max(0, lhs).addingReportingOverflow(max(0, item.freedBytes))
            return overflow ? Int64.max : sum
        }
    }
}
```

The payload initializer remains Infrastructure-internal; Features can read but cannot forge item facts. Generate one private request ID per input URL, return one ordered item fact per URL through `OperationResult<ShredderPayload>`, mark verified removals `.changed`, pre-mutation refusals `.none`, and ambiguous post-overwrite/delete failures `.possiblyChanged`; cancellation supplies `.cancelled` for every unattempted URL. `ShredderModel` may not translate `shredded/failed/freedBytes` scalar totals into a synthetic success.

- [ ] **Step 4: Inject history and notification sinks through XicoEnvironment**

Define `public protocol OutcomeHistoryWriting: Sendable` with public requirements `record(module:report:date:) -> HistoryRecordResult` for `CleaningReport` and `record(module:result:date:) -> HistoryRecordResult` for `OperationResult<ShredderPayload>`, plus `remove(id:) -> HistoryUpdateResult` and remove-only `updateRestorable(id:to:) -> HistoryUpdateResult`. The protocol requirements make `date` explicit—default arguments on a concrete `HistoryStore` method are not available through `any OutcomeHistoryWriting`. Both record overloads convert to Task 4's internal `ValidatedHistoryRecordCandidate` and feed one transaction, and neither accepts scalar aggregates. Define `public protocol CleaningNotificationSending: Sendable` with `send(_ request: ValidatedCleaningNotification)`, and `public protocol OutcomeInvalidationPublishing: Sendable` with `publish(_ request: ValidatedOutcomeInvalidation) -> OutcomeInvalidationPublishResult`. `HistoryStore`, the live user-notification adapter and `OutcomeInvalidationCenter` expose public witnesses so the separate Features target can consume or fake them; DTO/candidate types remain internal/private. Extend `XicoEnvironment.init` with public injectable `history: HistoryStore`, `historySink: any OutcomeHistoryWriting`, `cleaningNotifier: any CleaningNotificationSending`, and `invalidationSink: any OutcomeInvalidationPublishing` defaults; live uses the same history store for read/write, while tests inject temporary stores and spies. No consumer calls static `Notifier`, constructs its own `HistoryStore`, or depends on a concrete invalidation center.

Replace the scalar notification API with:

```swift
public struct ValidatedCleaningNotification: Sendable {
    public let operationID: UUID
    public let reclaimedBytes: Int64
    public let changedCount: Int

    public init?(report: CleaningReport) {
        let outcome = report.operation
        guard OutcomeOperationRegistry.semantics(for: outcome.kind)?
                  .allowsCleaningSuccessNotification == true,
              outcome.status == .success,
              outcome.mutation == .changed,
              outcome.counts.succeeded > 0,
              !outcome.issues.contains(where: { $0.category == .internalInvariant }) else {
            return nil
        }
        operationID = outcome.id
        reclaimedBytes = report.reclaimedBytes
        changedCount = outcome.counts.succeeded
    }
}
```

`CleaningNotificationSending.send(_:)` accepts only this validated type. The failable initializer accepts the closed, reducer-backed `CleaningReport` rather than a caller-supplied bytes/count pair, so notification metrics cannot diverge from the validated operation facts. Registry eligibility permits only the reviewed `cleaningExecute` kind; shred, remote and unknown kinds fail construction even if they are full changed success. Remove every static or instance spelling of the old scalar API (`Notifier.notifyCleaningDone`, `notifier.cleaningDone`); no formatted string/count pair may cross the validation boundary.

- [ ] **Step 5: Apply policy and per-channel gate at every cleaning consumer**

For `ModuleSessionViewModel`, `SmartScanHub`, `UninstallerModel` and `ShredderModel`:

- store the typed `CleaningReport` or `OperationResult<ShredderPayload>` for every non-empty terminal outcome;
- remove only items whose disposition is `.succeeded` or `.unchanged`;
- when policy says record, Module/Smart/Uninstaller call `historySink.record(module:report:date: report.operation.finishedAt)` and Shredder calls `historySink.record(module:result:date: result.outcome.finishedAt)`; all handle `.inserted/.alreadyRecorded/.notRecordedNoChanges/.rejected` explicitly, and no existential call omits `date`;
- construct `ValidatedCleaningNotification(report:)` and send it only after policy `.successNotification == .allowed` and the view-model-owned gate consumes `.successNotification` for that operation;
- expose celebration permission separately; outcome-workflows Task 3 must consume `.celebration` before animation and must not reuse the notification consume;
- publish a registry-validated typed invalidation through the injected `any OutcomeInvalidationPublishing` sink for `.changed` or `.possiblyChanged`, independent of user success notification; feature consumers must not depend on the concrete `OutcomeInvalidationCenter` and no consumer posts raw `.xicoDidClean`;
- retain failed/skipped/cancelled selections and compute retry occurrences through the tested per-item selector, not a status Boolean;
- preserve successful trash receipts across partial/cancelled undo.

Register a fresh operation ID with the gate only at the live terminal transition. Re-render/onAppear, repeated assignment of the same ID, and historical record display never register/reset a gate. Shredder uses `.neutral`, is cleaning-notification-ineligible and never celebrates. Uninstaller and every other kind follow the registry's exact capabilities; only `cleaningExecute` may construct a cleaning success notification. Any remote/server workflow that later adopts this policy must use `.neutral` and remain cleaning-notification-ineligible.

- [ ] **Step 6: Stop fabricating reports for historical undo**

Add `CleaningEngine.undo(_ items: [RestorableItem]) async -> UndoResult` and make `undo(_ report:)` delegate to it. `ScanViews` and `SettingsView` pass `CleaningRecord.restorable` directly; delete their `CleaningReport(removedCount:...)` construction.

Migrate history reads at the same time: `SettingsView` uses `totalHistoryRecords` for record-list/empty-state presence and `totalSuccessfulCleanups` for any “successful cleanups” count; `ScanViews` trust facts must not select a `.legacyUnknown`, partial, failure or cancelled record as a prior success. Remove the ambiguous `totalCleanups` compatibility property after these reads migrate.

- [ ] **Step 7: Remove scalar compatibility and aggregate constructors**

Run:

```bash
rg -n 'CleaningReport\(removedCount:' Sources Tests
```

Expected: no output.

Delete the compatibility initializer from `Models.swift`. Keep only reducer-backed `init(operation:items:)` and `merging`.

Run:

```bash
rg -n -U 'record\s*\([^)]*reclaimedBytes:|(?:Notifier\s*\.\s*notifyCleaningDone|\bnotifier\s*\.\s*cleaningDone)\s*\(|\.totalCleanups\b' Sources Tests
```

Expected: no output. Delete the temporary scalar history writer and scalar notification overload only after `ModuleSessionViewModel`, `SmartScanHub`, `UninstallerModel` and `ShredderModel` all use their explicit outcome workflows.

- [ ] **Step 8: Run focused, feature and full regressions**

Run:

```bash
swift test --filter CleaningOutcomeConsumerTests --disable-automatic-resolution --skip-update
swift test --filter OutcomeSideEffectPolicyTests --disable-automatic-resolution --skip-update
swift test --filter NotifierTests --disable-automatic-resolution --skip-update
swift test --filter CleaningRoundTripTests --disable-automatic-resolution --skip-update
swift test --filter HistoryStoreTests --disable-automatic-resolution --skip-update
swift test --disable-automatic-resolution --skip-update
swift build -c debug --disable-automatic-resolution --skip-update
swift build -c release --disable-automatic-resolution --skip-update
```

Expected: all pass, 0 failures.

This is still not a release gate: outcome-workflows Tasks 1–13 must complete every registry, sink and direct-consumer migration, and its Task 14 must prove the direct-call/source counts are zero before packaging or scoring.

- [ ] **Step 9: Commit consumer migration**

```bash
git add Sources/Domain/Models.swift Sources/Domain/CleaningEngine.swift Sources/Infrastructure/ShredderService.swift Sources/Infrastructure/HistoryStore.swift Sources/Infrastructure/Notifier.swift Sources/Infrastructure/XicoEnvironment.swift Sources/Features/ModuleSessionViewModel.swift Sources/Features/SmartScanHub.swift Sources/Features/UninstallerView.swift Sources/Features/ShredderView.swift Sources/Features/ScanViews.swift Sources/Features/SettingsView.swift Tests/FeatureTests/OutcomeSideEffectPolicyTests.swift Tests/FeatureTests/CleaningOutcomeConsumerTests.swift Tests/IntegrationTests/NotifierTests.swift Tests/IntegrationTests/HistoryStoreTests.swift Tests/IntegrationTests/CleaningRoundTripTests.swift
git commit -m "fix: consume reducer-backed cleaning facts"
```

---

### Task 6: Consumer Contract Handoff — Honest TaskOutcomeView (Non-Executable Here)

**Files:**
- Modify: `Sources/Features/SharedViews.swift`
- Modify: `Sources/Features/MaintenanceView.swift`
- Modify: `Sources/Features/AppUpdaterView.swift`
- Modify: `Sources/Features/CollectionBasket.swift`
- Modify: `Sources/Features/SpaceLensView.swift`
- Modify: `Sources/Features/OptimizationView.swift`
- Modify: `Sources/Features/ShredderView.swift`
- Modify: `Sources/Features/UninstallerView.swift`
- Modify: `Sources/Infrastructure/OptimizationService.swift`
- Create: `Tests/FeatureTests/TaskOutcomePresentationTests.swift`
- Create: `Tests/FeatureTests/OutcomeWorkflowAdapterTests.swift`
- Modify: all `Sources/DesignSystem/Resources/*.lproj/Localizable.strings`

- [ ] **Step 1: Write failing pure presentation tests**

Extract `TaskOutcomePresentation` from an `OperationOutcome` and test status icon, title key, metric, actions and celebration permission for success changed、success unchanged、partial、failure、cancelled. Tests must assert partial/failure/cancelled use distinct icon plus text and never a checkmark-only/color-only state.

Add reducer-backed adapter tests for every current direct `TaskCompletionView` consumer:

```swift
func testMaintenanceBatchUsesEveryTaskResultAndPartialNeverCelebrates() async
func testAppUpdateCheckIsReadOnlyUnchangedAndNeverCelebrates() async
func testBasketCleanupUsesCleaningReportInsteadOfFreedFailureScalars() async
func testOptimizationTerminateAcceptanceIsPossiblyChangedAndNeutral() async
func testShredderSuccessUsesNeutralPresentationWithoutCelebration() async
func testUninstallerPartialUsesCleaningReportPresentation() async
func testCleaningCompletionConsumesCelebrationAndSoundHapticChannelsOnceIndependently() async
func testRepeatedAppearanceCannotReplayCelebration() async
```

Each adapter creates `OperationItemOutcome` values and calls the reducer; no feature constructs `OperationOutcome`. App-update checking is read-only (`mutation == .none`). Termination acceptance that does not prove process exit is `.possiblyChanged`. Basket and uninstaller consume their typed reducer-backed reports. Maintenance records each task result rather than `done += 1`. Shredder consumes outcome-workflows Task 2's item-complete `ShredderPayload` and uses the neutral profile.

- [ ] **Step 2: Confirm RED**

Run:

```bash
swift test --filter TaskOutcomePresentationTests --disable-automatic-resolution --skip-update
swift test --filter OutcomeWorkflowAdapterTests --disable-automatic-resolution --skip-update
```

Expected: FAIL because the presentation/view and explicit reducer-backed adapters do not exist, not because an async XCTest autoclosure is invalid.

- [ ] **Step 3: Implement presentation and view**

Add a pure `TaskOutcomePresentation.make(outcome:affectedBytes:decision:)` that returns localization keys, SF Symbol names and celebration permission from the already evaluated `OutcomeSideEffectDecision`; presentation must not reimplement policy from status/bytes. Replace `CompletionView`'s direct `TaskCompletionView` call with `TaskOutcomeView`:

- success+changed: `checkmark.circle.fill`, success semantic, optional signature animation;
- success+unchanged: `checkmark.circle`, neutral info semantic, static;
- partial: `exclamationmark.circle.fill`, warning semantic, retry/details/undo;
- failure: `xmark.octagon.fill`, error semantic, retry/recovery/details;
- cancelled: `stop.circle.fill`, neutral semantic, return/details/undo.

Gate `XAnnihilationBurst`, `XCelebrationBurst`, `XSound` and `XHaptic` behind `presentation.allowsCelebration && !reduceMotion`. With Reduce Motion, render the final state synchronously and do not create visual or sound/haptic effect Tasks.

`TaskOutcomeView` receives the owning live view model's `OutcomeFeedbackGate`. Before creating a visual animation Task, bind and require `await gate.consume(.celebration, for: outcome.id)`. Independently, before creating the sound/haptic Task, bind and require `await gate.consume(.successSoundHaptic, for: outcome.id)`. Neither consume may stand in for the other; the independent-channel test proves each succeeds once and replay of either is rejected. The view never calls `registerTerminal`; repeated appearance cannot reset/replay, a stale ID is rejected, and historical outcome presentation passes no live gate and has no effects.

- [ ] **Step 4: Migrate every direct completion consumer to an explicit outcome workflow**

Replace direct `TaskCompletionView` calls in `CompletionView`, `MaintenanceView`, `AppUpdaterView`, `BasketCompletionHost`, `OptimizationView`, `ShredderView` and `UninstallerView` with `TaskOutcomeView`. Replace their scalar completion state (`maintDone`, `checked`-as-success, `completedBytes`, `quitFreed`, shredder scalar `Completion`, `lastFreed/lastRemovedCount`) with an `OperationResult`/typed report plus the owning gate registered at the live terminal transition.

`SpaceLensModel.trashMany` returns the reducer-backed `CleaningReport`, not `(freed, failures)`, so Basket preserves partial/cancelled item facts and receipts. Maintenance builds one requested subject per selected task and uses each `(ok,message)` result. Change `OptimizationService.quit(pid:)` to return `NSRunningApplication.terminate()`'s Boolean; Optimization marks accepted-but-not-observed exits `.possiblyChanged`, uses a neutral profile and never celebrates uncertain release estimates. App update checking produces unchanged read-only outcomes and no mutation side effects.

Run:

```bash
rg -n 'TaskCompletionView\(' Sources/Features
```

Expected: no direct call sites. Keep the compile-only, fail-closed `TaskCompletionView` shim until every consumer migration in outcome-workflows Tasks 4–13 is complete. Outcome-workflows Task 14 owns deleting the shim declaration and its private compatibility implementation; do not delete it early or leave an architecture-test allowlist for production callers afterward.

- [ ] **Step 5: Add exact strings to all 11 locales**

Add localized keys for four statuses, changed/unchanged detail, failed/skipped/cancelled counts, retry failed items, details, recovery and undo completed items. Preserve format placeholder parity across every locale.

- [ ] **Step 6: Run presentation, workflow, localization and accessibility regression**

Run:

```bash
swift test --filter TaskOutcomePresentationTests --disable-automatic-resolution --skip-update
swift test --filter OutcomeWorkflowAdapterTests --disable-automatic-resolution --skip-update
swift test --filter LocalizationCoverageTests --disable-automatic-resolution --skip-update
swift test --filter TypeScaleTokenGuardTests --disable-automatic-resolution --skip-update
```

Expected: all pass, 0 failures.

- [ ] **Step 7: Commit the truthful outcome UI**

```bash
git add Sources/Infrastructure/OptimizationService.swift Sources/Features/SharedViews.swift Sources/Features/MaintenanceView.swift Sources/Features/AppUpdaterView.swift Sources/Features/CollectionBasket.swift Sources/Features/SpaceLensView.swift Sources/Features/OptimizationView.swift Sources/Features/ShredderView.swift Sources/Features/UninstallerView.swift Tests/FeatureTests/TaskOutcomePresentationTests.swift Tests/FeatureTests/OutcomeWorkflowAdapterTests.swift Sources/DesignSystem/Resources
git commit -m "feat: present honest operation outcomes"
```

---

### Task 7: Consumer Contract Handoff — Static Gates and Final Verification (Non-Executable Here)

**Files:**
- Create: `Tests/FeatureTests/OperationOutcomeArchitectureTests.swift`
- Modify: `docs/20-全量文档任务台账与95分验收矩阵-2026-07-16.md`

- [ ] **Step 1: Add source architecture tests**

The test scans production Swift sources and fails when:

- a feature constructs `OperationOutcome`;
- `OperationOutcome` conforms to `Codable`/`Decodable` or exposes `init(from:)`;
- `CleaningItemResult` or fact-backed `CleaningReport(operation:items:)` exposes a public initializer;
- an Infrastructure history DTO, `ValidatedHistoryRecordCandidate`, full-record initializer or generic insert becomes public;
- `CleaningReport(removedCount:` exists;
- any production business page calls `TaskCompletionView` directly;
- a live outcome view registers a feedback gate from appearance/rendering or a historical record consumes live effects;
- cleaning consumers send a validated notification without `OutcomeSideEffectPolicy` and `.successNotification` gate consumption in the same terminal workflow;
- any static/instance scalar cleanup-notifier spelling (`Notifier.notifyCleaningDone` or `notifier.cleaningDone`) exists;
- the legacy scalar `record(module:reclaimedBytes:removedCount:)` overload declaration or any production call exists;
- the ambiguous `HistoryStore.totalCleanups` declaration or production read exists;
- `OutcomeChannel`, `OutcomeChannelGate`, a second gate declaration or unbounded UUID-keyed channel storage exists.

The architecture test contains an explicit inventory for `ModuleSessionViewModel`, `SmartScanHub`, `UninstallerModel`, `ShredderModel`, `BasketModel`/`SpaceLensModel`, maintenance, optimization, app-update checking, historical undo and `CompletionView`. It also compiles negative external Feature fixtures proving outcome/fact/DTO constructors remain inaccessible and a positive external sink fixture proving the public typed protocols are usable. It fails if a listed consumer has no reducer-backed terminal state, registry semantics and long-lived owner gate; adding an ignore path is not an accepted migration.

- [ ] **Step 2: Run and fix every violation**

Run: `swift test --filter OperationOutcomeArchitectureTests --disable-automatic-resolution --skip-update`

Expected: PASS with zero ignored paths except the architecture test fixture strings themselves.

- [ ] **Step 3: Run the complete quality gate**

Run:

```bash
swift test --filter OperationOutcomeReducerTests --disable-automatic-resolution --skip-update
swift test --filter CleaningEngineTests --disable-automatic-resolution --skip-update
swift test --filter OutcomeSideEffectPolicyTests --disable-automatic-resolution --skip-update
swift test --filter HistoryStoreTests --disable-automatic-resolution --skip-update
swift test --filter CleaningOutcomeConsumerTests --disable-automatic-resolution --skip-update
swift test --filter NotifierTests --disable-automatic-resolution --skip-update
swift test --filter OutcomeWorkflowAdapterTests --disable-automatic-resolution --skip-update
swift test --filter TaskOutcomePresentationTests --disable-automatic-resolution --skip-update
swift build -c debug --disable-automatic-resolution --skip-update
swift test --disable-automatic-resolution --skip-update
swift build -c release --disable-automatic-resolution --skip-update
scripts/quality_gate.sh
```

Expected: 0 failures; test count must be greater than the latest `.superpowers/sdd/xico-opfacts-task-2-report.md` full-suite baseline (423 tests on HEAD `2dbfe87` at plan revision time, or any higher count recorded later). A lower test count is a regression even if it still exceeds the historical 373-test audit snapshot. Every skip is listed with its explicit environment reason and the current 15-skip environment baseline may not silently grow.

- [ ] **Step 4: Self-review requirement coverage**

Verify and record:

- OUT-01…10 each map to at least one passing test.
- UI-OUT-01/02/05/06 each map to presentation or side-effect tests.
- `rg -n -U 'CleaningReport\s*\(\s*removedCount:|TaskCompletionView\s*\(|(?:Notifier\s*\.\s*notifyCleaningDone|\bnotifier\s*\.\s*cleaningDone)\s*\(|record\s*\([^)]*reclaimedBytes:|\.totalCleanups\b' Sources` produces no output.
- `rg -n 'struct OperationOutcome: (Codable|Decodable)|public init\(operation: OperationOutcome|public init\(requestID: UUID' Sources/Domain` produces no output.
- Task 3's full policy matrix, bounded per-channel gate concurrency/lifecycle tests and retry-selection matrix are all GREEN.
- Task 4's schema/degraded preservation, candidate→persist→publish, idempotency, same-URL two-store, fact/receipt cross-check, copy-update and `0700/0600` tests are all GREEN.
- No `TODO`, `TBD`, placeholder body or `fatalError` was introduced.
- All new public Sendable types compile under Swift 6 strict concurrency.
- No package/install/deploy/notarize/publish command ran at a Task 2–4 checkpoint; release scoring begins only after outcome-workflows Tasks 1–13, its Task 14 full gate and independent Critical/Important review are clean.

- [ ] **Step 5: Update the ledger with evidence, request code review and commit**

Update only the Operation Facts-related rows; mark `verified` only when all commands above pass. Request independent review, resolve all Critical/Important findings, rerun the complete gate, then commit:

```bash
git add Tests/FeatureTests/OperationOutcomeArchitectureTests.swift docs/20-全量文档任务台账与95分验收矩阵-2026-07-16.md
git commit -m "test: enforce operation outcome facts"
```
