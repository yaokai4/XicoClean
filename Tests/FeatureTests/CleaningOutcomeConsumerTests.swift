import Foundation
import XCTest
@testable import Domain
@testable import Infrastructure
@testable import Features

final class CleaningOutcomeConsumerTests: XCTestCase {
    private let startedAt = Date(timeIntervalSince1970: 100)
    private let finishedAt = Date(timeIntervalSince1970: 101)

    func testPartialCleaningRemovesOnlySucceededAndUnchangedSelectionOccurrencesEvenWhenItemIDsRepeat() async throws {
        let duplicateCallerID = UUID()
        let receipt = RestorableItem(
            originalURL: URL(fileURLWithPath: "/tmp/original-a"),
            trashedURL: URL(fileURLWithPath: "/tmp/trashed-a"))
        let retryIssue = issue("cleaning.retry", retryable: true)
        let facts: [CleaningOperationFact] = [
            .deletion(deletion(
                itemID: duplicateCallerID,
                disposition: .succeeded,
                mutation: .changed,
                bytes: 12,
                restorable: receipt)),
            .deletion(deletion(
                itemID: UUID(),
                disposition: .unchanged,
                mutation: .none)),
            .deletion(deletion(
                itemID: duplicateCallerID,
                disposition: .failed(retryIssue),
                mutation: .none,
                authorizedRetry: true)),
        ]
        let report = try report(facts: facts)
        let harness = makeHarness()

        let consumed = await harness.consumer.consume(
            module: "Cleaner",
            report: report,
            selectionOccurrenceCount: 3,
            detailKey: "部分完成",
            date: finishedAt)

        XCTAssertTrue(consumed.isTrusted)
        XCTAssertEqual(consumed.selectionMutation.removableOccurrenceIndices, [0, 1])
        XCTAssertEqual(
            consumed.selectionMutation.applying(to: ["first", "second", "third"]),
            ["third"])
        XCTAssertEqual(consumed.undoReceipts, [receipt])
        XCTAssertEqual(consumed.retryableRemainder.map(\.requestID), [facts[2].requestID])
        guard case let .deletion(occurrenceIndex, _, item) = consumed.retryableRemainder[0] else {
            return XCTFail("Expected the failed third deletion occurrence")
        }
        XCTAssertEqual(occurrenceIndex, 2)
        XCTAssertEqual(item.itemID, duplicateCallerID)
    }

    func testPartialCleaningRecordsPartialButDoesNotNotifyOrCelebrate() async throws {
        let report = try self.report(facts: [
            .deletion(deletion(
                disposition: .succeeded,
                mutation: .changed,
                bytes: 42,
                restorable: RestorableItem(
                    originalURL: URL(fileURLWithPath: "/tmp/original"),
                    trashedURL: URL(fileURLWithPath: "/tmp/trashed")))),
            .deletion(deletion(
                disposition: .failed(issue("cleaning.failed", retryable: true)),
                mutation: .none)),
        ])
        XCTAssertEqual(report.operation.status, .partial)
        let harness = makeHarness()

        let consumed = await harness.consumer.consume(
            module: "Cleaner",
            report: report,
            selectionOccurrenceCount: 2,
            detailKey: "部分完成",
            date: finishedAt)
        let grant = try XCTUnwrap(consumed.presentationAuthorization.take(
            expectedOperationID: report.operation.id))

        XCTAssertEqual(harness.history.cleaningStatuses, [.partial])
        XCTAssertEqual(consumed.historyResult, harness.history.insertResult)
        XCTAssertEqual(harness.notifier.requests.count, 0)
        XCTAssertFalse(consumed.didSendNotification)
        XCTAssertFalse(grant.celebration)
        XCTAssertFalse(grant.successSoundHaptic)
        XCTAssertTrue(grant.accessibilityAnnouncement)
        XCTAssertEqual(harness.invalidation.requests.count, 1)
        XCTAssertEqual(
            harness.invalidation.requests.first?.outcome.id,
            report.operation.id)
    }

    func testCancelledCleaningKeepsCompletedReceiptsAndRetryableRemainderInFactOrder() async throws {
        let completedRequestID = UUID()
        let remediationRequestID = UUID()
        let pendingRequestID = UUID()
        let receipt = RestorableItem(
            originalURL: URL(fileURLWithPath: "/tmp/completed"),
            trashedURL: URL(fileURLWithPath: "/tmp/completed-trash"))
        let remediationIssue = issue("threat.bootout.failed", retryable: true)
        let facts: [CleaningOperationFact] = [
            .deletion(deletion(
                requestID: completedRequestID,
                disposition: .succeeded,
                mutation: .changed,
                bytes: 8,
                restorable: receipt)),
            .auxiliary(CleaningAuxiliaryItemResult(
                requestID: remediationRequestID,
                relatedCleaningRequestID: completedRequestID,
                kind: .threatRemediation,
                disposition: .failed(remediationIssue),
                mutation: .none,
                retryToken: retryToken("cancelled"))),
            .deletion(deletion(
                requestID: pendingRequestID,
                disposition: .cancelled(nil),
                mutation: .none,
                authorizedRetry: true)),
        ]
        let report = try self.report(facts: facts, cancellationAccepted: true)
        let harness = makeHarness()

        let consumed = await harness.consumer.consume(
            module: "Cleaner",
            report: report,
            selectionOccurrenceCount: 2,
            detailKey: "操作已取消",
            date: finishedAt)

        XCTAssertEqual(report.operation.status, .cancelled)
        XCTAssertEqual(consumed.selectionMutation.removableOccurrenceIndices, [0])
        XCTAssertEqual(consumed.selectionMutation.applying(to: ["done", "pending"]), ["pending"])
        XCTAssertEqual(consumed.undoReceipts, [receipt])
        XCTAssertEqual(
            consumed.retryableRemainder.map(\.requestID),
            [remediationRequestID, pendingRequestID])
        guard case let .auxiliary(_, relatedOccurrence, _) = consumed.retryableRemainder[0],
              case let .deletion(pendingOccurrence, _, _) = consumed.retryableRemainder[1] else {
            return XCTFail("Retry facts must preserve auxiliary then deletion fact order")
        }
        XCTAssertEqual(relatedOccurrence, 0)
        XCTAssertEqual(pendingOccurrence, 1)
    }

    func testFailedRemediationAfterSuccessfulDeletionNeverSchedulesDeletionAgain() async throws {
        let deletionRequestID = UUID()
        let remediationRequestID = UUID()
        let report = try self.report(facts: [
            .deletion(deletion(
                requestID: deletionRequestID,
                disposition: .succeeded,
                mutation: .changed,
                bytes: 4,
                restorable: RestorableItem(
                    originalURL: URL(fileURLWithPath: "/tmp/agent.plist"),
                    trashedURL: URL(fileURLWithPath: "/tmp/trash/agent.plist")))),
            .auxiliary(CleaningAuxiliaryItemResult(
                requestID: remediationRequestID,
                relatedCleaningRequestID: deletionRequestID,
                kind: .threatRemediation,
                disposition: .failed(issue("threat.bootout.failed", retryable: true)),
                mutation: .none,
                retryToken: retryToken("bootout"))),
        ])
        let harness = makeHarness()

        let consumed = await harness.consumer.consume(
            module: "Cleaner",
            report: report,
            selectionOccurrenceCount: 1,
            detailKey: "部分完成",
            date: finishedAt)

        XCTAssertEqual(consumed.retryableRemainder.count, 1)
        XCTAssertFalse(consumed.retryableRemainder[0].requiresDeletionExecution)
        guard case let .auxiliary(_, relatedOccurrence, item) = consumed.retryableRemainder[0] else {
            return XCTFail("Only the failed remediation may be retried")
        }
        XCTAssertEqual(relatedOccurrence, 0)
        XCTAssertEqual(item.requestID, remediationRequestID)
        XCTAssertFalse(consumed.retryableRemainder.contains {
            $0.requiresDeletionExecution
        })
    }

    func testRetryableLookingFactsWithoutDomainAuthorityDoNotExposeRetry() async throws {
        let failedDeletionID = UUID()
        let completedDeletionID = UUID()
        let remediationID = UUID()
        let report = try self.report(facts: [
            .deletion(deletion(
                requestID: failedDeletionID,
                disposition: .failed(issue("cleaning.retry", retryable: true)),
                mutation: .none)),
            .deletion(deletion(
                requestID: completedDeletionID,
                disposition: .succeeded,
                mutation: .changed,
                bytes: 1)),
            .auxiliary(CleaningAuxiliaryItemResult(
                requestID: remediationID,
                relatedCleaningRequestID: completedDeletionID,
                kind: .threatRemediation,
                disposition: .failed(issue("threat.retry", retryable: true)),
                mutation: .none,
                retryToken: nil)),
        ])
        let harness = makeHarness()

        let consumed = await harness.consumer.consume(
            module: "Cleaner",
            report: report,
            selectionOccurrenceCount: 2,
            detailKey: "部分完成",
            date: finishedAt)

        XCTAssertTrue(consumed.isTrusted)
        XCTAssertTrue(consumed.retryableRemainder.isEmpty)
        XCTAssertEqual(consumed.presentationContext.retryableSubjectCount, 0)
    }

    func testAuxiliaryOnlyRetryRetainsPriorReceiptAndNeverNotifiesDeletionSuccess() async throws {
        let receipt = RestorableItem(
            originalURL: URL(fileURLWithPath: "/tmp/retry-owner"),
            trashedURL: URL(fileURLWithPath: "/tmp/retry-owner-trash"))
        let deletionID = UUID()
        let remediationID = UUID()
        let report = try self.report(facts: [
            .deletion(deletion(
                requestID: deletionID,
                disposition: .unchanged,
                mutation: .none)),
            .auxiliary(CleaningAuxiliaryItemResult(
                requestID: remediationID,
                relatedCleaningRequestID: deletionID,
                kind: .threatRemediation,
                disposition: .succeeded,
                mutation: .changed)),
        ])
        let execution = CleaningRetryExecution(
            report: report,
            occurrences: [CleaningRetryOccurrenceExecution(
                priorDeletionOccurrenceIndex: 0,
                deletionRequestID: deletionID,
                performedDeletion: false)],
            retainedReceipts: [CleaningRetryReceipt(
                ownerOperationID: UUID(),
                deletionRequestID: UUID(),
                item: receipt)])
        let harness = makeHarness()

        let consumed = await harness.consumer.consumeRetry(
            module: "Cleaner",
            execution: execution,
            selectionOccurrenceCount: 1,
            detailKey: "处置结果",
            date: finishedAt)

        XCTAssertEqual(consumed.undoReceipts, [receipt])
        XCTAssertTrue(consumed.presentationContext.canUndoChangedItems)
        XCTAssertEqual(report.removedCount, 0)
        XCTAssertTrue(harness.notifier.requests.isEmpty)
        XCTAssertFalse(consumed.didSendNotification)
    }

    func testRetrySelectionUsesDomainOccurrenceMappingAndNeverTargetsContextDeletion() throws {
        let contextID = UUID()
        let succeededID = UUID()
        let failedID = UUID()
        let report = try self.report(facts: [
            .deletion(deletion(
                requestID: contextID,
                disposition: .unchanged,
                mutation: .none)),
            .deletion(deletion(
                requestID: succeededID,
                disposition: .succeeded,
                mutation: .changed,
                bytes: 1)),
            .deletion(deletion(
                requestID: failedID,
                disposition: .failed(issue("retry.failed", retryable: true)),
                mutation: .none)),
        ])
        let execution = CleaningRetryExecution(
            report: report,
            occurrences: [
                CleaningRetryOccurrenceExecution(
                    priorDeletionOccurrenceIndex: 99,
                    deletionRequestID: contextID,
                    performedDeletion: false),
                CleaningRetryOccurrenceExecution(
                    priorDeletionOccurrenceIndex: 10,
                    deletionRequestID: succeededID,
                    performedDeletion: true),
                CleaningRetryOccurrenceExecution(
                    priorDeletionOccurrenceIndex: 20,
                    deletionRequestID: failedID,
                    performedDeletion: true),
            ],
            retainedReceipts: [])

        let transition = CleaningRetrySelectionTransition.make(
            execution: execution,
            priorReportOccurrenceMapping: [10: 1, 20: 3],
            currentSelectionOccurrenceCount: 4)

        XCTAssertEqual(transition.mutation.removableOccurrenceIndices, [1])
        XCTAssertEqual(
            transition.mutation.applying(to: ["keep-0", "done", "keep-2", "failed"]),
            ["keep-0", "keep-2", "failed"])
        XCTAssertEqual(transition.nextReportOccurrenceMapping, [2: 2])
    }

    func testRetrySelectionDuplicateReportRequestIDsFailClosedWithoutTrapping() throws {
        let duplicate = deletion(
            requestID: UUID(),
            disposition: .succeeded,
            mutation: .changed,
            bytes: 1)
        let baseline = try report(facts: [.deletion(duplicate)])
        let malformed = CleaningReport(
            operation: baseline.operation,
            facts: [.deletion(duplicate), .deletion(duplicate)])
        let execution = CleaningRetryExecution(
            report: malformed,
            occurrences: [
                CleaningRetryOccurrenceExecution(
                    priorDeletionOccurrenceIndex: 0,
                    deletionRequestID: duplicate.requestID,
                    performedDeletion: true),
                CleaningRetryOccurrenceExecution(
                    priorDeletionOccurrenceIndex: 1,
                    deletionRequestID: UUID(),
                    performedDeletion: true),
            ],
            retainedReceipts: [])

        let transition = CleaningRetrySelectionTransition.make(
            execution: execution,
            priorReportOccurrenceMapping: [0: 0, 1: 1],
            currentSelectionOccurrenceCount: 2)

        XCTAssertTrue(transition.mutation.removableOccurrenceIndices.isEmpty)
        XCTAssertEqual(transition.mutation.applying(to: ["first", "second"]), ["first", "second"])
        XCTAssertTrue(transition.nextReportOccurrenceMapping.isEmpty)
    }

    func testRetrySelectionRejectsReducerBackedNonCleaningTerminal() throws {
        let completed = deletion(
            requestID: UUID(),
            disposition: .succeeded,
            mutation: .changed,
            bytes: 1)
        let report = try self.report(
            kind: OperationKind("cleaning.test.wrongKind"),
            facts: [.deletion(completed)])
        XCTAssertTrue(report.isReducerBacked)
        let execution = CleaningRetryExecution(
            report: report,
            occurrences: [CleaningRetryOccurrenceExecution(
                priorDeletionOccurrenceIndex: 0,
                deletionRequestID: completed.requestID,
                performedDeletion: true)],
            retainedReceipts: [])

        let transition = CleaningRetrySelectionTransition.make(
            execution: execution,
            priorReportOccurrenceMapping: [0: 0],
            currentSelectionOccurrenceCount: 1)

        XCTAssertTrue(transition.mutation.removableOccurrenceIndices.isEmpty)
        XCTAssertEqual(transition.mutation.applying(to: ["keep"]), ["keep"])
        XCTAssertTrue(transition.nextReportOccurrenceMapping.isEmpty)
    }

    func testFullChangedSuccessConsumesEachApprovedChannelExactlyOnce() async throws {
        let report = try self.report(facts: [
            .deletion(deletion(
                disposition: .succeeded,
                mutation: .changed,
                bytes: 64,
                restorable: RestorableItem(
                    originalURL: URL(fileURLWithPath: "/tmp/full"),
                    trashedURL: URL(fileURLWithPath: "/tmp/full-trash")))),
        ])
        let harness = makeHarness()

        let first = await harness.consumer.consume(
            module: "Cleaner",
            report: report,
            selectionOccurrenceCount: 1,
            detailKey: "操作已完成",
            date: finishedAt)
        let replay = await harness.consumer.consume(
            module: "Cleaner",
            report: report,
            selectionOccurrenceCount: 1,
            detailKey: "操作已完成",
            date: finishedAt)
        let firstGrant = try XCTUnwrap(first.presentationAuthorization.take(
            expectedOperationID: report.operation.id))

        XCTAssertTrue(firstGrant.celebration)
        XCTAssertTrue(firstGrant.successSoundHaptic)
        XCTAssertTrue(firstGrant.accessibilityAnnouncement)
        XCTAssertNil(replay.presentationAuthorization.take(
            expectedOperationID: report.operation.id))
        XCTAssertEqual(harness.history.cleaningStatuses, [.success])
        XCTAssertEqual(harness.notifier.requests.count, 1)
        XCTAssertEqual(harness.notifier.requests.first?.changedCount, 1)
        XCTAssertEqual(harness.invalidation.requests.count, 1)
        XCTAssertTrue(first.didSendNotification)
        XCTAssertFalse(replay.didSendNotification)

        for channel in allChannels {
            let available = await harness.gate.consume(channel, for: report.operation.id)
            XCTAssertFalse(available, "Channel was not consumed exactly once: \(channel)")
        }
    }

    func testUnknownAndMergeRejectedReportsFailClosedWithoutDiscardingReceipts() async throws {
        let receipt = RestorableItem(
            originalURL: URL(fileURLWithPath: "/tmp/unknown"),
            trashedURL: URL(fileURLWithPath: "/tmp/unknown-trash"))
        let fact = CleaningOperationFact.deletion(deletion(
            disposition: .succeeded,
            mutation: .changed,
            bytes: 99,
            restorable: receipt))
        let unknown = try report(
            kind: OperationKind("cleaning.test.unknown"),
            facts: [fact])
        let rejected = mergeRejectedReport(facts: [fact])
        let harness = makeHarness()

        for report in [unknown, rejected] {
            let consumed = await harness.consumer.consume(
                module: "Cleaner",
                report: report,
                selectionOccurrenceCount: 1,
                detailKey: "结果需要确认",
                date: finishedAt)
            let grant = try XCTUnwrap(consumed.presentationAuthorization.take(
                expectedOperationID: report.operation.id))

            XCTAssertFalse(consumed.isTrusted)
            XCTAssertTrue(consumed.selectionMutation.removableOccurrenceIndices.isEmpty)
            XCTAssertEqual(consumed.selectionMutation.applying(to: ["keep"]), ["keep"])
            XCTAssertTrue(consumed.retryableRemainder.isEmpty)
            XCTAssertEqual(consumed.undoReceipts, [receipt])
            XCTAssertNil(consumed.presentationContext.affectedBytes)
            XCTAssertFalse(grant.celebration)
            XCTAssertFalse(grant.successSoundHaptic)
            XCTAssertTrue(grant.accessibilityAnnouncement)
        }

        XCTAssertTrue(harness.history.cleaningStatuses.isEmpty)
        XCTAssertTrue(harness.notifier.requests.isEmpty)
        XCTAssertTrue(harness.invalidation.requests.isEmpty)
    }

    func testRegisteredSpaceTrashKindCannotEnterCleaningExecuteConsumer() async throws {
        let report = try self.report(
            kind: .spaceTrash,
            facts: [
                .deletion(deletion(
                    disposition: .succeeded,
                    mutation: .changed,
                    bytes: 7)),
            ])
        let harness = makeHarness()

        let consumed = await harness.consumer.consume(
            module: "Cleaner",
            report: report,
            selectionOccurrenceCount: 1,
            detailKey: "结果需要确认",
            date: finishedAt)

        XCTAssertFalse(consumed.isTrusted)
        XCTAssertTrue(consumed.selectionMutation.removableOccurrenceIndices.isEmpty)
        XCTAssertTrue(consumed.retryableRemainder.isEmpty)
        XCTAssertTrue(harness.history.cleaningStatuses.isEmpty)
        XCTAssertTrue(harness.notifier.requests.isEmpty)
        XCTAssertTrue(harness.invalidation.requests.isEmpty)
    }

    func testOutOfOrderAuxiliaryFactFailsClosed() async throws {
        let firstDeletionRequestID = UUID()
        let facts: [CleaningOperationFact] = [
            .deletion(deletion(
                requestID: firstDeletionRequestID,
                disposition: .succeeded,
                mutation: .changed,
                bytes: 8)),
            .deletion(deletion(
                disposition: .succeeded,
                mutation: .changed,
                bytes: 9)),
            .auxiliary(CleaningAuxiliaryItemResult(
                requestID: UUID(),
                relatedCleaningRequestID: firstDeletionRequestID,
                kind: .threatRemediation,
                disposition: .succeeded,
                mutation: .changed)),
        ]
        let report = try self.report(facts: facts)
        let harness = makeHarness()

        let consumed = await harness.consumer.consume(
            module: "Cleaner",
            report: report,
            selectionOccurrenceCount: 2,
            detailKey: "结果需要确认",
            date: finishedAt)

        XCTAssertFalse(consumed.isTrusted)
        XCTAssertTrue(consumed.selectionMutation.removableOccurrenceIndices.isEmpty)
        XCTAssertTrue(consumed.retryableRemainder.isEmpty)
        XCTAssertTrue(harness.history.cleaningStatuses.isEmpty)
        XCTAssertTrue(harness.notifier.requests.isEmpty)
        XCTAssertTrue(harness.invalidation.requests.isEmpty)
    }

    func testSelectionOccurrenceCountMismatchRetainsEveryOccurrence() async throws {
        let report = try self.report(facts: [
            .deletion(deletion(
                disposition: .succeeded,
                mutation: .changed,
                bytes: 10)),
        ])
        let harness = makeHarness()

        let consumed = await harness.consumer.consume(
            module: "Cleaner",
            report: report,
            selectionOccurrenceCount: 2,
            detailKey: "操作已完成",
            date: finishedAt)

        XCTAssertTrue(consumed.isTrusted)
        XCTAssertTrue(consumed.selectionMutation.removableOccurrenceIndices.isEmpty)
        XCTAssertEqual(
            consumed.selectionMutation.applying(to: ["first", "second"]),
            ["first", "second"])
    }

    func testLiveCleaningProducersUseTheTypedConsumerWithoutRawSideEffects() throws {
        for relativePath in [
            "Sources/Features/ModuleSessionViewModel.swift",
            "Sources/Features/SmartScanHub.swift",
        ] {
            let source = try Self.source(relativePath)
            XCTAssertTrue(source.contains("CleaningOutcomeConsumer("), relativePath)
            XCTAssertTrue(source.contains("selectionMutation"), relativePath)
            XCTAssertFalse(source.contains("Notifier.notifyCleaningDone"), relativePath)
            XCTAssertFalse(source.contains("NotificationCenter.default.post(name: .xicoDidClean"), relativePath)
            XCTAssertFalse(source.contains("ThreatRemediation.bootoutUserAgents"), relativePath)
            XCTAssertFalse(source.contains("CleaningReport(\n" +
                "                    removedCount:"), relativePath)
        }
    }

    func testLiveCleaningTasksRetainCancellationAndReducerTerminalPresentation() throws {
        let module = try Self.source("Sources/Features/ModuleSessionViewModel.swift")
        let smart = try Self.source("Sources/Features/SmartScanHub.swift")
        let scanViews = try Self.source("Sources/Features/ScanViews.swift")
        let sharedViews = try Self.source("Sources/Features/SharedViews.swift")

        for source in [module, smart] {
            XCTAssertTrue(source.contains("cleanTask"))
            XCTAssertTrue(source.contains("cancelCleaning"))
            XCTAssertTrue(source.contains("outcomeConsumption"))
        }
        XCTAssertEqual(scanViews.components(separatedBy: "CompletionView(").count - 1, 2)
        XCTAssertTrue(scanViews.contains("outcome: outcome"))
        XCTAssertTrue(sharedViews.contains("TaskOutcomeView("))
        XCTAssertFalse(sharedViews.contains("TaskCompletionView(\n" +
            "            animateTo: report.reclaimedBytes"))
    }

    func testLiveCleaningRetryUsesDomainAuthorityAndOperationOwnedReceiptHistory() throws {
        let module = try Self.source("Sources/Features/ModuleSessionViewModel.swift")
        let smart = try Self.source("Sources/Features/SmartScanHub.swift")
        let scanViews = try Self.source("Sources/Features/ScanViews.swift")

        for (relativePath, source) in [
            ("ModuleSessionViewModel.swift", module),
            ("SmartScanHub.swift", smart),
        ] {
            XCTAssertTrue(source.contains("cleaningEngine.retry("), relativePath)
            XCTAssertTrue(source.contains("consumeRetry("), relativePath)
            XCTAssertTrue(source.contains("CleaningRetrySelectionTransition.make("), relativePath)
            XCTAssertTrue(source.contains("execution.retainedReceipts"), relativePath)
            XCTAssertTrue(source.contains("historyRecordIDsByOperation"), relativePath)
            XCTAssertTrue(source.contains("operationHasIrreversibleChanges"), relativePath)
            XCTAssertTrue(source.contains("retrySelectionInventory"), relativePath)
            XCTAssertTrue(source.contains("== retrySelectionInventory"), relativePath)
            XCTAssertFalse(source.contains("purpose: ."), relativePath)
            XCTAssertFalse(source.contains("originalCleaningPlans"), relativePath)
            XCTAssertFalse(source.contains("lastHistoryID"), relativePath)
        }
        XCTAssertTrue(module.contains("guard phase == .results, !isCleaning"))
        XCTAssertTrue(smart.contains("guard phase == .active, !cleaning"))
        for (relativePath, source) in [
            ("ModuleSessionViewModel.swift", module),
            ("SmartScanHub.swift", smart),
        ] {
            XCTAssertTrue(
                source.contains("!isUndoing || preservingHistoryOwnership"),
                relativePath)
            XCTAssertTrue(
                source.contains("public func cancel() {\n        guard !isUndoing"),
                relativePath)
            XCTAssertTrue(
                source.contains("public func reset() {\n        guard !isUndoing"),
                relativePath)
        }
        XCTAssertFalse(scanViews.contains("onRetry: nil"))
        XCTAssertTrue(scanViews.contains("vm.retryCleaning()"))
        XCTAssertTrue(scanViews.contains("hub.retryCleaning()"))
    }

    func testHistoricalUndoPassesRestorableItemsDirectlyAndHandlesPersistenceResult() throws {
        for relativePath in [
            "Sources/Features/ScanViews.swift",
            "Sources/Features/SettingsView.swift",
        ] {
            let source = try Self.source(relativePath)
            XCTAssertTrue(source.contains("rec.restorable"), relativePath)
            XCTAssertTrue(source.contains("HistoryUpdateResult"), relativePath)
            XCTAssertTrue(source.contains("case .committed"), relativePath)
            XCTAssertTrue(source.contains("case .notFound"), relativePath)
            XCTAssertTrue(source.contains("case .rejected"), relativePath)
            XCTAssertTrue(source.contains("!rec.hasIrreversibleChanges"), relativePath)
            XCTAssertFalse(source.contains("CleaningReport(\n" +
                "                    removedCount:"), relativePath)
        }
    }

    // MARK: - Fixtures

    private var allChannels: [OutcomeEffectChannel] {
        [
            .history,
            .successNotification,
            .celebration,
            .successSoundHaptic,
            .accessibilityAnnouncement,
            .internalInvalidation,
        ]
    }

    private func makeHarness() -> Harness {
        let history = HistoryFake()
        let notifier = NotificationFake()
        let invalidation = InvalidationFake()
        let gate = OutcomeFeedbackGate()
        return Harness(
            consumer: CleaningOutcomeConsumer(
                history: history,
                notifier: notifier,
                invalidation: invalidation,
                gate: gate),
            history: history,
            notifier: notifier,
            invalidation: invalidation,
            gate: gate)
    }

    private func deletion(
        requestID: UUID = UUID(),
        itemID: UUID = UUID(),
        disposition: OperationDisposition,
        mutation: OperationMutationFact,
        bytes: Int64 = 0,
        restorable: RestorableItem? = nil,
        authorizedRetry: Bool = false
    ) -> CleaningItemResult {
        let url = URL(fileURLWithPath: "/tmp/\(requestID.uuidString)")
        let authorization = authorizedRetry
            ? CleaningRetryAuthorization(
                item: CleanableItem(
                    id: itemID,
                    url: url,
                    displayName: "retry fixture",
                    size: bytes),
                intent: .trash,
                prerequisite: .none)
            : nil
        return CleaningItemResult(
            requestID: requestID,
            itemID: itemID,
            url: url,
            intent: .trash,
            retryAuthorization: authorization,
            disposition: disposition,
            mutation: mutation,
            reclaimedBytes: bytes,
            restorable: restorable)
    }

    private func retryToken(_ suffix: String) -> ThreatRemediationRetryToken {
        // Literal is constrained to the Domain token grammar; failure is a fixture programming bug.
        ThreatRemediationRetryToken(
            validatedLabel: "com.xico.tests.\(suffix)",
            rootRelativeIdentity: "\(suffix).plist")!
    }

    private func issue(_ code: String, retryable: Bool) -> OperationIssue {
        OperationIssue(
            code: code,
            category: .io,
            subjectID: nil,
            recovery: retryable ? .retry : .manualAction,
            retryable: retryable)
    }

    private func report(
        id: UUID = UUID(),
        kind: OperationKind = .cleaningExecute,
        facts: [CleaningOperationFact],
        cancellationAccepted: Bool = false
    ) throws -> CleaningReport {
        let operation = try OperationOutcomeReducer.reduce(
            id: id,
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
            startedAt: startedAt,
            finishedAt: finishedAt)
        return CleaningReport(operation: operation, facts: facts)
    }

    private func mergeRejectedReport(
        facts: [CleaningOperationFact]
    ) -> CleaningReport {
        let operation = OperationOutcomeReducer.internalFailure(
            kind: OperationKind("cleaning.merge.rejected"),
            requestedSubjectIDs: facts.map { $0.requestID.uuidString },
            itemOutcomes: facts.map {
                OperationItemOutcome(
                    subjectID: $0.requestID.uuidString,
                    disposition: $0.disposition,
                    mutation: $0.mutation,
                    affectedBytes: $0.affectedBytes)
            },
            code: "cleaning.merge.factMismatch",
            startedAt: startedAt,
            finishedAt: finishedAt)
        return CleaningReport(operation: operation, facts: facts)
    }

    private struct Harness {
        let consumer: CleaningOutcomeConsumer
        let history: HistoryFake
        let notifier: NotificationFake
        let invalidation: InvalidationFake
        let gate: OutcomeFeedbackGate
    }

    private static func source(_ relativePath: String) throws -> String {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(
            contentsOf: repositoryRoot.appendingPathComponent(relativePath),
            encoding: .utf8)
    }
}

private final class HistoryFake: OutcomeHistoryWriting, @unchecked Sendable {
    let insertResult = HistoryRecordResult.inserted(recordID: UUID())
    private let lock = NSLock()
    private var statuses: [OperationTerminalStatus] = []

    var cleaningStatuses: [OperationTerminalStatus] {
        lock.lock()
        defer { lock.unlock() }
        return statuses
    }

    func record(module: String, report: CleaningReport, date: Date) -> HistoryRecordResult {
        lock.lock()
        statuses.append(report.operation.status)
        lock.unlock()
        return insertResult
    }

    func record(
        module: String,
        result: OperationResult<ShredderPayload>,
        date: Date
    ) -> HistoryRecordResult {
        .notRecordedNoChanges
    }

    func remove(id: UUID) -> HistoryUpdateResult { .notFound }

    func updateRestorable(id: UUID, to: [RestorableItem]) -> HistoryUpdateResult {
        .notFound
    }
}

private final class NotificationFake: CleaningNotificationSending, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [ValidatedCleaningNotification] = []

    var requests: [ValidatedCleaningNotification] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func send(_ request: ValidatedCleaningNotification) {
        lock.lock()
        storage.append(request)
        lock.unlock()
    }
}

private final class InvalidationFake: OutcomeInvalidationPublishing, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [ValidatedOutcomeInvalidation] = []

    var requests: [ValidatedOutcomeInvalidation] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func publish(
        _ request: ValidatedOutcomeInvalidation
    ) -> OutcomeInvalidationPublishResult {
        lock.lock()
        storage.append(request)
        lock.unlock()
        return .published
    }
}
