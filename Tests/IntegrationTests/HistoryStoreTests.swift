import Foundation
import CryptoKit
import Darwin
import XCTest
@testable import Domain
@testable import Infrastructure

private func systemFlock(_ descriptor: Int32, _ operation: Int32) -> Int32 {
    flock(descriptor, operation)
}

final class HistoryStoreTests: XCTestCase {

    /// 注入临时目录，绝不触碰用户真实的 Application Support/Xico/history.json
    private var tmpDir: URL!
    override func setUpWithError() throws {
        tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent("xico-history-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: tmpDir) }

    func testLegacyRecordDecodesAsLegacyUnknownAndDoesNotCountAsSuccess() throws {
        let data = try archiveData([legacyRecordObject(reclaimedBytes: 42, removedCount: 1)])
        try writeArchive(data)

        let store = HistoryStore(directory: tmpDir)
        let record = try XCTUnwrap(store.recent(1).first)

        XCTAssertEqual(store.archiveState, .writable)
        XCTAssertEqual(record.schemaVersion, 0)
        XCTAssertEqual(record.outcomeStatus, .legacyUnknown)
        XCTAssertNil(record.operationID)
        XCTAssertNil(record.parentOperationID)
        XCTAssertNil(record.operationKind)
        XCTAssertNil(record.mutation)
        XCTAssertNil(record.counts)
        XCTAssertTrue(record.itemFacts.isEmpty)
        XCTAssertEqual(store.totalHistoryRecords, 1)
        XCTAssertEqual(store.totalSuccessfulCleanups, 0)
        XCTAssertEqual(store.totalReclaimedAllTime, 42)
    }

    func testPartiallyMigratedRecordNeverCountsAsSuccess() throws {
        var partial = legacyRecordObject(reclaimedBytes: 42, removedCount: 1)
        let v1 = v1RecordObject()
        partial["operation"] = v1["operation"]
        partial["items"] = v1["items"]
        let data = try archiveData([partial])
        try writeArchive(data)

        let store = HistoryStore(directory: tmpDir)

        assertDegraded(store)
        XCTAssertEqual(store.totalSuccessfulCleanups, 0)
        XCTAssertEqual(store.totalReclaimedAllTime, 0)
        XCTAssertEqual(store.recent(1).first?.outcomeStatus, .legacyUnknown)
        XCTAssertNil(store.record(module: "blocked", reclaimedBytes: 1, removedCount: 1))
        XCTAssertEqual(try Data(contentsOf: archiveURL), data)
    }

    func testUnknownFutureOutcomeStatusDoesNotDropOtherRecordsOrCountAsSuccess() throws {
        let legacy = legacyRecordObject(module: "legacy", reclaimedBytes: 7, removedCount: 1)
        let trusted = v1RecordObject(module: "trusted")
        var future = v1RecordObject(module: "future")
        var operation = try XCTUnwrap(future["operation"] as? [String: Any])
        operation["status"] = "future-success-v2"
        future["operation"] = operation
        let data = try archiveData([legacy, trusted, future])
        try writeArchive(data)

        let store = HistoryStore(directory: tmpDir)

        assertDegraded(store)
        XCTAssertEqual(store.totalHistoryRecords, 3)
        XCTAssertEqual(Set(store.recent(10).map(\.module)), ["legacy", "trusted", "future"])
        XCTAssertEqual(store.recent(10).first(where: { $0.module == "trusted" })?.outcomeStatus,
                       .success)
        XCTAssertEqual(store.recent(10).first(where: { $0.module == "future" })?.outcomeStatus,
                       .legacyUnknown)
        XCTAssertEqual(store.totalSuccessfulCleanups, 1)
        XCTAssertEqual(store.totalReclaimedAllTime, 17,
                       "Future outcome bytes are untrusted; valid legacy factual bytes remain readable")
        XCTAssertNil(store.record(module: "blocked", reclaimedBytes: 1, removedCount: 1))
        XCTAssertEqual(try Data(contentsOf: archiveURL), data)
    }

    func testCorruptElementDoesNotEraseValidRecordsOrPermitArchiveOverwrite() throws {
        let data = try archiveData([
            legacyRecordObject(module: "valid", reclaimedBytes: 9, removedCount: 1),
            "not-a-record"
        ])
        try writeArchive(data)

        let store = HistoryStore(directory: tmpDir)

        assertDegraded(store)
        XCTAssertEqual(store.recent(10).map(\.module), ["valid"])
        XCTAssertEqual(store.totalHistoryRecords, 1)
        XCTAssertEqual(store.totalSuccessfulCleanups, 0)
        XCTAssertEqual(store.totalReclaimedAllTime, 9)
        XCTAssertNil(store.record(module: "must-not-overwrite", reclaimedBytes: 1, removedCount: 1))
        XCTAssertEqual(try Data(contentsOf: archiveURL), data)
    }

    func testMalformedTopLevelArchiveRemainsByteForByteIntactAfterRejectedMutation() throws {
        let data = try XCTUnwrap("{\"records\":[]}".data(using: .utf8))
        try writeArchive(data)

        let store = HistoryStore(directory: tmpDir)

        assertDegraded(store)
        XCTAssertTrue(store.recent(10).isEmpty)
        XCTAssertNil(store.record(module: "must-not-overwrite", reclaimedBytes: 1, removedCount: 1))
        XCTAssertEqual(store.remove(id: UUID()), .rejected(code: "history.archive.readOnly"))
        XCTAssertEqual(try Data(contentsOf: archiveURL), data)
    }

    func testUnsupportedFutureSchemaIsReadOnlyAndPreserved() throws {
        var future = legacyRecordObject(module: "future-schema", reclaimedBytes: 20, removedCount: 1)
        future["schemaVersion"] = 3
        let data = try archiveData([future])
        try writeArchive(data)

        let store = HistoryStore(directory: tmpDir)

        assertDegraded(store)
        XCTAssertEqual(store.totalHistoryRecords, 1)
        XCTAssertEqual(store.recent(1).first?.outcomeStatus, .legacyUnknown)
        XCTAssertEqual(store.totalSuccessfulCleanups, 0)
        XCTAssertEqual(store.totalReclaimedAllTime, 0)
        XCTAssertNil(store.record(module: "must-not-overwrite", reclaimedBytes: 1, removedCount: 1))
        XCTAssertEqual(try Data(contentsOf: archiveURL), data)
    }

    func testLoadingLegacyArchiveDoesNotEagerlyRewriteBytes() throws {
        let data = try archiveData([
            legacyRecordObject(module: "legacy", reclaimedBytes: 12, removedCount: 2)
        ])
        try writeArchive(data)

        let store = HistoryStore(directory: tmpDir)

        XCTAssertEqual(store.archiveState, .writable)
        XCTAssertEqual(store.totalHistoryRecords, 1)
        XCTAssertEqual(store.totalSuccessfulCleanups, 0)
        XCTAssertEqual(try Data(contentsOf: archiveURL), data)
    }

    func testV1PartialRecordMissingRequiredKeysIsCorrupt() throws {
        var partials: [[String: Any]] = []

        for key in [
            "schemaVersion", "id", "date", "module", "reclaimedBytes",
            "removedCount", "operation", "items"
        ] {
            var record = v1RecordObject(module: "missing-record-\(key)")
            record.removeValue(forKey: key)
            partials.append(record)
        }

        for key in [
            "id", "kind", "status", "mutation", "counts", "issues", "startedAt", "finishedAt"
        ] {
            var record = v1RecordObject(module: "missing-operation-\(key)")
            var operation = try XCTUnwrap(record["operation"] as? [String: Any])
            operation.removeValue(forKey: key)
            record["operation"] = operation
            partials.append(record)
        }

        for key in ["requested", "succeeded", "unchanged", "skipped", "failed", "cancelled"] {
            var record = v1RecordObject(module: "missing-count-\(key)")
            var operation = try XCTUnwrap(record["operation"] as? [String: Any])
            var counts = try XCTUnwrap(operation["counts"] as? [String: Any])
            counts.removeValue(forKey: key)
            operation["counts"] = counts
            record["operation"] = operation
            partials.append(record)
        }

        for key in ["requestID", "intent", "disposition", "mutation", "affectedBytes"] {
            var record = v1RecordObject(module: "missing-item-\(key)")
            var items = try XCTUnwrap(record["items"] as? [[String: Any]])
            items[0].removeValue(forKey: key)
            record["items"] = items
            partials.append(record)
        }

        var missingDispositionKind = v1RecordObject(module: "missing-disposition-kind")
        var dispositionItems = try XCTUnwrap(missingDispositionKind["items"] as? [[String: Any]])
        dispositionItems[0]["disposition"] = [String: Any]()
        missingDispositionKind["items"] = dispositionItems
        partials.append(missingDispositionKind)

        let failedRequestID = UUID()
        let failedBase = v1RecordObject(
            module: "failed-base",
            items: [failedItemObject(requestID: failedRequestID)])
        var missingDispositionIssue = failedBase
        var noIssueItems = try XCTUnwrap(missingDispositionIssue["items"] as? [[String: Any]])
        var noIssueDisposition = try XCTUnwrap(noIssueItems[0]["disposition"] as? [String: Any])
        noIssueDisposition.removeValue(forKey: "issue")
        noIssueItems[0]["disposition"] = noIssueDisposition
        missingDispositionIssue["items"] = noIssueItems
        partials.append(missingDispositionIssue)

        for key in ["code", "category", "recovery", "retryable"] {
            var record = failedBase
            var items = try XCTUnwrap(record["items"] as? [[String: Any]])
            var disposition = try XCTUnwrap(items[0]["disposition"] as? [String: Any])
            var issue = try XCTUnwrap(disposition["issue"] as? [String: Any])
            issue.removeValue(forKey: key)
            disposition["issue"] = issue
            items[0]["disposition"] = disposition
            record["items"] = items
            var operation = try XCTUnwrap(record["operation"] as? [String: Any])
            operation["issues"] = [issue]
            record["operation"] = operation
            partials.append(record)
        }

        for key in ["originalURL", "trashedURL"] {
            var record = v1RecordObject(module: "missing-receipt-\(key)")
            var items = try XCTUnwrap(record["items"] as? [[String: Any]])
            var receipt = try XCTUnwrap(items[0]["receipt"] as? [String: Any])
            receipt.removeValue(forKey: key)
            items[0]["receipt"] = receipt
            record["items"] = items
            partials.append(record)
        }

        for (index, partial) in partials.enumerated() {
            let validSibling = legacyRecordObject(
                module: "valid-sibling-\(index)", reclaimedBytes: 3, removedCount: 1)
            let data = try archiveData([validSibling, partial])
            let (store, url) = try loadCase(data, name: "v1-partial-\(index)")

            assertDegraded(store)
            XCTAssertTrue(store.recent(10).contains { $0.module == validSibling["module"] as? String })
            XCTAssertEqual(store.totalSuccessfulCleanups, 0)
            XCTAssertNil(store.record(module: "blocked", reclaimedBytes: 1, removedCount: 1))
            XCTAssertEqual(try Data(contentsOf: url), data)
        }

        let nilSubjectRequestID = UUID()
        let nilSubjectData = try archiveData([v1RecordObject(
            module: "nil-issue-subject",
            items: [failedItemObject(
                requestID: nilSubjectRequestID, omitSubjectID: true)])])
        let (nilSubjectStore, _) = try loadCase(
            nilSubjectData, name: "v1-valid-nil-issue-subject")
        XCTAssertEqual(nilSubjectStore.archiveState, .writable)
        XCTAssertEqual(nilSubjectStore.recent(1).first?.module, "nil-issue-subject")
        XCTAssertEqual(nilSubjectStore.recent(1).first?.outcomeStatus, .failure)
    }

    func testV1MalformedUUIDCountsNegativeFactsAndInconsistentStatusAreCorrupt() throws {
        var corruptRecords: [[String: Any]] = []

        var malformedRecordID = v1RecordObject(module: "bad-record-id")
        malformedRecordID["id"] = "not-a-uuid"
        corruptRecords.append(malformedRecordID)

        corruptRecords.append(changingOperation(v1RecordObject(module: "bad-operation-id")) {
            $0["id"] = "not-a-uuid"
        })
        corruptRecords.append(changingOperation(v1RecordObject(module: "bad-parent-id")) {
            $0["parentID"] = "not-a-uuid"
        })
        corruptRecords.append(changingFirstItem(v1RecordObject(module: "bad-request-id")) {
            $0["requestID"] = "not-a-uuid"
        })

        var negativeTopLevelBytes = v1RecordObject(module: "negative-record-bytes")
        negativeTopLevelBytes["reclaimedBytes"] = -1
        corruptRecords.append(negativeTopLevelBytes)
        var negativeRemovedCount = v1RecordObject(module: "negative-removed-count")
        negativeRemovedCount["removedCount"] = -1
        corruptRecords.append(negativeRemovedCount)

        for key in ["requested", "succeeded", "unchanged", "skipped", "failed", "cancelled"] {
            corruptRecords.append(changingCounts(v1RecordObject(module: "negative-\(key)")) {
                $0[key] = -1
            })
        }
        corruptRecords.append(changingCounts(v1RecordObject(module: "count-sum")) {
            $0["requested"] = 2
        })
        corruptRecords.append(changingCounts(v1RecordObject(module: "count-overflow")) {
            $0["requested"] = 1
            $0["succeeded"] = Int.max
            $0["unchanged"] = 1
            $0["skipped"] = 0
            $0["failed"] = 0
            $0["cancelled"] = 0
        })

        var negativeItemBytes = changingFirstItem(v1RecordObject(module: "negative-item-bytes")) {
            $0["affectedBytes"] = -1
        }
        negativeItemBytes["reclaimedBytes"] = 0
        corruptRecords.append(negativeItemBytes)

        corruptRecords.append(changingOperation(v1RecordObject(module: "status")) {
            $0["status"] = "failure"
        })
        corruptRecords.append(changingOperation(v1RecordObject(module: "mutation")) {
            $0["mutation"] = "none"
        })
        let issueMismatchRequestID = UUID()
        corruptRecords.append(changingOperation(v1RecordObject(
            module: "issues",
            items: [succeededItemObject(requestID: issueMismatchRequestID)])) {
            $0["issues"] = [[
                "code": "history.test.unexpected",
                "category": "io",
                "subjectID": issueMismatchRequestID.uuidString,
                "recovery": "retry",
                "retryable": true
            ]]
        })
        let unboundArchiveRequestID = UUID()
        corruptRecords.append(v1RecordObject(
            module: "unbound-archive-issue",
            items: [failedItemObject(
                requestID: unboundArchiveRequestID,
                subjectID: UUID().uuidString)]))
        corruptRecords.append(changingOperation(v1RecordObject(module: "time")) {
            $0["startedAt"] = 2
            $0["finishedAt"] = 1
        })

        var inconsistentRemovedCount = v1RecordObject(module: "removed-count")
        inconsistentRemovedCount["removedCount"] = 0
        corruptRecords.append(inconsistentRemovedCount)
        var aggregateBytesMismatch = v1RecordObject(module: "aggregate-bytes")
        aggregateBytesMismatch["reclaimedBytes"] = 11
        corruptRecords.append(aggregateBytesMismatch)

        let duplicateRequestID = UUID()
        let duplicateFacts = [
            succeededItemObject(requestID: duplicateRequestID, affectedBytes: 1),
            succeededItemObject(requestID: duplicateRequestID, affectedBytes: 1)
        ]
        corruptRecords.append(v1RecordObject(
            module: "duplicate-request-id",
            items: duplicateFacts,
            reclaimedBytes: 2,
            removedCount: 2))

        corruptRecords.append(changingCounts(v1RecordObject(module: "missing-request-result")) {
            $0["requested"] = 2
            $0["succeeded"] = 2
        })

        let failedRequestID = UUID()
        let failedWithBytes = failedItemObject(requestID: failedRequestID)
        var nonSuccessBytes = v1RecordObject(
            module: "non-success-bytes", items: [failedWithBytes])
        nonSuccessBytes = changingFirstItem(nonSuccessBytes) { $0["affectedBytes"] = 1 }
        corruptRecords.append(nonSuccessBytes)

        corruptRecords.append(changingOperation(v1RecordObject(module: "unknown-op-mutation")) {
            $0["mutation"] = "futureMutation"
        })
        corruptRecords.append(changingFirstItem(v1RecordObject(module: "unknown-item-mutation")) {
            $0["mutation"] = "futureMutation"
        })
        corruptRecords.append(changingFirstItem(v1RecordObject(module: "unknown-intent")) {
            $0["intent"] = "futureIntent"
        })
        corruptRecords.append(changingFirstItem(v1RecordObject(module: "unknown-disposition")) {
            $0["disposition"] = ["kind": "futureDisposition"]
        })
        let categoryRequestID = UUID()
        corruptRecords.append(changingFirstIssue(v1RecordObject(
            module: "unknown-issue-category",
            items: [failedItemObject(requestID: categoryRequestID)])) {
                $0["category"] = "futureCategory"
            })
        let recoveryRequestID = UUID()
        corruptRecords.append(changingFirstIssue(v1RecordObject(
            module: "unknown-issue-recovery",
            items: [failedItemObject(requestID: recoveryRequestID)])) {
                $0["recovery"] = "futureRecovery"
            })

        for (index, corrupt) in corruptRecords.enumerated() {
            let siblingModule = "malformed-valid-sibling-\(index)"
            let data = try archiveData([
                legacyRecordObject(module: siblingModule, reclaimedBytes: 3, removedCount: 1),
                corrupt
            ])
            let (store, url) = try loadCase(data, name: "v1-malformed-\(index)")

            assertDegraded(store)
            XCTAssertTrue(store.recent(10).contains { $0.module == siblingModule })
            XCTAssertEqual(store.totalSuccessfulCleanups, 0)
            XCTAssertEqual(store.totalReclaimedAllTime, 3)
            XCTAssertNil(store.record(module: "blocked", reclaimedBytes: 1, removedCount: 1))
            XCTAssertEqual(try Data(contentsOf: url), data)
        }

        let saturatingItems = [
            succeededItemObject(affectedBytes: Int64.max),
            succeededItemObject(affectedBytes: Int64.max)
        ]
        let saturatingData = try archiveData([
            v1RecordObject(module: "saturating-valid",
                           items: saturatingItems,
                           reclaimedBytes: Int64.max,
                           removedCount: 2)
        ])
        let (saturatingStore, _) = try loadCase(saturatingData, name: "saturating-valid")
        XCTAssertEqual(saturatingStore.archiveState, .writable)
        XCTAssertEqual(saturatingStore.totalSuccessfulCleanups, 1)
        XCTAssertEqual(saturatingStore.totalReclaimedAllTime, Int64.max)
    }

    func testDuplicateOperationIDsOnDiskNeverDoubleSuccessOrBytes() throws {
        let operationID = UUID()
        let first = v1RecordObject(operationID: operationID, module: "same")
        var identical = first
        identical["id"] = UUID().uuidString
        identical["date"] = 3
        let identicalData = try archiveData([first, identical])
        let (identicalStore, identicalURL) = try loadCase(
            identicalData, name: "duplicate-operation-identical")

        assertDegraded(identicalStore)
        XCTAssertEqual(identicalStore.totalHistoryRecords, 1)
        XCTAssertEqual(identicalStore.recent(10).count, 1)
        XCTAssertEqual(identicalStore.recent(1).first?.outcomeStatus, .success)
        XCTAssertEqual(identicalStore.totalSuccessfulCleanups, 1)
        XCTAssertEqual(identicalStore.totalReclaimedAllTime, 10)
        XCTAssertNil(identicalStore.record(
            module: "blocked", reclaimedBytes: 1, removedCount: 1))
        XCTAssertEqual(try Data(contentsOf: identicalURL), identicalData)

        var conflicting = identical
        conflicting["module"] = "conflicting"
        let conflictingData = try archiveData([first, conflicting])
        let (conflictingStore, conflictingURL) = try loadCase(
            conflictingData, name: "duplicate-operation-conflicting")

        assertDegraded(conflictingStore)
        XCTAssertEqual(conflictingStore.totalHistoryRecords, 1)
        XCTAssertEqual(conflictingStore.recent(10).count, 1)
        XCTAssertTrue(conflictingStore.recent(10).contains { $0.outcomeStatus == .legacyUnknown })
        XCTAssertEqual(conflictingStore.totalSuccessfulCleanups, 0)
        XCTAssertEqual(conflictingStore.totalReclaimedAllTime, 0)
        XCTAssertNil(conflictingStore.record(
            module: "blocked", reclaimedBytes: 1, removedCount: 1))
        XCTAssertEqual(try Data(contentsOf: conflictingURL), conflictingData)
    }

    func testFutureDataDuplicateOperationTrustIsConservativeInBothOrders() throws {
        let operationID = UUID()
        let trusted = v1RecordObject(operationID: operationID, module: "future-duplicate")
        var future = trusted
        future["id"] = UUID().uuidString
        future["futureRecordField"] = true

        for (index, records) in [[trusted, future], [future, trusted]].enumerated() {
            let data = try archiveData(records)
            let (store, url) = try loadCase(data, name: "future-duplicate-order-\(index)")

            assertDegraded(store)
            XCTAssertEqual(store.totalHistoryRecords, 1)
            XCTAssertEqual(store.recent(1).first?.module, "future-duplicate")
            XCTAssertEqual(store.recent(1).first?.outcomeStatus, .success)
            XCTAssertEqual(store.totalSuccessfulCleanups, 0,
                           "Either duplicate carrying future data must make trust conservative")
            XCTAssertEqual(store.totalReclaimedAllTime, 0,
                           "Duplicate order must not change future-data aggregate trust")
            XCTAssertNil(store.record(module: "blocked", reclaimedBytes: 1, removedCount: 1))
            XCTAssertEqual(try Data(contentsOf: url), data)
        }
    }

    func testExistingArchiveReadFailureIsDegradedNotMissingOrWritable() throws {
        let persistence = ScriptedHistoryPersistence(
            loadResult: .failed(code: "history.persistence.readDenied"))
        let store = HistoryStore(directory: tmpDir, persistence: persistence)

        XCTAssertEqual(store.archiveState,
                       .degradedReadOnly(code: "history.persistence.readDenied"))
        XCTAssertTrue(store.recent(10).isEmpty)
        XCTAssertNil(store.record(module: "must-not-create", reclaimedBytes: 1, removedCount: 1))
        XCTAssertEqual(store.clear(), .rejected(code: "history.archive.readOnly"))
        XCTAssertEqual(persistence.commitCount, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: archiveURL.path))

        let priorData = try archiveData([v1RecordObject(module: "prior-trusted")])
        let priorRevision = HistoryRevision.sha256(Data(SHA256.hash(data: priorData)))
        let priorPersistence = ScriptedHistoryPersistence(
            loadResult: .loaded(HistoryPersistenceSnapshot(
                data: priorData, revision: priorRevision)))
        let priorStore = HistoryStore(directory: tmpDir, persistence: priorPersistence)
        XCTAssertEqual(priorStore.recent(1).first?.module, "prior-trusted")
        priorPersistence.replaceLoadResult(
            .failed(code: "history.persistence.reloadReadFailed"))

        XCTAssertEqual(priorStore.reload(),
                       .degraded(code: "history.persistence.reloadReadFailed"))
        XCTAssertEqual(priorStore.archiveState,
                       .degradedReadOnly(code: "history.persistence.reloadReadFailed"))
        XCTAssertEqual(priorStore.recent(1).first?.module, "prior-trusted")
        XCTAssertEqual(priorStore.totalSuccessfulCleanups, 1)
        XCTAssertEqual(priorStore.totalReclaimedAllTime, 10)
        XCTAssertNil(priorStore.record(module: "blocked", reclaimedBytes: 1, removedCount: 1))
        XCTAssertEqual(priorPersistence.commitCount, 0)

        let revisionData = try archiveData([v1RecordObject(module: "revision-valid-data")])
        for (index, badRevision) in [
            HistoryRevision.sha256(Data(repeating: 0, count: 31)),
            HistoryRevision.sha256(Data(repeating: 0, count: 32))
        ].enumerated() {
            let badPersistence = ScriptedHistoryPersistence(loadResult: .loaded(
                HistoryPersistenceSnapshot(data: revisionData, revision: badRevision)))
            let badStore = HistoryStore(directory: tmpDir, persistence: badPersistence)
            XCTAssertEqual(badStore.archiveState,
                           .degradedReadOnly(code: "history.persistence.invalidRevision"),
                           "bad revision case \(index)")
            XCTAssertTrue(badStore.recent(10).isEmpty)
            XCTAssertNil(badStore.record(
                module: "blocked", reclaimedBytes: 1, removedCount: 1))
            XCTAssertEqual(badPersistence.commitCount, 0)
        }
    }

    func testV1UnknownKeyIsReadOnlyAndPreserved() throws {
        var rootUnknown = v1RecordObject(module: "root")
        rootUnknown["futureRoot"] = true

        var operationUnknown = v1RecordObject(module: "operation")
        var operation = try XCTUnwrap(operationUnknown["operation"] as? [String: Any])
        operation["futureOperation"] = true
        operationUnknown["operation"] = operation

        var countsUnknown = v1RecordObject(module: "counts")
        var countsOperation = try XCTUnwrap(countsUnknown["operation"] as? [String: Any])
        var counts = try XCTUnwrap(countsOperation["counts"] as? [String: Any])
        counts["futureCounts"] = true
        countsOperation["counts"] = counts
        countsUnknown["operation"] = countsOperation

        var itemUnknown = v1RecordObject(module: "item")
        var itemFacts = try XCTUnwrap(itemUnknown["items"] as? [[String: Any]])
        itemFacts[0]["futureItem"] = true
        itemUnknown["items"] = itemFacts

        var dispositionUnknown = v1RecordObject(module: "disposition")
        var dispositionItems = try XCTUnwrap(dispositionUnknown["items"] as? [[String: Any]])
        var disposition = try XCTUnwrap(dispositionItems[0]["disposition"] as? [String: Any])
        disposition["futureDisposition"] = true
        dispositionItems[0]["disposition"] = disposition
        dispositionUnknown["items"] = dispositionItems

        var receiptUnknown = v1RecordObject(module: "receipt")
        var receiptItems = try XCTUnwrap(receiptUnknown["items"] as? [[String: Any]])
        var receipt = try XCTUnwrap(receiptItems[0]["receipt"] as? [String: Any])
        receipt["futureReceipt"] = true
        receiptItems[0]["receipt"] = receipt
        receiptUnknown["items"] = receiptItems

        let failedRequestID = UUID()
        var issueUnknown = v1RecordObject(
            module: "issue",
            items: [failedItemObject(requestID: failedRequestID)])
        var issueItems = try XCTUnwrap(issueUnknown["items"] as? [[String: Any]])
        var issueDisposition = try XCTUnwrap(issueItems[0]["disposition"] as? [String: Any])
        var issue = try XCTUnwrap(issueDisposition["issue"] as? [String: Any])
        issue["futureIssue"] = true
        issueDisposition["issue"] = issue
        issueItems[0]["disposition"] = issueDisposition
        issueUnknown["items"] = issueItems
        var issueOperation = try XCTUnwrap(issueUnknown["operation"] as? [String: Any])
        issueOperation["issues"] = [issue]
        issueUnknown["operation"] = issueOperation

        let unknownCases: [([String: Any], String, HistoryOutcomeStatus)] = [
            (rootUnknown, "root", .success),
            (operationUnknown, "operation", .success),
            (countsUnknown, "counts", .success),
            (itemUnknown, "item", .success),
            (dispositionUnknown, "disposition", .success),
            (receiptUnknown, "receipt", .success),
            (issueUnknown, "issue", .failure)
        ]
        for (index, entry) in unknownCases.enumerated() {
            let (unknown, expectedModule, expectedStatus) = entry
            let data = try archiveData([unknown])
            let (store, url) = try loadCase(data, name: "v1-unknown-\(index)")

            assertDegraded(store)
            XCTAssertEqual(store.totalHistoryRecords, 1)
            XCTAssertEqual(store.recent(1).first?.module, expectedModule)
            XCTAssertEqual(store.recent(1).first?.outcomeStatus, expectedStatus)
            XCTAssertEqual(store.totalSuccessfulCleanups, 0,
                           "Future V1 keys must never contribute trusted success")
            XCTAssertEqual(store.totalReclaimedAllTime, 0,
                           "Future V1 keys must never contribute trusted bytes")
            XCTAssertNil(store.record(module: "blocked", reclaimedBytes: 1, removedCount: 1))
            XCTAssertEqual(try Data(contentsOf: url), data)
        }
    }

    func testSchema0UnknownKeyIsReadOnlyAndPreserved() throws {
        var rootUnknown = legacyRecordObject(module: "legacy-root", reclaimedBytes: 5)
        rootUnknown["futureRoot"] = true

        var receipt = receiptObject()
        receipt["futureReceipt"] = true
        let receiptUnknown = legacyRecordObject(
            module: "legacy-receipt", reclaimedBytes: 5, restorable: [receipt])

        for (index, unknown) in [rootUnknown, receiptUnknown].enumerated() {
            let data = try archiveData([unknown])
            let (store, url) = try loadCase(data, name: "schema0-unknown-\(index)")

            assertDegraded(store)
            XCTAssertEqual(store.totalHistoryRecords, 1)
            XCTAssertEqual(store.recent(1).first?.module,
                           index == 0 ? "legacy-root" : "legacy-receipt")
            XCTAssertEqual(store.recent(1).first?.outcomeStatus, .legacyUnknown)
            XCTAssertEqual(store.totalSuccessfulCleanups, 0)
            XCTAssertEqual(store.totalReclaimedAllTime, 5)
            XCTAssertNil(store.record(module: "blocked", reclaimedBytes: 1, removedCount: 1))
            XCTAssertEqual(try Data(contentsOf: url), data)
        }
    }

    func testOversizedArchiveOrRecordFactsAreRejectedWithoutOverwrite() throws {
        let emptyArchive = try archiveData([])
        let boundaryArchive = paddedJSON(emptyArchive, byteCount: HistoryArchiveLimits.maximumArchiveBytes)
        let (boundaryStore, _) = try loadCase(boundaryArchive, name: "archive-boundary")
        XCTAssertEqual(boundaryStore.archiveState, .writable)

        let oversizedArchive = paddedJSON(
            emptyArchive, byteCount: HistoryArchiveLimits.maximumArchiveBytes + 1)
        try assertLimitRejected(oversizedArchive, name: "archive-one-over")

        let recordBoundary = (0..<HistoryArchiveLimits.maximumRecords).map { index in
            legacyRecordObject(module: "record-\(index)", reclaimedBytes: 1, removedCount: 1)
        }
        let recordBoundaryData = try archiveData(recordBoundary)
        XCTAssertLessThanOrEqual(recordBoundaryData.count,
                                 HistoryArchiveLimits.maximumArchiveBytes)
        let (recordBoundaryStore, _) = try loadCase(recordBoundaryData, name: "records-boundary")
        XCTAssertEqual(recordBoundaryStore.archiveState, .writable)
        XCTAssertEqual(recordBoundaryStore.totalHistoryRecords, HistoryArchiveLimits.maximumRecords)
        let recordOneOverData = try archiveData(
            recordBoundary + [legacyRecordObject(module: "one-over")])
        XCTAssertLessThanOrEqual(recordOneOverData.count,
                                 HistoryArchiveLimits.maximumArchiveBytes)
        try assertLimitRejected(
            recordOneOverData,
            name: "records-one-over")

        let itemBoundaryFacts = (0..<HistoryArchiveLimits.maximumItemFactsPerRecord).map { _ in
            succeededItemObject(affectedBytes: 0)
        }
        let itemBoundaryData = try archiveData([
            v1RecordObject(items: itemBoundaryFacts,
                           reclaimedBytes: 0,
                           removedCount: itemBoundaryFacts.count)
        ])
        XCTAssertLessThanOrEqual(itemBoundaryData.count,
                                 HistoryArchiveLimits.maximumArchiveBytes)
        let (itemBoundaryStore, _) = try loadCase(itemBoundaryData, name: "items-boundary")
        XCTAssertEqual(itemBoundaryStore.archiveState, .writable)
        let itemOneOverData = try archiveData([v1RecordObject(
            items: itemBoundaryFacts + [succeededItemObject(affectedBytes: 0)],
            reclaimedBytes: 0,
            removedCount: itemBoundaryFacts.count + 1)])
        XCTAssertLessThanOrEqual(itemOneOverData.count,
                                 HistoryArchiveLimits.maximumArchiveBytes)
        try assertLimitRejected(
            itemOneOverData,
            name: "items-one-over")

        XCTAssertEqual(HistoryArchiveLimits.maximumIssuesPerOperation,
                       HistoryArchiveLimits.maximumItemFactsPerRecord)
        let issueBoundaryFacts = (0..<HistoryArchiveLimits.maximumIssuesPerOperation).map { _ in
            failedItemObject()
        }
        let issueBoundaryData = try archiveData([
            v1RecordObject(items: issueBoundaryFacts, reclaimedBytes: 0, removedCount: 0)
        ])
        XCTAssertLessThanOrEqual(issueBoundaryData.count,
                                 HistoryArchiveLimits.maximumArchiveBytes)
        let (issueBoundaryStore, _) = try loadCase(issueBoundaryData, name: "issues-boundary")
        XCTAssertEqual(issueBoundaryStore.archiveState, .writable)
        let issueOneOverData = try archiveData([v1RecordObject(
            items: issueBoundaryFacts + [failedItemObject()],
            reclaimedBytes: 0,
            removedCount: 0)])
        XCTAssertEqual(issueBoundaryFacts.count + 1,
                       HistoryArchiveLimits.maximumItemFactsPerRecord + 1)
        XCTAssertLessThanOrEqual(issueOneOverData.count,
                                 HistoryArchiveLimits.maximumArchiveBytes)
        try assertLimitRejected(
            issueOneOverData,
            name: "issues-one-over")

        let moduleBoundary = utf8SizedString(HistoryArchiveLimits.maximumModuleUTF8Bytes)
        XCTAssertEqual(moduleBoundary.utf8.count, HistoryArchiveLimits.maximumModuleUTF8Bytes)
        let moduleBoundaryData = try archiveData([v1RecordObject(module: moduleBoundary)])
        XCTAssertLessThanOrEqual(moduleBoundaryData.count,
                                 HistoryArchiveLimits.maximumArchiveBytes)
        let (moduleBoundaryStore, _) = try loadCase(
            moduleBoundaryData, name: "module-boundary")
        XCTAssertEqual(moduleBoundaryStore.archiveState, .writable)
        let moduleOneOverData = try archiveData([v1RecordObject(module: moduleBoundary + "x")])
        XCTAssertLessThanOrEqual(moduleOneOverData.count,
                                 HistoryArchiveLimits.maximumArchiveBytes)
        try assertLimitRejected(
            moduleOneOverData,
            name: "module-one-over")

        let kindBoundary = utf8SizedString(HistoryArchiveLimits.maximumKindUTF8Bytes)
        let kindBoundaryData = try archiveData([v1RecordObject(kind: kindBoundary)])
        XCTAssertLessThanOrEqual(kindBoundaryData.count,
                                 HistoryArchiveLimits.maximumArchiveBytes)
        let (kindBoundaryStore, _) = try loadCase(
            kindBoundaryData, name: "kind-boundary")
        assertDegraded(kindBoundaryStore)
        XCTAssertEqual(kindBoundaryStore.totalReclaimedAllTime, 0)
        let kindOneOverData = try archiveData([v1RecordObject(kind: kindBoundary + "x")])
        XCTAssertLessThanOrEqual(kindOneOverData.count,
                                 HistoryArchiveLimits.maximumArchiveBytes)
        try assertLimitRejected(
            kindOneOverData,
            name: "kind-one-over")

        let codeBoundary = utf8SizedString(HistoryArchiveLimits.maximumCodeUTF8Bytes)
        let codeRequestID = UUID()
        let codeBoundaryRecord = v1RecordObject(
            items: [failedItemObject(requestID: codeRequestID, code: codeBoundary)])
        let codeBoundaryData = try archiveData([codeBoundaryRecord])
        XCTAssertLessThanOrEqual(codeBoundaryData.count,
                                 HistoryArchiveLimits.maximumArchiveBytes)
        let (codeBoundaryStore, _) = try loadCase(
            codeBoundaryData, name: "code-boundary")
        XCTAssertEqual(codeBoundaryStore.archiveState, .writable)
        let codeOneOverData = try archiveData([v1RecordObject(items: [
            failedItemObject(requestID: codeRequestID, code: codeBoundary + "x")
        ])])
        XCTAssertLessThanOrEqual(codeOneOverData.count,
                                 HistoryArchiveLimits.maximumArchiveBytes)
        try assertLimitRejected(
            codeOneOverData,
            name: "code-one-over")

        let subjectRequestID = UUID()
        XCTAssertEqual(HistoryArchiveLimits.maximumSubjectUTF8Bytes,
                       subjectRequestID.uuidString.utf8.count)
        let subjectBoundaryRecord = v1RecordObject(
            items: [failedItemObject(requestID: subjectRequestID)])
        let (subjectBoundaryStore, _) = try loadCase(
            archiveData([subjectBoundaryRecord]), name: "subject-boundary")
        XCTAssertEqual(subjectBoundaryStore.archiveState, .writable)
        let oversizedSubject = String(
            repeating: "s", count: HistoryArchiveLimits.maximumSubjectUTF8Bytes + 1)
        let subjectOneOverData = try archiveData([v1RecordObject(items: [
            failedItemObject(requestID: subjectRequestID, subjectID: oversizedSubject)
        ])])
        XCTAssertLessThanOrEqual(subjectOneOverData.count,
                                 HistoryArchiveLimits.maximumArchiveBytes)
        let (subjectOneOverStore, subjectOneOverURL) = try loadCase(
            subjectOneOverData, name: "subject-one-over")
        XCTAssertEqual(subjectOneOverStore.archiveState,
                       .degradedReadOnly(code: "history.archive.limitExceeded"),
                       "Length validation must reject before request-binding validation")
        XCTAssertNil(subjectOneOverStore.record(
            module: "blocked", reclaimedBytes: 1, removedCount: 1))
        XCTAssertEqual(try Data(contentsOf: subjectOneOverURL), subjectOneOverData)
    }

    func testFailedWriteDoesNotMutateMemoryOrReturnCommittedID() throws {
        let persistence = ScriptedHistoryPersistence(
            commitActions: [.failed(code: "history.persistence.testWriteFailed")])
        let store = HistoryStore(directory: tmpDir, persistence: persistence)
        let report = try makeSucceededReport()

        let result = store.record(module: "typed", report: report, date: fixedRecordDate)

        XCTAssertEqual(result, .rejected(code: "history.persistence.testWriteFailed"))
        XCTAssertTrue(store.recent(10).isEmpty)
        XCTAssertEqual(store.totalHistoryRecords, 0)
        XCTAssertEqual(persistence.commitCount, 1)
        XCTAssertFalse(persistence.committedPayloads[0].isEmpty)
        let fresh = HistoryStore(directory: tmpDir, persistence: persistence)
        XCTAssertTrue(fresh.recent(10).isEmpty)
        XCTAssertEqual(fresh.totalHistoryRecords, 0)
    }

    func testScalarCompatibilityUsesInjectedTransactionForEveryOutcome() throws {
        let receipt = RestorableItem(
            originalURL: URL(fileURLWithPath: "/tmp/scalar-transaction-original"),
            trashedURL: URL(fileURLWithPath: "/tmp/scalar-transaction-trash/item"))

        do {
            let persistence = ScriptedHistoryPersistence()
            let store = HistoryStore(directory: tmpDir, persistence: persistence)
            XCTAssertNil(store.record(module: "scalar-noop", reclaimedBytes: 0, removedCount: 0))
            XCTAssertEqual(persistence.commitCount, 0)

            let id = try XCTUnwrap(store.record(
                module: "scalar-committed",
                reclaimedBytes: 10,
                removedCount: 1,
                restorable: [receipt],
                date: fixedRecordDate))
            let current = try XCTUnwrap(store.recent(1).first)
            XCTAssertEqual(current.id, id)
            XCTAssertEqual(current.schemaVersion, 0)
            XCTAssertEqual(current.outcomeStatus, .legacyUnknown)
            XCTAssertNil(current.operationID)
            XCTAssertNil(current.operationKind)
            XCTAssertNil(current.mutation)
            XCTAssertNil(current.counts)
            XCTAssertTrue(current.itemFacts.isEmpty)
            XCTAssertEqual(current.restorable, [receipt])
            XCTAssertEqual(persistence.commitCount, 1)
            XCTAssertEqual(persistence.expectedRevisions, [.missing])
            XCTAssertEqual(
                HistoryStore(directory: tmpDir, persistence: persistence).recent(1).first,
                current)
        }

        do {
            let persistence = ScriptedHistoryPersistence(commitActions: [
                .failed(code: "history.persistence.scalarFailed")
            ])
            let store = HistoryStore(directory: tmpDir, persistence: persistence)
            XCTAssertNil(store.record(
                module: "scalar-failed", reclaimedBytes: 1, removedCount: 1))
            XCTAssertTrue(store.recent(10).isEmpty)
            XCTAssertTrue(HistoryStore(directory: tmpDir, persistence: persistence)
                .recent(10).isEmpty)
            XCTAssertEqual(persistence.commitCount, 1)
            XCTAssertEqual(persistence.expectedRevisions, [.missing])
            XCTAssertNil(persistence.loadedData)
        }

        do {
            let persistence = ScriptedHistoryPersistence(commitActions: [
                .indeterminateUsingCandidate(code: "history.persistence.parentFsyncFailed")
            ])
            let store = HistoryStore(directory: tmpDir, persistence: persistence)
            XCTAssertNil(store.record(
                module: "scalar-indeterminate",
                reclaimedBytes: 1,
                removedCount: 1,
                date: fixedRecordDate))
            XCTAssertEqual(store.archiveState,
                           .degradedReadOnly(code: "history.persistence.durabilityUnknown"))
            let observed = try XCTUnwrap(store.recent(1).first)
            XCTAssertEqual(observed.module, "scalar-indeterminate")
            XCTAssertEqual(observed.schemaVersion, 0)
            XCTAssertEqual(
                HistoryStore(directory: tmpDir, persistence: persistence).recent(1).first,
                observed)
            XCTAssertNil(store.record(
                module: "blocked", reclaimedBytes: 1, removedCount: 1))
            XCTAssertEqual(persistence.commitCount, 1)
        }

        do {
            let persistence = ScriptedHistoryPersistence(commitActions: [
                .conflict(latest: .failed(code: "history.persistence.casReadFailed"))
            ])
            let store = HistoryStore(directory: tmpDir, persistence: persistence)
            XCTAssertNil(store.record(
                module: "scalar-cas-failed", reclaimedBytes: 1, removedCount: 1))
            XCTAssertEqual(store.archiveState,
                           .degradedReadOnly(code: "history.persistence.casReadFailed"))
            XCTAssertTrue(store.recent(10).isEmpty)
            let fresh = HistoryStore(directory: tmpDir, persistence: persistence)
            XCTAssertEqual(fresh.archiveState,
                           .degradedReadOnly(code: "history.persistence.casReadFailed"))
            XCTAssertTrue(fresh.recent(10).isEmpty)
            XCTAssertEqual(persistence.commitCount, 1)
            XCTAssertNil(persistence.loadedData)
        }
    }

    func testParentDirectoryFsyncFailureEntersDegradedReadOnlyAndReloadsVisibleArchive() throws {
        let observedData = try archiveData([
            v1RecordObject(module: "observed-after-rename")
        ])
        let observedRevision = HistoryRevision.sha256(Data(SHA256.hash(data: observedData)))
        let persistence = ScriptedHistoryPersistence(
            commitActions: [
                .indeterminate(
                    latest: .loaded(HistoryPersistenceSnapshot(
                        data: observedData, revision: observedRevision)),
                    code: "history.persistence.parentFsyncFailed")
            ])
        let store = HistoryStore(directory: tmpDir, persistence: persistence)
        let report = try makeSucceededReport()

        let result = store.record(module: "visible-after-rename",
                                  report: report,
                                  date: fixedRecordDate)

        XCTAssertEqual(result, .rejected(code: "history.persistence.durabilityUnknown"))
        XCTAssertEqual(store.archiveState,
                       .degradedReadOnly(code: "history.persistence.durabilityUnknown"))
        XCTAssertEqual(store.recent(10).map(\.module), ["observed-after-rename"],
                       "Indeterminate publication must use the observed snapshot, not its candidate")
        XCTAssertEqual(store.totalSuccessfulCleanups, 1)
        XCTAssertEqual(persistence.commitCount, 1)
        XCTAssertEqual(store.record(module: "must-remain-blocked",
                                    report: report,
                                    date: fixedRecordDate),
                       .rejected(code: "history.archive.readOnly"))
        XCTAssertEqual(persistence.commitCount, 1)

        let fresh = HistoryStore(directory: tmpDir, persistence: persistence)
        XCTAssertEqual(fresh.archiveState, .writable)
        XCTAssertEqual(fresh.recent(10).map(\.module), ["observed-after-rename"])
    }

    func testSuccessfulMutationIsImmediatelyVisibleAfterReload() throws {
        let persistence = ScriptedHistoryPersistence()
        let store = HistoryStore(directory: tmpDir, persistence: persistence)
        let report = try makeSucceededReport()

        let result = store.record(module: "reload-visible", report: report, date: fixedRecordDate)
        let recordID = try insertedRecordID(result)

        let published = try XCTUnwrap(store.recent(1).first)
        XCTAssertEqual(published.id, recordID)
        XCTAssertEqual(published.schemaVersion, 1)
        XCTAssertEqual(published.operationID, report.operation.id)
        XCTAssertEqual(published.outcomeStatus, .success)
        XCTAssertEqual(published.mutation, .changed)
        XCTAssertEqual(published.counts, report.operation.counts)
        XCTAssertEqual(published.itemFacts.count, report.items.count)

        XCTAssertEqual(store.reload(), .writable)
        let current = try XCTUnwrap(store.recent(1).first)
        XCTAssertEqual(current, published)

        let fresh = HistoryStore(directory: tmpDir, persistence: persistence)
        XCTAssertEqual(fresh.recent(1).first, current)
        XCTAssertEqual(persistence.commitCount, 1)
    }

    func testHandBuiltCleaningReportRejectsObservableOperationItemMismatches() throws {
        let requestID = UUID()
        let succeededSpec = ReportItemSpec(
            requestID: requestID,
            itemID: UUID(),
            url: URL(fileURLWithPath: "/tmp/manual-report-succeeded"),
            intent: .permanent,
            disposition: .succeeded,
            mutation: .changed,
            affectedBytes: 5,
            receipt: nil)
        let succeeded = try makeReport(
            operationID: fixedOperationID,
            specs: [succeededSpec],
            cancellationAccepted: false)
        let twoSucceeded = try makeReport(
            operationID: fixedOperationID,
            specs: [succeededSpec, ReportItemSpec(
                requestID: UUID(),
                itemID: UUID(),
                url: URL(fileURLWithPath: "/tmp/manual-report-second"),
                intent: .permanent,
                disposition: .succeeded,
                mutation: .changed,
                affectedBytes: 1,
                receipt: nil)],
            cancellationAccepted: false)
        let failureA = boundIssue(code: "history.test.issue-a", requestID: requestID)
        let failureB = boundIssue(code: "history.test.issue-b", requestID: requestID)
        let failedA = try makeReport(
            operationID: fixedOperationID,
            specs: [ReportItemSpec(
                requestID: requestID,
                itemID: UUID(),
                url: URL(fileURLWithPath: "/tmp/manual-report-failed-a"),
                intent: .trash,
                disposition: .failed(failureA),
                mutation: .none,
                affectedBytes: 0,
                receipt: nil)],
            cancellationAccepted: false)
        let failedB = try makeReport(
            operationID: fixedOperationID,
            specs: [ReportItemSpec(
                requestID: requestID,
                itemID: UUID(),
                url: URL(fileURLWithPath: "/tmp/manual-report-failed-b"),
                intent: .trash,
                disposition: .failed(failureB),
                mutation: .none,
                affectedBytes: 0,
                receipt: nil)],
            cancellationAccepted: false)
        let unchanged = try makeReport(
            operationID: fixedOperationID,
            specs: [ReportItemSpec(
                requestID: requestID,
                itemID: UUID(),
                url: URL(fileURLWithPath: "/tmp/manual-report-unchanged"),
                intent: .trash,
                disposition: .unchanged,
                mutation: .none,
                affectedBytes: 0,
                receipt: nil)],
            cancellationAccepted: false)
        let possiblyChanged = try makeReport(
            operationID: fixedOperationID,
            specs: [ReportItemSpec(
                requestID: requestID,
                itemID: UUID(),
                url: URL(fileURLWithPath: "/tmp/manual-report-possibly-changed"),
                intent: .permanent,
                disposition: .succeeded,
                mutation: .possiblyChanged,
                affectedBytes: 5,
                receipt: nil)],
            cancellationAccepted: false)
        let invariantStatusOperation = try OperationOutcomeReducer.reduce(
            id: fixedOperationID,
            kind: OperationKind("cleaning.execute"),
            requestedSubjectIDs: [requestID.uuidString],
            itemOutcomes: [
                OperationItemOutcome(subjectID: requestID.uuidString,
                                     disposition: .succeeded,
                                     mutation: .changed,
                                     affectedBytes: 5),
                OperationItemOutcome(subjectID: UUID().uuidString,
                                     disposition: .succeeded,
                                     mutation: .none,
                                     affectedBytes: 0)
            ],
            cancellationAccepted: false,
            startedAt: Date(timeIntervalSinceReferenceDate: 100),
            finishedAt: Date(timeIntervalSinceReferenceDate: 101))
        let failedWithBytes = try makeReport(
            operationID: fixedOperationID,
            specs: [ReportItemSpec(
                requestID: requestID,
                itemID: UUID(),
                url: URL(fileURLWithPath: "/tmp/manual-report-failed-bytes"),
                intent: .trash,
                disposition: .failed(failureA),
                mutation: .none,
                affectedBytes: 9,
                receipt: nil)],
            cancellationAccepted: false)
        let mismatches: [(String, CleaningReport)] = [
            ("counts", CleaningReport(operation: twoSucceeded.operation,
                                      items: succeeded.items)),
            ("status", CleaningReport(operation: invariantStatusOperation,
                                      items: succeeded.items)),
            ("mutation", CleaningReport(operation: possiblyChanged.operation,
                                        items: succeeded.items)),
            ("issues", CleaningReport(operation: failedA.operation,
                                      items: failedB.items)),
            ("disposition", CleaningReport(operation: succeeded.operation,
                                           items: unchanged.items)),
            ("non-success-bytes", failedWithBytes)
        ]

        for (label, report) in mismatches {
            let persistence = ScriptedHistoryPersistence()
            let store = HistoryStore(directory: tmpDir, persistence: persistence)
            let result = store.record(
                module: "manual-mismatch-\(label)", report: report, date: fixedRecordDate)
            guard case .rejected = result else {
                XCTFail("Observable \(label) mismatch must reject, got \(result)")
                continue
            }
            XCTAssertEqual(persistence.commitCount, 0)
            XCTAssertTrue(store.recent(10).isEmpty)
            XCTAssertTrue(HistoryStore(directory: tmpDir, persistence: persistence)
                .recent(10).isEmpty)
        }
    }

    func testRegisteredNonDefaultParentKindAndItemFactsRoundTripCurrentAndFresh() throws {
        let operationID = UUID()
        let parentID = UUID()
        let kind = OperationKind.spaceTrash
        let succeededID = UUID()
        let unchangedID = UUID()
        let failedID = UUID()
        let receipt = RestorableItem(
            originalURL: URL(fileURLWithPath: "/tmp/roundtrip-original"),
            trashedURL: URL(fileURLWithPath: "/tmp/roundtrip-trash/item"))
        let issue = boundIssue(code: "history.roundtrip.failure", requestID: failedID)
        let report = try makeReport(
            operationID: operationID,
            parentID: parentID,
            kind: kind,
            specs: [
                ReportItemSpec(requestID: succeededID,
                               itemID: UUID(),
                               url: URL(fileURLWithPath: "/tmp/roundtrip-succeeded-source"),
                               intent: .trash,
                               disposition: .succeeded,
                               mutation: .changed,
                               affectedBytes: 12,
                               receipt: receipt),
                ReportItemSpec(requestID: unchangedID,
                               itemID: UUID(),
                               url: URL(fileURLWithPath: "/tmp/roundtrip-unchanged-source"),
                               intent: .permanent,
                               disposition: .unchanged,
                               mutation: .none,
                               affectedBytes: 0,
                               receipt: nil),
                ReportItemSpec(requestID: failedID,
                               itemID: UUID(),
                               url: URL(fileURLWithPath: "/tmp/roundtrip-failed-source"),
                               intent: .trash,
                               disposition: .failed(issue),
                               mutation: .none,
                               affectedBytes: 0,
                               receipt: nil)
            ],
            cancellationAccepted: false)
        let persistence = ScriptedHistoryPersistence()
        let store = HistoryStore(directory: tmpDir, persistence: persistence)

        _ = try insertedRecordID(store.record(
            module: "roundtrip", report: report, date: fixedRecordDate))

        let current = try XCTUnwrap(store.recent(1).first)
        XCTAssertEqual(current.operationID, operationID)
        XCTAssertEqual(current.parentOperationID, parentID)
        XCTAssertEqual(current.operationKind, kind)
        XCTAssertEqual(current.outcomeStatus, .partial)
        XCTAssertEqual(current.mutation, .changed)
        XCTAssertEqual(current.counts, report.operation.counts)
        XCTAssertEqual(current.reclaimedBytes, 12)
        XCTAssertEqual(current.removedCount, 1)
        XCTAssertEqual(current.itemFacts.map(\.requestID),
                       [succeededID, unchangedID, failedID])
        XCTAssertEqual(current.itemFacts.map(\.intent), [.trash, .permanent, .trash])
        XCTAssertEqual(current.itemFacts.map(\.disposition),
                       [.succeeded, .unchanged, .failed(issue)])
        XCTAssertEqual(current.itemFacts.map(\.mutation), [.changed, .none, .none])
        XCTAssertEqual(current.itemFacts.map(\.affectedBytes), [12, 0, 0])
        XCTAssertEqual(current.itemFacts.map(\.receipt), [receipt, nil, nil])
        let fresh = try XCTUnwrap(
            HistoryStore(directory: tmpDir, persistence: persistence).recent(1).first)
        XCTAssertEqual(fresh, current)
    }

    func testCleaningHistoryRejectsUnknownAndRegisteredIneligibleKindsWithoutCommit() throws {
        let ineligibleKinds = [
            OperationKind("history.test.unknown"),
            OperationKind.threatRemediation
        ]

        for kind in ineligibleKinds {
            let persistence = ScriptedHistoryPersistence()
            let store = HistoryStore(directory: tmpDir, persistence: persistence)
            let report = try makeReport(
                operationID: UUID(),
                kind: kind,
                specs: [ReportItemSpec(
                    requestID: UUID(),
                    itemID: UUID(),
                    url: URL(fileURLWithPath: "/tmp/ineligible-history"),
                    intent: .permanent,
                    disposition: .succeeded,
                    mutation: .changed,
                    affectedBytes: 1,
                    receipt: nil)],
                cancellationAccepted: false)

            XCTAssertEqual(
                store.record(module: "Ineligible", report: report, date: fixedRecordDate),
                .rejected(code: "history.operation.ineligibleKind"))
            XCTAssertEqual(persistence.commitCount, 0)
            XCTAssertTrue(store.recent(10).isEmpty)
        }
    }

    func testAtomicMigrationFailureLeavesLegacyArchiveUnchanged() throws {
        let legacyData = try archiveData([
            legacyRecordObject(module: "legacy", reclaimedBytes: 8, removedCount: 1)
        ])
        let revision = HistoryRevision.sha256(Data(SHA256.hash(data: legacyData)))
        let persistence = ScriptedHistoryPersistence(
            loadResult: .loaded(HistoryPersistenceSnapshot(data: legacyData, revision: revision)),
            commitActions: [.failed(code: "history.persistence.migrationFailed")])
        let store = HistoryStore(directory: tmpDir, persistence: persistence)
        let report = try makeSucceededReport()

        let result = store.record(module: "typed", report: report, date: fixedRecordDate)

        XCTAssertEqual(result, .rejected(code: "history.persistence.migrationFailed"))
        XCTAssertEqual(store.recent(10).map(\.module), ["legacy"])
        XCTAssertEqual(store.totalReclaimedAllTime, 8)
        XCTAssertEqual(persistence.commitCount, 1)
        XCTAssertEqual(persistence.loadedData, legacyData)
        let fresh = HistoryStore(directory: tmpDir, persistence: persistence)
        XCTAssertEqual(fresh.recent(10).map(\.module), ["legacy"])
        XCTAssertEqual(fresh.totalReclaimedAllTime, 8)
    }

    func testRecordingSameOperationIDTwiceIsIdempotent() throws {
        let persistence = ScriptedHistoryPersistence()
        let store = HistoryStore(directory: tmpDir, persistence: persistence)
        let report = try makeSucceededReport(operationID: fixedOperationID)

        let first = store.record(module: "same", report: report, date: fixedRecordDate)
        let firstID = try insertedRecordID(first)
        let bytesAfterFirst = try XCTUnwrap(persistence.committedPayloads.last)
        let second = store.record(
            module: "same",
            report: report,
            date: fixedRecordDate.addingTimeInterval(999))

        XCTAssertEqual(second, .alreadyRecorded(recordID: firstID))
        XCTAssertEqual(persistence.commitCount, 1)
        XCTAssertEqual(persistence.committedPayloads.last, bytesAfterFirst)
        XCTAssertEqual(store.totalHistoryRecords, 1)
        XCTAssertEqual(store.recent(1).first?.id, firstID)
        XCTAssertEqual(HistoryStore(directory: tmpDir, persistence: persistence).totalHistoryRecords, 1)
    }

    func testConflictingDuplicateOperationIDIsRejectedWithoutOverwrite() throws {
        let persistence = ScriptedHistoryPersistence()
        let store = HistoryStore(directory: tmpDir, persistence: persistence)
        let report = try makeSucceededReport(operationID: fixedOperationID)
        _ = try insertedRecordID(
            store.record(module: "original", report: report, date: fixedRecordDate))
        let originalBytes = try XCTUnwrap(persistence.committedPayloads.last)

        let conflict = store.record(module: "different-module",
                                    report: report,
                                    date: fixedRecordDate)

        XCTAssertEqual(conflict, .rejected(code: "history.operation.conflict"))
        XCTAssertEqual(persistence.commitCount, 1)
        XCTAssertEqual(persistence.committedPayloads.last, originalBytes)
        XCTAssertEqual(store.recent(1).first?.module, "original")
        XCTAssertEqual(HistoryStore(directory: tmpDir, persistence: persistence)
            .recent(1).first?.module, "original")
    }

    func testSameOperationIDRejectsEveryImmutableFactChangeWithoutWriting() throws {
        let operationID = fixedOperationID
        let parentID = UUID()
        let requestID = UUID()
        let baseReceipt = RestorableItem(
            originalURL: URL(fileURLWithPath: "/tmp/idempotency-original"),
            trashedURL: URL(fileURLWithPath: "/tmp/idempotency-trash/original"))
        let baseSpec = ReportItemSpec(
            requestID: requestID,
            itemID: UUID(),
            url: URL(fileURLWithPath: "/tmp/idempotency-source"),
            intent: .trash,
            disposition: .succeeded,
            mutation: .changed,
            affectedBytes: 10,
            receipt: baseReceipt)
        let base = try makeReport(
            operationID: operationID,
            parentID: parentID,
            kind: .cleaningExecute,
            specs: [baseSpec],
            cancellationAccepted: false)
        let changedReceipt = RestorableItem(
            originalURL: baseReceipt.originalURL,
            trashedURL: URL(fileURLWithPath: "/tmp/idempotency-trash/changed"))
        let changedReceiptOriginal = RestorableItem(
            originalURL: URL(fileURLWithPath: "/tmp/idempotency-original-changed"),
            trashedURL: baseReceipt.trashedURL)
        let variants: [(String, CleaningReport)] = [
            ("parent", try makeReport(
                operationID: operationID,
                parentID: UUID(),
                kind: .cleaningExecute,
                specs: [baseSpec],
                cancellationAccepted: false)),
            ("kind", try makeReport(
                operationID: operationID,
                parentID: parentID,
                kind: .spaceTrash,
                specs: [baseSpec],
                cancellationAccepted: false)),
            ("status", try makeReport(
                operationID: operationID,
                parentID: parentID,
                kind: .cleaningExecute,
                specs: [baseSpec],
                cancellationAccepted: true)),
            ("timestamps", try makeReport(
                operationID: operationID,
                parentID: parentID,
                kind: .cleaningExecute,
                specs: [baseSpec],
                cancellationAccepted: false,
                startedAt: Date(timeIntervalSinceReferenceDate: 99),
                finishedAt: Date(timeIntervalSinceReferenceDate: 101))),
            ("finishedAt", try makeReport(
                operationID: operationID,
                parentID: parentID,
                kind: .cleaningExecute,
                specs: [baseSpec],
                cancellationAccepted: false,
                startedAt: Date(timeIntervalSinceReferenceDate: 100),
                finishedAt: Date(timeIntervalSinceReferenceDate: 102))),
            ("request", try makeReport(
                operationID: operationID,
                parentID: parentID,
                kind: .cleaningExecute,
                specs: [ReportItemSpec(
                    requestID: UUID(), itemID: baseSpec.itemID, url: baseSpec.url,
                    intent: baseSpec.intent, disposition: baseSpec.disposition,
                    mutation: baseSpec.mutation, affectedBytes: baseSpec.affectedBytes,
                    receipt: baseSpec.receipt)],
                cancellationAccepted: false)),
            ("disposition", try makeReport(
                operationID: operationID,
                parentID: parentID,
                kind: .cleaningExecute,
                specs: [ReportItemSpec(
                    requestID: requestID, itemID: baseSpec.itemID, url: baseSpec.url,
                    intent: baseSpec.intent, disposition: .unchanged,
                    mutation: .none, affectedBytes: 0, receipt: nil)],
                cancellationAccepted: false)),
            ("bytes", try makeReport(
                operationID: operationID,
                parentID: parentID,
                kind: .cleaningExecute,
                specs: [ReportItemSpec(
                    requestID: requestID, itemID: baseSpec.itemID, url: baseSpec.url,
                    intent: baseSpec.intent, disposition: baseSpec.disposition,
                    mutation: baseSpec.mutation, affectedBytes: 11,
                    receipt: baseSpec.receipt)],
                cancellationAccepted: false)),
            ("receipt", try makeReport(
                operationID: operationID,
                parentID: parentID,
                kind: .cleaningExecute,
                specs: [ReportItemSpec(
                    requestID: requestID, itemID: baseSpec.itemID, url: baseSpec.url,
                    intent: baseSpec.intent, disposition: baseSpec.disposition,
                    mutation: baseSpec.mutation, affectedBytes: baseSpec.affectedBytes,
                    receipt: changedReceipt)],
                cancellationAccepted: false)),
            ("receipt-original", try makeReport(
                operationID: operationID,
                parentID: parentID,
                kind: .cleaningExecute,
                specs: [ReportItemSpec(
                    requestID: requestID, itemID: baseSpec.itemID, url: baseSpec.url,
                    intent: baseSpec.intent, disposition: baseSpec.disposition,
                    mutation: baseSpec.mutation, affectedBytes: baseSpec.affectedBytes,
                    receipt: changedReceiptOriginal)],
                cancellationAccepted: false))
        ]

        for (label, variant) in variants {
            let persistence = ScriptedHistoryPersistence()
            let store = HistoryStore(directory: tmpDir, persistence: persistence)
            _ = try insertedRecordID(store.record(
                module: "same-module", report: base, date: fixedRecordDate))
            let original = try XCTUnwrap(store.recent(1).first)

            XCTAssertEqual(store.record(
                module: "same-module",
                report: variant,
                date: fixedRecordDate.addingTimeInterval(999)),
                           .rejected(code: "history.operation.conflict"), label)
            XCTAssertEqual(persistence.commitCount, 1, label)
            XCTAssertEqual(store.recent(1).first, original, label)
            XCTAssertEqual(
                HistoryStore(directory: tmpDir, persistence: persistence).recent(1).first,
                original,
                label)
        }

        let mutationSpec = ReportItemSpec(
            requestID: requestID,
            itemID: UUID(),
            url: URL(fileURLWithPath: "/tmp/idempotency-mutation-source"),
            intent: .permanent,
            disposition: .succeeded,
            mutation: .changed,
            affectedBytes: 10,
            receipt: nil)
        let mutationBase = try makeReport(
            operationID: operationID,
            parentID: parentID,
            kind: .cleaningExecute,
            specs: [mutationSpec],
            cancellationAccepted: false)
        let mutationVariant = try makeReport(
            operationID: operationID,
            parentID: parentID,
            kind: .cleaningExecute,
            specs: [ReportItemSpec(
                requestID: mutationSpec.requestID,
                itemID: mutationSpec.itemID,
                url: mutationSpec.url,
                intent: mutationSpec.intent,
                disposition: mutationSpec.disposition,
                mutation: .possiblyChanged,
                affectedBytes: mutationSpec.affectedBytes,
                receipt: nil)],
            cancellationAccepted: false)
        let mutationPersistence = ScriptedHistoryPersistence()
        let mutationStore = HistoryStore(
            directory: tmpDir, persistence: mutationPersistence)
        _ = try insertedRecordID(mutationStore.record(
            module: "same-module", report: mutationBase, date: fixedRecordDate))
        let mutationOriginal = try XCTUnwrap(mutationStore.recent(1).first)
        XCTAssertEqual(mutationStore.record(
            module: "same-module", report: mutationVariant, date: fixedRecordDate),
                       .rejected(code: "history.operation.conflict"))
        XCTAssertEqual(mutationPersistence.commitCount, 1)
        XCTAssertEqual(mutationStore.recent(1).first, mutationOriginal)
        XCTAssertEqual(HistoryStore(
            directory: tmpDir,
            persistence: mutationPersistence).recent(1).first,
                       mutationOriginal)

        func assertAdditionalImmutableFactConflict(
            _ label: String,
            base: CleaningReport,
            variant: CleaningReport
        ) throws {
            let persistence = ScriptedHistoryPersistence()
            let store = HistoryStore(directory: tmpDir, persistence: persistence)
            _ = try insertedRecordID(store.record(
                module: "same-module", report: base, date: fixedRecordDate))
            let original = try XCTUnwrap(store.recent(1).first)

            XCTAssertEqual(store.record(
                module: "same-module", report: variant, date: fixedRecordDate),
                           .rejected(code: "history.operation.conflict"), label)
            XCTAssertEqual(persistence.commitCount, 1, label)
            XCTAssertEqual(store.recent(1).first, original, label)
            XCTAssertEqual(HistoryStore(
                directory: tmpDir,
                persistence: persistence).recent(1).first,
                           original,
                           label)
        }

        let intentSpec = ReportItemSpec(
            requestID: UUID(),
            itemID: UUID(),
            url: URL(fileURLWithPath: "/tmp/idempotency-intent-source"),
            intent: .trash,
            disposition: .succeeded,
            mutation: .changed,
            affectedBytes: 10,
            receipt: nil)
        let intentBase = try makeReport(
            operationID: operationID,
            parentID: parentID,
            kind: .cleaningExecute,
            specs: [intentSpec],
            cancellationAccepted: false)
        let intentVariant = try makeReport(
            operationID: operationID,
            parentID: parentID,
            kind: .cleaningExecute,
            specs: [ReportItemSpec(
                requestID: intentSpec.requestID,
                itemID: intentSpec.itemID,
                url: intentSpec.url,
                intent: .permanent,
                disposition: intentSpec.disposition,
                mutation: intentSpec.mutation,
                affectedBytes: intentSpec.affectedBytes,
                receipt: nil)],
            cancellationAccepted: false)
        try assertAdditionalImmutableFactConflict(
            "intent", base: intentBase, variant: intentVariant)

        let issueRequestID = UUID()
        let commonSucceededSpec = ReportItemSpec(
            requestID: UUID(),
            itemID: UUID(),
            url: URL(fileURLWithPath: "/tmp/idempotency-issue-success"),
            intent: .permanent,
            disposition: .succeeded,
            mutation: .changed,
            affectedBytes: 10,
            receipt: nil)
        func issueSpec(_ issue: OperationIssue) -> ReportItemSpec {
            ReportItemSpec(
                requestID: issueRequestID,
                itemID: UUID(),
                url: URL(fileURLWithPath: "/tmp/idempotency-issue-failure"),
                intent: .trash,
                disposition: .failed(issue),
                mutation: .none,
                affectedBytes: 0,
                receipt: nil)
        }
        let baseIssue = OperationIssue(
            code: "history.idempotency.issue.base",
            category: .io,
            subjectID: issueRequestID.uuidString,
            recovery: .retry,
            retryable: true)
        let baseIssueSpec = issueSpec(baseIssue)
        let issueBase = try makeReport(
            operationID: operationID,
            parentID: parentID,
            kind: .cleaningExecute,
            specs: [commonSucceededSpec, baseIssueSpec],
            cancellationAccepted: false)
        let issueVariants: [(String, OperationIssue)] = [
            ("issue-code", OperationIssue(
                code: "history.idempotency.issue.changed",
                category: baseIssue.category,
                subjectID: baseIssue.subjectID,
                recovery: baseIssue.recovery,
                retryable: baseIssue.retryable)),
            ("issue-category", OperationIssue(
                code: baseIssue.code,
                category: .permission,
                subjectID: baseIssue.subjectID,
                recovery: baseIssue.recovery,
                retryable: baseIssue.retryable)),
            ("issue-recovery", OperationIssue(
                code: baseIssue.code,
                category: baseIssue.category,
                subjectID: baseIssue.subjectID,
                recovery: .manualAction,
                retryable: baseIssue.retryable)),
            ("issue-retryable", OperationIssue(
                code: baseIssue.code,
                category: baseIssue.category,
                subjectID: baseIssue.subjectID,
                recovery: baseIssue.recovery,
                retryable: false))
        ]
        for (label, changedIssue) in issueVariants {
            let changedSpec = ReportItemSpec(
                requestID: baseIssueSpec.requestID,
                itemID: baseIssueSpec.itemID,
                url: baseIssueSpec.url,
                intent: baseIssueSpec.intent,
                disposition: .failed(changedIssue),
                mutation: baseIssueSpec.mutation,
                affectedBytes: baseIssueSpec.affectedBytes,
                receipt: nil)
            let variant = try makeReport(
                operationID: operationID,
                parentID: parentID,
                kind: .cleaningExecute,
                specs: [commonSucceededSpec, changedSpec],
                cancellationAccepted: false)
            try assertAdditionalImmutableFactConflict(
                label, base: issueBase, variant: variant)
        }

        let failedRequestID = UUID()
        let skippedRequestID = UUID()
        let failedIssue = boundIssue(
            code: "history.idempotency.disposition.failed",
            requestID: failedRequestID)
        let skippedIssue = boundIssue(
            code: "history.idempotency.disposition.skipped",
            requestID: skippedRequestID)
        let failedSpec = ReportItemSpec(
            requestID: failedRequestID,
            itemID: UUID(),
            url: URL(fileURLWithPath: "/tmp/idempotency-disposition-failed"),
            intent: .trash,
            disposition: .failed(failedIssue),
            mutation: .none,
            affectedBytes: 0,
            receipt: nil)
        let skippedSpec = ReportItemSpec(
            requestID: skippedRequestID,
            itemID: UUID(),
            url: URL(fileURLWithPath: "/tmp/idempotency-disposition-skipped"),
            intent: .trash,
            disposition: .skipped(skippedIssue),
            mutation: .none,
            affectedBytes: 0,
            receipt: nil)
        let dispositionBase = try makeReport(
            operationID: operationID,
            parentID: parentID,
            kind: .cleaningExecute,
            specs: [commonSucceededSpec, failedSpec, skippedSpec],
            cancellationAccepted: false)
        let dispositionVariant = try makeReport(
            operationID: operationID,
            parentID: parentID,
            kind: .cleaningExecute,
            specs: [
                commonSucceededSpec,
                ReportItemSpec(
                    requestID: failedSpec.requestID,
                    itemID: failedSpec.itemID,
                    url: failedSpec.url,
                    intent: failedSpec.intent,
                    disposition: .skipped(failedIssue),
                    mutation: failedSpec.mutation,
                    affectedBytes: failedSpec.affectedBytes,
                    receipt: nil),
                ReportItemSpec(
                    requestID: skippedSpec.requestID,
                    itemID: skippedSpec.itemID,
                    url: skippedSpec.url,
                    intent: skippedSpec.intent,
                    disposition: .failed(skippedIssue),
                    mutation: skippedSpec.mutation,
                    affectedBytes: skippedSpec.affectedBytes,
                    receipt: nil)
            ],
            cancellationAccepted: false)
        try assertAdditionalImmutableFactConflict(
            "disposition-only",
            base: dispositionBase,
            variant: dispositionVariant)
    }

    func testConcurrentDuplicateOperationIDCommitsExactlyOnce() async throws {
        let persistence = ScriptedHistoryPersistence()
        let store = HistoryStore(directory: tmpDir, persistence: persistence)
        let report = try makeSucceededReport(operationID: fixedOperationID)
        let gate = AsyncStartGate(parties: 2)
        let date = fixedRecordDate

        async let first: HistoryRecordResult = {
            await gate.arriveAndWait()
            return store.record(module: "same", report: report, date: date)
        }()
        async let second: HistoryRecordResult = {
            await gate.arriveAndWait()
            return store.record(module: "same", report: report, date: date)
        }()
        let results = await [first, second]

        let inserted = results.compactMap { result -> UUID? in
            guard case let .inserted(recordID) = result else { return nil }
            return recordID
        }
        let alreadyRecorded = results.compactMap { result -> UUID? in
            guard case let .alreadyRecorded(recordID) = result else { return nil }
            return recordID
        }
        XCTAssertEqual(inserted.count, 1)
        XCTAssertEqual(alreadyRecorded, inserted)
        XCTAssertEqual(persistence.commitCount, 1)
        XCTAssertEqual(store.totalHistoryRecords, 1)
        XCTAssertEqual(HistoryStore(directory: tmpDir, persistence: persistence).totalHistoryRecords, 1)
    }

    func testConcurrentSingleStoreMutationsPersistEveryCommittedRecord() async throws {
        let persistence = ScriptedHistoryPersistence()
        let store = HistoryStore(directory: tmpDir, persistence: persistence)
        let operationIDs = (0..<12).map { _ in UUID() }
        let reports = try operationIDs.map { try makeSucceededReport(operationID: $0) }
        let gate = AsyncStartGate(parties: reports.count)
        let date = fixedRecordDate

        let results = await withTaskGroup(of: HistoryRecordResult.self) { group in
            for (index, report) in reports.enumerated() {
                group.addTask {
                    await gate.arriveAndWait()
                    return store.record(module: "single-\(index)",
                                        report: report,
                                        date: date)
                }
            }
            var values: [HistoryRecordResult] = []
            for await value in group { values.append(value) }
            return values
        }

        XCTAssertEqual(results.filter { if case .inserted = $0 { true } else { false } }.count,
                       reports.count)
        XCTAssertEqual(persistence.commitCount, reports.count)
        XCTAssertEqual(store.totalHistoryRecords, reports.count)
        let fresh = HistoryStore(directory: tmpDir, persistence: persistence)
        XCTAssertEqual(Set(fresh.recent(100).compactMap(\.operationID)), Set(operationIDs))
    }

    func testTwoStoresForSameURLCannotLoseCommittedRecords() async throws {
        try await assertDeterministicTwoStoreCollision(
            firstDirectory: tmpDir,
            secondDirectory: tmpDir,
            firstModule: "first",
            secondModule: "second")
    }

    func testSymlinkAliasStoresForSameArchiveCannotLoseCommittedRecords() async throws {
        let physical = tmpDir.appendingPathComponent("physical", isDirectory: true)
        let alias = tmpDir.appendingPathComponent("alias", isDirectory: true)
        try FileManager.default.createDirectory(at: physical, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: physical)
        XCTAssertEqual(alias.resolvingSymlinksInPath().standardizedFileURL,
                       physical.resolvingSymlinksInPath().standardizedFileURL)
        try await assertDeterministicTwoStoreCollision(
            firstDirectory: physical,
            secondDirectory: alias,
            firstModule: "physical",
            secondModule: "alias")
        let fresh = HistoryStore(directory: physical)
        XCTAssertEqual(fresh.totalHistoryRecords, 2)
        XCTAssertEqual(Set(fresh.recent(10).map(\.module)), ["physical", "alias"])
        XCTAssertEqual(try Data(contentsOf: physical.appendingPathComponent("history.json")),
                       try Data(contentsOf: alias.appendingPathComponent("history.json")))
    }

    func testDifferentCanonicalArchivesEnterLivePersistenceConcurrently() throws {
        let firstDirectory = try makeCaseDirectory("parallel-canonical-first")
        let secondDirectory = try makeCaseDirectory("parallel-canonical-second")
        XCTAssertNotEqual(
            firstDirectory.resolvingSymlinksInPath().standardizedFileURL,
            secondDirectory.resolvingSymlinksInPath().standardizedFileURL)
        let gate = DifferentArchivePersistenceGate()
        let hooks = HistoryPersistenceHooks(didOpen: { role, _ in
            if role == .staging { gate.enterAndWaitForRelease() }
        })
        let firstStore = HistoryStore(
            directory: firstDirectory,
            persistence: LiveHistoryPersistence(directory: firstDirectory, hooks: hooks))
        let secondStore = HistoryStore(
            directory: secondDirectory,
            persistence: LiveHistoryPersistence(directory: secondDirectory, hooks: hooks))
        let firstReport = try makeSucceededReport(operationID: UUID())
        let secondReport = try makeSucceededReport(operationID: UUID())
        let firstResult = LockedValueBox<HistoryRecordResult?>(nil)
        let secondResult = LockedValueBox<HistoryRecordResult?>(nil)
        let start = DispatchSemaphore(value: 0)
        let finished = DispatchGroup()
        finished.enter()
        finished.enter()
        let date = fixedRecordDate
        var released = false
        defer {
            if !released { gate.releaseBoth() }
            _ = finished.wait(timeout: .now() + 5)
        }

        DispatchQueue.global(qos: .userInitiated).async {
            defer { finished.leave() }
            _ = start.wait(timeout: .now() + 5)
            firstResult.set(firstStore.record(
                module: "parallel-first", report: firstReport, date: date))
        }
        DispatchQueue.global(qos: .userInitiated).async {
            defer { finished.leave() }
            _ = start.wait(timeout: .now() + 5)
            secondResult.set(secondStore.record(
                module: "parallel-second", report: secondReport, date: date))
        }
        start.signal()
        start.signal()
        let firstEntered = gate.entered.wait(timeout: .now() + 5)
        let secondEntered = gate.entered.wait(timeout: .now() + 5)
        gate.releaseBoth()
        released = true

        XCTAssertEqual(firstEntered, .success)
        XCTAssertEqual(secondEntered, .success,
                       "Distinct canonical archives must not share one global process mutex")
        XCTAssertEqual(finished.wait(timeout: .now() + 5), .success)
        _ = try insertedRecordID(try XCTUnwrap(firstResult.value))
        _ = try insertedRecordID(try XCTUnwrap(secondResult.value))
        XCTAssertFalse(gate.didTimeOutWaitingForRelease)
    }

    func testProcessMutexRegistryWeaklyReleasesAndPrunesDeadCanonicalSlots() throws {
        let retainedTokens = LockedValueBox<[AnyObject]>([])
        let retainInitialTokens = LockedValueBox(true)
        let weakTokens = (0..<3).map { _ in WeakObjectProbe() }
        let snapshots = LockedValueBox<[(storedEntries: Int, liveEntries: Int)]>([])
        let hooks = HistoryPersistenceHooks(
            didResolveProcessMutex: { token, snapshot in
                snapshots.withValue {
                    $0.append((snapshot.storedEntries, snapshot.liveEntries))
                }
                guard retainInitialTokens.value else { return }
                var newTokenIndex: Int?
                retainedTokens.withValue { tokens in
                    guard !tokens.contains(where: { $0 === token }) else { return }
                    tokens.append(token)
                    newTokenIndex = tokens.count - 1
                }
                if let newTokenIndex,
                   weakTokens.indices.contains(newTokenIndex) {
                    weakTokens[newTokenIndex].capture(token)
                }
            })
        for index in weakTokens.indices {
            autoreleasepool {
                do {
                    let directory = try makeCaseDirectory(
                        "mutex-lifecycle-live-\(index)")
                    let persistence = LiveHistoryPersistence(
                        directory: directory, hooks: hooks)
                    let store = HistoryStore(
                        directory: directory, persistence: persistence)
                    _ = store.archiveState
                } catch {
                    XCTFail("Failed to resolve canonical token \(index): \(error)")
                }
            }
        }
        XCTAssertGreaterThanOrEqual(retainedTokens.value.count, 3)
        XCTAssertTrue(weakTokens.allSatisfy { !$0.isNil },
                      "At least three distinct canonical tokens must be live together")
        XCTAssertGreaterThanOrEqual(snapshots.value.last?.liveEntries ?? 0, 3)
        let snapshotCountBeforeNextResolution = snapshots.value.count
        retainInitialTokens.set(false)
        retainedTokens.set([])
        XCTAssertTrue(weakTokens.allSatisfy(\.isNil),
                      "Releasing the three owners must create at least three dead slots")

        let pruneDirectory = try makeCaseDirectory("mutex-lifecycle-next-resolution")
        autoreleasepool {
            let persistence = LiveHistoryPersistence(
                directory: pruneDirectory, hooks: hooks)
            let store = HistoryStore(directory: pruneDirectory, persistence: persistence)
            _ = store.archiveState
        }
        XCTAssertEqual(snapshots.value.count, snapshotCountBeforeNextResolution + 1,
                       "A new canonical URL must perform the observed next resolution")
        let finalSnapshot = try XCTUnwrap(snapshots.value.last)
        XCTAssertEqual(finalSnapshot.storedEntries,
                       finalSnapshot.liveEntries,
                       "One live resolution must remove every dead weak slot, not only one")
    }

    func testConflictRetryBudgetIsEightTotalCommitAttempts() throws {
        var conflictActions: [ScriptedHistoryPersistence.CommitAction] = []
        var revisions: [HistoryRevision] = []
        for attempt in 1...8 {
            let data = try archiveData((0..<attempt).map { index in
                legacyRecordObject(module: "external-\(index)", reclaimedBytes: 1, removedCount: 1)
            })
            let revision = HistoryRevision.sha256(Data(SHA256.hash(data: data)))
            revisions.append(revision)
            conflictActions.append(.conflict(latest: .loaded(
                HistoryPersistenceSnapshot(data: data, revision: revision))))
        }
        let persistence = ScriptedHistoryPersistence(commitActions: conflictActions)
        let store = HistoryStore(directory: tmpDir, persistence: persistence)
        let report = try makeSucceededReport(operationID: fixedOperationID)

        let result = store.record(module: "candidate", report: report, date: fixedRecordDate)

        XCTAssertEqual(result, .rejected(code: "history.persistence.conflictExhausted"))
        XCTAssertEqual(persistence.commitCount, 8)
        XCTAssertEqual(persistence.expectedRevisions,
                       [.missing] + Array(revisions.dropLast()))
        for (attemptIndex, payload) in persistence.committedPayloads.enumerated() {
            let objects = try XCTUnwrap(
                JSONSerialization.jsonObject(with: payload) as? [[String: Any]])
            XCTAssertEqual(objects.count, attemptIndex + 1)
            let modules = Set(objects.compactMap { $0["module"] as? String })
            let expectedExternal = Set((0..<attemptIndex).map { "external-\($0)" })
            XCTAssertEqual(modules, expectedExternal.union(["candidate"]),
                           "Each retry must reapply the candidate to the latest verified snapshot")
            let candidate = try XCTUnwrap(objects.first { $0["module"] as? String == "candidate" })
            let operation = try XCTUnwrap(candidate["operation"] as? [String: Any])
            XCTAssertEqual(operation["id"] as? String, fixedOperationID.uuidString)
        }
        XCTAssertTrue(store.recent(100).isEmpty,
                      "Conflict exhaustion must not publish either candidate or uncommitted latest state")
        let fresh = HistoryStore(directory: tmpDir, persistence: persistence)
        XCTAssertFalse(fresh.recent(100).contains { $0.operationID == fixedOperationID })
    }

    func testSucceededZeroByteChangeIsRecordedAndCountsAsSuccessfulCleanup() throws {
        let persistence = ScriptedHistoryPersistence()
        let store = HistoryStore(directory: tmpDir, persistence: persistence)
        let report = try makeSucceededReport(bytes: 0)

        let result = store.record(module: "zero-byte", report: report, date: fixedRecordDate)
        _ = try insertedRecordID(result)

        XCTAssertEqual(store.totalHistoryRecords, 1)
        XCTAssertEqual(store.totalSuccessfulCleanups, 1)
        XCTAssertEqual(store.totalReclaimedAllTime, 0)
        let record = try XCTUnwrap(store.recent(1).first)
        XCTAssertEqual(record.schemaVersion, 1)
        XCTAssertEqual(record.outcomeStatus, .success)
        XCTAssertEqual(record.mutation, .changed)
        XCTAssertEqual(record.counts?.succeeded, 1)
        XCTAssertEqual(HistoryStore(directory: tmpDir, persistence: persistence)
            .totalSuccessfulCleanups, 1)
    }

    func testCancelledWithoutChangesIsNotRecorded() throws {
        let requestID = UUID()
        let report = try makeReport(
            operationID: fixedOperationID,
            specs: [ReportItemSpec(
                requestID: requestID,
                itemID: UUID(),
                url: URL(fileURLWithPath: "/tmp/cancelled-unattempted"),
                intent: .trash,
                disposition: .cancelled(nil),
                mutation: .none,
                affectedBytes: 0,
                receipt: nil)],
            cancellationAccepted: true)
        let persistence = ScriptedHistoryPersistence()
        let store = HistoryStore(directory: tmpDir, persistence: persistence)

        let result = store.record(module: "cancelled", report: report, date: fixedRecordDate)

        XCTAssertEqual(result, .notRecordedNoChanges)
        XCTAssertEqual(store.totalHistoryRecords, 0)
        XCTAssertEqual(store.totalSuccessfulCleanups, 0)
        XCTAssertEqual(persistence.commitCount, 0)
    }

    func testDecodedAllUnchangedSuccessCannotInflateSuccessfulCount() throws {
        let data = try archiveData([
            v1RecordObject(module: "all-unchanged",
                           items: [unchangedItemObject()],
                           status: "success",
                           mutation: "none",
                           reclaimedBytes: 0,
                           removedCount: 0)
        ])
        let (store, _) = try loadCase(data, name: "all-unchanged")

        XCTAssertEqual(store.archiveState, .writable)
        XCTAssertEqual(store.totalHistoryRecords, 1)
        XCTAssertEqual(store.recent(1).first?.outcomeStatus, .success)
        XCTAssertEqual(store.recent(1).first?.mutation, OperationMutationFact.none)
        XCTAssertEqual(store.recent(1).first?.counts?.unchanged, 1)
        XCTAssertEqual(store.totalSuccessfulCleanups, 0)
        XCTAssertEqual(store.totalReclaimedAllTime, 0)
    }

    func testPartialRecordPersistsCountsAndRestorableReceipts() throws {
        let successRequestID = UUID()
        let failedRequestID = UUID()
        let receipt = RestorableItem(
            originalURL: URL(fileURLWithPath: "/tmp/partial-original"),
            trashedURL: URL(fileURLWithPath: "/tmp/partial-trash/item"))
        let failure = boundIssue(code: "history.test.partial", requestID: failedRequestID)
        let report = try makeReport(
            operationID: fixedOperationID,
            specs: [
                ReportItemSpec(requestID: successRequestID,
                               itemID: UUID(),
                               url: receipt.originalURL,
                               intent: .trash,
                               disposition: .succeeded,
                               mutation: .changed,
                               affectedBytes: 12,
                               receipt: receipt),
                ReportItemSpec(requestID: failedRequestID,
                               itemID: UUID(),
                               url: URL(fileURLWithPath: "/tmp/partial-failed"),
                               intent: .trash,
                               disposition: .failed(failure),
                               mutation: .none,
                               affectedBytes: 0,
                               receipt: nil)
            ],
            cancellationAccepted: false)
        let persistence = ScriptedHistoryPersistence()
        let store = HistoryStore(directory: tmpDir, persistence: persistence)

        _ = try insertedRecordID(
            store.record(module: "partial", report: report, date: fixedRecordDate))
        let current = try XCTUnwrap(store.recent(1).first)

        XCTAssertEqual(current.outcomeStatus, .partial)
        XCTAssertEqual(current.mutation, .changed)
        XCTAssertEqual(current.counts,
                       OperationCounts(requested: 2, succeeded: 1, unchanged: 0,
                                       skipped: 0, failed: 1, cancelled: 0))
        XCTAssertEqual(current.itemFacts.count, 2)
        XCTAssertEqual(current.restorable, [receipt])
        XCTAssertEqual(current.reclaimedBytes, 12)
        XCTAssertEqual(current.removedCount, 1)
        XCTAssertEqual(store.totalSuccessfulCleanups, 0)
        let fresh = HistoryStore(directory: tmpDir, persistence: persistence)
        XCTAssertEqual(fresh.recent(1).first, current)
    }

    func testCancelledRecordWithChangesPersistsButDoesNotCountAsSuccessfulCleanup() throws {
        let succeededID = UUID()
        let cancelledID = UUID()
        let report = try makeReport(
            operationID: fixedOperationID,
            specs: [
                ReportItemSpec(requestID: succeededID,
                               itemID: UUID(),
                               url: URL(fileURLWithPath: "/tmp/cancelled-completed"),
                               intent: .permanent,
                               disposition: .succeeded,
                               mutation: .changed,
                               affectedBytes: 6,
                               receipt: nil),
                ReportItemSpec(requestID: cancelledID,
                               itemID: UUID(),
                               url: URL(fileURLWithPath: "/tmp/cancelled-pending"),
                               intent: .trash,
                               disposition: .cancelled(nil),
                               mutation: .none,
                               affectedBytes: 0,
                               receipt: nil)
            ],
            cancellationAccepted: true)
        let persistence = ScriptedHistoryPersistence()
        let store = HistoryStore(directory: tmpDir, persistence: persistence)

        _ = try insertedRecordID(
            store.record(module: "cancelled-changed", report: report, date: fixedRecordDate))

        XCTAssertEqual(store.totalHistoryRecords, 1)
        XCTAssertEqual(store.totalSuccessfulCleanups, 0)
        XCTAssertEqual(store.totalReclaimedAllTime, 6)
        XCTAssertEqual(store.recent(1).first?.outcomeStatus, .cancelled)
        XCTAssertEqual(store.recent(1).first?.mutation, .changed)
        XCTAssertEqual(store.recent(1).first?.counts?.cancelled, 1)
        XCTAssertEqual(HistoryStore(directory: tmpDir, persistence: persistence)
            .recent(1).first?.outcomeStatus, .cancelled)
    }

    func testShredderPayloadHistoryPersistsPermanentFactsWithoutURLsOrReceipts() throws {
        let succeededID = UUID()
        let failedID = UUID()
        let failure = OperationIssue(
            code: "shred.test.failed",
            category: .io,
            subjectID: failedID.uuidString,
            recovery: .retry,
            retryable: true)
        let items = [
            ShredderItemResult(
                requestID: succeededID,
                url: URL(fileURLWithPath: "/Users/private/Documents/secret.txt"),
                disposition: .succeeded,
                mutation: .changed,
                freedBytes: 17),
            ShredderItemResult(
                requestID: failedID,
                url: URL(fileURLWithPath: "/Users/private/Documents/failed.txt"),
                disposition: .failed(failure),
                mutation: .possiblyChanged,
                freedBytes: 0)
        ]
        let payload = ShredderPayload(items: items)
        let operation = try OperationOutcomeReducer.reduce(
            id: fixedOperationID,
            kind: .shred,
            requestedSubjectIDs: items.map { $0.requestID.uuidString },
            itemOutcomes: items.map {
                OperationItemOutcome(
                    subjectID: $0.requestID.uuidString,
                    disposition: $0.disposition,
                    mutation: $0.mutation,
                    affectedBytes: $0.freedBytes)
            },
            cancellationAccepted: false,
            startedAt: Date(timeIntervalSince1970: 100),
            finishedAt: Date(timeIntervalSince1970: 101))
        let result = OperationResult(outcome: operation, payload: payload)
        let persistence = ScriptedHistoryPersistence()
        let store = HistoryStore(directory: tmpDir, persistence: persistence)

        let first = store.record(module: "shred", result: result, date: fixedRecordDate)
        let insertedID = try insertedRecordID(first)
        let second = store.record(module: "shred", result: result, date: fixedRecordDate)

        XCTAssertEqual(second, .alreadyRecorded(recordID: insertedID))
        XCTAssertEqual(payload.freedBytes, 17)
        let record = try XCTUnwrap(store.recent(1).first)
        XCTAssertEqual(record.operationKind, .shred)
        XCTAssertEqual(record.outcomeStatus, .partial)
        XCTAssertEqual(record.mutation, .possiblyChanged)
        XCTAssertEqual(record.reclaimedBytes, 17)
        XCTAssertEqual(record.removedCount, 1)
        XCTAssertEqual(record.itemFacts.map(\.intent), [.permanent, .permanent])
        XCTAssertTrue(record.restorable.isEmpty)
        XCTAssertTrue(record.itemFacts.allSatisfy { $0.receipt == nil })
        XCTAssertEqual(persistence.commitCount, 1)
        let archive = String(
            decoding: try XCTUnwrap(persistence.committedPayloads.last),
            as: UTF8.self)
        XCTAssertFalse(archive.contains("/Users/private"))
        XCTAssertFalse(archive.contains("secret.txt"))
        XCTAssertFalse(archive.contains("failed.txt"))
    }

    func testShredderPayloadWithoutMutationIsNotRecorded() throws {
        let item = ShredderItemResult(
            requestID: UUID(),
            url: URL(fileURLWithPath: "/Users/private/Documents/already-gone.txt"),
            disposition: .unchanged,
            mutation: .none,
            freedBytes: 0)
        let payload = ShredderPayload(items: [item])
        let operation = try OperationOutcomeReducer.reduce(
            kind: .shred,
            requestedSubjectIDs: [item.requestID.uuidString],
            itemOutcomes: [OperationItemOutcome(
                subjectID: item.requestID.uuidString,
                disposition: item.disposition,
                mutation: item.mutation,
                affectedBytes: item.freedBytes)],
            cancellationAccepted: false,
            startedAt: Date(timeIntervalSince1970: 100),
            finishedAt: Date(timeIntervalSince1970: 101))
        let persistence = ScriptedHistoryPersistence()
        let store = HistoryStore(directory: tmpDir, persistence: persistence)

        let result = store.record(
            module: "shred-none",
            result: OperationResult(outcome: operation, payload: payload),
            date: fixedRecordDate)

        XCTAssertEqual(result, .notRecordedNoChanges)
        XCTAssertEqual(store.totalHistoryRecords, 0)
        XCTAssertEqual(persistence.commitCount, 0)
    }

    func testShredderPayloadRejectsNonShredKindAndMismatchedOutcomeFacts() throws {
        let requestID = UUID()
        let item = ShredderItemResult(
            requestID: requestID,
            url: URL(fileURLWithPath: "/Users/private/Documents/rejected.txt"),
            disposition: .succeeded,
            mutation: .changed,
            freedBytes: 17)
        let payload = ShredderPayload(items: [item])

        for (kind, disposition, mutation, outcomeBytes, label) in [
            (OperationKind.cleaningExecute, OperationDisposition.succeeded,
             OperationMutationFact.changed, Int64(17), "kind"),
            (OperationKind.shred, OperationDisposition.unchanged,
             OperationMutationFact.none, Int64(0), "facts")
        ] {
            let operation = try OperationOutcomeReducer.reduce(
                kind: kind,
                requestedSubjectIDs: [requestID.uuidString],
                itemOutcomes: [OperationItemOutcome(
                    subjectID: requestID.uuidString,
                    disposition: disposition,
                    mutation: mutation,
                    affectedBytes: outcomeBytes)],
                cancellationAccepted: false,
                startedAt: Date(timeIntervalSince1970: 100),
                finishedAt: Date(timeIntervalSince1970: 101))
            let persistence = ScriptedHistoryPersistence()
            let store = HistoryStore(directory: tmpDir, persistence: persistence)

            XCTAssertEqual(
                store.record(
                    module: "shred-rejected-\(label)",
                    result: OperationResult(outcome: operation, payload: payload),
                    date: fixedRecordDate),
                .rejected(code: "history.operation.invalidFacts"),
                label)
            XCTAssertEqual(persistence.commitCount, 0, label)
        }
    }

    func testShredderPayloadSameOperationIDDifferentFactsConflicts() throws {
        let requestID = UUID()
        func result(bytes: Int64) throws -> OperationResult<ShredderPayload> {
            let item = ShredderItemResult(
                requestID: requestID,
                url: URL(fileURLWithPath: "/Users/private/Documents/conflict.txt"),
                disposition: .succeeded,
                mutation: .changed,
                freedBytes: bytes)
            let payload = ShredderPayload(items: [item])
            let operation = try OperationOutcomeReducer.reduce(
                id: fixedOperationID,
                kind: .shred,
                requestedSubjectIDs: [requestID.uuidString],
                itemOutcomes: [OperationItemOutcome(
                    subjectID: requestID.uuidString,
                    disposition: item.disposition,
                    mutation: item.mutation,
                    affectedBytes: item.freedBytes)],
                cancellationAccepted: false,
                startedAt: Date(timeIntervalSince1970: 100),
                finishedAt: Date(timeIntervalSince1970: 101))
            return OperationResult(outcome: operation, payload: payload)
        }
        let persistence = ScriptedHistoryPersistence()
        let store = HistoryStore(directory: tmpDir, persistence: persistence)

        _ = try insertedRecordID(store.record(
            module: "shred-conflict", result: result(bytes: 17), date: fixedRecordDate))
        let conflict = store.record(
            module: "shred-conflict", result: try result(bytes: 18), date: fixedRecordDate)

        XCTAssertEqual(conflict, .rejected(code: "history.operation.conflict"))
        XCTAssertEqual(persistence.commitCount, 1)
        XCTAssertEqual(store.recent(1).first?.reclaimedBytes, 17)
    }

    func testCancelledShredderPayloadPersistsCompletedFacts() throws {
        let completedID = UUID()
        let cancelledID = UUID()
        let items = [
            ShredderItemResult(
                requestID: completedID,
                url: URL(fileURLWithPath: "/Users/private/Documents/completed.txt"),
                disposition: .succeeded,
                mutation: .changed,
                freedBytes: 9),
            ShredderItemResult(
                requestID: cancelledID,
                url: URL(fileURLWithPath: "/Users/private/Documents/cancelled.txt"),
                disposition: .cancelled(nil),
                mutation: .none,
                freedBytes: 0)
        ]
        let payload = ShredderPayload(items: items)
        let operation = try OperationOutcomeReducer.reduce(
            kind: .shred,
            requestedSubjectIDs: items.map { $0.requestID.uuidString },
            itemOutcomes: items.map {
                OperationItemOutcome(
                    subjectID: $0.requestID.uuidString,
                    disposition: $0.disposition,
                    mutation: $0.mutation,
                    affectedBytes: $0.freedBytes)
            },
            cancellationAccepted: true,
            startedAt: Date(timeIntervalSince1970: 100),
            finishedAt: Date(timeIntervalSince1970: 101))
        let store = HistoryStore(directory: tmpDir)

        _ = try insertedRecordID(store.record(
            module: "shred-cancelled",
            result: OperationResult(outcome: operation, payload: payload),
            date: fixedRecordDate))

        let record = try XCTUnwrap(store.recent(1).first)
        XCTAssertEqual(record.outcomeStatus, .cancelled)
        XCTAssertEqual(record.mutation, .changed)
        XCTAssertEqual(record.counts?.succeeded, 1)
        XCTAssertEqual(record.counts?.cancelled, 1)
        XCTAssertEqual(record.reclaimedBytes, 9)
        XCTAssertEqual(record.removedCount, 1)
        XCTAssertTrue(record.restorable.isEmpty)
    }

    func testMaximumIssueTerminalWithReceiptRecordsAndReloads() throws {
        XCTAssertEqual(
            HistoryArchiveLimits.maximumIssuesPerOperation,
            CleaningOperationLimits.maximumFactCount)
        let receipt = RestorableItem(
            originalURL: URL(fileURLWithPath: "/tmp/history-max-issues-original"),
            trashedURL: URL(fileURLWithPath: "/tmp/history-max-issues-trash"))
        var specs = [ReportItemSpec(
            requestID: UUID(),
            itemID: UUID(),
            url: URL(fileURLWithPath: "/tmp/history-max-issues-success"),
            intent: .trash,
            disposition: .succeeded,
            mutation: .changed,
            affectedBytes: 7,
            receipt: receipt)]
        for index in 1..<CleaningOperationLimits.maximumFactCount {
            let requestID = UUID()
            specs.append(ReportItemSpec(
                requestID: requestID,
                itemID: UUID(),
                url: URL(fileURLWithPath: "/tmp/history-max-issues-failed-\(index)"),
                intent: .trash,
                disposition: .failed(boundIssue(
                    code: "history.boundary.failed",
                    requestID: requestID)),
                mutation: .none,
                affectedBytes: 0,
                receipt: nil))
        }
        let report = try makeReport(
            specs: specs,
            cancellationAccepted: false)
        XCTAssertEqual(report.facts.count, CleaningOperationLimits.maximumFactCount)
        XCTAssertEqual(
            report.operation.issues.count,
            CleaningOperationLimits.maximumFactCount - 1)
        let store = HistoryStore(directory: tmpDir)

        let recordID = try insertedRecordID(store.record(
            module: "maximum issue terminal",
            report: report,
            date: fixedRecordDate))

        let fresh = HistoryStore(directory: tmpDir)
        XCTAssertEqual(fresh.archiveState, .writable)
        let record = try XCTUnwrap(fresh.recent(1).first)
        XCTAssertEqual(record.id, recordID)
        XCTAssertEqual(record.itemFacts.count, CleaningOperationLimits.maximumFactCount)
        XCTAssertEqual(record.counts?.succeeded, 1)
        XCTAssertEqual(
            record.counts?.failed,
            CleaningOperationLimits.maximumFactCount - 1)
        XCTAssertEqual(record.restorable, [receipt])
        XCTAssertEqual(record.mutation, .changed)
    }

    func testSkippedAndCancelledIssuesRoundTripFromTypedAndRawRecords() throws {
        for (label, specialDisposition, cancellationAccepted, expectedStatus) in [
            ("skipped",
             OperationDisposition.skipped(OperationIssue(
                code: "history.valid.skipped",
                category: .safetyPolicy,
                subjectID: nil,
                recovery: .manualAction,
                retryable: false)),
             false,
             HistoryOutcomeStatus.partial),
            ("cancelled",
             OperationDisposition.cancelled(OperationIssue(
                code: "history.valid.cancelled",
                category: .io,
                subjectID: nil,
                recovery: .retry,
                retryable: true)),
             true,
             HistoryOutcomeStatus.cancelled)
        ] {
            let specialRequestID = UUID()
            let boundDisposition: OperationDisposition
            switch specialDisposition {
            case let .skipped(issue):
                boundDisposition = .skipped(OperationIssue(
                    code: issue.code,
                    category: issue.category,
                    subjectID: specialRequestID.uuidString,
                    recovery: issue.recovery,
                    retryable: issue.retryable))
            case let .cancelled(issue?):
                boundDisposition = .cancelled(OperationIssue(
                    code: issue.code,
                    category: issue.category,
                    subjectID: specialRequestID.uuidString,
                    recovery: issue.recovery,
                    retryable: issue.retryable))
            default:
                throw TestFailure.unexpectedResult
            }
            let report = try makeReport(
                specs: [
                    ReportItemSpec(
                        requestID: UUID(),
                        itemID: UUID(),
                        url: URL(fileURLWithPath: "/tmp/\(label)-roundtrip-success"),
                        intent: .permanent,
                        disposition: .succeeded,
                        mutation: .changed,
                        affectedBytes: 2,
                        receipt: nil),
                    ReportItemSpec(
                        requestID: specialRequestID,
                        itemID: UUID(),
                        url: URL(fileURLWithPath: "/tmp/\(label)-roundtrip-special"),
                        intent: .trash,
                        disposition: boundDisposition,
                        mutation: .none,
                        affectedBytes: 0,
                        receipt: nil)
                ],
                cancellationAccepted: cancellationAccepted)
            let persistence = ScriptedHistoryPersistence()
            let store = HistoryStore(directory: tmpDir, persistence: persistence)

            _ = try insertedRecordID(store.record(
                module: "typed-\(label)-issue", report: report, date: fixedRecordDate))
            let current = try XCTUnwrap(store.recent(1).first)

            XCTAssertEqual(current.outcomeStatus, expectedStatus, label)
            XCTAssertEqual(current.itemFacts.first {
                $0.requestID == specialRequestID
            }?.disposition, boundDisposition, label)
            XCTAssertEqual(HistoryStore(
                directory: tmpDir,
                persistence: persistence).recent(1).first,
                           current,
                           label)
        }

        let rawSkippedID = UUID()
        let rawCancelledID = UUID()
        let rawSkippedIssue = issueObject(
            code: "history.raw.skipped", subjectID: rawSkippedID.uuidString)
        let rawCancelledIssue = issueObject(
            code: "history.raw.cancelled", subjectID: rawCancelledID.uuidString)
        let rawSkippedItem: [String: Any] = [
            "requestID": rawSkippedID.uuidString,
            "intent": "trash",
            "disposition": ["kind": "skipped", "issue": rawSkippedIssue],
            "mutation": "none",
            "affectedBytes": 0
        ]
        let rawCancelledItem: [String: Any] = [
            "requestID": rawCancelledID.uuidString,
            "intent": "trash",
            "disposition": ["kind": "cancelled", "issue": rawCancelledIssue],
            "mutation": "none",
            "affectedBytes": 0
        ]
        let rawData = try archiveData([
            v1RecordObject(
                module: "raw-skipped-issue",
                items: [succeededItemObject(
                    intent: "permanent", affectedBytes: 2), rawSkippedItem]),
            v1RecordObject(
                module: "raw-cancelled-issue",
                items: [succeededItemObject(
                    intent: "permanent", affectedBytes: 2), rawCancelledItem],
                status: "cancelled")
        ])
        let (rawStore, rawURL) = try loadCase(rawData, name: "valid-raw-special-issues")

        XCTAssertEqual(rawStore.archiveState, .writable)
        XCTAssertEqual(rawStore.totalHistoryRecords, 2)
        XCTAssertEqual(rawStore.recent(10).first {
            $0.module == "raw-skipped-issue"
        }?.itemFacts.first { $0.requestID == rawSkippedID }?.disposition,
                       .skipped(OperationIssue(
                        code: "history.raw.skipped",
                        category: .io,
                        subjectID: rawSkippedID.uuidString,
                        recovery: .retry,
                        retryable: true)))
        XCTAssertEqual(rawStore.recent(10).first {
            $0.module == "raw-cancelled-issue"
        }?.itemFacts.first { $0.requestID == rawCancelledID }?.disposition,
                       .cancelled(OperationIssue(
                        code: "history.raw.cancelled",
                        category: .io,
                        subjectID: rawCancelledID.uuidString,
                        recovery: .retry,
                        retryable: true)))
        XCTAssertEqual(try Data(contentsOf: rawURL), rawData,
                       "Valid raw special-issue records must not be eagerly rewritten")
    }

    func testTotalSuccessfulCleanupsExcludesLegacyPartialFailureAndCancelled() throws {
        let partialFacts = [
            succeededItemObject(affectedBytes: 4),
            failedItemObject()
        ]
        let failureFacts = [failedItemObject()]
        let cancelledFacts = [
            succeededItemObject(intent: "permanent", affectedBytes: 3),
            cancelledItemObject()
        ]
        let records: [Any] = [
            legacyRecordObject(module: "legacy", reclaimedBytes: 5, removedCount: 1),
            v1RecordObject(module: "success", items: [succeededItemObject(affectedBytes: 10)]),
            v1RecordObject(module: "partial", items: partialFacts),
            v1RecordObject(module: "failure", items: failureFacts),
            v1RecordObject(module: "cancelled", items: cancelledFacts, status: "cancelled"),
            v1RecordObject(module: "unchanged",
                           items: [unchangedItemObject()],
                           status: "success",
                           mutation: "none",
                           reclaimedBytes: 0,
                           removedCount: 0)
        ]
        let data = try archiveData(records)
        let (store, _) = try loadCase(data, name: "aggregate-statuses")

        XCTAssertEqual(store.archiveState, .writable)
        XCTAssertEqual(store.totalHistoryRecords, 6)
        XCTAssertEqual(Set(store.recent(10).map(\.outcomeStatus)),
                       [.legacyUnknown, .success, .partial, .failure, .cancelled])
        XCTAssertEqual(store.totalSuccessfulCleanups, 1)
        XCTAssertEqual(store.totalReclaimedAllTime, 22)
    }

    func testAggregateBytesSaturateAcrossRecordsAndPossiblyChangedIsNotSuccess() throws {
        var possiblyChanged = succeededItemObject(affectedBytes: Int64.max)
        possiblyChanged["mutation"] = "possiblyChanged"
        let data = try archiveData([
            legacyRecordObject(module: "legacy-max-a", reclaimedBytes: Int64.max),
            legacyRecordObject(module: "legacy-max-b", reclaimedBytes: Int64.max),
            v1RecordObject(module: "possibly-changed-max",
                           items: [possiblyChanged],
                           reclaimedBytes: Int64.max,
                           removedCount: 1)
        ])
        let (store, _) = try loadCase(data, name: "cross-record-saturation")

        XCTAssertEqual(store.archiveState, .writable)
        XCTAssertEqual(store.totalHistoryRecords, 3)
        XCTAssertEqual(store.totalSuccessfulCleanups, 0)
        XCTAssertEqual(store.totalReclaimedAllTime, Int64.max)
        XCTAssertEqual(store.recent(10).first(where: {
            $0.module == "possibly-changed-max"
        })?.mutation, .possiblyChanged)
    }

    func testRetentionEvictsOldestOfFiveHundredInOneTransaction() throws {
        XCTAssertEqual(HistoryArchiveLimits.maximumRecords, 500)
        let seedRecords = (0..<HistoryArchiveLimits.maximumRecords).map { index in
            legacyRecordObject(
                date: TimeInterval(index),
                module: "retention-\(index)",
                reclaimedBytes: 1,
                removedCount: 1)
        }
        let seedData = try archiveData(seedRecords)
        XCTAssertLessThanOrEqual(seedData.count, HistoryArchiveLimits.maximumArchiveBytes)
        let revision = HistoryRevision.sha256(Data(SHA256.hash(data: seedData)))
        let persistence = ScriptedHistoryPersistence(loadResult: .loaded(
            HistoryPersistenceSnapshot(data: seedData, revision: revision)))
        let store = HistoryStore(directory: tmpDir, persistence: persistence)
        XCTAssertEqual(store.totalHistoryRecords, 500)

        let insertedID = try XCTUnwrap(store.record(
            module: "retention-new",
            reclaimedBytes: 1,
            removedCount: 1,
            date: Date(timeIntervalSinceReferenceDate: 501)))

        XCTAssertEqual(persistence.commitCount, 1)
        XCTAssertEqual(store.totalHistoryRecords, 500)
        XCTAssertEqual(store.recent(1).first?.id, insertedID)
        XCTAssertEqual(store.recent(1).first?.module, "retention-new")
        XCTAssertFalse(store.recent(1_000).contains { $0.module == "retention-0" })
        XCTAssertTrue(store.recent(1_000).contains { $0.module == "retention-499" })
        let fresh = HistoryStore(directory: tmpDir, persistence: persistence)
        XCTAssertEqual(fresh.totalHistoryRecords, 500)
        XCTAssertEqual(fresh.recent(1).first?.id, insertedID)
        XCTAssertFalse(fresh.recent(1_000).contains { $0.module == "retention-0" })
    }

    func testByteRetentionEvictsOldestLargeTypedRecordsAndReloadsNewestReceipt() throws {
        let store = HistoryStore(directory: tmpDir)
        var insertedIDs: [UUID] = []
        var newestReceipt: RestorableItem?

        for batch in 0..<12 {
            let receipt = RestorableItem(
                originalURL: URL(fileURLWithPath: "/tmp/byte-retention-\(batch)-original"),
                trashedURL: URL(fileURLWithPath: "/tmp/byte-retention-\(batch)-trash"))
            newestReceipt = receipt
            var specs = [ReportItemSpec(
                requestID: UUID(),
                itemID: UUID(),
                url: URL(fileURLWithPath: "/tmp/byte-retention-\(batch)-success"),
                intent: .trash,
                disposition: .succeeded,
                mutation: .changed,
                affectedBytes: 1,
                receipt: receipt)]
            for index in 1..<CleaningOperationLimits.maximumFactCount {
                let requestID = UUID()
                specs.append(ReportItemSpec(
                    requestID: requestID,
                    itemID: UUID(),
                    url: URL(fileURLWithPath: "/tmp/byte-retention-\(batch)-failed-\(index)"),
                    intent: .trash,
                    disposition: .failed(boundIssue(
                        code: String(repeating: "x", count: 200),
                        requestID: requestID)),
                    mutation: .none,
                    affectedBytes: 0,
                    receipt: nil))
            }
            let report = try makeReport(
                operationID: UUID(),
                specs: specs,
                cancellationAccepted: false)
            insertedIDs.append(try insertedRecordID(store.record(
                module: "byte-retention-\(batch)",
                report: report,
                date: Date(timeIntervalSinceReferenceDate: TimeInterval(1_000 + batch)))))
        }

        let current = store.recent(100)
        XCTAssertLessThan(current.count, insertedIDs.count,
                          "the byte ceiling must evict before the 500-record ceiling")
        XCTAssertEqual(current.first?.id, insertedIDs.last)
        XCTAssertEqual(current.first?.restorable, newestReceipt.map { [$0] } ?? [])
        XCTAssertFalse(current.contains { $0.id == insertedIDs.first })
        let archive = try Data(contentsOf: archiveURL)
        XCTAssertLessThanOrEqual(archive.count, HistoryArchiveLimits.maximumArchiveBytes)

        let fresh = HistoryStore(directory: tmpDir)
        XCTAssertEqual(fresh.archiveState, .writable)
        XCTAssertEqual(fresh.recent(100), current)
        XCTAssertEqual(fresh.recent(1).first?.restorable, newestReceipt.map { [$0] } ?? [])
    }

    func testRetentionKeepsNewestFirstAndRejectsAnImmediatelyEvictedInsertion() throws {
        let orderedPersistence = ScriptedHistoryPersistence()
        let orderedStore = HistoryStore(directory: tmpDir, persistence: orderedPersistence)
        XCTAssertNotNil(orderedStore.record(
            module: "newer",
            reclaimedBytes: 1,
            removedCount: 1,
            date: Date(timeIntervalSinceReferenceDate: 20)))
        XCTAssertNotNil(orderedStore.record(
            module: "older",
            reclaimedBytes: 1,
            removedCount: 1,
            date: Date(timeIntervalSinceReferenceDate: 10)))
        XCTAssertEqual(orderedStore.recent(10).map(\.module), ["newer", "older"])

        let seedRecords = (0..<HistoryArchiveLimits.maximumRecords).reversed().map { index in
            legacyRecordObject(
                date: TimeInterval(index),
                module: "retained-\(index)",
                reclaimedBytes: 1,
                removedCount: 1)
        }
        let seedData = try archiveData(seedRecords)
        let persistence = ScriptedHistoryPersistence(loadResult: loadedResult(seedData))
        let store = HistoryStore(directory: tmpDir, persistence: persistence)
        let result = store.record(
            module: "too-old-to-retain",
            report: try makeSucceededReport(operationID: fixedOperationID),
            date: Date(timeIntervalSinceReferenceDate: -1))

        XCTAssertEqual(result, .rejected(code: "history.retention.tooOld"))
        XCTAssertEqual(persistence.commitCount, 0)
        XCTAssertEqual(store.totalHistoryRecords, HistoryArchiveLimits.maximumRecords)
        XCTAssertFalse(store.recent(1_000).contains { $0.module == "too-old-to-retain" })
        XCTAssertEqual(store.recent(1).first?.module, "retained-499")
        XCTAssertEqual(HistoryStore(directory: tmpDir, persistence: persistence).recent(1_000),
                       store.recent(1_000))
    }

    func testUpdateRestorablePreservesOperationFactsAcrossReload() throws {
        let first = RestorableItem(
            originalURL: URL(fileURLWithPath: "/tmp/update-first"),
            trashedURL: URL(fileURLWithPath: "/tmp/update-trash/first"))
        let second = RestorableItem(
            originalURL: URL(fileURLWithPath: "/tmp/update-second"),
            trashedURL: URL(fileURLWithPath: "/tmp/update-trash/second"))
        let report = try makeReportWithReceipts(
            operationID: fixedOperationID, receipts: [first, second])
        let persistence = ScriptedHistoryPersistence()
        let store = HistoryStore(directory: tmpDir, persistence: persistence)
        let recordID = try insertedRecordID(
            store.record(module: "update", report: report, date: fixedRecordDate))
        let before = try XCTUnwrap(store.recent(1).first)

        XCTAssertEqual(store.updateRestorable(id: recordID, to: [first]), .committed)
        let after = try XCTUnwrap(store.recent(1).first)

        assertImmutableFactsEqual(before, after)
        XCTAssertEqual(after.restorable, [first])
        XCTAssertEqual(after.itemFacts.compactMap(\.receipt), [first])
        let fresh = try XCTUnwrap(
            HistoryStore(directory: tmpDir, persistence: persistence).recent(1).first)
        XCTAssertEqual(fresh, after)
    }

    func testUpdateRestorableRejectsForgedChangedOrExpandedReceiptSet() throws {
        let first = RestorableItem(
            originalURL: URL(fileURLWithPath: "/tmp/reject-first"),
            trashedURL: URL(fileURLWithPath: "/tmp/reject-trash/first"))
        let second = RestorableItem(
            originalURL: URL(fileURLWithPath: "/tmp/reject-second"),
            trashedURL: URL(fileURLWithPath: "/tmp/reject-trash/second"))
        let changed = RestorableItem(
            originalURL: first.originalURL,
            trashedURL: URL(fileURLWithPath: "/tmp/reject-trash/changed"))
        let changedOriginal = RestorableItem(
            originalURL: URL(fileURLWithPath: "/tmp/reject-changed-original"),
            trashedURL: first.trashedURL)
        let added = RestorableItem(
            originalURL: URL(fileURLWithPath: "/tmp/reject-added"),
            trashedURL: URL(fileURLWithPath: "/tmp/reject-trash/added"))
        let remoteAlias = RestorableItem(
            originalURL: try XCTUnwrap(
                URL(string: "https://example.invalid/tmp/reject-first")),
            trashedURL: try XCTUnwrap(
                URL(string: "https://example.invalid/tmp/reject-trash/first")))
        let queryAlias = RestorableItem(
            originalURL: try XCTUnwrap(
                URL(string: "file:///tmp/reject-first?token=private")),
            trashedURL: try XCTUnwrap(
                URL(string: "file:///tmp/reject-trash/first?token=private")))
        let dotSegmentAlias = RestorableItem(
            originalURL: try XCTUnwrap(
                URL(string: "file:///tmp/alias-parent/../reject-first")),
            trashedURL: try XCTUnwrap(
                URL(string: "file:///tmp/alias-parent/../reject-trash/first")))
        let persistence = ScriptedHistoryPersistence()
        let store = HistoryStore(directory: tmpDir, persistence: persistence)
        let report = try makeReportWithReceipts(
            operationID: fixedOperationID, receipts: [first, second])
        let recordID = try insertedRecordID(
            store.record(module: "typed-receipts", report: report, date: fixedRecordDate))
        let committedBytes = try XCTUnwrap(persistence.committedPayloads.last)

        for forged in [
            [changed], [changedOriginal], [first, second, added], [first, first],
            [remoteAlias], [queryAlias], [dotSegmentAlias]
        ] {
            XCTAssertEqual(store.updateRestorable(id: recordID, to: forged),
                           .rejected(code: "history.receipt.notRemoveOnly"))
            XCTAssertEqual(store.recent(1).first?.restorable, [first, second])
            XCTAssertEqual(persistence.committedPayloads.last, committedBytes)
        }
        XCTAssertEqual(persistence.commitCount, 1)

        let legacyPersistence = ScriptedHistoryPersistence()
        let legacyStore = HistoryStore(directory: tmpDir, persistence: legacyPersistence)
        let legacyID = try XCTUnwrap(legacyStore.record(
            module: "legacy-receipts",
            reclaimedBytes: 2,
            removedCount: 2,
            restorable: [first, second],
            date: fixedRecordDate))
        XCTAssertEqual(legacyStore.updateRestorable(id: legacyID, to: [first]), .committed,
                       "Schema-0 compatibility permits only a subset of its exact existing pairs")
        XCTAssertEqual(legacyStore.recent(1).first?.restorable, [first])
        for forged in [
            [changed], [changedOriginal], [first, added], [first, first],
            [remoteAlias], [queryAlias], [dotSegmentAlias]
        ] {
            XCTAssertEqual(legacyStore.updateRestorable(id: legacyID, to: forged),
                           .rejected(code: "history.receipt.notRemoveOnly"))
        }
        XCTAssertEqual(legacyStore.clearRestorable(id: legacyID), .committed)
        XCTAssertTrue(legacyStore.recent(1).first?.restorable.isEmpty == true)
    }

    func testFirstUndoablePruningPreservesOperationFactsAcrossReload() throws {
        let alive = RestorableItem(
            originalURL: URL(fileURLWithPath: "/tmp/prune-alive"),
            trashedURL: URL(fileURLWithPath: "/tmp/prune-trash/alive"))
        let missing = RestorableItem(
            originalURL: URL(fileURLWithPath: "/tmp/prune-missing"),
            trashedURL: URL(fileURLWithPath: "/tmp/prune-trash/missing"))
        let report = try makeReportWithReceipts(
            operationID: fixedOperationID, receipts: [alive, missing])
        let persistence = ScriptedHistoryPersistence()
        let store = HistoryStore(directory: tmpDir, persistence: persistence)
        _ = try insertedRecordID(
            store.record(module: "prune", report: report, date: fixedRecordDate))
        let before = try XCTUnwrap(store.recent(1).first)

        let pruned = try XCTUnwrap(store.firstUndoable(
            existsInTrash: { $0 == alive.trashedURL }))

        assertImmutableFactsEqual(before, pruned)
        XCTAssertEqual(pruned.restorable, [alive])
        XCTAssertEqual(pruned.itemFacts.compactMap(\.receipt), [alive])
        let fresh = try XCTUnwrap(
            HistoryStore(directory: tmpDir, persistence: persistence).recent(1).first)
        XCTAssertEqual(fresh, pruned)
    }

    func testRemoveUsesInjectedTransactionForEveryOutcomeAndNotFound() throws {
        func scenario(
            _ actions: [ScriptedHistoryPersistence.CommitAction] = []
        ) throws -> (HistoryStore, ScriptedHistoryPersistence, UUID, CleaningRecord, Data) {
            let persistence = ScriptedHistoryPersistence()
            let seed = try makeScalarSeed(persistence: persistence, receipts: [])
            persistence.replaceCommitActions(actions)
            return (seed.store, persistence, seed.id, seed.record, seed.data)
        }

        do {
            let (store, persistence, id, _, seedData) = try scenario()
            XCTAssertEqual(store.remove(id: id), .committed)
            XCTAssertTrue(store.recent(10).isEmpty)
            XCTAssertTrue(HistoryStore(directory: tmpDir, persistence: persistence)
                .recent(10).isEmpty)
            XCTAssertEqual(persistence.commitCount, 2)
            XCTAssertEqual(persistence.expectedRevisions, [.missing, revision(of: seedData)])
        }

        do {
            let (store, persistence, id, before, seedData) = try scenario([
                .failed(code: "history.persistence.removeFailed")
            ])
            XCTAssertEqual(store.remove(id: id),
                           .rejected(code: "history.persistence.removeFailed"))
            XCTAssertEqual(store.recent(1).first, before)
            XCTAssertEqual(persistence.loadedData, seedData)
            XCTAssertEqual(
                HistoryStore(directory: tmpDir, persistence: persistence).recent(1).first,
                before)
            XCTAssertEqual(persistence.commitCount, 2)
            XCTAssertEqual(persistence.expectedRevisions, [.missing, revision(of: seedData)])
        }

        do {
            let (store, persistence, id, _, seedData) = try scenario([
                .indeterminateUsingCandidate(code: "history.persistence.parentFsyncFailed")
            ])
            XCTAssertEqual(store.remove(id: id),
                           .rejected(code: "history.persistence.durabilityUnknown"))
            XCTAssertTrue(store.recent(10).isEmpty,
                          "The observed post-rename remove candidate is the honest read model")
            XCTAssertTrue(HistoryStore(directory: tmpDir, persistence: persistence)
                .recent(10).isEmpty)
            XCTAssertEqual(store.archiveState,
                           .degradedReadOnly(code: "history.persistence.durabilityUnknown"))
            XCTAssertEqual(persistence.commitCount, 2)
            XCTAssertEqual(persistence.expectedRevisions, [.missing, revision(of: seedData)])
        }

        do {
            let (store, persistence, id, before, seedData) = try scenario([
                .conflict(latest: .failed(code: "history.persistence.removeCASReadFailed"))
            ])
            XCTAssertEqual(store.remove(id: id),
                           .rejected(code: "history.persistence.removeCASReadFailed"))
            XCTAssertEqual(store.archiveState,
                           .degradedReadOnly(code: "history.persistence.removeCASReadFailed"))
            XCTAssertEqual(store.recent(1).first, before)
            let fresh = HistoryStore(directory: tmpDir, persistence: persistence)
            XCTAssertEqual(fresh.archiveState,
                           .degradedReadOnly(code: "history.persistence.removeCASReadFailed"))
            XCTAssertTrue(fresh.recent(10).isEmpty)
            XCTAssertEqual(persistence.commitCount, 2)
            XCTAssertEqual(persistence.expectedRevisions, [.missing, revision(of: seedData)])
        }

        do {
            let (store, persistence, _, before, seedData) = try scenario()
            XCTAssertEqual(store.remove(id: UUID()), .notFound)
            XCTAssertEqual(store.recent(1).first, before)
            XCTAssertEqual(persistence.loadedData, seedData)
            XCTAssertEqual(persistence.commitCount, 1)
            XCTAssertEqual(
                HistoryStore(directory: tmpDir, persistence: persistence).recent(1).first,
                before)
        }
    }

    func testReceiptUpdatesUseInjectedTransactionForEveryOutcomeAndNotFound() throws {
        let first = RestorableItem(
            originalURL: URL(fileURLWithPath: "/tmp/update-transaction-first"),
            trashedURL: URL(fileURLWithPath: "/tmp/update-transaction-trash/first"))
        let second = RestorableItem(
            originalURL: URL(fileURLWithPath: "/tmp/update-transaction-second"),
            trashedURL: URL(fileURLWithPath: "/tmp/update-transaction-trash/second"))

        for route in ["update", "clearRestorable"] {
            func scenario(
                _ actions: [ScriptedHistoryPersistence.CommitAction] = []
            ) throws -> (HistoryStore, ScriptedHistoryPersistence, UUID, CleaningRecord, Data) {
                let persistence = ScriptedHistoryPersistence()
                let seed = try makeScalarSeed(
                    persistence: persistence, receipts: [first, second])
                persistence.replaceCommitActions(actions)
                return (seed.store, persistence, seed.id, seed.record, seed.data)
            }
            func mutate(_ store: HistoryStore, _ id: UUID) -> HistoryUpdateResult {
                route == "update"
                    ? store.updateRestorable(id: id, to: [first])
                    : store.clearRestorable(id: id)
            }
            let expectedReceipts = route == "update" ? [first] : []

            do {
                let (store, persistence, id, before, seedData) = try scenario()
                XCTAssertEqual(mutate(store, id), .committed, route)
                let current = try XCTUnwrap(store.recent(1).first)
                assertImmutableFactsEqual(before, current)
                XCTAssertEqual(current.restorable, expectedReceipts, route)
                XCTAssertEqual(
                    HistoryStore(directory: tmpDir, persistence: persistence)
                        .recent(1).first,
                    current,
                    route)
                XCTAssertEqual(persistence.commitCount, 2, route)
                XCTAssertEqual(persistence.expectedRevisions,
                               [.missing, revision(of: seedData)], route)
            }

            do {
                let code = "history.persistence.\(route)Failed"
                let (store, persistence, id, before, seedData) = try scenario([
                    .failed(code: code)
                ])
                XCTAssertEqual(mutate(store, id), .rejected(code: code), route)
                XCTAssertEqual(store.recent(1).first, before, route)
                XCTAssertEqual(persistence.loadedData, seedData, route)
                XCTAssertEqual(
                    HistoryStore(directory: tmpDir, persistence: persistence)
                        .recent(1).first,
                    before,
                    route)
                XCTAssertEqual(persistence.commitCount, 2, route)
                XCTAssertEqual(persistence.expectedRevisions,
                               [.missing, revision(of: seedData)], route)
            }

            do {
                let (store, persistence, id, before, seedData) = try scenario([
                    .indeterminateUsingCandidate(
                        code: "history.persistence.parentFsyncFailed")
                ])
                XCTAssertEqual(mutate(store, id),
                               .rejected(code: "history.persistence.durabilityUnknown"),
                               route)
                let observed = try XCTUnwrap(store.recent(1).first)
                assertImmutableFactsEqual(before, observed)
                XCTAssertEqual(observed.restorable, expectedReceipts, route)
                XCTAssertEqual(store.archiveState,
                               .degradedReadOnly(
                                code: "history.persistence.durabilityUnknown"), route)
                XCTAssertEqual(
                    HistoryStore(directory: tmpDir, persistence: persistence)
                        .recent(1).first,
                    observed,
                    route)
                XCTAssertEqual(persistence.commitCount, 2, route)
                XCTAssertEqual(persistence.expectedRevisions,
                               [.missing, revision(of: seedData)], route)
            }

            do {
                let code = "history.persistence.\(route)CASReadFailed"
                let (store, persistence, id, before, seedData) = try scenario([
                    .conflict(latest: .failed(code: code))
                ])
                XCTAssertEqual(mutate(store, id), .rejected(code: code), route)
                XCTAssertEqual(store.archiveState, .degradedReadOnly(code: code), route)
                XCTAssertEqual(store.recent(1).first, before, route)
                let fresh = HistoryStore(directory: tmpDir, persistence: persistence)
                XCTAssertEqual(fresh.archiveState, .degradedReadOnly(code: code), route)
                XCTAssertTrue(fresh.recent(10).isEmpty, route)
                XCTAssertEqual(persistence.commitCount, 2, route)
                XCTAssertEqual(persistence.expectedRevisions,
                               [.missing, revision(of: seedData)], route)
            }

            do {
                let (store, persistence, _, before, seedData) = try scenario()
                XCTAssertEqual(mutate(store, UUID()), .notFound, route)
                XCTAssertEqual(store.recent(1).first, before, route)
                XCTAssertEqual(persistence.loadedData, seedData, route)
                XCTAssertEqual(persistence.commitCount, 1, route)
                XCTAssertEqual(
                    HistoryStore(directory: tmpDir, persistence: persistence)
                        .recent(1).first,
                    before,
                    route)
            }
        }
    }

    func testClearUsesInjectedTransactionForEveryOutcome() throws {
        func scenario(
            _ actions: [ScriptedHistoryPersistence.CommitAction] = []
        ) throws -> (HistoryStore, ScriptedHistoryPersistence, CleaningRecord, Data) {
            let persistence = ScriptedHistoryPersistence()
            let seed = try makeScalarSeed(persistence: persistence, receipts: [])
            persistence.replaceCommitActions(actions)
            return (seed.store, persistence, seed.record, seed.data)
        }

        do {
            let (store, persistence, _, seedData) = try scenario()
            XCTAssertEqual(store.clear(), .committed)
            XCTAssertTrue(store.recent(10).isEmpty)
            XCTAssertTrue(HistoryStore(directory: tmpDir, persistence: persistence)
                .recent(10).isEmpty)
            XCTAssertEqual(persistence.commitCount, 2)
            XCTAssertEqual(persistence.expectedRevisions, [.missing, revision(of: seedData)])
        }
        do {
            let (store, persistence, before, seedData) = try scenario([
                .failed(code: "history.persistence.clearFailed")
            ])
            XCTAssertEqual(store.clear(),
                           .rejected(code: "history.persistence.clearFailed"))
            XCTAssertEqual(store.recent(1).first, before)
            XCTAssertEqual(persistence.loadedData, seedData)
            XCTAssertEqual(
                HistoryStore(directory: tmpDir, persistence: persistence).recent(1).first,
                before)
            XCTAssertEqual(persistence.commitCount, 2)
            XCTAssertEqual(persistence.expectedRevisions, [.missing, revision(of: seedData)])
        }
        do {
            let (store, persistence, _, seedData) = try scenario([
                .indeterminateUsingCandidate(code: "history.persistence.parentFsyncFailed")
            ])
            XCTAssertEqual(store.clear(),
                           .rejected(code: "history.persistence.durabilityUnknown"))
            XCTAssertTrue(store.recent(10).isEmpty)
            XCTAssertTrue(HistoryStore(directory: tmpDir, persistence: persistence)
                .recent(10).isEmpty)
            XCTAssertEqual(store.archiveState,
                           .degradedReadOnly(code: "history.persistence.durabilityUnknown"))
            XCTAssertEqual(persistence.commitCount, 2)
            XCTAssertEqual(persistence.expectedRevisions, [.missing, revision(of: seedData)])
        }
        do {
            let code = "history.persistence.clearCASReadFailed"
            let (store, persistence, before, seedData) = try scenario([
                .conflict(latest: .failed(code: code))
            ])
            XCTAssertEqual(store.clear(), .rejected(code: code))
            XCTAssertEqual(store.archiveState, .degradedReadOnly(code: code))
            XCTAssertEqual(store.recent(1).first, before)
            let fresh = HistoryStore(directory: tmpDir, persistence: persistence)
            XCTAssertEqual(fresh.archiveState, .degradedReadOnly(code: code))
            XCTAssertTrue(fresh.recent(10).isEmpty)
            XCTAssertEqual(persistence.commitCount, 2)
            XCTAssertEqual(persistence.expectedRevisions, [.missing, revision(of: seedData)])
        }
    }

    func testVerifiedConflictBaseRemainsVisibleAfterRetryWriteOrEncodeFailure() throws {
        do {
            let latestData = try archiveData([
                legacyRecordObject(
                    module: "conflict-write-base", reclaimedBytes: 3, removedCount: 1)
            ])
            let code = "history.persistence.retryWriteFailed"
            let persistence = ScriptedHistoryPersistence(commitActions: [
                .conflict(latest: loadedResult(latestData)),
                .failed(code: code)
            ])
            let store = HistoryStore(directory: tmpDir, persistence: persistence)

            XCTAssertNil(store.record(
                module: "conflict-write-candidate",
                reclaimedBytes: 7,
                removedCount: 1,
                date: fixedRecordDate))
            XCTAssertEqual(persistence.commitCount, 2)
            XCTAssertEqual(store.archiveState, .writable)
            XCTAssertEqual(store.recent(10).map(\.module), ["conflict-write-base"])
            XCTAssertEqual(store.totalReclaimedAllTime, 3)
            XCTAssertEqual(HistoryStore(
                directory: tmpDir,
                persistence: persistence).recent(10), store.recent(10))
        }

        do {
            let base = legacyRecordObject(
                module: "conflict-encode-base",
                reclaimedBytes: 3,
                removedCount: 1,
                restorable: [receiptObject(
                    original: "file:///tmp/",
                    trashed: "file:///tmp/conflict-encode-trash")])
            let baseline = try archiveData([base])
            let targetSize = HistoryArchiveLimits.maximumArchiveBytes - 64
            let paddingCount = targetSize - baseline.count
            XCTAssertGreaterThan(paddingCount, 0)
            var paddedBase = base
            var receipts = try XCTUnwrap(paddedBase["restorable"] as? [[String: Any]])
            receipts[0]["originalURL"] = "file:///tmp/" + String(repeating: "a", count: paddingCount)
            paddedBase["restorable"] = receipts
            let latestData = try archiveData([paddedBase])
            XCTAssertEqual(latestData.count, targetSize)
            XCTAssertGreaterThan(
                try archiveData([
                    legacyRecordObject(
                        module: "conflict-encode-candidate",
                        reclaimedBytes: 1,
                        removedCount: 1),
                    paddedBase
                ]).count,
                HistoryArchiveLimits.maximumArchiveBytes)
            let persistence = ScriptedHistoryPersistence(commitActions: [
                .conflict(latest: loadedResult(latestData))
            ])
            let store = HistoryStore(directory: tmpDir, persistence: persistence)

            let insertedID = try XCTUnwrap(store.record(
                module: "conflict-encode-candidate",
                reclaimedBytes: 1,
                removedCount: 1,
                date: fixedRecordDate))
            XCTAssertEqual(persistence.commitCount, 2,
                           "The retry must evict the oversized oldest record and commit once")
            XCTAssertEqual(store.archiveState, .writable)
            XCTAssertEqual(store.recent(10).map(\.module), ["conflict-encode-candidate"])
            XCTAssertEqual(store.recent(1).first?.id, insertedID)
            let fresh = HistoryStore(directory: tmpDir, persistence: persistence)
            XCTAssertEqual(fresh.totalHistoryRecords, 1)
            XCTAssertEqual(fresh.recent(1).first?.module, "conflict-encode-candidate")
            XCTAssertEqual(fresh.recent(1).first?.id, insertedID)
        }
    }

    func testScalarRouteRetriesVerifiedConflictAndExhaustsAfterEightAttempts() throws {
        do {
            let latestData = try archiveData([
                legacyRecordObject(
                    module: "scalar-conflict-external", reclaimedBytes: 1, removedCount: 1)
            ])
            let persistence = ScriptedHistoryPersistence(commitActions: [
                .conflict(latest: loadedResult(latestData)),
                .committed
            ])
            let store = HistoryStore(directory: tmpDir, persistence: persistence)

            let id = try XCTUnwrap(store.record(
                module: "scalar-conflict-candidate",
                reclaimedBytes: 7,
                removedCount: 1,
                date: fixedRecordDate))

            XCTAssertEqual(persistence.commitCount, 2)
            XCTAssertEqual(persistence.expectedRevisions,
                           [.missing, revision(of: latestData)])
            XCTAssertEqual(Set(store.recent(10).map(\.module)), [
                "scalar-conflict-external", "scalar-conflict-candidate"
            ])
            XCTAssertEqual(store.recent(10).first { $0.id == id }?.reclaimedBytes, 7)
            XCTAssertEqual(HistoryStore(
                directory: tmpDir,
                persistence: persistence).recent(10),
                           store.recent(10))
        }

        do {
            let persistence = ScriptedHistoryPersistence()
            let store = HistoryStore(directory: tmpDir, persistence: persistence)
            let conflicts = try verifiedConflictActions(
                startingFrom: try archiveData([]),
                count: 8,
                prefix: "scalar-conflict-exhausted")
            persistence.replaceCommitActions(conflicts)

            XCTAssertNil(store.record(
                module: "scalar-must-not-publish",
                reclaimedBytes: 7,
                removedCount: 1,
                date: fixedRecordDate))

            XCTAssertEqual(persistence.commitCount, 8)
            let emptyData = try archiveData([])
            let conflictRevisions = try (1..<8).map { attempt in
                revision(of: try appendingLegacyRecords(
                    to: emptyData,
                    count: attempt,
                    prefix: "scalar-conflict-exhausted"))
            }
            XCTAssertEqual(persistence.expectedRevisions,
                           [.missing] + conflictRevisions)
            XCTAssertTrue(store.recent(10).isEmpty)
            let fresh = HistoryStore(directory: tmpDir, persistence: persistence)
            XCTAssertFalse(fresh.recent(100).contains {
                $0.module == "scalar-must-not-publish"
            })
            XCTAssertTrue((0..<8).allSatisfy { index in
                fresh.recent(100).contains {
                    $0.module == "scalar-conflict-exhausted-\(index)"
                }
            })
        }
    }

    func testRemoveAndClearRoutesRetryVerifiedConflictAndExhaustAfterEightAttempts() throws {
        let receipt = RestorableItem(
            originalURL: URL(fileURLWithPath: "/tmp/remove-clear-conflict-original"),
            trashedURL: URL(fileURLWithPath: "/tmp/remove-clear-conflict-trash/item"))
        for route in ["remove", "clear"] {
            do {
                let persistence = ScriptedHistoryPersistence()
                let seed = try makeTypedSeed(
                    persistence: persistence,
                    receipts: [receipt],
                    module: "\(route)-conflict-target")
                let latestData = try appendingLegacyRecords(
                    to: seed.data, count: 1, prefix: "\(route)-conflict-external")
                persistence.replaceCommitActions([
                    .conflict(latest: loadedResult(latestData)),
                    .committed
                ])

                let result = route == "remove"
                    ? seed.store.remove(id: seed.id)
                    : seed.store.clear()

                XCTAssertEqual(result, .committed, route)
                XCTAssertEqual(persistence.commitCount, 3, route)
                XCTAssertEqual(persistence.expectedRevisions,
                               [.missing,
                                revision(of: seed.data),
                                revision(of: latestData)],
                               route)
                let currentModules = Set(seed.store.recent(10).map(\.module))
                XCTAssertEqual(currentModules,
                               route == "remove"
                                ? Set(["\(route)-conflict-external-0"])
                                : Set<String>(),
                               route)
                XCTAssertEqual(HistoryStore(
                    directory: tmpDir,
                    persistence: persistence).recent(10),
                               seed.store.recent(10),
                               route)
            }

            do {
                let persistence = ScriptedHistoryPersistence()
                let seed = try makeTypedSeed(
                    persistence: persistence,
                    receipts: [receipt],
                    module: "\(route)-exhausted-target")
                persistence.replaceCommitActions(try verifiedConflictActions(
                    startingFrom: seed.data,
                    count: 8,
                    prefix: "\(route)-conflict-exhausted"))

                let result = route == "remove"
                    ? seed.store.remove(id: seed.id)
                    : seed.store.clear()

                XCTAssertEqual(result,
                               .rejected(code: "history.persistence.conflictExhausted"),
                               route)
                XCTAssertEqual(persistence.commitCount, 9, route)
                XCTAssertEqual(
                    persistence.expectedRevisions,
                    [.missing] + (try expectedRevisionsForVerifiedConflicts(
                        startingFrom: seed.data,
                        count: 8,
                        prefix: "\(route)-conflict-exhausted")),
                    route)
                XCTAssertEqual(seed.store.recent(1).first, seed.record, route)
                let fresh = HistoryStore(directory: tmpDir, persistence: persistence)
                XCTAssertTrue(fresh.recent(100).contains { $0.id == seed.id }, route)
                XCTAssertTrue((0..<8).allSatisfy { index in
                    fresh.recent(100).contains {
                        $0.module == "\(route)-conflict-exhausted-\(index)"
                    }
                }, route)
            }
        }
    }

    func testReceiptRoutesRetryConflictsForSchema0AndSchema1AndExhaustAfterEightAttempts()
    throws {
        let first = RestorableItem(
            originalURL: URL(fileURLWithPath: "/tmp/receipt-conflict-first"),
            trashedURL: URL(fileURLWithPath: "/tmp/receipt-conflict-trash/first"))
        let second = RestorableItem(
            originalURL: URL(fileURLWithPath: "/tmp/receipt-conflict-second"),
            trashedURL: URL(fileURLWithPath: "/tmp/receipt-conflict-trash/second"))

        func seed(
            schema: Int,
            persistence: ScriptedHistoryPersistence,
            module: String
        ) throws -> (store: HistoryStore, id: UUID, record: CleaningRecord, data: Data) {
            if schema == 0 {
                return try makeScalarSeed(
                    persistence: persistence,
                    receipts: [first, second],
                    module: module)
            }
            let store = HistoryStore(directory: tmpDir, persistence: persistence)
            let id = try insertedRecordID(store.record(
                module: module,
                report: makeReportWithReceipts(receipts: [first, second]),
                date: fixedRecordDate))
            return (store,
                    id,
                    try XCTUnwrap(store.recent(1).first),
                    try XCTUnwrap(persistence.committedPayloads.last))
        }

        for schema in [0, 1] {
            for route in ["update", "clearRestorable"] {
                func mutate(_ store: HistoryStore, id: UUID) -> HistoryUpdateResult {
                    route == "update"
                        ? store.updateRestorable(id: id, to: [first])
                        : store.clearRestorable(id: id)
                }
                let expectedReceipts = route == "update" ? [first] : []
                let label = "schema\(schema)-\(route)"

                do {
                    let persistence = ScriptedHistoryPersistence()
                    let seeded = try seed(
                        schema: schema,
                        persistence: persistence,
                        module: "\(label)-target")
                    let latestData = try appendingLegacyRecords(
                        to: seeded.data, count: 1, prefix: "\(label)-external")
                    persistence.replaceCommitActions([
                        .conflict(latest: loadedResult(latestData)),
                        .committed
                    ])

                    XCTAssertEqual(mutate(seeded.store, id: seeded.id), .committed, label)
                    XCTAssertEqual(persistence.commitCount, 3, label)
                    XCTAssertEqual(persistence.expectedRevisions,
                                   [.missing,
                                    revision(of: seeded.data),
                                    revision(of: latestData)],
                                   label)
                    let current = try XCTUnwrap(seeded.store.recent(100).first {
                        $0.id == seeded.id
                    })
                    assertImmutableFactsEqual(seeded.record, current)
                    XCTAssertEqual(current.restorable, expectedReceipts, label)
                    XCTAssertEqual(current.itemFacts.compactMap(\.receipt),
                                   schema == 1 ? expectedReceipts : [],
                                   label)
                    let fresh = HistoryStore(directory: tmpDir, persistence: persistence)
                    XCTAssertEqual(fresh.recent(100), seeded.store.recent(100), label)
                    XCTAssertTrue(fresh.recent(100).contains {
                        $0.module == "\(label)-external-0"
                    }, label)
                }

                do {
                    let persistence = ScriptedHistoryPersistence()
                    let seeded = try seed(
                        schema: schema,
                        persistence: persistence,
                        module: "\(label)-exhausted-target")
                    persistence.replaceCommitActions(try verifiedConflictActions(
                        startingFrom: seeded.data,
                        count: 8,
                        prefix: "\(label)-conflict-exhausted"))

                    XCTAssertEqual(
                        mutate(seeded.store, id: seeded.id),
                        .rejected(code: "history.persistence.conflictExhausted"),
                        label)
                    XCTAssertEqual(persistence.commitCount, 9, label)
                    XCTAssertEqual(
                        persistence.expectedRevisions,
                        [.missing] + (try expectedRevisionsForVerifiedConflicts(
                            startingFrom: seeded.data,
                            count: 8,
                            prefix: "\(label)-conflict-exhausted")),
                        label)
                    XCTAssertEqual(seeded.store.recent(1).first, seeded.record, label)
                    let fresh = HistoryStore(directory: tmpDir, persistence: persistence)
                    let freshTarget = try XCTUnwrap(fresh.recent(100).first {
                        $0.id == seeded.id
                    })
                    assertImmutableFactsEqual(seeded.record, freshTarget)
                    XCTAssertEqual(freshTarget.restorable, [first, second], label)
                    XCTAssertEqual(freshTarget.itemFacts.compactMap(\.receipt),
                                   schema == 1 ? [first, second] : [],
                                   label)
                    XCTAssertTrue((0..<8).allSatisfy { index in
                        fresh.recent(100).contains {
                            $0.module == "\(label)-conflict-exhausted-\(index)"
                        }
                    }, label)
                }
            }
        }
    }

    func testHistoryArchiveLockAndStagingFilesUsePrivatePermissions() throws {
        let directory = try makeCaseDirectory("private-file-modes")
        try setPermissions(0o755, at: directory)
        let capture = OpenedFileModeCapture()
        let persistence = LiveHistoryPersistence(
            directory: directory,
            hooks: HistoryPersistenceHooks(
                stagingName: { "history.staging.permissions" },
                didOpen: { role, descriptor in
                    capture.record(role: role, descriptor: descriptor)
                }))
        let store = HistoryStore(directory: directory, persistence: persistence)

        _ = try insertedRecordID(store.record(
            module: "private-modes",
            report: makeSucceededReport(),
            date: fixedRecordDate))

        XCTAssertEqual(try permissions(at: directory), 0o700)
        XCTAssertEqual(try permissions(at: directory.appendingPathComponent("history.json")),
                       0o600)
        XCTAssertEqual(try permissions(at: directory.appendingPathComponent("history.lock")),
                       0o600)
        XCTAssertEqual(capture.mode(for: .staging), 0o600,
                       "Staging permissions must be inspected while its descriptor is open")
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: directory.path)),
                       ["history.json", "history.lock"])
    }

    func testLivePersistenceRetriesEINTRShortWritesAndStagingFsync() throws {
        let directory = try makeCaseDirectory("posix-retry-loops")
        let controller = POSIXRetryController()
        let persistence = LiveHistoryPersistence(
            directory: directory,
            hooks: HistoryPersistenceHooks(
                stagingName: { "history.staging.retry-loops" },
                write: { descriptor, pointer, count in
                    controller.write(descriptor: descriptor, pointer: pointer, count: count)
                },
                fsync: { descriptor, role in
                    controller.fsync(descriptor: descriptor, role: role)
                },
                flock: { descriptor, operation in
                    controller.flock(descriptor: descriptor, operation: operation)
                }))
        controller.resetAndArmCommitEpoch()
        let store = HistoryStore(directory: directory, persistence: persistence)
        XCTAssertEqual(controller.failedExclusiveFlockAttemptCount, 1)
        XCTAssertEqual(controller.successfulExclusiveFlockAttemptCount, 1)
        XCTAssertEqual(controller.exclusiveFlockAttemptCount, 2,
                       "The load epoch must independently retry LOCK_EX after EINTR")
        XCTAssertEqual(controller.writeCallCount, 0,
                       "Loading must never enter the staging write path")
        controller.resetAndArmCommitEpoch()
        let report = try makeSucceededReport(operationID: fixedOperationID)

        _ = try insertedRecordID(store.record(
            module: "posix-retry-loops", report: report, date: fixedRecordDate))

        XCTAssertGreaterThanOrEqual(controller.writeCallCount, 3,
                                    "EINTR and a short write require additional write calls")
        XCTAssertTrue(controller.didPerformShortWrite)
        XCTAssertGreaterThanOrEqual(controller.stagingFsyncCallCount, 2,
                                    "The first staging fsync EINTR must be retried")
        XCTAssertEqual(controller.failedExclusiveFlockAttemptCount, 1)
        XCTAssertEqual(controller.successfulExclusiveFlockAttemptCount, 1)
        XCTAssertEqual(controller.exclusiveFlockAttemptCount, 2,
                       "The commit epoch must contain one failed and one successful LOCK_EX")
        XCTAssertTrue(controller.didAcquireExclusiveLockBeforeFirstWrite,
                      "A successful LOCK_EX, not LOCK_UN, must precede archive publication")
        if controller.successfulExplicitUnlockCount > 0 {
            XCTAssertFalse(controller.isExclusiveLockMarkedAcquired,
                           "A successful LOCK_UN must clear the controller's acquired epoch")
        }
        XCTAssertEqual(store.recent(1).first?.operationID, fixedOperationID)
        XCTAssertEqual(HistoryStore(directory: directory).recent(1).first,
                       store.recent(1).first)
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: directory.path)),
                       ["history.json", "history.lock"])
    }

    func testLivePersistenceRetriesEINTRAndShortReadsAndRejectsSameSizeMutation() throws {
        do {
            let directory = try makeCaseDirectory("posix-read-retry-loops")
            let data = try archiveData([
                legacyRecordObject(module: "read-retry", reclaimedBytes: 9, removedCount: 1)
            ])
            try writeArchive(data, directory: directory)
            let controller = POSIXReadRetryController()
            let persistence = LiveHistoryPersistence(
                directory: directory,
                hooks: HistoryPersistenceHooks(read: { descriptor, pointer, count in
                    controller.read(descriptor: descriptor, pointer: pointer, count: count)
                }))

            let store = HistoryStore(directory: directory, persistence: persistence)

            XCTAssertEqual(store.archiveState, .writable)
            XCTAssertEqual(store.recent(1).first?.module, "read-retry")
            XCTAssertEqual(store.totalReclaimedAllTime, 9)
            XCTAssertGreaterThanOrEqual(controller.callCount, 3)
            XCTAssertTrue(controller.didInjectEINTR)
            XCTAssertTrue(controller.didPerformShortRead)
        }

        do {
            let directory = try makeCaseDirectory("same-size-read-mutation")
            let data = try archiveData([
                legacyRecordObject(
                    module: "same-size-read-mutation", reclaimedBytes: 4, removedCount: 1)
            ])
            try writeArchive(data, directory: directory)
            let archive = directory.appendingPathComponent("history.json")
            let controller = SameSizeReadMutationController(archiveURL: archive)
            let persistence = LiveHistoryPersistence(
                directory: directory,
                hooks: HistoryPersistenceHooks(read: { descriptor, pointer, count in
                    controller.read(descriptor: descriptor, pointer: pointer, count: count)
                }))

            let store = HistoryStore(directory: directory, persistence: persistence)

            XCTAssertTrue(controller.didMutate)
            XCTAssertEqual(store.archiveState, .degradedReadOnly(
                code: "history.persistence.archiveChangedDuringRead"))
            XCTAssertTrue(store.recent(10).isEmpty)
            XCTAssertNil(store.record(module: "blocked", reclaimedBytes: 1, removedCount: 1))
            XCTAssertEqual(try Data(contentsOf: archive), data,
                           "The injected mutation rewrites one byte with itself")
        }
    }

    func testLivePersistenceUsesTheSameFlockAsAnExternalProcess() throws {
        let directory = try makeCaseDirectory("external-flock")
        let controller = ExternalFlockController()
        let persistence = LiveHistoryPersistence(
            directory: directory,
            hooks: HistoryPersistenceHooks(flock: { descriptor, operation in
                controller.flock(descriptor: descriptor, operation: operation)
            }))
        let store = HistoryStore(directory: directory, persistence: persistence)
        let holderExecutable = try makeFlockHolderExecutable(in: tmpDir)
        let holderInput = Pipe()
        let holderOutputURL = tmpDir.appendingPathComponent("flock-holder.stdout")
        let holderErrorURL = tmpDir.appendingPathComponent("flock-holder.stderr")
        _ = FileManager.default.createFile(atPath: holderOutputURL.path, contents: nil)
        _ = FileManager.default.createFile(atPath: holderErrorURL.path, contents: nil)
        let holderOutput = try FileHandle(forWritingTo: holderOutputURL)
        let holderError = try FileHandle(forWritingTo: holderErrorURL)
        let holder = Process()
        holder.executableURL = holderExecutable
        holder.arguments = [directory.appendingPathComponent("history.lock").path]
        holder.standardInput = holderInput
        holder.standardOutput = holderOutput
        holder.standardError = holderError
        let holderMonitor = ProcessTerminationMonitor(holder)
        defer {
            controller.allowBlockingLock.signal()
            try? holderInput.fileHandleForWriting.close()
            if holder.isRunning {
                XCTAssertTrue(holderMonitor.stopAndWait(),
                              "External flock holder must be reaped after forced cleanup")
            }
            try? holderOutput.close()
            try? holderError.close()
        }
        try holder.run()
        guard try waitForFilePrefix(
            Data([UInt8(ascii: "R")]), at: holderOutputURL, timeout: 5) else {
            XCTFail("External flock holder did not report readiness before timeout")
            throw TestFailure.unexpectedResult
        }
        controller.arm()

        let started = DispatchSemaphore(value: 0)
        let finished = DispatchSemaphore(value: 0)
        let resultBox = LockedValueBox<HistoryRecordResult?>(nil)
        let report = try makeSucceededReport(operationID: fixedOperationID)
        let date = fixedRecordDate
        DispatchQueue.global(qos: .userInitiated).async {
            started.signal()
            resultBox.set(store.record(
                module: "external-flock", report: report, date: date))
            finished.signal()
        }
        XCTAssertEqual(started.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(controller.observedContention.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(controller.nonblockingErrno, EWOULDBLOCK,
                       "The production lock must contend with the external process lock")

        try holderInput.fileHandleForWriting.write(contentsOf: Data([UInt8(ascii: "X")]))
        try holderInput.fileHandleForWriting.close()
        guard holderMonitor.wait(timeout: .now() + 5) == .success else {
            XCTAssertTrue(holderMonitor.stopAndWait(),
                          "SIGKILL fallback must still reap the external flock holder")
            XCTFail("External flock holder did not exit after bounded release")
            throw TestFailure.unexpectedResult
        }
        try holderError.synchronize()
        let holderDiagnostics = String(
            decoding: try Data(contentsOf: holderErrorURL),
            as: UTF8.self)
        XCTAssertEqual(holder.terminationStatus, 0, holderDiagnostics)
        controller.allowBlockingLock.signal()
        XCTAssertEqual(finished.wait(timeout: .now() + 5), .success)
        _ = try insertedRecordID(try XCTUnwrap(resultBox.value))
        XCTAssertEqual(HistoryStore(directory: directory).recent(1).first?.operationID,
                       fixedOperationID)
    }

    func testProductionFlockCoversCASWriteRenameAndDurabilityFsync() throws {
        let directory = try makeCaseDirectory("flock-full-transaction")
        let archive = directory.appendingPathComponent("history.json")
        try archiveData([
            legacyRecordObject(module: "flock-seed", reclaimedBytes: 1, removedCount: 1)
        ]).write(to: archive)
        let helperExecutable = try makeFlockHolderExecutable(in: tmpDir)
        let trace = FlockCoverageTrace(
            helperExecutable: helperExecutable,
            lockURL: directory.appendingPathComponent("history.lock"))
        let persistence = LiveHistoryPersistence(
            directory: directory,
            hooks: HistoryPersistenceHooks(
                didOpen: { role, descriptor in
                    trace.didOpen(role: role, descriptor: descriptor)
                },
                read: { descriptor, pointer, count in
                    trace.read(descriptor: descriptor, pointer: pointer, count: count)
                },
                write: { descriptor, pointer, count in
                    trace.write(descriptor: descriptor, pointer: pointer, count: count)
                },
                fsync: { descriptor, role in
                    trace.fsync(descriptor: descriptor, role: role)
                },
                rename: { directoryDescriptor, source, destination in
                    trace.rename(
                        directoryDescriptor: directoryDescriptor,
                        source: source,
                        destination: destination)
                },
                flock: { descriptor, operation in
                    trace.flock(descriptor: descriptor, operation: operation)
                },
                didClose: { role, descriptor in
                    trace.didClose(role: role, descriptor: descriptor)
                }))
        let store = HistoryStore(directory: directory, persistence: persistence)
        let loadEvents = trace.events
        XCTAssertGreaterThanOrEqual(loadEvents.filter { $0 == .exclusiveLock }.count, 1,
                                    "Initial load must acquire a successful exclusive lock")
        let loadExclusive = try XCTUnwrap(loadEvents.firstIndex(of: .exclusiveLock))
        let loadArchiveOpen = try XCTUnwrap(loadEvents.firstIndex(of: .archiveOpen))
        let loadArchiveReads = loadEvents.indices.filter {
            loadEvents[$0] == .archiveRead
        }
        let loadLastArchiveRead = try XCTUnwrap(loadArchiveReads.last)
        let loadLockClose = try XCTUnwrap(loadEvents.firstIndex(of: .lockClose))
        XCTAssertLessThan(loadExclusive, loadArchiveOpen)
        XCTAssertFalse(loadArchiveReads.isEmpty,
                       "The seeded archive load must exercise the read hook")
        XCTAssertTrue(loadArchiveReads.allSatisfy { loadExclusive < $0 },
                      "Every archive read must occur after the exclusive lock")
        if loadExclusive <= loadLastArchiveRead {
            XCTAssertFalse(loadEvents[loadExclusive...loadLastArchiveRead].contains(.unlock),
                           "Initial load may not unlock before its final archive read")
        }
        XCTAssertLessThan(loadLastArchiveRead, loadLockClose,
                          "The lock descriptor may close only after archive loading ends")
        XCTAssertEqual(trace.externalProbeStatuses[.archiveOpen],
                       FlockCoverageTrace.externalBlockedExitStatus,
                       "Initial archive load must remain inside the flock interval")
        XCTAssertEqual(trace.probeExternalLockAfterTransaction(),
                       FlockCoverageTrace.externalAcquiredExitStatus,
                       "Load return must release the flock, whether by LOCK_UN or close")
        trace.reset()

        _ = try insertedRecordID(store.record(
            module: "flock-candidate",
            report: makeSucceededReport(operationID: fixedOperationID),
            date: fixedRecordDate))

        let events = trace.events
        XCTAssertGreaterThanOrEqual(events.filter { $0 == .exclusiveLock }.count, 1,
                                    "Commit must acquire a successful exclusive lock")
        let exclusive = try XCTUnwrap(events.firstIndex(of: .exclusiveLock))
        let archiveOpen = try XCTUnwrap(events.firstIndex(of: .archiveOpen))
        let archiveReads = events.indices.filter { events[$0] == .archiveRead }
        let lastArchiveRead = try XCTUnwrap(archiveReads.last)
        let write = try XCTUnwrap(events.firstIndex(of: .write))
        let stagingFsync = try XCTUnwrap(events.firstIndex(of: .stagingFsync))
        let rename = try XCTUnwrap(events.firstIndex(of: .rename))
        let parentFsync = try XCTUnwrap(events.firstIndex(of: .parentFsync))
        let lockClose = try XCTUnwrap(events.firstIndex(of: .lockClose))
        XCTAssertLessThan(exclusive, archiveOpen)
        XCTAssertFalse(archiveReads.isEmpty,
                       "CAS commit must reload the archive through the read hook")
        XCTAssertTrue(archiveReads.allSatisfy { exclusive < $0 },
                      "Every CAS archive read must occur after the exclusive lock")
        XCTAssertLessThan(lastArchiveRead, write,
                          "CAS must finish reading the archive before staging any candidate")
        XCTAssertLessThan(archiveOpen, write)
        XCTAssertLessThan(write, stagingFsync)
        XCTAssertLessThan(stagingFsync, rename)
        XCTAssertLessThan(rename, parentFsync)
        XCTAssertLessThan(parentFsync, lockClose,
                          "The lock descriptor may close only after durable publication")
        if exclusive < parentFsync {
            XCTAssertFalse(events[(exclusive + 1)...parentFsync].contains(.unlock),
                           "No unlock may split CAS from write, rename, or durability fsync")
        }
        XCTAssertEqual(trace.externalProbeStatuses, [
            .archiveOpen: FlockCoverageTrace.externalBlockedExitStatus,
            .parentFsync: FlockCoverageTrace.externalBlockedExitStatus
        ], "An external process must still be excluded at both ends of publication")
        XCTAssertEqual(trace.probeExternalLockAfterTransaction(),
                       FlockCoverageTrace.externalAcquiredExitStatus,
                       "Commit return must release the flock, whether by LOCK_UN or close")
        XCTAssertEqual(trace.externalProbeCleanupFailureCount, 0,
                       "Every timed-out external probe must be forcibly reaped")
        XCTAssertEqual(HistoryStore(directory: directory).recent(10), store.recent(10))
    }

    func testStagingFsyncAndRenameFailuresPreserveArchiveAndCleanOwnedStaging() throws {
        for failurePoint in ["staging-fsync", "rename"] {
            let directory = try makeCaseDirectory("pre-rename-\(failurePoint)")
            let archive = directory.appendingPathComponent("history.json")
            let originalData = try archiveData([
                legacyRecordObject(module: "pre-rename-original", reclaimedBytes: 7)
            ])
            try originalData.write(to: archive)
            let stagingName = "history.staging.\(failurePoint)"
            let hooks: HistoryPersistenceHooks
            if failurePoint == "staging-fsync" {
                hooks = HistoryPersistenceHooks(
                    stagingName: { stagingName },
                    fsync: { descriptor, role in
                        if role == .staging {
                            errno = EIO
                            return -1
                        }
                        return Darwin.fsync(descriptor)
                    })
            } else {
                hooks = HistoryPersistenceHooks(
                    stagingName: { stagingName },
                    rename: { _, _, _ in
                        errno = EIO
                        return -1
                    })
            }
            let store = HistoryStore(
                directory: directory,
                persistence: LiveHistoryPersistence(directory: directory, hooks: hooks))
            XCTAssertEqual(store.recent(1).first?.module, "pre-rename-original")

            let result = store.record(
                module: "must-not-publish-\(failurePoint)",
                report: try makeSucceededReport(),
                date: fixedRecordDate)

            let expectedCode = failurePoint == "staging-fsync"
                ? "history.persistence.stagingFsyncFailed"
                : "history.persistence.renameFailed"
            XCTAssertEqual(result, .rejected(code: expectedCode), failurePoint)
            XCTAssertEqual(store.archiveState, .writable, failurePoint)
            XCTAssertEqual(store.recent(1).first?.module,
                           "pre-rename-original", failurePoint)
            XCTAssertEqual(try Data(contentsOf: archive), originalData, failurePoint)
            XCTAssertEqual(HistoryStore(directory: directory).recent(1).first?.module,
                           "pre-rename-original", failurePoint)
            let entries = Set(try FileManager.default.contentsOfDirectory(
                atPath: directory.path))
            XCTAssertEqual(entries, ["history.json", "history.lock"], failurePoint)
            XCTAssertFalse(entries.contains {
                $0.contains("staging") || $0.contains("recovery")
            }, failurePoint)
        }
    }

    func testStagingInodeReplacementAfterOpenIsRejectedWithoutDeletingReplacement() throws {
        let directory = try makeCaseDirectory("staging-inode-replacement")
        let archive = directory.appendingPathComponent("history.json")
        let originalData = try archiveData([
            legacyRecordObject(module: "inode-original", reclaimedBytes: 4)
        ])
        try originalData.write(to: archive)
        let stagingName = "history.staging.inode-replacement"
        let staging = directory.appendingPathComponent(stagingName)
        let replacementData = Data("attacker-owned-replacement-sentinel".utf8)
        let swap = StagingInodeSwapController(
            stagingURL: staging, replacementData: replacementData)
        let persistence = LiveHistoryPersistence(
            directory: directory,
            hooks: HistoryPersistenceHooks(
                stagingName: { stagingName },
                didOpen: { role, descriptor in
                    if role == .staging { swap.replaceNamedInode(openDescriptor: descriptor) }
                }))
        let store = HistoryStore(directory: directory, persistence: persistence)

        let result = store.record(
            module: "inode-candidate", report: try makeSucceededReport(), date: fixedRecordDate)

        guard case .rejected = result else {
            return XCTFail("Changed staging identity must reject, got \(result)")
        }
        XCTAssertTrue(swap.didReplaceWithDifferentInode)
        assertDegraded(store)
        XCTAssertEqual(store.recent(1).first?.module, "inode-original")
        XCTAssertEqual(try Data(contentsOf: archive), originalData)
        XCTAssertEqual(try Data(contentsOf: staging), replacementData,
                       "Cleanup may unlink only the staging inode it created")
        XCTAssertEqual(HistoryStore(directory: directory).recent(1).first?.module,
                       "inode-original")
        let entries = Set(try FileManager.default.contentsOfDirectory(atPath: directory.path))
        XCTAssertFalse(entries.contains { $0.contains("recovery") })
    }

    func testExistingLegacyArchivePermissionsAreCorrectedWithoutRewritingBytes() throws {
        let directory = try makeCaseDirectory("legacy-file-modes")
        let data = try archiveData([
            legacyRecordObject(module: "legacy-private", reclaimedBytes: 8, removedCount: 1)
        ])
        let archive = directory.appendingPathComponent("history.json")
        let lock = directory.appendingPathComponent("history.lock")
        try data.write(to: archive)
        try Data("legacy-lock-content".utf8).write(to: lock)
        try setPermissions(0o755, at: directory)
        try setPermissions(0o644, at: archive)
        try setPermissions(0o644, at: lock)

        let store = HistoryStore(
            directory: directory,
            persistence: LiveHistoryPersistence(directory: directory))

        XCTAssertEqual(store.archiveState, .writable)
        XCTAssertEqual(store.recent(1).first?.module, "legacy-private")
        XCTAssertEqual(try permissions(at: directory), 0o700)
        XCTAssertEqual(try permissions(at: archive), 0o600)
        XCTAssertEqual(try permissions(at: lock), 0o600)
        XCTAssertEqual(try Data(contentsOf: archive), data,
                       "The privacy migration is metadata-only")
    }

    func testIndeterminateCommitLeavesNoPromotableRecoveryArtifact() throws {
        let directory = try makeCaseDirectory("real-indeterminate")
        let persistence = LiveHistoryPersistence(
            directory: directory,
            hooks: HistoryPersistenceHooks(
                stagingName: { "history.staging.indeterminate" },
                fsync: { descriptor, role in
                    if role == .parentDirectory {
                        errno = EIO
                        return -1
                    }
                    return Darwin.fsync(descriptor)
                }))
        let store = HistoryStore(directory: directory, persistence: persistence)
        let report = try makeSucceededReport(operationID: fixedOperationID)

        let result = store.record(
            module: "renamed-before-parent-fsync",
            report: report,
            date: fixedRecordDate)

        XCTAssertEqual(result, .rejected(code: "history.persistence.durabilityUnknown"))
        XCTAssertEqual(store.archiveState,
                       .degradedReadOnly(code: "history.persistence.durabilityUnknown"))
        XCTAssertEqual(store.recent(1).first?.operationID, fixedOperationID,
                       "The exact post-rename observation remains visible")
        XCTAssertEqual(store.record(module: "blocked", report: report, date: fixedRecordDate),
                       .rejected(code: "history.archive.readOnly"))
        let entries = Set(try FileManager.default.contentsOfDirectory(atPath: directory.path))
        XCTAssertEqual(entries, ["history.json", "history.lock"])
        XCTAssertFalse(entries.contains { $0.contains("staging") || $0.contains("recovery") })
        let fresh = HistoryStore(directory: directory)
        XCTAssertEqual(fresh.archiveState, .writable)
        XCTAssertEqual(fresh.recent(1).first?.operationID, fixedOperationID)
    }

    func testArchiveLockAndStagingRejectSymlinkOrNonRegularTargets() throws {
        let sentinel = tmpDir.appendingPathComponent("unsafe-entry-sentinel")
        let sentinelData = try archiveData([
            legacyRecordObject(module: "valid-writable-sentinel", reclaimedBytes: 9)
        ])
        try sentinelData.write(to: sentinel)
        try setPermissions(0o644, at: sentinel)

        for (name, entryName, makeEntry) in [
            ("archive-symlink", "history.json", true),
            ("lock-symlink", "history.lock", true),
            ("archive-directory", "history.json", false),
            ("lock-directory", "history.lock", false)
        ] {
            let directory = try makeCaseDirectory(name)
            let entry = directory.appendingPathComponent(entryName)
            if makeEntry {
                try FileManager.default.createSymbolicLink(at: entry, withDestinationURL: sentinel)
            } else {
                try FileManager.default.createDirectory(at: entry, withIntermediateDirectories: false)
            }
            let store = HistoryStore(
                directory: directory,
                persistence: LiveHistoryPersistence(directory: directory))

            assertDegraded(store)
            XCTAssertNil(store.record(module: "blocked", reclaimedBytes: 1, removedCount: 1))
            XCTAssertEqual(try Data(contentsOf: sentinel), sentinelData)
            XCTAssertEqual(try permissions(at: sentinel), 0o644,
                           "No-follow rejection must not chmod the symlink target")
            var entryInfo = stat()
            XCTAssertEqual(entry.path.withCString { lstat($0, &entryInfo) }, 0)
            if makeEntry {
                XCTAssertEqual(entryInfo.st_mode & S_IFMT, S_IFLNK)
            } else {
                XCTAssertEqual(entryInfo.st_mode & S_IFMT, S_IFDIR)
            }
        }

        for (name, entryKind) in [
            ("staging-symlink", "symlink"),
            ("staging-directory", "directory"),
            ("staging-regular", "regular")
        ] {
            let directory = try makeCaseDirectory(name)
            let stagingName = "history.staging.fixed"
            let staging = directory.appendingPathComponent(stagingName)
            if entryKind == "symlink" {
                try FileManager.default.createSymbolicLink(at: staging, withDestinationURL: sentinel)
            } else if entryKind == "directory" {
                try FileManager.default.createDirectory(
                    at: staging, withIntermediateDirectories: false)
            } else {
                try sentinelData.write(to: staging)
            }
            let persistence = LiveHistoryPersistence(
                directory: directory,
                hooks: HistoryPersistenceHooks(stagingName: { stagingName }))
            let store = HistoryStore(directory: directory, persistence: persistence)
            XCTAssertEqual(store.archiveState, .writable)

            let result = store.record(
                module: "blocked-staging",
                report: try makeSucceededReport(),
                date: fixedRecordDate)

            guard case .rejected = result else {
                XCTFail("Unsafe staging collision must reject, got \(result)")
                continue
            }
            assertDegraded(store)
            XCTAssertEqual(try Data(contentsOf: sentinel), sentinelData)
            var stagingInfo = stat()
            XCTAssertEqual(staging.path.withCString { lstat($0, &stagingInfo) }, 0)
            let expectedType = entryKind == "symlink"
                ? S_IFLNK
                : (entryKind == "directory" ? S_IFDIR : S_IFREG)
            XCTAssertEqual(stagingInfo.st_mode & S_IFMT, expectedType)
            if entryKind != "directory" {
                XCTAssertEqual(try Data(contentsOf: staging), sentinelData,
                               "A colliding staging entry is never truncated or removed")
            }
            XCTAssertFalse(FileManager.default.fileExists(
                atPath: directory.appendingPathComponent("history.json").path))
        }
    }

    func testReceiptPathsAppearOnlyInProtectedReceiptFields() throws {
        let receipt = RestorableItem(
            originalURL: URL(fileURLWithPath: "/tmp/receipt-secret-original-93D14A"),
            trashedURL: URL(fileURLWithPath: "/tmp/receipt-secret-trash-93D14A"))
        let persistence = ScriptedHistoryPersistence()
        let store = HistoryStore(directory: tmpDir, persistence: persistence)

        _ = try insertedRecordID(store.record(
            module: "receipt-path-scope",
            report: makeReportWithReceipts(
                operationID: fixedOperationID, receipts: [receipt]),
            date: fixedRecordDate))

        let payload = try XCTUnwrap(persistence.committedPayloads.last)
        let root = try JSONSerialization.jsonObject(with: payload)
        let leaves = jsonStringLeaves(root)
        XCTAssertEqual(leaves.filter { $0.value == receipt.originalURL.absoluteString }.map(\.path),
                       ["$[0].items[0].receipt.originalURL"])
        XCTAssertEqual(leaves.filter { $0.value == receipt.trashedURL.absoluteString }.map(\.path),
                       ["$[0].items[0].receipt.trashedURL"])
        let records = try XCTUnwrap(root as? [[String: Any]])
        XCTAssertNil(records[0]["restorable"],
                     "Schema 1 must not duplicate receipts in a legacy top-level field")
        let URLLikeLeaves = leaves.filter {
            $0.value.contains("file://") || $0.value.hasPrefix("/tmp/")
        }
        XCTAssertEqual(Set(URLLikeLeaves.map(\.path)), [
            "$[0].items[0].receipt.originalURL",
            "$[0].items[0].receipt.trashedURL"
        ], "Every URL-like persisted string must be structurally allowlisted")
        XCTAssertTrue(jsonKeys(root).isDisjoint(with: [
            "path", "sourcePath", "sourceURL", "debugPath"
        ]))
    }

    func testPermanentAndOrdinaryMetadataPersistNoPaths() throws {
        let permanentSource = URL(fileURLWithPath: "/tmp/private-permanent-source-7F2A")
        let ordinarySource = URL(fileURLWithPath: "/tmp/private-ordinary-source-7F2A")
        let permanentItemID = UUID()
        let ordinaryItemID = UUID()
        let receipt = RestorableItem(
            originalURL: URL(fileURLWithPath: "/tmp/canonical-receipt-original-7F2A"),
            trashedURL: URL(fileURLWithPath: "/tmp/canonical-receipt-trash-7F2A"))
        let report = try makeReport(
            operationID: fixedOperationID,
            specs: [
                ReportItemSpec(requestID: UUID(),
                               itemID: permanentItemID,
                               url: permanentSource,
                               intent: .permanent,
                               disposition: .succeeded,
                               mutation: .changed,
                               affectedBytes: 4,
                               receipt: nil),
                ReportItemSpec(requestID: UUID(),
                               itemID: ordinaryItemID,
                               url: ordinarySource,
                               intent: .trash,
                               disposition: .succeeded,
                               mutation: .changed,
                               affectedBytes: 6,
                               receipt: receipt)
            ],
            cancellationAccepted: false)
        let persistence = ScriptedHistoryPersistence()
        let store = HistoryStore(directory: tmpDir, persistence: persistence)

        _ = try insertedRecordID(store.record(
            module: "metadata-path-scope", report: report, date: fixedRecordDate))

        let payload = try XCTUnwrap(persistence.committedPayloads.last)
        let root = try JSONSerialization.jsonObject(with: payload)
        let leaves = jsonStringLeaves(root)
        let persistedStrings = Set(leaves.map(\.value))
        for forbidden in [
            permanentSource.absoluteString, permanentSource.path,
            ordinarySource.absoluteString, ordinarySource.path,
            permanentItemID.uuidString, ordinaryItemID.uuidString
        ] {
            XCTAssertFalse(persistedStrings.contains(forbidden),
                           "Ordinary item metadata must not persist source paths or item IDs")
            XCTAssertFalse(leaves.contains { $0.value.contains(forbidden) },
                           "Sensitive metadata must not survive inside a larger debug string")
        }
        let keys = jsonKeys(root)
        XCTAssertTrue(keys.isDisjoint(with: [
            "url", "path", "sourcePath", "sourceURL", "debugPath", "itemID"
        ]))
        XCTAssertTrue(persistedStrings.contains(receipt.originalURL.absoluteString))
        XCTAssertTrue(persistedStrings.contains(receipt.trashedURL.absoluteString))
    }

    func testSensitivePathBearingIssueMetadataIsRejectedBeforePersistence() throws {
        let failedRequestID = UUID()
        let sensitiveToken = "/tmp/issue-private-source-4C3E"
        let issue = OperationIssue(
            code: "history.io.failure:\(sensitiveToken)",
            category: .io,
            subjectID: failedRequestID.uuidString,
            recovery: .retry,
            retryable: true)
        let report = try makeReport(
            operationID: fixedOperationID,
            specs: [
                ReportItemSpec(requestID: UUID(),
                               itemID: UUID(),
                               url: URL(fileURLWithPath: "/tmp/issue-success-source"),
                               intent: .permanent,
                               disposition: .succeeded,
                               mutation: .changed,
                               affectedBytes: 1,
                               receipt: nil),
                ReportItemSpec(requestID: failedRequestID,
                               itemID: UUID(),
                               url: URL(fileURLWithPath: sensitiveToken),
                               intent: .trash,
                               disposition: .failed(issue),
                               mutation: .none,
                               affectedBytes: 0,
                               receipt: nil)
            ],
            cancellationAccepted: false)
        let persistence = ScriptedHistoryPersistence()
        let store = HistoryStore(directory: tmpDir, persistence: persistence)

        XCTAssertEqual(store.record(
            module: "privacy-issue", report: report, date: fixedRecordDate),
                       .rejected(code: "history.privacy.pathMetadata"))
        XCTAssertEqual(persistence.commitCount, 0)
        XCTAssertTrue(store.recent(10).isEmpty)
        XCTAssertNil(persistence.loadedData)
    }

    func testPathBearingModuleAndKindMetadataFailClosedAcrossRawAndTypedInputs() throws {
        let rawCases: [[String: Any]] = [
            legacyRecordObject(module: "/Applications/Private.app"),
            v1RecordObject(module: "source:/Volumes/External/secret"),
            v1RecordObject(kind: "file:%2F%2F%2FLibrary/Application%20Support/secret"),
            v1RecordObject(module: "source,/Volumes/External/secret"),
            v1RecordObject(module: "%ZZ%2FUsers%2Falice%2Fsecret"),
            v1RecordObject(module: "source: / Users/alice/secret"),
            v1RecordObject(module: "source-/Users/alice/secret"),
            v1RecordObject(module: "source_/Users/alice/secret"),
            v1RecordObject(module: "source./Users/alice/secret"),
            v1RecordObject(module: "~alice/Library/secret"),
            v1RecordObject(
                kind: "file%25253A%25252F%25252F%25252FLibrary/secret")
        ]
        for (index, raw) in rawCases.enumerated() {
            let data = try archiveData([raw])
            let (store, url) = try loadCase(data, name: "privacy-raw-\(index)")
            assertDegraded(store)
            XCTAssertEqual(store.totalSuccessfulCleanups, 0)
            XCTAssertEqual(store.totalReclaimedAllTime, 0)
            XCTAssertNil(store.record(module: "blocked", reclaimedBytes: 1, removedCount: 1))
            XCTAssertEqual(try Data(contentsOf: url), data)
        }

        let requestID = UUID()
        let specs = [ReportItemSpec(
            requestID: requestID,
            itemID: UUID(),
            url: URL(fileURLWithPath: "/tmp/privacy-typed-source"),
            intent: .permanent,
            disposition: .succeeded,
            mutation: .changed,
            affectedBytes: 1,
            receipt: nil)]
        for (index, entry) in [
            (module: "/var/private-module", kind: "cleaning.execute"),
            (module: "safe-module", kind: "source:/Applications/Private.app"),
            (module: "safe-module", kind: "file:%2F%2F%2FVolumes/Private"),
            (module: "safe-module", kind: "source;/Volumes/Private"),
            (module: "%ZZ%2FUsers%2Falice%2Fsecret", kind: "cleaning.execute"),
            (module: "source: / Users/alice/secret", kind: "cleaning.execute"),
            (module: "source-/Users/alice/secret", kind: "cleaning.execute"),
            (module: "source_/Users/alice/secret", kind: "cleaning.execute"),
            (module: "source./Users/alice/secret", kind: "cleaning.execute"),
            (module: "~alice/Library/secret", kind: "cleaning.execute"),
            (module: "safe-module",
             kind: "file%25253A%25252F%25252F%25252FApplications/Private.app")
        ].enumerated() {
            let persistence = ScriptedHistoryPersistence()
            let store = HistoryStore(directory: tmpDir, persistence: persistence)
            let report = try makeReport(
                operationID: UUID(),
                kind: OperationKind(entry.kind),
                specs: specs,
                cancellationAccepted: false)
            XCTAssertEqual(store.record(
                module: entry.module, report: report, date: fixedRecordDate),
                           .rejected(code: "history.privacy.pathMetadata"), "case \(index)")
            XCTAssertEqual(persistence.commitCount, 0, "case \(index)")
            XCTAssertTrue(store.recent(10).isEmpty, "case \(index)")
        }

        for (index, module) in [
            "%ZZ%2FUsers%2Falice%2Fsecret",
            "source: / Users/alice/secret",
            "source-/Users/alice/secret",
            "source_/Users/alice/secret",
            "source./Users/alice/secret",
            "~alice/Library/secret"
        ].enumerated() {
            let persistence = ScriptedHistoryPersistence()
            let store = HistoryStore(directory: tmpDir, persistence: persistence)
            XCTAssertNil(store.record(
                module: module,
                reclaimedBytes: 1,
                removedCount: 1,
                date: fixedRecordDate), "scalar case \(index)")
            XCTAssertEqual(persistence.commitCount, 0, "scalar case \(index)")
            XCTAssertTrue(store.recent(10).isEmpty, "scalar case \(index)")
        }

        let fallbackData = try archiveData([
            legacyRecordObject(module: "/Users/alice/private-history")
        ])
        let (fallbackStore, _) = try loadCase(
            fallbackData,
            name: "privacy-path-module-fallback")
        assertDegraded(fallbackStore)
        XCTAssertTrue(
            fallbackStore.recent(10).isEmpty,
            "A path-bearing raw module must not be exposed through the degraded read model")

        let safeRawData = try archiveData([
            legacyRecordObject(
                module: "Profile File: Backup · CPU / Memory",
                reclaimedBytes: 5,
                removedCount: 1)
        ])
        let (safeRawStore, _) = try loadCase(safeRawData, name: "privacy-safe-file-label")
        XCTAssertEqual(safeRawStore.archiveState, .writable)
        XCTAssertEqual(safeRawStore.totalReclaimedAllTime, 5)

        let safePersistence = ScriptedHistoryPersistence()
        let safeStore = HistoryStore(directory: tmpDir, persistence: safePersistence)
        let safeReport = try makeReport(
            operationID: UUID(),
            kind: .cleaningExecute,
            specs: specs,
            cancellationAccepted: false)
        _ = try insertedRecordID(safeStore.record(
            module: "Profile File: Backup · CPU / Memory",
            report: safeReport,
            date: fixedRecordDate))
        XCTAssertEqual(safePersistence.commitCount, 1)
    }

    func testNonFileReceiptsAreRejectedBeforeAnyScalarOrTypedCommit() throws {
        let invalidReceipt = RestorableItem(
            originalURL: try XCTUnwrap(URL(string: "https://example.invalid/original")),
            trashedURL: URL(fileURLWithPath: "/tmp/non-file-receipt-trash"))
        let liveDirectory = try makeCaseDirectory("non-file-scalar-receipt")
        let liveStore = HistoryStore(directory: liveDirectory)

        XCTAssertNil(liveStore.record(
            module: "invalid-scalar-receipt",
            reclaimedBytes: 1,
            removedCount: 1,
            restorable: [invalidReceipt],
            date: fixedRecordDate))
        XCTAssertTrue(liveStore.recent(10).isEmpty)
        let fresh = HistoryStore(directory: liveDirectory)
        XCTAssertEqual(fresh.archiveState, .writable)
        XCTAssertTrue(fresh.recent(10).isEmpty)

        let typedPersistence = ScriptedHistoryPersistence()
        let typedStore = HistoryStore(directory: tmpDir, persistence: typedPersistence)
        let report = try makeSucceededReport(
            operationID: fixedOperationID,
            receipt: invalidReceipt)
        XCTAssertEqual(typedStore.record(
            module: "invalid-typed-receipt", report: report, date: fixedRecordDate),
                       .rejected(code: "history.receipt.invalidBinding"))
        XCTAssertEqual(typedPersistence.commitCount, 0)
        XCTAssertTrue(typedStore.recent(10).isEmpty)
    }

    func testReceiptURLsRequireAbsoluteLocalUnadornedFileLocations() throws {
        let invalidValues = [
            "file:relative",
            "file:%2F%2F%2Ftmp/encoded-root",
            "file://remote.example/tmp/remote-item",
            "file:///tmp/query-item?token=secret",
            "file:///tmp/fragment-item#secret"
        ]
        for (index, invalidValue) in invalidValues.enumerated() {
            let invalidURL = try XCTUnwrap(URL(string: invalidValue))
            XCTAssertTrue(invalidURL.isFileURL,
                          "Fixture must exercise a value Foundation calls a file URL")
            let rawReceipt = receiptObject(
                original: invalidValue,
                trashed: "file:///tmp/valid-trash-\(index)")
            let rawCases: [[String: Any]] = [
                legacyRecordObject(
                    module: "invalid-receipt-schema0-\(index)",
                    reclaimedBytes: 7,
                    removedCount: 1,
                    restorable: [rawReceipt]),
                v1RecordObject(
                    module: "invalid-receipt-schema1-\(index)",
                    items: [succeededItemObject(receipt: rawReceipt)])
            ]
            for (schemaIndex, raw) in rawCases.enumerated() {
                let data = try archiveData([raw])
                let (store, url) = try loadCase(
                    data, name: "invalid-receipt-\(index)-\(schemaIndex)")
                assertDegraded(store)
                XCTAssertEqual(store.totalSuccessfulCleanups, 0)
                XCTAssertEqual(store.totalReclaimedAllTime, 0)
                XCTAssertNil(store.record(
                    module: "blocked", reclaimedBytes: 1, removedCount: 1))
                XCTAssertEqual(try Data(contentsOf: url), data)
            }

            let receipt = RestorableItem(
                originalURL: invalidURL,
                trashedURL: URL(fileURLWithPath: "/tmp/valid-write-trash-\(index)"))
            let scalarPersistence = ScriptedHistoryPersistence()
            let scalarStore = HistoryStore(directory: tmpDir, persistence: scalarPersistence)
            XCTAssertNil(scalarStore.record(
                module: "invalid-scalar-receipt-\(index)",
                reclaimedBytes: 1,
                removedCount: 1,
                restorable: [receipt],
                date: fixedRecordDate))
            XCTAssertEqual(scalarPersistence.commitCount, 0)

            let typedPersistence = ScriptedHistoryPersistence()
            let typedStore = HistoryStore(directory: tmpDir, persistence: typedPersistence)
            let report = try makeSucceededReport(operationID: UUID(), receipt: receipt)
            XCTAssertEqual(typedStore.record(
                module: "invalid-typed-receipt-\(index)",
                report: report,
                date: fixedRecordDate),
                           .rejected(code: "history.receipt.invalidBinding"))
            XCTAssertEqual(typedPersistence.commitCount, 0)
        }

        let localhostReceipt = RestorableItem(
            originalURL: try XCTUnwrap(URL(string: "file://localhost/tmp/local-original")),
            trashedURL: try XCTUnwrap(URL(string: "file://localhost/tmp/local-trash")))
        let validPersistence = ScriptedHistoryPersistence()
        let validStore = HistoryStore(directory: tmpDir, persistence: validPersistence)
        XCTAssertNotNil(validStore.record(
            module: "localhost-receipt",
            reclaimedBytes: 1,
            removedCount: 1,
            restorable: [localhostReceipt],
            date: fixedRecordDate))
        let fresh = HistoryStore(directory: tmpDir, persistence: validPersistence)
        XCTAssertEqual(fresh.archiveState, .writable)
        XCTAssertEqual(fresh.recent(1).first?.restorable, [localhostReceipt])
    }

    func testNormalImportClientCanUseOnlyPublicHistoryReadAndResultAPIs() throws {
        let result = try compileInfrastructureExternalClient("""
        import Foundation
        import Domain
        import Infrastructure

        func consume(store: HistoryStore,
                     report: CleaningReport,
                     shredder: OperationResult<ShredderPayload>,
                     record: CleaningRecord,
                     fact: HistoryItemFact,
                     receipt: RestorableItem) {
            let scalarID: UUID? = store.record(
                module: "external-scalar",
                reclaimedBytes: 1,
                removedCount: 1)
            let typedResult: HistoryRecordResult = store.record(
                module: "external-typed", report: report)
            let writer: any OutcomeHistoryWriting = store
            let shredResult: HistoryRecordResult = writer.record(
                module: "external-shred", result: shredder, date: Date())
            let writerRemoveResult: HistoryUpdateResult = writer.remove(id: UUID())
            let writerUpdateResult: HistoryUpdateResult = writer.updateRestorable(
                id: UUID(), to: [receipt])
            let removeResult: HistoryUpdateResult = store.remove(id: UUID())
            let updateResult: HistoryUpdateResult = store.updateRestorable(
                id: UUID(), to: [receipt])
            let clearReceiptResult: HistoryUpdateResult = store.clearRestorable(id: UUID())
            let clearResult: HistoryUpdateResult = store.clear()
            let reloadResult: HistoryReloadResult = store.reload()
            _ = scalarID
            _ = typedResult
            _ = shredResult
            _ = writerRemoveResult
            _ = writerUpdateResult
            _ = removeResult
            _ = updateResult
            _ = clearReceiptResult
            _ = clearResult
            _ = reloadResult
            _ = store.recent(10)
            _ = store.firstUndoable(existsInTrash: { _ in false })
            _ = store.totalHistoryRecords
            _ = store.totalSuccessfulCleanups
            _ = store.totalReclaimedAllTime
            _ = store.totalCleanups
            _ = record.id
            _ = record.date
            _ = record.module
            _ = record.reclaimedBytes
            _ = record.removedCount
            _ = record.restorable
            _ = record.canUndo
            _ = record.schemaVersion
            _ = record.operationID
            _ = record.parentOperationID
            _ = record.operationKind
            _ = record.outcomeStatus
            _ = record.mutation
            _ = record.counts
            _ = record.itemFacts
            _ = record.operationFacts
            if let operationFact = record.operationFacts.first {
                _ = operationFact.requestID
                _ = operationFact.role
                _ = operationFact.relatedCleaningRequestID
                _ = operationFact.intent
                _ = operationFact.disposition
                _ = operationFact.mutation
                _ = operationFact.affectedBytes
                _ = operationFact.receipt
            }
            _ = fact.requestID
            _ = fact.intent
            _ = fact.disposition
            _ = fact.mutation
            _ = fact.affectedBytes
            _ = fact.receipt
            _ = shredder.payload.items
            _ = shredder.payload.freedBytes
            _ = shredder.payload.items.first?.requestID
            _ = shredder.payload.items.first?.url
            _ = shredder.payload.items.first?.disposition
            _ = shredder.payload.items.first?.mutation
            _ = shredder.payload.items.first?.freedBytes
        }
        """, warningsAsErrors: true)

        XCTAssertEqual(result.status, 0, result.diagnostics)
        assertNoInfrastructureModuleLoadFailure(result)
    }

    func testNormalImportClientCannotForgeHistoryRecordsFactsDTOsOrPersistence() throws {
        let nonconformance = ["requires that", "conform to", "does not conform"]
        let inaccessibleOrUnavailable = [
            "inaccessible", "internal protection level", "cannot find", "not found",
            "no exact matches", "extra argument", "missing argument"
        ]
        let notFound = [
            "cannot find", "not found", "has no member", "no exact matches"
        ]
        let genericInsertUnavailable = [
            "inaccessible", "internal protection level", "cannot find", "not found",
            "has no member"
        ]
        let forbiddenClients: [(String, String, [String], String)] = [
            ("record-encodable", "CleaningRecord", nonconformance, """
             import Foundation
             import Infrastructure
             func requireEncodable<T: Encodable>(_ type: T.Type) {}
             requireEncodable(CleaningRecord.self)
             """),
            ("record-decodable", "CleaningRecord", nonconformance, """
             import Foundation
             import Infrastructure
             func requireDecodable<T: Decodable>(_ type: T.Type) {}
             requireDecodable(CleaningRecord.self)
             """),
            ("fact-decodable", "HistoryItemFact", nonconformance, """
             import Foundation
             import Infrastructure
             func requireDecodable<T: Decodable>(_ type: T.Type) {}
             requireDecodable(HistoryItemFact.self)
             """),
            ("operation-fact-decodable", "HistoryOperationFact", nonconformance, """
             import Foundation
             import Infrastructure
             func requireDecodable<T: Decodable>(_ type: T.Type) {}
             requireDecodable(HistoryOperationFact.self)
             """),
            ("record-init", "CleaningRecord", inaccessibleOrUnavailable, """
             import Foundation
             import Infrastructure
             _ = CleaningRecord(id: UUID(), date: Date(), module: "forged",
                                reclaimedBytes: 1, removedCount: 1, restorable: [])
             """),
            ("record-full-facts-init", "CleaningRecord", inaccessibleOrUnavailable, """
             import Foundation
             import Domain
             import Infrastructure
             _ = CleaningRecord(
                 id: UUID(), date: Date(), module: "forged",
                 reclaimedBytes: 1, removedCount: 1, restorable: [],
                 schemaVersion: 1, operationID: UUID(), parentOperationID: nil,
                 operationKind: OperationKind("forged"), outcomeStatus: .success,
                 mutation: .changed,
                 counts: OperationCounts(requested: 0, succeeded: 0, unchanged: 0,
                                         skipped: 0, failed: 0, cancelled: 0),
                 itemFacts: [])
             """),
            ("fact-init", "HistoryItemFact", inaccessibleOrUnavailable, """
             import Foundation
             import Domain
             import Infrastructure
             _ = HistoryItemFact(requestID: UUID(), intent: .trash,
                                 disposition: .succeeded, mutation: .changed,
                                 affectedBytes: 1, receipt: nil)
             """),
            ("operation-fact-init", "HistoryOperationFact", inaccessibleOrUnavailable, """
             import Foundation
             import Domain
             import Infrastructure
             _ = HistoryOperationFact(
                 requestID: UUID(), role: .deletion,
                 relatedCleaningRequestID: nil, intent: .trash,
                 disposition: .succeeded, mutation: .changed,
                 affectedBytes: 1, receipt: nil)
             """),
            ("shred-item-init", "ShredderItemResult", inaccessibleOrUnavailable, """
             import Foundation
             import Domain
             import Infrastructure
             _ = ShredderItemResult(requestID: UUID(),
                                     url: URL(fileURLWithPath: "/tmp/forged"),
                                     disposition: .succeeded,
                                     mutation: .changed,
                                     freedBytes: 1)
             """),
            ("shred-payload-init", "ShredderPayload", inaccessibleOrUnavailable, """
             import Infrastructure
             _ = ShredderPayload(items: [])
             """),
            ("operation-dto", "HistoryOperationDTO", notFound, """
             import Infrastructure
             _ = HistoryOperationDTO.self
             """),
            ("item-dto", "HistoryItemFactDTO", notFound, """
             import Infrastructure
             _ = HistoryItemFactDTO.self
             """),
            ("candidate", "ValidatedHistoryRecordCandidate", notFound, """
             import Infrastructure
             _ = ValidatedHistoryRecordCandidate.self
             """),
            ("generic-insert", "insert", genericInsertUnavailable, """
             import Infrastructure
             func forge(store: HistoryStore, record: CleaningRecord) {
                 store.insert(record)
             }
             """),
            ("persistence-protocol", "HistoryPersistence", notFound, """
             import Infrastructure
             _ = HistoryPersistence.self
             """),
            ("persistence-hooks", "HistoryPersistenceHooks", notFound, """
             import Infrastructure
             _ = HistoryPersistenceHooks.self
             """),
            ("store-hooks", "HistoryStoreHooks", notFound, """
             import Infrastructure
             _ = HistoryStoreHooks.self
             """),
            ("transaction-kind", "HistoryStoreTransactionKind", notFound, """
             import Infrastructure
             _ = HistoryStoreTransactionKind.self
             """),
            ("transaction-registry", "HistoryStoreTransactionRegistry", notFound, """
             import Infrastructure
             _ = HistoryStoreTransactionRegistry.self
             """)
        ]

        for (label, expectedDiagnostic, failureFragments, source) in forbiddenClients {
            let result = try compileInfrastructureExternalClient(
                source, warningsAsErrors: false)
            XCTAssertNotEqual(result.status, 0, label)
            XCTAssertTrue(result.standardError.contains(expectedDiagnostic),
                          "\(label): \(result.diagnostics)")
            let normalizedDiagnostics = result.standardError.lowercased()
            XCTAssertTrue(failureFragments.contains {
                normalizedDiagnostics.contains($0)
            }, "\(label) failed for an unrelated reason: \(result.diagnostics)")
            assertNoInfrastructureModuleLoadFailure(result)
        }
    }

    func testReloadRecoversDurabilityUnknownOnlyAfterValidatedLoad() throws {
        let persistence = ScriptedHistoryPersistence(
            commitActions: [
                .indeterminateUsingCandidate(code: "history.persistence.parentFsyncFailed")
            ])
        let store = HistoryStore(directory: tmpDir, persistence: persistence)
        let report = try makeSucceededReport(operationID: fixedOperationID)

        XCTAssertEqual(store.record(
            module: "durability-candidate", report: report, date: fixedRecordDate),
                       .rejected(code: "history.persistence.durabilityUnknown"))
        let prior = try XCTUnwrap(store.recent(1).first)
        let validData = try XCTUnwrap(persistence.committedPayloads.last)
        XCTAssertEqual(store.archiveState,
                       .degradedReadOnly(code: "history.persistence.durabilityUnknown"))

        persistence.replaceLoadResult(.failed(code: "history.persistence.reloadDenied"))
        XCTAssertEqual(store.reload(),
                       .degraded(code: "history.persistence.reloadDenied"))
        XCTAssertEqual(store.recent(1).first, prior)

        let corruptData = Data("not-json".utf8)
        persistence.replaceLoadResult(.loaded(HistoryPersistenceSnapshot(
            data: corruptData,
            revision: .sha256(Data(SHA256.hash(data: corruptData))))))
        guard case .degraded = store.reload() else {
            return XCTFail("A corrupt observation cannot clear durability-unknown degradation")
        }
        XCTAssertEqual(store.recent(1).first, prior)
        assertDegraded(store)

        var futureSchema = legacyRecordObject(module: "reload-future-schema")
        futureSchema["schemaVersion"] = 3
        var futureStatus = v1RecordObject(module: "reload-future-status")
        futureStatus = changingOperation(futureStatus) {
            $0["status"] = "futureStatus"
        }
        var unknownKey = v1RecordObject(module: "reload-unknown-key")
        unknownKey["futureRoot"] = true
        let oversizedArchive = paddedJSON(
            try archiveData([]),
            byteCount: HistoryArchiveLimits.maximumArchiveBytes + 1)
        let oversizedFacts = try archiveData([v1RecordObject(
            module: "reload-oversized-facts",
            items: (0...HistoryArchiveLimits.maximumItemFactsPerRecord).map { _ in
                succeededItemObject(affectedBytes: 0)
            },
            reclaimedBytes: 0,
            removedCount: HistoryArchiveLimits.maximumItemFactsPerRecord + 1)])
        XCTAssertLessThanOrEqual(oversizedFacts.count,
                                 HistoryArchiveLimits.maximumArchiveBytes)
        let invalidObservations = [
            try archiveData([futureSchema]),
            try archiveData([futureStatus]),
            try archiveData([unknownKey]),
            oversizedArchive,
            oversizedFacts
        ]
        for (index, invalidData) in invalidObservations.enumerated() {
            persistence.replaceLoadResult(loadedResult(invalidData))
            guard case .degraded = store.reload() else {
                XCTFail("Invalid reload observation \(index) cannot restore writability")
                continue
            }
            XCTAssertEqual(store.recent(1).first, prior)
            assertDegraded(store)
            XCTAssertEqual(persistence.commitCount, 1,
                           "Invalid reloads are read-only")
        }

        persistence.replaceLoadResult(.loaded(HistoryPersistenceSnapshot(
            data: validData,
            revision: .sha256(Data(SHA256.hash(data: validData))))))
        XCTAssertEqual(store.reload(), .writable)
        XCTAssertEqual(store.archiveState, .writable)
        XCTAssertEqual(store.recent(1).first, prior)

        let postRecoveryReport = try makeSucceededReport(operationID: UUID())
        _ = try insertedRecordID(store.record(
            module: "post-reload-mutation",
            report: postRecoveryReport,
            date: fixedRecordDate.addingTimeInterval(1)))
        XCTAssertEqual(store.totalHistoryRecords, 2)
        XCTAssertEqual(store.recent(1).first?.operationID, postRecoveryReport.operation.id)
        XCTAssertEqual(persistence.commitCount, 2)

        persistence.replaceLoadResult(.missing)
        XCTAssertEqual(store.reload(), .writable)
        XCTAssertEqual(store.archiveState, .writable)
        XCTAssertTrue(store.recent(10).isEmpty)
        XCTAssertEqual(persistence.commitCount, 2, "Reload itself is strictly read-only")
    }

    func testReloadAndMutationShareOneTransactionMutex() throws {
        let persistence = BlockingHistoryPersistence(initial: .missing)
        let mutationContended = DispatchSemaphore(value: 0)
        let observedKinds = LockedValueBox<[HistoryStoreTransactionKind]>([])
        let store = HistoryStore(
            directory: tmpDir,
            persistence: persistence,
            hooks: HistoryStoreHooks(didObserveTransactionContention: { kind in
                observedKinds.withValue { $0.append(kind) }
                if kind == .record { mutationContended.signal() }
            }))
        persistence.blockNextLoad(returning: .missing)
        let report = try makeSucceededReport(operationID: fixedOperationID)
        let date = fixedRecordDate
        let reloadResult = LockedValueBox<HistoryReloadResult?>(nil)
        let mutationResult = LockedValueBox<HistoryRecordResult?>(nil)
        let reloadFinished = DispatchSemaphore(value: 0)
        let mutationFinished = DispatchSemaphore(value: 0)

        DispatchQueue.global(qos: .userInitiated).async {
            reloadResult.set(store.reload())
            reloadFinished.signal()
        }
        XCTAssertEqual(persistence.loadEntered.wait(timeout: .now() + 5), .success)

        DispatchQueue.global(qos: .userInitiated).async {
            mutationResult.set(store.record(
                module: "mutex-mutation", report: report, date: date))
            mutationFinished.signal()
        }
        XCTAssertEqual(mutationContended.wait(timeout: .now() + 5), .success,
                       "The record path must positively report observing reload's held mutex")
        XCTAssertEqual(observedKinds.value, [.record])

        persistence.allowLoad.signal()
        XCTAssertEqual(reloadFinished.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(mutationFinished.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(persistence.commitEntered.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(reloadResult.value, .writable)
        _ = try insertedRecordID(try XCTUnwrap(mutationResult.value))
        XCTAssertEqual(persistence.events,
                       [.loadEntered, .loadReleased, .commitEntered])
        XCTAssertEqual(persistence.commitCount, 1)
        XCTAssertEqual(store.recent(1).first?.operationID, fixedOperationID)
        XCTAssertEqual(store.totalHistoryRecords, 1,
                       "Reload completion must not overwrite the later committed mutation")
    }

    func testFirstUndoablePruningFailureReturnsNoTransientCandidate() throws {
        let alive = RestorableItem(
            originalURL: URL(fileURLWithPath: "/tmp/prune-failure-alive"),
            trashedURL: URL(fileURLWithPath: "/tmp/prune-failure-trash/alive"))
        let missing = RestorableItem(
            originalURL: URL(fileURLWithPath: "/tmp/prune-failure-missing"),
            trashedURL: URL(fileURLWithPath: "/tmp/prune-failure-trash/missing"))
        func makeScenario() throws -> (
            store: HistoryStore,
            persistence: ScriptedHistoryPersistence,
            before: CleaningRecord,
            data: Data
        ) {
            let persistence = ScriptedHistoryPersistence()
            let store = HistoryStore(directory: tmpDir, persistence: persistence)
            _ = try insertedRecordID(store.record(
                module: "prune-failure",
                report: makeReportWithReceipts(
                    operationID: fixedOperationID, receipts: [alive, missing]),
                date: fixedRecordDate))
            return (store,
                    persistence,
                    try XCTUnwrap(store.recent(1).first),
                    try XCTUnwrap(persistence.committedPayloads.last))
        }

        do {
            let scenario = try makeScenario()
            scenario.persistence.replaceCommitActions([
                .failed(code: "history.persistence.pruneWriteFailed")
            ])

            XCTAssertNil(scenario.store.firstUndoable(
                existsInTrash: { $0 == alive.trashedURL }))
            XCTAssertEqual(scenario.store.recent(1).first, scenario.before)
            XCTAssertEqual(scenario.store.recent(1).first?.restorable, [alive, missing])
            XCTAssertEqual(scenario.persistence.commitCount, 2)
            XCTAssertEqual(scenario.persistence.loadedData, scenario.data)
            let fresh = try XCTUnwrap(HistoryStore(
                directory: tmpDir,
                persistence: scenario.persistence).recent(1).first)
            XCTAssertEqual(fresh, scenario.before)
        }

        do {
            let scenario = try makeScenario()
            var conflicts: [ScriptedHistoryPersistence.CommitAction] = []
            for attempt in 1...8 {
                let latestData = try appendingLegacyRecords(
                    to: scenario.data,
                    count: attempt,
                    prefix: "prune-conflict-exhausted")
                conflicts.append(.conflict(latest: loadedResult(latestData)))
            }
            scenario.persistence.replaceCommitActions(conflicts)

            XCTAssertNil(scenario.store.firstUndoable(
                existsInTrash: { $0 == alive.trashedURL }))
            XCTAssertEqual(scenario.persistence.commitCount, 9,
                           "Insert plus exactly eight prune commit attempts")
            XCTAssertEqual(scenario.store.recent(1).first, scenario.before)
            XCTAssertEqual(scenario.store.recent(1).first?.restorable, [alive, missing])
            let fresh = try XCTUnwrap(HistoryStore(
                directory: tmpDir,
                persistence: scenario.persistence).recent(100).first {
                    $0.operationID == fixedOperationID
                })
            XCTAssertEqual(fresh.restorable, [alive, missing])
            let externalModules = Set(HistoryStore(
                directory: tmpDir,
                persistence: scenario.persistence).recent(100).map(\.module))
            XCTAssertTrue((0..<8).allSatisfy {
                externalModules.contains("prune-conflict-exhausted-\($0)")
            })
        }

        do {
            let scenario = try makeScenario()
            let observedData = try appendingLegacyRecords(
                to: scenario.data, count: 1, prefix: "prune-indeterminate-observed")
            scenario.persistence.replaceCommitActions([
                .indeterminate(
                    latest: loadedResult(observedData),
                    code: "history.persistence.parentFsyncFailed")
            ])

            XCTAssertNil(scenario.store.firstUndoable(
                existsInTrash: { $0 == alive.trashedURL }))
            XCTAssertEqual(scenario.persistence.commitCount, 2)
            XCTAssertEqual(scenario.store.archiveState,
                           .degradedReadOnly(code: "history.persistence.durabilityUnknown"))
            let current = try XCTUnwrap(scenario.store.recent(100).first {
                $0.operationID == fixedOperationID
            })
            XCTAssertEqual(current.restorable, [alive, missing])
            XCTAssertTrue(scenario.store.recent(100).contains {
                $0.module == "prune-indeterminate-observed-0"
            })
            XCTAssertEqual(scenario.store.clear(),
                           .rejected(code: "history.archive.readOnly"))
            XCTAssertEqual(scenario.persistence.commitCount, 2)
            let fresh = try XCTUnwrap(HistoryStore(
                directory: tmpDir,
                persistence: scenario.persistence).recent(100).first {
                    $0.operationID == fixedOperationID
                })
            XCTAssertEqual(fresh.restorable, [alive, missing])
            XCTAssertTrue(HistoryStore(
                directory: tmpDir,
                persistence: scenario.persistence).recent(100).contains {
                    $0.module == "prune-indeterminate-observed-0"
                })
        }

        do {
            let scenario = try makeScenario()
            let latestData = try appendingLegacyRecords(
                to: scenario.data, count: 1, prefix: "prune-conflict-success")
            let existence = ConflictEpochTrashExistence(
                alwaysPresent: alive.trashedURL,
                presentAfterConflict: missing.trashedURL)
            scenario.persistence.onConflictReturned {
                existence.beginPostConflictEpoch()
            }
            scenario.persistence.replaceCommitActions([
                .conflict(latest: loadedResult(latestData)),
                .committed
            ])

            let committed = try XCTUnwrap(scenario.store.firstUndoable(
                existsInTrash: { existence.exists($0) }))
            XCTAssertGreaterThanOrEqual(
                existence.preConflictProbeCount(for: missing.trashedURL),
                1,
                "The initial candidate must observe the pre-conflict filesystem epoch")
            XCTAssertGreaterThanOrEqual(
                existence.postConflictProbeCount(for: missing.trashedURL),
                1,
                "Returning the verified conflict must trigger a fresh existence epoch")
            XCTAssertEqual(committed.restorable, [alive, missing],
                           "The retry must publish newly re-observed receipt facts")
            XCTAssertEqual(scenario.persistence.commitCount, 3,
                           "Insert plus conflict and successful retry")
            let current = try XCTUnwrap(scenario.store.recent(100).first {
                $0.operationID == fixedOperationID
            })
            XCTAssertEqual(current, committed)
            XCTAssertEqual(current.restorable, [alive, missing])
            XCTAssertTrue(scenario.store.recent(100).contains {
                $0.module == "prune-conflict-success-0"
            })
            let freshStore = HistoryStore(
                directory: tmpDir,
                persistence: scenario.persistence)
            let fresh = try XCTUnwrap(freshStore.recent(100).first {
                    $0.operationID == fixedOperationID
                })
            XCTAssertEqual(fresh, committed)
            XCTAssertTrue(freshStore.recent(100).contains {
                $0.module == "prune-conflict-success-0"
            })
            let lastPayload = try XCTUnwrap(scenario.persistence.committedPayloads.last)
            let lastObjects = try XCTUnwrap(
                JSONSerialization.jsonObject(with: lastPayload) as? [[String: Any]])
            XCTAssertTrue(lastObjects.contains {
                $0["module"] as? String == "prune-conflict-success-0"
            })
        }
    }

    func testDuplicateOrConflictingReceiptsAndUnboundIssueSubjectsAreRejected() throws {
        let first = RestorableItem(
            originalURL: URL(fileURLWithPath: "/tmp/invalid-receipt-original"),
            trashedURL: URL(fileURLWithPath: "/tmp/invalid-receipt-trash/first"))
        let changedTrash = RestorableItem(
            originalURL: first.originalURL,
            trashedURL: URL(fileURLWithPath: "/tmp/invalid-receipt-trash/changed"))
        let changedOriginal = RestorableItem(
            originalURL: URL(fileURLWithPath: "/tmp/invalid-receipt-other-original"),
            trashedURL: first.trashedURL)
        let canonicalAlias = RestorableItem(
            originalURL: try XCTUnwrap(URL(string: "file:///tmp/receipt-alias-original")),
            trashedURL: try XCTUnwrap(URL(string: "file:///tmp/receipt-alias-trash")))
        let localhostAlias = RestorableItem(
            originalURL: try XCTUnwrap(
                URL(string: "file://localhost/tmp/receipt-alias-original")),
            trashedURL: try XCTUnwrap(
                URL(string: "file://localhost/tmp/receipt-alias-trash")))
        let dotSegmentReceipt = RestorableItem(
            originalURL: try XCTUnwrap(
                URL(string: "file:///tmp/receipt-parent/../receipt-dot-original")),
            trashedURL: try XCTUnwrap(
                URL(string: "file:///tmp/receipt-parent/../receipt-dot-trash")))

        let invalidReceiptReports = [
            try makeReportWithReceipts(receipts: [first, first]),
            try makeReportWithReceipts(receipts: [first, changedTrash]),
            try makeReportWithReceipts(receipts: [first, changedOriginal]),
            try makeReportWithReceipts(receipts: [canonicalAlias, localhostAlias]),
            try makeSucceededReport(receipt: dotSegmentReceipt),
            try makeReport(
                specs: [ReportItemSpec(
                    requestID: UUID(),
                    itemID: UUID(),
                    url: URL(fileURLWithPath: "/tmp/possibly-changed-with-receipt"),
                    intent: .trash,
                    disposition: .succeeded,
                    mutation: .possiblyChanged,
                    affectedBytes: 1,
                    receipt: first)],
                cancellationAccepted: false)
        ]
        for (index, report) in invalidReceiptReports.enumerated() {
            let persistence = ScriptedHistoryPersistence()
            let store = HistoryStore(directory: tmpDir, persistence: persistence)
            XCTAssertEqual(store.record(
                module: "invalid-receipt-\(index)", report: report, date: fixedRecordDate),
                           .rejected(code: "history.receipt.invalidBinding"))
            XCTAssertEqual(persistence.commitCount, 0)
            XCTAssertTrue(store.recent(10).isEmpty)
        }

        var permanentReceipt = v1RecordObject(
            module: "raw-permanent-receipt",
            items: [succeededItemObject(
                intent: "permanent", receipt: receiptObject())])
        permanentReceipt["removedCount"] = 1
        let failedRequestID = UUID()
        var failedReceiptFact = failedItemObject(requestID: failedRequestID)
        failedReceiptFact["receipt"] = receiptObject()
        let nonSuccessReceipt = v1RecordObject(
            module: "raw-non-success-receipt",
            items: [failedReceiptFact])
        let mutationNoneReceipt = v1RecordObject(
            module: "raw-mutation-none-receipt",
            items: [succeededItemObject(
                affectedBytes: 0, receipt: receiptObject()).merging([
                    "mutation": "none"
                ]) { _, replacement in replacement }],
            reclaimedBytes: 0,
            removedCount: 1)
        let duplicateRawReceipt = receiptObject(
            original: "file:///tmp/raw-duplicate-original",
            trashed: "file:///tmp/raw-duplicate-trash")
        let exactDuplicateReceipts = v1RecordObject(
            module: "raw-duplicate-receipt",
            items: [
                succeededItemObject(affectedBytes: 1, receipt: duplicateRawReceipt),
                succeededItemObject(affectedBytes: 2, receipt: duplicateRawReceipt)
            ],
            reclaimedBytes: 3,
            removedCount: 2)
        let sameOriginalReceipts = v1RecordObject(
            module: "raw-conflicting-original-receipt",
            items: [
                succeededItemObject(affectedBytes: 1, receipt: receiptObject(
                    original: "file:///tmp/raw-same-original",
                    trashed: "file:///tmp/raw-trash-a")),
                succeededItemObject(affectedBytes: 2, receipt: receiptObject(
                    original: "file:///tmp/raw-same-original",
                    trashed: "file:///tmp/raw-trash-b"))
            ],
            reclaimedBytes: 3,
            removedCount: 2)
        let sameTrashReceipts = v1RecordObject(
            module: "raw-conflicting-trash-receipt",
            items: [
                succeededItemObject(affectedBytes: 1, receipt: receiptObject(
                    original: "file:///tmp/raw-original-a",
                    trashed: "file:///tmp/raw-same-trash")),
                succeededItemObject(affectedBytes: 2, receipt: receiptObject(
                    original: "file:///tmp/raw-original-b",
                    trashed: "file:///tmp/raw-same-trash"))
            ],
            reclaimedBytes: 3,
            removedCount: 2)
        let canonicalAliasReceipts = v1RecordObject(
            module: "raw-canonical-alias-receipt",
            items: [
                succeededItemObject(affectedBytes: 1, receipt: receiptObject(
                    original: "file:///tmp/raw-alias-original",
                    trashed: "file:///tmp/raw-alias-trash")),
                succeededItemObject(affectedBytes: 2, receipt: receiptObject(
                    original: "file://localhost/tmp/raw-alias-original",
                    trashed: "file://localhost/tmp/raw-alias-trash"))
            ],
            reclaimedBytes: 3,
            removedCount: 2)
        let dotSegmentRawReceipt = v1RecordObject(
            module: "raw-dot-segment-receipt",
            items: [succeededItemObject(receipt: receiptObject(
                original: "file:///tmp/raw-parent/../raw-dot-original",
                trashed: "file:///tmp/raw-parent/../raw-dot-trash"))])
        let invalidV1Receipts = [
            permanentReceipt,
            nonSuccessReceipt,
            mutationNoneReceipt,
            exactDuplicateReceipts,
            sameOriginalReceipts,
            sameTrashReceipts,
            canonicalAliasReceipts,
            dotSegmentRawReceipt
        ]
        for (index, raw) in invalidV1Receipts.enumerated() {
            let siblingModule = "raw-invalid-valid-sibling-\(index)"
            let data = try archiveData([
                legacyRecordObject(
                    module: siblingModule, reclaimedBytes: 3, removedCount: 1),
                raw
            ])
            let (store, url) = try loadCase(data, name: "raw-invalid-receipt-\(index)")
            assertDegraded(store)
            XCTAssertTrue(store.recent(10).contains { $0.module == siblingModule })
            XCTAssertEqual(store.totalSuccessfulCleanups, 0,
                           "Invalid schema-1 receipt facts contribute no success")
            XCTAssertEqual(store.totalReclaimedAllTime, 3,
                           "Invalid schema-1 receipt facts contribute zero bytes")
            XCTAssertNil(store.record(module: "blocked", reclaimedBytes: 1, removedCount: 1))
            XCTAssertEqual(try Data(contentsOf: url), data)
        }

        for missingKey in ["originalURL", "trashedURL"] {
            var malformedReceipt = receiptObject(
                original: "file:///tmp/schema0-malformed-original",
                trashed: "file:///tmp/schema0-malformed-trash")
            malformedReceipt.removeValue(forKey: missingKey)
            let siblingModule = "schema0-missing-receipt-\(missingKey)-sibling"
            let invalidModule = "schema0-missing-receipt-\(missingKey)"
            let data = try archiveData([
                legacyRecordObject(
                    module: siblingModule, reclaimedBytes: 3, removedCount: 1),
                legacyRecordObject(
                    module: invalidModule,
                    reclaimedBytes: 91,
                    removedCount: 1,
                    restorable: [malformedReceipt])
            ])
            let (store, url) = try loadCase(
                data, name: "schema0-missing-receipt-\(missingKey)")
            assertDegraded(store)
            XCTAssertTrue(store.recent(10).contains { $0.module == siblingModule })
            XCTAssertEqual(store.totalSuccessfulCleanups, 0)
            XCTAssertEqual(store.totalReclaimedAllTime, 3,
                           "Malformed schema-0 receipts contribute zero bytes")
            XCTAssertNil(store.record(module: "blocked", reclaimedBytes: 1, removedCount: 1))
            XCTAssertEqual(try Data(contentsOf: url), data)
        }

        let requestID = UUID()
        let unboundIssue = OperationIssue(
            code: "history.test.unbound",
            category: .io,
            subjectID: UUID().uuidString,
            recovery: .retry,
            retryable: true)
        let unboundReport = try makeReport(
            specs: [ReportItemSpec(
                requestID: requestID,
                itemID: UUID(),
                url: URL(fileURLWithPath: "/tmp/unbound-issue-source"),
                intent: .trash,
                disposition: .failed(unboundIssue),
                mutation: .none,
                affectedBytes: 0,
                receipt: nil)],
            cancellationAccepted: false)
        let issuePersistence = ScriptedHistoryPersistence()
        let issueStore = HistoryStore(directory: tmpDir, persistence: issuePersistence)

        XCTAssertEqual(issueStore.record(
            module: "unbound-issue", report: unboundReport, date: fixedRecordDate),
                       .rejected(code: "history.issue.unboundSubject"))
        XCTAssertEqual(issuePersistence.commitCount, 0)
        XCTAssertTrue(issueStore.recent(10).isEmpty)
    }

    func testRecordsAccumulateAndPersist() throws {
        let store = HistoryStore(directory: tmpDir)
        XCTAssertEqual(store.totalCleanups, 0)

        store.record(module: "系统垃圾", reclaimedBytes: 1_000, removedCount: 3)
        store.record(module: "废纸篓", reclaimedBytes: 2_000, removedCount: 1)

        XCTAssertEqual(store.totalCleanups, 2)
        XCTAssertEqual(store.totalReclaimedAllTime, 3_000)
        XCTAssertEqual(store.recent(1).first?.module, "废纸篓", "最近记录应排在最前")

        // 同目录重建应从磁盘加载（持久化）
        XCTAssertEqual(HistoryStore(directory: tmpDir).totalReclaimedAllTime, 3_000)
    }

    func testIgnoresEmptyRecords() {
        let store = HistoryStore(directory: tmpDir)
        store.record(module: "x", reclaimedBytes: 0, removedCount: 0)
        XCTAssertEqual(store.totalCleanups, 0, "零释放零删除不应记录")
    }

    /// 撤销回滚：remove(id:) 后累计释放不应仍计入（修复「撤销后累计释放虚高」）
    func testRemoveRollsBackTotal() throws {
        let store = HistoryStore(directory: tmpDir)
        let id = store.record(module: "系统垃圾", reclaimedBytes: 5_000, removedCount: 2)
        XCTAssertEqual(store.totalReclaimedAllTime, 5_000)
        XCTAssertNotNil(id)
        store.remove(id: id!)
        XCTAssertEqual(store.totalReclaimedAllTime, 0, "撤销后累计释放应回滚")
        XCTAssertEqual(store.totalCleanups, 0)
    }

    /// 持久化 restorable 映射，并支持跨会话读取用于历史页撤销
    func testRestorablePersistsAndClears() throws {
        let store = HistoryStore(directory: tmpDir)
        let items = [RestorableItem(originalURL: URL(fileURLWithPath: "/tmp/a"),
                                    trashedURL: URL(fileURLWithPath: "/tmp/.Trash/a"))]
        let id = try XCTUnwrap(store.record(module: "系统垃圾", reclaimedBytes: 100,
                                            removedCount: 1, restorable: items))
        // 跨会话重建后仍能读到 restorable
        let reloaded = HistoryStore(directory: tmpDir)
        let rec = try XCTUnwrap(reloaded.recent(1).first)
        XCTAssertTrue(rec.canUndo)
        XCTAssertEqual(rec.restorable.count, 1)
        // 撤销后清除 restorable，但保留统计
        reloaded.clearRestorable(id: id)
        let after = try XCTUnwrap(reloaded.recent(1).first)
        XCTAssertFalse(after.canUndo)
        XCTAssertEqual(reloaded.totalReclaimedAllTime, 100, "clearRestorable 不应影响累计统计")
    }

    /// 核心修复：废纸篓被清空后，撤销卡片不应再空许「可放回原位」。
    /// firstUndoable 按文件系统现实过滤——注入「文件已不存在」→ 返回 nil。
    func testFirstUndoableHidesWhenTrashEmptied() throws {
        let store = HistoryStore(directory: tmpDir)
        let items = [RestorableItem(originalURL: URL(fileURLWithPath: "/tmp/a"),
                                    trashedURL: URL(fileURLWithPath: "/tmp/.Trash/a")),
                     RestorableItem(originalURL: URL(fileURLWithPath: "/tmp/b"),
                                    trashedURL: URL(fileURLWithPath: "/tmp/.Trash/b"))]
        store.record(module: "系统垃圾", reclaimedBytes: 100, removedCount: 2, restorable: items)

        // 文件还在废纸篓 → 可撤销
        XCTAssertNotNil(store.firstUndoable(existsInTrash: { _ in true }))
        // 废纸篓已清空（所有 trashedURL 不存在）→ 不再展示撤销
        XCTAssertNil(store.firstUndoable(existsInTrash: { _ in false }),
                     "清空废纸篓后撤销入口必须消失")
        // 且累计释放统计不受影响（撤销消失 ≠ 清理没发生过）
        XCTAssertEqual(store.totalReclaimedAllTime, 100)
    }

    /// 部分清空：只保留仍在废纸篓的项为可撤销，并把已消失映射自愈剪除（跨会话持久）。
    func testFirstUndoablePrunesMissingItemsAndPersists() throws {
        let store = HistoryStore(directory: tmpDir)
        let a = RestorableItem(originalURL: URL(fileURLWithPath: "/tmp/a"),
                               trashedURL: URL(fileURLWithPath: "/tmp/.Trash/a"))
        let b = RestorableItem(originalURL: URL(fileURLWithPath: "/tmp/b"),
                               trashedURL: URL(fileURLWithPath: "/tmp/.Trash/b"))
        store.record(module: "系统垃圾", reclaimedBytes: 100, removedCount: 2, restorable: [a, b])

        // 只有 a 还在废纸篓 → 记录仍可撤销，但只剩 a 一项
        let rec = try XCTUnwrap(store.firstUndoable(existsInTrash: { $0 == a.trashedURL }))
        XCTAssertEqual(rec.restorable, [a])
        // 自愈已落盘：重建 store 后仍只剩 a（默认存在性检查此时会判 a 也不存在，但持久化的映射应只含 a）
        let reloaded = HistoryStore(directory: tmpDir)
        XCTAssertEqual(reloaded.recent(1).first?.restorable, [a], "剪除后的映射应持久化")
    }

    /// 旧版 history.json（无 restorable 字段）必须能被容错解码
    func testDecodesLegacyRecordsWithoutRestorable() throws {
        let legacy = """
        [{"id":"\(UUID().uuidString)","date":0,"module":"旧记录","reclaimedBytes":42,"removedCount":1}]
        """
        try legacy.data(using: .utf8)!.write(to: tmpDir.appendingPathComponent("history.json"))
        let store = HistoryStore(directory: tmpDir)
        XCTAssertEqual(store.totalCleanups, 1)
        XCTAssertEqual(store.recent(1).first?.reclaimedBytes, 42)
        XCTAssertFalse(store.recent(1).first!.canUndo, "旧记录无 restorable，不可撤销")
    }

    func testCompoundFactRolesRoundTripWithoutPersistingPathsOrLabels() throws {
        let deletionID = UUID()
        let remediationID = UUID()
        let secretPath = "/Users/private/Library/LaunchAgents/com.secret.agent.plist"
        let secretLabel = "com.secret.agent"
        let receipt = RestorableItem(
            originalURL: URL(fileURLWithPath: "/tmp/compound-original"),
            trashedURL: URL(fileURLWithPath: "/tmp/compound-trash/item"))
        let report = try makeCompoundReport(
            deletionID: deletionID,
            remediationID: remediationID,
            deletionURL: URL(fileURLWithPath: secretPath),
            deletionDisposition: .succeeded,
            deletionMutation: .changed,
            deletionBytes: 12,
            receipt: receipt,
            remediationDisposition: .failed(boundIssue(
                code: "threat.remediation.postconditionUnknown",
                requestID: remediationID)),
            remediationMutation: .possiblyChanged)
        let store = HistoryStore(directory: tmpDir)

        _ = try insertedRecordID(store.record(
            module: "Threat cleanup", report: report, date: fixedRecordDate))

        let current = try XCTUnwrap(store.recent(1).first)
        XCTAssertEqual(current.schemaVersion, 2)
        XCTAssertEqual(current.outcomeStatus, .partial)
        XCTAssertEqual(current.counts?.requested, 2)
        XCTAssertEqual(current.removedCount, 1)
        XCTAssertEqual(current.reclaimedBytes, 12)
        XCTAssertEqual(current.restorable, [receipt])
        XCTAssertEqual(current.itemFacts.map(\.requestID), [deletionID],
                       "The compatibility item view remains deletion-only")
        XCTAssertEqual(current.operationFacts.map(\.role),
                       [.deletion, .threatRemediation])
        XCTAssertEqual(current.operationFacts.map(\.requestID),
                       [deletionID, remediationID])
        XCTAssertEqual(current.operationFacts[1].relatedCleaningRequestID, deletionID)
        XCTAssertTrue(current.hasIrreversibleChanges,
                      "possiblyChanged remediation must survive Trash receipt undo")
        XCTAssertEqual(HistoryStore(directory: tmpDir).recent(1).first, current)

        let archive = String(decoding: try Data(contentsOf: archiveURL), as: UTF8.self)
        XCTAssertFalse(archive.contains(secretPath))
        XCTAssertFalse(archive.contains(secretLabel))
    }

    func testSuccessfulRemediationDoesNotInflateCleaningAggregates() throws {
        let receipt = RestorableItem(
            originalURL: URL(fileURLWithPath: "/tmp/remediation-original"),
            trashedURL: URL(fileURLWithPath: "/tmp/remediation-trash/item"))
        let report = try makeCompoundReport(
            deletionDisposition: .succeeded,
            deletionMutation: .changed,
            deletionBytes: 80,
            receipt: receipt,
            remediationDisposition: .succeeded,
            remediationMutation: .changed)
        let store = HistoryStore(directory: tmpDir)

        let recordID = try insertedRecordID(store.record(
            module: "Compound success", report: report, date: fixedRecordDate))

        let record = try XCTUnwrap(store.recent(1).first)
        XCTAssertEqual(record.outcomeStatus, .success)
        XCTAssertEqual(record.counts?.succeeded, 2)
        XCTAssertEqual(record.removedCount, 1)
        XCTAssertEqual(record.reclaimedBytes, 80)
        XCTAssertEqual(store.totalSuccessfulCleanups, 1)
        XCTAssertEqual(store.totalReclaimedAllTime, 80)
        XCTAssertTrue(record.hasIrreversibleChanges,
                      "A changed remediation must survive deletion-receipt undo")

        XCTAssertEqual(store.updateRestorable(id: recordID, to: []), .committed)
        let afterUndo = try XCTUnwrap(store.recent(1).first)
        XCTAssertTrue(afterUndo.restorable.isEmpty)
        XCTAssertTrue(afterUndo.hasIrreversibleChanges)
        XCTAssertEqual(afterUndo.operationFacts.map(\.role),
                       [.deletion, .threatRemediation])
    }

    func testSchema2ReceiptUpdatePrunesOnlyDeletionReceipt() throws {
        let receipt = RestorableItem(
            originalURL: URL(fileURLWithPath: "/tmp/schema2-update-original"),
            trashedURL: URL(fileURLWithPath: "/tmp/schema2-update-trash/item"))
        let report = try makeCompoundReport(
            deletionDisposition: .succeeded,
            deletionMutation: .changed,
            deletionBytes: 16,
            receipt: receipt,
            remediationDisposition: .unchanged,
            remediationMutation: .none)
        let store = HistoryStore(directory: tmpDir)
        let recordID = try insertedRecordID(store.record(
            module: "Schema two receipt", report: report, date: fixedRecordDate))

        XCTAssertEqual(store.updateRestorable(id: recordID, to: []), .committed)

        let current = try XCTUnwrap(store.recent(1).first)
        XCTAssertEqual(current.schemaVersion, 2)
        XCTAssertTrue(current.restorable.isEmpty)
        XCTAssertNil(current.itemFacts.first?.receipt)
        XCTAssertEqual(current.operationFacts.map(\.role),
                       [.deletion, .threatRemediation])
        XCTAssertNil(current.operationFacts[0].receipt)
        XCTAssertNil(current.operationFacts[1].receipt)
        XCTAssertFalse(current.hasIrreversibleChanges)
        XCTAssertEqual(HistoryStore(directory: tmpDir).recent(1).first, current)
    }

    func testSchema2RejectsCrossRoleDuplicateIDsBrokenLinksAndNonDRFactOrder() throws {
        let report = try makeCompoundReport(
            deletionDisposition: .succeeded,
            deletionMutation: .changed,
            deletionBytes: 5,
            remediationDisposition: .succeeded,
            remediationMutation: .changed)
        let seed = HistoryStore(directory: tmpDir)
        _ = try insertedRecordID(seed.record(
            module: "Schema two seed", report: report, date: fixedRecordDate))
        let validData = try Data(contentsOf: archiveURL)
        let root = try XCTUnwrap(
            JSONSerialization.jsonObject(with: validData) as? [[String: Any]])
        let validRecord = try XCTUnwrap(root.first)

        let variants: [(String, ([String: Any]) throws -> [String: Any])] = [
            ("cross-role-duplicate", { record in
                var copy = record
                var facts = try XCTUnwrap(copy["facts"] as? [[String: Any]])
                facts[1]["requestID"] = facts[0]["requestID"]
                copy["facts"] = facts
                return copy
            }),
            ("broken-link", { record in
                var copy = record
                var facts = try XCTUnwrap(copy["facts"] as? [[String: Any]])
                facts[1]["relatedCleaningRequestID"] = UUID().uuidString
                copy["facts"] = facts
                return copy
            }),
            ("non-dr-order", { record in
                var copy = record
                let facts = try XCTUnwrap(copy["facts"] as? [[String: Any]])
                copy["facts"] = Array(facts.reversed())
                return copy
            }),
            ("auxiliary-receipt", { record in
                var copy = record
                var facts = try XCTUnwrap(copy["facts"] as? [[String: Any]])
                facts[1]["receipt"] = self.receiptObject()
                copy["facts"] = facts
                return copy
            })
        ]

        for (name, mutate) in variants {
            let directory = tmpDir.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: false)
            let data = try archiveData([mutate(validRecord)])
            try data.write(to: directory.appendingPathComponent("history.json"))

            let store = HistoryStore(directory: directory)
            assertDegraded(store)
            XCTAssertEqual(store.totalSuccessfulCleanups, 0, name)
            XCTAssertEqual(store.totalReclaimedAllTime, 0, name)
        }
    }

    func testSchemaOneAndTwoArchiveLoadRejectUnknownAndHistoryIneligibleKinds() throws {
        let compound = try makeCompoundReport(
            deletionDisposition: .succeeded,
            deletionMutation: .changed,
            deletionBytes: 7,
            remediationDisposition: .unchanged,
            remediationMutation: .none)
        let seed = HistoryStore(directory: tmpDir)
        _ = try insertedRecordID(seed.record(
            module: "Schema two seed",
            report: compound,
            date: fixedRecordDate))
        let schemaTwoRoot = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: archiveURL))
                as? [[String: Any]])
        let schemaTwo = try XCTUnwrap(schemaTwoRoot.first)
        let schemas: [(String, [String: Any])] = [
            ("schema-one", v1RecordObject(module: "Schema one seed")),
            ("schema-two", schemaTwo),
        ]
        let kinds = [
            "history.test.unknown",
            OperationKind.threatRemediation.rawValue,
        ]

        for (schemaName, record) in schemas {
            for kind in kinds {
                var mutated = record
                var operation = try XCTUnwrap(mutated["operation"] as? [String: Any])
                operation["kind"] = kind
                mutated["operation"] = operation
                let directory = tmpDir.appendingPathComponent(
                    "\(schemaName)-\(UUID().uuidString)",
                    isDirectory: true)
                try FileManager.default.createDirectory(
                    at: directory,
                    withIntermediateDirectories: false)
                try archiveData([mutated]).write(
                    to: directory.appendingPathComponent("history.json"))

                let store = HistoryStore(directory: directory)
                assertDegraded(store)
                XCTAssertEqual(store.totalSuccessfulCleanups, 0, schemaName)
                XCTAssertEqual(store.totalReclaimedAllTime, 0, schemaName)
            }
        }
    }

    func testSchema1RemainsReadableWhenSchema2CompoundRecordIsAppended() throws {
        let schema1 = v1RecordObject(module: "Schema one")
        let original = try archiveData([schema1])
        try writeArchive(original)
        let store = HistoryStore(directory: tmpDir)
        XCTAssertEqual(store.archiveState, .writable)
        XCTAssertEqual(store.recent(1).first?.schemaVersion, 1)

        let compound = try makeCompoundReport(
            deletionDisposition: .succeeded,
            deletionMutation: .changed,
            deletionBytes: 9,
            remediationDisposition: .unchanged,
            remediationMutation: .none)
        _ = try insertedRecordID(store.record(
            module: "Schema two", report: compound, date: fixedRecordDate))

        let fresh = HistoryStore(directory: tmpDir)
        XCTAssertEqual(fresh.archiveState, .writable)
        XCTAssertEqual(Set(fresh.recent(10).map(\.schemaVersion)), [1, 2])
        XCTAssertEqual(Set(fresh.recent(10).map(\.module)), ["Schema one", "Schema two"])
    }

    private var archiveURL: URL {
        tmpDir.appendingPathComponent("history.json")
    }

    private var fixedOperationID: UUID {
        UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
    }

    private var fixedRecordDate: Date {
        Date(timeIntervalSinceReferenceDate: 500)
    }

    private struct ReportItemSpec {
        let requestID: UUID
        let itemID: UUID
        let url: URL
        let intent: DeleteIntent
        let disposition: OperationDisposition
        let mutation: OperationMutationFact
        let affectedBytes: Int64
        let receipt: RestorableItem?
    }

    private struct JSONStringLeaf: Equatable {
        let path: String
        let value: String
    }

    private struct ExternalCompileResult {
        let status: Int32
        let standardOutput: String
        let standardError: String
        var diagnostics: String { standardOutput + standardError }
    }

    private func makeSucceededReport(
        operationID: UUID = UUID(),
        bytes: Int64 = 10,
        intent: DeleteIntent = .trash,
        receipt: RestorableItem? = RestorableItem(
            originalURL: URL(fileURLWithPath: "/tmp/typed-original"),
            trashedURL: URL(fileURLWithPath: "/tmp/typed-trash/item"))
    ) throws -> CleaningReport {
        let requestID = UUID()
        return try makeReport(
            operationID: operationID,
            specs: [ReportItemSpec(
                requestID: requestID,
                itemID: UUID(),
                url: URL(fileURLWithPath: "/tmp/private-source"),
                intent: intent,
                disposition: .succeeded,
                mutation: .changed,
                affectedBytes: bytes,
                receipt: receipt)],
            cancellationAccepted: false)
    }

    private func makeReportWithReceipts(
        operationID: UUID = UUID(),
        receipts: [RestorableItem]
    ) throws -> CleaningReport {
        try makeReport(
            operationID: operationID,
            specs: receipts.enumerated().map { index, receipt in
                ReportItemSpec(
                    requestID: UUID(),
                    itemID: UUID(),
                    url: URL(fileURLWithPath: "/tmp/report-source-\(index)"),
                    intent: .trash,
                    disposition: .succeeded,
                    mutation: .changed,
                    affectedBytes: Int64(index + 1),
                    receipt: receipt)
            },
            cancellationAccepted: false)
    }

    private func makeScalarSeed(
        persistence: ScriptedHistoryPersistence,
        receipts: [RestorableItem],
        module: String = "scalar-seed"
    ) throws -> (store: HistoryStore, id: UUID, record: CleaningRecord, data: Data) {
        let store = HistoryStore(directory: tmpDir, persistence: persistence)
        let id = try XCTUnwrap(store.record(
            module: module,
            reclaimedBytes: 10,
            removedCount: max(1, receipts.count),
            restorable: receipts,
            date: fixedRecordDate))
        return (store,
                id,
                try XCTUnwrap(store.recent(1).first),
                try XCTUnwrap(persistence.committedPayloads.last))
    }

    private func makeTypedSeed(
        persistence: ScriptedHistoryPersistence,
        receipts: [RestorableItem],
        module: String
    ) throws -> (store: HistoryStore, id: UUID, record: CleaningRecord, data: Data) {
        let store = HistoryStore(directory: tmpDir, persistence: persistence)
        let id = try insertedRecordID(store.record(
            module: module,
            report: makeReportWithReceipts(receipts: receipts),
            date: fixedRecordDate))
        return (store,
                id,
                try XCTUnwrap(store.recent(1).first),
                try XCTUnwrap(persistence.committedPayloads.last))
    }

    private func revision(of data: Data) -> HistoryRevision {
        .sha256(Data(SHA256.hash(data: data)))
    }

    private func boundIssue(
        code: String = "history.test.failure",
        requestID: UUID
    ) -> OperationIssue {
        OperationIssue(code: code,
                       category: .io,
                       subjectID: requestID.uuidString,
                       recovery: .retry,
                       retryable: true)
    }

    private func makeReport(
        operationID: UUID = UUID(),
        parentID: UUID? = nil,
        kind: OperationKind = OperationKind("cleaning.execute"),
        specs: [ReportItemSpec],
        cancellationAccepted: Bool,
        startedAt: Date = Date(timeIntervalSinceReferenceDate: 100),
        finishedAt: Date = Date(timeIntervalSinceReferenceDate: 101)
    ) throws -> CleaningReport {
        let outcome = try OperationOutcomeReducer.reduce(
            id: operationID,
            parentID: parentID,
            kind: kind,
            requestedSubjectIDs: specs.map { $0.requestID.uuidString },
            itemOutcomes: specs.map {
                OperationItemOutcome(subjectID: $0.requestID.uuidString,
                                     disposition: $0.disposition,
                                     mutation: $0.mutation,
                                     affectedBytes: $0.affectedBytes)
            },
            cancellationAccepted: cancellationAccepted,
            startedAt: startedAt,
            finishedAt: finishedAt)
        let items = specs.map {
            CleaningItemResult(requestID: $0.requestID,
                               itemID: $0.itemID,
                               url: $0.url,
                               intent: $0.intent,
                               disposition: $0.disposition,
                               mutation: $0.mutation,
                               reclaimedBytes: $0.affectedBytes,
                               restorable: $0.receipt)
        }
        return CleaningReport(operation: outcome, items: items)
    }

    private func makeCompoundReport(
        deletionID: UUID = UUID(),
        remediationID: UUID = UUID(),
        deletionURL: URL = URL(fileURLWithPath: "/tmp/private-compound-source"),
        deletionDisposition: OperationDisposition,
        deletionMutation: OperationMutationFact,
        deletionBytes: Int64,
        receipt: RestorableItem? = nil,
        remediationDisposition: OperationDisposition,
        remediationMutation: OperationMutationFact
    ) throws -> CleaningReport {
        let deletion = CleaningItemResult(
            requestID: deletionID,
            itemID: UUID(),
            url: deletionURL,
            intent: .trash,
            disposition: deletionDisposition,
            mutation: deletionMutation,
            reclaimedBytes: deletionBytes,
            restorable: receipt)
        let remediation = CleaningAuxiliaryItemResult(
            requestID: remediationID,
            relatedCleaningRequestID: deletionID,
            kind: .threatRemediation,
            disposition: remediationDisposition,
            mutation: remediationMutation)
        let facts: [CleaningOperationFact] = [
            .deletion(deletion),
            .auxiliary(remediation)
        ]
        let outcome = try OperationOutcomeReducer.reduce(
            kind: .cleaningExecute,
            requestedSubjectIDs: facts.map { $0.requestID.uuidString },
            itemOutcomes: facts.map {
                OperationItemOutcome(
                    subjectID: $0.requestID.uuidString,
                    disposition: $0.disposition,
                    mutation: $0.mutation,
                    affectedBytes: $0.affectedBytes)
            },
            cancellationAccepted: false,
            startedAt: Date(timeIntervalSinceReferenceDate: 100),
            finishedAt: Date(timeIntervalSinceReferenceDate: 101))
        return CleaningReport(operation: outcome, facts: facts)
    }

    private func insertedRecordID(
        _ result: HistoryRecordResult,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> UUID {
        guard case let .inserted(recordID) = result else {
            XCTFail("Expected inserted history result, got \(result)", file: file, line: line)
            throw TestFailure.unexpectedResult
        }
        return recordID
    }

    private func assertImmutableFactsEqual(
        _ before: CleaningRecord,
        _ after: CleaningRecord,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(after.id, before.id, file: file, line: line)
        XCTAssertEqual(after.date, before.date, file: file, line: line)
        XCTAssertEqual(after.module, before.module, file: file, line: line)
        XCTAssertEqual(after.reclaimedBytes, before.reclaimedBytes, file: file, line: line)
        XCTAssertEqual(after.removedCount, before.removedCount, file: file, line: line)
        XCTAssertEqual(after.schemaVersion, before.schemaVersion, file: file, line: line)
        XCTAssertEqual(after.operationID, before.operationID, file: file, line: line)
        XCTAssertEqual(after.parentOperationID, before.parentOperationID, file: file, line: line)
        XCTAssertEqual(after.operationKind, before.operationKind, file: file, line: line)
        XCTAssertEqual(after.outcomeStatus, before.outcomeStatus, file: file, line: line)
        XCTAssertEqual(after.mutation, before.mutation, file: file, line: line)
        XCTAssertEqual(after.counts, before.counts, file: file, line: line)
        XCTAssertEqual(after.startedAt, before.startedAt, file: file, line: line)
        XCTAssertEqual(after.finishedAt, before.finishedAt, file: file, line: line)
        XCTAssertEqual(after.issues, before.issues, file: file, line: line)
        XCTAssertEqual(after.itemFacts.count, before.itemFacts.count, file: file, line: line)
        for (lhs, rhs) in zip(after.itemFacts, before.itemFacts) {
            XCTAssertEqual(lhs.requestID, rhs.requestID, file: file, line: line)
            XCTAssertEqual(lhs.intent, rhs.intent, file: file, line: line)
            XCTAssertEqual(lhs.disposition, rhs.disposition, file: file, line: line)
            XCTAssertEqual(lhs.mutation, rhs.mutation, file: file, line: line)
            XCTAssertEqual(lhs.affectedBytes, rhs.affectedBytes, file: file, line: line)
        }
    }

    private func assertDeterministicTwoStoreCollision(
        firstDirectory: URL,
        secondDirectory: URL,
        firstModule: String,
        secondModule: String
    ) async throws {
        let blocker = FirstStagingCommitBlocker()
        let trace = PersistenceCommitTrace()
        let hooks = HistoryPersistenceHooks(didOpen: { role, _ in
            if role == .staging { blocker.blockFirstStagingOpen() }
        })
        let firstPersistence = RecordingHistoryPersistence(
            base: LiveHistoryPersistence(directory: firstDirectory, hooks: hooks),
            trace: trace)
        let secondPersistence = RecordingHistoryPersistence(
            base: LiveHistoryPersistence(directory: secondDirectory, hooks: hooks),
            trace: trace)
        let firstStore = HistoryStore(
            directory: firstDirectory, persistence: firstPersistence)
        let secondStore = HistoryStore(
            directory: secondDirectory, persistence: secondPersistence)
        XCTAssertEqual(firstPersistence.missingLoadCount, 1)
        XCTAssertEqual(secondPersistence.missingLoadCount, 1)
        let firstReport = try makeSucceededReport(operationID: UUID())
        let secondReport = try makeSucceededReport(operationID: UUID())
        let date = fixedRecordDate
        let gate = AsyncStartGate(parties: 2)

        let firstTask = Task.detached {
            await gate.arriveAndWait()
            return firstStore.record(
                module: firstModule, report: firstReport, date: date)
        }
        let secondTask = Task.detached {
            await gate.arriveAndWait()
            return secondStore.record(
                module: secondModule, report: secondReport, date: date)
        }
        let stagingEntered = await waitForSemaphore(blocker.entered)
        let firstCommitEntered = await waitForSemaphore(trace.commitEntered)
        let secondCommitEntered = await waitForSemaphore(trace.commitEntered)
        XCTAssertEqual(stagingEntered, .success)
        XCTAssertEqual(firstCommitEntered, .success)
        XCTAssertEqual(secondCommitEntered, .success,
                       "Both stores must start from the captured missing revision")
        blocker.release.signal()

        let firstResult = await firstTask.value
        let secondResult = await secondTask.value
        XCTAssertTrue([firstResult, secondResult].allSatisfy {
            if case .inserted = $0 { return true }
            return false
        })
        let attempts = trace.attempts
        XCTAssertEqual(attempts.count, 3)
        XCTAssertEqual(Array(attempts.map(\.expectedRevision).prefix(2)),
                       [.missing, .missing])
        guard attempts.count == 3 else { return }
        let firstPairCommitted = attempts.prefix(2).compactMap { attempt -> HistoryRevision? in
            guard case let .committed(revision)? = attempt.result else { return nil }
            return revision
        }
        let firstPairConflicts = attempts.prefix(2).filter { attempt in
            guard case .conflict? = attempt.result else { return false }
            return true
        }
        XCTAssertEqual(firstPairCommitted.count, 1)
        XCTAssertEqual(firstPairConflicts.count, 1)
        guard let firstRevision = firstPairCommitted.first,
              let committedAttempt = attempts.prefix(2).first(where: {
                  guard case .committed? = $0.result else { return false }
                  return true
              }),
              case .committed? = attempts[2].result else {
            return XCTFail("Expected one initial commit, one conflict, then a committed retry")
        }
        XCTAssertEqual(firstRevision, revision(of: committedAttempt.payload))
        XCTAssertEqual(attempts[2].expectedRevision, firstRevision)
        let retryObjects = try XCTUnwrap(
            JSONSerialization.jsonObject(with: attempts[2].payload) as? [[String: Any]])
        XCTAssertEqual(Set(retryObjects.compactMap { $0["module"] as? String }),
                       [firstModule, secondModule])
        let fresh = HistoryStore(directory: firstDirectory)
        XCTAssertEqual(fresh.totalHistoryRecords, 2)
        XCTAssertEqual(Set(fresh.recent(10).map(\.module)),
                       [firstModule, secondModule])
    }

    private func waitForSemaphore(
        _ semaphore: DispatchSemaphore,
        timeout: DispatchTime = .now() + 5
    ) async -> DispatchTimeoutResult {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: semaphore.wait(timeout: timeout))
            }
        }
    }

    private func writeArchive(_ data: Data, directory: URL? = nil) throws {
        try data.write(to: (directory ?? tmpDir).appendingPathComponent("history.json"))
    }

    private func makeCaseDirectory(_ name: String) throws -> URL {
        let directory = tmpDir.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: false)
        return directory
    }

    private func permissions(at url: URL) throws -> mode_t {
        var info = stat()
        let result = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return lstat(path, &info)
        }
        guard result == 0 else {
            throw POSIXTestError(operation: "lstat", code: errno)
        }
        return info.st_mode & 0o777
    }

    private func setPermissions(_ mode: mode_t, at url: URL) throws {
        let result = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return chmod(path, mode)
        }
        guard result == 0 else {
            throw POSIXTestError(operation: "chmod", code: errno)
        }
    }

    private func jsonStringLeaves(_ value: Any, path: String = "$") -> [JSONStringLeaf] {
        if let string = value as? String {
            return [JSONStringLeaf(path: path, value: string)]
        }
        if let array = value as? [Any] {
            return array.enumerated().flatMap { index, element in
                jsonStringLeaves(element, path: "\(path)[\(index)]")
            }
        }
        if let object = value as? [String: Any] {
            return object.keys.sorted().flatMap { key in
                jsonStringLeaves(object[key] as Any, path: "\(path).\(key)")
            }
        }
        return []
    }

    private func jsonKeys(_ value: Any) -> Set<String> {
        if let array = value as? [Any] {
            return array.reduce(into: Set<String>()) { keys, element in
                keys.formUnion(jsonKeys(element))
            }
        }
        if let object = value as? [String: Any] {
            return object.reduce(into: Set(object.keys)) { keys, entry in
                keys.formUnion(jsonKeys(entry.value))
            }
        }
        return []
    }

    private func compileInfrastructureExternalClient(
        _ source: String,
        warningsAsErrors: Bool = true
    ) throws -> ExternalCompileResult {
        let fileManager = FileManager.default
        let temporaryURL = fileManager.temporaryDirectory.appendingPathComponent(
            "XicoInfrastructureClient-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(
            at: temporaryURL, withIntermediateDirectories: false)
        defer { try? fileManager.removeItem(at: temporaryURL) }
        let sourceURL = temporaryURL.appendingPathComponent("client.swift")
        try source.write(to: sourceURL, atomically: true, encoding: .utf8)

        let modulesURL = try debugInfrastructureModulesDirectory()
        let debugURL = modulesURL.deletingLastPathComponent()
        let moduleCacheURL = debugURL.appendingPathComponent(
            "ModuleCache", isDirectory: true)
        try fileManager.createDirectory(
            at: moduleCacheURL, withIntermediateDirectories: true)
        let moduleMaps = ["CProcessBatch", "CSensors"].map {
            debugURL.appendingPathComponent("\($0).build/module.modulemap")
        }
        for moduleMap in moduleMaps {
            guard fileManager.fileExists(atPath: moduleMap.path) else {
                XCTFail("Expected module map at \(moduleMap.path)")
                throw CocoaError(.fileNoSuchFile)
            }
        }
        let outputURL = temporaryURL.appendingPathComponent("stdout.txt")
        let errorURL = temporaryURL.appendingPathComponent("stderr.txt")
        _ = fileManager.createFile(atPath: outputURL.path, contents: nil)
        _ = fileManager.createFile(atPath: errorURL.path, contents: nil)
        let output = try FileHandle(forWritingTo: outputURL)
        let error = try FileHandle(forWritingTo: errorURL)
        defer {
            try? output.close()
            try? error.close()
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        var arguments = ["swiftc", "-typecheck"]
        if warningsAsErrors {
            arguments.append("-warnings-as-errors")
        }
        arguments.append(contentsOf: [
            "-module-cache-path", moduleCacheURL.path,
            "-I", modulesURL.path
        ])
        for moduleMap in moduleMaps {
            arguments.append("-Xcc")
            arguments.append("-fmodule-map-file=\(moduleMap.path)")
        }
        arguments.append(sourceURL.path)
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = error
        let processMonitor = ProcessTerminationMonitor(process)
        defer {
            if process.isRunning {
                XCTAssertTrue(processMonitor.stopAndWait(),
                              "Timed-out normal-import compiler must be reaped")
            }
        }
        try process.run()
        guard processMonitor.wait(timeout: .now() + 20) == .success else {
            XCTAssertTrue(processMonitor.stopAndWait(),
                          "SIGKILL fallback must reap the normal-import compiler")
            XCTFail("Timed out typechecking normal-import Infrastructure client")
            throw TestFailure.unexpectedResult
        }
        try output.synchronize()
        try error.synchronize()
        try output.close()
        try error.close()
        return ExternalCompileResult(
            status: process.terminationStatus,
            standardOutput: String(
                decoding: try Data(contentsOf: outputURL), as: UTF8.self),
            standardError: String(
                decoding: try Data(contentsOf: errorURL), as: UTF8.self))
    }

    private func waitForFilePrefix(
        _ prefix: Data,
        at url: URL,
        timeout: TimeInterval
    ) throws -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let data = try Data(contentsOf: url)
            if data.starts(with: prefix) { return true }
            usleep(10_000)
        }
        return false
    }

    private func makeFlockHolderExecutable(in parent: URL) throws -> URL {
        let directory = parent.appendingPathComponent(
            "flock-holder-build-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: false)
        let sourceURL = directory.appendingPathComponent("holder.swift")
        let executableURL = directory.appendingPathComponent("holder")
        let source = """
        import Darwin

        if CommandLine.arguments.count == 3,
           CommandLine.arguments[1] == "probe" {
            let descriptor = open(CommandLine.arguments[2], O_RDWR | O_CREAT, 0o600)
            guard descriptor >= 0 else { exit(20) }
            let result = flock(descriptor, LOCK_EX | LOCK_NB)
            let observedErrno = errno
            if result == 0 {
                _ = flock(descriptor, LOCK_UN)
                close(descriptor)
                exit(21)
            }
            close(descriptor)
            exit(observedErrno == EWOULDBLOCK ? 23 : 24)
        }

        guard CommandLine.arguments.count == 2 else { exit(2) }
        let descriptor = open(CommandLine.arguments[1], O_RDWR | O_CREAT, 0o600)
        guard descriptor >= 0 else { exit(3) }
        guard flock(descriptor, LOCK_EX) == 0 else { exit(4) }
        var ready = UInt8(ascii: "R")
        guard withUnsafePointer(to: &ready, {
            Darwin.write(STDOUT_FILENO, $0, 1)
        }) == 1 else { exit(5) }
        var release: UInt8 = 0
        guard withUnsafeMutablePointer(to: &release, {
            Darwin.read(STDIN_FILENO, $0, 1)
        }) == 1 else { exit(6) }
        guard flock(descriptor, LOCK_UN) == 0 else { exit(7) }
        close(descriptor)
        """
        try source.write(to: sourceURL, atomically: true, encoding: .utf8)
        let outputURL = directory.appendingPathComponent("compile.stdout")
        let errorURL = directory.appendingPathComponent("compile.stderr")
        _ = FileManager.default.createFile(atPath: outputURL.path, contents: nil)
        _ = FileManager.default.createFile(atPath: errorURL.path, contents: nil)
        let output = try FileHandle(forWritingTo: outputURL)
        let error = try FileHandle(forWritingTo: errorURL)
        defer {
            try? output.close()
            try? error.close()
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["swiftc", sourceURL.path, "-o", executableURL.path]
        process.standardOutput = output
        process.standardError = error
        let monitor = ProcessTerminationMonitor(process)
        defer {
            if process.isRunning {
                XCTAssertTrue(monitor.stopAndWait(),
                              "Timed-out flock-helper compiler must be reaped")
            }
        }
        try process.run()
        guard monitor.wait(timeout: .now() + 20) == .success else {
            XCTAssertTrue(monitor.stopAndWait(),
                          "SIGKILL fallback must reap the flock-helper compiler")
            XCTFail("Timed out compiling external flock helper")
            throw TestFailure.unexpectedResult
        }
        try output.synchronize()
        try error.synchronize()
        let diagnostics = String(
            decoding: try Data(contentsOf: errorURL), as: UTF8.self)
        guard process.terminationStatus == 0 else {
            XCTFail("Failed to compile flock holder: \(diagnostics)")
            throw TestFailure.unexpectedResult
        }
        return executableURL
    }

    private func assertNoInfrastructureModuleLoadFailure(
        _ result: ExternalCompileResult,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertFalse(result.standardError.localizedCaseInsensitiveContains(
            "no such module"), result.diagnostics, file: file, line: line)
        XCTAssertFalse(result.standardError.localizedCaseInsensitiveContains(
            "missing required module"), result.diagnostics, file: file, line: line)
    }

    private func debugInfrastructureModulesDirectory() throws -> URL {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let buildURL = repositoryRoot.appendingPathComponent(".build", isDirectory: true)
        let enumerator = FileManager.default.enumerator(
            at: buildURL, includingPropertiesForKeys: nil)
        var candidates: [URL] = []
        while let candidate = enumerator?.nextObject() as? URL {
            guard candidate.lastPathComponent == "Infrastructure.swiftmodule" else { continue }
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
                             "Expected debug Infrastructure.swiftmodule")
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

    private func archiveData(_ records: [Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: records, options: [.sortedKeys])
    }

    private func loadedResult(_ data: Data) -> HistoryLoadResult {
        .loaded(HistoryPersistenceSnapshot(
            data: data,
            revision: .sha256(Data(SHA256.hash(data: data)))))
    }

    private func appendingLegacyRecords(
        to data: Data,
        count: Int,
        prefix: String
    ) throws -> Data {
        var records = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        records.append(contentsOf: (0..<count).map { index in
            legacyRecordObject(
                id: deterministicLegacyRecordID(prefix: prefix, index: index),
                date: TimeInterval(index + 1_000),
                module: "\(prefix)-\(index)",
                reclaimedBytes: 1,
                removedCount: 1)
        })
        return try archiveData(records)
    }

    private func verifiedConflictActions(
        startingFrom data: Data,
        count: Int,
        prefix: String
    ) throws -> [ScriptedHistoryPersistence.CommitAction] {
        guard count > 0 else { return [] }
        var latest = data
        var actions: [ScriptedHistoryPersistence.CommitAction] = []
        for attempt in 0..<count {
            latest = try appendingLegacyRecord(
                to: latest, index: attempt, prefix: prefix)
            actions.append(.conflict(latest: loadedResult(latest)))
        }
        return actions
    }

    private func expectedRevisionsForVerifiedConflicts(
        startingFrom data: Data,
        count: Int,
        prefix: String
    ) throws -> [HistoryRevision] {
        guard count > 0 else { return [] }
        var revisions = [revision(of: data)]
        var latest = data
        for attempt in 0..<(count - 1) {
            latest = try appendingLegacyRecord(
                to: latest, index: attempt, prefix: prefix)
            revisions.append(revision(of: latest))
        }
        return revisions
    }

    private func appendingLegacyRecord(
        to data: Data,
        index: Int,
        prefix: String
    ) throws -> Data {
        var records = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        records.append(legacyRecordObject(
            id: deterministicLegacyRecordID(prefix: prefix, index: index),
            date: TimeInterval(index + 1_000),
            module: "\(prefix)-\(index)",
            reclaimedBytes: 1,
            removedCount: 1))
        return try archiveData(records)
    }

    private func deterministicLegacyRecordID(prefix: String, index: Int) -> UUID {
        let digest = SHA256.hash(data: Data("\(prefix)#\(index)".utf8))
        let hex = digest.prefix(16).map { String(format: "%02x", $0) }.joined()
        let value = "\(hex.prefix(8))-\(hex.dropFirst(8).prefix(4))-"
            + "\(hex.dropFirst(12).prefix(4))-\(hex.dropFirst(16).prefix(4))-"
            + "\(hex.dropFirst(20).prefix(12))"
        return UUID(uuidString: value)!
    }

    private func loadCase(_ data: Data, name: String) throws -> (HistoryStore, URL) {
        let directory = tmpDir.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try writeArchive(data, directory: directory)
        return (HistoryStore(directory: directory), directory.appendingPathComponent("history.json"))
    }

    private func assertLimitRejected(
        _ data: Data,
        name: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let (store, url) = try loadCase(data, name: name)
        assertDegraded(store, file: file, line: line)
        XCTAssertEqual(store.totalSuccessfulCleanups, 0, file: file, line: line)
        XCTAssertNil(store.record(module: "blocked", reclaimedBytes: 1, removedCount: 1),
                     file: file, line: line)
        XCTAssertEqual(try Data(contentsOf: url), data, file: file, line: line)
    }

    private func paddedJSON(_ data: Data, byteCount: Int) -> Data {
        precondition(byteCount >= data.count)
        var result = data
        result.append(contentsOf: repeatElement(UInt8(ascii: " "), count: byteCount - data.count))
        return result
    }

    private func utf8SizedString(_ byteCount: Int) -> String {
        let doubleByteCount = byteCount / 2
        return String(repeating: "é", count: doubleByteCount)
            + (byteCount.isMultiple(of: 2) ? "" : "x")
    }

    private func changingOperation(
        _ record: [String: Any],
        _ change: (inout [String: Any]) -> Void
    ) -> [String: Any] {
        var result = record
        var operation = result["operation"] as! [String: Any]
        change(&operation)
        result["operation"] = operation
        return result
    }

    private func changingCounts(
        _ record: [String: Any],
        _ change: (inout [String: Any]) -> Void
    ) -> [String: Any] {
        changingOperation(record) { operation in
            var counts = operation["counts"] as! [String: Any]
            change(&counts)
            operation["counts"] = counts
        }
    }

    private func changingFirstItem(
        _ record: [String: Any],
        _ change: (inout [String: Any]) -> Void
    ) -> [String: Any] {
        var result = record
        var items = result["items"] as! [[String: Any]]
        change(&items[0])
        result["items"] = items
        return result
    }

    private func changingFirstIssue(
        _ record: [String: Any],
        _ change: (inout [String: Any]) -> Void
    ) -> [String: Any] {
        var result = record
        var items = result["items"] as! [[String: Any]]
        var disposition = items[0]["disposition"] as! [String: Any]
        var issue = disposition["issue"] as! [String: Any]
        change(&issue)
        disposition["issue"] = issue
        items[0]["disposition"] = disposition
        result["items"] = items
        var operation = result["operation"] as! [String: Any]
        operation["issues"] = [issue]
        result["operation"] = operation
        return result
    }

    private func legacyRecordObject(
        id: UUID = UUID(),
        date: TimeInterval = 0,
        module: String = "legacy",
        reclaimedBytes: Int64 = 42,
        removedCount: Int = 1,
        restorable: [[String: Any]]? = nil
    ) -> [String: Any] {
        var object: [String: Any] = [
            "id": id.uuidString,
            "date": date,
            "module": module,
            "reclaimedBytes": reclaimedBytes,
            "removedCount": removedCount
        ]
        if let restorable { object["restorable"] = restorable }
        return object
    }

    private func receiptObject(
        original: String = "file:///tmp/history-original",
        trashed: String = "file:///tmp/history-trash/item"
    ) -> [String: Any] {
        ["originalURL": original, "trashedURL": trashed]
    }

    private func issueObject(
        code: String = "history.test.failure",
        subjectID: String?,
        extra: [String: Any] = [:]
    ) -> [String: Any] {
        var issue: [String: Any] = [
            "code": code,
            "category": "io",
            "recovery": "retry",
            "retryable": true
        ]
        if let subjectID { issue["subjectID"] = subjectID }
        issue.merge(extra) { _, new in new }
        return issue
    }

    private func succeededItemObject(
        requestID: UUID = UUID(),
        intent: String = "trash",
        affectedBytes: Int64 = 10,
        receipt: [String: Any]? = nil
    ) -> [String: Any] {
        var item: [String: Any] = [
            "requestID": requestID.uuidString,
            "intent": intent,
            "disposition": ["kind": "succeeded"],
            "mutation": "changed",
            "affectedBytes": affectedBytes
        ]
        if let receipt { item["receipt"] = receipt }
        return item
    }

    private func unchangedItemObject(requestID: UUID = UUID()) -> [String: Any] {
        [
            "requestID": requestID.uuidString,
            "intent": "trash",
            "disposition": ["kind": "unchanged"],
            "mutation": "none",
            "affectedBytes": Int64(0)
        ]
    }

    private func cancelledItemObject(requestID: UUID = UUID()) -> [String: Any] {
        [
            "requestID": requestID.uuidString,
            "intent": "trash",
            "disposition": ["kind": "cancelled"],
            "mutation": "none",
            "affectedBytes": Int64(0)
        ]
    }

    private func failedItemObject(
        requestID: UUID = UUID(),
        code: String = "history.test.failure",
        subjectID: String? = nil,
        omitSubjectID: Bool = false,
        issueExtra: [String: Any] = [:]
    ) -> [String: Any] {
        let issue = issueObject(code: code,
                                subjectID: omitSubjectID
                                    ? nil
                                    : (subjectID ?? requestID.uuidString),
                                extra: issueExtra)
        return [
            "requestID": requestID.uuidString,
            "intent": "trash",
            "disposition": ["kind": "failed", "issue": issue],
            "mutation": "none",
            "affectedBytes": 0
        ]
    }

    private func v1RecordObject(
        recordID: UUID = UUID(),
        operationID: UUID = UUID(),
        parentOperationID: UUID? = nil,
        module: String = "typed-cleaning",
        kind: String = "cleaning.execute",
        items: [[String: Any]]? = nil,
        status: String? = nil,
        mutation: String? = nil,
        issues: [[String: Any]]? = nil,
        reclaimedBytes: Int64? = nil,
        removedCount: Int? = nil
    ) -> [String: Any] {
        let facts = items ?? [succeededItemObject(receipt: receiptObject())]
        let dispositions = facts.compactMap { fact in
            (fact["disposition"] as? [String: Any])?["kind"] as? String
        }
        let succeeded = dispositions.filter { $0 == "succeeded" }.count
        let unchanged = dispositions.filter { $0 == "unchanged" }.count
        let skipped = dispositions.filter { $0 == "skipped" }.count
        let failed = dispositions.filter { $0 == "failed" }.count
        let cancelled = dispositions.filter { $0 == "cancelled" }.count
        let itemIssues = facts.compactMap { fact -> [String: Any]? in
            guard let disposition = fact["disposition"] as? [String: Any] else { return nil }
            return disposition["issue"] as? [String: Any]
        }
        let aggregateMutation: String = facts.contains { ($0["mutation"] as? String) == "possiblyChanged" }
            ? "possiblyChanged"
            : (facts.contains { ($0["mutation"] as? String) == "changed" } ? "changed" : "none")
        let aggregateBytes = facts.reduce(Int64(0)) { total, fact in
            guard ((fact["disposition"] as? [String: Any])?["kind"] as? String) == "succeeded",
                  let value = fact["affectedBytes"] as? Int64 else { return total }
            let (sum, overflow) = total.addingReportingOverflow(max(0, value))
            return overflow ? Int64.max : sum
        }
        let derivedStatus: String
        if failed + skipped + cancelled == 0 {
            derivedStatus = "success"
        } else if succeeded + unchanged > 0 {
            derivedStatus = "partial"
        } else {
            derivedStatus = "failure"
        }
        var operation: [String: Any] = [
            "id": operationID.uuidString,
            "kind": kind,
            "status": status ?? derivedStatus,
            "mutation": mutation ?? aggregateMutation,
            "counts": [
                "requested": facts.count,
                "succeeded": succeeded,
                "unchanged": unchanged,
                "skipped": skipped,
                "failed": failed,
                "cancelled": cancelled
            ],
            "issues": canonicalIssueObjects(issues ?? itemIssues),
            "startedAt": 0,
            "finishedAt": 1
        ]
        if let parentOperationID { operation["parentID"] = parentOperationID.uuidString }
        return [
            "schemaVersion": 1,
            "id": recordID.uuidString,
            "date": 2,
            "module": module,
            "reclaimedBytes": reclaimedBytes ?? aggregateBytes,
            "removedCount": removedCount ?? succeeded,
            "operation": operation,
            "items": facts
        ]
    }

    private func assertDegraded(
        _ store: HistoryStore,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case .degradedReadOnly = store.archiveState else {
            XCTFail("Expected degraded read-only history archive", file: file, line: line)
            return
        }
    }

    private func canonicalIssueObjects(_ issues: [[String: Any]]) -> [[String: Any]] {
        issues.sorted { lhs, rhs in
            let lhsSubject = lhs["subjectID"] as? String
            let rhsSubject = rhs["subjectID"] as? String
            switch (lhsSubject, rhsSubject) {
            case (nil, .some): return true
            case (.some, nil): return false
            case let (.some(left), .some(right)) where left != right: return left < right
            default: break
            }
            let keys = ["code", "category", "recovery"]
            for key in keys {
                let left = lhs[key] as? String ?? ""
                let right = rhs[key] as? String ?? ""
                if left != right { return left < right }
            }
            let leftRetryable = lhs["retryable"] as? Bool ?? false
            let rightRetryable = rhs["retryable"] as? Bool ?? false
            return !leftRetryable && rightRetryable
        }
    }
}

private final class ScriptedHistoryPersistence: HistoryPersistence, @unchecked Sendable {
    enum CommitAction: Sendable {
        case committed
        case failed(code: String)
        case conflict(latest: HistoryLoadResult)
        case indeterminateUsingCandidate(code: String)
        case indeterminate(latest: HistoryLoadResult?, code: String)
    }

    private let lock = NSLock()
    private var currentLoad: HistoryLoadResult
    private var actions: [CommitAction]
    private var payloads: [Data] = []
    private var expected: [HistoryRevision] = []
    private var loads = 0
    private var conflictReturnedCallback: (@Sendable () -> Void)?

    init(loadResult: HistoryLoadResult = .missing, commitActions: [CommitAction] = []) {
        currentLoad = loadResult
        actions = commitActions
    }

    func load() -> HistoryLoadResult {
        lock.lock(); defer { lock.unlock() }
        loads += 1
        return currentLoad
    }

    func commit(_ data: Data, expectedRevision: HistoryRevision) -> HistoryCommitResult {
        lock.lock()
        var callbackAfterUnlock: (@Sendable () -> Void)?
        defer {
            lock.unlock()
            callbackAfterUnlock?()
        }
        payloads.append(data)
        expected.append(expectedRevision)
        let actualRevision: HistoryRevision
        switch currentLoad {
        case .missing:
            actualRevision = .missing
        case let .loaded(snapshot):
            actualRevision = snapshot.revision
        case .failed:
            callbackAfterUnlock = conflictReturnedCallback
            return .conflict(latest: currentLoad)
        }
        guard actualRevision == expectedRevision else {
            callbackAfterUnlock = conflictReturnedCallback
            return .conflict(latest: currentLoad)
        }
        let action = actions.isEmpty ? .committed : actions.removeFirst()
        switch action {
        case .committed:
            let revision = HistoryRevision.sha256(Data(SHA256.hash(data: data)))
            currentLoad = .loaded(HistoryPersistenceSnapshot(data: data, revision: revision))
            return .committed(newRevision: revision)
        case let .failed(code):
            return .failed(code: code)
        case let .conflict(latest):
            currentLoad = latest
            callbackAfterUnlock = conflictReturnedCallback
            return .conflict(latest: latest)
        case let .indeterminateUsingCandidate(code):
            let revision = HistoryRevision.sha256(Data(SHA256.hash(data: data)))
            let latest = HistoryLoadResult.loaded(
                HistoryPersistenceSnapshot(data: data, revision: revision))
            currentLoad = latest
            return .indeterminate(latest: latest, code: code)
        case let .indeterminate(latest, code):
            if let latest { currentLoad = latest }
            return .indeterminate(latest: latest, code: code)
        }
    }

    func replaceLoadResult(_ result: HistoryLoadResult) {
        lock.lock(); defer { lock.unlock() }
        currentLoad = result
    }

    func replaceCommitActions(_ newActions: [CommitAction]) {
        lock.lock(); defer { lock.unlock() }
        actions = newActions
    }

    func onConflictReturned(_ callback: @escaping @Sendable () -> Void) {
        lock.lock(); defer { lock.unlock() }
        conflictReturnedCallback = callback
    }

    var commitCount: Int {
        lock.lock(); defer { lock.unlock() }
        return payloads.count
    }

    var loadCount: Int {
        lock.lock(); defer { lock.unlock() }
        return loads
    }

    var committedPayloads: [Data] {
        lock.lock(); defer { lock.unlock() }
        return payloads
    }

    var expectedRevisions: [HistoryRevision] {
        lock.lock(); defer { lock.unlock() }
        return expected
    }

    var loadedData: Data? {
        lock.lock(); defer { lock.unlock() }
        guard case let .loaded(snapshot) = currentLoad else { return nil }
        return snapshot.data
    }
}

private final class BlockingHistoryPersistence: HistoryPersistence, @unchecked Sendable {
    enum Event: Equatable {
        case loadEntered
        case loadReleased
        case commitEntered
    }

    let loadEntered = DispatchSemaphore(value: 0)
    let allowLoad = DispatchSemaphore(value: 0)
    let commitEntered = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var current: HistoryLoadResult
    private var blockedLoad: HistoryLoadResult?
    private var recordedEvents: [Event] = []
    private var commits = 0

    init(initial: HistoryLoadResult) {
        current = initial
    }

    func blockNextLoad(returning result: HistoryLoadResult) {
        lock.lock(); defer { lock.unlock() }
        blockedLoad = result
    }

    func load() -> HistoryLoadResult {
        lock.lock()
        guard let result = blockedLoad else {
            let value = current
            lock.unlock()
            return value
        }
        blockedLoad = nil
        recordedEvents.append(.loadEntered)
        lock.unlock()

        loadEntered.signal()
        _ = allowLoad.wait(timeout: .now() + 10)

        lock.lock()
        current = result
        recordedEvents.append(.loadReleased)
        lock.unlock()
        return result
    }

    func commit(_ data: Data, expectedRevision: HistoryRevision) -> HistoryCommitResult {
        lock.lock()
        recordedEvents.append(.commitEntered)
        commits += 1
        let latest = current
        lock.unlock()
        commitEntered.signal()

        let actual: HistoryRevision
        switch latest {
        case .missing:
            actual = .missing
        case let .loaded(snapshot):
            actual = snapshot.revision
        case .failed:
            return .conflict(latest: latest)
        }
        guard actual == expectedRevision else { return .conflict(latest: latest) }
        let revision = HistoryRevision.sha256(Data(SHA256.hash(data: data)))
        lock.lock()
        current = .loaded(HistoryPersistenceSnapshot(data: data, revision: revision))
        lock.unlock()
        return .committed(newRevision: revision)
    }

    var events: [Event] {
        lock.lock(); defer { lock.unlock() }
        return recordedEvents
    }

    var commitCount: Int {
        lock.lock(); defer { lock.unlock() }
        return commits
    }
}

private final class FirstStagingCommitBlocker: @unchecked Sendable {
    let entered = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var hasBlocked = false

    func blockFirstStagingOpen() {
        lock.lock()
        guard !hasBlocked else {
            lock.unlock()
            return
        }
        hasBlocked = true
        lock.unlock()
        entered.signal()
        _ = release.wait(timeout: .now() + 10)
    }
}

private final class PersistenceCommitTrace: @unchecked Sendable {
    struct Attempt: @unchecked Sendable {
        let expectedRevision: HistoryRevision
        let payload: Data
        var result: HistoryCommitResult?
    }

    let commitEntered = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var recorded: [Attempt] = []

    func begin(payload: Data, expectedRevision: HistoryRevision) -> Int {
        lock.lock()
        let index = recorded.count
        recorded.append(Attempt(
            expectedRevision: expectedRevision, payload: payload, result: nil))
        lock.unlock()
        commitEntered.signal()
        return index
    }

    func finish(index: Int, result: HistoryCommitResult) {
        lock.lock(); defer { lock.unlock() }
        recorded[index].result = result
    }

    var attempts: [Attempt] {
        lock.lock(); defer { lock.unlock() }
        return recorded
    }
}

private final class RecordingHistoryPersistence: HistoryPersistence, @unchecked Sendable {
    private let base: any HistoryPersistence
    private let trace: PersistenceCommitTrace
    private let lock = NSLock()
    private var missingLoads = 0

    init(base: any HistoryPersistence, trace: PersistenceCommitTrace) {
        self.base = base
        self.trace = trace
    }

    func load() -> HistoryLoadResult {
        let result = base.load()
        if case .missing = result {
            lock.lock()
            missingLoads += 1
            lock.unlock()
        }
        return result
    }

    func commit(_ data: Data, expectedRevision: HistoryRevision) -> HistoryCommitResult {
        let index = trace.begin(payload: data, expectedRevision: expectedRevision)
        let result = base.commit(data, expectedRevision: expectedRevision)
        trace.finish(index: index, result: result)
        return result
    }

    var missingLoadCount: Int {
        lock.lock(); defer { lock.unlock() }
        return missingLoads
    }
}

private enum TestFailure: Error {
    case unexpectedResult
}

private struct POSIXTestError: Error {
    let operation: String
    let code: Int32
}

private final class ProcessTerminationMonitor: @unchecked Sendable {
    private let process: Process
    private let group = DispatchGroup()

    init(_ process: Process) {
        self.process = process
        group.enter()
        let completionGroup = group
        process.terminationHandler = { _ in completionGroup.leave() }
    }

    func wait(timeout: DispatchTime) -> DispatchTimeoutResult {
        group.wait(timeout: timeout)
    }

    func stopAndWait() -> Bool {
        if process.isRunning { process.terminate() }
        if group.wait(timeout: .now() + 2) == .success { return true }
        if process.isRunning { _ = Darwin.kill(process.processIdentifier, SIGKILL) }
        return group.wait(timeout: .now() + 2) == .success
    }
}

private final class FlockCoverageTrace: @unchecked Sendable {
    enum Event: Hashable {
        case exclusiveLock
        case archiveOpen
        case archiveRead
        case write
        case stagingFsync
        case rename
        case parentFsync
        case lockClose
        case unlock
    }

    static let externalBlockedExitStatus: Int32 = 23
    static let externalAcquiredExitStatus: Int32 = 21

    private let helperExecutable: URL
    private let lockURL: URL
    private let lock = NSLock()
    private var recordedEvents: [Event] = []
    private var probeStatuses: [Event: Int32] = [:]
    private var descriptorRoles: [Int32: HistoryPersistenceFileRole] = [:]
    private var probeCleanupFailures = 0

    init(helperExecutable: URL, lockURL: URL) {
        self.helperExecutable = helperExecutable
        self.lockURL = lockURL
    }

    func reset() {
        lock.lock(); defer { lock.unlock() }
        recordedEvents = []
        probeStatuses = [:]
        descriptorRoles = [:]
    }

    func didOpen(role: HistoryPersistenceFileRole, descriptor: Int32) {
        lock.lock()
        descriptorRoles[descriptor] = role
        lock.unlock()
        guard role == .archive else { return }
        record(.archiveOpen)
        probeExternalLock(at: .archiveOpen)
    }

    func read(
        descriptor: Int32,
        pointer: UnsafeMutableRawPointer?,
        count: Int
    ) -> Int {
        if role(for: descriptor) == .archive {
            record(.archiveRead)
        }
        return Darwin.read(descriptor, pointer, count)
    }

    func write(
        descriptor: Int32,
        pointer: UnsafeRawPointer?,
        count: Int
    ) -> Int {
        record(.write)
        return Darwin.write(descriptor, pointer, count)
    }

    func fsync(descriptor: Int32, role: HistoryPersistenceFileRole) -> Int32 {
        switch role {
        case .staging:
            record(.stagingFsync)
        case .parentDirectory:
            record(.parentFsync)
            probeExternalLock(at: .parentFsync)
        default:
            break
        }
        return Darwin.fsync(descriptor)
    }

    func rename(
        directoryDescriptor: Int32,
        source: String,
        destination: String
    ) -> Int32 {
        record(.rename)
        return source.withCString { sourcePath in
            destination.withCString { destinationPath in
                Darwin.renameat(
                    directoryDescriptor,
                    sourcePath,
                    directoryDescriptor,
                    destinationPath)
            }
        }
    }

    func flock(descriptor: Int32, operation: Int32) -> Int32 {
        let result = systemFlock(descriptor, operation)
        guard result == 0 else { return result }
        if (operation & LOCK_EX) != 0 {
            record(.exclusiveLock)
        } else if (operation & LOCK_UN) != 0 {
            record(.unlock)
        }
        return result
    }

    func didClose(role: HistoryPersistenceFileRole, descriptor: Int32) {
        lock.lock()
        descriptorRoles.removeValue(forKey: descriptor)
        lock.unlock()
        if role == .lock {
            record(.lockClose)
        }
    }

    var events: [Event] {
        lock.lock(); defer { lock.unlock() }
        return recordedEvents
    }

    var externalProbeStatuses: [Event: Int32] {
        lock.lock(); defer { lock.unlock() }
        return probeStatuses
    }

    var externalProbeCleanupFailureCount: Int {
        lock.lock(); defer { lock.unlock() }
        return probeCleanupFailures
    }

    func probeExternalLockAfterTransaction() -> Int32 {
        runExternalProbe()
    }

    private func record(_ event: Event) {
        lock.lock(); defer { lock.unlock() }
        recordedEvents.append(event)
    }

    private func role(for descriptor: Int32) -> HistoryPersistenceFileRole? {
        lock.lock(); defer { lock.unlock() }
        return descriptorRoles[descriptor]
    }

    private func probeExternalLock(at event: Event) {
        let status = runExternalProbe()
        lock.lock(); defer { lock.unlock() }
        probeStatuses[event] = status
    }

    private func runExternalProbe() -> Int32 {
        let process = Process()
        process.executableURL = helperExecutable
        process.arguments = ["probe", lockURL.path]
        let monitor = ProcessTerminationMonitor(process)
        do {
            try process.run()
            if monitor.wait(timeout: .now() + 5) == .success {
                return process.terminationStatus
            } else {
                let reaped = monitor.stopAndWait()
                if !reaped {
                    lock.lock()
                    probeCleanupFailures += 1
                    lock.unlock()
                }
                return reaped ? -101 : -102
            }
        } catch {
            return -100
        }
    }
}

private final class OpenedFileModeCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var modes: [HistoryPersistenceFileRole: mode_t] = [:]

    func record(role: HistoryPersistenceFileRole, descriptor: Int32) {
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { return }
        lock.lock(); defer { lock.unlock() }
        modes[role] = info.st_mode & 0o777
    }

    func mode(for role: HistoryPersistenceFileRole) -> mode_t? {
        lock.lock(); defer { lock.unlock() }
        return modes[role]
    }
}

private final class POSIXRetryController: @unchecked Sendable {
    private let lock = NSLock()
    private var armed = false
    private var writes = 0
    private var shortWrite = false
    private var stagingSyncs = 0
    private var exclusiveAttempts = 0
    private var failedExclusiveAttempts = 0
    private var successfulExclusiveAttempts = 0
    private var successfulExplicitUnlocks = 0
    private var exclusiveLockAcquired = false
    private var exclusiveAcquiredBeforeFirstWrite = false

    func resetAndArmCommitEpoch() {
        lock.lock(); defer { lock.unlock() }
        writes = 0
        shortWrite = false
        stagingSyncs = 0
        exclusiveAttempts = 0
        failedExclusiveAttempts = 0
        successfulExclusiveAttempts = 0
        successfulExplicitUnlocks = 0
        exclusiveLockAcquired = false
        exclusiveAcquiredBeforeFirstWrite = false
        armed = true
    }

    func write(
        descriptor: Int32,
        pointer: UnsafeRawPointer?,
        count: Int
    ) -> Int {
        lock.lock()
        guard armed else {
            lock.unlock()
            return Darwin.write(descriptor, pointer, count)
        }
        writes += 1
        let call = writes
        if call == 1 {
            exclusiveAcquiredBeforeFirstWrite = exclusiveLockAcquired
        }
        if call == 2 { shortWrite = true }
        lock.unlock()
        if call == 1 {
            errno = EINTR
            return -1
        }
        let requested = call == 2 ? min(7, count) : count
        return Darwin.write(descriptor, pointer, requested)
    }

    func fsync(descriptor: Int32, role: HistoryPersistenceFileRole) -> Int32 {
        lock.lock()
        let shouldInject = armed && role == .staging
        guard shouldInject else {
            lock.unlock()
            return Darwin.fsync(descriptor)
        }
        stagingSyncs += 1
        let call = stagingSyncs
        lock.unlock()
        if call == 1 {
            errno = EINTR
            return -1
        }
        return Darwin.fsync(descriptor)
    }

    func flock(descriptor: Int32, operation: Int32) -> Int32 {
        if (operation & LOCK_UN) != 0 {
            let result = systemFlock(descriptor, operation)
            if result == 0 {
                lock.lock()
                successfulExplicitUnlocks += 1
                exclusiveLockAcquired = false
                lock.unlock()
            }
            return result
        }
        lock.lock()
        let shouldInject = armed && (operation & LOCK_EX) != 0
        guard shouldInject else {
            lock.unlock()
            return systemFlock(descriptor, operation)
        }
        exclusiveAttempts += 1
        let call = exclusiveAttempts
        lock.unlock()
        if call == 1 {
            lock.lock()
            failedExclusiveAttempts += 1
            lock.unlock()
            errno = EINTR
            return -1
        }
        let result = systemFlock(descriptor, operation)
        if result == 0 {
            lock.lock()
            successfulExclusiveAttempts += 1
            exclusiveLockAcquired = true
            lock.unlock()
        }
        return result
    }

    var writeCallCount: Int {
        lock.lock(); defer { lock.unlock() }
        return writes
    }

    var didPerformShortWrite: Bool {
        lock.lock(); defer { lock.unlock() }
        return shortWrite
    }

    var stagingFsyncCallCount: Int {
        lock.lock(); defer { lock.unlock() }
        return stagingSyncs
    }

    var exclusiveFlockAttemptCount: Int {
        lock.lock(); defer { lock.unlock() }
        return exclusiveAttempts
    }

    var failedExclusiveFlockAttemptCount: Int {
        lock.lock(); defer { lock.unlock() }
        return failedExclusiveAttempts
    }

    var successfulExclusiveFlockAttemptCount: Int {
        lock.lock(); defer { lock.unlock() }
        return successfulExclusiveAttempts
    }

    var didAcquireExclusiveLockBeforeFirstWrite: Bool {
        lock.lock(); defer { lock.unlock() }
        return exclusiveAcquiredBeforeFirstWrite
    }

    var successfulExplicitUnlockCount: Int {
        lock.lock(); defer { lock.unlock() }
        return successfulExplicitUnlocks
    }

    var isExclusiveLockMarkedAcquired: Bool {
        lock.lock(); defer { lock.unlock() }
        return exclusiveLockAcquired
    }
}

private final class POSIXReadRetryController: @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    private var injectedEINTR = false
    private var shortRead = false

    func read(
        descriptor: Int32,
        pointer: UnsafeMutableRawPointer?,
        count: Int
    ) -> Int {
        lock.lock()
        calls += 1
        let call = calls
        if call == 1 { injectedEINTR = true }
        if call == 2 { shortRead = true }
        lock.unlock()
        if call == 1 {
            errno = EINTR
            return -1
        }
        let requested = call == 2 ? max(1, min(7, count)) : count
        return Darwin.read(descriptor, pointer, requested)
    }

    var callCount: Int {
        lock.lock(); defer { lock.unlock() }
        return calls
    }

    var didInjectEINTR: Bool {
        lock.lock(); defer { lock.unlock() }
        return injectedEINTR
    }

    var didPerformShortRead: Bool {
        lock.lock(); defer { lock.unlock() }
        return shortRead
    }
}

private final class SameSizeReadMutationController: @unchecked Sendable {
    private let archiveURL: URL
    private let lock = NSLock()
    private var mutated = false

    init(archiveURL: URL) {
        self.archiveURL = archiveURL
    }

    func read(
        descriptor: Int32,
        pointer: UnsafeMutableRawPointer?,
        count: Int
    ) -> Int {
        let requested = max(1, min(7, count))
        let amount = Darwin.read(descriptor, pointer, requested)
        guard amount > 0 else { return amount }
        lock.lock()
        let shouldMutate = !mutated
        mutated = true
        lock.unlock()
        if shouldMutate { rewriteOneByteAndMoveTimestamp() }
        return amount
    }

    var didMutate: Bool {
        lock.lock(); defer { lock.unlock() }
        return mutated
    }

    private func rewriteOneByteAndMoveTimestamp() {
        let descriptor = archiveURL.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return Darwin.open(path, O_RDWR | O_CLOEXEC | O_NOFOLLOW)
        }
        guard descriptor >= 0 else { return }
        defer { _ = Darwin.close(descriptor) }
        var byte: UInt8 = 0
        guard Darwin.pread(descriptor, &byte, 1, 0) == 1,
              Darwin.pwrite(descriptor, &byte, 1, 0) == 1 else { return }
        var times = [
            timeval(tv_sec: 1_000_000_000, tv_usec: 0),
            timeval(tv_sec: 1_000_000_000, tv_usec: 0)
        ]
        _ = times.withUnsafeMutableBufferPointer { buffer in
            Darwin.futimes(descriptor, buffer.baseAddress)
        }
        _ = Darwin.fsync(descriptor)
    }
}

private final class StagingInodeSwapController: @unchecked Sendable {
    private let stagingURL: URL
    private let replacementData: Data
    private let lock = NSLock()
    private var replaced = false

    init(stagingURL: URL, replacementData: Data) {
        self.stagingURL = stagingURL
        self.replacementData = replacementData
    }

    func replaceNamedInode(openDescriptor: Int32) {
        lock.lock(); defer { lock.unlock() }
        guard !replaced else { return }
        var opened = stat()
        guard fstat(openDescriptor, &opened) == 0 else { return }
        let unlinked = stagingURL.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return unlink(path)
        }
        guard unlinked == 0,
              (try? replacementData.write(to: stagingURL)) != nil else { return }
        var replacement = stat()
        let inspected = stagingURL.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return lstat(path, &replacement)
        }
        replaced = inspected == 0
            && (opened.st_dev != replacement.st_dev || opened.st_ino != replacement.st_ino)
    }

    var didReplaceWithDifferentInode: Bool {
        lock.lock(); defer { lock.unlock() }
        return replaced
    }
}

private final class ExternalFlockController: @unchecked Sendable {
    let observedContention = DispatchSemaphore(value: 0)
    let allowBlockingLock = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var armed = false
    private var didObserve = false
    private var observedErrno: Int32?

    func arm() {
        lock.lock(); defer { lock.unlock() }
        armed = true
    }

    func flock(descriptor: Int32, operation: Int32) -> Int32 {
        lock.lock()
        let shouldProbe = armed && !didObserve && (operation & LOCK_EX) != 0
        if shouldProbe { didObserve = true }
        lock.unlock()
        guard shouldProbe else { return systemFlock(descriptor, operation) }

        let result = systemFlock(descriptor, operation | LOCK_NB)
        let code = errno
        lock.lock()
        observedErrno = result == -1 ? code : 0
        lock.unlock()
        observedContention.signal()
        _ = allowBlockingLock.wait(timeout: .now() + 10)
        return systemFlock(descriptor, operation)
    }

    var nonblockingErrno: Int32? {
        lock.lock(); defer { lock.unlock() }
        return observedErrno
    }
}

private final class LockedValueBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value

    init(_ value: Value) {
        stored = value
    }

    func set(_ value: Value) {
        lock.lock(); defer { lock.unlock() }
        stored = value
    }

    func withValue(_ body: (inout Value) -> Void) {
        lock.lock(); defer { lock.unlock() }
        body(&stored)
    }

    var value: Value {
        lock.lock(); defer { lock.unlock() }
        return stored
    }
}

private final class WeakObjectProbe: @unchecked Sendable {
    private let lock = NSLock()
    private weak var object: AnyObject?

    func capture(_ object: AnyObject) {
        lock.lock(); defer { lock.unlock() }
        self.object = object
    }

    var isNil: Bool {
        lock.lock(); defer { lock.unlock() }
        return object == nil
    }
}

private final class DifferentArchivePersistenceGate: @unchecked Sendable {
    let entered = DispatchSemaphore(value: 0)
    private let release = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var timedOut = false

    func enterAndWaitForRelease() {
        entered.signal()
        guard release.wait(timeout: .now() + 10) == .success else {
            lock.lock(); defer { lock.unlock() }
            timedOut = true
            return
        }
    }

    func releaseBoth() {
        release.signal()
        release.signal()
    }

    var didTimeOutWaitingForRelease: Bool {
        lock.lock(); defer { lock.unlock() }
        return timedOut
    }
}

private final class ConflictEpochTrashExistence: @unchecked Sendable {
    private let alwaysPresent: URL
    private let postConflictPresent: URL
    private let lock = NSLock()
    private var isPostConflict = false
    private var preConflictProbes: [URL: Int] = [:]
    private var postConflictProbes: [URL: Int] = [:]

    init(alwaysPresent: URL, presentAfterConflict: URL) {
        self.alwaysPresent = alwaysPresent
        postConflictPresent = presentAfterConflict
    }

    func beginPostConflictEpoch() {
        lock.lock(); defer { lock.unlock() }
        isPostConflict = true
    }

    func exists(_ url: URL) -> Bool {
        lock.lock()
        let postConflict = isPostConflict
        if postConflict {
            postConflictProbes[url, default: 0] += 1
        } else {
            preConflictProbes[url, default: 0] += 1
        }
        lock.unlock()
        if url == alwaysPresent { return true }
        return postConflict && url == postConflictPresent
    }

    func preConflictProbeCount(for url: URL) -> Int {
        lock.lock(); defer { lock.unlock() }
        return preConflictProbes[url, default: 0]
    }

    func postConflictProbeCount(for url: URL) -> Int {
        lock.lock(); defer { lock.unlock() }
        return postConflictProbes[url, default: 0]
    }
}

private actor AsyncStartGate {
    private let parties: Int
    private var arrivals = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(parties: Int) {
        precondition(parties > 0)
        self.parties = parties
    }

    func arriveAndWait() async {
        arrivals += 1
        if arrivals == parties {
            let ready = waiters
            waiters.removeAll()
            for waiter in ready { waiter.resume() }
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }
}
