import Foundation

public struct OperationKind: RawRepresentable, Hashable, Codable, Sendable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ rawValue: String) { self.rawValue = rawValue }
}

public enum OperationTerminalStatus: String, Codable, Hashable, Sendable {
    case success, partial, failure, cancelled
}

public enum OperationIssueCategory: String, Codable, Hashable, Sendable {
    case permission, safetyPolicy, notFound, identityChanged, io, network
    case authentication, validation, timeout, unavailable, internalInvariant
}

public enum OperationRecoveryHint: String, Codable, Hashable, Sendable {
    case retry, grantPermission, installHelper, reauthenticate, chooseAnotherTarget
    case revealInFinder, openSettings, manualAction, none
}

public struct OperationIssue: Codable, Hashable, Sendable {
    public let code: String
    public let category: OperationIssueCategory
    public let subjectID: String?
    public let recovery: OperationRecoveryHint
    public let retryable: Bool
    public init(code: String, category: OperationIssueCategory, subjectID: String?,
                recovery: OperationRecoveryHint, retryable: Bool) {
        self.code = code
        self.category = category
        self.subjectID = subjectID
        self.recovery = recovery
        self.retryable = retryable
    }
}

public enum OperationDisposition: Sendable, Equatable {
    case succeeded
    case unchanged
    case skipped(OperationIssue)
    case failed(OperationIssue)
    case cancelled(OperationIssue?)
}

public struct OperationItemOutcome: Sendable, Equatable {
    public let subjectID: String
    public let disposition: OperationDisposition
    public let affectedBytes: Int64
    public init(subjectID: String, disposition: OperationDisposition, affectedBytes: Int64 = 0) {
        self.subjectID = subjectID
        self.disposition = disposition
        self.affectedBytes = max(0, affectedBytes)
    }
}

public struct OperationCounts: Codable, Equatable, Sendable {
    public let requested: Int
    public let succeeded: Int
    public let unchanged: Int
    public let skipped: Int
    public let failed: Int
    public let cancelled: Int
    public init(requested: Int, succeeded: Int, unchanged: Int,
                skipped: Int, failed: Int, cancelled: Int) {
        self.requested = requested
        self.succeeded = succeeded
        self.unchanged = unchanged
        self.skipped = skipped
        self.failed = failed
        self.cancelled = cancelled
    }
}

public struct OperationOutcome: Encodable, Identifiable, Sendable {
    public let id: UUID
    public let parentID: UUID?
    public let kind: OperationKind
    public let status: OperationTerminalStatus
    public let counts: OperationCounts
    public let startedAt: Date
    public let finishedAt: Date
    public let issues: [OperationIssue]
    public var hasChanges: Bool { counts.succeeded > 0 }

    fileprivate init(id: UUID, parentID: UUID?, kind: OperationKind,
                     status: OperationTerminalStatus, counts: OperationCounts,
                     startedAt: Date, finishedAt: Date, issues: [OperationIssue]) {
        self.id = id
        self.parentID = parentID
        self.kind = kind
        self.status = status
        self.counts = counts
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.issues = issues
    }
}

public struct OperationResult<Payload: Sendable>: Sendable {
    public let outcome: OperationOutcome
    public let payload: Payload
    public init(outcome: OperationOutcome, payload: Payload) {
        self.outcome = outcome
        self.payload = payload
    }
}

public struct OperationProgress: Sendable, Equatable {
    public let completed: Int
    public let requested: Int
    public let affectedBytes: Int64
    public init(completed: Int, requested: Int, affectedBytes: Int64) {
        self.completed = completed
        self.requested = requested
        self.affectedBytes = max(0, affectedBytes)
    }
}

public enum OperationLifecycle<Payload: Sendable>: Sendable {
    case idle
    case running(OperationProgress)
    case cancelling(OperationProgress)
    case terminal(OperationResult<Payload>)
}

public enum OperationReductionError: Error, Equatable, Sendable {
    case emptyRequest
    case duplicateRequestedSubject(String)
    case invalidTimeRange
}

public enum OperationOutcomeReducer {
    private struct Normalization {
        let dispositions: [OperationDisposition]
        let invariantIssues: [OperationIssue]
        let hasInvariantViolation: Bool
    }

    public static func reduce(
        id: UUID = UUID(), parentID: UUID? = nil, kind: OperationKind,
        requestedSubjectIDs: [String], itemOutcomes: [OperationItemOutcome],
        cancellationAccepted: Bool, startedAt: Date, finishedAt: Date
    ) throws -> OperationOutcome {
        guard !requestedSubjectIDs.isEmpty else { throw OperationReductionError.emptyRequest }
        guard finishedAt >= startedAt else { throw OperationReductionError.invalidTimeRange }

        var requestedSet = Set<String>()
        for subjectID in requestedSubjectIDs {
            guard requestedSet.insert(subjectID).inserted else {
                throw OperationReductionError.duplicateRequestedSubject(subjectID)
            }
        }

        let normalization = normalize(
            requestedSubjectIDs: requestedSubjectIDs,
            requestedSet: requestedSet,
            itemOutcomes: itemOutcomes,
            cancellationAccepted: cancellationAccepted)
        let counts = counts(requested: requestedSubjectIDs.count,
                            dispositions: normalization.dispositions)
        let issues = collectIssues(dispositions: normalization.dispositions,
                                   additional: normalization.invariantIssues)
        let status = reducedStatus(counts: counts,
                                   cancellationAccepted: cancellationAccepted,
                                   hasInvariantViolation: normalization.hasInvariantViolation)

        return OperationOutcome(id: id, parentID: parentID, kind: kind, status: status,
                                counts: counts, startedAt: startedAt, finishedAt: finishedAt,
                                issues: issues)
    }

    static func internalFailure(
        id: UUID = UUID(), parentID: UUID? = nil, kind: OperationKind,
        requestedSubjectIDs: [String], itemOutcomes: [OperationItemOutcome] = [],
        cancellationAccepted: Bool = false, code: String,
        startedAt: Date, finishedAt: Date
    ) -> OperationOutcome {
        let requestedSet = Set(requestedSubjectIDs)
        let normalization = normalize(
            requestedSubjectIDs: requestedSubjectIDs,
            requestedSet: requestedSet,
            itemOutcomes: itemOutcomes,
            cancellationAccepted: cancellationAccepted)
        let counts = counts(requested: requestedSubjectIDs.count,
                            dispositions: normalization.dispositions)
        let invariantIssue = OperationIssue(code: code,
                                            category: .internalInvariant,
                                            subjectID: nil,
                                            recovery: .retry,
                                            retryable: true)
        let issues = collectIssues(
            dispositions: normalization.dispositions,
            additional: normalization.invariantIssues + [invariantIssue])
        let status: OperationTerminalStatus
        if cancellationAccepted {
            status = .cancelled
        } else if counts.succeeded + counts.unchanged > 0 {
            status = .partial
        } else {
            status = .failure
        }
        let clampedFinishedAt = max(startedAt, finishedAt)

        return OperationOutcome(id: id, parentID: parentID, kind: kind, status: status,
                                counts: counts, startedAt: startedAt,
                                finishedAt: clampedFinishedAt, issues: issues)
    }

    private static func normalize(
        requestedSubjectIDs: [String],
        requestedSet: Set<String>,
        itemOutcomes: [OperationItemOutcome],
        cancellationAccepted: Bool
    ) -> Normalization {
        let grouped = Dictionary(grouping: itemOutcomes, by: \.subjectID)
        let requestedCounts = Dictionary(grouping: requestedSubjectIDs, by: { $0 })
            .mapValues(\.count)
        var normalized: [OperationDisposition] = []
        var invariantIssues: [OperationIssue] = []
        var hasInvariantViolation = false

        for subjectID in requestedSubjectIDs {
            let values = grouped[subjectID] ?? []
            if requestedCounts[subjectID, default: 0] > 1 {
                let issue = OperationIssue(code: "operation.request.duplicate",
                                           category: .internalInvariant,
                                           subjectID: subjectID,
                                           recovery: .retry, retryable: true)
                normalized.append(.failed(issue))
                hasInvariantViolation = true
            } else if values.isEmpty {
                if cancellationAccepted {
                    normalized.append(.cancelled(nil))
                } else {
                    let issue = OperationIssue(code: "operation.result.missing",
                                               category: .internalInvariant,
                                               subjectID: subjectID,
                                               recovery: .retry, retryable: true)
                    normalized.append(.failed(issue))
                    hasInvariantViolation = true
                }
            } else if values.count > 1 {
                let issue = OperationIssue(code: "operation.result.duplicate",
                                           category: .internalInvariant,
                                           subjectID: subjectID,
                                           recovery: .retry, retryable: true)
                normalized.append(.failed(issue))
                hasInvariantViolation = true
            } else if let value = values.first {
                normalized.append(value.disposition)
            }
        }

        for subjectID in grouped.keys where !requestedSet.contains(subjectID) {
            invariantIssues.append(OperationIssue(code: "operation.result.unexpected",
                                                  category: .internalInvariant,
                                                  subjectID: subjectID,
                                                  recovery: .none, retryable: false))
            hasInvariantViolation = true
        }

        return Normalization(dispositions: normalized,
                             invariantIssues: invariantIssues,
                             hasInvariantViolation: hasInvariantViolation)
    }

    private static func counts(
        requested: Int,
        dispositions: [OperationDisposition]
    ) -> OperationCounts {
        var succeeded = 0, unchanged = 0, skipped = 0, failed = 0, cancelled = 0
        for disposition in dispositions {
            switch disposition {
            case .succeeded: succeeded += 1
            case .unchanged: unchanged += 1
            case .skipped: skipped += 1
            case .failed: failed += 1
            case .cancelled: cancelled += 1
            }
        }

        return OperationCounts(requested: requested,
                               succeeded: succeeded, unchanged: unchanged,
                               skipped: skipped, failed: failed, cancelled: cancelled)
    }

    private static func collectIssues(
        dispositions: [OperationDisposition],
        additional: [OperationIssue]
    ) -> [OperationIssue] {
        var issues = additional
        for disposition in dispositions {
            switch disposition {
            case let .skipped(issue), let .failed(issue):
                issues.append(issue)
            case let .cancelled(issue):
                if let issue { issues.append(issue) }
            case .succeeded, .unchanged:
                break
            }
        }
        return Array(Set(issues)).sorted(by: issueComesBefore)
    }

    private static func issueComesBefore(
        _ lhs: OperationIssue,
        _ rhs: OperationIssue
    ) -> Bool {
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

    private static func reducedStatus(
        counts: OperationCounts,
        cancellationAccepted: Bool,
        hasInvariantViolation: Bool
    ) -> OperationTerminalStatus {
        let status: OperationTerminalStatus
        if cancellationAccepted {
            status = .cancelled
        } else if hasInvariantViolation && counts.succeeded + counts.unchanged == counts.requested {
            status = .partial
        } else if counts.failed + counts.skipped + counts.cancelled == 0 {
            status = .success
        } else if counts.succeeded + counts.unchanged > 0 {
            status = .partial
        } else {
            status = .failure
        }
        return status
    }
}
