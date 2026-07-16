import XCTest
@testable import Domain

final class OperationOutcomeReducerTests: XCTestCase {
    private struct ExternalCompileResult {
        let status: Int32
        let standardOutput: String
        let standardError: String

        var diagnostics: String {
            [standardOutput, standardError]
                .filter { !$0.isEmpty }
                .joined(separator: "\n")
        }
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

    func testExternalClientCanReadFactsAndEncodeOutcome() throws {
        let result = try compileExternalClient("""
        import Foundation
        import Domain

        func consume(report: CleaningReport,
                     item: CleaningItemResult,
                     outcome: OperationOutcome) throws {
            _ = report.operation.status
            _ = report.items.count
            _ = item.requestID
            _ = item.itemID
            _ = item.url
            _ = item.disposition
            _ = item.reclaimedBytes
            _ = item.restorable
            _ = try JSONEncoder().encode(outcome)
        }
        """)

        XCTAssertEqual(result.status, 0, result.diagnostics)
        XCTAssertFalse(result.standardError.localizedCaseInsensitiveContains("no such module"),
                       result.diagnostics)
    }

    func testExternalClientCannotConstructCleaningItemResult() throws {
        let result = try compileExternalClient("""
        import Foundation
        import Domain

        let item = CleaningItemResult(
            requestID: UUID(),
            itemID: UUID(),
            url: URL(fileURLWithPath: "/tmp/external-item"),
            disposition: .succeeded,
            reclaimedBytes: 0,
            restorable: nil)
        """)

        XCTAssertNotEqual(result.status, 0, "External construction must fail")
        XCTAssertTrue(result.standardError.contains("CleaningItemResult"), result.diagnostics)
        XCTAssertTrue(result.standardError.localizedCaseInsensitiveContains("inaccessible"),
                      result.diagnostics)
        assertNoModuleLoadFailure(result)
    }

    func testExternalClientCannotConstructFactBackedCleaningReport() throws {
        let result = try compileExternalClient("""
        import Domain

        func build(operation: OperationOutcome,
                   items: [CleaningItemResult]) -> CleaningReport {
            CleaningReport(operation: operation, items: items)
        }
        """)

        XCTAssertNotEqual(result.status, 0, "External construction must fail")
        XCTAssertTrue(result.standardError.contains("CleaningReport"), result.diagnostics)
        XCTAssertTrue(
            result.standardError.localizedCaseInsensitiveContains("inaccessible")
                || result.standardError.contains("extra arguments at positions #1, #2"),
            result.diagnostics)
        assertNoModuleLoadFailure(result)
    }

    func testExternalClientCannotRequireOperationOutcomeDecodable() throws {
        let result = try compileExternalClient("""
        import Domain

        func requireDecodable<T: Decodable>(_ type: T.Type) {}
        requireDecodable(OperationOutcome.self)
        """)

        XCTAssertNotEqual(result.status, 0, "OperationOutcome must not be externally Decodable")
        XCTAssertTrue(result.standardError.contains("OperationOutcome"), result.diagnostics)
        XCTAssertTrue(result.standardError.contains("Decodable"), result.diagnostics)
        assertNoModuleLoadFailure(result)
    }

    func testLegacyCompatibilityUsesFixedSentinelRatherThanAggregateSizedIDs() {
        let failure = CleaningFailure(url: URL(fileURLWithPath: "/tmp/legacy-failure"),
                                      reason: "legacy")

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

    func testLegacyAggregateSubjectIDsStayBoundedAtExtremeCounts() {
        let extreme = CleaningReport.legacyAggregateSubjectIDs(
            removedCount: Int.max,
            reclaimedBytes: Int64.max,
            failureCount: Int.max,
            restorableCount: Int.max)
        XCTAssertEqual(extreme, ["legacy-aggregate"])
        XCTAssertEqual(extreme.count, 1)

        XCTAssertTrue(CleaningReport.legacyAggregateSubjectIDs(
            removedCount: 0,
            reclaimedBytes: 0,
            failureCount: 0,
            restorableCount: 0).isEmpty)

        XCTAssertEqual(CleaningReport.legacyAggregateSubjectIDs(
            removedCount: 1, reclaimedBytes: 0, failureCount: 0, restorableCount: 0),
                       ["legacy-aggregate"])
        XCTAssertEqual(CleaningReport.legacyAggregateSubjectIDs(
            removedCount: 0, reclaimedBytes: 1, failureCount: 0, restorableCount: 0),
                       ["legacy-aggregate"])
        XCTAssertEqual(CleaningReport.legacyAggregateSubjectIDs(
            removedCount: 0, reclaimedBytes: 0, failureCount: 1, restorableCount: 0),
                       ["legacy-aggregate"])
        XCTAssertEqual(CleaningReport.legacyAggregateSubjectIDs(
            removedCount: 0, reclaimedBytes: 0, failureCount: 0, restorableCount: 1),
                       ["legacy-aggregate"])
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

    private func compileExternalClient(_ source: String) throws -> ExternalCompileResult {
        let fileManager = FileManager.default
        let temporaryURL = fileManager.temporaryDirectory
            .appendingPathComponent("XicoDomainClient-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: temporaryURL,
                                        withIntermediateDirectories: false)
        defer { try? fileManager.removeItem(at: temporaryURL) }

        let sourceURL = temporaryURL.appendingPathComponent("client.swift")
        let moduleCacheURL = temporaryURL.appendingPathComponent("module-cache", isDirectory: true)
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
