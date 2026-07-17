import Foundation
import Domain
import Infrastructure

/// A position-based selection mutation. Caller IDs and paths are deliberately
/// absent: duplicate caller IDs are valid and deletion identity belongs to the
/// reducer request occurrence.
struct CleaningSelectionMutation: Equatable, Sendable {
    let originalOccurrenceCount: Int
    let removableOccurrenceIndices: [Int]

    func applying<Element>(to occurrences: [Element]) -> [Element] {
        guard occurrences.count == originalOccurrenceCount else {
            // A stale/mismatched UI inventory must retain everything.
            return occurrences
        }
        let removable = Set(removableOccurrenceIndices)
        return occurrences.enumerated().compactMap { index, element in
            removable.contains(index) ? nil : element
        }
    }

    /// Maps this report's deletion occurrence indices to the surviving selection ordinals after
    /// applying the mutation. This positional mapping is the only input accepted by retry UI.
    var retainedOccurrenceMapping: [Int: Int] {
        let removable = Set(removableOccurrenceIndices)
        var nextOrdinal = 0
        var mapping: [Int: Int] = [:]
        for reportIndex in 0..<originalOccurrenceCount where !removable.contains(reportIndex) {
            mapping[reportIndex] = nextOrdinal
            nextOrdinal += 1
        }
        return mapping
    }
}

struct CleaningRetrySelectionTransition: Equatable, Sendable {
    let mutation: CleaningSelectionMutation
    let nextReportOccurrenceMapping: [Int: Int]

    static func make(
        execution: CleaningRetryExecution,
        priorReportOccurrenceMapping: [Int: Int],
        currentSelectionOccurrenceCount: Int
    ) -> CleaningRetrySelectionTransition {
        let boundedCount = max(0, currentSelectionOccurrenceCount)
        let reportItems = execution.report.items
        guard execution.report.operation.kind == .cleaningExecute,
              execution.report.isReducerBacked,
              execution.occurrences.count == reportItems.count,
              Set(execution.occurrences.map(\.priorDeletionOccurrenceIndex)).count
                == execution.occurrences.count,
              Set(execution.occurrences.map(\.deletionRequestID)).count
                == execution.occurrences.count else {
            return failClosed(count: boundedCount)
        }
        var reportIndexByRequestID: [UUID: Int] = [:]
        for (index, item) in reportItems.enumerated() {
            guard reportIndexByRequestID.updateValue(index, forKey: item.requestID) == nil else {
                return failClosed(count: boundedCount)
            }
        }

        var removableOrdinals = Set<Int>()
        var sourceOrdinalByNewReportIndex: [Int: Int] = [:]
        for occurrence in execution.occurrences {
            guard let reportIndex = reportIndexByRequestID[occurrence.deletionRequestID]
            else { return failClosed(count: boundedCount) }
            guard let sourceOrdinal = priorReportOccurrenceMapping[
                occurrence.priorDeletionOccurrenceIndex] else {
                // A context D for an already-removed occurrence intentionally has no UI target.
                if occurrence.performedDeletion {
                    return failClosed(count: boundedCount)
                }
                continue
            }
            guard (0..<boundedCount).contains(sourceOrdinal) else {
                return failClosed(count: boundedCount)
            }
            sourceOrdinalByNewReportIndex[reportIndex] = sourceOrdinal
            guard occurrence.performedDeletion else { continue }
            switch reportItems[reportIndex].disposition {
            case .succeeded, .unchanged:
                guard removableOrdinals.insert(sourceOrdinal).inserted else {
                    return failClosed(count: boundedCount)
                }
            case .skipped, .failed, .cancelled:
                break
            }
        }

        let sortedRemovals = removableOrdinals.sorted()
        var nextMapping: [Int: Int] = [:]
        for (reportIndex, oldOrdinal) in sourceOrdinalByNewReportIndex {
            guard !removableOrdinals.contains(oldOrdinal) else { continue }
            let removedBefore = sortedRemovals.partitioningIndex { $0 >= oldOrdinal }
            nextMapping[reportIndex] = oldOrdinal - removedBefore
        }
        return CleaningRetrySelectionTransition(
            mutation: CleaningSelectionMutation(
                originalOccurrenceCount: boundedCount,
                removableOccurrenceIndices: sortedRemovals),
            nextReportOccurrenceMapping: nextMapping)
    }

    private static func failClosed(count: Int) -> CleaningRetrySelectionTransition {
        CleaningRetrySelectionTransition(
            mutation: CleaningSelectionMutation(
                originalOccurrenceCount: count,
                removableOccurrenceIndices: []),
            nextReportOccurrenceMapping: [:])
    }
}

private extension Array where Element == Int {
    func partitioningIndex(where predicate: (Int) -> Bool) -> Int {
        firstIndex(where: predicate) ?? count
    }
}

/// Typed retry remainder in the parent report's exact fact order.
///
/// An auxiliary retry never implies that its already-successful deletion may
/// run again. Domain owns execution/correlation of that future retry.
enum CleaningRetryFact: Sendable {
    case deletion(
        occurrenceIndex: Int,
        factIndex: Int,
        item: CleaningItemResult)
    case auxiliary(
        factIndex: Int,
        relatedDeletionOccurrenceIndex: Int,
        item: CleaningAuxiliaryItemResult)

    var requestID: UUID {
        switch self {
        case let .deletion(_, _, item): item.requestID
        case let .auxiliary(_, _, item): item.requestID
        }
    }

    var requiresDeletionExecution: Bool {
        if case .deletion = self { return true }
        return false
    }
}

struct CleaningOutcomeConsumption: Sendable {
    let report: CleaningReport
    let isTrusted: Bool
    let selectionMutation: CleaningSelectionMutation
    let retryableRemainder: [CleaningRetryFact]
    let undoReceipts: [RestorableItem]
    let presentationContext: TaskOutcomeContext
    let presentationAuthorization: OutcomePresentationEffectAuthorization
    let historyResult: HistoryRecordResult?
    let didSendNotification: Bool
    let invalidationResult: OutcomeInvalidationPublishResult?
}

/// The only Feature-layer coordinator for cleaning terminal consumption.
/// It consumes reducer-backed reports; it never constructs or relabels one.
struct CleaningOutcomeConsumer: Sendable {
    private let history: any OutcomeHistoryWriting
    private let notifier: any CleaningNotificationSending
    private let invalidation: any OutcomeInvalidationPublishing
    private let gate: OutcomeFeedbackGate

    init(
        history: any OutcomeHistoryWriting,
        notifier: any CleaningNotificationSending,
        invalidation: any OutcomeInvalidationPublishing,
        gate: OutcomeFeedbackGate
    ) {
        self.history = history
        self.notifier = notifier
        self.invalidation = invalidation
        self.gate = gate
    }

    func consume(
        module: String,
        report: CleaningReport,
        selectionOccurrenceCount: Int,
        detailKey: String,
        note: String? = nil,
        date: Date = Date()
    ) async -> CleaningOutcomeConsumption {
        await consume(
            module: module,
            report: report,
            retainedUndoReceipts: [],
            selectionOccurrenceCount: selectionOccurrenceCount,
            detailKey: detailKey,
            note: note,
            date: date)
    }

    /// Retry terminals carry a Domain-owned receipt ledger so an auxiliary-only retry cannot
    /// erase the user's still-valid undo capability from an earlier successful deletion.
    func consumeRetry(
        module: String,
        execution: CleaningRetryExecution,
        selectionOccurrenceCount: Int,
        detailKey: String,
        note: String? = nil,
        date: Date = Date()
    ) async -> CleaningOutcomeConsumption {
        await consume(
            module: module,
            report: execution.report,
            retainedUndoReceipts: execution.retainedReceipts.map(\.item),
            selectionOccurrenceCount: selectionOccurrenceCount,
            detailKey: detailKey,
            note: note,
            date: date)
    }

    private func consume(
        module: String,
        report: CleaningReport,
        retainedUndoReceipts: [RestorableItem],
        selectionOccurrenceCount: Int,
        detailKey: String,
        note: String?,
        date: Date
    ) async -> CleaningOutcomeConsumption {
        let operation = report.operation
        await gate.registerTerminal(operation.id)

        let semantics = OutcomeOperationRegistry.semantics(for: operation.kind)
        let isTrusted = operation.kind == .cleaningExecute
            && semantics != nil
            && Self.isReducerConsistent(report)
        let decision = OutcomeSideEffectPolicy.evaluate(operation)
        let selectionMutation = Self.selectionMutation(
            report: report,
            occurrenceCount: selectionOccurrenceCount,
            isTrusted: isTrusted)
        let retryableRemainder = isTrusted
            ? Self.retryableRemainder(in: report)
            : []
        // Preserve only payload-backed receipts from definite changed deletion
        // facts. Legacy aggregates and uncertain mutations cannot mint undo.
        let undoReceipts = Self.mergingReceipts(
            retainedUndoReceipts,
            Self.safeUndoReceipts(in: report))

        var historyResult: HistoryRecordResult?
        if isTrusted,
           case .record = decision.history,
           await gate.consume(.history, for: operation.id) {
            historyResult = history.record(
                module: module,
                report: report,
                date: date)
        }

        var didSendNotification = false
        if isTrusted,
           decision.successNotification == .allowed,
           await gate.consume(.successNotification, for: operation.id),
           let request = ValidatedCleaningNotification(report: report) {
            notifier.send(request)
            didSendNotification = true
        }

        var invalidationResult: OutcomeInvalidationPublishResult?
        if isTrusted,
           decision.broadcastsInternalInvalidation,
           let domains = semantics?.invalidationDomains,
           !domains.isEmpty,
           await gate.consume(.internalInvalidation, for: operation.id),
           let request = ValidatedOutcomeInvalidation(
                outcome: operation,
                domains: domains) {
            invalidationResult = invalidation.publish(request)
        }

        let presentationContext = TaskOutcomeContext(
            operation: operation,
            affectedBytes: isTrusted ? report.reclaimedBytes : nil,
            primaryDetailKey: detailKey,
            note: note,
            canUndoChangedItems: !undoReceipts.isEmpty,
            retryableSubjectCount: retryableRemainder.count)
        // Presentation channels are frozen last, after every sink decision.
        let presentationAuthorization = await OutcomePresentationEffectAuthorization.consume(
            context: presentationContext,
            gate: gate)

        return CleaningOutcomeConsumption(
            report: report,
            isTrusted: isTrusted,
            selectionMutation: selectionMutation,
            retryableRemainder: retryableRemainder,
            undoReceipts: undoReceipts,
            presentationContext: presentationContext,
            presentationAuthorization: presentationAuthorization,
            historyResult: historyResult,
            didSendNotification: didSendNotification,
            invalidationResult: invalidationResult)
    }

    private static func mergingReceipts(
        _ retained: [RestorableItem],
        _ current: [RestorableItem]
    ) -> [RestorableItem] {
        (retained + current).reduce(into: []) { result, receipt in
            if !result.contains(receipt) { result.append(receipt) }
        }
    }

    private static func selectionMutation(
        report: CleaningReport,
        occurrenceCount: Int,
        isTrusted: Bool
    ) -> CleaningSelectionMutation {
        let boundedCount = max(0, occurrenceCount)
        guard isTrusted, report.items.count == boundedCount else {
            return CleaningSelectionMutation(
                originalOccurrenceCount: boundedCount,
                removableOccurrenceIndices: [])
        }
        let removable = report.items.enumerated().compactMap { index, item in
            switch item.disposition {
            case .succeeded, .unchanged: index
            case .skipped, .failed, .cancelled: nil
            }
        }
        return CleaningSelectionMutation(
            originalOccurrenceCount: boundedCount,
            removableOccurrenceIndices: removable)
    }

    private static func retryableRemainder(
        in report: CleaningReport
    ) -> [CleaningRetryFact] {
        let deletionOccurrenceByID = Dictionary(uniqueKeysWithValues:
            report.items.enumerated().map { ($0.element.requestID, $0.offset) })

        return report.facts.enumerated().compactMap { factIndex, fact in
            // UI retry availability must use the same Domain authority predicate as execution.
            // A retryable-looking issue without an in-memory deletion authorization / R token is
            // diagnostic only and must never create a dead retry button.
            guard OperationConsumerFacts.isRetryable(fact) else { return nil }
            switch fact {
            case let .deletion(item):
                guard let occurrenceIndex = deletionOccurrenceByID[item.requestID] else {
                    return nil
                }
                return .deletion(
                    occurrenceIndex: occurrenceIndex,
                    factIndex: factIndex,
                    item: item)
            case let .auxiliary(item):
                guard let occurrenceIndex = deletionOccurrenceByID[
                    item.relatedCleaningRequestID] else {
                    return nil
                }
                return .auxiliary(
                    factIndex: factIndex,
                    relatedDeletionOccurrenceIndex: occurrenceIndex,
                    item: item)
            }
        }
    }

    private static func safeUndoReceipts(
        in report: CleaningReport
    ) -> [RestorableItem] {
        report.items.compactMap { item in
            guard item.disposition == .succeeded,
                  item.mutation == .changed else { return nil }
            return item.restorable
        }
    }

    private static func isReducerConsistent(_ report: CleaningReport) -> Bool {
        let facts = report.facts
        guard !facts.isEmpty,
              !report.items.isEmpty else { return false }
        let requestIDs = facts.map { $0.requestID.uuidString }
        guard Set(requestIDs).count == requestIDs.count else { return false }

        // A truthful merged cleaning stream is a sequence of D [R]? groups:
        // remediation, when present, belongs to the immediately preceding
        // deletion and there can be at most one remediation per deletion.
        var precedingDeletionRequestID: UUID?
        for fact in facts {
            switch fact {
            case let .deletion(item):
                precedingDeletionRequestID = item.requestID
            case let .auxiliary(item):
                guard precedingDeletionRequestID == item.relatedCleaningRequestID else {
                    return false
                }
                precedingDeletionRequestID = nil
            }
        }

        let outcome = report.operation
        let reduced: OperationOutcome
        do {
            reduced = try OperationOutcomeReducer.reduce(
                id: outcome.id,
                parentID: outcome.parentID,
                kind: outcome.kind,
                requestedSubjectIDs: requestIDs,
                itemOutcomes: facts.map {
                    OperationItemOutcome(
                        subjectID: $0.requestID.uuidString,
                        disposition: $0.disposition,
                        mutation: $0.mutation,
                        affectedBytes: $0.affectedBytes)
                },
                cancellationAccepted: outcome.status == .cancelled,
                startedAt: outcome.startedAt,
                finishedAt: outcome.finishedAt)
        } catch {
            return false
        }
        return reduced.id == outcome.id
            && reduced.parentID == outcome.parentID
            && reduced.kind == outcome.kind
            && reduced.status == outcome.status
            && reduced.counts == outcome.counts
            && reduced.startedAt == outcome.startedAt
            && reduced.finishedAt == outcome.finishedAt
            && reduced.issues == outcome.issues
            && reduced.mutation == outcome.mutation
    }
}
