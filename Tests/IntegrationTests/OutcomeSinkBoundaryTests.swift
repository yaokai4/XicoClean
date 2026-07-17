@preconcurrency import Foundation
import XCTest
@testable import Domain
@testable import Infrastructure

final class OutcomeSinkBoundaryTests: XCTestCase {
    func testHistoryWriterReturnsNotRecordedForMutationNone() throws {
        let directory = try makeCaseDirectory("no-mutation")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = HistoryStore(directory: directory)
        let sink: any OutcomeHistoryWriting = store
        let report = try makeReport(facts: [unchangedFact()])

        XCTAssertEqual(
            sink.record(module: "No changes", report: report, date: fixedDate),
            .notRecordedNoChanges)
        XCTAssertEqual(store.totalHistoryRecords, 0)
        XCTAssertEqual(store.totalSuccessfulCleanups, 0)
        XCTAssertTrue(store.recent(10).isEmpty)
    }

    func testHistoryWriterPersistsPartialCancelledAndPossiblyChangedFacts() throws {
        let directory = try makeCaseDirectory("terminal-facts")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = HistoryStore(directory: directory)
        let sink: any OutcomeHistoryWriting = store

        let partial = try makeReport(facts: [
            succeededFact(bytes: 11),
            failedFact(code: "sink.partial.failure")
        ])
        let cancelled = try makeReport(facts: [
            succeededFact(bytes: 22),
            cancelledFact()
        ], cancellationAccepted: true)
        let possiblyChanged = try makeReport(facts: [
            failedFact(
                mutation: .possiblyChanged,
                code: "sink.ambiguous.failure")
        ])

        for (module, report) in [
            ("Partial", partial),
            ("Cancelled", cancelled),
            ("Possibly changed", possiblyChanged)
        ] {
            assertInserted(sink.record(module: module, report: report, date: fixedDate))
        }

        let records = Dictionary(uniqueKeysWithValues: store.recent(10).compactMap { record in
            record.operationID.map { ($0, record) }
        })
        let partialRecord = try XCTUnwrap(records[partial.operation.id])
        XCTAssertEqual(partialRecord.outcomeStatus, .partial)
        XCTAssertEqual(partialRecord.mutation, .changed)
        XCTAssertEqual(partialRecord.counts?.succeeded, 1)
        XCTAssertEqual(partialRecord.counts?.failed, 1)
        XCTAssertEqual(partialRecord.reclaimedBytes, 11)

        let cancelledRecord = try XCTUnwrap(records[cancelled.operation.id])
        XCTAssertEqual(cancelledRecord.outcomeStatus, .cancelled)
        XCTAssertEqual(cancelledRecord.mutation, .changed)
        XCTAssertEqual(cancelledRecord.counts?.succeeded, 1)
        XCTAssertEqual(cancelledRecord.counts?.cancelled, 1)
        XCTAssertEqual(cancelledRecord.reclaimedBytes, 22)

        let ambiguousRecord = try XCTUnwrap(records[possiblyChanged.operation.id])
        XCTAssertEqual(ambiguousRecord.outcomeStatus, .failure)
        XCTAssertEqual(ambiguousRecord.mutation, .possiblyChanged)
        XCTAssertEqual(ambiguousRecord.counts?.failed, 1)
        XCTAssertEqual(ambiguousRecord.reclaimedBytes, 0)

        XCTAssertEqual(store.totalHistoryRecords, 3)
        XCTAssertEqual(store.totalSuccessfulCleanups, 0,
                       "Partial, cancelled and failed facts must never inflate success totals")
    }

    func testValidatedCleaningNotificationOnlyAcceptsChangedFullSuccess() throws {
        let accepted = try makeReport(facts: [succeededFact(bytes: 64)])
        let unchanged = try makeReport(facts: [unchangedFact()])
        let partial = try makeReport(facts: [
            succeededFact(bytes: 1),
            failedFact(code: "notification.partial")
        ])
        let failed = try makeReport(facts: [failedFact(code: "notification.failed")])
        let cancelled = try makeReport(
            facts: [cancelledFact()],
            cancellationAccepted: true)
        let possiblyChangedSuccess = try makeReport(facts: [
            succeededFact(bytes: 1, mutation: .possiblyChanged)
        ])
        let invariant = try makeReport(
            facts: [succeededFact(bytes: 1)],
            requestedSubjectIDs: ["missing-request-subject"])

        XCTAssertNotNil(ValidatedCleaningNotification(report: accepted))
        for rejected in [
            unchanged,
            partial,
            failed,
            cancelled,
            possiblyChangedSuccess,
            invariant
        ] {
            XCTAssertNil(ValidatedCleaningNotification(report: rejected),
                         "Only an invariant-free full changed success is notification-safe")
        }
    }

    func testValidatedCleaningNotificationRejectsShredRemoteAndUnknownKinds() throws {
        let ineligibleKinds: [OperationKind] = [
            .shred,
            .sftpDelete,
            .remoteDisconnect,
            .spaceTrash,
            .uninstall,
            OperationKind("test.unknown.notification-kind")
        ]

        for kind in ineligibleKinds {
            let report = try makeReport(
                kind: kind,
                facts: [succeededFact(bytes: 10)])
            XCTAssertEqual(report.operation.status, .success)
            XCTAssertEqual(report.operation.mutation, .changed)
            XCTAssertNil(ValidatedCleaningNotification(report: report),
                         "\(kind.rawValue) must fail closed at notification validation")
        }
    }

    func testValidatedCleaningNotificationDerivesMetricsFromClosedReport() throws {
        let report = try makeReport(facts: [
            succeededFact(bytes: 40),
            unchangedFact(),
            succeededFact(bytes: 2)
        ])

        let request = try XCTUnwrap(ValidatedCleaningNotification(report: report))

        XCTAssertEqual(request.operationID, report.operation.id)
        XCTAssertEqual(request.reclaimedBytes, 42)
        XCTAssertEqual(request.reclaimedBytes, report.reclaimedBytes)
        XCTAssertEqual(request.changedCount, 2)
        XCTAssertEqual(request.changedCount, report.operation.counts.succeeded)
    }

    func testCompoundCleaningNotificationCountsOnlySuccessfulDeletions() throws {
        let report = try makeCompoundReport(
            deletionDisposition: .succeeded,
            deletionMutation: .changed,
            deletionBytes: 64,
            remediationDisposition: .succeeded,
            remediationMutation: .changed)

        XCTAssertEqual(report.operation.status, .success)
        XCTAssertEqual(report.operation.counts.succeeded, 2,
                       "The parent reducer must consume deletion and remediation facts")
        XCTAssertEqual(report.removedCount, 1)
        let request = try XCTUnwrap(ValidatedCleaningNotification(report: report))
        XCTAssertEqual(request.changedCount, 1,
                       "A successful bootout is not a removed filesystem item")
        XCTAssertEqual(request.reclaimedBytes, 64)
    }

    func testCompoundPartialCleaningNeverProducesSuccessNotification() throws {
        let remediationID = UUID()
        let remediationIssue = OperationIssue(
            code: "threat.remediation.postconditionUnknown",
            category: .io,
            subjectID: remediationID.uuidString,
            recovery: .retry,
            retryable: true)
        let report = try makeCompoundReport(
            remediationID: remediationID,
            deletionDisposition: .succeeded,
            deletionMutation: .changed,
            deletionBytes: 64,
            remediationDisposition: .failed(remediationIssue),
            remediationMutation: .possiblyChanged)

        XCTAssertEqual(report.operation.status, .partial)
        XCTAssertEqual(report.removedCount, 1)
        XCTAssertNil(ValidatedCleaningNotification(report: report),
                     "A deleted plist whose live agent may remain active is not full success")
    }

    func testCleaningNotifierFormatsInternallyAndSendsEachOperationIDOnce() throws {
        let report = try makeReport(facts: [succeededFact(bytes: 1_536)])
        let request = try XCTUnwrap(ValidatedCleaningNotification(report: report))
        let deliveries = LockedBox<[(reclaimed: String, count: Int, identifier: String)]>([])
        let notifier: any CleaningNotificationSending = Notifier { reclaimed, count, identifier in
            deliveries.set(deliveries.value + [(reclaimed, count, identifier)])
        }

        notifier.send(request)
        notifier.send(request)

        XCTAssertEqual(deliveries.value.count, 1)
        let delivery = try XCTUnwrap(deliveries.value.first)
        XCTAssertEqual(delivery.reclaimed, report.reclaimedBytes.formattedBytes)
        XCTAssertEqual(delivery.count, report.operation.counts.succeeded)
        XCTAssertTrue(delivery.identifier.contains(report.operation.id.uuidString.lowercased()))
    }

    func testCleaningNotifierKeepsItsInMemoryIdempotencyLedgerBounded() throws {
        let deliveries = LockedBox<[String]>([])
        let notifier = Notifier { _, _, identifier in
            deliveries.set(deliveries.value + [identifier])
        }
        var firstRequest: ValidatedCleaningNotification?

        for _ in 0...Notifier.maximumRememberedOperationIDs {
            let report = try makeReport(facts: [succeededFact(bytes: 1)])
            let request = try XCTUnwrap(ValidatedCleaningNotification(report: report))
            firstRequest = firstRequest ?? request
            notifier.send(request)
        }
        let countAfterUniqueOperations = deliveries.value.count
        notifier.send(try XCTUnwrap(firstRequest))

        XCTAssertEqual(
            countAfterUniqueOperations,
            Notifier.maximumRememberedOperationIDs + 1)
        XCTAssertEqual(deliveries.value.count, countAfterUniqueOperations + 1)
        XCTAssertEqual(Set(deliveries.value).count, countAfterUniqueOperations,
                       "Deterministic system identifiers still replace an evicted notification")
    }

    func testCleaningNotifierConcurrentDuplicateDeliveryOccursExactlyOnce() throws {
        let report = try makeReport(facts: [succeededFact(bytes: 2)])
        let request = try XCTUnwrap(ValidatedCleaningNotification(report: report))
        let deliveryCount = LockedBox(0)
        let notifier = Notifier { _, _, _ in
            deliveryCount.withValue { $0 += 1 }
        }

        DispatchQueue.concurrentPerform(iterations: 64) { _ in
            notifier.send(request)
        }

        XCTAssertEqual(deliveryCount.value, 1)
    }

    func testInvalidationRequestRequiresMutationAndNonEmptyRegisteredDomains() throws {
        let changed = try makeOutcome(
            kind: .cleaningExecute,
            facts: [succeededFact(bytes: 1)])
        let possiblyChanged = try makeOutcome(
            kind: .sftpDelete,
            facts: [failedFact(
                mutation: .possiblyChanged,
                code: "invalidation.ambiguous")])
        let unchanged = try makeOutcome(
            kind: .cleaningExecute,
            facts: [unchangedFact()])
        let unknown = try makeOutcome(
            kind: OperationKind("test.unknown.invalidation-kind"),
            facts: [succeededFact(bytes: 1)])

        XCTAssertNotNil(ValidatedOutcomeInvalidation(
            outcome: changed,
            domains: [.diskCapacity, .scanIndex]))
        XCTAssertNotNil(ValidatedOutcomeInvalidation(
            outcome: possiblyChanged,
            domains: [.remoteDirectory]))
        XCTAssertNil(ValidatedOutcomeInvalidation(
            outcome: unchanged,
            domains: [.diskCapacity]))
        XCTAssertNil(ValidatedOutcomeInvalidation(
            outcome: changed,
            domains: []))
        XCTAssertNil(ValidatedOutcomeInvalidation(
            outcome: unknown,
            domains: [.diskCapacity]))
    }

    func testInvalidationRequestRejectsDomainsOutsideRegisteredKindSemantics() throws {
        let cleaning = try makeOutcome(
            kind: .cleaningExecute,
            facts: [succeededFact(bytes: 1)])
        let tunnel = try makeOutcome(
            kind: .tunnelDelete,
            facts: [succeededFact(bytes: 1)])

        XCTAssertNotNil(ValidatedOutcomeInvalidation(
            outcome: cleaning,
            domains: [.scanIndex]))
        XCTAssertNil(ValidatedOutcomeInvalidation(
            outcome: cleaning,
            domains: [.diskCapacity, .license]))
        XCTAssertNotNil(ValidatedOutcomeInvalidation(
            outcome: tunnel,
            domains: [.tunnels, .serverConfiguration]))
        XCTAssertNil(ValidatedOutcomeInvalidation(
            outcome: tunnel,
            domains: [.remoteDirectory]))
    }

    func testInvalidationCenterPublishesEachOperationIDOnceUnderConcurrency() throws {
        let outcome = try makeOutcome(
            kind: .cleaningExecute,
            facts: [succeededFact(bytes: 1)])
        let request = try XCTUnwrap(ValidatedOutcomeInvalidation(
            outcome: outcome,
            domains: [.diskCapacity]))
        let notificationCenter = NotificationCenter()
        let publicationCount = LockedBox(0)
        let token = notificationCenter.addObserver(
            forName: .xicoOutcomeInvalidated,
            object: nil,
            queue: nil
        ) { _ in
            publicationCount.withValue { $0 += 1 }
        }
        defer { notificationCenter.removeObserver(token) }
        let center = OutcomeInvalidationCenter(center: notificationCenter)

        DispatchQueue.concurrentPerform(iterations: 64) { _ in
            _ = center.publish(request)
        }

        XCTAssertEqual(publicationCount.value, 1)
    }

    func testInvalidationCenterKeepsItsIdempotencyLedgerBounded() throws {
        let notificationCenter = NotificationCenter()
        let publicationCount = LockedBox(0)
        let token = notificationCenter.addObserver(
            forName: .xicoOutcomeInvalidated,
            object: nil,
            queue: nil
        ) { _ in
            publicationCount.withValue { $0 += 1 }
        }
        defer { notificationCenter.removeObserver(token) }
        let center = OutcomeInvalidationCenter(center: notificationCenter)
        var firstRequest: ValidatedOutcomeInvalidation?

        for _ in 0...OutcomeInvalidationCenter.maximumRememberedOperationIDs {
            let outcome = try makeOutcome(
                kind: .cleaningExecute,
                facts: [succeededFact(bytes: 1)])
            let request = try XCTUnwrap(ValidatedOutcomeInvalidation(
                outcome: outcome,
                domains: [.diskCapacity]))
            firstRequest = firstRequest ?? request
            XCTAssertEqual(center.publish(request), .published)
        }
        let countAfterUniqueOperations = publicationCount.value
        XCTAssertEqual(center.publish(try XCTUnwrap(firstRequest)), .published)

        XCTAssertEqual(
            countAfterUniqueOperations,
            OutcomeInvalidationCenter.maximumRememberedOperationIDs + 1)
        XCTAssertEqual(publicationCount.value, countAfterUniqueOperations + 1)
    }

    func testExternalInvalidationFakeCanConformToPublicProtocol() throws {
        let result = try compileInfrastructureExternalClient("""
        import Foundation
        import Domain
        import Infrastructure

        struct ExternalInvalidationFake: OutcomeInvalidationPublishing {
            func publish(
                _ request: ValidatedOutcomeInvalidation
            ) -> OutcomeInvalidationPublishResult {
                _ = request.outcome.id
                _ = request.domains
                return .published
            }
        }

        struct ExternalNotificationFake: CleaningNotificationSending {
            func send(_ request: ValidatedCleaningNotification) {
                _ = request.operationID
                _ = request.reclaimedBytes
                _ = request.changedCount
            }
        }

        struct ExternalHistoryFake: OutcomeHistoryWriting {
            func record(
                module: String,
                report: CleaningReport,
                date: Date
            ) -> HistoryRecordResult {
                .notRecordedNoChanges
            }

            func record(
                module: String,
                result: OperationResult<ShredderPayload>,
                date: Date
            ) -> HistoryRecordResult {
                .notRecordedNoChanges
            }

            func remove(id: UUID) -> HistoryUpdateResult { .notFound }

            func updateRestorable(
                id: UUID,
                to items: [RestorableItem]
            ) -> HistoryUpdateResult {
                .notFound
            }
        }

        func consume(event: OutcomeInvalidationEvent) {
            _ = event.operationID
            _ = event.kind
            _ = event.status
            _ = event.mutation
            _ = event.domains
            _ = Notification.Name.xicoOutcomeInvalidated
        }

        func buildEnvironment(
            fs: FileSystemService,
            safety: SafetyEngine,
            definitions: DefinitionsLibrary,
            license: LicenseService,
            history: HistoryStore,
            historySink: any OutcomeHistoryWriting,
            notifier: any CleaningNotificationSending,
            invalidation: any OutcomeInvalidationPublishing
        ) -> XicoEnvironment {
            let environment = XicoEnvironment(
                fs: fs,
                safety: safety,
                definitions: definitions,
                license: license,
                history: history,
                historySink: historySink,
                cleaningNotifier: notifier,
                invalidationSink: invalidation)
            _ = environment.history
            _ = environment.historySink
            _ = environment.cleaningNotifier
            _ = environment.invalidationSink
            return environment
        }

        _ = ExternalInvalidationFake()
        _ = ExternalNotificationFake()
        _ = ExternalHistoryFake()
        """)

        XCTAssertEqual(result.status, 0, result.diagnostics)
        assertNoModuleLoadFailure(result)
    }

    func testHistoryRecordIsIdempotentByOperationID() throws {
        let directory = try makeCaseDirectory("idempotent")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = HistoryStore(directory: directory)
        let sink: any OutcomeHistoryWriting = store
        let report = try makeReport(facts: [succeededFact(bytes: 99)])

        let first = sink.record(module: "Idempotent", report: report, date: fixedDate)
        let second = sink.record(module: "Idempotent", report: report, date: fixedDate)
        let firstID = try insertedRecordID(first)

        XCTAssertEqual(second, .alreadyRecorded(recordID: firstID))
        XCTAssertEqual(store.totalHistoryRecords, 1)
        XCTAssertEqual(store.totalSuccessfulCleanups, 1)
        XCTAssertEqual(store.totalReclaimedAllTime, 99)
        XCTAssertEqual(store.recent(10).map(\.operationID), [report.operation.id])
    }

    func testInvalidationEventDoesNotMasqueradeAsUserNotification() throws {
        let secret = "/Users/private/.ssh/id_ed25519 host=internal token=do-not-publish"
        let outcome = try makeOutcome(
            kind: .sftpDelete,
            facts: [failedFact(
                mutation: .possiblyChanged,
                code: secret)])
        let request = try XCTUnwrap(ValidatedOutcomeInvalidation(
            outcome: outcome,
            domains: [.remoteDirectory]))
        let notificationCenter = NotificationCenter()
        let received = LockedBox<Notification?>(nil)
        let token = notificationCenter.addObserver(
            forName: .xicoOutcomeInvalidated,
            object: nil,
            queue: nil
        ) { notification in
            received.set(notification)
        }
        defer { notificationCenter.removeObserver(token) }
        let center = OutcomeInvalidationCenter(center: notificationCenter)

        XCTAssertEqual(center.publish(request), .published)

        let notification = try XCTUnwrap(received.value)
        let event = try XCTUnwrap(notification.object as? OutcomeInvalidationEvent)
        XCTAssertEqual(notification.name, .xicoOutcomeInvalidated)
        XCTAssertNil(notification.userInfo,
                     "Internal invalidation is a typed refresh event, not user-facing copy")
        XCTAssertEqual(event.operationID, outcome.id)
        XCTAssertEqual(event.kind, .sftpDelete)
        XCTAssertEqual(event.status, .failure)
        XCTAssertEqual(event.mutation, .possiblyChanged)
        XCTAssertEqual(event.domains, [.remoteDirectory])
        let eventFields = Set(Mirror(reflecting: event).children.compactMap(\.label))
        XCTAssertTrue(
            Set(["operationID", "kind", "status", "mutation", "domains"])
                .isSubset(of: eventFields))
        XCTAssertTrue(
            eventFields.isDisjoint(with: [
                "outcome", "issues", "message", "title", "body", "path", "url",
                "command", "endpoint", "credentials", "error"
            ]),
            "The event may carry refresh metadata but must not retain private/user-facing facts")
        XCTAssertFalse(String(reflecting: event).contains(secret))
    }

    func testShredHistoryWriterPersistsFactsWithoutPersistingURLs() throws {
        let directory = try makeCaseDirectory("shred-privacy")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = HistoryStore(directory: directory)
        let sink: any OutcomeHistoryWriting = store
        let succeededID = UUID()
        let failedID = UUID()
        let issue = OperationIssue(
            code: "shred.remove.ambiguous",
            category: .io,
            subjectID: failedID.uuidString,
            recovery: .retry,
            retryable: true)
        let itemFacts = [
            OperationItemOutcome(
                subjectID: succeededID.uuidString,
                disposition: .succeeded,
                mutation: .changed,
                affectedBytes: 512),
            OperationItemOutcome(
                subjectID: failedID.uuidString,
                disposition: .failed(issue),
                mutation: .possiblyChanged)
        ]
        let outcome = try OperationOutcomeReducer.reduce(
            kind: .shred,
            requestedSubjectIDs: itemFacts.map(\.subjectID),
            itemOutcomes: itemFacts,
            cancellationAccepted: false,
            startedAt: fixedDate,
            finishedAt: fixedDate.addingTimeInterval(1))
        let secretSucceededURL = URL(
            fileURLWithPath: "/Users/private/.ssh/secret-source-key")
        let secretFailedURL = URL(
            fileURLWithPath: "/Volumes/private/remote-secret-source")
        let payload = ShredderPayload(items: [
            ShredderItemResult(
                requestID: succeededID,
                url: secretSucceededURL,
                disposition: .succeeded,
                mutation: .changed,
                freedBytes: 512),
            ShredderItemResult(
                requestID: failedID,
                url: secretFailedURL,
                disposition: .failed(issue),
                mutation: .possiblyChanged,
                freedBytes: 0)
        ])
        let result = OperationResult(outcome: outcome, payload: payload)

        assertInserted(sink.record(module: "Shredder", result: result, date: fixedDate))

        let record = try XCTUnwrap(store.recent(1).first)
        XCTAssertEqual(record.operationID, outcome.id)
        XCTAssertEqual(record.operationKind, .shred)
        XCTAssertEqual(record.outcomeStatus, .partial)
        XCTAssertEqual(record.mutation, .possiblyChanged)
        XCTAssertEqual(record.reclaimedBytes, 512)
        XCTAssertEqual(record.itemFacts.count, 2)
        XCTAssertTrue(record.itemFacts.allSatisfy { $0.intent == .permanent })
        XCTAssertTrue(record.restorable.isEmpty)

        let archive = String(
            decoding: try Data(contentsOf: directory.appendingPathComponent("history.json")),
            as: UTF8.self)
        XCTAssertFalse(archive.contains(secretSucceededURL.path))
        XCTAssertFalse(archive.contains(secretFailedURL.path))
        XCTAssertFalse(archive.contains("secret-source"))
    }

    private let fixedDate = Date(timeIntervalSinceReferenceDate: 10_000)

    private struct CleaningFact {
        let requestID: UUID
        let itemID: UUID
        let url: URL
        let intent: DeleteIntent
        let disposition: OperationDisposition
        let mutation: OperationMutationFact
        let affectedBytes: Int64
        let receipt: RestorableItem?
    }

    private struct ExternalCompileResult {
        let status: Int32
        let standardOutput: String
        let standardError: String
        var diagnostics: String { standardOutput + standardError }
    }

    private func succeededFact(
        bytes: Int64,
        mutation: OperationMutationFact = .changed
    ) -> CleaningFact {
        let requestID = UUID()
        return CleaningFact(
            requestID: requestID,
            itemID: UUID(),
            url: URL(fileURLWithPath: "/tmp/outcome-sink-\(requestID.uuidString)"),
            intent: .trash,
            disposition: .succeeded,
            mutation: mutation,
            affectedBytes: bytes,
            receipt: nil)
    }

    private func unchangedFact() -> CleaningFact {
        let requestID = UUID()
        return CleaningFact(
            requestID: requestID,
            itemID: UUID(),
            url: URL(fileURLWithPath: "/tmp/outcome-sink-\(requestID.uuidString)"),
            intent: .trash,
            disposition: .unchanged,
            mutation: .none,
            affectedBytes: 0,
            receipt: nil)
    }

    private func failedFact(
        mutation: OperationMutationFact = .none,
        code: String
    ) -> CleaningFact {
        let requestID = UUID()
        let issue = OperationIssue(
            code: code,
            category: .io,
            subjectID: requestID.uuidString,
            recovery: .retry,
            retryable: true)
        return CleaningFact(
            requestID: requestID,
            itemID: UUID(),
            url: URL(fileURLWithPath: "/tmp/outcome-sink-\(requestID.uuidString)"),
            intent: .trash,
            disposition: .failed(issue),
            mutation: mutation,
            affectedBytes: 0,
            receipt: nil)
    }

    private func cancelledFact() -> CleaningFact {
        let requestID = UUID()
        return CleaningFact(
            requestID: requestID,
            itemID: UUID(),
            url: URL(fileURLWithPath: "/tmp/outcome-sink-\(requestID.uuidString)"),
            intent: .trash,
            disposition: .cancelled(nil),
            mutation: .none,
            affectedBytes: 0,
            receipt: nil)
    }

    private func makeReport(
        kind: OperationKind = .cleaningExecute,
        facts: [CleaningFact],
        cancellationAccepted: Bool = false,
        requestedSubjectIDs: [String]? = nil
    ) throws -> CleaningReport {
        let outcome = try makeOutcome(
            kind: kind,
            facts: facts,
            cancellationAccepted: cancellationAccepted,
            requestedSubjectIDs: requestedSubjectIDs)
        return CleaningReport(
            operation: outcome,
            items: facts.map {
                CleaningItemResult(
                    requestID: $0.requestID,
                    itemID: $0.itemID,
                    url: $0.url,
                    intent: $0.intent,
                    disposition: $0.disposition,
                    mutation: $0.mutation,
                    reclaimedBytes: $0.affectedBytes,
                    restorable: $0.receipt)
            })
    }

    private func makeOutcome(
        kind: OperationKind,
        facts: [CleaningFact],
        cancellationAccepted: Bool = false,
        requestedSubjectIDs: [String]? = nil
    ) throws -> OperationOutcome {
        try OperationOutcomeReducer.reduce(
            kind: kind,
            requestedSubjectIDs: requestedSubjectIDs ?? facts.map {
                $0.requestID.uuidString
            },
            itemOutcomes: facts.map {
                OperationItemOutcome(
                    subjectID: $0.requestID.uuidString,
                    disposition: $0.disposition,
                    mutation: $0.mutation,
                    affectedBytes: $0.affectedBytes)
            },
            cancellationAccepted: cancellationAccepted,
            startedAt: fixedDate,
            finishedAt: fixedDate.addingTimeInterval(1))
    }

    private func makeCompoundReport(
        deletionID: UUID = UUID(),
        remediationID: UUID = UUID(),
        deletionDisposition: OperationDisposition,
        deletionMutation: OperationMutationFact,
        deletionBytes: Int64,
        remediationDisposition: OperationDisposition,
        remediationMutation: OperationMutationFact
    ) throws -> CleaningReport {
        let deletion = CleaningItemResult(
            requestID: deletionID,
            itemID: UUID(),
            url: URL(fileURLWithPath: "/tmp/private-compound-plist"),
            intent: .trash,
            disposition: deletionDisposition,
            mutation: deletionMutation,
            reclaimedBytes: deletionBytes,
            restorable: nil)
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
            startedAt: fixedDate,
            finishedAt: fixedDate.addingTimeInterval(1))
        return CleaningReport(operation: outcome, facts: facts)
    }

    private func makeCaseDirectory(_ label: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "xico-outcome-sink-\(label)-\(UUID().uuidString)",
            isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false)
        return directory
    }

    private func assertInserted(
        _ result: HistoryRecordResult,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case .inserted = result else {
            XCTFail("Expected inserted history result, got \(result)", file: file, line: line)
            return
        }
    }

    private func insertedRecordID(
        _ result: HistoryRecordResult,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> UUID {
        guard case let .inserted(recordID) = result else {
            XCTFail("Expected inserted history result, got \(result)", file: file, line: line)
            throw TestError.unexpectedHistoryResult
        }
        return recordID
    }

    private func compileInfrastructureExternalClient(
        _ source: String
    ) throws -> ExternalCompileResult {
        let fileManager = FileManager.default
        let temporaryURL = fileManager.temporaryDirectory.appendingPathComponent(
            "XicoOutcomeSinkClient-\(UUID().uuidString)",
            isDirectory: true)
        try fileManager.createDirectory(
            at: temporaryURL,
            withIntermediateDirectories: false)
        defer { try? fileManager.removeItem(at: temporaryURL) }

        let sourceURL = temporaryURL.appendingPathComponent("client.swift")
        let moduleCacheURL = temporaryURL.appendingPathComponent(
            "module-cache",
            isDirectory: true)
        try fileManager.createDirectory(
            at: moduleCacheURL,
            withIntermediateDirectories: false)
        try source.write(to: sourceURL, atomically: true, encoding: .utf8)

        let modulesURL = try debugInfrastructureModulesDirectory()
        let debugURL = modulesURL.deletingLastPathComponent()
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
        var arguments = [
            "swiftc",
            "-typecheck",
            "-warnings-as-errors",
            "-module-cache-path", moduleCacheURL.path,
            "-I", modulesURL.path
        ]
        for moduleMap in moduleMaps {
            arguments.append("-Xcc")
            arguments.append("-fmodule-map-file=\(moduleMap.path)")
        }
        arguments.append(sourceURL.path)
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = error
        defer {
            if process.isRunning {
                process.terminate()
                process.waitUntilExit()
            }
        }

        try process.run()
        process.waitUntilExit()
        try output.synchronize()
        try error.synchronize()
        try output.close()
        try error.close()

        return ExternalCompileResult(
            status: process.terminationStatus,
            standardOutput: String(
                decoding: try Data(contentsOf: outputURL),
                as: UTF8.self),
            standardError: String(
                decoding: try Data(contentsOf: errorURL),
                as: UTF8.self))
    }

    private func assertNoModuleLoadFailure(
        _ result: ExternalCompileResult,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertFalse(
            result.standardError.localizedCaseInsensitiveContains("no such module"),
            result.diagnostics,
            file: file,
            line: line)
        XCTAssertFalse(
            result.standardError.localizedCaseInsensitiveContains("missing required module"),
            result.diagnostics,
            file: file,
            line: line)
    }

    private func debugInfrastructureModulesDirectory() throws -> URL {
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
            guard candidate.lastPathComponent == "Infrastructure.swiftmodule" else {
                continue
            }
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
        return try XCTUnwrap(
            candidates.sorted { $0.path < $1.path }.first,
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

    private enum TestError: Error {
        case unexpectedHistoryResult
    }
}

private final class LockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value

    init(_ value: Value) {
        stored = value
    }

    var value: Value {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    func set(_ value: Value) {
        lock.lock()
        stored = value
        lock.unlock()
    }

    func withValue(_ body: (inout Value) -> Void) {
        lock.lock()
        body(&stored)
        lock.unlock()
    }
}
