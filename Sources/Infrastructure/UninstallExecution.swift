@_spi(XicoUninstallExecution) import Domain
import Foundation

struct UninstallPayloadOccurrenceBinding: Sendable {
    let requestID: UUID
    let target: PreparedUninstallTarget
}

struct UninstallPayloadExecution: Sendable {
    let report: CleaningReport
    let occurrences: [UninstallPayloadOccurrenceBinding]
}

package enum UninstallCompletion: Sendable, Equatable {
    case fullSuccess
    case dataMovedButAppNotUninstalled
    case appMovedButSomeDataRetained
    case partial
    case failure
    case cancelled
    /// A later operation succeeded, but an earlier mutation remained indeterminate.
    case uncertain
}

package enum UninstallRetryDirective: Sendable, Equatable {
    case uninstallApp
    case cleanLeftovers
    case determineFromFreshScan
    case restoreAppThenRescan
}

/// Exact, immutable identity of one reviewed uninstall occurrence. The public package surface is
/// read-only; only Infrastructure can construct facts from a validated execution terminal.
package struct UninstallOccurrenceSubject: Sendable, Equatable {
    package let appIdentity: UninstallAppWorkflowIdentity
    package var appID: String { appIdentity.appID }
    package let canonicalPath: String
    package let role: UninstallCandidateRole
    package let evidence: OwnershipEvidence
}

package struct UninstallOccurrenceID: Hashable, Sendable {
    package let operationID: UUID
    package let requestID: UUID
}

/// Reducer-backed result for one exact prepared occurrence. Feature code may retain and reconcile
/// these facts, but cannot fabricate them because the memberwise initializer remains internal to
/// Infrastructure.
package struct UninstallOccurrenceFact: Identifiable, Sendable {
    package var id: UninstallOccurrenceID {
        UninstallOccurrenceID(operationID: operationID, requestID: requestID)
    }
    package let operationID: UUID
    package let requestID: UUID
    package let candidateID: UUID
    package let subject: UninstallOccurrenceSubject
    package let disposition: OperationDisposition
    package let mutation: OperationMutationFact
}

private struct MalformedReceiptEndpointPair: Hashable {
    let original: String
    let trashed: String
}

private struct MalformedReceiptCandidate {
    let receipt: RestorableItem
    let endpoints: MalformedReceiptEndpointPair
    let isAppBody: Bool
}

/// Infrastructure-owned terminal that binds every Domain fact back to the exact Task 4 candidate
/// occurrence. Features can consume its read-only truth but cannot construct one.
package struct UninstallExecution: Sendable {
    package let report: CleaningReport
    package let remainingBatch: UninstallBatch?
    package let restorable: [RestorableItem]
    package let appBodyRestorable: RestorableItem?
    package let fullSuccess: Bool
    package let completion: UninstallCompletion
    package let appBodyFailureAfterAssociatedSuccess: Bool
    package let appBodySucceededWithAssociatedFailures: Bool
    package let requiresFreshScanForRetry: Bool
    package let retryDirective: UninstallRetryDirective?
    package let hasPossiblyChangedFacts: Bool
    package let occurrenceFacts: [UninstallOccurrenceFact]

    init?(payload: UninstallPayloadExecution, prepared: PreparedUninstallExecution) {
        let report = payload.report
        let occurrences = payload.occurrences
        guard prepared.validateIntegrity(),
              report.operation.kind == .uninstall,
              report.isReducerBacked,
              report.auxiliaryItems.isEmpty,
              report.facts.count == report.items.count,
              report.items.count == occurrences.count,
              occurrences.count == prepared.orderedTargets.count,
              Set(occurrences.map(\.requestID)).count == occurrences.count else { return nil }

        var successfulOriginalIndices = Set<Int>()
        var receipts: [RestorableItem] = []
        var receiptEndpoints = Set<String>()
        var bodyResult: CleaningItemResult?
        var bodyReceipt: RestorableItem?
        var associatedSucceeded = false
        var associatedFailed = false
        var failedRichEvidenceAfterBody = false
        var occurrenceFacts: [UninstallOccurrenceFact] = []

        for index in occurrences.indices {
            let occurrence = occurrences[index]
            let expectedTarget = prepared.orderedTargets[index]
            let result = report.items[index]
            guard Self.sameTarget(occurrence.target, expectedTarget),
                  occurrence.requestID == result.requestID,
                  result.itemID == expectedTarget.candidate.item.id,
                  result.url.standardizedFileURL.path == expectedTarget.canonicalPath,
                  result.intent == .trash,
                  result.prerequisite == .none,
                  result.retryAuthorization == nil,
                  Self.hasValidIssueBinding(
                    result.disposition, requestID: result.requestID) else { return nil }

            occurrenceFacts.append(UninstallOccurrenceFact(
                operationID: report.operation.id,
                requestID: result.requestID,
                candidateID: expectedTarget.candidate.id,
                subject: UninstallOccurrenceSubject(
                    appIdentity: prepared.batchSnapshot.app.uninstallWorkflowIdentity,
                    canonicalPath: expectedTarget.canonicalPath,
                    role: expectedTarget.candidate.role,
                    evidence: expectedTarget.candidate.evidence),
                disposition: result.disposition,
                mutation: result.mutation))

            switch result.disposition {
            case .succeeded:
                guard result.mutation == .changed,
                      result.reclaimedBytes
                        == expectedTarget.candidate.item.estimatedReclaimableBytes,
                      let receipt = result.restorable,
                      Self.validReceipt(receipt, target: expectedTarget),
                      receiptEndpoints.insert(
                        receipt.originalURL.standardizedFileURL.path).inserted,
                      receiptEndpoints.insert(
                        receipt.trashedURL.standardizedFileURL.path).inserted else { return nil }
                successfulOriginalIndices.insert(Int(expectedTarget.batchCandidateIndex))
                receipts.append(receipt)
                if expectedTarget.candidate.role == .appBody {
                    bodyResult = result
                    bodyReceipt = receipt
                } else {
                    associatedSucceeded = true
                }
            case .unchanged:
                // Every admitted uninstall target existed and carried a non-nil sealed identity.
                // Missing after preparation is identity drift, never an unchanged completion.
                return nil
            case .failed, .skipped, .cancelled:
                guard result.reclaimedBytes == 0, result.restorable == nil,
                      result.mutation == .none || result.mutation == .possiblyChanged else {
                    return nil
                }
                if expectedTarget.candidate.role == .appBody {
                    bodyResult = result
                } else {
                    associatedFailed = true
                    if expectedTarget.candidate.evidence == .signedApplicationGroup
                        || expectedTarget.candidate.evidence
                            == .launchAgentProgramInsideBundle {
                        failedRichEvidenceAfterBody = true
                    }
                }
            }
        }

        let fullSuccess = report.operation.status == .success
            && report.items.allSatisfy { $0.disposition == .succeeded }
        var retained = prepared.batchSnapshot
        retained.removeCandidates(atOriginalIndices: successfulOriginalIndices)

        let bodySucceeded = bodyResult?.disposition == .succeeded
        let bodyFailedAfterData = bodyResult != nil && !bodySucceeded && associatedSucceeded
        let bodySucceededWithFailures = bodySucceeded && associatedFailed
        let completion: UninstallCompletion
        if fullSuccess {
            completion = .fullSuccess
        } else if bodyFailedAfterData {
            completion = .dataMovedButAppNotUninstalled
        } else if bodySucceededWithFailures {
            completion = .appMovedButSomeDataRetained
        } else {
            switch report.operation.status {
            case .failure: completion = .failure
            case .cancelled: completion = .cancelled
            case .success, .partial: completion = .partial
            }
        }

        let retryDirective: UninstallRetryDirective?
        if fullSuccess {
            retryDirective = nil
        } else if prepared.batchSnapshot.mode == .cleanLeftovers {
            retryDirective = .cleanLeftovers
        } else if bodySucceeded && failedRichEvidenceAfterBody {
            retryDirective = .restoreAppThenRescan
        } else if bodySucceeded {
            retryDirective = .cleanLeftovers
        } else if bodyResult?.mutation == .possiblyChanged {
            retryDirective = .determineFromFreshScan
        } else {
            // A body identity failure may mean the App disappeared after preparation. A fresh
            // existence check must choose uninstall-vs-leftovers; forcing `.uninstallApp` can
            // strand an absent body with no executable recovery route.
            retryDirective = .determineFromFreshScan
        }

        self.report = report
        self.remainingBatch = fullSuccess ? nil : retained
        self.restorable = receipts
        self.appBodyRestorable = bodyReceipt
        self.fullSuccess = fullSuccess
        self.completion = completion
        self.appBodyFailureAfterAssociatedSuccess = bodyFailedAfterData
        self.appBodySucceededWithAssociatedFailures = bodySucceededWithFailures
        self.requiresFreshScanForRetry = !fullSuccess
        self.retryDirective = retryDirective
        self.hasPossiblyChangedFacts = report.items.contains {
            $0.mutation == .possiblyChanged
        }
        self.occurrenceFacts = occurrenceFacts
    }

    /// Fail-closed recovery for a payload returned after the mutation body ran but whose aggregate
    /// terminal cannot be trusted. Every prepared occurrence becomes `possiblyChanged`; only an
    /// individually exact, unique Trash receipt is retained for undo. The malformed payload can
    /// therefore never celebrate or authorize replay, while known recovery handles are not lost.
    init(malformedPayload payload: UninstallPayloadExecution,
         prepared: PreparedUninstallExecution) {
        let operationID = payload.report.operation.id
        let bindingsByRequestID = Dictionary(
            grouping: payload.occurrences, by: \.requestID)
        let resultsByRequestID = Dictionary(
            grouping: payload.report.items, by: \.requestID)
        var usedRequestIDs = Set<UUID>()
        var receiptCandidates: [MalformedReceiptCandidate] = []
        var fallbackOccurrences: [UninstallMalformedOccurrence] = []
        fallbackOccurrences.reserveCapacity(prepared.orderedTargets.count)
        receiptCandidates.reserveCapacity(prepared.orderedTargets.count)

        for target in prepared.orderedTargets {
            let exactBindings = payload.occurrences.filter {
                Self.sameTarget($0.target, target)
            }
            let exactBinding = exactBindings.count == 1 ? exactBindings[0] : nil
            var requestID: UUID
            if let exactBinding,
               bindingsByRequestID[exactBinding.requestID]?.count == 1,
               usedRequestIDs.insert(exactBinding.requestID).inserted {
                requestID = exactBinding.requestID
            } else {
                repeat { requestID = UUID() }
                while !usedRequestIDs.insert(requestID).inserted
            }

            if let exactBinding,
               exactBinding.requestID == requestID,
               let candidates = resultsByRequestID[requestID],
               candidates.count == 1 {
                let result = candidates[0]
                if result.itemID == target.candidate.id,
                   result.url.standardizedFileURL.path == target.canonicalPath,
                   result.intent == .trash,
                   result.prerequisite == .none,
                   result.retryAuthorization == nil,
                   result.disposition == .succeeded,
                   result.mutation == .changed,
                   result.reclaimedBytes
                        == target.candidate.item.estimatedReclaimableBytes,
                   let receipt = result.restorable,
                   Self.validReceipt(receipt, target: target) {
                    let original = receipt.originalURL.standardizedFileURL.path
                    let trashed = receipt.trashedURL.standardizedFileURL.path
                    receiptCandidates.append(MalformedReceiptCandidate(
                        receipt: receipt,
                        endpoints: MalformedReceiptEndpointPair(
                            original: original, trashed: trashed),
                        isAppBody: target.candidate.role == .appBody))
                }
            }

            fallbackOccurrences.append(UninstallMalformedOccurrence(
                requestID: requestID,
                item: target.candidate.item))
        }

        // A malformed aggregate cannot establish which receipt is authoritative when any endpoint
        // is shared across different receipt pairs. Build the complete incidence graph first, then
        // discard every vertex touching a shared or crossed original/Trash endpoint. A greedy pass
        // would incorrectly retain whichever ambiguous receipt happened to appear first.
        var receiptPairsByEndpoint: [String: Set<MalformedReceiptEndpointPair>] = [:]
        for candidate in receiptCandidates {
            receiptPairsByEndpoint[candidate.endpoints.original, default: []]
                .insert(candidate.endpoints)
            receiptPairsByEndpoint[candidate.endpoints.trashed, default: []]
                .insert(candidate.endpoints)
        }
        let retainedReceiptCandidates = receiptCandidates.filter { candidate in
            receiptPairsByEndpoint[candidate.endpoints.original]?.count == 1
                && receiptPairsByEndpoint[candidate.endpoints.trashed]?.count == 1
        }
        let receipts = retainedReceiptCandidates.map(\.receipt)
        let bodyReceipt = retainedReceiptCandidates.first(where: \.isAppBody)?.receipt

        let now = Date()
        let report = CleaningReport.uninstallMalformed(
            operationID: operationID,
            occurrences: fallbackOccurrences,
            startedAt: now,
            finishedAt: now)
        let occurrenceFacts = zip(prepared.orderedTargets, report.items).map {
            target, result in
            UninstallOccurrenceFact(
                operationID: operationID,
                requestID: result.requestID,
                candidateID: target.candidate.id,
                subject: UninstallOccurrenceSubject(
                    appIdentity: prepared.batchSnapshot.app.uninstallWorkflowIdentity,
                    canonicalPath: target.canonicalPath,
                    role: target.candidate.role,
                    evidence: target.candidate.evidence),
                disposition: result.disposition,
                mutation: result.mutation)
        }

        self.report = report
        self.remainingBatch = prepared.batchSnapshot
        self.restorable = receipts
        self.appBodyRestorable = bodyReceipt
        self.fullSuccess = false
        self.completion = .uncertain
        self.appBodyFailureAfterAssociatedSuccess = false
        self.appBodySucceededWithAssociatedFailures = false
        self.requiresFreshScanForRetry = true
        self.retryDirective = bodyReceipt == nil
            ? .determineFromFreshScan : .restoreAppThenRescan
        self.hasPossiblyChangedFacts = true
        self.occurrenceFacts = occurrenceFacts
    }

    private static func sameTarget(
        _ lhs: PreparedUninstallTarget,
        _ rhs: PreparedUninstallTarget
    ) -> Bool {
        lhs.ordinal == rhs.ordinal
            && lhs.batchCandidateIndex == rhs.batchCandidateIndex
            && UninstallEvidenceSeal.sameCandidate(lhs.candidate, rhs.candidate)
            && lhs.canonicalPath == rhs.canonicalPath
            && lhs.expectedIdentity == rhs.expectedIdentity
            && lhs.evidenceFingerprint == rhs.evidenceFingerprint
            && lhs.ownershipAttestation == rhs.ownershipAttestation
    }

    private static func validReceipt(
        _ receipt: RestorableItem,
        target: PreparedUninstallTarget
    ) -> Bool {
        guard receipt.originalURL.isFileURL, receipt.trashedURL.isFileURL else { return false }
        let original = receipt.originalURL.standardizedFileURL.path
        let trashed = receipt.trashedURL.standardizedFileURL.path
        return original == target.canonicalPath
            && original.hasPrefix("/")
            && trashed.hasPrefix("/")
            && original != "/"
            && trashed != "/"
            && original != trashed
    }

    private static func hasValidIssueBinding(
        _ disposition: OperationDisposition,
        requestID: UUID
    ) -> Bool {
        let expectedSubjectID = requestID.uuidString
        switch disposition {
        case .failed(let issue), .skipped(let issue):
            return issue.subjectID == expectedSubjectID
        case .cancelled(nil):
            return true
        case .cancelled(.some(let issue)):
            return issue.subjectID == expectedSubjectID
        case .succeeded, .unchanged:
            return true
        }
    }
}
