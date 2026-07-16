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
}
