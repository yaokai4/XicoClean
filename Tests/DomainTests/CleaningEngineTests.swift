import Foundation
import XCTest
@testable import Domain

final class CleaningEngineTests: XCTestCase {
    private struct AllowAllSafety: SafetyEngine {
        func verify(_ url: URL, intent: DeleteIntent) -> SafetyVerdict { .allow }
    }

    private struct DenyAllSafety: SafetyEngine {
        func verify(_ url: URL, intent: DeleteIntent) -> SafetyVerdict {
            .deny(reason: "test denial")
        }
    }

    private enum ExpectedIssueDisposition {
        case failed
        case skipped
    }

    private func assertIssue(
        _ result: CleaningItemResult?,
        disposition expectedDisposition: ExpectedIssueDisposition,
        code: String,
        category: OperationIssueCategory,
        recovery: OperationRecoveryHint,
        retryable: Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let result else {
            XCTFail("Expected one cleaning item result", file: file, line: line)
            return
        }
        let issue: OperationIssue?
        switch (expectedDisposition, result.disposition) {
        case let (.failed, .failed(value)), let (.skipped, .skipped(value)):
            issue = value
        default:
            issue = nil
            XCTFail("Unexpected item disposition: \(result.disposition)", file: file, line: line)
        }
        XCTAssertEqual(
            issue,
            OperationIssue(code: code,
                           category: category,
                           subjectID: result.requestID.uuidString,
                           recovery: recovery,
                           retryable: retryable),
            file: file,
            line: line)
    }

    func testMissingPathIsUnchangedRatherThanSilentlyDropped() async {
        let url = URL(fileURLWithPath: "/tmp/missing")
        let engine = CleaningEngine(safety: AllowAllSafety(), fs: MemoryFS(existing: []))
        let item = CleanableItem(url: url, displayName: "missing", size: 10)
        let report = await engine.execute(CleaningPlan(items: [item], intent: .trash))
        XCTAssertEqual(report.operation.status, .success)
        XCTAssertEqual(report.operation.counts.unchanged, 1)
        XCTAssertEqual(report.items.single?.disposition, .unchanged)
        XCTAssertEqual(report.items.single?.intent, .trash)
        XCTAssertEqual(report.items.single?.mutation, OperationMutationFact.none)
        XCTAssertNil(report.items.single?.restorable)
        XCTAssertEqual(report.operation.mutation, .none)
    }

    func testSafetyDenialIsSkippedAndFailsSingleItemOperation() async {
        let url = URL(fileURLWithPath: "/tmp/denied")
        let engine = CleaningEngine(safety: DenyAllSafety(), fs: MemoryFS(existing: [url.path]))
        let report = await engine.execute(CleaningPlan(
            items: [CleanableItem(url: url, displayName: "denied", size: 10)], intent: .trash))
        XCTAssertEqual(report.operation.status, .failure)
        XCTAssertEqual(report.operation.counts.skipped, 1)
        XCTAssertEqual(report.items.single?.intent, .trash)
        XCTAssertEqual(report.items.single?.mutation, OperationMutationFact.none)
        XCTAssertNil(report.items.single?.restorable)
        XCTAssertEqual(report.operation.mutation, .none)
        assertIssue(report.items.single,
                    disposition: .skipped,
                    code: "cleaning.safety.denied",
                    category: .safetyPolicy,
                    recovery: .chooseAnotherTarget,
                    retryable: false)
    }

    func testSafetyRecheckDenialIsFailedAsIdentityChanged() async {
        let url = URL(fileURLWithPath: "/tmp/identity-changed")
        let fs = RecordingFS(existing: [url.path])
        let engine = CleaningEngine(safety: AllowThenDenySafety(), fs: fs)
        let report = await engine.execute(CleaningPlan(
            items: [CleanableItem(url: url, displayName: "changed", size: 10)], intent: .trash))

        XCTAssertEqual(report.operation.status, .failure)
        XCTAssertEqual(report.operation.counts.failed, 1)
        assertIssue(report.items.single,
                    disposition: .failed,
                    code: "cleaning.safety.identityChanged",
                    category: .identityChanged,
                    recovery: .retry,
                    retryable: true)
        XCTAssertTrue(fs.mutatedPaths.isEmpty)
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
        XCTAssertEqual(report.items.single?.intent, .trash)
        XCTAssertEqual(report.items.single?.mutation, .possiblyChanged)
        XCTAssertEqual(report.operation.mutation, .possiblyChanged)
        assertIssue(report.items.single,
                    disposition: .failed,
                    code: "cleaning.filesystem.operationFailed",
                    category: .io,
                    recovery: .retry,
                    retryable: true)
    }

    func testCleaningThrownMutationAndAmbiguousHelperFailureArePossiblyChanged() async {
        let ordinaryURL = URL(fileURLWithPath: "/tmp/ambiguous-ordinary")
        let ordinaryEngine = CleaningEngine(
            safety: AllowAllSafety(),
            fs: ThrowingFS(existing: [ordinaryURL.path], failing: [ordinaryURL.path]))
        let ordinary = await ordinaryEngine.execute(CleaningPlan(items: [
            CleanableItem(url: ordinaryURL, displayName: "ordinary", size: 10)
        ], intent: .trash))

        XCTAssertEqual(ordinary.items.single?.intent, .trash)
        XCTAssertEqual(ordinary.items.single?.mutation, .possiblyChanged)
        XCTAssertEqual(ordinary.operation.mutation, .possiblyChanged)
        XCTAssertNil(ordinary.items.single?.restorable)

        let helperURL = URL(fileURLWithPath: "/Library/Caches/XicoAmbiguousHelper")
        let helperFS = MemoryFS(existing: [helperURL.path])
        let helper = FakePrivileged(
            fs: helperFS,
            report: PrivilegedRemovalReport(freedBytes: 0, failures: [helperURL]),
            removesTargets: false)
        let helperEngine = CleaningEngine(
            safety: AllowAllSafety(), fs: helperFS, privileged: helper)
        let privileged = await helperEngine.execute(CleaningPlan(items: [
            CleanableItem(url: helperURL,
                          displayName: "helper",
                          size: 10,
                          requiresHelper: true)
        ], intent: .permanent))

        XCTAssertEqual(privileged.items.single?.intent, .permanent)
        XCTAssertEqual(privileged.items.single?.mutation, .possiblyChanged)
        XCTAssertEqual(privileged.operation.mutation, .possiblyChanged)
        XCTAssertNil(privileged.items.single?.restorable)
    }

    func testCleaningItemResultCarriesExactDeleteIntentWithoutDefault() throws {
        let result = CleaningItemResult(
            requestID: UUID(),
            itemID: UUID(),
            url: URL(fileURLWithPath: "/tmp/exact-intent"),
            intent: .permanent,
            disposition: .unchanged,
            mutation: .none,
            reclaimedBytes: 0,
            restorable: nil)

        XCTAssertEqual(result.intent, .permanent)
        XCTAssertEqual(result.mutation, .none)
    }

    func testOnlySucceededTrashFactCanCarryReceipt() {
        let receipt = RestorableItem(
            originalURL: URL(fileURLWithPath: "/tmp/receipt-original"),
            trashedURL: URL(fileURLWithPath: "/tmp/receipt-trashed"))
        let issue = OperationIssue(
            code: "test.receipt.disposition",
            category: .io,
            subjectID: nil,
            recovery: .retry,
            retryable: true)
        let rows: [(
            label: String,
            intent: DeleteIntent,
            disposition: OperationDisposition,
            mutation: OperationMutationFact,
            expectedReceipt: RestorableItem?
        )] = [
            ("trash succeeded", .trash, .succeeded, .changed, receipt),
            ("permanent succeeded", .permanent, .succeeded, .changed, nil),
            ("trash unchanged", .trash, .unchanged, .none, nil),
            ("permanent unchanged", .permanent, .unchanged, .none, nil),
            ("trash skipped", .trash, .skipped(issue), .none, nil),
            ("permanent skipped", .permanent, .skipped(issue), .none, nil),
            ("trash failed", .trash, .failed(issue), .possiblyChanged, nil),
            ("permanent failed", .permanent, .failed(issue), .possiblyChanged, nil),
            ("trash cancelled", .trash, .cancelled(issue), .none, nil),
            ("permanent cancelled", .permanent, .cancelled(issue), .none, nil)
        ]

        for row in rows {
            let result = CleaningItemResult(
                requestID: UUID(),
                itemID: UUID(),
                url: receipt.originalURL,
                intent: row.intent,
                disposition: row.disposition,
                mutation: row.mutation,
                reclaimedBytes: 0,
                restorable: receipt)

            XCTAssertEqual(result.intent, row.intent, row.label)
            XCTAssertEqual(result.disposition, row.disposition, row.label)
            XCTAssertEqual(result.mutation, row.mutation, row.label)
            XCTAssertEqual(result.restorable, row.expectedReceipt, row.label)
        }
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
        XCTAssertEqual(report.items.map(\.intent), [.trash, .trash, .trash])
        XCTAssertEqual(report.items.map(\.mutation), [.changed, .none, .none])
        XCTAssertNil(report.items[1].restorable)
        XCTAssertNil(report.items[2].restorable)
        XCTAssertEqual(report.operation.mutation, .changed)
    }

    func testCancellationDuringLastPrivilegedItemWinsAfterHelperReturns() async {
        let url = URL(fileURLWithPath: "/Library/Caches/XicoCancelledHelper")
        let fs = RecordingFS(existing: [url.path])
        let helper = SuspendingPrivileged(
            fs: fs,
            report: PrivilegedRemovalReport(freedBytes: 42, failures: []))
        let engine = CleaningEngine(safety: AllowAllSafety(), fs: fs, privileged: helper)
        let task = Task { await engine.execute(CleaningPlan(items: [
            CleanableItem(url: url,
                          displayName: "cancelled-helper",
                          size: 42,
                          requiresHelper: true)
        ], intent: .permanent)) }

        await helper.waitUntilFirstCall()
        task.cancel()
        await helper.resumeFirstCall()
        let report = await task.value

        XCTAssertEqual(report.operation.status, .cancelled)
        XCTAssertEqual(report.operation.counts.requested, 1)
        XCTAssertEqual(report.operation.counts.succeeded, 1)
        XCTAssertEqual(report.operation.counts.cancelled, 0)
        XCTAssertEqual(report.items.single?.disposition, .succeeded)
        XCTAssertEqual(report.items.single?.reclaimedBytes, 42)
        XCTAssertEqual(report.items.single?.intent, .permanent)
        XCTAssertEqual(report.items.single?.mutation, .changed)
        XCTAssertEqual(report.operation.mutation, .changed)
    }

    func testCancellationDuringLastOrdinaryMutationWinsAfterMutationReturns() async {
        let url = URL(fileURLWithPath: "/tmp/cancel-last-ordinary")
        let fs = SuspendingFS(existing: [url.path])
        let engine = CleaningEngine(safety: AllowAllSafety(), fs: fs)
        let task = Task { await engine.execute(CleaningPlan(items: [
            CleanableItem(url: url, displayName: "cancel-last", size: 10)
        ], intent: .permanent)) }

        await fs.waitUntilFirstMutation()
        task.cancel()
        await fs.resume()
        let report = await task.value

        XCTAssertEqual(report.operation.status, .cancelled)
        XCTAssertEqual(report.operation.counts.requested, 1)
        XCTAssertEqual(report.operation.counts.succeeded, 1)
        XCTAssertEqual(report.operation.counts.cancelled, 0)
        XCTAssertEqual(report.items.single?.disposition, .succeeded)
        XCTAssertEqual(report.items.single?.intent, .permanent)
        XCTAssertEqual(report.items.single?.mutation, .changed)
        XCTAssertEqual(report.operation.mutation, .changed)
    }

    func testCancellationFromLastProgressCallbackWinsBeforeReduction() async {
        let url = URL(fileURLWithPath: "/tmp/cancel-last-progress")
        let fs = RecordingFS(existing: [url.path])
        let engine = CleaningEngine(safety: AllowAllSafety(), fs: fs)

        let report = await engine.execute(CleaningPlan(items: [
            CleanableItem(url: url, displayName: "cancel-progress", size: 10)
        ], intent: .permanent)) { _ in
            withUnsafeCurrentTask { $0?.cancel() }
        }

        XCTAssertEqual(report.operation.status, .cancelled)
        XCTAssertEqual(report.operation.counts.requested, 1)
        XCTAssertEqual(report.operation.counts.succeeded, 1)
        XCTAssertEqual(report.operation.counts.cancelled, 0)
        XCTAssertEqual(report.items.single?.disposition, .succeeded)
        XCTAssertEqual(report.items.single?.intent, .permanent)
        XCTAssertEqual(report.items.single?.mutation, .changed)
        XCTAssertEqual(report.operation.mutation, .changed)
    }

    func testConcurrentExecutionsOfSameTargetFailSecondBeforeAnyDependencyCall() async {
        let url = URL(fileURLWithPath: "/Library/Caches/XicoInFlight")
        let fs = RecordingFS(existing: [url.path])
        let safety = RecordingSafety(verdict: .allow)
        let helper = SuspendingPrivileged(
            fs: fs,
            report: PrivilegedRemovalReport(freedBytes: 10, failures: []))
        let engine = CleaningEngine(safety: safety, fs: fs, privileged: helper)
        let firstTask = Task { await engine.execute(CleaningPlan(items: [
            CleanableItem(url: url, displayName: "first", size: 10, requiresHelper: true)
        ], intent: .permanent)) }

        await helper.waitUntilFirstCall()
        let attemptedBeforeSecond = fs.attemptedPaths
        let mutatedBeforeSecond = fs.mutatedPaths
        let safetyCallsBeforeSecond = safety.callCount
        let helperCallsBeforeSecond = await helper.callCount
        let secondProgress = ProgressRecorder()

        let secondReport = await engine.execute(CleaningPlan(items: [
            CleanableItem(url: url, displayName: "second", size: 10, requiresHelper: true)
        ], intent: .permanent)) {
            secondProgress.record($0)
        }

        XCTAssertEqual(secondReport.operation.status, .failure)
        XCTAssertEqual(secondReport.operation.counts.failed, 1)
        assertIssue(secondReport.items.single,
                    disposition: .failed,
                    code: "cleaning.request.inFlight",
                    category: .internalInvariant,
                    recovery: .retry,
                    retryable: true)
        XCTAssertEqual(secondReport.items.single?.intent, .permanent)
        XCTAssertEqual(secondReport.items.single?.mutation, OperationMutationFact.none)
        XCTAssertEqual(secondReport.operation.mutation, .none)
        XCTAssertEqual(fs.attemptedPaths, attemptedBeforeSecond)
        XCTAssertEqual(fs.mutatedPaths, mutatedBeforeSecond)
        XCTAssertEqual(safety.callCount, safetyCallsBeforeSecond)
        let helperCallsAfterSecond = await helper.callCount
        XCTAssertEqual(helperCallsAfterSecond, helperCallsBeforeSecond)
        XCTAssertEqual(secondProgress.callCount, 0)

        await helper.resumeFirstCall()
        let firstReport = await firstTask.value
        XCTAssertEqual(firstReport.operation.status, .success)
        XCTAssertEqual(firstReport.operation.counts.succeeded, 1)
        XCTAssertEqual(firstReport.items.single?.intent, .permanent)
        XCTAssertEqual(firstReport.items.single?.mutation, .changed)

        let helperCallsAfterFirst = await helper.callCount
        let afterReleaseReport = await engine.execute(CleaningPlan(items: [
            CleanableItem(url: url,
                          displayName: "after-release",
                          size: 10,
                          requiresHelper: true)
        ], intent: .permanent))
        XCTAssertEqual(afterReleaseReport.operation.status, .success)
        XCTAssertEqual(afterReleaseReport.operation.counts.unchanged, 1)
        XCTAssertEqual(afterReleaseReport.items.single?.disposition, .unchanged)
        XCTAssertEqual(afterReleaseReport.items.single?.intent, .permanent)
        XCTAssertEqual(afterReleaseReport.items.single?.mutation, OperationMutationFact.none)
        let helperCallsAfterRelease = await helper.callCount
        XCTAssertEqual(helperCallsAfterRelease, helperCallsAfterFirst)
    }

    func testLocalDuplicatePrecedesCrossExecutionInFlightWithoutDependencies() async {
        let direct = URL(fileURLWithPath: "/Library/Caches/XicoDuplicateInFlight")
        let equivalent = URL(
            fileURLWithPath: "/Library/Caches/xico-parent/../XicoDuplicateInFlight")
        XCTAssertEqual(direct.standardizedFileURL.path,
                       equivalent.standardizedFileURL.path)
        let fs = RecordingFS(existing: [direct.path])
        let safety = RecordingSafety(verdict: .allow)
        let helper = SuspendingPrivileged(
            fs: fs,
            report: PrivilegedRemovalReport(freedBytes: 10, failures: []))
        let engine = CleaningEngine(safety: safety, fs: fs, privileged: helper)
        let firstTask = Task { await engine.execute(CleaningPlan(items: [
            CleanableItem(url: direct, displayName: "active", size: 10, requiresHelper: true)
        ], intent: .permanent)) }

        await helper.waitUntilFirstCall()
        let attemptedBeforeDuplicates = fs.attemptedPaths
        let mutatedBeforeDuplicates = fs.mutatedPaths
        let safetyCallsBeforeDuplicates = safety.callCount
        let helperCallsBeforeDuplicates = await helper.callCount
        let duplicateProgress = ProgressRecorder()

        let duplicateReport = await engine.execute(CleaningPlan(items: [
            CleanableItem(url: direct,
                          displayName: "duplicate-direct",
                          size: 10,
                          requiresHelper: true),
            CleanableItem(url: equivalent,
                          displayName: "duplicate-equivalent",
                          size: 10,
                          requiresHelper: true)
        ], intent: .permanent)) {
            duplicateProgress.record($0)
        }

        XCTAssertEqual(duplicateReport.operation.status, .failure)
        XCTAssertEqual(duplicateReport.operation.counts.requested, 2)
        XCTAssertEqual(duplicateReport.operation.counts.failed, 2)
        XCTAssertEqual(duplicateReport.items.count, 2)
        for result in duplicateReport.items {
            assertIssue(result,
                        disposition: .failed,
                        code: "cleaning.request.duplicateTarget",
                        category: .internalInvariant,
                        recovery: .chooseAnotherTarget,
                        retryable: false)
            XCTAssertEqual(result.intent, .permanent)
            XCTAssertEqual(result.mutation, .none)
        }
        XCTAssertEqual(duplicateReport.operation.mutation, .none)
        XCTAssertEqual(fs.attemptedPaths, attemptedBeforeDuplicates)
        XCTAssertEqual(fs.mutatedPaths, mutatedBeforeDuplicates)
        XCTAssertEqual(safety.callCount, safetyCallsBeforeDuplicates)
        let helperCallsAfterDuplicates = await helper.callCount
        XCTAssertEqual(helperCallsAfterDuplicates, helperCallsBeforeDuplicates)
        XCTAssertEqual(duplicateProgress.callCount, 0)

        await helper.resumeFirstCall()
        let firstReport = await firstTask.value
        XCTAssertEqual(firstReport.operation.status, .success)
        XCTAssertEqual(firstReport.operation.counts.succeeded, 1)
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
        for result in report.items {
            assertIssue(result,
                        disposition: .failed,
                        code: "cleaning.request.duplicateTarget",
                        category: .internalInvariant,
                        recovery: .chooseAnotherTarget,
                        retryable: false)
            XCTAssertEqual(result.intent, .trash)
            XCTAssertEqual(result.mutation, .none)
        }
        XCTAssertEqual(report.operation.mutation, .none)
        XCTAssertTrue(fs.attemptedPaths.isEmpty)
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
        for result in report.items {
            assertIssue(result,
                        disposition: .failed,
                        code: "cleaning.request.duplicateTarget",
                        category: .internalInvariant,
                        recovery: .chooseAnotherTarget,
                        retryable: false)
        }
        XCTAssertTrue(fs.attemptedPaths.isEmpty)
        XCTAssertTrue(fs.mutatedPaths.isEmpty)
    }

    func testInformationalItemIsSkippedWithoutFilesystemMutation() async {
        let url = URL(fileURLWithPath: "/tmp/informational")
        let fs = RecordingFS(existing: [url.path])
        let engine = CleaningEngine(safety: AllowAllSafety(), fs: fs)
        let item = CleanableItem(url: url,
                                 displayName: "informational",
                                 size: 10,
                                 isInformational: true)

        let report = await engine.execute(CleaningPlan(items: [item], intent: .trash))

        XCTAssertEqual(report.operation.status, .failure)
        XCTAssertEqual(report.operation.counts.skipped, 1)
        XCTAssertEqual(report.items.count, 1)
        assertIssue(report.items.single,
                    disposition: .skipped,
                    code: "cleaning.item.informational",
                    category: .safetyPolicy,
                    recovery: .manualAction,
                    retryable: false)
        XCTAssertEqual(report.items.single?.intent, .trash)
        XCTAssertEqual(report.items.single?.mutation, OperationMutationFact.none)
        XCTAssertNil(report.items.single?.restorable)
        XCTAssertTrue(fs.attemptedPaths.isEmpty)
        XCTAssertTrue(fs.mutatedPaths.isEmpty)
    }

    func testEmptyPlanFailsClosedWithoutFilesystemMutation() async {
        let safety = RecordingSafety(verdict: .allow)
        let fs = RecordingFS(existing: [])
        let helper = FakePrivileged(fs: fs,
                                    report: PrivilegedRemovalReport(freedBytes: 0, failures: []),
                                    removesTargets: true)
        let progress = ProgressRecorder()
        let engine = CleaningEngine(safety: safety, fs: fs, privileged: helper)

        let report = await engine.execute(CleaningPlan(items: [], intent: .trash)) {
            progress.record($0)
        }

        XCTAssertEqual(report.operation.status, .failure)
        XCTAssertEqual(report.operation.counts.requested, 0)
        XCTAssertEqual(report.operation.counts.failed, 0)
        XCTAssertEqual(report.items.count, 0)
        XCTAssertTrue(report.operation.issues.contains {
            $0.code == "cleaning.request.empty" && $0.category == .internalInvariant
        })
        XCTAssertEqual(safety.callCount, 0)
        XCTAssertTrue(fs.attemptedPaths.isEmpty)
        let helperCalls = await helper.snapshot()
        XCTAssertEqual(helperCalls.count, 0)
        XCTAssertEqual(progress.callCount, 0)
    }

    func testMissingHelperFailsRequestedItem() async {
        let url = URL(fileURLWithPath: "/Library/Caches/XicoTest")
        let fs = RecordingFS(existing: [url.path])
        let engine = CleaningEngine(safety: AllowAllSafety(), fs: fs)
        let item = CleanableItem(url: url,
                                 displayName: "XicoTest",
                                 size: 10,
                                 requiresHelper: true)

        let report = await engine.execute(CleaningPlan(items: [item], intent: .permanent))

        XCTAssertEqual(report.operation.status, .failure)
        XCTAssertEqual(report.operation.counts.requested, 1)
        XCTAssertEqual(report.operation.counts.failed, 1)
        XCTAssertEqual(report.items.count, 1)
        assertIssue(report.items.single,
                    disposition: .failed,
                    code: "cleaning.helper.unavailable",
                    category: .unavailable,
                    recovery: .installHelper,
                    retryable: true)
        XCTAssertEqual(report.items.single?.intent, .permanent)
        XCTAssertEqual(report.items.single?.mutation, OperationMutationFact.none)
        XCTAssertNil(report.items.single?.restorable)
        XCTAssertTrue(fs.mutatedPaths.isEmpty)
    }

    func testHelperIntentMismatchFailsWithoutCallingHelper() async {
        let url = URL(fileURLWithPath: "/Library/Caches/XicoTest")
        let fs = RecordingFS(existing: [url.path])
        let helper = FakePrivileged(fs: fs,
                                    report: PrivilegedRemovalReport(freedBytes: 123, failures: []),
                                    removesTargets: true)
        let engine = CleaningEngine(safety: AllowAllSafety(), fs: fs, privileged: helper)
        let item = CleanableItem(url: url,
                                 displayName: "XicoTest",
                                 size: 10,
                                 requiresHelper: true)

        let report = await engine.execute(CleaningPlan(items: [item], intent: .trash))

        XCTAssertEqual(report.operation.status, .failure)
        XCTAssertEqual(report.operation.counts.failed, 1)
        XCTAssertEqual(report.items.count, 1)
        assertIssue(report.items.single,
                    disposition: .failed,
                    code: "cleaning.helper.intentMismatch",
                    category: .validation,
                    recovery: .chooseAnotherTarget,
                    retryable: false)
        XCTAssertEqual(report.items.single?.intent, .trash)
        XCTAssertEqual(report.items.single?.mutation, OperationMutationFact.none)
        XCTAssertNil(report.items.single?.restorable)
        let helperCalls = await helper.snapshot()
        XCTAssertEqual(helperCalls.count, 0)
        XCTAssertTrue(fs.mutatedPaths.isEmpty)
    }

    func testHelperReportedTargetFailureIsFailed() async {
        let url = URL(fileURLWithPath: "/Library/Caches/XicoTargetFailure")
        let fs = RecordingFS(existing: [url.path])
        let helper = FakePrivileged(fs: fs,
                                    report: PrivilegedRemovalReport(freedBytes: 100, failures: [url]),
                                    removesTargets: false)
        let engine = CleaningEngine(safety: AllowAllSafety(), fs: fs, privileged: helper)

        let report = await engine.execute(CleaningPlan(items: [
            CleanableItem(url: url, displayName: "target", size: 10, requiresHelper: true)
        ], intent: .permanent))

        XCTAssertEqual(report.operation.counts.failed, 1)
        XCTAssertEqual(report.items.count, 1)
        assertIssue(report.items.single,
                    disposition: .failed,
                    code: "cleaning.helper.removalFailed",
                    category: .io,
                    recovery: .retry,
                    retryable: true)
        XCTAssertEqual(report.items.single?.intent, .permanent)
        XCTAssertEqual(report.items.single?.mutation, .possiblyChanged)
        XCTAssertEqual(report.operation.mutation, .possiblyChanged)
        let helperCalls = await helper.snapshot()
        XCTAssertEqual(helperCalls.count, 1)
        XCTAssertTrue(fs.mutatedPaths.isEmpty)
    }

    func testHelperUnexpectedFailurePathFailsClosed() async {
        let url = URL(fileURLWithPath: "/Library/Caches/XicoUnexpected")
        let unexpected = URL(fileURLWithPath: "/Library/Caches/OtherTarget")
        let fs = RecordingFS(existing: [url.path])
        let helper = FakePrivileged(
            fs: fs,
            report: PrivilegedRemovalReport(freedBytes: 100, failures: [unexpected]),
            removesTargets: false)
        let engine = CleaningEngine(safety: AllowAllSafety(), fs: fs, privileged: helper)

        let report = await engine.execute(CleaningPlan(items: [
            CleanableItem(url: url, displayName: "target", size: 10, requiresHelper: true)
        ], intent: .permanent))

        XCTAssertEqual(report.operation.counts.failed, 1)
        XCTAssertEqual(report.items.count, 1)
        assertIssue(report.items.single,
                    disposition: .failed,
                    code: "cleaning.helper.unexpectedFailurePath",
                    category: .internalInvariant,
                    recovery: .retry,
                    retryable: true)
        XCTAssertEqual(report.items.single?.intent, .permanent)
        XCTAssertEqual(report.items.single?.mutation, .possiblyChanged)
        XCTAssertEqual(report.operation.mutation, .possiblyChanged)
        XCTAssertTrue(fs.mutatedPaths.isEmpty)
    }

    func testHelperTargetAndUnexpectedFailuresPreferInvariantFailure() async {
        let url = URL(fileURLWithPath: "/Library/Caches/XicoMixedFailure")
        let unexpected = URL(fileURLWithPath: "/Library/Caches/OtherTarget")
        let fs = RecordingFS(existing: [url.path])
        let helper = FakePrivileged(
            fs: fs,
            report: PrivilegedRemovalReport(freedBytes: 999, failures: [url, unexpected]),
            removesTargets: false)
        let engine = CleaningEngine(safety: AllowAllSafety(), fs: fs, privileged: helper)

        let report = await engine.execute(CleaningPlan(items: [
            CleanableItem(url: url, displayName: "target", size: 10, requiresHelper: true)
        ], intent: .permanent))

        XCTAssertEqual(report.operation.counts.failed, 1)
        XCTAssertEqual(report.reclaimedBytes, 0)
        XCTAssertEqual(report.items.single?.reclaimedBytes, 0)
        XCTAssertNil(report.items.single?.restorable)
        assertIssue(report.items.single,
                    disposition: .failed,
                    code: "cleaning.helper.unexpectedFailurePath",
                    category: .internalInvariant,
                    recovery: .retry,
                    retryable: true)
        XCTAssertEqual(report.items.single?.intent, .permanent)
        XCTAssertEqual(report.items.single?.mutation, .possiblyChanged)
        XCTAssertEqual(report.operation.mutation, .possiblyChanged)
    }

    func testHelperClaimedSuccessWhileTargetExistsIsFailed() async {
        let url = URL(fileURLWithPath: "/Library/Caches/XicoStillExists")
        let fs = RecordingFS(existing: [url.path])
        let helper = FakePrivileged(fs: fs,
                                    report: PrivilegedRemovalReport(freedBytes: 100, failures: []),
                                    removesTargets: false)
        let engine = CleaningEngine(safety: AllowAllSafety(), fs: fs, privileged: helper)

        let report = await engine.execute(CleaningPlan(items: [
            CleanableItem(url: url, displayName: "target", size: 10, requiresHelper: true)
        ], intent: .permanent))

        XCTAssertEqual(report.operation.counts.failed, 1)
        XCTAssertEqual(report.items.count, 1)
        assertIssue(report.items.single,
                    disposition: .failed,
                    code: "cleaning.helper.targetStillExists",
                    category: .io,
                    recovery: .retry,
                    retryable: true)
        XCTAssertEqual(report.items.single?.intent, .permanent)
        XCTAssertEqual(report.items.single?.mutation, .possiblyChanged)
        XCTAssertEqual(report.operation.mutation, .possiblyChanged)
    }

    func testHelperVerifiedSuccessUsesExactZeroMeasuredBytes() async {
        let url = URL(fileURLWithPath: "/Library/Caches/XicoZeroBytes")
        let fs = RecordingFS(existing: [url.path])
        let helper = FakePrivileged(fs: fs,
                                    report: PrivilegedRemovalReport(freedBytes: 0, failures: []),
                                    removesTargets: true)
        let engine = CleaningEngine(safety: AllowAllSafety(), fs: fs, privileged: helper)

        let report = await engine.execute(CleaningPlan(items: [
            CleanableItem(url: url, displayName: "target", size: 10_000, requiresHelper: true)
        ], intent: .permanent))

        XCTAssertEqual(report.operation.status, .success)
        XCTAssertEqual(report.operation.counts.succeeded, 1)
        XCTAssertEqual(report.items.single?.disposition, .succeeded)
        XCTAssertEqual(report.items.single?.reclaimedBytes, 0)
        XCTAssertEqual(report.reclaimedBytes, 0)
    }

    func testHelperVerifiedSuccessClampsNegativeMeasuredBytesToZero() async {
        let url = URL(fileURLWithPath: "/Library/Caches/XicoNegativeBytes")
        let fs = RecordingFS(existing: [url.path])
        let helper = FakePrivileged(fs: fs,
                                    report: PrivilegedRemovalReport(freedBytes: -99, failures: []),
                                    removesTargets: true)
        let engine = CleaningEngine(safety: AllowAllSafety(), fs: fs, privileged: helper)

        let report = await engine.execute(CleaningPlan(items: [
            CleanableItem(url: url, displayName: "target", size: 10_000, requiresHelper: true)
        ], intent: .permanent))

        XCTAssertEqual(report.operation.status, .success)
        XCTAssertEqual(report.items.single?.reclaimedBytes, 0)
        XCTAssertEqual(report.reclaimedBytes, 0)
        XCTAssertGreaterThanOrEqual(report.reclaimedBytes, 0)
    }

    func testPrivilegedItemsUseInjectedHelperForPermanentDelete() async {
        let url = URL(fileURLWithPath: "/Library/Caches/XicoTest")
        let fs = RecordingFS(existing: [url.path])
        let helper = FakePrivileged(fs: fs,
                                    report: PrivilegedRemovalReport(freedBytes: 123, failures: []),
                                    removesTargets: true)
        let engine = CleaningEngine(safety: AllowAllSafety(), fs: fs, privileged: helper)
        let item = CleanableItem(url: url,
                                 displayName: "XicoTest",
                                 size: 10,
                                 requiresHelper: true)

        let report = await engine.execute(CleaningPlan(items: [item], intent: .permanent))

        XCTAssertEqual(report.operation.status, .success)
        XCTAssertEqual(report.operation.counts.succeeded, 1)
        XCTAssertEqual(report.items.single?.disposition, .succeeded)
        XCTAssertEqual(report.items.single?.reclaimedBytes, 123)
        XCTAssertNil(report.items.single?.restorable)
        XCTAssertEqual(report.items.single?.intent, .permanent)
        XCTAssertEqual(report.items.single?.mutation, .changed)
        XCTAssertEqual(report.operation.mutation, .changed)
        let helperCalls = await helper.snapshot()
        XCTAssertEqual(helperCalls, [[url]])
        XCTAssertFalse(fs.contains(url))
    }

    func testOverlappingDuplicateGroupsFailOnlyDuplicateMembersBeforeAnyDependencyCall() async {
        let firstURL = URL(fileURLWithPath: "/tmp/overlap-first")
        let sharedPath = URL(fileURLWithPath: "/tmp/overlap-shared")
        let equivalentSharedPath = URL(fileURLWithPath: "/tmp/xico-parent/../overlap-shared")
        let independentURL = URL(fileURLWithPath: "/tmp/overlap-independent")
        let duplicateID = UUID()
        let fs = RecordingFS(existing: [firstURL.path,
                                        sharedPath.path,
                                        independentURL.path])
        let helper = FakePrivileged(fs: fs,
                                    report: PrivilegedRemovalReport(freedBytes: 0, failures: []),
                                    removesTargets: true)
        let engine = CleaningEngine(safety: AllowAllSafety(), fs: fs, privileged: helper)
        let items = [
            CleanableItem(id: duplicateID, url: firstURL, displayName: "first", size: 10),
            CleanableItem(id: duplicateID, url: sharedPath, displayName: "second", size: 10),
            CleanableItem(url: equivalentSharedPath, displayName: "third", size: 10),
            CleanableItem(url: independentURL, displayName: "fourth", size: 10)
        ]

        let report = await engine.execute(CleaningPlan(items: items, intent: .permanent))

        XCTAssertEqual(report.operation.status, .partial)
        XCTAssertEqual(report.operation.counts.requested, 4)
        XCTAssertEqual(report.operation.counts.failed, 3)
        XCTAssertEqual(report.operation.counts.succeeded, 1)
        XCTAssertEqual(report.items.map(\.itemID), items.map(\.id))
        XCTAssertEqual(report.items.map(\.url), items.map(\.url))
        for result in report.items.prefix(3) {
            assertIssue(result,
                        disposition: .failed,
                        code: "cleaning.request.duplicateTarget",
                        category: .internalInvariant,
                        recovery: .chooseAnotherTarget,
                        retryable: false)
        }
        XCTAssertEqual(report.items.last?.disposition, .succeeded)
        XCTAssertEqual(fs.existsPaths, [independentURL.standardizedFileURL.path])
        XCTAssertEqual(fs.mutatedPaths, [independentURL.standardizedFileURL.path])
        let helperCalls = await helper.snapshot()
        XCTAssertEqual(helperCalls.count, 0)
    }

    func testOrdinaryTrashAndPermanentSuccessPreserveItemFacts() async {
        await assertTwoItemOrdinarySuccess(intent: .trash)
        await assertTwoItemOrdinarySuccess(intent: .permanent)
    }

    func testReclaimedByteTotalsSaturateAfterEverySuccessfulMutation() async {
        let urls = [
            URL(fileURLWithPath: "/tmp/saturating-first"),
            URL(fileURLWithPath: "/tmp/saturating-second")
        ]
        let fs = RecordingFS(existing: Set(urls.map(\.path)))
        let engine = CleaningEngine(safety: AllowAllSafety(), fs: fs)
        let items = urls.map {
            CleanableItem(url: $0,
                          displayName: $0.lastPathComponent,
                          size: Int64.max)
        }

        let report = await engine.execute(CleaningPlan(items: items, intent: .permanent))

        XCTAssertEqual(report.operation.status, .success)
        XCTAssertEqual(report.operation.counts.succeeded, 2)
        XCTAssertEqual(report.items.count, 2)
        XCTAssertEqual(report.reclaimedBytes, Int64.max)
        XCTAssertEqual(fs.mutatedPaths, urls.map { $0.standardizedFileURL.path })
    }

    func testRepeatedCallerItemIDGetsFreshRequestIDPerExecution() async {
        let callerID = UUID()
        let firstURL = URL(fileURLWithPath: "/tmp/repeated-id-first")
        let secondURL = URL(fileURLWithPath: "/tmp/repeated-id-second")
        let fs = MemoryFS(existing: [firstURL.path, secondURL.path])
        let engine = CleaningEngine(safety: AllowAllSafety(), fs: fs)

        let first = await engine.execute(CleaningPlan(items: [
            CleanableItem(id: callerID, url: firstURL, displayName: "first", size: 10)
        ], intent: .permanent))
        let second = await engine.execute(CleaningPlan(items: [
            CleanableItem(id: callerID, url: secondURL, displayName: "second", size: 10)
        ], intent: .permanent))

        XCTAssertEqual(first.items.single?.itemID, callerID)
        XCTAssertEqual(second.items.single?.itemID, callerID)
        XCTAssertNotEqual(first.items.single?.requestID, second.items.single?.requestID)
    }

    func testCleaningReportUsesEstimatedReclaimableBytes() async {
        let url = URL(fileURLWithPath: "/tmp/XicoCloneCandidate")
        let fs = MemoryFS(existing: [url.path])
        let engine = CleaningEngine(safety: AllowAllSafety(), fs: fs)
        let item = CleanableItem(
            url: url, displayName: "clone", size: 10_000,
            assessment: FindingAssessment(
                confidence: 1,
                evidence: [
                    ScanEvidence(code: "exact", kind: .exactContent, title: "内容相同"),
                    ScanEvidence(code: "clone", kind: .size, title: "APFS 独占块")
                ],
                reclaimableBytes: 1_024,
                recovery: .none,
                regenerationCost: .unknown))

        let report = await engine.execute(CleaningPlan(items: [item], intent: .permanent))

        XCTAssertEqual(report.operation.status, .success)
        XCTAssertEqual(report.operation.counts.succeeded, 1)
        XCTAssertEqual(report.items.single?.reclaimedBytes, 1_024)
        XCTAssertEqual(report.reclaimedBytes, 1_024,
                       "清理结果不得把克隆/稀疏文件的表观大小当成真实释放量")
    }

    private func assertTwoItemOrdinarySuccess(
        intent: DeleteIntent,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let suffix = intent == .trash ? "trash" : "permanent"
        let urls = [
            URL(fileURLWithPath: "/tmp/facts-\(suffix)-first"),
            URL(fileURLWithPath: "/tmp/facts-\(suffix)-second")
        ]
        let items = urls.enumerated().map {
            CleanableItem(url: $0.element,
                          displayName: "item-\($0.offset)",
                          size: Int64(($0.offset + 1) * 10))
        }
        let fs = MemoryFS(existing: Set(urls.map(\.path)))
        let engine = CleaningEngine(safety: AllowAllSafety(), fs: fs)

        let report = await engine.execute(CleaningPlan(items: items, intent: intent))

        XCTAssertEqual(report.operation.status, .success, file: file, line: line)
        XCTAssertEqual(report.operation.counts.succeeded, 2, file: file, line: line)
        XCTAssertEqual(report.items.count, 2, file: file, line: line)
        XCTAssertEqual(report.items.map(\.itemID), items.map(\.id), file: file, line: line)
        XCTAssertEqual(report.items.map(\.url), urls, file: file, line: line)
        XCTAssertEqual(Set(report.items.map(\.requestID)).count, 2, file: file, line: line)

        for (result, item) in zip(report.items, items) {
            XCTAssertEqual(result.disposition, .succeeded, file: file, line: line)
            XCTAssertEqual(result.intent, intent, file: file, line: line)
            XCTAssertEqual(result.mutation, .changed, file: file, line: line)
            XCTAssertNotEqual(result.requestID, item.id, file: file, line: line)
            if intent == .trash {
                XCTAssertEqual(result.restorable?.originalURL, item.url, file: file, line: line)
            } else {
                XCTAssertNil(result.restorable, file: file, line: line)
            }
        }
        XCTAssertEqual(report.operation.mutation, .changed, file: file, line: line)
        if intent == .trash {
            XCTAssertEqual(report.restorable.map(\.originalURL), urls, file: file, line: line)
        } else {
            XCTAssertTrue(report.restorable.isEmpty, file: file, line: line)
        }
    }
}

private extension Array {
    var single: Element? { count == 1 ? first : nil }
}

private final class LockedFileState: @unchecked Sendable {
    private struct State {
        var existing: Set<String>
        var attemptedPaths: [String] = []
        var existsPaths: [String] = []
        var mutationPaths: [String] = []
        var receiptCounter = 0
    }

    private let lock = NSLock()
    private var state: State

    init(existing: Set<String>) {
        state = State(existing: Set(existing.map {
            URL(fileURLWithPath: $0).standardizedFileURL.path
        }))
    }

    func contains(_ url: URL) -> Bool {
        synchronized { $0.existing.contains(Self.path(url)) }
    }

    func exists(_ url: URL) -> Bool {
        synchronized {
            let path = Self.path(url)
            $0.attemptedPaths.append(path)
            $0.existsPaths.append(path)
            return $0.existing.contains(path)
        }
    }

    func recordRead(_ url: URL) {
        synchronized { $0.attemptedPaths.append(Self.path(url)) }
    }

    func trash(_ url: URL, removeExisting: Bool = true) -> URL {
        synchronized {
            let path = Self.path(url)
            $0.attemptedPaths.append(path)
            $0.mutationPaths.append(path)
            if removeExisting { $0.existing.remove(path) }
            $0.receiptCounter += 1
            return URL(fileURLWithPath: "/tmp/xico-memory-trash")
                .appendingPathComponent("\($0.receiptCounter)-\(url.lastPathComponent)")
        }
    }

    func remove(_ url: URL, removeExisting: Bool = true) {
        synchronized {
            let path = Self.path(url)
            $0.attemptedPaths.append(path)
            $0.mutationPaths.append(path)
            if removeExisting { $0.existing.remove(path) }
        }
    }

    func restore(_ item: RestorableItem) {
        synchronized {
            let path = Self.path(item.originalURL)
            $0.attemptedPaths.append(path)
            $0.mutationPaths.append(path)
            $0.existing.insert(path)
        }
    }

    func markRemovedByHelper(_ url: URL) {
        _ = synchronized { $0.existing.remove(Self.path(url)) }
    }

    var attemptedPaths: [String] { synchronized { $0.attemptedPaths } }
    var existsPaths: [String] { synchronized { $0.existsPaths } }
    var mutatedPaths: [String] { synchronized { $0.mutationPaths } }

    private static func path(_ url: URL) -> String { url.standardizedFileURL.path }

    private func synchronized<T>(_ body: (inout State) -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body(&state)
    }
}

private final class MemoryFS: @unchecked Sendable, FileSystemService {
    fileprivate let state: LockedFileState

    init(existing: Set<String>) {
        state = LockedFileState(existing: existing)
    }

    func exists(_ url: URL) -> Bool { state.exists(url) }
    func contentsOfDirectory(_ url: URL) -> [URL] { state.recordRead(url); return [] }
    func allocatedSize(of url: URL) -> Int64 { state.recordRead(url); return 0 }
    func entry(for url: URL) -> FileEntry? { state.recordRead(url); return nil }
    func trash(_ url: URL) throws -> URL { state.trash(url) }
    func remove(_ url: URL) throws { state.remove(url) }
    func restore(_ item: RestorableItem) throws { state.restore(item) }
    func volumeCapacity(for url: URL) -> VolumeCapacity? { state.recordRead(url); return nil }
    func deepEnumerate(_ url: URL, includeFiles: Bool) -> AsyncStream<FileEntry> {
        state.recordRead(url)
        return AsyncStream { $0.finish() }
    }

    func markRemovedByHelper(_ url: URL) { state.markRemovedByHelper(url) }
    func contains(_ url: URL) -> Bool { state.contains(url) }
    var attemptedPaths: [String] { state.attemptedPaths }
    var existsPaths: [String] { state.existsPaths }
    var mutatedPaths: [String] { state.mutatedPaths }
}

private typealias RecordingFS = MemoryFS

private enum TestFileSystemError: Error {
    case operationFailed
}

private final class ThrowingFS: @unchecked Sendable, FileSystemService {
    private let state: LockedFileState
    private let failing: Set<String>

    init(existing: Set<String>, failing: Set<String>) {
        state = LockedFileState(existing: existing)
        self.failing = Set(failing.map { URL(fileURLWithPath: $0).standardizedFileURL.path })
    }

    func exists(_ url: URL) -> Bool { state.exists(url) }
    func contentsOfDirectory(_ url: URL) -> [URL] { state.recordRead(url); return [] }
    func allocatedSize(of url: URL) -> Int64 { state.recordRead(url); return 0 }
    func entry(for url: URL) -> FileEntry? { state.recordRead(url); return nil }
    func trash(_ url: URL) throws -> URL {
        let shouldFail = failing.contains(url.standardizedFileURL.path)
        let receipt = state.trash(url, removeExisting: !shouldFail)
        if shouldFail { throw TestFileSystemError.operationFailed }
        return receipt
    }
    func remove(_ url: URL) throws {
        let shouldFail = failing.contains(url.standardizedFileURL.path)
        state.remove(url, removeExisting: !shouldFail)
        if shouldFail { throw TestFileSystemError.operationFailed }
    }
    func restore(_ item: RestorableItem) throws { state.restore(item) }
    func volumeCapacity(for url: URL) -> VolumeCapacity? { state.recordRead(url); return nil }
    func deepEnumerate(_ url: URL, includeFiles: Bool) -> AsyncStream<FileEntry> {
        state.recordRead(url)
        return AsyncStream { $0.finish() }
    }
}

private final class SuspendingFS: @unchecked Sendable, FileSystemService {
    private let state: LockedFileState
    private let condition = NSCondition()

    // Lock invariant: condition protects every flag and continuation array below.
    // Continuations are detached while locked and always resumed after unlocking.
    private var mutationStarted = false
    private var released = false
    private var mutationFinished = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var finishWaiters: [CheckedContinuation<Void, Never>] = []

    init(existing: Set<String>) {
        state = LockedFileState(existing: existing)
    }

    func waitUntilFirstMutation() async {
        await withCheckedContinuation { continuation in
            if registerStartWaiter(continuation) {
                continuation.resume()
            }
        }
    }

    func resume() async {
        await withCheckedContinuation { continuation in
            if releaseAndRegisterFinishWaiter(continuation) {
                continuation.resume()
            }
        }
    }

    func exists(_ url: URL) -> Bool { state.exists(url) }
    func contentsOfDirectory(_ url: URL) -> [URL] { state.recordRead(url); return [] }
    func allocatedSize(of url: URL) -> Int64 { state.recordRead(url); return 0 }
    func entry(for url: URL) -> FileEntry? { state.recordRead(url); return nil }
    func trash(_ url: URL) throws -> URL {
        beginMutationAndWaitForRelease()
        let receipt = state.trash(url)
        completeMutation()
        return receipt
    }
    func remove(_ url: URL) throws {
        beginMutationAndWaitForRelease()
        state.remove(url)
        completeMutation()
    }
    func restore(_ item: RestorableItem) throws { state.restore(item) }
    func volumeCapacity(for url: URL) -> VolumeCapacity? { state.recordRead(url); return nil }
    func deepEnumerate(_ url: URL, includeFiles: Bool) -> AsyncStream<FileEntry> {
        state.recordRead(url)
        return AsyncStream { $0.finish() }
    }

    private func registerStartWaiter(_ continuation: CheckedContinuation<Void, Never>) -> Bool {
        condition.lock()
        let shouldResume = mutationStarted
        if !shouldResume { startWaiters.append(continuation) }
        condition.unlock()
        return shouldResume
    }

    private func releaseAndRegisterFinishWaiter(
        _ continuation: CheckedContinuation<Void, Never>
    ) -> Bool {
        condition.lock()
        released = true
        condition.broadcast()
        let shouldResume = mutationFinished
        if !shouldResume { finishWaiters.append(continuation) }
        condition.unlock()
        return shouldResume
    }

    private func beginMutationAndWaitForRelease() {
        condition.lock()
        mutationStarted = true
        let waiters = startWaiters
        startWaiters.removeAll()
        condition.unlock()
        for waiter in waiters { waiter.resume() }

        condition.lock()
        while !released { condition.wait() }
        condition.unlock()
    }

    private func completeMutation() {
        condition.lock()
        mutationFinished = true
        let waiters = finishWaiters
        finishWaiters.removeAll()
        condition.unlock()
        for waiter in waiters { waiter.resume() }
    }
}

private final class RecordingSafety: @unchecked Sendable, SafetyEngine {
    private let lock = NSLock()
    private let verdict: SafetyVerdict
    private var calls = 0

    init(verdict: SafetyVerdict) {
        self.verdict = verdict
    }

    func verify(_ url: URL, intent: DeleteIntent) -> SafetyVerdict {
        lock.lock()
        calls += 1
        lock.unlock()
        return verdict
    }

    var callCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return calls
    }
}

private final class AllowThenDenySafety: @unchecked Sendable, SafetyEngine {
    private let lock = NSLock()
    private var calls = 0

    func verify(_ url: URL, intent: DeleteIntent) -> SafetyVerdict {
        lock.lock()
        calls += 1
        let current = calls
        lock.unlock()
        return current == 1 ? .allow : .deny(reason: "identity changed")
    }
}

private final class ProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0

    func record(_ progress: ScanProgress) {
        lock.lock()
        calls += 1
        lock.unlock()
    }

    var callCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return calls
    }
}

private actor FakePrivileged: PrivilegedCleaningService {
    private let fs: MemoryFS
    private let report: PrivilegedRemovalReport
    private let removesTargets: Bool
    private var calls: [[URL]] = []

    init(fs: MemoryFS,
         report: PrivilegedRemovalReport,
         removesTargets: Bool) {
        self.fs = fs
        self.report = report
        self.removesTargets = removesTargets
    }

    func removeProtected(_ urls: [URL]) async -> PrivilegedRemovalReport {
        calls.append(urls)
        if removesTargets {
            for url in urls { fs.markRemovedByHelper(url) }
        }
        return report
    }

    func snapshot() -> [[URL]] { calls }
}

private actor SuspendingPrivileged: PrivilegedCleaningService {
    private let fs: MemoryFS
    private let report: PrivilegedRemovalReport
    private var calls = 0
    private var firstStarted = false
    private var firstReleaseRequested = false
    private var firstFinished = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var firstReleaseContinuation: CheckedContinuation<Void, Never>?
    private var finishWaiters: [CheckedContinuation<Void, Never>] = []

    init(fs: MemoryFS, report: PrivilegedRemovalReport) {
        self.fs = fs
        self.report = report
    }

    var callCount: Int { calls }

    func waitUntilFirstCall() async {
        if firstStarted { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func resumeFirstCall() async {
        firstReleaseRequested = true
        let release = firstReleaseContinuation
        firstReleaseContinuation = nil
        release?.resume()
        if firstFinished { return }
        await withCheckedContinuation { continuation in
            finishWaiters.append(continuation)
        }
    }

    func removeProtected(_ urls: [URL]) async -> PrivilegedRemovalReport {
        calls += 1
        let currentCall = calls
        if currentCall == 1 {
            firstStarted = true
            let waiters = startWaiters
            startWaiters.removeAll()
            for waiter in waiters { waiter.resume() }
            await withCheckedContinuation { continuation in
                if firstReleaseRequested {
                    continuation.resume()
                } else {
                    firstReleaseContinuation = continuation
                }
            }
        }

        for url in urls { fs.markRemovedByHelper(url) }

        if currentCall == 1 {
            firstFinished = true
            let waiters = finishWaiters
            finishWaiters.removeAll()
            for waiter in waiters { waiter.resume() }
        }
        return report
    }
}
