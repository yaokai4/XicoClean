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

    func testInternalFailureWithZeroRequestsIsFailure() {
        let outcome = OperationOutcomeReducer.internalFailure(
            kind: kind,
            requestedSubjectIDs: [],
            code: "cleaning.request.empty",
            startedAt: start,
            finishedAt: finish)

        XCTAssertEqual(outcome.status, .failure)
        XCTAssertEqual(outcome.counts, OperationCounts(requested: 0, succeeded: 0,
                                                       unchanged: 0, skipped: 0,
                                                       failed: 0, cancelled: 0))
        XCTAssertTrue(outcome.issues.contains {
            $0.code == "cleaning.request.empty" && $0.category == .internalInvariant
        })
    }

    func testInternalFailurePreservesCompletedFactsAndAddsInvariantIssue() {
        let originalIssue = OperationIssue(code: "cleaning.filesystem.operationFailed",
                                           category: .io,
                                           subjectID: "c",
                                           recovery: .retry,
                                           retryable: true)
        let outcome = OperationOutcomeReducer.internalFailure(
            kind: kind,
            requestedSubjectIDs: ["a", "b", "c"],
            itemOutcomes: [
                item("a", .succeeded, bytes: 10),
                item("b", .unchanged),
                item("c", .failed(originalIssue))
            ],
            code: "cleaning.reducer.invariant",
            startedAt: start,
            finishedAt: finish)

        XCTAssertEqual(outcome.status, .partial)
        XCTAssertEqual(outcome.counts, OperationCounts(requested: 3, succeeded: 1,
                                                       unchanged: 1, skipped: 0,
                                                       failed: 1, cancelled: 0))
        XCTAssertTrue(outcome.issues.contains { $0 == originalIssue })
        XCTAssertTrue(outcome.issues.contains {
            $0.code == "cleaning.reducer.invariant" && $0.category == .internalInvariant
        })
    }

    func testInternalFailureAcceptedCancellationWinsAndPreservesCompletedFacts() {
        let outcome = OperationOutcomeReducer.internalFailure(
            kind: kind,
            requestedSubjectIDs: ["a", "b"],
            itemOutcomes: [item("a", .succeeded, bytes: 10)],
            cancellationAccepted: true,
            code: "cleaning.reducer.invariant",
            startedAt: start,
            finishedAt: finish)

        XCTAssertEqual(outcome.status, .cancelled)
        XCTAssertEqual(outcome.counts.succeeded, 1)
        XCTAssertEqual(outcome.counts.cancelled, 1)
    }

    func testInternalFailureClampsFinishedAtToStartedAt() {
        let outcome = OperationOutcomeReducer.internalFailure(
            kind: kind,
            requestedSubjectIDs: ["a"],
            itemOutcomes: [item("a", .succeeded)],
            code: "cleaning.reducer.invariant",
            startedAt: finish,
            finishedAt: start)

        XCTAssertEqual(outcome.startedAt, finish)
        XCTAssertEqual(outcome.finishedAt, finish)
    }

    func testInternalFailureDuplicateRequestedSubjectsCannotDoubleCountSingleOutcome() {
        let outcome = OperationOutcomeReducer.internalFailure(
            kind: kind,
            requestedSubjectIDs: ["a", "a"],
            itemOutcomes: [item("a", .succeeded, bytes: 10)],
            code: "cleaning.reducer.invariant",
            startedAt: start,
            finishedAt: finish)

        XCTAssertEqual(outcome.status, .failure)
        XCTAssertEqual(outcome.counts, OperationCounts(requested: 2, succeeded: 0,
                                                       unchanged: 0, skipped: 0,
                                                       failed: 2, cancelled: 0))
        XCTAssertTrue(outcome.issues.contains {
            $0 == OperationIssue(code: "operation.request.duplicate",
                                 category: .internalInvariant,
                                 subjectID: "a",
                                 recovery: .retry,
                                 retryable: true)
        })
    }

    func testIssueOrderingUsesFullStableTuple() throws {
        let categories: [OperationIssueCategory] = [
            .permission, .safetyPolicy, .notFound, .identityChanged, .io, .network,
            .authentication, .validation, .timeout, .unavailable, .internalInvariant
        ]
        let recoveries: [OperationRecoveryHint] = [
            .retry, .grantPermission, .installHelper, .reauthenticate,
            .chooseAnotherTarget, .revealInFinder, .openSettings, .manualAction, .none
        ]
        let issues = categories.flatMap { category in
            recoveries.flatMap { recovery in
                [false, true].map { retryable in
                    OperationIssue(code: "same.code",
                                   category: category,
                                   subjectID: "same-subject",
                                   recovery: recovery,
                                   retryable: retryable)
                }
            }
        }
        let requested = issues.indices.map { "requested-\($0)" }
        let outcomes = zip(requested, issues).map {
            item($0.0, .failed($0.1))
        }

        let outcome = try reduce(requested, outcomes)
        let expected = issues.sorted(by: issueComesBefore)

        XCTAssertEqual(outcome.issues, expected)
    }

    func testCleaningFactConstructorsStayDomainInternal() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let modelsURL = repositoryRoot.appendingPathComponent("Sources/Domain/Models.swift")
        let source = try String(contentsOf: modelsURL, encoding: .utf8)

        XCTAssertFalse(source.contains("public init(requestID: UUID"),
                       "CleaningItemResult construction must remain inside Domain")
        XCTAssertFalse(source.contains("public init(operation: OperationOutcome"),
                       "Fact-backed CleaningReport construction must remain inside Domain")
        XCTAssertTrue(source.contains("public init(removedCount: Int"),
                      "The temporary fail-closed legacy boundary remains public until Task 5")
    }

    func testLegacyCompatibilityUsesFixedSentinelRatherThanAggregateSizedIDs() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let modelsURL = repositoryRoot.appendingPathComponent("Sources/Domain/Models.swift")
        let source = try String(contentsOf: modelsURL, encoding: .utf8)
        let failure = CleaningFailure(url: URL(fileURLWithPath: "/tmp/legacy-failure"),
                                      reason: "legacy")

        XCTAssertFalse(source.contains("let countFromFacts"))
        XCTAssertFalse(source.contains("(0..<requested).map"),
                       "Legacy aggregates must never synthesize one ID per aggregate count")

        let report = CleaningReport(removedCount: 3,
                                    reclaimedBytes: 7,
                                    failures: [failure],
                                    restorable: [])

        XCTAssertEqual(report.operation.status, .failure)
        XCTAssertEqual(report.operation.counts.requested, 1)
        XCTAssertEqual(report.removedCount, 3)
        XCTAssertEqual(report.reclaimedBytes, 7)
        XCTAssertEqual(report.failures.count, 1)
        XCTAssertTrue(report.items.isEmpty)
    }

    func testOperationOutcomeCannotRegainADecodableConstructionBoundary() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let outcomeURL = repositoryRoot
            .appendingPathComponent("Sources/Domain/OperationOutcome.swift")
        let source = try String(contentsOf: outcomeURL, encoding: .utf8)

        XCTAssertFalse(source.contains("struct OperationOutcome: Codable"))
        XCTAssertFalse(source.contains("struct OperationOutcome: Decodable"))
        XCTAssertTrue(source.contains("struct OperationOutcome: Encodable"),
                      "Persistence must encode through the trusted fact and decode through a DTO")
    }

    private func issueComesBefore(_ lhs: OperationIssue, _ rhs: OperationIssue) -> Bool {
        let lhsSubject = lhs.subjectID ?? ""
        let rhsSubject = rhs.subjectID ?? ""
        if lhsSubject != rhsSubject { return lhsSubject < rhsSubject }
        if lhs.code != rhs.code { return lhs.code < rhs.code }
        if lhs.category.rawValue != rhs.category.rawValue {
            return lhs.category.rawValue < rhs.category.rawValue
        }
        if lhs.recovery.rawValue != rhs.recovery.rawValue {
            return lhs.recovery.rawValue < rhs.recovery.rawValue
        }
        return !lhs.retryable && rhs.retryable
    }
}
