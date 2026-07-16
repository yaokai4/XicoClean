import XCTest
@testable import Domain

final class OperationOutcomeReducerTests: XCTestCase {
    private enum SourceGate {
        static let publicCleaningItemResultInitializer = #"(?s)(?:\bpublic\s+(?:nonisolated\s+)?init\s*\(\s*requestID\s*:\s*UUID\b|\bpublic\s+extension\s+CleaningItemResult\b[^\{]*\{.*?\binit\s*\(\s*requestID\s*:\s*UUID\b)"#
        static let publicFactBackedReportInitializer = #"(?s)(?:\bpublic\s+(?:nonisolated\s+)?init\s*\(\s*operation\s*:\s*OperationOutcome\b|\bpublic\s+extension\s+CleaningReport\b[^\{]*\{.*?\binit\s*\(\s*operation\s*:\s*OperationOutcome\b)"#
        static let cleaningItemResultInitializer = #"(?s)\binit\s*\(\s*requestID\s*:\s*UUID\b"#
        static let factBackedReportInitializer = #"(?s)\binit\s*\(\s*operation\s*:\s*OperationOutcome\b"#
        static let publicLegacyInitializer = #"(?s)\bpublic\s+init\s*\(\s*removedCount\s*:\s*Int\b"#
        static let fixedLegacySentinelFlow = #"(?s)\blet\s+subjectIDs\s*=\s*hasAggregateFacts\s*\?\s*\[\s*\"legacy-aggregate\"\s*\]\s*:\s*\[\s*\].*?\brequestedSubjectIDs\s*:\s*subjectIDs\b"#
        static let forbiddenOutcomeDecodingConformance = #"(?s)(?:\bstruct\s+OperationOutcome\s*:[^\{]*\b(?:Codable|Decodable)\b|\bextension\s+OperationOutcome\s*:[^\{]*\b(?:Codable|Decodable)\b)"#
        static let outcomeEncodableDeclaration = #"(?s)\bstruct\s+OperationOutcome\s*:[^\{]*\bEncodable\b"#
    }

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

    func testIssueOrderingDistinguishesNilSubjectFromEmptySubject() throws {
        func issue(_ code: String, subjectID: String?) -> OperationIssue {
            OperationIssue(code: code,
                           category: .validation,
                           subjectID: subjectID,
                           recovery: .retry,
                           retryable: true)
        }
        let nilA = issue("a.code", subjectID: nil)
        let nilB = issue("b.code", subjectID: nil)
        let emptyA = issue("a.code", subjectID: "")
        let emptyB = issue("b.code", subjectID: "")
        let requested = ["requested-0", "requested-1", "requested-2", "requested-3"]
        let outcome = try reduce(requested, [
            item(requested[0], .failed(emptyB)),
            item(requested[1], .failed(nilA)),
            item(requested[2], .failed(emptyA)),
            item(requested[3], .failed(nilB))
        ])

        XCTAssertEqual(outcome.issues, [nilA, nilB, emptyA, emptyB],
                       "nil subject IDs must sort before present-but-empty subject IDs")
    }

    func testCleaningFactConstructorsStayDomainInternal() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try domainSource(repositoryRoot: repositoryRoot)

        XCTAssertFalse(try matches(SourceGate.publicCleaningItemResultInitializer, in: source),
                       "CleaningItemResult construction must remain inside Domain")
        XCTAssertFalse(try matches(SourceGate.publicFactBackedReportInitializer, in: source),
                       "Fact-backed CleaningReport construction must remain inside Domain")
        XCTAssertTrue(try matches(SourceGate.cleaningItemResultInitializer, in: source))
        XCTAssertTrue(try matches(SourceGate.factBackedReportInitializer, in: source))
        XCTAssertTrue(try matches(SourceGate.publicLegacyInitializer, in: source),
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

        XCTAssertTrue(try matches(SourceGate.fixedLegacySentinelFlow, in: source),
                      "Legacy facts must flow through exactly one fixed sentinel subject")

        let report = CleaningReport(removedCount: 4_097,
                                    reclaimedBytes: 4_097,
                                    failures: [failure],
                                    restorable: [])

        XCTAssertEqual(report.operation.status, .failure)
        XCTAssertEqual(report.operation.counts.requested, 1)
        XCTAssertEqual(report.removedCount, 4_097)
        XCTAssertEqual(report.reclaimedBytes, 4_097)
        XCTAssertEqual(report.failures.count, 1)
        XCTAssertTrue(report.items.isEmpty)
    }

    func testOperationOutcomeCannotRegainADecodableConstructionBoundary() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try domainSource(repositoryRoot: repositoryRoot)

        XCTAssertFalse(try matches(SourceGate.forbiddenOutcomeDecodingConformance, in: source))
        XCTAssertTrue(try matches(SourceGate.outcomeEncodableDeclaration, in: source),
                      "Persistence must encode through the trusted fact and decode through a DTO")
    }

    func testSourceGateRegexesRejectMultilineAndExtensionEvasions() throws {
        XCTAssertTrue(try matches(SourceGate.publicCleaningItemResultInitializer, in: """
        public
        init(
            requestID: UUID, itemID: UUID
        ) {}
        """))
        XCTAssertTrue(try matches(SourceGate.publicCleaningItemResultInitializer, in: """
        public extension CleaningItemResult {
            init(
                requestID: UUID, itemID: UUID
            ) {}
        }
        """))
        XCTAssertTrue(try matches(SourceGate.publicFactBackedReportInitializer, in: """
        public extension CleaningReport {
            init(
                operation: OperationOutcome, items: [CleaningItemResult]
            ) {}
        }
        """))
        XCTAssertTrue(try matches(SourceGate.forbiddenOutcomeDecodingConformance, in: """
        public struct OperationOutcome:
            Encodable,
            Decodable,
            Sendable {
        }
        """))
        XCTAssertTrue(try matches(SourceGate.forbiddenOutcomeDecodingConformance, in: """
        extension OperationOutcome:
            Decodable {
        }
        """))
    }

    private func issueComesBefore(_ lhs: OperationIssue, _ rhs: OperationIssue) -> Bool {
        switch (lhs.subjectID, rhs.subjectID) {
        case (nil, .some): return true
        case (.some, nil): return false
        case let (.some(lhsSubject), .some(rhsSubject)) where lhsSubject != rhsSubject:
            return lhsSubject < rhsSubject
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
    }

    private func matches(_ pattern: String, in source: String) throws -> Bool {
        let expression = try NSRegularExpression(pattern: pattern)
        let range = NSRange(source.startIndex..<source.endIndex, in: source)
        return expression.firstMatch(in: source, range: range) != nil
    }

    private func domainSource(repositoryRoot: URL) throws -> String {
        let domainURL = repositoryRoot.appendingPathComponent("Sources/Domain")
        let sourceURLs = try FileManager.default
            .contentsOfDirectory(at: domainURL,
                                 includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
            .sorted { $0.path < $1.path }
        return try sourceURLs
            .map { try String(contentsOf: $0, encoding: .utf8) }
            .joined(separator: "\n")
    }
}
