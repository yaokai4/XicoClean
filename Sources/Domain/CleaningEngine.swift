import Foundation
import os

/// 清理引擎：执行清理计划。
/// 默认所有删除走废纸篓（可恢复）；每一项删除前都经过 SafetyEngine 校验。
public actor CleaningEngine {
    private static let log = Logger(subsystem: "com.xico.app", category: "clean")

    private struct CleaningRequest: Sendable {
        let requestID: UUID
        let item: CleanableItem
        let intent: DeleteIntent
        let prerequisite: CleaningPrerequisite
        let authorization: CleaningRetryAuthorization
        let remediationRequestID: UUID?
        let remediationRetryToken: ThreatRemediationRetryToken?
    }

    private struct BoundRetryOccurrence: Sendable {
        let priorDeletionOccurrenceIndex: Int
        let authorization: CleaningRetryAuthorization
        let deletion: CleaningItemResult
        let auxiliary: CleaningAuxiliaryItemResult?
    }

    private struct PreparedRetryOccurrence: Sendable {
        let bound: BoundRetryOccurrence
        let request: CleaningRequest
        let retriesDeletion: Bool
        let retriesAuxiliary: Bool
    }

    private struct UndoRequest: Sendable {
        let requestID: UUID
        let item: RestorableItem
        let endpointPaths: [String]
    }

    private enum RetryValidationFailure: Error {
        case invalidPriorKind
        case invalidPriorFacts
        case inventoryMismatch
        case duplicateRetryTarget

        var code: String {
            switch self {
            case .invalidPriorKind: "cleaning.retry.invalidPriorKind"
            case .invalidPriorFacts: "cleaning.retry.invalidPriorFacts"
            case .inventoryMismatch: "cleaning.retry.inventoryMismatch"
            case .duplicateRetryTarget: "cleaning.retry.duplicateTarget"
            }
        }
    }

    private let safety: SafetyEngine
    private let fs: FileSystemService
    private let privileged: PrivilegedCleaningService?
    private let threatRemediation: (any ThreatRemediationExecuting)?
    private var activeNormalizedPaths: Set<String> = []

    public init(safety: SafetyEngine,
                fs: FileSystemService,
                privileged: PrivilegedCleaningService? = nil,
                threatRemediation: (any ThreatRemediationExecuting)? = nil) {
        self.safety = safety
        self.fs = fs
        self.privileged = privileged
        self.threatRemediation = threatRemediation
    }

    public func execute(
        _ plan: CleaningPlan,
        progress: @escaping ProgressHandler = { _ in }
    ) async -> CleaningReport {
        await execute(
            [plan],
            purpose: .standard,
            parentID: nil,
            progress: progress)
    }

    func execute(
        _ plan: CleaningPlan,
        purpose: CleaningOperationPurpose,
        progress: @escaping ProgressHandler = { _ in }
    ) async -> CleaningReport {
        await execute(
            [plan],
            purpose: purpose,
            parentID: nil,
            progress: progress)
    }

    /// Retries only payload-backed retryable facts from a prior standard cleaning terminal.
    /// The complete original ordered inventory is rebound before any dependency is invoked.
    public func retry(
        _ prior: CleaningReport,
        progress: @escaping ProgressHandler = { _ in }
    ) async -> CleaningRetryExecution {
        guard prior.facts.count <= CleaningOperationLimits.maximumFactCount else {
            return Self.inventoryLimitRetryExecution(
                prior: prior,
                projectedFactCount: prior.facts.count,
                preserveBoundedReceipts: false)
        }
        let bound: [BoundRetryOccurrence]
        do {
            bound = try Self.bindRetryInventory(prior: prior)
        } catch let failure as RetryValidationFailure {
            return Self.rejectedRetryExecution(prior: prior, code: failure.code)
        } catch {
            return Self.rejectedRetryExecution(
                prior: prior,
                code: RetryValidationFailure.invalidPriorFacts.code)
        }

        var generated = Set<UUID>()
        func nextID() -> UUID {
            var value = UUID()
            while !generated.insert(value).inserted { value = UUID() }
            return value
        }

        let prepared = bound.compactMap { occurrence -> PreparedRetryOccurrence? in
            let deletionFact = CleaningOperationFact.deletion(occurrence.deletion)
            var retriesDeletion = OperationConsumerFacts.isRetryable(deletionFact)
            var retriesAuxiliary = occurrence.auxiliary.map {
                OperationConsumerFacts.isRetryable(.auxiliary($0))
            } ?? false
            let needsThreatPrerequisite = occurrence.authorization.prerequisite
                == .threatRemediation
                && occurrence.authorization.item.url.pathExtension
                    .caseInsensitiveCompare("plist") == .orderedSame
            if retriesDeletion, needsThreatPrerequisite {
                if let auxiliary = occurrence.auxiliary {
                    switch auxiliary.disposition {
                    case .succeeded, .unchanged:
                        // A prior bootout/probe is not a durable prerequisite authorization.
                        // While the plist still exists the agent may have been loaded again, so
                        // every deletion retry refreshes R before acting on D.
                        retriesAuxiliary = true
                    default:
                        let canRestartFromSource =
                            OperationConsumerFacts.isRetryable(auxiliary.disposition)
                            && auxiliary.mutation == .none
                            && occurrence.deletion.mutation == .none
                        if canRestartFromSource {
                            retriesAuxiliary = true
                        } else if !retriesAuxiliary {
                            // Never retry a prerequisite-bound deletion by silently bypassing R.
                            retriesDeletion = false
                        }
                    }
                    if case .cancelled = auxiliary.disposition,
                       case .cancelled = occurrence.deletion.disposition,
                       auxiliary.mutation == .none {
                        retriesAuxiliary = true
                    }
                } else {
                    // A prior in-flight preflight has no R fact; retry owns the prerequisite.
                    retriesAuxiliary = true
                }
            }
            guard retriesDeletion || retriesAuxiliary else { return nil }
            let requestID = nextID()
            return PreparedRetryOccurrence(
                bound: occurrence,
                request: CleaningRequest(
                    requestID: requestID,
                    item: occurrence.authorization.item,
                    intent: occurrence.authorization.intent,
                    prerequisite: occurrence.authorization.prerequisite,
                    authorization: occurrence.authorization,
                    remediationRequestID: retriesAuxiliary ? nextID() : nil,
                    // A deletion retry means the source still exists and must be parsed again.
                    // Reusing R's old token here could boot out a stale label after the plist was
                    // replaced. Only an auxiliary-only retry may rely on the carried token because
                    // its successful D fact says the source is already gone.
                    remediationRetryToken: retriesAuxiliary && !retriesDeletion
                        ? occurrence.auxiliary?.retryToken
                        : nil),
                retriesDeletion: retriesDeletion,
                retriesAuxiliary: retriesAuxiliary)
        }
        guard !prepared.isEmpty else {
            return Self.rejectedRetryExecution(
                prior: prior,
                code: "cleaning.retry.nothingRetryable")
        }
        let projectedRetryFactCount = Self.projectedRetryFactCount(prepared)
        guard projectedRetryFactCount <= CleaningOperationLimits.maximumFactCount else {
            return Self.inventoryLimitRetryExecution(
                prior: prior,
                projectedFactCount: projectedRetryFactCount,
                preserveBoundedReceipts: true)
        }

        let correlationPaths = prepared.map {
            $0.request.item.url.standardizedFileURL.path
        }
        guard Set(correlationPaths).count == correlationPaths.count else {
            return Self.rejectedRetryExecution(
                prior: prior,
                code: RetryValidationFailure.duplicateRetryTarget.code)
        }

        let startedAt = Date()
        let operationID = UUID()
        let reservedPaths = Set(correlationPaths.filter { !activeNormalizedPaths.contains($0) })
        let inFlightPaths = Set(correlationPaths).intersection(activeNormalizedPaths)
        activeNormalizedPaths.formUnion(reservedPaths)
        defer { activeNormalizedPaths.subtract(reservedPaths) }

        var cancellationAccepted = false
        let remediationRequests = prepared.compactMap { occurrence
            -> ThreatRemediationRequest? in
            guard occurrence.retriesAuxiliary,
                  !inFlightPaths.contains(
                    occurrence.request.item.url.standardizedFileURL.path),
                  let remediationID = occurrence.request.remediationRequestID else {
                return nil
            }
            return ThreatRemediationRequest(
                requestID: remediationID,
                relatedCleaningRequestID: occurrence.request.requestID,
                url: occurrence.request.item.url,
                retryToken: occurrence.request.remediationRetryToken)
        }
        var supplemental: [OperationResult<ThreatRemediationReport>] = []
        if !remediationRequests.isEmpty {
            let remediation: OperationResult<ThreatRemediationReport>
            if Task.isCancelled {
                cancellationAccepted = true
                remediation = Self.cancelledRemediationResult(
                    for: remediationRequests,
                    operationID: UUID(),
                    parentID: operationID)
            } else if let threatRemediation {
                let remediationOperationID = UUID()
                let received = await threatRemediation.remediate(
                    remediationRequests,
                    operationID: remediationOperationID,
                    parentID: operationID)
                remediation = Self.validatedRemediationResult(
                    received,
                    expected: remediationRequests,
                    operationID: remediationOperationID,
                    parentID: operationID)
            } else {
                remediation = Self.unavailableRemediationResult(
                    for: remediationRequests,
                    operationID: UUID(),
                    parentID: operationID)
            }
            supplemental.append(remediation)
            if remediation.outcome.status == .cancelled || Task.isCancelled {
                cancellationAccepted = true
            }
        }
        let inFlightRemediationRequests = prepared.compactMap { occurrence
            -> ThreatRemediationRequest? in
            guard occurrence.retriesAuxiliary,
                  inFlightPaths.contains(
                    occurrence.request.item.url.standardizedFileURL.path),
                  let remediationID = occurrence.request.remediationRequestID else {
                return nil
            }
            return ThreatRemediationRequest(
                requestID: remediationID,
                relatedCleaningRequestID: occurrence.request.requestID,
                url: occurrence.request.item.url,
                retryToken: occurrence.request.remediationRetryToken)
        }
        if !inFlightRemediationRequests.isEmpty {
            supplemental.append(Self.failedRemediationResult(
                for: inFlightRemediationRequests,
                operationID: UUID(),
                parentID: operationID,
                code: "threat.remediation.request.inFlight",
                mutation: .none))
        }

        let deletionRetryCount = prepared.reduce(into: 0) {
            if $1.retriesDeletion { $0 += 1 }
        }
        var completedDeletionRetries = 0
        var reclaimedForProgress: Int64 = 0
        var deletionResults: [CleaningItemResult] = []
        deletionResults.reserveCapacity(prepared.count)
        for occurrence in prepared {
            let request = occurrence.request
            let result: CleaningItemResult
            if !occurrence.retriesDeletion {
                result = Self.result(
                    for: request,
                    intent: request.intent,
                    disposition: .unchanged,
                    mutation: .none)
            } else if inFlightPaths.contains(request.item.url.standardizedFileURL.path) {
                let issue = Self.issue(
                    code: "cleaning.request.inFlight",
                    category: .internalInvariant,
                    requestID: request.requestID,
                    recovery: .retry,
                    retryable: true)
                result = Self.result(
                    for: request,
                    intent: request.intent,
                    disposition: .failed(issue),
                    mutation: .none)
            } else if cancellationAccepted || Task.isCancelled {
                cancellationAccepted = true
                result = Self.result(
                    for: request,
                    intent: request.intent,
                    disposition: .cancelled(nil),
                    mutation: .none)
            } else {
                result = await executeItem(request, intent: request.intent)
            }
            deletionResults.append(result)
            guard occurrence.retriesDeletion else { continue }
            completedDeletionRetries += 1
            if result.disposition == .succeeded {
                reclaimedForProgress = saturatedNonnegativeSum(
                    reclaimedForProgress,
                    result.reclaimedBytes)
            }
            progress(ScanProgress(
                fraction: deletionRetryCount > 0
                    ? Double(completedDeletionRetries) / Double(deletionRetryCount)
                    : nil,
                message: request.item.displayName,
                bytesFound: reclaimedForProgress))
            if Task.isCancelled { cancellationAccepted = true }
        }

        let operationItems = deletionResults.map {
            OperationItemOutcome(
                subjectID: $0.requestID.uuidString,
                disposition: $0.disposition,
                mutation: $0.mutation,
                affectedBytes: $0.reclaimedBytes)
        }
        let finishedAt = Date()
        let childOutcome: OperationOutcome
        do {
            childOutcome = try OperationOutcomeReducer.reduce(
                id: UUID(),
                parentID: operationID,
                kind: .cleaningExecute,
                requestedSubjectIDs: deletionResults.map { $0.requestID.uuidString },
                itemOutcomes: operationItems,
                cancellationAccepted: cancellationAccepted,
                startedAt: startedAt,
                finishedAt: finishedAt)
        } catch {
            childOutcome = OperationOutcomeReducer.internalFailure(
                parentID: operationID,
                kind: .cleaningExecute,
                requestedSubjectIDs: deletionResults.map { $0.requestID.uuidString },
                itemOutcomes: operationItems,
                cancellationAccepted: cancellationAccepted,
                code: "cleaning.retry.reducer.invariant",
                startedAt: startedAt,
                finishedAt: finishedAt)
        }
        let childReport = CleaningReport(operation: childOutcome, items: deletionResults)
        do {
            let merged = try CleaningReport.merging(
                [childReport],
                supplemental: supplemental,
                purpose: .standard,
                id: operationID,
                parentID: prior.operation.id,
                occurrenceOrder: deletionResults.map(\.requestID))
            let occurrences = zip(prepared, deletionResults).map { value in
                CleaningRetryOccurrenceExecution(
                    priorDeletionOccurrenceIndex:
                        value.0.bound.priorDeletionOccurrenceIndex,
                    deletionRequestID: value.1.requestID,
                    performedDeletion: value.0.retriesDeletion)
            }
            let receipts = Self.retryReceiptLedger(
                prior: prior,
                current: merged)
            let report = CleaningReport(
                operation: merged.operation,
                facts: merged.facts,
                retryReceiptLedger: receipts)
            return CleaningRetryExecution(
                report: report,
                occurrences: occurrences,
                retainedReceipts: receipts)
        } catch let error as CleaningReportMergeError {
            let receipts = Self.retryReceiptLedger(
                prior: prior,
                current: error.failClosedReport)
            return CleaningRetryExecution(
                report: CleaningReport(
                    operation: error.failClosedReport.operation,
                    facts: error.failClosedReport.facts,
                    retryReceiptLedger: receipts,
                    rejectionMetadata: error.failClosedReport.rejectionMetadata),
                occurrences: [],
                retainedReceipts: receipts)
        } catch {
            let report = Self.unexpectedMergeFailure(
                childReport: childReport,
                operationID: operationID,
                parentID: prior.operation.id,
                startedAt: startedAt,
                finishedAt: Date())
            let receipts = Self.retryReceiptLedger(prior: prior, current: report)
            return CleaningRetryExecution(
                report: CleaningReport(
                    operation: report.operation,
                    facts: report.facts,
                    retryReceiptLedger: receipts,
                    rejectionMetadata: report.rejectionMetadata),
                occurrences: [],
                retainedReceipts: receipts)
        }
    }

    /// Executes every child plan as one correlated operation. The complete target inventory is
    /// prepared before any remediation, safety, filesystem, or helper dependency is invoked.
    public func execute(
        _ plans: [CleaningPlan],
        parentID: UUID? = nil,
        progress: @escaping ProgressHandler = { _ in }
    ) async -> CleaningReport {
        await execute(
            plans,
            purpose: .standard,
            parentID: parentID,
            progress: progress)
    }

    func execute(
        _ plans: [CleaningPlan],
        purpose: CleaningOperationPurpose,
        parentID: UUID? = nil,
        progress: @escaping ProgressHandler = { _ in }
    ) async -> CleaningReport {
        let startedAt = Date()
        let operationKind = purpose.operationKind
        let rootOperationID = UUID()
        let projectedFactCount = Self.projectedFactCount(for: plans)
        guard projectedFactCount > 0 else {
            let operation = OperationOutcomeReducer.internalFailure(
                id: rootOperationID,
                parentID: parentID,
                kind: operationKind,
                requestedSubjectIDs: [],
                code: "cleaning.request.empty",
                startedAt: startedAt,
                finishedAt: Date())
            return CleaningReport(operation: operation, items: [])
        }
        guard projectedFactCount <= CleaningOperationLimits.maximumFactCount else {
            return Self.inventoryLimitReport(
                projectedFactCount: projectedFactCount,
                operationID: rootOperationID,
                parentID: parentID,
                kind: operationKind,
                startedAt: startedAt)
        }
        let requests = Self.makeRequests(for: plans)

        let duplicateRequestIDs = Self.duplicateRequestIDs(in: requests)
        var inFlightRequestIDs: Set<UUID> = []
        var preflightResults: [UUID: CleaningItemResult] = [:]
        var reservedPaths: Set<String> = []
        for request in requests {
            if duplicateRequestIDs.contains(request.requestID) { continue }
            let path = request.item.url.standardizedFileURL.path
            if activeNormalizedPaths.contains(path) {
                inFlightRequestIDs.insert(request.requestID)
            } else if request.item.isInformational {
                let issue = Self.issue(
                    code: "cleaning.item.informational",
                    category: .safetyPolicy,
                    requestID: request.requestID,
                    recovery: .manualAction,
                    retryable: false)
                preflightResults[request.requestID] = Self.result(
                    for: request,
                    intent: request.intent,
                    disposition: .skipped(issue),
                    mutation: .none)
            } else if !safety.verify(request.item.url, intent: request.intent).isAllowed {
                let issue = Self.issue(
                    code: "cleaning.safety.denied",
                    category: .safetyPolicy,
                    requestID: request.requestID,
                    recovery: .chooseAnotherTarget,
                    retryable: false)
                preflightResults[request.requestID] = Self.result(
                    for: request,
                    intent: request.intent,
                    disposition: .skipped(issue),
                    mutation: .none)
            } else {
                reservedPaths.insert(path)
            }
        }
        activeNormalizedPaths.formUnion(reservedPaths)
        defer { activeNormalizedPaths.subtract(reservedPaths) }

        var cancellationAccepted = false
        var supplemental: [OperationResult<ThreatRemediationReport>] = []
        let remediationRequests = requests.compactMap { request -> ThreatRemediationRequest? in
            guard !duplicateRequestIDs.contains(request.requestID),
                  !inFlightRequestIDs.contains(request.requestID),
                  preflightResults[request.requestID] == nil,
                  let remediationRequestID = request.remediationRequestID else {
                return nil
            }
            return ThreatRemediationRequest(
                requestID: remediationRequestID,
                relatedCleaningRequestID: request.requestID,
                url: request.item.url,
                retryToken: nil)
        }
        if !remediationRequests.isEmpty {
            let remediationResult: OperationResult<ThreatRemediationReport>
            if Task.isCancelled {
                cancellationAccepted = true
                remediationResult = Self.cancelledRemediationResult(
                    for: remediationRequests,
                    operationID: UUID(),
                    parentID: rootOperationID)
            } else if let threatRemediation {
                let remediationOperationID = UUID()
                let received = await threatRemediation.remediate(
                    remediationRequests,
                    operationID: remediationOperationID,
                    parentID: rootOperationID)
                remediationResult = Self.validatedRemediationResult(
                    received,
                    expected: remediationRequests,
                    operationID: remediationOperationID,
                    parentID: rootOperationID)
            } else {
                remediationResult = Self.unavailableRemediationResult(
                    for: remediationRequests,
                    operationID: UUID(),
                    parentID: rootOperationID)
            }
            supplemental.append(remediationResult)
            if remediationResult.outcome.status == .cancelled || Task.isCancelled {
                cancellationAccepted = true
            }
        }

        var results: [CleaningItemResult] = []
        results.reserveCapacity(requests.count)
        var reclaimedForProgress: Int64 = 0

        for (index, request) in requests.enumerated() {
            let result: CleaningItemResult
            let suppressProgress: Bool
            if duplicateRequestIDs.contains(request.requestID) {
                let issue = Self.issue(
                    code: "cleaning.request.duplicateTarget",
                    category: .internalInvariant,
                    requestID: request.requestID,
                    recovery: .chooseAnotherTarget,
                    retryable: false)
                result = Self.result(for: request,
                                     intent: request.intent,
                                     disposition: .failed(issue),
                                     mutation: .none)
                suppressProgress = true
            } else if inFlightRequestIDs.contains(request.requestID) {
                let issue = Self.issue(
                    code: "cleaning.request.inFlight",
                    category: .internalInvariant,
                    requestID: request.requestID,
                    recovery: .retry,
                    retryable: true)
                result = Self.result(for: request,
                                     intent: request.intent,
                                     disposition: .failed(issue),
                                     mutation: .none)
                suppressProgress = true
            } else if let prepared = preflightResults[request.requestID] {
                result = prepared
                suppressProgress = true
            } else if cancellationAccepted || Task.isCancelled {
                cancellationAccepted = true
                result = Self.result(
                    for: request,
                    intent: request.intent,
                    disposition: .cancelled(nil),
                    mutation: .none)
                suppressProgress = true
            } else {
                result = await executeItem(request, intent: request.intent)
                suppressProgress = false
            }
            results.append(result)
            if Task.isCancelled { cancellationAccepted = true }

            if result.disposition == .succeeded {
                reclaimedForProgress = saturatedNonnegativeSum(
                    reclaimedForProgress,
                    result.reclaimedBytes)
            }
            if !suppressProgress {
                progress(ScanProgress(
                    fraction: Double(index + 1) / Double(requests.count),
                    message: request.item.displayName,
                    bytesFound: reclaimedForProgress))
                if Task.isCancelled { cancellationAccepted = true }
            }
        }

        let operationItems = results.map {
            OperationItemOutcome(subjectID: $0.requestID.uuidString,
                                 disposition: $0.disposition,
                                 mutation: $0.mutation,
                                 affectedBytes: $0.reclaimedBytes)
        }
        let requestIDs = requests.map { $0.requestID.uuidString }
        let finishedAt = Date()
        if Task.isCancelled { cancellationAccepted = true }
        let childOperationID = UUID()
        let childOperation: OperationOutcome
        do {
            childOperation = try OperationOutcomeReducer.reduce(
                id: childOperationID,
                parentID: rootOperationID,
                kind: operationKind,
                requestedSubjectIDs: requestIDs,
                itemOutcomes: operationItems,
                cancellationAccepted: cancellationAccepted,
                startedAt: startedAt,
                finishedAt: finishedAt)
        } catch {
            childOperation = OperationOutcomeReducer.internalFailure(
                id: childOperationID,
                parentID: rootOperationID,
                kind: operationKind,
                requestedSubjectIDs: requestIDs,
                itemOutcomes: operationItems,
                cancellationAccepted: cancellationAccepted,
                code: "cleaning.reducer.invariant",
                startedAt: startedAt,
                finishedAt: finishedAt)
        }
        let childReport = CleaningReport(operation: childOperation, items: results)
        do {
            return try CleaningReport.merging(
                [childReport],
                supplemental: supplemental,
                purpose: purpose,
                id: rootOperationID,
                parentID: parentID,
                occurrenceOrder: requests.map(\.requestID))
        } catch let error as CleaningReportMergeError {
            return error.failClosedReport
        } catch {
            return Self.unexpectedMergeFailure(
                childReport: childReport,
                operationID: rootOperationID,
                parentID: parentID,
                startedAt: startedAt,
                finishedAt: Date())
        }
    }

    private func executeItem(
        _ request: CleaningRequest,
        intent: DeleteIntent
    ) async -> CleaningItemResult {
        let item = request.item

        // 仅提示项只提供官方处置指引，任何清理计划都不能把它变成删除请求。
        if item.isInformational {
            let issue = Self.issue(
                code: "cleaning.item.informational",
                category: .safetyPolicy,
                requestID: request.requestID,
                recovery: .manualAction,
                retryable: false)
            return Self.result(for: request,
                               intent: intent,
                               disposition: .skipped(issue),
                               mutation: .none)
        }

        // 废纸篓内叶子软链的永久删除只删除链接本身，不解析或跟随目标。
        if intent == .permanent, Self.isInsideTrash(item.url), Self.isSymlink(item.url) {
            do {
                try fs.remove(item.url)
                return Self.result(for: request,
                                   intent: intent,
                                   disposition: .succeeded,
                                   mutation: .changed,
                                   reclaimedBytes: item.estimatedReclaimableBytes)
            } catch {
                Self.log.error("cleaning.filesystem.operationFailed count=1")
                let issue = Self.issue(
                    code: "cleaning.filesystem.operationFailed",
                    category: .io,
                    requestID: request.requestID,
                    recovery: .retry,
                    retryable: true)
                return Self.result(for: request,
                                   intent: intent,
                                   disposition: .failed(issue),
                                   mutation: .possiblyChanged)
            }
        }

        guard safety.verify(item.url, intent: intent).isAllowed else {
            let issue = Self.issue(
                code: "cleaning.safety.denied",
                category: .safetyPolicy,
                requestID: request.requestID,
                recovery: .chooseAnotherTarget,
                retryable: false)
            return Self.result(for: request,
                               intent: intent,
                               disposition: .skipped(issue),
                               mutation: .none)
        }

        guard fs.exists(item.url) else {
            return Self.result(for: request,
                               intent: intent,
                               disposition: .unchanged,
                               mutation: .none)
        }

        if item.requiresHelper {
            return await executePrivilegedItem(request, intent: intent)
        }

        let resolved = item.url.resolvingSymlinksInPath()
        guard safety.verify(item.url, intent: intent).isAllowed,
              safety.verify(resolved, intent: intent).isAllowed else {
            Self.log.error("cleaning.safety.identityChanged count=1")
            let issue = Self.issue(
                code: "cleaning.safety.identityChanged",
                category: .identityChanged,
                requestID: request.requestID,
                recovery: .retry,
                retryable: true)
            return Self.result(for: request,
                               intent: intent,
                               disposition: .failed(issue),
                               mutation: .none)
        }

        if intent == .permanent, Self.isSymlink(item.url) {
            Self.log.error("cleaning.safety.identityChanged count=1")
            let issue = Self.issue(
                code: "cleaning.safety.identityChanged",
                category: .identityChanged,
                requestID: request.requestID,
                recovery: .retry,
                retryable: true)
            return Self.result(for: request,
                               intent: intent,
                               disposition: .failed(issue),
                               mutation: .none)
        }

        do {
            switch intent {
            case .trash:
                let trashedURL = try fs.trash(item.url)
                let receipt = RestorableItem(originalURL: item.url, trashedURL: trashedURL)
                return Self.result(for: request,
                                   intent: intent,
                                   disposition: .succeeded,
                                   mutation: .changed,
                                   reclaimedBytes: item.estimatedReclaimableBytes,
                                   restorable: receipt)
            case .permanent:
                try fs.remove(item.url)
                return Self.result(for: request,
                                   intent: intent,
                                   disposition: .succeeded,
                                   mutation: .changed,
                                   reclaimedBytes: item.estimatedReclaimableBytes)
            }
        } catch {
            Self.log.error("cleaning.filesystem.operationFailed count=1")
            let issue = Self.issue(
                code: "cleaning.filesystem.operationFailed",
                category: .io,
                requestID: request.requestID,
                recovery: .retry,
                retryable: true)
            return Self.result(for: request,
                               intent: intent,
                               disposition: .failed(issue),
                               mutation: .possiblyChanged)
        }
    }

    private func executePrivilegedItem(
        _ request: CleaningRequest,
        intent: DeleteIntent
    ) async -> CleaningItemResult {
        guard let privileged else {
            let issue = Self.issue(
                code: "cleaning.helper.unavailable",
                category: .unavailable,
                requestID: request.requestID,
                recovery: .installHelper,
                retryable: true)
            return Self.result(for: request,
                               intent: intent,
                               disposition: .failed(issue),
                               mutation: .none)
        }
        guard intent == .permanent else {
            let issue = Self.issue(
                code: "cleaning.helper.intentMismatch",
                category: .validation,
                requestID: request.requestID,
                recovery: .chooseAnotherTarget,
                retryable: false)
            return Self.result(for: request,
                               intent: intent,
                               disposition: .failed(issue),
                               mutation: .none)
        }

        let report = await privileged.removeProtected([request.item.url])
        let requestedPath = request.item.url.standardizedFileURL.path
        let failedPaths = report.failures.map { $0.standardizedFileURL.path }

        if failedPaths.contains(where: { $0 != requestedPath }) {
            Self.log.error("cleaning.helper.unexpectedFailurePath count=1")
            let issue = Self.issue(
                code: "cleaning.helper.unexpectedFailurePath",
                category: .internalInvariant,
                requestID: request.requestID,
                recovery: .retry,
                retryable: true)
            return Self.result(for: request,
                               intent: intent,
                               disposition: .failed(issue),
                               mutation: .possiblyChanged)
        }
        if failedPaths.contains(requestedPath) {
            Self.log.error("cleaning.helper.removalFailed count=1")
            let issue = Self.issue(
                code: "cleaning.helper.removalFailed",
                category: .io,
                requestID: request.requestID,
                recovery: .retry,
                retryable: true)
            return Self.result(for: request,
                               intent: intent,
                               disposition: .failed(issue),
                               mutation: .possiblyChanged)
        }
        if fs.exists(request.item.url) {
            Self.log.error("cleaning.helper.targetStillExists count=1")
            let issue = Self.issue(
                code: "cleaning.helper.targetStillExists",
                category: .io,
                requestID: request.requestID,
                recovery: .retry,
                retryable: true)
            return Self.result(for: request,
                               intent: intent,
                               disposition: .failed(issue),
                               mutation: .possiblyChanged)
        }

        return Self.result(for: request,
                           intent: intent,
                           disposition: .succeeded,
                           mutation: .changed,
                           reclaimedBytes: report.freedBytes)
    }

    /// Restores exact Trash receipts and returns one reducer fact for every requested receipt.
    public func undo(
        _ items: [RestorableItem],
        parentID: UUID? = nil
    ) async -> OperationResult<UndoReport> {
        let operationID = UUID()
        let startedAt = Date()
        guard !items.isEmpty else {
            let outcome = OperationOutcomeReducer.internalFailure(
                id: operationID,
                parentID: parentID,
                kind: .cleaningUndo,
                requestedSubjectIDs: [],
                code: "cleaning.undo.empty",
                startedAt: startedAt,
                finishedAt: Date())
            return OperationResult(outcome: outcome, payload: UndoReport(items: []))
        }

        var generated = Set<UUID>()
        let requests = items.map { item -> UndoRequest in
            var requestID = UUID()
            while !generated.insert(requestID).inserted {
                requestID = UUID()
            }
            return UndoRequest(
                requestID: requestID,
                item: item,
                endpointPaths: [
                    item.originalURL.standardizedFileURL.path,
                    item.trashedURL.standardizedFileURL.path
                ])
        }

        var endpointOwners: [String: [UUID]] = [:]
        for request in requests {
            for path in request.endpointPaths {
                endpointOwners[path, default: []].append(request.requestID)
            }
        }
        let duplicateRequestIDs = Set(endpointOwners.values.flatMap { owners in
            owners.count > 1 ? owners : []
        })
        var inFlightRequestIDs = Set<UUID>()
        var ownedReservedPaths = Set<String>()
        for request in requests where !duplicateRequestIDs.contains(request.requestID) {
            if request.endpointPaths.contains(where: activeNormalizedPaths.contains) {
                inFlightRequestIDs.insert(request.requestID)
            } else {
                ownedReservedPaths.formUnion(request.endpointPaths)
            }
        }
        activeNormalizedPaths.formUnion(ownedReservedPaths)
        defer { activeNormalizedPaths.subtract(ownedReservedPaths) }

        var results: [UndoItemResult] = []
        results.reserveCapacity(requests.count)
        var cancellationAccepted = false
        for request in requests {
            let requestID = request.requestID
            let item = request.item
            if duplicateRequestIDs.contains(requestID) {
                let issue = OperationIssue(
                    code: "cleaning.undo.duplicateTarget",
                    category: .internalInvariant,
                    subjectID: requestID.uuidString,
                    recovery: .chooseAnotherTarget,
                    retryable: false)
                results.append(UndoItemResult(
                    requestID: requestID,
                    item: item,
                    disposition: .failed(issue),
                    mutation: .none))
                continue
            } else if inFlightRequestIDs.contains(requestID) {
                let issue = OperationIssue(
                    code: "cleaning.undo.inFlight",
                    category: .internalInvariant,
                    subjectID: requestID.uuidString,
                    recovery: .retry,
                    retryable: true)
                results.append(UndoItemResult(
                    requestID: requestID,
                    item: item,
                    disposition: .failed(issue),
                    mutation: .none))
                continue
            } else if cancellationAccepted || Task.isCancelled {
                cancellationAccepted = true
                results.append(UndoItemResult(
                    requestID: requestID,
                    item: item,
                    disposition: .cancelled(nil),
                    mutation: .none))
                continue
            }
            do {
                try fs.restore(item)
                results.append(UndoItemResult(
                    requestID: requestID,
                    item: item,
                    disposition: .succeeded,
                    mutation: .changed))
            } catch {
                Self.log.error("cleaning.undo.restoreFailed count=1")
                let issue = OperationIssue(
                    code: "cleaning.undo.restoreFailed",
                    category: .io,
                    subjectID: requestID.uuidString,
                    recovery: .retry,
                    retryable: true)
                results.append(UndoItemResult(
                    requestID: requestID,
                    item: item,
                    disposition: .failed(issue),
                    mutation: .possiblyChanged))
            }
            if Task.isCancelled { cancellationAccepted = true }
        }

        let requestedIDs = requests.map { $0.requestID.uuidString }
        let operationItems = results.map {
            OperationItemOutcome(
                subjectID: $0.requestID.uuidString,
                disposition: $0.disposition,
                mutation: $0.mutation)
        }
        let finishedAt = Date()
        let outcome: OperationOutcome
        do {
            outcome = try OperationOutcomeReducer.reduce(
                id: operationID,
                parentID: parentID,
                kind: .cleaningUndo,
                requestedSubjectIDs: requestedIDs,
                itemOutcomes: operationItems,
                cancellationAccepted: cancellationAccepted,
                startedAt: startedAt,
                finishedAt: finishedAt)
        } catch {
            outcome = OperationOutcomeReducer.internalFailure(
                id: operationID,
                parentID: parentID,
                kind: .cleaningUndo,
                requestedSubjectIDs: requestedIDs,
                itemOutcomes: operationItems,
                cancellationAccepted: cancellationAccepted,
                code: "cleaning.undo.reducer.invariant",
                startedAt: startedAt,
                finishedAt: finishedAt)
        }
        return OperationResult(outcome: outcome, payload: UndoReport(items: results))
    }

    /// Transitional convenience for existing live consumers; it delegates to the typed receipt API.
    public func undo(_ report: CleaningReport) async -> UndoResult {
        let result = await undo(report.restorable, parentID: report.operation.id)
        return UndoResult(
            restored: result.payload.restoredCount,
            failed: result.payload.remaining)
    }

    private static func projectedFactCount(for plans: [CleaningPlan]) -> Int {
        var count = 0
        for plan in plans {
            count = saturatedCount(count, plan.items.count)
            guard plan.prerequisite == .threatRemediation else { continue }
            for item in plan.items where
                item.url.pathExtension.caseInsensitiveCompare("plist") == .orderedSame {
                count = saturatedCount(count, 1)
            }
        }
        return count
    }

    private static func projectedRetryFactCount(
        _ occurrences: [PreparedRetryOccurrence]
    ) -> Int {
        var count = occurrences.count
        for occurrence in occurrences where occurrence.retriesAuxiliary {
            count = saturatedCount(count, 1)
        }
        return count
    }

    private static func saturatedCount(_ lhs: Int, _ rhs: Int) -> Int {
        let (sum, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? .max : sum
    }

    private static func inventoryLimitReport(
        projectedFactCount: Int,
        operationID: UUID,
        parentID: UUID?,
        kind: OperationKind,
        startedAt: Date
    ) -> CleaningReport {
        let finishedAt = Date()
        let operation = OperationOutcomeReducer.admissionFailure(
            id: operationID,
            parentID: parentID,
            kind: kind,
            requestedCount: projectedFactCount,
            code: "cleaning.request.inventoryLimitExceeded",
            startedAt: startedAt,
            finishedAt: finishedAt)
        return CleaningReport(
            operation: operation,
            facts: [],
            rejectionMetadata: .inventoryLimit(
                projectedFactCount: projectedFactCount))
    }

    private static func inventoryLimitRetryExecution(
        prior: CleaningReport,
        projectedFactCount: Int,
        preserveBoundedReceipts: Bool
    ) -> CleaningRetryExecution {
        let operationID = UUID()
        let startedAt = Date()
        let finishedAt = Date()
        let operation = OperationOutcomeReducer.admissionFailure(
            id: operationID,
            parentID: prior.operation.id,
            kind: .cleaningExecute,
            requestedCount: projectedFactCount,
            code: "cleaning.request.inventoryLimitExceeded",
            startedAt: startedAt,
            finishedAt: finishedAt)
        let receipts = preserveBoundedReceipts
            ? retryReceiptLedger(prior: prior, current: nil)
            : []
        return CleaningRetryExecution(
            report: CleaningReport(
                operation: operation,
                facts: [],
                retryReceiptLedger: receipts,
                rejectionMetadata: .inventoryLimit(
                    projectedFactCount: projectedFactCount)),
            occurrences: [],
            retainedReceipts: receipts)
    }

    private static func makeRequests(for plans: [CleaningPlan]) -> [CleaningRequest] {
        var generated = Set<UUID>()

        func nextID() -> UUID {
            var requestID = UUID()
            while !generated.insert(requestID).inserted {
                requestID = UUID()
            }
            return requestID
        }

        return plans.flatMap { plan in
            plan.items.map { item in
                let requestID = nextID()
                let needsRemediation = plan.prerequisite == .threatRemediation
                    && item.url.pathExtension.caseInsensitiveCompare("plist") == .orderedSame
                let authorization = CleaningRetryAuthorization(
                    item: item,
                    intent: plan.intent,
                    prerequisite: plan.prerequisite)
                return CleaningRequest(
                    requestID: requestID,
                    item: item,
                    intent: plan.intent,
                    prerequisite: plan.prerequisite,
                    authorization: authorization,
                    remediationRequestID: needsRemediation ? nextID() : nil,
                    remediationRetryToken: nil)
            }
        }
    }

    private static func duplicateRequestIDs(
        in requests: [CleaningRequest]
    ) -> Set<UUID> {
        let paths = Dictionary(grouping: requests, by: { $0.item.url.standardizedFileURL.path })
        let duplicatePaths = Set(paths.compactMap { $0.value.count > 1 ? $0.key : nil })
        return Set(requests.compactMap { request in
            duplicatePaths.contains(request.item.url.standardizedFileURL.path)
                ? request.requestID
                : nil
        })
    }

    private static func cancelledRemediationResult(
        for requests: [ThreatRemediationRequest],
        operationID: UUID,
        parentID: UUID
    ) -> OperationResult<ThreatRemediationReport> {
        remediationResult(
            for: requests,
            operationID: operationID,
            parentID: parentID,
            cancellationAccepted: true) { _ in
                (.cancelled(nil), .none)
            }
    }

    private static func unavailableRemediationResult(
        for requests: [ThreatRemediationRequest],
        operationID: UUID,
        parentID: UUID
    ) -> OperationResult<ThreatRemediationReport> {
        remediationResult(
            for: requests,
            operationID: operationID,
            parentID: parentID,
            cancellationAccepted: false) { request in
                let issue = OperationIssue(
                    code: "threat.remediation.unavailable",
                    category: .unavailable,
                    subjectID: request.requestID.uuidString,
                    recovery: .retry,
                    retryable: true)
                return (.failed(issue), .none)
            }
    }

    private static func remediationResult(
        for requests: [ThreatRemediationRequest],
        operationID: UUID,
        parentID: UUID,
        cancellationAccepted: Bool,
        result: (ThreatRemediationRequest) -> (OperationDisposition, OperationMutationFact)
    ) -> OperationResult<ThreatRemediationReport> {
        let startedAt = Date()
        let items = requests.map { request in
            let value = result(request)
            return ThreatRemediationItemResult(
                requestID: request.requestID,
                relatedCleaningRequestID: request.relatedCleaningRequestID,
                url: request.url,
                disposition: value.0,
                mutation: value.1,
                retryToken: request.retryToken)
        }
        let operationItems = items.map {
            OperationItemOutcome(
                subjectID: $0.requestID.uuidString,
                disposition: $0.disposition,
                mutation: $0.mutation)
        }
        let requestIDs = items.map { $0.requestID.uuidString }
        let finishedAt = Date()
        let outcome: OperationOutcome
        do {
            outcome = try OperationOutcomeReducer.reduce(
                id: operationID,
                parentID: parentID,
                kind: .threatRemediation,
                requestedSubjectIDs: requestIDs,
                itemOutcomes: operationItems,
                cancellationAccepted: cancellationAccepted,
                startedAt: startedAt,
                finishedAt: finishedAt)
        } catch {
            outcome = OperationOutcomeReducer.internalFailure(
                id: operationID,
                parentID: parentID,
                kind: .threatRemediation,
                requestedSubjectIDs: requestIDs,
                itemOutcomes: operationItems,
                cancellationAccepted: cancellationAccepted,
                code: "threat.remediation.reducer.invariant",
                startedAt: startedAt,
                finishedAt: finishedAt)
        }
        return OperationResult(
            outcome: outcome,
            payload: ThreatRemediationReport(items: items))
    }

    private static func validatedRemediationResult(
        _ received: OperationResult<ThreatRemediationReport>,
        expected: [ThreatRemediationRequest],
        operationID: UUID,
        parentID: UUID
    ) -> OperationResult<ThreatRemediationReport> {
        let exact = received.outcome.id == operationID
            && received.outcome.parentID == parentID
            && received.outcome.kind == .threatRemediation
            && CleaningReport.isReducerConsistent(received)
            && received.payload.items.count == expected.count
            && zip(expected, received.payload.items).allSatisfy { request, item in
                guard item.requestID == request.requestID,
                      item.relatedCleaningRequestID == request.relatedCleaningRequestID,
                      item.url.standardizedFileURL.path
                        == request.url.standardizedFileURL.path else {
                    return false
                }
                if let requestToken = request.retryToken,
                   item.retryToken != requestToken {
                    return false
                }
                if let token = item.retryToken,
                   token.rootRelativeIdentity != request.url.lastPathComponent {
                    return false
                }
                return issueSubjectMatchesRequest(
                    disposition: item.disposition,
                    requestID: item.requestID)
            }
        guard exact else {
            return failedRemediationResult(
                for: expected,
                operationID: operationID,
                parentID: parentID,
                code: "threat.remediation.executor.invalidPayload",
                mutation: .possiblyChanged)
        }
        return received
    }

    private static func failedRemediationResult(
        for requests: [ThreatRemediationRequest],
        operationID: UUID,
        parentID: UUID,
        code: String,
        mutation: OperationMutationFact
    ) -> OperationResult<ThreatRemediationReport> {
        remediationResult(
            for: requests,
            operationID: operationID,
            parentID: parentID,
            cancellationAccepted: false) { request in
                let canRetry = mutation == .none || request.retryToken != nil
                let issue = OperationIssue(
                    code: code,
                    category: .internalInvariant,
                    subjectID: request.requestID.uuidString,
                    recovery: canRetry ? .retry : .manualAction,
                    retryable: canRetry)
                return (.failed(issue), mutation)
            }
    }

    private static func unexpectedMergeFailure(
        childReport: CleaningReport,
        operationID: UUID,
        parentID: UUID?,
        startedAt: Date,
        finishedAt: Date
    ) -> CleaningReport {
        let operationItems = childReport.items.map {
            OperationItemOutcome(
                subjectID: $0.requestID.uuidString,
                disposition: $0.disposition,
                mutation: $0.mutation,
                affectedBytes: $0.reclaimedBytes)
        }
        let operation = OperationOutcomeReducer.internalFailure(
            id: operationID,
            parentID: parentID,
            kind: OperationKind("cleaning.merge.rejected"),
            requestedSubjectIDs: childReport.items.map { $0.requestID.uuidString },
            itemOutcomes: operationItems,
            code: "cleaning.merge.unexpected",
            startedAt: startedAt,
            finishedAt: finishedAt)
        return CleaningReport(
            operation: operation,
            facts: childReport.facts,
            rejectionMetadata: .unexpectedMerge)
    }

    private static func result(
        for request: CleaningRequest,
        intent: DeleteIntent,
        disposition: OperationDisposition,
        mutation: OperationMutationFact,
        reclaimedBytes: Int64 = 0,
        restorable: RestorableItem? = nil
    ) -> CleaningItemResult {
        let validatedReceipt = intent == .trash && disposition == .succeeded
            ? restorable
            : nil
        return CleaningItemResult(requestID: request.requestID,
                                  itemID: request.item.id,
                                  url: request.item.url,
                                  intent: intent,
                                  prerequisite: request.prerequisite,
                                  retryAuthorization: request.authorization,
                                  disposition: disposition,
                                  mutation: mutation,
                                  reclaimedBytes: reclaimedBytes,
                                  restorable: validatedReceipt)
    }

    private static func bindRetryInventory(
        prior: CleaningReport
    ) throws -> [BoundRetryOccurrence] {
        guard prior.operation.kind == .cleaningExecute else {
            throw RetryValidationFailure.invalidPriorKind
        }
        guard prior.isReducerBacked else {
            throw RetryValidationFailure.invalidPriorFacts
        }
        let requestIDs = prior.facts.map(\.requestID)
        guard Set(requestIDs).count == requestIDs.count else {
            throw RetryValidationFailure.invalidPriorFacts
        }

        var factIndex = 0
        var occurrenceIndex = 0
        var bound: [BoundRetryOccurrence] = []
        while factIndex < prior.facts.count {
            guard factIndex < prior.facts.count,
                  case let .deletion(deletion) = prior.facts[factIndex],
                  let authorization = deletion.retryAuthorization else {
                throw RetryValidationFailure.invalidPriorFacts
            }
            guard deletion.itemID == authorization.item.id,
                  deletion.url.absoluteString == authorization.item.url.absoluteString,
                  deletion.intent == authorization.intent,
                  deletion.prerequisite == authorization.prerequisite,
                  issueSubjectMatchesRequest(
                    disposition: deletion.disposition,
                    requestID: deletion.requestID) else {
                throw RetryValidationFailure.inventoryMismatch
            }
            factIndex += 1
            var auxiliary: CleaningAuxiliaryItemResult?
            if factIndex < prior.facts.count,
               case let .auxiliary(candidate) = prior.facts[factIndex] {
                guard authorization.prerequisite == .threatRemediation,
                      authorization.item.url.pathExtension
                        .caseInsensitiveCompare("plist") == .orderedSame,
                      candidate.kind == .threatRemediation,
                      candidate.relatedCleaningRequestID == deletion.requestID,
                      candidate.retryToken?.rootRelativeIdentity
                        == authorization.item.url.lastPathComponent
                        || candidate.retryToken == nil,
                      issueSubjectMatchesRequest(
                        disposition: candidate.disposition,
                        requestID: candidate.requestID) else {
                    throw RetryValidationFailure.inventoryMismatch
                }
                auxiliary = candidate
                factIndex += 1
            }
            bound.append(BoundRetryOccurrence(
                priorDeletionOccurrenceIndex: occurrenceIndex,
                authorization: authorization,
                deletion: deletion,
                auxiliary: auxiliary))
            occurrenceIndex += 1
        }
        guard !bound.isEmpty else { throw RetryValidationFailure.invalidPriorFacts }
        return bound
    }

    private static func issueSubjectMatchesRequest(
        disposition: OperationDisposition,
        requestID: UUID
    ) -> Bool {
        let issue: OperationIssue?
        switch disposition {
        case .succeeded, .unchanged:
            return true
        case let .skipped(value), let .failed(value):
            issue = value
        case let .cancelled(value):
            guard let value else { return true }
            issue = value
        }
        return issue?.subjectID == requestID.uuidString
    }

    private static func rejectedRetry(
        prior: CleaningReport,
        code: String
    ) -> CleaningReport {
        let now = Date()
        let operation = OperationOutcomeReducer.internalFailure(
            parentID: prior.operation.id,
            kind: OperationKind("cleaning.retry.rejected"),
            requestedSubjectIDs: [],
            code: code,
            startedAt: now,
            finishedAt: now)
        return CleaningReport(operation: operation, facts: [])
    }

    private static func rejectedRetryExecution(
        prior: CleaningReport,
        code: String
    ) -> CleaningRetryExecution {
        let receipts = retryReceiptLedger(prior: prior, current: nil)
        let rejected = rejectedRetry(prior: prior, code: code)
        return CleaningRetryExecution(
            report: CleaningReport(
                operation: rejected.operation,
                facts: rejected.facts,
                retryReceiptLedger: receipts),
            occurrences: [],
            retainedReceipts: receipts)
    }

    private static func retryReceiptLedger(
        prior: CleaningReport,
        current: CleaningReport?
    ) -> [CleaningRetryReceipt] {
        var receipts = prior.retainedRetryReceipts
        func appendReceipts(from report: CleaningReport) {
            for item in report.items {
                guard item.disposition == .succeeded,
                      let receipt = item.restorable else { continue }
                let entry = CleaningRetryReceipt(
                    ownerOperationID: report.operation.id,
                    deletionRequestID: item.requestID,
                    item: receipt)
                guard !receipts.contains(entry) else { continue }
                receipts.append(entry)
            }
        }
        appendReceipts(from: prior)
        if let current { appendReceipts(from: current) }
        return receipts
    }

    private static func issue(
        code: String,
        category: OperationIssueCategory,
        requestID: UUID,
        recovery: OperationRecoveryHint,
        retryable: Bool
    ) -> OperationIssue {
        OperationIssue(code: code,
                       category: category,
                       subjectID: requestID.uuidString,
                       recovery: recovery,
                       retryable: retryable)
    }

    /// 叶子自身是否为符号链接（lstat 语义，不跟随）。
    private static func isSymlink(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink ?? false
    }

    /// 路径字面量是否锚定于真实废纸篓根内；刻意不解析符号链接。
    private static func isInsideTrash(_ url: URL) -> Bool {
        let comps = url.standardizedFileURL.pathComponents.map { $0.lowercased() }
        let home = FileManager.default.homeDirectoryForCurrentUser
            .standardizedFileURL.pathComponents.map { $0.lowercased() }
        if comps.count > home.count,
           Array(comps.prefix(home.count)) == home,
           comps[home.count] == ".trash" {
            return true
        }
        if let trashIndex = comps.firstIndex(of: ".trashes") {
            let validAnchor = trashIndex == 1
                || (trashIndex == 3 && comps.count > 1 && comps[1] == "volumes")
            if validAnchor && comps.count > trashIndex + 1 { return true }
        }
        return false
    }
}
