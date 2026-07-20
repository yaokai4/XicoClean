import Foundation
import XCTest
@testable import Domain

final class CleaningEngineTests: XCTestCase {
    private struct ExternalCompileResult {
        let status: Int32
        let standardOutput: String
        let standardError: String

        var diagnostics: String {
            "stdout:\n\(standardOutput)\nstderr:\n\(standardError)"
        }
    }

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

    func testCleaningPurposesProduceOnlyTheirCanonicalReportKinds() async {
        let cases: [(purpose: CleaningOperationPurpose, kind: OperationKind, name: String)] = [
            (.standard, .cleaningExecute, "standard"),
            (.spaceTrash, .spaceTrash, "space-trash"),
            (.uninstall, .uninstall, "uninstall")
        ]

        for testCase in cases {
            let url = URL(fileURLWithPath: "/tmp/cleaning-purpose-\(testCase.name)")
            let engine = CleaningEngine(
                safety: AllowAllSafety(),
                fs: MemoryFS(existing: [url.path]))
            let ordinary = await engine.execute(
                CleaningPlan(items: [
                    CleanableItem(url: url,
                                  displayName: testCase.name,
                                  size: 10)
                ], intent: .permanent),
                purpose: testCase.purpose)

            XCTAssertEqual(ordinary.operation.kind, testCase.kind, testCase.name)
            XCTAssertEqual(ordinary.operation.status, .success, testCase.name)

            let emptyInternalFailure = await engine.execute(
                CleaningPlan(items: [], intent: .permanent),
                purpose: testCase.purpose)

            XCTAssertEqual(emptyInternalFailure.operation.kind,
                           testCase.kind,
                           testCase.name)
            XCTAssertEqual(emptyInternalFailure.operation.status,
                           .failure,
                           testCase.name)
            XCTAssertTrue(
                emptyInternalFailure.operation.issues.contains {
                    $0.code == "cleaning.request.empty"
                        && $0.category == .internalInvariant
                },
                testCase.name)
        }
    }

    func testExternalClientCanOnlyExecuteCanonicalStandardCleaning() throws {
        let valid = try compileExternalClient("""
        import Domain

        func execute(engine: CleaningEngine, plan: CleaningPlan) async {
            _ = await engine.execute(plan)
            _ = await engine.execute([plan])
        }
        """)

        XCTAssertEqual(valid.status, 0, valid.diagnostics)
        assertNoModuleLoadFailure(valid)

        let inaccessiblePurpose = try compileExternalClient("""
        import Domain

        let purpose: CleaningOperationPurpose = .spaceTrash
        _ = purpose
        """)

        XCTAssertNotEqual(inaccessiblePurpose.status, 0, inaccessiblePurpose.diagnostics)
        XCTAssertTrue(
            inaccessiblePurpose.standardError.contains("CleaningOperationPurpose"),
            inaccessiblePurpose.diagnostics)
        let inaccessibleDiagnostic = inaccessiblePurpose.standardError.lowercased()
        XCTAssertTrue(
            inaccessibleDiagnostic.contains("inaccessible")
                || inaccessibleDiagnostic.contains("protection level")
                || inaccessibleDiagnostic.contains("cannot find"),
            inaccessiblePurpose.diagnostics)
        assertNoModuleLoadFailure(inaccessiblePurpose)

        let externalMerge = try compileExternalClient("""
        import Foundation
        import Domain

        func merge(
            reports: [CleaningReport],
            supplemental: [OperationResult<ThreatRemediationReport>],
            id: UUID,
            order: [UUID]
        ) throws {
            _ = try CleaningReport.merging(
                reports,
                supplemental: supplemental,
                purpose: .standard,
                id: id,
                parentID: nil,
                occurrenceOrder: order)
        }
        """)

        XCTAssertNotEqual(externalMerge.status, 0, externalMerge.diagnostics)
        XCTAssertTrue(
            externalMerge.standardError.localizedCaseInsensitiveContains("inaccessible")
                || externalMerge.standardError.localizedCaseInsensitiveContains(
                    "protection level"),
            externalMerge.diagnostics)
        assertNoModuleLoadFailure(externalMerge)
    }

    func testExternalClientCannotForgeOutcomeOperationSemantics() throws {
        let forgedSemantics = try compileExternalClient("""
        import Domain

        let forged = OutcomeOperationSemantics(
            profile: .celebratory,
            recordsHistory: true,
            allowsCleaningSuccessNotification: true,
            invalidationDomains: [.diskCapacity])
        _ = forged
        """)

        XCTAssertNotEqual(forgedSemantics.status, 0, forgedSemantics.diagnostics)
        XCTAssertTrue(
            forgedSemantics.standardError.contains("OutcomeOperationSemantics"),
            forgedSemantics.diagnostics)
        XCTAssertTrue(
            forgedSemantics.standardError.localizedCaseInsensitiveContains("inaccessible")
                || forgedSemantics.standardError.localizedCaseInsensitiveContains(
                    "protection level"),
            forgedSemantics.diagnostics)
        assertNoModuleLoadFailure(forgedSemantics)
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

    func testCancellationDuringRemediationPreservesDuplicateAndSafetyPreflightFacts() async {
        let duplicate = URL(fileURLWithPath: "/tmp/cancel-preflight-duplicate.plist")
        let denied = URL(fileURLWithPath: "/tmp/cancel-preflight-denied.plist")
        let eligible = URL(fileURLWithPath: "/tmp/cancel-preflight-eligible.plist")
        let fs = RecordingFS(existing: [duplicate.path, denied.path, eligible.path])
        let remediation = SuspendingThreatRemediation()
        let engine = CleaningEngine(
            safety: SelectiveSafety(denied: [denied.path]),
            fs: fs,
            threatRemediation: remediation)
        let task = Task { await engine.execute(CleaningPlan(
            items: [
                CleanableItem(url: duplicate, displayName: "duplicate-1", size: 1),
                CleanableItem(url: duplicate, displayName: "duplicate-2", size: 1),
                CleanableItem(url: denied, displayName: "denied", size: 1),
                CleanableItem(url: eligible, displayName: "eligible", size: 1)
            ],
            intent: .permanent,
            prerequisite: .threatRemediation)) }

        await remediation.waitUntilCall()
        task.cancel()
        await remediation.resume()
        let report = await task.value

        XCTAssertEqual(report.operation.status, .cancelled)
        XCTAssertEqual(report.items.count, 4)
        XCTAssertEqual(report.auxiliaryItems.count, 1)
        for item in report.items.prefix(2) {
            assertIssue(
                item,
                disposition: .failed,
                code: "cleaning.request.duplicateTarget",
                category: .internalInvariant,
                recovery: .chooseAnotherTarget,
                retryable: false)
            XCTAssertEqual(item.mutation, .none)
        }
        assertIssue(
            report.items[2],
            disposition: .skipped,
            code: "cleaning.safety.denied",
            category: .safetyPolicy,
            recovery: .chooseAnotherTarget,
            retryable: false)
        XCTAssertEqual(report.items[2].mutation, .none)
        XCTAssertEqual(report.items[3].disposition, .cancelled(nil))
        XCTAssertEqual(report.items[3].mutation, .none)
        XCTAssertEqual(
            OperationConsumerFacts.retryableCleaningFacts(from: report).map(\.requestID),
            [report.items[3].requestID])
        XCTAssertTrue(fs.attemptedPaths.isEmpty)
        XCTAssertTrue(fs.mutatedPaths.isEmpty)
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

    func testRepeatedCallerItemIDRemainsDistinctWithinOneExecution() async {
        let firstURL = URL(fileURLWithPath: "/tmp/duplicate-a")
        let secondURL = URL(fileURLWithPath: "/tmp/duplicate-b")
        let duplicateID = UUID()
        let fs = RecordingFS(existing: [firstURL.path, secondURL.path])
        let engine = CleaningEngine(safety: AllowAllSafety(), fs: fs)
        let report = await engine.execute(CleaningPlan(items: [
            CleanableItem(id: duplicateID, url: firstURL, displayName: "first", size: 10),
            CleanableItem(id: duplicateID, url: secondURL, displayName: "second", size: 10)
        ], intent: .trash))
        XCTAssertEqual(report.operation.status, .success)
        XCTAssertEqual(report.operation.counts.requested, 2)
        XCTAssertEqual(report.operation.counts.succeeded, 2)
        XCTAssertEqual(report.items.count, 2)
        XCTAssertEqual(report.items.map(\.itemID), [duplicateID, duplicateID])
        XCTAssertEqual(Set(report.items.map(\.requestID)).count, 2)
        XCTAssertEqual(report.items.map(\.disposition), [.succeeded, .succeeded])
        XCTAssertEqual(report.operation.mutation, .changed)
        XCTAssertEqual(fs.mutatedPaths, [firstURL.path, secondURL.path])
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
        XCTAssertEqual(report.operation.counts.failed, 2)
        XCTAssertEqual(report.operation.counts.succeeded, 2)
        XCTAssertEqual(report.items.map(\.itemID), items.map(\.id))
        XCTAssertEqual(report.items.map(\.url), items.map(\.url))
        XCTAssertEqual(report.items.first?.disposition, .succeeded)
        for result in report.items[1...2] {
            assertIssue(result,
                        disposition: .failed,
                        code: "cleaning.request.duplicateTarget",
                        category: .internalInvariant,
                        recovery: .chooseAnotherTarget,
                        retryable: false)
        }
        XCTAssertEqual(report.items.last?.disposition, .succeeded)
        XCTAssertEqual(fs.existsPaths, [firstURL.standardizedFileURL.path,
                                        independentURL.standardizedFileURL.path])
        XCTAssertEqual(fs.mutatedPaths, [firstURL.standardizedFileURL.path,
                                         independentURL.standardizedFileURL.path])
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

    func testCrossPlanDuplicatePathFailsBeforeThreatSafetyFilesystemOrHelper() async {
        let direct = URL(fileURLWithPath: "/Library/Caches/XicoCrossPlanDuplicate.plist")
        let equivalent = URL(
            fileURLWithPath: "/Library/Caches/parent/../XicoCrossPlanDuplicate.plist")
        let safety = RecordingSafety(verdict: .allow)
        let fs = RecordingFS(existing: [direct.path])
        let helper = FakePrivileged(
            fs: fs,
            report: PrivilegedRemovalReport(freedBytes: 0, failures: []),
            removesTargets: true)
        let remediation = RecordingThreatRemediation()
        let engine = CleaningEngine(
            safety: safety,
            fs: fs,
            privileged: helper,
            threatRemediation: remediation)

        let report = await engine.execute([
            CleaningPlan(
                items: [CleanableItem(
                    url: direct,
                    displayName: "first",
                    size: 10)],
                intent: .trash,
                prerequisite: .threatRemediation),
            CleaningPlan(
                items: [CleanableItem(
                    url: equivalent,
                    displayName: "second",
                    size: 10,
                    requiresHelper: true)],
                intent: .permanent)
        ])

        XCTAssertEqual(report.operation.status, .failure)
        XCTAssertEqual(report.operation.counts.failed, 2)
        XCTAssertEqual(report.items.count, 2)
        XCTAssertTrue(report.auxiliaryItems.isEmpty)
        let remediationCalls = await remediation.callCount
        let helperCalls = await helper.snapshot()
        XCTAssertEqual(remediationCalls, 0)
        XCTAssertEqual(safety.callCount, 0)
        XCTAssertTrue(fs.attemptedPaths.isEmpty)
        XCTAssertTrue(fs.mutatedPaths.isEmpty)
        XCTAssertEqual(helperCalls.count, 0)
    }

    func testMixedIntentSmartScanMergesEveryRequestOccurrenceExactlyOnce() async {
        let callerID = UUID()
        let trashURL = URL(fileURLWithPath: "/tmp/xico-mixed-trash")
        let permanentURL = URL(fileURLWithPath: "/tmp/xico-mixed-permanent")
        let threatURL = URL(fileURLWithPath: "/tmp/xico-mixed-agent.plist")
        let fs = RecordingFS(existing: [trashURL.path, permanentURL.path, threatURL.path])
        let remediation = RecordingThreatRemediation()
        let engine = CleaningEngine(
            safety: AllowAllSafety(),
            fs: fs,
            threatRemediation: remediation)
        func item(_ url: URL) -> CleanableItem {
            CleanableItem(
                id: callerID,
                url: url,
                displayName: url.lastPathComponent,
                size: 10)
        }

        let report = await engine.execute([
            CleaningPlan(items: [item(trashURL)], intent: .trash),
            CleaningPlan(items: [item(permanentURL)], intent: .permanent),
            CleaningPlan(
                items: [item(threatURL)],
                intent: .trash,
                prerequisite: .threatRemediation),
        ])

        XCTAssertEqual(report.operation.status, .success)
        XCTAssertEqual(report.operation.counts.requested, 4)
        XCTAssertEqual(report.operation.counts.succeeded, 4)
        XCTAssertEqual(report.items.count, 3)
        XCTAssertEqual(report.items.map(\.itemID), [callerID, callerID, callerID])
        XCTAssertEqual(Set(report.items.map(\.requestID)).count, 3)
        XCTAssertEqual(report.removedCount, 3)
        XCTAssertEqual(report.reclaimedBytes, 30)
        XCTAssertEqual(fs.mutatedPaths, [
            trashURL.path,
            permanentURL.path,
            threatURL.path,
        ])
        XCTAssertEqual(report.facts.count, 4)
        guard case .deletion = report.facts[0],
              case .deletion = report.facts[1],
              case let .deletion(threatDeletion) = report.facts[2],
              case let .auxiliary(remediationFact) = report.facts[3] else {
            return XCTFail("Expected D, D, D, R occurrence order")
        }
        XCTAssertEqual(
            remediationFact.relatedCleaningRequestID,
            threatDeletion.requestID)
        let remediationCallCount = await remediation.callCount
        XCTAssertEqual(remediationCallCount, 1)
    }

    func testInformationalThreatPlanNeverInvokesRemediationSafetyFilesystemOrHelper() async {
        let url = URL(fileURLWithPath: "/Library/LaunchAgents/informational.plist")
        let safety = RecordingSafety(verdict: .allow)
        let fs = RecordingFS(existing: [url.path])
        let helper = FakePrivileged(
            fs: fs,
            report: PrivilegedRemovalReport(freedBytes: 1, failures: []),
            removesTargets: true)
        let remediation = RecordingThreatRemediation()
        let engine = CleaningEngine(
            safety: safety,
            fs: fs,
            privileged: helper,
            threatRemediation: remediation)

        let report = await engine.execute(CleaningPlan(
            items: [CleanableItem(
                url: url,
                displayName: "informational",
                size: 1,
                requiresHelper: true,
                isInformational: true)],
            intent: .permanent,
            prerequisite: .threatRemediation))

        XCTAssertEqual(report.items.single?.disposition, .skipped(OperationIssue(
            code: "cleaning.item.informational",
            category: .safetyPolicy,
            subjectID: report.items.single?.requestID.uuidString,
            recovery: .manualAction,
            retryable: false)))
        XCTAssertTrue(report.auxiliaryItems.isEmpty)
        let helperCalls = await helper.snapshot()
        let remediationCalls = await remediation.callCount
        XCTAssertEqual(safety.callCount, 0)
        XCTAssertTrue(fs.attemptedPaths.isEmpty)
        XCTAssertTrue(fs.mutatedPaths.isEmpty)
        XCTAssertTrue(helperCalls.isEmpty)
        XCTAssertEqual(remediationCalls, 0)
    }

    func testSafetyDeniedThreatPlanNeverInvokesRemediationFilesystemOrHelper() async {
        let url = URL(fileURLWithPath: "/Library/LaunchAgents/denied.plist")
        let safety = RecordingSafety(verdict: .deny(reason: "test.denied"))
        let fs = RecordingFS(existing: [url.path])
        let helper = FakePrivileged(
            fs: fs,
            report: PrivilegedRemovalReport(freedBytes: 1, failures: []),
            removesTargets: true)
        let remediation = RecordingThreatRemediation()
        let engine = CleaningEngine(
            safety: safety,
            fs: fs,
            privileged: helper,
            threatRemediation: remediation)

        let report = await engine.execute(CleaningPlan(
            items: [CleanableItem(
                url: url,
                displayName: "denied",
                size: 1,
                requiresHelper: true)],
            intent: .permanent,
            prerequisite: .threatRemediation))

        guard case let .skipped(issue)? = report.items.single?.disposition else {
            return XCTFail("Expected a denied deletion fact")
        }
        XCTAssertEqual(issue.code, "cleaning.safety.denied")
        XCTAssertTrue(report.auxiliaryItems.isEmpty)
        let helperCalls = await helper.snapshot()
        let remediationCalls = await remediation.callCount
        XCTAssertEqual(safety.callCount, 1)
        XCTAssertTrue(fs.attemptedPaths.isEmpty)
        XCTAssertTrue(fs.mutatedPaths.isEmpty)
        XCTAssertTrue(helperCalls.isEmpty)
        XCTAssertEqual(remediationCalls, 0)
    }

    func testEngineCompoundFailureKeepsDeletionReceiptAndStableDRFacts() async {
        let url = URL(fileURLWithPath: "/tmp/xico-engine-threat.plist")
        let fs = RecordingFS(existing: [url.path])
        let remediation = RecordingThreatRemediation(fails: true)
        let engine = CleaningEngine(
            safety: AllowAllSafety(),
            fs: fs,
            threatRemediation: remediation)
        let report = await engine.execute([
            CleaningPlan(
                items: [CleanableItem(
                    url: url,
                    displayName: "threat",
                    size: 42)],
                intent: .trash,
                prerequisite: .threatRemediation)
        ])

        XCTAssertEqual(report.operation.status, .partial)
        XCTAssertEqual(report.operation.counts.requested, 2)
        XCTAssertEqual(report.operation.counts.succeeded, 1)
        XCTAssertEqual(report.operation.counts.failed, 1)
        XCTAssertEqual(report.operation.mutation, .possiblyChanged)
        XCTAssertEqual(report.removedCount, 1)
        XCTAssertEqual(report.reclaimedBytes, 42)
        XCTAssertEqual(report.restorable.map(\.originalURL), [url])
        XCTAssertEqual(report.items.single?.disposition, .succeeded)
        XCTAssertEqual(report.auxiliaryItems.single?.mutation, .possiblyChanged)
        guard case let .failed(issue)? = report.auxiliaryItems.single?.disposition else {
            return XCTFail("Expected remediation failure fact")
        }
        XCTAssertEqual(issue.code, "test.threat.notConfirmed")
        XCTAssertEqual(issue.subjectID, report.auxiliaryItems.single?.requestID.uuidString)
        XCTAssertEqual(report.facts.count, 2)
        guard case let .deletion(deletion) = report.facts[0],
              case let .auxiliary(auxiliary) = report.facts[1] else {
            return XCTFail("Expected stable D then R fact order")
        }
        XCTAssertEqual(auxiliary.relatedCleaningRequestID, deletion.requestID)
        let remediationCalls = await remediation.callCount
        XCTAssertEqual(remediationCalls, 1)
    }

    func testParentInventoryAdmitsExactFactBudgetForThreatAndPlainRequests() async {
        let cases: [(name: String, count: Int, prerequisite: CleaningPrerequisite)] = [
            ("threat", CleaningOperationLimits.maximumFactCount / 2, .threatRemediation),
            ("plain", CleaningOperationLimits.maximumFactCount, .none)
        ]
        for value in cases {
            let urls = (0..<value.count).map { index in
                URL(fileURLWithPath: value.prerequisite == .threatRemediation
                    ? "/tmp/fact-budget-\(value.name)-\(index).plist"
                    : "/tmp/fact-budget-\(value.name)-\(index)")
            }
            let fs = RecordingFS(existing: Set(urls.map(\.path)))
            let remediation = RecordingThreatRemediation()
            let engine = CleaningEngine(
                safety: AllowAllSafety(),
                fs: fs,
                threatRemediation: remediation)

            let report = await engine.execute(CleaningPlan(
                items: urls.map {
                    CleanableItem(url: $0, displayName: value.name, size: 1)
                },
                intent: .permanent,
                prerequisite: value.prerequisite))
            let remediationCalls = await remediation.callCount

            XCTAssertEqual(report.operation.status, .success, value.name)
            XCTAssertTrue(report.isReducerBacked, value.name)
            XCTAssertEqual(report.items.count, value.count, value.name)
            XCTAssertEqual(
                report.auxiliaryItems.count,
                value.prerequisite == .threatRemediation ? value.count : 0,
                value.name)
            XCTAssertEqual(
                report.facts.count,
                CleaningOperationLimits.maximumFactCount,
                value.name)
            XCTAssertEqual(fs.mutatedPaths.count, value.count, value.name)
            XCTAssertEqual(
                remediationCalls,
                value.prerequisite == .threatRemediation ? 1 : 0,
                value.name)
        }
    }

    func testOversizedParentFactInventoryFailsBeforeEveryDependency() async {
        let cases: [(name: String, count: Int, prerequisite: CleaningPrerequisite)] = [
            ("threat", CleaningOperationLimits.maximumFactCount / 2 + 1,
             .threatRemediation),
            ("plain", CleaningOperationLimits.maximumFactCount + 1, .none),
            ("huge", 10_000, .none)
        ]
        for value in cases {
            let urls = (0..<value.count).map { index in
                URL(fileURLWithPath: value.prerequisite == .threatRemediation
                    ? "/Library/LaunchAgents/limit-\(value.name)-\(index).plist"
                    : "/Library/Caches/limit-\(value.name)-\(index)")
            }
            let fs = RecordingFS(existing: [])
            let safety = RecordingSafety(verdict: .allow)
            let helper = FakePrivileged(
                fs: fs,
                report: PrivilegedRemovalReport(freedBytes: 1, failures: []),
                removesTargets: true)
            let remediation = RecordingThreatRemediation()
            let engine = CleaningEngine(
                safety: safety,
                fs: fs,
                privileged: helper,
                threatRemediation: remediation)
            let plan = CleaningPlan(
                items: urls.map {
                    CleanableItem(
                        url: $0,
                        displayName: "limit",
                        size: 1,
                        requiresHelper: true)
                },
                intent: .permanent,
                prerequisite: value.prerequisite)

            let report = await engine.execute(plan)
            let helperCalls = await helper.snapshot()
            let remediationCalls = await remediation.callCount

            let projectedFactCount = value.prerequisite == .threatRemediation
                ? value.count * 2
                : value.count
            XCTAssertTrue(report.items.isEmpty, value.name)
            XCTAssertTrue(report.auxiliaryItems.isEmpty, value.name)
            XCTAssertTrue(report.facts.isEmpty, value.name)
            XCTAssertEqual(report.operation.status, .failure, value.name)
            XCTAssertTrue(report.isReducerBacked, value.name)
            XCTAssertEqual(
                report.operation.counts.requested,
                projectedFactCount,
                value.name)
            XCTAssertEqual(report.operation.counts.failed, projectedFactCount, value.name)
            XCTAssertEqual(report.operation.mutation, .none, value.name)
            XCTAssertEqual(report.operation.issues.count, 1, value.name)
            XCTAssertEqual(
                report.operation.issues.single,
                OperationIssue(
                    code: "cleaning.request.inventoryLimitExceeded",
                    category: .validation,
                    subjectID: nil,
                    recovery: .chooseAnotherTarget,
                    retryable: false),
                value.name)
            XCTAssertEqual(safety.callCount, 0, value.name)
            XCTAssertTrue(fs.attemptedPaths.isEmpty, value.name)
            XCTAssertTrue(fs.mutatedPaths.isEmpty, value.name)
            XCTAssertTrue(helperCalls.isEmpty, value.name)
            XCTAssertEqual(remediationCalls, 0, value.name)
        }
    }

    func testCompoundMergeKeepsDeletionReceiptAndMakesBootoutFailurePartial() throws {
        let parentID = UUID()
        let cleaningRequestID = UUID()
        let remediationRequestID = UUID()
        let original = URL(fileURLWithPath: "/tmp/threat.plist")
        let receipt = RestorableItem(
            originalURL: original,
            trashedURL: URL(fileURLWithPath: "/tmp/trash/threat.plist"))
        let deletion = try makeCleaningChild(
            operationID: UUID(),
            parentID: parentID,
            requestID: cleaningRequestID,
            itemID: UUID(),
            url: original,
            intent: .trash,
            disposition: .succeeded,
            mutation: .changed,
            bytes: 42,
            receipt: receipt)
        let remediationIssue = OperationIssue(
            code: "threat.remediation.bootout.failed",
            category: .io,
            subjectID: remediationRequestID.uuidString,
            recovery: .retry,
            retryable: true)
        let remediation = try makeThreatChild(
            operationID: UUID(),
            parentID: parentID,
            requestID: remediationRequestID,
            relatedCleaningRequestID: cleaningRequestID,
            url: original,
            disposition: .failed(remediationIssue),
            mutation: .possiblyChanged)

        let merged = try CleaningReport.merging(
            [deletion],
            supplemental: [remediation],
            purpose: .standard,
            id: parentID,
            parentID: nil,
            occurrenceOrder: [cleaningRequestID])

        XCTAssertEqual(merged.operation.id, parentID)
        XCTAssertEqual(merged.operation.status, .partial)
        XCTAssertEqual(merged.operation.counts.requested, 2)
        XCTAssertEqual(merged.operation.counts.succeeded, 1)
        XCTAssertEqual(merged.operation.counts.failed, 1)
        XCTAssertEqual(merged.operation.mutation, .possiblyChanged)
        XCTAssertEqual(merged.removedCount, 1)
        XCTAssertEqual(merged.reclaimedBytes, 42)
        XCTAssertEqual(merged.restorable, [receipt])
        XCTAssertEqual(merged.auxiliaryItems.map(\.requestID), [remediationRequestID])
        XCTAssertEqual(merged.auxiliaryItems.map(\.relatedCleaningRequestID),
                       [cleaningRequestID])
    }

    func testSuccessfulBootoutDoesNotInflateRemovedCount() throws {
        let parentID = UUID()
        let cleaningRequestID = UUID()
        let remediationRequestID = UUID()
        let url = URL(fileURLWithPath: "/tmp/threat-success.plist")
        let deletion = try makeCleaningChild(
            operationID: UUID(),
            parentID: parentID,
            requestID: cleaningRequestID,
            itemID: UUID(),
            url: url,
            intent: .permanent,
            disposition: .succeeded,
            mutation: .changed,
            bytes: 7,
            receipt: nil)
        let remediation = try makeThreatChild(
            operationID: UUID(),
            parentID: parentID,
            requestID: remediationRequestID,
            relatedCleaningRequestID: cleaningRequestID,
            url: url,
            disposition: .succeeded,
            mutation: .changed)

        let merged = try CleaningReport.merging(
            [deletion],
            supplemental: [remediation],
            purpose: .standard,
            id: parentID,
            parentID: nil,
            occurrenceOrder: [cleaningRequestID])

        XCTAssertEqual(merged.operation.status, .success)
        XCTAssertEqual(merged.operation.counts.succeeded, 2)
        XCTAssertEqual(merged.removedCount, 1)
        XCTAssertEqual(merged.reclaimedBytes, 7)
    }

    func testMergeUsesExplicitDeletionThenRemediationOccurrenceOrder() throws {
        let parentID = UUID()
        let firstID = UUID()
        let secondID = UUID()
        let firstURL = URL(fileURLWithPath: "/tmp/ordered-first.plist")
        let secondURL = URL(fileURLWithPath: "/tmp/ordered-second.plist")
        let first = try makeCleaningChild(
            operationID: UUID(), parentID: parentID, requestID: firstID,
            itemID: UUID(), url: firstURL, intent: .permanent,
            disposition: .succeeded, mutation: .changed, bytes: 1, receipt: nil)
        let second = try makeCleaningChild(
            operationID: UUID(), parentID: parentID, requestID: secondID,
            itemID: UUID(), url: secondURL, intent: .permanent,
            disposition: .succeeded, mutation: .changed, bytes: 1, receipt: nil)
        let firstRemediationID = UUID()
        let secondRemediationID = UUID()
        let firstRemediation = try makeThreatChild(
            operationID: UUID(), parentID: parentID,
            requestID: firstRemediationID, relatedCleaningRequestID: firstID,
            url: firstURL, disposition: .unchanged, mutation: .none)
        let secondRemediation = try makeThreatChild(
            operationID: UUID(), parentID: parentID,
            requestID: secondRemediationID, relatedCleaningRequestID: secondID,
            url: secondURL, disposition: .unchanged, mutation: .none)

        let merged = try CleaningReport.merging(
            [second, first],
            supplemental: [secondRemediation, firstRemediation],
            purpose: .standard,
            id: parentID,
            parentID: nil,
            occurrenceOrder: [firstID, secondID])

        let orderedIDs = merged.facts.map { fact -> String in
            switch fact {
            case let .deletion(item): return "D:\(item.requestID.uuidString)"
            case let .auxiliary(item): return "R:\(item.requestID.uuidString)"
            }
        }
        XCTAssertEqual(orderedIDs, [
            "D:\(firstID.uuidString)",
            "R:\(firstRemediationID.uuidString)",
            "D:\(secondID.uuidString)",
            "R:\(secondRemediationID.uuidString)"
        ])
    }

    func testMergeRejectsDuplicateRequestIDAcrossFactRoles() throws {
        let parentID = UUID()
        let requestID = UUID()
        let url = URL(fileURLWithPath: "/tmp/duplicate-role.plist")
        let deletion = try makeCleaningChild(
            operationID: UUID(), parentID: parentID, requestID: requestID,
            itemID: UUID(), url: url, intent: .permanent,
            disposition: .succeeded, mutation: .changed, bytes: 1, receipt: nil)
        let remediation = try makeThreatChild(
            operationID: UUID(), parentID: parentID, requestID: requestID,
            relatedCleaningRequestID: requestID, url: url,
            disposition: .unchanged, mutation: .none)

        XCTAssertThrowsError(try CleaningReport.merging(
            [deletion], supplemental: [remediation], purpose: .standard,
            id: parentID, parentID: nil, occurrenceOrder: [requestID])) { error in
                XCTAssertEqual(
                    (error as? CleaningReportMergeError)?.code,
                    "cleaning.merge.duplicateRequestID")
        }
    }

    func testMergeRejectsAuxiliaryWithoutRelatedDeletion() throws {
        let parentID = UUID()
        let requestID = UUID()
        let url = URL(fileURLWithPath: "/tmp/unbound-role.plist")
        let deletion = try makeCleaningChild(
            operationID: UUID(), parentID: parentID, requestID: requestID,
            itemID: UUID(), url: url, intent: .permanent,
            disposition: .succeeded, mutation: .changed, bytes: 1, receipt: nil)
        let remediation = try makeThreatChild(
            operationID: UUID(), parentID: parentID, requestID: UUID(),
            relatedCleaningRequestID: UUID(), url: url,
            disposition: .unchanged, mutation: .none)

        XCTAssertThrowsError(try CleaningReport.merging(
            [deletion], supplemental: [remediation], purpose: .standard,
            id: parentID, parentID: nil, occurrenceOrder: [requestID])) { error in
                XCTAssertEqual(
                    (error as? CleaningReportMergeError)?.code,
                    "cleaning.merge.invalidAuxiliaryLink")
        }
    }

    func testMergeRejectsChildOutcomeThatDoesNotMatchItsFacts() throws {
        let parentID = UUID()
        let requestID = UUID()
        let url = URL(fileURLWithPath: "/tmp/fact-mismatch")
        let consistent = try makeCleaningChild(
            operationID: UUID(), parentID: parentID, requestID: requestID,
            itemID: UUID(), url: url, intent: .permanent,
            disposition: .succeeded, mutation: .changed, bytes: 1, receipt: nil)
        let issue = OperationIssue(
            code: "test.fact.mismatch", category: .io,
            subjectID: requestID.uuidString, recovery: .retry, retryable: true)
        let inconsistentItem = CleaningItemResult(
            requestID: requestID,
            itemID: UUID(),
            url: url,
            intent: .permanent,
            disposition: .failed(issue),
            mutation: .none,
            reclaimedBytes: 0,
            restorable: nil)
        let inconsistent = CleaningReport(
            operation: consistent.operation,
            items: [inconsistentItem])

        XCTAssertThrowsError(try CleaningReport.merging(
            [inconsistent], supplemental: [], purpose: .standard,
            id: parentID, parentID: nil, occurrenceOrder: [requestID])) { error in
                XCTAssertEqual(
                    (error as? CleaningReportMergeError)?.code,
                    "cleaning.merge.factMismatch")
        }
    }

    func testMergePurposeMismatchCarriesUnregisteredFailClosedReport() throws {
        let parentID = UUID()
        let originalURL = URL(fileURLWithPath: "/tmp/wrong-purpose")
        let receipt = RestorableItem(
            originalURL: originalURL,
            trashedURL: URL(fileURLWithPath: "/tmp/trash/wrong-purpose"))
        let child = try makeCleaningChild(
            operationID: UUID(),
            parentID: parentID,
            requestID: UUID(),
            itemID: UUID(),
            url: originalURL,
            intent: .trash,
            disposition: .succeeded,
            mutation: .changed,
            bytes: 1,
            receipt: receipt,
            kind: .spaceTrash)

        XCTAssertThrowsError(try CleaningReport.merging(
            [child],
            supplemental: [],
            purpose: .standard,
            id: parentID,
            parentID: nil,
            occurrenceOrder: child.items.map(\.requestID))) { error in
                guard let mergeError = error as? CleaningReportMergeError else {
                    return XCTFail("Expected CleaningReportMergeError, got \(error)")
                }
                XCTAssertEqual(mergeError.code, "cleaning.merge.purposeMismatch")
                XCTAssertTrue(mergeError.failClosedReport.isReducerBacked)
                XCTAssertEqual(mergeError.failClosedReport.restorable, [receipt])
                XCTAssertNil(OutcomeOperationRegistry.semantics(
                    for: mergeError.failClosedReport.operation.kind))
                XCTAssertTrue(mergeError.failClosedReport.operation.issues.contains {
                    $0.code == "cleaning.merge.purposeMismatch"
                        && $0.category == .internalInvariant
                })
        }
    }

    func testFailClosedMetadataReplaysStableCodeAndNeverTrustsOutcomeIssues() throws {
        let child = try makeCleaningChild(
            operationID: UUID(),
            parentID: UUID(),
            requestID: UUID(),
            itemID: UUID(),
            url: URL(fileURLWithPath: "/tmp/merge-metadata"),
            intent: .permanent,
            disposition: .succeeded,
            mutation: .changed,
            bytes: 1,
            receipt: nil)
        let now = Date(timeIntervalSinceReferenceDate: 200)
        func report(
            code: String,
            metadata: CleaningReportRejectionMetadata
        ) -> CleaningReport {
            let operation = OperationOutcomeReducer.internalFailure(
                kind: OperationKind("cleaning.merge.rejected"),
                requestedSubjectIDs: child.facts.map { $0.requestID.uuidString },
                itemOutcomes: child.facts.map {
                    OperationItemOutcome(
                        subjectID: $0.requestID.uuidString,
                        disposition: $0.disposition,
                        mutation: $0.mutation,
                        affectedBytes: $0.affectedBytes)
                },
                code: code,
                startedAt: now,
                finishedAt: now)
            return CleaningReport(
                operation: operation,
                facts: child.facts,
                rejectionMetadata: metadata)
        }

        XCTAssertTrue(report(
            code: "cleaning.merge.unexpected",
            metadata: .unexpectedMerge).isReducerBacked)
        XCTAssertFalse(report(
            code: "cleaning.merge.unexpected",
            metadata: .merge(.purposeMismatch)).isReducerBacked)
    }

    func testInventoryLimitMetadataReplaysOnlyTheExactProjectedCount() {
        let now = Date(timeIntervalSinceReferenceDate: 201)
        let projectedFactCount = CleaningOperationLimits.maximumFactCount + 1
        let operation = OperationOutcomeReducer.admissionFailure(
            kind: .cleaningExecute,
            requestedCount: projectedFactCount,
            code: "cleaning.request.inventoryLimitExceeded",
            startedAt: now,
            finishedAt: now)

        let exact = CleaningReport(
            operation: operation,
            facts: [],
            rejectionMetadata: .inventoryLimit(projectedFactCount: projectedFactCount))
        let forgedCount = CleaningReport(
            operation: operation,
            facts: [],
            rejectionMetadata: .inventoryLimit(projectedFactCount: projectedFactCount + 1))

        XCTAssertTrue(exact.isReducerBacked)
        XCTAssertFalse(forgedCount.isReducerBacked)
        XCTAssertEqual(operation.counts, OperationCounts(
            requested: projectedFactCount,
            succeeded: 0,
            unchanged: 0,
            skipped: 0,
            failed: projectedFactCount,
            cancelled: 0))
        XCTAssertEqual(operation.issues, [OperationIssue(
            code: "cleaning.request.inventoryLimitExceeded",
            category: .validation,
            subjectID: nil,
            recovery: .chooseAnotherTarget,
            retryable: false)])
        XCTAssertEqual(operation.mutation, .none)
    }

    func testAuxiliaryOnlyRetryUsesContextDeletionWithoutCallingDeletionDependencies() async throws {
        let url = URL(fileURLWithPath: "/Library/LaunchAgents/com.xico.retry.plist")
        let callerItemID = UUID()
        let priorDeletionID = UUID()
        let priorRemediationID = UUID()
        let authorizedItem = CleanableItem(
            id: callerItemID,
            url: url,
            displayName: "agent",
            size: 32,
            requiresHelper: true)
        let authorization = CleaningRetryAuthorization(
            item: authorizedItem,
            intent: .permanent,
            prerequisite: .threatRemediation)
        let retryToken = try XCTUnwrap(ThreatRemediationRetryToken(
            validatedLabel: "com.xico.retry",
            rootRelativeIdentity: "com.xico.retry.plist"))
        let retryIssue = OperationIssue(
            code: "test.threat.notConfirmed",
            category: .io,
            subjectID: priorRemediationID.uuidString,
            recovery: .retry,
            retryable: true)
        let priorFacts: [CleaningOperationFact] = [
            .deletion(CleaningItemResult(
                requestID: priorDeletionID,
                itemID: callerItemID,
                url: url,
                intent: .permanent,
                prerequisite: .threatRemediation,
                retryAuthorization: authorization,
                disposition: .succeeded,
                mutation: .changed,
                reclaimedBytes: 32,
                restorable: nil)),
            .auxiliary(CleaningAuxiliaryItemResult(
                requestID: priorRemediationID,
                relatedCleaningRequestID: priorDeletionID,
                kind: .threatRemediation,
                disposition: .failed(retryIssue),
                mutation: .possiblyChanged,
                retryToken: retryToken))
        ]
        let prior = try makeParentReport(facts: priorFacts)
        let safety = RecordingSafety(verdict: .allow)
        let fs = RecordingFS(existing: [url.path])
        let helper = FakePrivileged(
            fs: fs,
            report: PrivilegedRemovalReport(freedBytes: 32, failures: []),
            removesTargets: true)
        let remediation = RecordingThreatRemediation()
        let engine = CleaningEngine(
            safety: safety,
            fs: fs,
            privileged: helper,
            threatRemediation: remediation)

        let execution = await engine.retry(prior)
        let retry = execution.report

        XCTAssertEqual(execution.occurrences.count, 1)
        XCTAssertEqual(execution.occurrences[0].priorDeletionOccurrenceIndex, 0)
        XCTAssertFalse(execution.occurrences[0].performedDeletion)
        XCTAssertEqual(retry.operation.kind, .cleaningExecute)
        XCTAssertEqual(retry.operation.parentID, prior.operation.id)
        XCTAssertEqual(retry.operation.status, .success)
        XCTAssertEqual(retry.operation.counts.requested, 2)
        XCTAssertEqual(retry.operation.counts.succeeded, 1)
        XCTAssertEqual(retry.operation.counts.unchanged, 1)
        XCTAssertEqual(retry.removedCount, 0)
        XCTAssertEqual(retry.reclaimedBytes, 0)
        XCTAssertTrue(retry.restorable.isEmpty)
        XCTAssertEqual(retry.facts.count, 2)
        guard case let .deletion(context) = retry.facts[0],
              case let .auxiliary(auxiliary) = retry.facts[1] else {
            return XCTFail("Expected canonical context D then retried R")
        }
        XCTAssertNotEqual(context.requestID, priorDeletionID)
        XCTAssertEqual(execution.occurrences[0].deletionRequestID, context.requestID)
        XCTAssertEqual(context.itemID, callerItemID)
        XCTAssertEqual(context.url, url)
        XCTAssertEqual(context.intent, .permanent)
        XCTAssertEqual(context.prerequisite, .threatRemediation)
        XCTAssertEqual(context.retryAuthorization?.item.requiresHelper, true)
        XCTAssertEqual(context.retryAuthorization?.item.estimatedReclaimableBytes, 32)
        XCTAssertEqual(context.disposition, .unchanged)
        XCTAssertEqual(context.mutation, .none)
        XCTAssertEqual(context.reclaimedBytes, 0)
        XCTAssertNil(context.restorable)
        XCTAssertNotEqual(auxiliary.requestID, priorRemediationID)
        XCTAssertEqual(auxiliary.relatedCleaningRequestID, context.requestID)
        XCTAssertEqual(auxiliary.retryToken, retryToken)
        XCTAssertEqual(auxiliary.disposition, .succeeded)
        XCTAssertEqual(auxiliary.mutation, .changed)
        XCTAssertEqual(safety.callCount, 0)
        XCTAssertTrue(fs.attemptedPaths.isEmpty)
        XCTAssertTrue(fs.mutatedPaths.isEmpty)
        let helperCalls = await helper.snapshot()
        let remediationCalls = await remediation.callCount
        XCTAssertTrue(helperCalls.isEmpty)
        XCTAssertEqual(remediationCalls, 1)
    }

    func testRetryCancellationPreservesContextAndInFlightFacts() async throws {
        let contextURL = URL(fileURLWithPath: "/Library/LaunchAgents/retry-context.plist")
        let inFlightURL = URL(fileURLWithPath: "/Library/Caches/retry-in-flight")
        let eligibleURL = URL(fileURLWithPath: "/Library/LaunchAgents/retry-eligible.plist")
        let contextItem = CleanableItem(
            id: UUID(), url: contextURL, displayName: "context", size: 1)
        let inFlightItem = CleanableItem(
            id: UUID(),
            url: inFlightURL,
            displayName: "in-flight",
            size: 1,
            requiresHelper: true)
        let eligibleItem = CleanableItem(
            id: UUID(), url: eligibleURL, displayName: "eligible", size: 1)
        let contextDeletionID = UUID()
        let contextAuxiliaryID = UUID()
        let inFlightDeletionID = UUID()
        let eligibleDeletionID = UUID()
        let contextToken = try XCTUnwrap(ThreatRemediationRetryToken(
            validatedLabel: "com.xico.retry.context",
            rootRelativeIdentity: contextURL.lastPathComponent))
        let retryIssue: (UUID) -> OperationIssue = { requestID in
            OperationIssue(
                code: "test.retry",
                category: .io,
                subjectID: requestID.uuidString,
                recovery: .retry,
                retryable: true)
        }
        let prior = try makeParentReport(facts: [
            .deletion(CleaningItemResult(
                requestID: contextDeletionID,
                itemID: contextItem.id,
                url: contextURL,
                intent: .permanent,
                prerequisite: .threatRemediation,
                retryAuthorization: CleaningRetryAuthorization(
                    item: contextItem,
                    intent: .permanent,
                    prerequisite: .threatRemediation),
                disposition: .succeeded,
                mutation: .changed,
                reclaimedBytes: 1,
                restorable: nil)),
            .auxiliary(CleaningAuxiliaryItemResult(
                requestID: contextAuxiliaryID,
                relatedCleaningRequestID: contextDeletionID,
                kind: .threatRemediation,
                disposition: .failed(retryIssue(contextAuxiliaryID)),
                mutation: .possiblyChanged,
                retryToken: contextToken)),
            .deletion(CleaningItemResult(
                requestID: inFlightDeletionID,
                itemID: inFlightItem.id,
                url: inFlightURL,
                intent: .permanent,
                retryAuthorization: CleaningRetryAuthorization(
                    item: inFlightItem,
                    intent: .permanent,
                    prerequisite: .none),
                disposition: .failed(retryIssue(inFlightDeletionID)),
                mutation: .none,
                reclaimedBytes: 0,
                restorable: nil)),
            .deletion(CleaningItemResult(
                requestID: eligibleDeletionID,
                itemID: eligibleItem.id,
                url: eligibleURL,
                intent: .permanent,
                prerequisite: .threatRemediation,
                retryAuthorization: CleaningRetryAuthorization(
                    item: eligibleItem,
                    intent: .permanent,
                    prerequisite: .threatRemediation),
                disposition: .failed(retryIssue(eligibleDeletionID)),
                mutation: .none,
                reclaimedBytes: 0,
                restorable: nil))
        ])
        let fs = RecordingFS(existing: [inFlightURL.path, eligibleURL.path])
        let helper = SuspendingPrivileged(
            fs: fs,
            report: PrivilegedRemovalReport(freedBytes: 1, failures: []))
        let remediation = SuspendingThreatRemediation()
        let engine = CleaningEngine(
            safety: AllowAllSafety(),
            fs: fs,
            privileged: helper,
            threatRemediation: remediation)
        let active = Task { await engine.execute(CleaningPlan(
            items: [inFlightItem],
            intent: .permanent)) }

        await helper.waitUntilFirstCall()
        let retry = Task { await engine.retry(prior) }
        await remediation.waitUntilCall()
        retry.cancel()
        await remediation.resume()
        let execution = await retry.value

        XCTAssertEqual(execution.report.operation.status, .cancelled)
        XCTAssertEqual(execution.report.items.count, 3)
        XCTAssertEqual(execution.report.auxiliaryItems.count, 2)
        XCTAssertEqual(execution.report.items[0].disposition, .unchanged)
        XCTAssertEqual(execution.report.items[0].mutation, .none)
        assertIssue(
            execution.report.items[1],
            disposition: .failed,
            code: "cleaning.request.inFlight",
            category: .internalInvariant,
            recovery: .retry,
            retryable: true)
        XCTAssertEqual(execution.report.items[1].mutation, .none)
        XCTAssertEqual(execution.report.items[2].disposition, .cancelled(nil))
        XCTAssertEqual(execution.report.items[2].mutation, .none)
        XCTAssertEqual(
            OperationConsumerFacts.retryableCleaningFacts(from: execution.report)
                .map(\.requestID),
            [execution.report.items[1].requestID, execution.report.items[2].requestID])
        XCTAssertTrue(fs.mutatedPaths.isEmpty)

        await helper.resumeFirstCall()
        _ = await active.value
    }

    func testRetryRejectsEveryAuthorizationBindingMismatchBeforeDependencies() async throws {
        let url = URL(fileURLWithPath: "/tmp/retry-binding.plist")
        let itemID = UUID()
        let deletionID = UUID()
        let authorization = CleaningRetryAuthorization(
            item: CleanableItem(
                id: itemID,
                url: url,
                displayName: "authorized",
                size: 1,
                requiresHelper: true),
            intent: .permanent,
            prerequisite: .none)
        let issue = OperationIssue(
            code: "test.retry",
            category: .io,
            subjectID: deletionID.uuidString,
            recovery: .retry,
            retryable: true)
        func fact(
            itemID valueID: UUID = itemID,
            url valueURL: URL = url,
            intent valueIntent: DeleteIntent = .permanent,
            prerequisite valuePrerequisite: CleaningPrerequisite = .none
        ) -> CleaningOperationFact {
            .deletion(CleaningItemResult(
                requestID: deletionID,
                itemID: valueID,
                url: valueURL,
                intent: valueIntent,
                prerequisite: valuePrerequisite,
                retryAuthorization: authorization,
                disposition: .failed(issue),
                mutation: .none,
                reclaimedBytes: 0,
                restorable: nil))
        }
        let mismatches = try [
            makeParentReport(facts: [fact(itemID: UUID())]),
            makeParentReport(facts: [fact(url: URL(
                fileURLWithPath: "/tmp/retry-binding-other.plist"))]),
            makeParentReport(facts: [fact(intent: .trash)]),
            makeParentReport(facts: [fact(prerequisite: .threatRemediation)])
        ]
        let safety = RecordingSafety(verdict: .allow)
        let fs = RecordingFS(existing: [url.path])
        let helper = FakePrivileged(
            fs: fs,
            report: PrivilegedRemovalReport(freedBytes: 1, failures: []),
            removesTargets: true)
        let remediation = RecordingThreatRemediation()
        let engine = CleaningEngine(
            safety: safety,
            fs: fs,
            privileged: helper,
            threatRemediation: remediation)

        for mismatch in mismatches {
            let execution = await engine.retry(mismatch)
            XCTAssertTrue(execution.occurrences.isEmpty)
            XCTAssertEqual(execution.report.operation.parentID, mismatch.operation.id)
            XCTAssertEqual(
                execution.report.operation.kind,
                OperationKind("cleaning.retry.rejected"))
            XCTAssertTrue(execution.report.operation.issues.contains {
                $0.code == "cleaning.retry.inventoryMismatch"
            })
            XCTAssertNil(OutcomeOperationRegistry.semantics(
                for: execution.report.operation.kind))
        }

        let helperCalls = await helper.snapshot()
        let remediationCalls = await remediation.callCount
        XCTAssertEqual(safety.callCount, 0)
        XCTAssertTrue(fs.attemptedPaths.isEmpty)
        XCTAssertTrue(fs.mutatedPaths.isEmpty)
        XCTAssertTrue(helperCalls.isEmpty)
        XCTAssertEqual(remediationCalls, 0)
    }

    func testRetryRejectsFailedIssueWithoutExactRequestSubjectBeforeDependencies() async throws {
        for issueSubjectID in [nil, UUID().uuidString] as [String?] {
            let url = URL(fileURLWithPath: "/tmp/retry-issue-binding.plist")
            let deletionID = UUID()
            let prior = try makeParentReport(facts: [
                .deletion(retryDeletionFixture(
                    requestID: deletionID,
                    itemID: UUID(),
                    url: url,
                    intent: .permanent,
                    disposition: .failed(OperationIssue(
                        code: "test.retry.issueBinding",
                        category: .io,
                        subjectID: issueSubjectID,
                        recovery: .retry,
                        retryable: true)),
                    authorizedBytes: 1))
            ])
            let safety = RecordingSafety(verdict: .allow)
            let fs = RecordingFS(existing: [url.path])
            let engine = CleaningEngine(safety: safety, fs: fs)

            let execution = await engine.retry(prior)

            XCTAssertTrue(execution.occurrences.isEmpty)
            XCTAssertEqual(
                execution.report.operation.kind,
                OperationKind("cleaning.retry.rejected"))
            XCTAssertTrue(execution.report.operation.issues.contains {
                $0.code == "cleaning.retry.inventoryMismatch"
            })
            XCTAssertEqual(safety.callCount, 0)
            XCTAssertTrue(fs.attemptedPaths.isEmpty)
            XCTAssertTrue(fs.mutatedPaths.isEmpty)
        }
    }

    func testRetryRejectsWrongKindMalformedOrderAndReducerMismatchBeforeDependencies() async throws {
        let url = URL(fileURLWithPath: "/tmp/retry-invalid-prior.plist")
        let itemID = UUID()
        let deletionID = UUID()
        let remediationID = UUID()
        let retryIssue = OperationIssue(
            code: "test.retry",
            category: .io,
            subjectID: deletionID.uuidString,
            recovery: .retry,
            retryable: true)
        let deletion = retryDeletionFixture(
            requestID: deletionID,
            itemID: itemID,
            url: url,
            intent: .permanent,
            prerequisite: .threatRemediation,
            disposition: .failed(retryIssue))
        let auxiliary = CleaningAuxiliaryItemResult(
            requestID: remediationID,
            relatedCleaningRequestID: deletionID,
            kind: .threatRemediation,
            disposition: .unchanged,
            mutation: .none)
        let wrongKind = try makeParentReport(
            facts: [.deletion(deletion), .auxiliary(auxiliary)],
            kind: .spaceTrash)
        let malformedOrder = try makeParentReport(
            facts: [.auxiliary(auxiliary), .deletion(deletion)])
        let now = Date(timeIntervalSinceReferenceDate: 100)
        let inconsistentOutcome = try OperationOutcomeReducer.reduce(
            kind: .cleaningExecute,
            requestedSubjectIDs: [deletionID.uuidString],
            itemOutcomes: [OperationItemOutcome(
                subjectID: deletionID.uuidString,
                disposition: .succeeded,
                mutation: .changed,
                affectedBytes: 1)],
            cancellationAccepted: false,
            startedAt: now,
            finishedAt: now)
        let reducerMismatch = CleaningReport(
            operation: inconsistentOutcome,
            facts: [.deletion(deletion)])
        let safety = RecordingSafety(verdict: .allow)
        let fs = RecordingFS(existing: [url.path])
        let remediation = RecordingThreatRemediation()
        let engine = CleaningEngine(
            safety: safety,
            fs: fs,
            threatRemediation: remediation)

        let rejected = [
            await engine.retry(wrongKind),
            await engine.retry(malformedOrder),
            await engine.retry(reducerMismatch)
        ]

        XCTAssertTrue(rejected.allSatisfy { $0.occurrences.isEmpty })
        XCTAssertTrue(rejected.allSatisfy {
            $0.report.operation.kind == OperationKind("cleaning.retry.rejected")
        })
        XCTAssertTrue(rejected[0].report.operation.issues.contains {
            $0.code == "cleaning.retry.invalidPriorKind"
        })
        XCTAssertTrue(rejected[1].report.operation.issues.contains {
            $0.code == "cleaning.retry.invalidPriorFacts"
        })
        XCTAssertTrue(rejected[2].report.operation.issues.contains {
            $0.code == "cleaning.retry.invalidPriorFacts"
        })
        let remediationCalls = await remediation.callCount
        XCTAssertEqual(safety.callCount, 0)
        XCTAssertTrue(fs.attemptedPaths.isEmpty)
        XCTAssertTrue(fs.mutatedPaths.isEmpty)
        XCTAssertEqual(remediationCalls, 0)
    }

    func testRetryExecutesOnlyRetryableDeletionOccurrenceAndKeepsPriorIndex() async throws {
        let repeatedCallerID = UUID()
        let urls = (0..<3).map {
            URL(fileURLWithPath: "/tmp/retry-deletion-\($0)")
        }
        let firstID = UUID()
        let secondID = UUID()
        let thirdID = UUID()
        let retryableIssue = OperationIssue(
            code: "test.retryable",
            category: .io,
            subjectID: thirdID.uuidString,
            recovery: .retry,
            retryable: true)
        let nonretryableIssue = OperationIssue(
            code: "test.manual",
            category: .safetyPolicy,
            subjectID: secondID.uuidString,
            recovery: .manualAction,
            retryable: false)
        let prior = try makeParentReport(facts: [
            .deletion(retryDeletionFixture(
                requestID: firstID, itemID: repeatedCallerID, url: urls[0],
                intent: .permanent, disposition: .succeeded,
                mutation: .changed, bytes: 3)),
            .deletion(retryDeletionFixture(
                requestID: secondID, itemID: UUID(), url: urls[1],
                intent: .permanent, disposition: .failed(nonretryableIssue),
                authorizedBytes: 5)),
            .deletion(retryDeletionFixture(
                requestID: thirdID, itemID: repeatedCallerID, url: urls[2],
                intent: .permanent, disposition: .failed(retryableIssue),
                authorizedBytes: 7))
        ])
        let fs = RecordingFS(existing: Set(urls.map(\.path)))
        let engine = CleaningEngine(safety: AllowAllSafety(), fs: fs)

        let execution = await engine.retry(prior)
        let report = execution.report

        XCTAssertEqual(execution.occurrences.count, 1)
        XCTAssertEqual(execution.occurrences[0].priorDeletionOccurrenceIndex, 2)
        XCTAssertTrue(execution.occurrences[0].performedDeletion)
        XCTAssertEqual(report.operation.parentID, prior.operation.id)
        XCTAssertEqual(report.items.count, 1)
        XCTAssertEqual(report.items[0].itemID, repeatedCallerID)
        XCTAssertEqual(report.items[0].url, urls[2])
        XCTAssertEqual(report.items[0].disposition, .succeeded)
        XCTAssertEqual(report.removedCount, 1)
        XCTAssertEqual(report.reclaimedBytes, 7)
        XCTAssertEqual(fs.mutatedPaths, [urls[2].standardizedFileURL.path])
        XCTAssertFalse(fs.attemptedPaths.contains(urls[0].standardizedFileURL.path))
        XCTAssertFalse(fs.attemptedPaths.contains(urls[1].standardizedFileURL.path))
    }

    func testDeletionRetryRefreshesPreviouslySuccessfulThreatPrerequisite() async throws {
        let url = URL(fileURLWithPath: "/tmp/retry-deletion-only.plist")
        let itemID = UUID()
        let deletionID = UUID()
        let remediationID = UUID()
        let prior = try makeParentReport(facts: [
            .deletion(retryDeletionFixture(
                requestID: deletionID,
                itemID: itemID,
                url: url,
                intent: .permanent,
                prerequisite: .threatRemediation,
                disposition: .failed(OperationIssue(
                    code: "test.delete.retry",
                    category: .io,
                    subjectID: deletionID.uuidString,
                    recovery: .retry,
                    retryable: true)),
                authorizedBytes: 11)),
            .auxiliary(CleaningAuxiliaryItemResult(
                requestID: remediationID,
                relatedCleaningRequestID: deletionID,
                kind: .threatRemediation,
                disposition: .succeeded,
                mutation: .changed))
        ])
        let fs = RecordingFS(existing: [url.path])
        let remediation = RecordingThreatRemediation(unchanged: true)
        let engine = CleaningEngine(
            safety: AllowAllSafety(),
            fs: fs,
            threatRemediation: remediation)

        let execution = await engine.retry(prior)

        XCTAssertEqual(execution.occurrences.map(\.priorDeletionOccurrenceIndex), [0])
        XCTAssertTrue(execution.occurrences[0].performedDeletion)
        XCTAssertEqual(execution.report.facts.count, 2)
        guard case let .deletion(item) = execution.report.facts[0],
              case let .auxiliary(auxiliary) = execution.report.facts[1] else {
            return XCTFail("Expected refreshed D then R prerequisite facts")
        }
        XCTAssertEqual(item.disposition, .succeeded)
        XCTAssertEqual(auxiliary.relatedCleaningRequestID, item.requestID)
        XCTAssertEqual(auxiliary.disposition, .unchanged)
        XCTAssertEqual(execution.report.operation.status, .success)
        XCTAssertEqual(execution.report.removedCount, 1)
        XCTAssertEqual(execution.report.reclaimedBytes, 11)
        let remediationCalls = await remediation.callCount
        XCTAssertEqual(remediationCalls, 1)
    }

    func testDeletionRetryReportsPartialWhenRefreshedThreatPrerequisiteFails() async throws {
        let url = URL(fileURLWithPath: "/tmp/retry-refreshed-threat-fails.plist")
        let deletionID = UUID()
        let prior = try makeParentReport(facts: [
            .deletion(retryDeletionFixture(
                requestID: deletionID,
                itemID: UUID(),
                url: url,
                intent: .permanent,
                prerequisite: .threatRemediation,
                disposition: .failed(OperationIssue(
                    code: "test.delete.retry",
                    category: .io,
                    subjectID: deletionID.uuidString,
                    recovery: .retry,
                    retryable: true)),
                authorizedBytes: 7)),
            .auxiliary(CleaningAuxiliaryItemResult(
                requestID: UUID(),
                relatedCleaningRequestID: deletionID,
                kind: .threatRemediation,
                disposition: .succeeded,
                mutation: .changed))
        ])
        let fs = RecordingFS(existing: [url.path])
        let remediation = RecordingThreatRemediation(fails: true)
        let engine = CleaningEngine(
            safety: AllowAllSafety(),
            fs: fs,
            threatRemediation: remediation)

        let execution = await engine.retry(prior)
        let remediationCalls = await remediation.callCount

        XCTAssertEqual(execution.report.operation.status, .partial)
        XCTAssertEqual(execution.report.facts.count, 2)
        guard case let .deletion(deletion) = execution.report.facts[0],
              case let .auxiliary(auxiliary) = execution.report.facts[1],
              case let .failed(issue) = auxiliary.disposition else {
            return XCTFail("Expected successful D plus refreshed failed R")
        }
        XCTAssertEqual(deletion.disposition, .succeeded)
        XCTAssertEqual(auxiliary.relatedCleaningRequestID, deletion.requestID)
        XCTAssertEqual(issue.code, "test.threat.notConfirmed")
        XCTAssertEqual(auxiliary.mutation, .possiblyChanged)
        XCTAssertEqual(execution.report.removedCount, 1)
        XCTAssertEqual(remediationCalls, 1)
    }

    func testDeletionAndAuxiliaryRetryPreservesCanonicalDRAndDeletionOnlyMetrics() async throws {
        let url = URL(fileURLWithPath: "/tmp/retry-both.plist")
        let itemID = UUID()
        let deletionID = UUID()
        let remediationID = UUID()
        let token = try XCTUnwrap(ThreatRemediationRetryToken(
            validatedLabel: "com.xico.retry.both",
            rootRelativeIdentity: "retry-both.plist"))
        let prior = try makeParentReport(facts: [
            .deletion(retryDeletionFixture(
                requestID: deletionID,
                itemID: itemID,
                url: url,
                intent: .permanent,
                prerequisite: .threatRemediation,
                disposition: .failed(OperationIssue(
                    code: "test.delete.retry",
                    category: .io,
                    subjectID: deletionID.uuidString,
                    recovery: .retry,
                    retryable: true)),
                authorizedBytes: 13)),
            .auxiliary(CleaningAuxiliaryItemResult(
                requestID: remediationID,
                relatedCleaningRequestID: deletionID,
                kind: .threatRemediation,
                disposition: .failed(OperationIssue(
                    code: "test.threat.retry",
                    category: .io,
                    subjectID: remediationID.uuidString,
                    recovery: .retry,
                    retryable: true)),
                mutation: .possiblyChanged,
                retryToken: token))
        ])
        let fs = RecordingFS(existing: [url.path])
        let remediation = RecordingThreatRemediation()
        let engine = CleaningEngine(
            safety: AllowAllSafety(),
            fs: fs,
            threatRemediation: remediation)

        let execution = await engine.retry(prior)
        let report = execution.report

        XCTAssertEqual(report.operation.parentID, prior.operation.id)
        XCTAssertEqual(report.operation.status, .success)
        XCTAssertEqual(report.operation.counts.succeeded, 2)
        XCTAssertEqual(report.facts.count, 2)
        guard case let .deletion(deletion) = report.facts[0],
              case let .auxiliary(auxiliary) = report.facts[1] else {
            return XCTFail("Expected retried D then R")
        }
        XCTAssertEqual(auxiliary.relatedCleaningRequestID, deletion.requestID)
        XCTAssertEqual(deletion.disposition, .succeeded)
        XCTAssertEqual(auxiliary.disposition, .succeeded)
        XCTAssertEqual(report.removedCount, 1)
        XCTAssertEqual(report.reclaimedBytes, 13)
        XCTAssertEqual(execution.occurrences.count, 1)
        XCTAssertTrue(execution.occurrences[0].performedDeletion)
        let remediationCalls = await remediation.callCount
        XCTAssertEqual(remediationCalls, 1)
        XCTAssertEqual(fs.mutatedPaths, [url.standardizedFileURL.path])
    }

    func testDeletionAndAuxiliaryRetryReReadsChangedPlistAndCannotReportFalseSuccess()
        async throws {
        let url = URL(fileURLWithPath: "/tmp/retry-changed-source.plist")
        let deletionID = UUID()
        let auxiliaryID = UUID()
        let staleToken = try XCTUnwrap(ThreatRemediationRetryToken(
            validatedLabel: "com.xico.stale",
            rootRelativeIdentity: url.lastPathComponent))
        let freshToken = try XCTUnwrap(ThreatRemediationRetryToken(
            validatedLabel: "com.xico.fresh",
            rootRelativeIdentity: url.lastPathComponent))
        let prior = try makeParentReport(facts: [
            .deletion(retryDeletionFixture(
                requestID: deletionID,
                itemID: UUID(),
                url: url,
                intent: .permanent,
                prerequisite: .threatRemediation,
                disposition: .failed(OperationIssue(
                    code: "test.delete.retry",
                    category: .io,
                    subjectID: deletionID.uuidString,
                    recovery: .retry,
                    retryable: true)),
                authorizedBytes: 5)),
            .auxiliary(CleaningAuxiliaryItemResult(
                requestID: auxiliaryID,
                relatedCleaningRequestID: deletionID,
                kind: .threatRemediation,
                disposition: .failed(OperationIssue(
                    code: "test.threat.retry",
                    category: .io,
                    subjectID: auxiliaryID.uuidString,
                    recovery: .retry,
                    retryable: true)),
                mutation: .possiblyChanged,
                retryToken: staleToken))
        ])
        let fs = RecordingFS(existing: [url.path])
        let remediation = ChangedSourceThreatRemediation(
            staleToken: staleToken,
            freshToken: freshToken)
        let engine = CleaningEngine(
            safety: AllowAllSafety(),
            fs: fs,
            threatRemediation: remediation)

        let execution = await engine.retry(prior)
        let receivedTokens = await remediation.receivedRetryTokens

        XCTAssertEqual(receivedTokens.count, 1)
        XCTAssertNil(receivedTokens[0], "D+R retry must re-read the still-present plist")
        XCTAssertEqual(execution.report.operation.status, .partial)
        XCTAssertEqual(execution.report.facts.count, 2)
        guard case let .deletion(deletion) = execution.report.facts[0],
              case let .auxiliary(auxiliary) = execution.report.facts[1],
              case let .failed(issue) = auxiliary.disposition else {
            return XCTFail("Expected successful D and fresh-source R failure")
        }
        XCTAssertEqual(deletion.disposition, .succeeded)
        XCTAssertEqual(auxiliary.relatedCleaningRequestID, deletion.requestID)
        XCTAssertEqual(auxiliary.retryToken, freshToken)
        XCTAssertEqual(issue.code, "test.threat.changedSourceNeedsRemediation")
        XCTAssertEqual(fs.mutatedPaths, [url.standardizedFileURL.path])
    }

    func testExecuteSynthesizesEveryExpectedRemediationWhenExecutorDropsPayload() async {
        let urls = [
            URL(fileURLWithPath: "/tmp/executor-first.plist"),
            URL(fileURLWithPath: "/tmp/executor-second.plist")
        ]
        let fs = RecordingFS(existing: Set(urls.map(\.path)))
        let remediation = MalformedThreatRemediation(mode: .dropLast)
        let engine = CleaningEngine(
            safety: AllowAllSafety(),
            fs: fs,
            threatRemediation: remediation)
        let plan = CleaningPlan(
            items: urls.enumerated().map {
                CleanableItem(
                    url: $0.element,
                    displayName: "executor-\($0.offset)",
                    size: Int64($0.offset + 1))
            },
            intent: .permanent,
            prerequisite: .threatRemediation)

        let report = await engine.execute(plan)

        XCTAssertNotEqual(report.operation.status, .success)
        XCTAssertEqual(report.items.count, 2)
        XCTAssertEqual(report.auxiliaryItems.count, 2)
        XCTAssertEqual(report.facts.count, 4)
        for index in 0..<2 {
            guard case .deletion = report.facts[index * 2],
                  case let .auxiliary(item) = report.facts[index * 2 + 1],
                  case let .failed(issue) = item.disposition else {
                return XCTFail("Expected synthesized D/R failure for occurrence \(index)")
            }
            XCTAssertEqual(issue.code, "threat.remediation.executor.invalidPayload")
            XCTAssertFalse(issue.retryable)
            XCTAssertEqual(item.mutation, .possiblyChanged)
            XCTAssertNil(item.retryToken)
        }
        XCTAssertEqual(report.removedCount, 2)
        XCTAssertEqual(report.reclaimedBytes, 3)
    }

    func testExecuteRejectsRemediationIssueWithoutExactRequestSubject() async {
        let cases: [(MalformedThreatRemediation.Mode, String)] = [
            (.missingIssueSubject, "missing"),
            (.wrongIssueSubject, "wrong")
        ]
        for (mode, suffix) in cases {
            let url = URL(fileURLWithPath: "/tmp/executor-issue-\(suffix).plist")
            let fs = RecordingFS(existing: [url.path])
            let remediation = MalformedThreatRemediation(mode: mode)
            let engine = CleaningEngine(
                safety: AllowAllSafety(),
                fs: fs,
                threatRemediation: remediation)

            let report = await engine.execute(CleaningPlan(
                items: [CleanableItem(
                    url: url,
                    displayName: "executor issue \(suffix)",
                    size: 1)],
                intent: .permanent,
                prerequisite: .threatRemediation))

            guard let auxiliary = report.auxiliaryItems.single,
                  case let .failed(issue) = auxiliary.disposition else {
                XCTFail("Expected synthesized remediation failure for \(suffix)")
                continue
            }
            XCTAssertEqual(issue.code, "threat.remediation.executor.invalidPayload")
            XCTAssertEqual(issue.subjectID, auxiliary.requestID.uuidString)
            XCTAssertEqual(auxiliary.mutation, .possiblyChanged)
        }
    }

    func testAuxiliaryRetrySynthesizesFailureWhenExecutorReturnsWrongURL() async throws {
        let url = URL(fileURLWithPath: "/tmp/executor-retry.plist")
        let itemID = UUID()
        let deletionID = UUID()
        let remediationID = UUID()
        let token = try XCTUnwrap(ThreatRemediationRetryToken(
            validatedLabel: "com.xico.executor.retry",
            rootRelativeIdentity: "executor-retry.plist"))
        let authorization = CleaningRetryAuthorization(
            item: CleanableItem(
                id: itemID, url: url, displayName: "executor retry", size: 5),
            intent: .permanent,
            prerequisite: .threatRemediation)
        let prior = try makeParentReport(facts: [
            .deletion(CleaningItemResult(
                requestID: deletionID,
                itemID: itemID,
                url: url,
                intent: .permanent,
                prerequisite: .threatRemediation,
                retryAuthorization: authorization,
                disposition: .succeeded,
                mutation: .changed,
                reclaimedBytes: 5,
                restorable: nil)),
            .auxiliary(CleaningAuxiliaryItemResult(
                requestID: remediationID,
                relatedCleaningRequestID: deletionID,
                kind: .threatRemediation,
                disposition: .failed(OperationIssue(
                    code: "test.retry",
                    category: .io,
                    subjectID: remediationID.uuidString,
                    recovery: .retry,
                    retryable: true)),
                mutation: .possiblyChanged,
                retryToken: token))
        ])
        let safety = RecordingSafety(verdict: .allow)
        let fs = RecordingFS(existing: [url.path])
        let remediation = MalformedThreatRemediation(mode: .wrongURL)
        let engine = CleaningEngine(
            safety: safety,
            fs: fs,
            threatRemediation: remediation)

        let execution = await engine.retry(prior)
        let report = execution.report

        XCTAssertEqual(execution.occurrences.count, 1)
        XCTAssertFalse(execution.occurrences[0].performedDeletion)
        XCTAssertEqual(report.removedCount, 0)
        XCTAssertEqual(report.reclaimedBytes, 0)
        XCTAssertEqual(report.facts.count, 2)
        guard case let .deletion(context) = report.facts[0],
              case let .auxiliary(auxiliary) = report.facts[1],
              case let .failed(issue) = auxiliary.disposition else {
            return XCTFail("Expected context D and synthesized R failure")
        }
        XCTAssertEqual(context.disposition, .unchanged)
        XCTAssertEqual(auxiliary.relatedCleaningRequestID, context.requestID)
        XCTAssertEqual(auxiliary.retryToken, token)
        XCTAssertEqual(issue.code, "threat.remediation.executor.invalidPayload")
        XCTAssertTrue(issue.retryable)
        XCTAssertEqual(auxiliary.mutation, .possiblyChanged)
        XCTAssertEqual(safety.callCount, 0)
        XCTAssertTrue(fs.attemptedPaths.isEmpty)
        XCTAssertTrue(fs.mutatedPaths.isEmpty)
    }

    func testAuxiliaryOnlyRetryWithoutTokenFailsClosedBeforeDependencies() async throws {
        let url = URL(fileURLWithPath: "/tmp/no-token.plist")
        let itemID = UUID()
        let deletionID = UUID()
        let remediationID = UUID()
        let authorization = CleaningRetryAuthorization(
            item: CleanableItem(
                id: itemID, url: url, displayName: "no token", size: 1),
            intent: .permanent,
            prerequisite: .threatRemediation)
        let prior = try makeParentReport(facts: [
            .deletion(CleaningItemResult(
                requestID: deletionID,
                itemID: itemID,
                url: url,
                intent: .permanent,
                prerequisite: .threatRemediation,
                retryAuthorization: authorization,
                disposition: .succeeded,
                mutation: .changed,
                reclaimedBytes: 1,
                restorable: nil)),
            .auxiliary(CleaningAuxiliaryItemResult(
                requestID: remediationID,
                relatedCleaningRequestID: deletionID,
                kind: .threatRemediation,
                disposition: .failed(OperationIssue(
                    code: "test.noToken",
                    category: .io,
                    subjectID: remediationID.uuidString,
                    recovery: .retry,
                    retryable: true)),
                mutation: .possiblyChanged))
        ])
        let safety = RecordingSafety(verdict: .allow)
        let fs = RecordingFS(existing: [url.path])
        let remediation = RecordingThreatRemediation()
        let engine = CleaningEngine(
            safety: safety,
            fs: fs,
            threatRemediation: remediation)

        let execution = await engine.retry(prior)

        XCTAssertTrue(execution.occurrences.isEmpty)
        XCTAssertEqual(
            execution.report.operation.kind,
            OperationKind("cleaning.retry.rejected"))
        XCTAssertTrue(execution.report.operation.issues.contains {
            $0.code == "cleaning.retry.nothingRetryable"
        })
        let remediationCalls = await remediation.callCount
        XCTAssertEqual(remediationCalls, 0)
        XCTAssertEqual(safety.callCount, 0)
        XCTAssertTrue(fs.attemptedPaths.isEmpty)
        XCTAssertTrue(fs.mutatedPaths.isEmpty)
    }

    func testMutatedDeletionRetryIsRejectedBeforeEveryDependencyAndRetainsReceipts() async throws {
        let mutations: [OperationMutationFact] = [.changed, .possiblyChanged]
        for (index, mutation) in mutations.enumerated() {
            let receiptURL = URL(fileURLWithPath: "/tmp/mutated-retry-receipt-\(index)")
            let receipt = RestorableItem(
                originalURL: receiptURL,
                trashedURL: URL(fileURLWithPath: "/tmp/trash/mutated-retry-\(index)"))
            let receiptID = UUID()
            let receiptItem = CleanableItem(
                id: UUID(), url: receiptURL, displayName: "receipt", size: 4)
            let dangerousURL = URL(
                fileURLWithPath: "/tmp/mutated-retry-danger-\(index).plist")
            let dangerousID = UUID()
            let dangerousItem = CleanableItem(
                id: UUID(),
                url: dangerousURL,
                displayName: "must not retry",
                size: 9,
                requiresHelper: true)
            let prior = try makeParentReport(facts: [
                .deletion(CleaningItemResult(
                    requestID: receiptID,
                    itemID: receiptItem.id,
                    url: receiptURL,
                    intent: .trash,
                    retryAuthorization: CleaningRetryAuthorization(
                        item: receiptItem,
                        intent: .trash,
                        prerequisite: .none),
                    disposition: .succeeded,
                    mutation: .changed,
                    reclaimedBytes: 4,
                    restorable: receipt)),
                .deletion(CleaningItemResult(
                    requestID: dangerousID,
                    itemID: dangerousItem.id,
                    url: dangerousURL,
                    intent: .permanent,
                    prerequisite: .threatRemediation,
                    retryAuthorization: CleaningRetryAuthorization(
                        item: dangerousItem,
                        intent: .permanent,
                        prerequisite: .threatRemediation),
                    disposition: .failed(OperationIssue(
                        code: "test.retry.mutated",
                        category: .io,
                        subjectID: dangerousID.uuidString,
                        recovery: .retry,
                        retryable: true)),
                    mutation: mutation,
                    reclaimedBytes: 0,
                    restorable: nil))
            ])
            let safety = RecordingSafety(verdict: .allow)
            let fs = RecordingFS(existing: [dangerousURL.path])
            let helper = FakePrivileged(
                fs: fs,
                report: PrivilegedRemovalReport(freedBytes: 9, failures: []),
                removesTargets: true)
            let remediation = RecordingThreatRemediation()
            let engine = CleaningEngine(
                safety: safety,
                fs: fs,
                privileged: helper,
                threatRemediation: remediation)

            let execution = await engine.retry(prior)
            let helperCalls = await helper.snapshot()
            let remediationCalls = await remediation.callCount

            XCTAssertTrue(execution.occurrences.isEmpty)
            XCTAssertEqual(
                execution.report.operation.kind,
                OperationKind("cleaning.retry.rejected"))
            XCTAssertTrue(execution.report.operation.issues.contains {
                $0.code == "cleaning.retry.nothingRetryable"
            })
            XCTAssertEqual(execution.retainedReceipts, [CleaningRetryReceipt(
                ownerOperationID: prior.operation.id,
                deletionRequestID: receiptID,
                item: receipt)])
            XCTAssertEqual(safety.callCount, 0)
            XCTAssertTrue(fs.attemptedPaths.isEmpty)
            XCTAssertTrue(fs.mutatedPaths.isEmpty)
            XCTAssertTrue(helperCalls.isEmpty)
            XCTAssertEqual(remediationCalls, 0)
        }
    }

    func testRetryFactBudgetAdmitsExactThreatAndPlainBoundaries() async throws {
        for isThreat in [true, false] {
            let count = isThreat
                ? CleaningOperationLimits.maximumFactCount / 2
                : CleaningOperationLimits.maximumFactCount
            var facts: [CleaningOperationFact] = []
            var urls: [URL] = []
            facts.reserveCapacity(isThreat ? count * 2 : count)
            for index in 0..<count {
                let url = URL(fileURLWithPath: isThreat
                    ? "/Library/LaunchAgents/retry-pass-\(index).plist"
                    : "/tmp/retry-plain-pass-\(index)")
                urls.append(url)
                let item = CleanableItem(
                    id: UUID(), url: url, displayName: "retry pass", size: 1)
                let deletionID = UUID()
                if isThreat {
                    let auxiliaryID = UUID()
                    let token = try XCTUnwrap(ThreatRemediationRetryToken(
                        validatedLabel: "com.xico.retry.pass.\(index)",
                        rootRelativeIdentity: url.lastPathComponent))
                    facts.append(.deletion(CleaningItemResult(
                        requestID: deletionID,
                        itemID: item.id,
                        url: url,
                        intent: .permanent,
                        prerequisite: .threatRemediation,
                        retryAuthorization: CleaningRetryAuthorization(
                            item: item,
                            intent: .permanent,
                            prerequisite: .threatRemediation),
                        disposition: .succeeded,
                        mutation: .changed,
                        reclaimedBytes: 1,
                        restorable: nil)))
                    facts.append(.auxiliary(CleaningAuxiliaryItemResult(
                        requestID: auxiliaryID,
                        relatedCleaningRequestID: deletionID,
                        kind: .threatRemediation,
                        disposition: .failed(OperationIssue(
                            code: "test.retry.pass",
                            category: .io,
                            subjectID: auxiliaryID.uuidString,
                            recovery: .retry,
                            retryable: true)),
                        mutation: .possiblyChanged,
                        retryToken: token)))
                } else {
                    facts.append(.deletion(CleaningItemResult(
                        requestID: deletionID,
                        itemID: item.id,
                        url: url,
                        intent: .permanent,
                        retryAuthorization: CleaningRetryAuthorization(
                            item: item,
                            intent: .permanent,
                            prerequisite: .none),
                        disposition: .failed(OperationIssue(
                            code: "test.retry.pass",
                            category: .io,
                            subjectID: deletionID.uuidString,
                            recovery: .retry,
                            retryable: true)),
                        mutation: .none,
                        reclaimedBytes: 0,
                        restorable: nil)))
                }
            }
            let prior = try makeParentReport(facts: facts)
            let fs = RecordingFS(existing: isThreat ? [] : Set(urls.map(\.path)))
            let remediation = RecordingThreatRemediation()
            let engine = CleaningEngine(
                safety: AllowAllSafety(),
                fs: fs,
                threatRemediation: remediation)

            let execution = await engine.retry(prior)
            let remediationCalls = await remediation.callCount

            XCTAssertEqual(execution.report.operation.status, .success)
            XCTAssertTrue(execution.report.isReducerBacked)
            XCTAssertEqual(
                execution.report.facts.count,
                CleaningOperationLimits.maximumFactCount)
            XCTAssertEqual(execution.occurrences.count, count)
            XCTAssertEqual(
                execution.occurrences.filter(\.performedDeletion).count,
                isThreat ? 0 : count)
            XCTAssertEqual(fs.mutatedPaths.count, isThreat ? 0 : count)
            XCTAssertEqual(remediationCalls, isThreat ? 1 : 0)
        }
    }

    func testOversizedRetryFactInventoryFailsBeforeEveryDependency() async throws {
        for isThreat in [true, false] {
            let count = isThreat
                ? CleaningOperationLimits.maximumFactCount / 2 + 1
                : CleaningOperationLimits.maximumFactCount + 1
            var facts: [CleaningOperationFact] = []
            var retainedReceipt: (requestID: UUID, item: RestorableItem)?
            facts.reserveCapacity(count + (isThreat ? 1 : 0))
            if isThreat {
                let receiptURL = URL(fileURLWithPath: "/tmp/retry-limit-retained")
                let receiptItem = CleanableItem(
                    id: UUID(), url: receiptURL, displayName: "retained", size: 1)
                let receiptID = UUID()
                let receipt = RestorableItem(
                    originalURL: receiptURL,
                    trashedURL: URL(fileURLWithPath: "/tmp/trash/retry-limit-retained"))
                retainedReceipt = (receiptID, receipt)
                facts.append(.deletion(CleaningItemResult(
                    requestID: receiptID,
                    itemID: receiptItem.id,
                    url: receiptURL,
                    intent: .trash,
                    retryAuthorization: CleaningRetryAuthorization(
                        item: receiptItem,
                        intent: .trash,
                        prerequisite: .none),
                    disposition: .succeeded,
                    mutation: .changed,
                    reclaimedBytes: 1,
                    restorable: receipt)))
            }
            for index in 0..<count {
                let url = URL(fileURLWithPath: isThreat
                    ? "/Library/LaunchAgents/retry-limit-\(index).plist"
                    : "/Library/Caches/retry-limit-\(index)")
                let item = CleanableItem(
                    id: UUID(),
                    url: url,
                    displayName: "retry limit",
                    size: 1,
                    requiresHelper: true)
                let deletionID = UUID()
                if isThreat {
                    facts.append(.deletion(CleaningItemResult(
                        requestID: deletionID,
                        itemID: item.id,
                        url: url,
                        intent: .permanent,
                        prerequisite: .threatRemediation,
                        retryAuthorization: CleaningRetryAuthorization(
                            item: item,
                            intent: .permanent,
                            prerequisite: .threatRemediation),
                        disposition: .failed(OperationIssue(
                            code: "test.retry.limit",
                            category: .io,
                            subjectID: deletionID.uuidString,
                            recovery: .retry,
                            retryable: true)),
                        mutation: .none,
                        reclaimedBytes: 0,
                        restorable: nil)))
                } else if index == 0 {
                    let receipt = RestorableItem(
                        originalURL: url,
                        trashedURL: URL(fileURLWithPath: "/tmp/trash/retry-limit-0"))
                    retainedReceipt = (deletionID, receipt)
                    facts.append(.deletion(CleaningItemResult(
                        requestID: deletionID,
                        itemID: item.id,
                        url: url,
                        intent: .trash,
                        retryAuthorization: CleaningRetryAuthorization(
                            item: item,
                            intent: .trash,
                            prerequisite: .none),
                        disposition: .succeeded,
                        mutation: .changed,
                        reclaimedBytes: 1,
                        restorable: receipt)))
                } else {
                    facts.append(.deletion(CleaningItemResult(
                        requestID: deletionID,
                        itemID: item.id,
                        url: url,
                        intent: .permanent,
                        retryAuthorization: CleaningRetryAuthorization(
                            item: item,
                            intent: .permanent,
                            prerequisite: .none),
                        disposition: .failed(OperationIssue(
                            code: "test.retry.limit",
                            category: .io,
                            subjectID: deletionID.uuidString,
                            recovery: .retry,
                            retryable: true)),
                        mutation: .none,
                        reclaimedBytes: 0,
                        restorable: nil)))
                }
            }
            let prior = try makeParentReport(facts: facts)
            let safety = RecordingSafety(verdict: .allow)
            let fs = RecordingFS(existing: [])
            let helper = FakePrivileged(
                fs: fs,
                report: PrivilegedRemovalReport(freedBytes: 1, failures: []),
                removesTargets: true)
            let remediation = RecordingThreatRemediation()
            let engine = CleaningEngine(
                safety: safety,
                fs: fs,
                privileged: helper,
                threatRemediation: remediation)

            let execution = await engine.retry(prior)
            let helperCalls = await helper.snapshot()
            let remediationCalls = await remediation.callCount

            XCTAssertEqual(execution.report.operation.parentID, prior.operation.id)
            XCTAssertTrue(execution.report.isReducerBacked)
            XCTAssertTrue(execution.report.facts.isEmpty)
            XCTAssertTrue(execution.report.items.isEmpty)
            XCTAssertTrue(execution.occurrences.isEmpty)
            let projectedFactCount = isThreat ? count * 2 : facts.count
            XCTAssertEqual(execution.report.operation.counts.requested, projectedFactCount)
            XCTAssertEqual(execution.report.operation.counts.failed, projectedFactCount)
            XCTAssertEqual(execution.report.operation.mutation, .none)
            XCTAssertEqual(execution.report.operation.issues.count, 1)
            XCTAssertEqual(
                execution.report.operation.issues.single,
                OperationIssue(
                    code: "cleaning.request.inventoryLimitExceeded",
                    category: .validation,
                    subjectID: nil,
                    recovery: .chooseAnotherTarget,
                    retryable: false))
            if isThreat, let retainedReceipt {
                XCTAssertEqual(execution.retainedReceipts, [CleaningRetryReceipt(
                    ownerOperationID: prior.operation.id,
                    deletionRequestID: retainedReceipt.requestID,
                    item: retainedReceipt.item)])
            } else {
                XCTAssertTrue(execution.retainedReceipts.isEmpty)
            }
            XCTAssertEqual(safety.callCount, 0)
            XCTAssertTrue(fs.attemptedPaths.isEmpty)
            XCTAssertTrue(fs.mutatedPaths.isEmpty)
            XCTAssertTrue(helperCalls.isEmpty)
            XCTAssertEqual(remediationCalls, 0)
        }
    }

    func testHugePriorRetryProducesBoundedAggregateWithoutTraversingReceiptLedger()
        async throws {
        let count = 10_000
        let facts = (0..<count).map { index -> CleaningOperationFact in
            let url = URL(fileURLWithPath: "/tmp/huge-prior-\(index)")
            return .deletion(CleaningItemResult(
                requestID: UUID(),
                itemID: UUID(),
                url: url,
                intent: .permanent,
                disposition: .succeeded,
                mutation: .changed,
                reclaimedBytes: 1,
                restorable: nil))
        }
        let prior = try makeParentReport(facts: facts)
        let safety = RecordingSafety(verdict: .allow)
        let fs = RecordingFS(existing: [])
        let engine = CleaningEngine(safety: safety, fs: fs)

        let execution = await engine.retry(prior)

        XCTAssertTrue(execution.report.isReducerBacked)
        XCTAssertTrue(execution.report.facts.isEmpty)
        XCTAssertTrue(execution.occurrences.isEmpty)
        XCTAssertTrue(execution.retainedReceipts.isEmpty)
        XCTAssertEqual(execution.report.operation.counts.requested, count)
        XCTAssertEqual(execution.report.operation.counts.failed, count)
        XCTAssertEqual(execution.report.operation.issues.count, 1)
        XCTAssertEqual(
            execution.report.operation.issues.single?.code,
            "cleaning.request.inventoryLimitExceeded")
        XCTAssertEqual(safety.callCount, 0)
        XCTAssertTrue(fs.attemptedPaths.isEmpty)
        XCTAssertTrue(fs.mutatedPaths.isEmpty)
    }

    func testSecondRetryUsesCarriedAuthorizationAndRetainsPriorReceiptOwnership() async throws {
        let receiptOwnerURL = URL(fileURLWithPath: "/tmp/receipt-owner")
        let receipt = RestorableItem(
            originalURL: receiptOwnerURL,
            trashedURL: URL(fileURLWithPath: "/tmp/trash/receipt-owner"))
        let retainedID = UUID()
        let retryURL = URL(fileURLWithPath: "/tmp/second-retry")
        let retryID = UUID()
        let retryIssue = OperationIssue(
            code: "test.retry",
            category: .io,
            subjectID: retryID.uuidString,
            recovery: .retry,
            retryable: true)
        let retainedItem = CleanableItem(
            id: UUID(), url: receiptOwnerURL, displayName: "receipt", size: 4)
        let retryItem = CleanableItem(
            id: UUID(), url: retryURL, displayName: "retry", size: 9,
            requiresHelper: true)
        let prior = try makeParentReport(facts: [
            .deletion(CleaningItemResult(
                requestID: retainedID,
                itemID: retainedItem.id,
                url: receiptOwnerURL,
                intent: .trash,
                retryAuthorization: CleaningRetryAuthorization(
                    item: retainedItem, intent: .trash, prerequisite: .none),
                disposition: .succeeded,
                mutation: .changed,
                reclaimedBytes: 4,
                restorable: receipt)),
            .deletion(CleaningItemResult(
                requestID: retryID,
                itemID: retryItem.id,
                url: retryURL,
                intent: .permanent,
                retryAuthorization: CleaningRetryAuthorization(
                    item: retryItem, intent: .permanent, prerequisite: .none),
                disposition: .failed(retryIssue),
                mutation: .none,
                reclaimedBytes: 0,
                restorable: nil))
        ])
        let firstFS = RecordingFS(existing: [retryURL.path])
        let failing = CleaningEngine(safety: AllowAllSafety(), fs: firstFS)

        let first = await failing.retry(prior)

        XCTAssertEqual(first.occurrences.map(\.priorDeletionOccurrenceIndex), [1])
        XCTAssertEqual(first.report.operation.parentID, prior.operation.id)
        XCTAssertEqual(first.retainedReceipts, [CleaningRetryReceipt(
            ownerOperationID: prior.operation.id,
            deletionRequestID: retainedID,
            item: receipt)])
        XCTAssertEqual(first.report.items.single?.mutation, OperationMutationFact.none)
        XCTAssertEqual(first.report.items.single?.retryAuthorization?.item.requiresHelper, true)
        XCTAssertEqual(
            first.report.items.single?.retryAuthorization?.item.estimatedReclaimableBytes,
            9)
        let secondFS = RecordingFS(existing: [retryURL.path])
        let helper = FakePrivileged(
            fs: secondFS,
            report: PrivilegedRemovalReport(freedBytes: 9, failures: []),
            removesTargets: true)
        let succeeding = CleaningEngine(
            safety: AllowAllSafety(),
            fs: secondFS,
            privileged: helper)

        let second = await succeeding.retry(first.report)
        let helperCalls = await helper.snapshot()

        XCTAssertEqual(second.report.operation.parentID, first.report.operation.id)
        XCTAssertEqual(second.occurrences.map(\.priorDeletionOccurrenceIndex), [0])
        XCTAssertTrue(second.occurrences[0].performedDeletion)
        XCTAssertEqual(second.report.removedCount, 1)
        XCTAssertEqual(second.report.reclaimedBytes, 9)
        XCTAssertEqual(second.retainedReceipts, first.retainedReceipts)
        XCTAssertEqual(second.report.items.single?.retryAuthorization?.item.id, retryItem.id)
        XCTAssertEqual(
            second.report.items.single?.retryAuthorization?.item.estimatedReclaimableBytes,
            9)
        XCTAssertEqual(helperCalls, [[retryURL]])
    }

    func testUndoReturnsReducerBackedPartialAndKeepsOnlyFailedReceipts() async {
        let restored = RestorableItem(
            originalURL: URL(fileURLWithPath: "/tmp/undo-restored"),
            trashedURL: URL(fileURLWithPath: "/tmp/trash/undo-restored"))
        let retained = RestorableItem(
            originalURL: URL(fileURLWithPath: "/tmp/undo-retained"),
            trashedURL: URL(fileURLWithPath: "/tmp/trash/undo-retained"))
        let fs = ThrowingFS(
            existing: [],
            failing: [retained.originalURL.standardizedFileURL.path])
        let engine = CleaningEngine(safety: AllowAllSafety(), fs: fs)
        let parentID = UUID()

        let result = await engine.undo([restored, retained], parentID: parentID)

        XCTAssertEqual(result.outcome.parentID, parentID)
        XCTAssertEqual(result.outcome.kind, .cleaningUndo)
        XCTAssertEqual(result.outcome.status, .partial)
        XCTAssertEqual(result.outcome.counts.requested, 2)
        XCTAssertEqual(result.outcome.counts.succeeded, 1)
        XCTAssertEqual(result.outcome.counts.failed, 1)
        XCTAssertEqual(result.outcome.mutation, .possiblyChanged)
        XCTAssertEqual(result.payload.items.count, 2)
        XCTAssertEqual(Set(result.payload.items.map(\.requestID)).count, 2)
        XCTAssertEqual(result.payload.items.first?.disposition, .succeeded)
        XCTAssertEqual(result.payload.items.first?.mutation, .changed)
        XCTAssertEqual(result.payload.items.first?.restoredURL,
                       restored.originalURL)
        guard case let .failed(issue)? = result.payload.items.last?.disposition else {
            return XCTFail("Expected failed undo fact")
        }
        XCTAssertEqual(issue.code, "cleaning.undo.restoreFailed")
        XCTAssertEqual(issue.category, .io)
        XCTAssertEqual(issue.recovery, .retry)
        XCTAssertTrue(issue.retryable)
        XCTAssertEqual(result.payload.items.last?.mutation, .possiblyChanged)
        XCTAssertNil(result.payload.items.last?.restoredURL)
        XCTAssertEqual(result.payload.restoredCount, 1)
        XCTAssertEqual(result.payload.remaining, [retained])
    }

    func testUndoSuccessCarriesActualRestoredURLAndFailureCarriesNone() async {
        let restored = RestorableItem(
            originalURL: URL(fileURLWithPath: "/tmp/undo-actual-original"),
            trashedURL: URL(fileURLWithPath: "/tmp/trash/undo-actual-original"))
        let alternateURL = URL(fileURLWithPath: "/tmp/undo-actual-original (恢复 1)")
        let retained = RestorableItem(
            originalURL: URL(fileURLWithPath: "/tmp/undo-actual-retained"),
            trashedURL: URL(fileURLWithPath: "/tmp/trash/undo-actual-retained"))
        let fs = RestoreResultFS(
            results: [
                restored.originalURL.standardizedFileURL.path: .success(alternateURL),
                retained.originalURL.standardizedFileURL.path:
                    .failure(TestFileSystemError.operationFailed)
            ],
            existingAfterRestore: Set([alternateURL]))
        let engine = CleaningEngine(safety: AllowAllSafety(), fs: fs)

        let result = await engine.undo([restored, retained])

        XCTAssertEqual(result.payload.items.count, 2)
        XCTAssertEqual(result.payload.items[0].disposition, .succeeded)
        XCTAssertEqual(result.payload.items[0].mutation, .changed)
        XCTAssertEqual(result.payload.items[0].restoredURL, alternateURL)
        guard case .failed = result.payload.items[1].disposition else {
            return XCTFail("Expected the throwing receipt to remain failed")
        }
        XCTAssertEqual(result.payload.items[1].mutation, .possiblyChanged)
        XCTAssertNil(result.payload.items[1].restoredURL)
        XCTAssertEqual(result.payload.remaining, [retained])
    }

    func testUndoRejectsInvalidReturnedRestoreURLAndRetainsExactReceipt() async {
        let invalidCases: [(name: String, returned: URL, existsAfterRestore: Bool)] = [
            ("non-file URL", URL(string: "https://example.invalid/restored")!, true),
            ("same as Trash receipt",
             URL(fileURLWithPath: "/tmp/trash/undo-invalid-same"), true),
            ("reported destination missing",
             URL(fileURLWithPath: "/tmp/undo-invalid-missing"), false)
        ]

        for testCase in invalidCases {
            let original = URL(fileURLWithPath:
                "/tmp/undo-invalid-original-\(UUID().uuidString)")
            let trashed = testCase.name == "same as Trash receipt"
                ? testCase.returned
                : URL(fileURLWithPath:
                    "/tmp/trash/undo-invalid-\(UUID().uuidString)")
            let receipt = RestorableItem(originalURL: original, trashedURL: trashed)
            let existing = testCase.existsAfterRestore ? [testCase.returned] : []
            let fs = RestoreResultFS(
                results: [original.standardizedFileURL.path: .success(testCase.returned)],
                existingAfterRestore: Set(existing))
            let engine = CleaningEngine(safety: AllowAllSafety(), fs: fs)

            let result = await engine.undo([receipt])

            XCTAssertEqual(result.outcome.status, .failure, testCase.name)
            guard let fact = result.payload.items.single,
                  case .failed = fact.disposition else {
                XCTFail("Invalid restore result must be a failed fact: \(testCase.name)")
                continue
            }
            XCTAssertEqual(fact.mutation, .possiblyChanged, testCase.name)
            XCTAssertNil(fact.restoredURL, testCase.name)
            XCTAssertEqual(result.payload.remaining, [receipt], testCase.name)
        }
    }

    func testCancelledUndoDoesNotCarryRestoredURL() async {
        let receipt = RestorableItem(
            originalURL: URL(fileURLWithPath: "/tmp/undo-cancelled"),
            trashedURL: URL(fileURLWithPath: "/tmp/trash/undo-cancelled"))
        let fs = RecordingFS(existing: [])
        let engine = CleaningEngine(safety: AllowAllSafety(), fs: fs)
        let task = Task {
            do {
                try await Task.sleep(for: .seconds(30))
            } catch {}
            return await engine.undo([receipt])
        }

        task.cancel()
        let result = await task.value

        guard let fact = result.payload.items.single,
              case .cancelled = fact.disposition else {
            return XCTFail("A pre-cancelled undo must emit a cancelled fact")
        }
        XCTAssertEqual(fact.mutation, .none)
        XCTAssertNil(fact.restoredURL)
        XCTAssertEqual(result.payload.remaining, [receipt])
        XCTAssertTrue(fs.mutatedPaths.isEmpty)
    }

    func testUnchangedUndoItemCannotCarryRestoredURL() {
        let receipt = RestorableItem(
            originalURL: URL(fileURLWithPath: "/tmp/undo-unchanged"),
            trashedURL: URL(fileURLWithPath: "/tmp/trash/undo-unchanged"))
        let fact = UndoItemResult(
            requestID: UUID(),
            item: receipt,
            disposition: .unchanged,
            mutation: .none,
            restoredURL: receipt.originalURL)

        XCTAssertNil(fact.restoredURL,
                     "Only a succeeded undo fact may expose a restored destination")
    }

    func testUndoRejectsActiveDeletionAtEitherReceiptEndpointWithoutRestore() async {
        for activeEndpoint in 0..<2 {
            let original = URL(fileURLWithPath: "/Library/Caches/undo-active-original-\(activeEndpoint)")
            let trashed = URL(fileURLWithPath: "/tmp/trash/undo-active-\(activeEndpoint)")
            let receipt = RestorableItem(originalURL: original, trashedURL: trashed)
            let activeURL = activeEndpoint == 0 ? original : trashed
            let fs = RecordingFS(existing: [activeURL.path])
            let helper = SuspendingPrivileged(
                fs: fs,
                report: PrivilegedRemovalReport(freedBytes: 1, failures: []))
            let engine = CleaningEngine(
                safety: AllowAllSafety(),
                fs: fs,
                privileged: helper)
            let deletion = Task { await engine.execute(CleaningPlan(
                items: [CleanableItem(
                    url: activeURL,
                    displayName: "active deletion",
                    size: 1,
                    requiresHelper: true)],
                intent: .permanent)) }

            await helper.waitUntilFirstCall()
            let attemptedBeforeUndo = fs.attemptedPaths
            let mutatedBeforeUndo = fs.mutatedPaths
            let undo = await engine.undo([receipt])

            XCTAssertEqual(undo.payload.items.count, 1)
            guard let item = undo.payload.items.single,
                  case let .failed(issue) = item.disposition else {
                XCTFail("Expected typed undo in-flight failure")
                await helper.resumeFirstCall()
                _ = await deletion.value
                continue
            }
            XCTAssertEqual(issue.code, "cleaning.undo.inFlight")
            XCTAssertEqual(issue.subjectID, item.requestID.uuidString)
            XCTAssertEqual(issue.category, .internalInvariant)
            XCTAssertEqual(issue.recovery, .retry)
            XCTAssertTrue(issue.retryable)
            XCTAssertEqual(item.mutation, .none)
            XCTAssertEqual(undo.payload.remaining, [receipt])
            XCTAssertEqual(fs.attemptedPaths, attemptedBeforeUndo)
            XCTAssertEqual(fs.mutatedPaths, mutatedBeforeUndo)

            await helper.resumeFirstCall()
            _ = await deletion.value
        }
    }

    func testUndoRejectsActiveRetryTargetWithoutRestore() async throws {
        let activeURL = URL(fileURLWithPath: "/Library/Caches/undo-active-retry")
        let item = CleanableItem(
            id: UUID(),
            url: activeURL,
            displayName: "active retry",
            size: 1,
            requiresHelper: true)
        let deletionID = UUID()
        let prior = try makeParentReport(facts: [
            .deletion(CleaningItemResult(
                requestID: deletionID,
                itemID: item.id,
                url: activeURL,
                intent: .permanent,
                retryAuthorization: CleaningRetryAuthorization(
                    item: item,
                    intent: .permanent,
                    prerequisite: .none),
                disposition: .failed(OperationIssue(
                    code: "test.retry",
                    category: .io,
                    subjectID: deletionID.uuidString,
                    recovery: .retry,
                    retryable: true)),
                mutation: .none,
                reclaimedBytes: 0,
                restorable: nil))
        ])
        let receipt = RestorableItem(
            originalURL: activeURL,
            trashedURL: URL(fileURLWithPath: "/tmp/trash/undo-active-retry"))
        let fs = RecordingFS(existing: [activeURL.path])
        let helper = SuspendingPrivileged(
            fs: fs,
            report: PrivilegedRemovalReport(freedBytes: 1, failures: []))
        let engine = CleaningEngine(
            safety: AllowAllSafety(),
            fs: fs,
            privileged: helper)
        let retry = Task { await engine.retry(prior) }

        await helper.waitUntilFirstCall()
        let attemptedBeforeUndo = fs.attemptedPaths
        let mutatedBeforeUndo = fs.mutatedPaths
        let undo = await engine.undo([receipt])

        XCTAssertEqual(undo.payload.items.count, 1)
        guard let undoItem = undo.payload.items.single,
              case let .failed(issue) = undoItem.disposition else {
            await helper.resumeFirstCall()
            _ = await retry.value
            return XCTFail("Expected undo in-flight while retry owns target")
        }
        XCTAssertEqual(issue.code, "cleaning.undo.inFlight")
        XCTAssertEqual(undoItem.mutation, .none)
        XCTAssertEqual(fs.attemptedPaths, attemptedBeforeUndo)
        XCTAssertEqual(fs.mutatedPaths, mutatedBeforeUndo)

        await helper.resumeFirstCall()
        _ = await retry.value
    }

    func testUndoRejectsEveryDuplicateEndpointButRestoresUniqueReceiptInOrder() async {
        let shared = URL(fileURLWithPath: "/tmp/undo-shared-endpoint")
        let first = RestorableItem(
            originalURL: shared,
            trashedURL: URL(fileURLWithPath: "/tmp/trash/undo-first"))
        let unique = RestorableItem(
            originalURL: URL(fileURLWithPath: "/tmp/undo-unique"),
            trashedURL: URL(fileURLWithPath: "/tmp/trash/undo-unique"))
        let crossRole = RestorableItem(
            originalURL: URL(fileURLWithPath: "/tmp/undo-cross-role"),
            trashedURL: shared)
        let selfDuplicateURL = URL(fileURLWithPath: "/tmp/undo-self-duplicate")
        let selfDuplicate = RestorableItem(
            originalURL: selfDuplicateURL,
            trashedURL: selfDuplicateURL)
        let fs = RecordingFS(existing: [])
        let engine = CleaningEngine(safety: AllowAllSafety(), fs: fs)

        let result = await engine.undo([first, unique, crossRole, selfDuplicate])

        XCTAssertEqual(result.payload.items.count, 4)
        XCTAssertEqual(result.payload.items.map(\.item), [
            first, unique, crossRole, selfDuplicate
        ])
        XCTAssertEqual(result.payload.items[1].disposition, .succeeded)
        for index in [0, 2, 3] {
            guard case let .failed(issue) = result.payload.items[index].disposition else {
                XCTFail("Expected duplicate failure at index \(index)")
                continue
            }
            XCTAssertEqual(issue.code, "cleaning.undo.duplicateTarget")
            XCTAssertEqual(issue.subjectID, result.payload.items[index].requestID.uuidString)
            XCTAssertEqual(issue.category, .internalInvariant)
            XCTAssertEqual(issue.recovery, .chooseAnotherTarget)
            XCTAssertFalse(issue.retryable)
            XCTAssertEqual(result.payload.items[index].mutation, .none)
        }
        let uniquePath = unique.originalURL.standardizedFileURL.path
        XCTAssertEqual(fs.attemptedPaths, [uniquePath, uniquePath])
        XCTAssertEqual(fs.existsPaths, [uniquePath])
        XCTAssertEqual(fs.mutatedPaths, [unique.originalURL.standardizedFileURL.path])
    }

    func testConcurrentUndoCallsRemainSerializedAndSecondUsesRealReceiptState() async {
        let receipt = RestorableItem(
            originalURL: URL(fileURLWithPath: "/tmp/undo-serialized"),
            trashedURL: URL(fileURLWithPath: "/tmp/trash/undo-serialized"))
        let fs = SingleUseRestoreFS(receipt: receipt)
        let engine = CleaningEngine(safety: AllowAllSafety(), fs: fs)

        async let first = engine.undo([receipt])
        async let second = engine.undo([receipt])
        let results = await [first, second]
        let items = results.compactMap { $0.payload.items.single }

        XCTAssertEqual(items.filter { $0.disposition == .succeeded }.count, 1)
        let failures = items.compactMap { item -> OperationIssue? in
            guard case let .failed(issue) = item.disposition else { return nil }
            return issue
        }
        XCTAssertEqual(failures.map(\.code), ["cleaning.undo.restoreFailed"])
        XCTAssertFalse(failures.contains { $0.code == "cleaning.undo.inFlight" })
        XCTAssertEqual(fs.restoreCallCount, 2)
        XCTAssertEqual(fs.maximumConcurrentRestoreCount, 1)
    }

    func testEmptyUndoFailsClosedWithoutInventingReceiptFacts() async {
        let fs = RecordingFS(existing: [])
        let engine = CleaningEngine(safety: AllowAllSafety(), fs: fs)
        let parentID = UUID()

        let result = await engine.undo([], parentID: parentID)

        XCTAssertEqual(result.outcome.parentID, parentID)
        XCTAssertEqual(result.outcome.kind, .cleaningUndo)
        XCTAssertEqual(result.outcome.status, .failure)
        XCTAssertEqual(result.outcome.counts.requested, 0)
        XCTAssertTrue(result.outcome.issues.contains {
            $0.code == "cleaning.undo.empty" && $0.category == .internalInvariant
        })
        XCTAssertTrue(result.payload.items.isEmpty)
        XCTAssertTrue(result.payload.remaining.isEmpty)
        XCTAssertTrue(fs.mutatedPaths.isEmpty)
    }

    private func makeCleaningChild(
        operationID: UUID,
        parentID: UUID,
        requestID: UUID,
        itemID: UUID,
        url: URL,
        intent: DeleteIntent,
        disposition: OperationDisposition,
        mutation: OperationMutationFact,
        bytes: Int64,
        receipt: RestorableItem?,
        kind: OperationKind = .cleaningExecute
    ) throws -> CleaningReport {
        let item = CleaningItemResult(
            requestID: requestID,
            itemID: itemID,
            url: url,
            intent: intent,
            disposition: disposition,
            mutation: mutation,
            reclaimedBytes: bytes,
            restorable: receipt)
        let now = Date(timeIntervalSinceReferenceDate: 100)
        let outcome = try OperationOutcomeReducer.reduce(
            id: operationID,
            parentID: parentID,
            kind: kind,
            requestedSubjectIDs: [requestID.uuidString],
            itemOutcomes: [OperationItemOutcome(
                subjectID: requestID.uuidString,
                disposition: disposition,
                mutation: mutation,
                affectedBytes: bytes)],
            cancellationAccepted: false,
            startedAt: now,
            finishedAt: now)
        return CleaningReport(operation: outcome, items: [item])
    }

    private func makeParentReport(
        facts: [CleaningOperationFact],
        kind: OperationKind = .cleaningExecute,
        cancellationAccepted: Bool = false
    ) throws -> CleaningReport {
        let now = Date(timeIntervalSinceReferenceDate: 100)
        let outcome = try OperationOutcomeReducer.reduce(
            kind: kind,
            requestedSubjectIDs: facts.map { $0.requestID.uuidString },
            itemOutcomes: facts.map {
                OperationItemOutcome(
                    subjectID: $0.requestID.uuidString,
                    disposition: $0.disposition,
                    mutation: $0.mutation,
                    affectedBytes: $0.affectedBytes)
            },
            cancellationAccepted: cancellationAccepted,
            startedAt: now,
            finishedAt: now)
        return CleaningReport(operation: outcome, facts: facts)
    }

    private func retryDeletionFixture(
        requestID: UUID,
        itemID: UUID,
        url: URL,
        intent: DeleteIntent,
        prerequisite: CleaningPrerequisite = .none,
        disposition: OperationDisposition,
        mutation: OperationMutationFact = .none,
        bytes: Int64 = 0,
        authorizedBytes: Int64? = nil
    ) -> CleaningItemResult {
        let item = CleanableItem(
            id: itemID,
            url: url,
            displayName: "retry fixture",
            size: authorizedBytes ?? max(1, bytes))
        return CleaningItemResult(
            requestID: requestID,
            itemID: itemID,
            url: url,
            intent: intent,
            prerequisite: prerequisite,
            retryAuthorization: CleaningRetryAuthorization(
                item: item,
                intent: intent,
                prerequisite: prerequisite),
            disposition: disposition,
            mutation: mutation,
            reclaimedBytes: bytes,
            restorable: nil)
    }

    private func makeThreatChild(
        operationID: UUID,
        parentID: UUID,
        requestID: UUID,
        relatedCleaningRequestID: UUID,
        url: URL,
        disposition: OperationDisposition,
        mutation: OperationMutationFact
    ) throws -> OperationResult<ThreatRemediationReport> {
        let item = ThreatRemediationItemResult(
            requestID: requestID,
            relatedCleaningRequestID: relatedCleaningRequestID,
            url: url,
            disposition: disposition,
            mutation: mutation)
        let now = Date(timeIntervalSinceReferenceDate: 100)
        let outcome = try OperationOutcomeReducer.reduce(
            id: operationID,
            parentID: parentID,
            kind: .threatRemediation,
            requestedSubjectIDs: [requestID.uuidString],
            itemOutcomes: [OperationItemOutcome(
                subjectID: requestID.uuidString,
                disposition: disposition,
                mutation: mutation)],
            cancellationAccepted: false,
            startedAt: now,
            finishedAt: now)
        return OperationResult(
            outcome: outcome,
            payload: ThreatRemediationReport(items: [item]))
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

    private func compileExternalClient(_ source: String) throws -> ExternalCompileResult {
        let fileManager = FileManager.default
        let temporaryURL = fileManager.temporaryDirectory
            .appendingPathComponent("XicoCleaningPurposeClient-\(UUID().uuidString)",
                                    isDirectory: true)
        try fileManager.createDirectory(at: temporaryURL,
                                        withIntermediateDirectories: false)
        defer { try? fileManager.removeItem(at: temporaryURL) }

        let sourceURL = temporaryURL.appendingPathComponent("client.swift")
        let moduleCacheURL = temporaryURL.appendingPathComponent("module-cache",
                                                                  isDirectory: true)
        try fileManager.createDirectory(at: moduleCacheURL,
                                        withIntermediateDirectories: false)
        try source.write(to: sourceURL, atomically: true, encoding: .utf8)

        let modulesURL = try debugDomainModulesDirectory()
        let cProcessBatchModuleMap = modulesURL
            .deletingLastPathComponent()
            .appendingPathComponent("CProcessBatch.build/module.modulemap")
        guard fileManager.fileExists(atPath: cProcessBatchModuleMap.path) else {
            XCTFail("Expected the debug CProcessBatch module map")
            throw CocoaError(.fileNoSuchFile)
        }
        let standardOutputURL = temporaryURL.appendingPathComponent("stdout.txt")
        let standardErrorURL = temporaryURL.appendingPathComponent("stderr.txt")
        _ = fileManager.createFile(atPath: standardOutputURL.path, contents: nil)
        _ = fileManager.createFile(atPath: standardErrorURL.path, contents: nil)
        let standardOutput = try FileHandle(forWritingTo: standardOutputURL)
        let standardError = try FileHandle(forWritingTo: standardErrorURL)
        defer {
            try? standardOutput.close()
            try? standardError.close()
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = [
            "swiftc",
            "-typecheck",
            "-module-cache-path", moduleCacheURL.path,
            "-I", modulesURL.path,
            "-Xcc", "-fmodule-map-file=\(cProcessBatchModuleMap.path)",
            sourceURL.path
        ]
        process.standardOutput = standardOutput
        process.standardError = standardError
        defer {
            if process.isRunning {
                process.terminate()
                process.waitUntilExit()
            }
        }

        try process.run()
        process.waitUntilExit()
        try standardOutput.synchronize()
        try standardError.synchronize()
        try standardOutput.close()
        try standardError.close()
        let outputData = try Data(contentsOf: standardOutputURL)
        let errorData = try Data(contentsOf: standardErrorURL)

        return ExternalCompileResult(
            status: process.terminationStatus,
            standardOutput: String(decoding: outputData, as: UTF8.self),
            standardError: String(decoding: errorData, as: UTF8.self))
    }

    private func assertNoModuleLoadFailure(
        _ result: ExternalCompileResult,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertFalse(result.standardError.localizedCaseInsensitiveContains("no such module"),
                       result.diagnostics,
                       file: file,
                       line: line)
        XCTAssertFalse(result.standardError.localizedCaseInsensitiveContains(
            "missing required module"),
            result.diagnostics,
            file: file,
            line: line)
    }

    private func debugDomainModulesDirectory() throws -> URL {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let buildURL = repositoryRoot.appendingPathComponent(".build", isDirectory: true)
        let enumerator = FileManager.default.enumerator(
            at: buildURL,
            includingPropertiesForKeys: nil)
        var candidates: [URL] = []
        while let candidate = enumerator?.nextObject() as? URL {
            guard candidate.lastPathComponent == "Domain.swiftmodule" else { continue }
            let modulesURL = candidate.deletingLastPathComponent()
            let targetTriple = modulesURL
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .lastPathComponent
            guard modulesURL.lastPathComponent == "Modules",
                  modulesURL.deletingLastPathComponent().lastPathComponent == "debug",
                  targetTriple.hasPrefix(currentArchitecturePrefix) else {
                continue
            }
            candidates.append(modulesURL)
        }
        return try XCTUnwrap(candidates.sorted { $0.path < $1.path }.first,
                             "Expected a recursively discoverable debug Domain.swiftmodule")
    }

    private var currentArchitecturePrefix: String {
        #if arch(arm64)
        "arm64-"
        #elseif arch(x86_64)
        "x86_64-"
        #else
        ""
        #endif
    }
}

private actor RecordingThreatRemediation: ThreatRemediationExecuting {
    private(set) var callCount = 0
    private let fails: Bool
    private let unchanged: Bool

    init(fails: Bool = false, unchanged: Bool = false) {
        self.fails = fails
        self.unchanged = unchanged
    }

    func remediate(
        _ requests: [ThreatRemediationRequest],
        operationID: UUID,
        parentID: UUID
    ) async -> OperationResult<ThreatRemediationReport> {
        callCount += 1
        let items = requests.map { request in
            let disposition: OperationDisposition
            let mutation: OperationMutationFact
            if fails {
                disposition = .failed(OperationIssue(
                    code: "test.threat.notConfirmed",
                    category: .io,
                    subjectID: request.requestID.uuidString,
                    recovery: .retry,
                    retryable: true))
                mutation = .possiblyChanged
            } else if unchanged {
                disposition = .unchanged
                mutation = .none
            } else {
                disposition = .succeeded
                mutation = .changed
            }
            return ThreatRemediationItemResult(
                requestID: request.requestID,
                relatedCleaningRequestID: request.relatedCleaningRequestID,
                url: request.url,
                disposition: disposition,
                mutation: mutation,
                retryToken: request.retryToken ?? ThreatRemediationRetryToken(
                    validatedLabel: "com.xico.test",
                    rootRelativeIdentity: request.url.lastPathComponent))
        }
        let now = Date(timeIntervalSinceReferenceDate: 100)
        let outcome: OperationOutcome
        do {
            outcome = try OperationOutcomeReducer.reduce(
                id: operationID,
                parentID: parentID,
                kind: .threatRemediation,
                requestedSubjectIDs: items.map { $0.requestID.uuidString },
                itemOutcomes: items.map {
                    OperationItemOutcome(
                        subjectID: $0.requestID.uuidString,
                        disposition: $0.disposition,
                        mutation: $0.mutation)
                },
                cancellationAccepted: false,
                startedAt: now,
                finishedAt: now)
        } catch {
            fatalError("Invalid test remediation fixture: \(error)")
        }
        return OperationResult(
            outcome: outcome,
            payload: ThreatRemediationReport(items: items))
    }
}

private actor SuspendingThreatRemediation: ThreatRemediationExecuting {
    private var started = false
    private var released = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func waitUntilCall() async {
        if started { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func resume() {
        released = true
        let continuation = releaseContinuation
        releaseContinuation = nil
        continuation?.resume()
    }

    func remediate(
        _ requests: [ThreatRemediationRequest],
        operationID: UUID,
        parentID: UUID
    ) async -> OperationResult<ThreatRemediationReport> {
        started = true
        let waiters = startWaiters
        startWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
        await withCheckedContinuation { continuation in
            if released {
                continuation.resume()
            } else {
                releaseContinuation = continuation
            }
        }
        let items = requests.map { request in
            ThreatRemediationItemResult(
                requestID: request.requestID,
                relatedCleaningRequestID: request.relatedCleaningRequestID,
                url: request.url,
                disposition: .succeeded,
                mutation: .changed,
                retryToken: request.retryToken ?? ThreatRemediationRetryToken(
                    validatedLabel: "com.xico.suspended",
                    rootRelativeIdentity: request.url.lastPathComponent))
        }
        let now = Date(timeIntervalSinceReferenceDate: 102)
        let outcome: OperationOutcome
        do {
            outcome = try OperationOutcomeReducer.reduce(
                id: operationID,
                parentID: parentID,
                kind: .threatRemediation,
                requestedSubjectIDs: items.map { $0.requestID.uuidString },
                itemOutcomes: items.map {
                    OperationItemOutcome(
                        subjectID: $0.requestID.uuidString,
                        disposition: $0.disposition,
                        mutation: $0.mutation)
                },
                cancellationAccepted: false,
                startedAt: now,
                finishedAt: now)
        } catch {
            fatalError("Invalid suspended remediation fixture: \(error)")
        }
        return OperationResult(
            outcome: outcome,
            payload: ThreatRemediationReport(items: items))
    }
}

/// Models a plist that was replaced between retry generations. A stale token would falsely report
/// success; a nil token forces a source read, discovers the fresh label, and surfaces its failure.
private actor ChangedSourceThreatRemediation: ThreatRemediationExecuting {
    private let staleToken: ThreatRemediationRetryToken
    private let freshToken: ThreatRemediationRetryToken
    private(set) var receivedRetryTokens: [ThreatRemediationRetryToken?] = []

    init(
        staleToken: ThreatRemediationRetryToken,
        freshToken: ThreatRemediationRetryToken
    ) {
        self.staleToken = staleToken
        self.freshToken = freshToken
    }

    func remediate(
        _ requests: [ThreatRemediationRequest],
        operationID: UUID,
        parentID: UUID
    ) async -> OperationResult<ThreatRemediationReport> {
        receivedRetryTokens.append(contentsOf: requests.map(\.retryToken))
        let items = requests.map { request -> ThreatRemediationItemResult in
            if request.retryToken == staleToken {
                return ThreatRemediationItemResult(
                    requestID: request.requestID,
                    relatedCleaningRequestID: request.relatedCleaningRequestID,
                    url: request.url,
                    disposition: .succeeded,
                    mutation: .changed,
                    retryToken: staleToken)
            }
            return ThreatRemediationItemResult(
                requestID: request.requestID,
                relatedCleaningRequestID: request.relatedCleaningRequestID,
                url: request.url,
                disposition: .failed(OperationIssue(
                    code: "test.threat.changedSourceNeedsRemediation",
                    category: .io,
                    subjectID: request.requestID.uuidString,
                    recovery: .retry,
                    retryable: true)),
                mutation: .none,
                retryToken: freshToken)
        }
        let now = Date(timeIntervalSinceReferenceDate: 101)
        let outcome: OperationOutcome
        do {
            outcome = try OperationOutcomeReducer.reduce(
                id: operationID,
                parentID: parentID,
                kind: .threatRemediation,
                requestedSubjectIDs: items.map { $0.requestID.uuidString },
                itemOutcomes: items.map {
                    OperationItemOutcome(
                        subjectID: $0.requestID.uuidString,
                        disposition: $0.disposition,
                        mutation: $0.mutation)
                },
                cancellationAccepted: false,
                startedAt: now,
                finishedAt: now)
        } catch {
            fatalError("Invalid changed-source remediation fixture: \(error)")
        }
        return OperationResult(
            outcome: outcome,
            payload: ThreatRemediationReport(items: items))
    }
}

private actor MalformedThreatRemediation: ThreatRemediationExecuting {
    enum Mode: Sendable {
        case dropLast
        case wrongURL
        case missingIssueSubject
        case wrongIssueSubject
    }

    private let mode: Mode

    init(mode: Mode) {
        self.mode = mode
    }

    func remediate(
        _ requests: [ThreatRemediationRequest],
        operationID: UUID,
        parentID: UUID
    ) async -> OperationResult<ThreatRemediationReport> {
        var items = requests.map { request in
            ThreatRemediationItemResult(
                requestID: request.requestID,
                relatedCleaningRequestID: request.relatedCleaningRequestID,
                url: request.url,
                disposition: .succeeded,
                mutation: .changed,
                retryToken: request.retryToken ?? ThreatRemediationRetryToken(
                    validatedLabel: "com.xico.malformed",
                    rootRelativeIdentity: request.url.lastPathComponent))
        }
        switch mode {
        case .dropLast:
            _ = items.popLast()
        case .wrongURL:
            if let first = items.first {
                items[0] = ThreatRemediationItemResult(
                    requestID: first.requestID,
                    relatedCleaningRequestID: first.relatedCleaningRequestID,
                    url: URL(fileURLWithPath: "/tmp/wrong-executor.plist"),
                    disposition: first.disposition,
                    mutation: first.mutation,
                    retryToken: first.retryToken)
            }
        case .missingIssueSubject, .wrongIssueSubject:
            if let first = items.first {
                let subjectID: String?
                switch mode {
                case .missingIssueSubject: subjectID = nil
                case .wrongIssueSubject: subjectID = UUID().uuidString
                case .dropLast, .wrongURL: subjectID = nil
                }
                items[0] = ThreatRemediationItemResult(
                    requestID: first.requestID,
                    relatedCleaningRequestID: first.relatedCleaningRequestID,
                    url: first.url,
                    disposition: .failed(OperationIssue(
                        code: "test.malformed.issueSubject",
                        category: .io,
                        subjectID: subjectID,
                        recovery: .retry,
                        retryable: true)),
                    mutation: .none,
                    retryToken: first.retryToken)
            }
        }
        let now = Date(timeIntervalSinceReferenceDate: 100)
        let outcome: OperationOutcome
        if items.isEmpty {
            outcome = OperationOutcomeReducer.internalFailure(
                id: operationID,
                parentID: parentID,
                kind: .threatRemediation,
                requestedSubjectIDs: [],
                code: "test.malformed.empty",
                startedAt: now,
                finishedAt: now)
        } else {
            do {
                outcome = try OperationOutcomeReducer.reduce(
                    id: operationID,
                    parentID: parentID,
                    kind: .threatRemediation,
                    requestedSubjectIDs: items.map { $0.requestID.uuidString },
                    itemOutcomes: items.map {
                        OperationItemOutcome(
                            subjectID: $0.requestID.uuidString,
                            disposition: $0.disposition,
                            mutation: $0.mutation)
                    },
                    cancellationAccepted: false,
                    startedAt: now,
                    finishedAt: now)
            } catch {
                outcome = OperationOutcomeReducer.internalFailure(
                    id: operationID,
                    parentID: parentID,
                    kind: .threatRemediation,
                    requestedSubjectIDs: items.map { $0.requestID.uuidString },
                    code: "test.malformed.reducer",
                    startedAt: now,
                    finishedAt: now)
            }
        }
        return OperationResult(
            outcome: outcome,
            payload: ThreatRemediationReport(items: items))
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

    func restore(_ item: RestorableItem) -> URL {
        synchronized {
            let path = Self.path(item.originalURL)
            $0.attemptedPaths.append(path)
            $0.mutationPaths.append(path)
            $0.existing.insert(path)
            return item.originalURL
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
    func restore(_ item: RestorableItem) throws -> URL { state.restore(item) }
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
    func restore(_ item: RestorableItem) throws -> URL {
        if failing.contains(item.originalURL.standardizedFileURL.path) {
            throw TestFileSystemError.operationFailed
        }
        return state.restore(item)
    }
    func volumeCapacity(for url: URL) -> VolumeCapacity? { state.recordRead(url); return nil }
    func deepEnumerate(_ url: URL, includeFiles: Bool) -> AsyncStream<FileEntry> {
        state.recordRead(url)
        return AsyncStream { $0.finish() }
    }
}

/// Reports a caller-selected restore destination without mutating the real filesystem. This fake
/// lets undo tests distinguish the filesystem's typed receipt from the engine's validation of it.
private final class RestoreResultFS: @unchecked Sendable, FileSystemService {
    private let results: [String: Result<URL, TestFileSystemError>]
    private let existingAfterRestore: Set<String>

    init(results: [String: Result<URL, TestFileSystemError>],
         existingAfterRestore: Set<URL>) {
        self.results = results
        self.existingAfterRestore = Set(existingAfterRestore.map(Self.key))
    }

    func exists(_ url: URL) -> Bool { existingAfterRestore.contains(Self.key(url)) }
    func contentsOfDirectory(_ url: URL) -> [URL] { [] }
    func allocatedSize(of url: URL) -> Int64 { 0 }
    func entry(for url: URL) -> FileEntry? { nil }
    func trash(_ url: URL) throws -> URL { url }
    func remove(_ url: URL) throws {}
    func restore(_ item: RestorableItem) throws -> URL {
        guard let result = results[item.originalURL.standardizedFileURL.path] else {
            throw TestFileSystemError.operationFailed
        }
        return try result.get()
    }
    func volumeCapacity(for url: URL) -> VolumeCapacity? { nil }
    func deepEnumerate(_ url: URL, includeFiles: Bool) -> AsyncStream<FileEntry> {
        AsyncStream { $0.finish() }
    }

    private static func key(_ url: URL) -> String {
        url.isFileURL ? url.standardizedFileURL.path : url.absoluteString
    }
}

private final class SingleUseRestoreFS: @unchecked Sendable, FileSystemService {
    private let lock = NSLock()
    private let receipt: RestorableItem
    private var available = true
    private var restoreCalls = 0
    private var activeRestores = 0
    private var maximumActiveRestores = 0

    init(receipt: RestorableItem) {
        self.receipt = receipt
    }

    func exists(_ url: URL) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return !available
            && url.standardizedFileURL.path
                == receipt.originalURL.standardizedFileURL.path
    }
    func contentsOfDirectory(_ url: URL) -> [URL] { [] }
    func allocatedSize(of url: URL) -> Int64 { 0 }
    func entry(for url: URL) -> FileEntry? { nil }
    func trash(_ url: URL) throws -> URL { url }
    func remove(_ url: URL) throws {}
    func restore(_ item: RestorableItem) throws -> URL {
        lock.lock()
        restoreCalls += 1
        activeRestores += 1
        maximumActiveRestores = max(maximumActiveRestores, activeRestores)
        let succeeds = available && item == receipt
        if succeeds { available = false }
        activeRestores -= 1
        lock.unlock()
        if !succeeds { throw TestFileSystemError.operationFailed }
        return item.originalURL
    }
    func volumeCapacity(for url: URL) -> VolumeCapacity? { nil }
    func deepEnumerate(_ url: URL, includeFiles: Bool) -> AsyncStream<FileEntry> {
        AsyncStream { $0.finish() }
    }

    var restoreCallCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return restoreCalls
    }

    var maximumConcurrentRestoreCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return maximumActiveRestores
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
    func restore(_ item: RestorableItem) throws -> URL { state.restore(item) }
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

private struct SelectiveSafety: SafetyEngine {
    private let denied: Set<String>

    init(denied: Set<String>) {
        self.denied = Set(denied.map {
            URL(fileURLWithPath: $0).standardizedFileURL.path
        })
    }

    func verify(_ url: URL, intent: DeleteIntent) -> SafetyVerdict {
        denied.contains(url.standardizedFileURL.path)
            ? .deny(reason: "test denial")
            : .allow
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
