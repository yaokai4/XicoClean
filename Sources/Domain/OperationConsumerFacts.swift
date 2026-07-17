import Foundation

enum CleaningOperationPurpose: Sendable {
    case standard
    case spaceTrash
    case uninstall

    var operationKind: OperationKind {
        switch self {
        case .standard:
            return .cleaningExecute
        case .spaceTrash:
            return .spaceTrash
        case .uninstall:
            return .uninstall
        }
    }
}

public enum OutcomeWorkflowProfile: String, Equatable, Sendable {
    case celebratory
    case neutral
}

public enum OutcomeInvalidationDomain: String, Hashable, Sendable {
    case diskCapacity
    case scanIndex
    case cleaningHistory
    case installedApps
    case launchAgents
    case runningApplications
    case remoteDirectory
    case remoteConnections
    case serverConfiguration
    case tunnels
    case downloadComponents
    case benchmarkHistory
    case ignoreList
    case license
}

public struct OutcomeOperationSemantics: Sendable {
    public let profile: OutcomeWorkflowProfile
    public let recordsHistory: Bool
    public let allowsCleaningSuccessNotification: Bool
    public let invalidationDomains: Set<OutcomeInvalidationDomain>

    init(
        profile: OutcomeWorkflowProfile,
        recordsHistory: Bool,
        allowsCleaningSuccessNotification: Bool,
        invalidationDomains: Set<OutcomeInvalidationDomain>
    ) {
        self.profile = profile
        self.recordsHistory = recordsHistory
        self.allowsCleaningSuccessNotification = allowsCleaningSuccessNotification
        self.invalidationDomains = invalidationDomains
    }
}

public enum OutcomeOperationRegistry {
    public static func semantics(for kind: OperationKind) -> OutcomeOperationSemantics? {
        switch kind {
        case .cleaningExecute:
            return .init(
                profile: .celebratory,
                recordsHistory: true,
                allowsCleaningSuccessNotification: true,
                invalidationDomains: [.diskCapacity, .scanIndex, .cleaningHistory])
        case .cleaningUndo:
            return .init(
                profile: .neutral,
                recordsHistory: false,
                allowsCleaningSuccessNotification: false,
                invalidationDomains: [.diskCapacity, .scanIndex, .cleaningHistory])
        case .threatRemediation:
            return .init(
                profile: .neutral,
                recordsHistory: false,
                allowsCleaningSuccessNotification: false,
                invalidationDomains: [.diskCapacity, .scanIndex])
        case .spaceTrash:
            return .init(
                profile: .celebratory,
                recordsHistory: true,
                allowsCleaningSuccessNotification: false,
                invalidationDomains: [.diskCapacity, .scanIndex, .cleaningHistory])
        case .snapshotDelete:
            return .init(
                profile: .neutral,
                recordsHistory: false,
                allowsCleaningSuccessNotification: false,
                invalidationDomains: [.diskCapacity])
        case .shred:
            return .init(
                profile: .neutral,
                recordsHistory: true,
                allowsCleaningSuccessNotification: false,
                invalidationDomains: [.diskCapacity, .cleaningHistory])
        case .uninstall:
            return .init(
                profile: .celebratory,
                recordsHistory: true,
                allowsCleaningSuccessNotification: false,
                invalidationDomains: [.diskCapacity, .installedApps, .cleaningHistory])
        case .maintenance, .iCloudEvict:
            return .init(
                profile: .neutral,
                recordsHistory: false,
                allowsCleaningSuccessNotification: false,
                invalidationDomains: [.diskCapacity])
        case .helperInstall, .appUpdateCheck, .xicoUpdateCheck,
             .downloadJob, .onboardingReset:
            return .init(
                profile: .neutral,
                recordsHistory: false,
                allowsCleaningSuccessNotification: false,
                invalidationDomains: [])
        case .appTerminate, .memoryPurge:
            return .init(
                profile: .neutral,
                recordsHistory: false,
                allowsCleaningSuccessNotification: false,
                invalidationDomains: [.runningApplications])
        case .launchAgentToggle:
            return .init(
                profile: .neutral,
                recordsHistory: false,
                allowsCleaningSuccessNotification: false,
                invalidationDomains: [.launchAgents])
        case .sftpDelete:
            return .init(
                profile: .neutral,
                recordsHistory: false,
                allowsCleaningSuccessNotification: false,
                invalidationDomains: [.remoteDirectory])
        case .hostDelete, .snippetDelete:
            return .init(
                profile: .neutral,
                recordsHistory: false,
                allowsCleaningSuccessNotification: false,
                invalidationDomains: [.serverConfiguration])
        case .tunnelDelete:
            return .init(
                profile: .neutral,
                recordsHistory: false,
                allowsCleaningSuccessNotification: false,
                invalidationDomains: [.tunnels, .serverConfiguration])
        case .remoteDisconnect:
            return .init(
                profile: .neutral,
                recordsHistory: false,
                allowsCleaningSuccessNotification: false,
                invalidationDomains: [.remoteConnections])
        case .componentInstall:
            return .init(
                profile: .neutral,
                recordsHistory: false,
                allowsCleaningSuccessNotification: false,
                invalidationDomains: [.downloadComponents])
        case .historyClear:
            return .init(
                profile: .neutral,
                recordsHistory: false,
                allowsCleaningSuccessNotification: false,
                invalidationDomains: [.cleaningHistory])
        case .benchmarkHistoryClear:
            return .init(
                profile: .neutral,
                recordsHistory: false,
                allowsCleaningSuccessNotification: false,
                invalidationDomains: [.benchmarkHistory])
        case .ignoreRemove:
            return .init(
                profile: .neutral,
                recordsHistory: false,
                allowsCleaningSuccessNotification: false,
                invalidationDomains: [.ignoreList])
        case .licenseDeactivate:
            return .init(
                profile: .neutral,
                recordsHistory: false,
                allowsCleaningSuccessNotification: false,
                invalidationDomains: [.license])
        default:
            return nil
        }
    }
}

public enum OperationConsumerFacts {
    public static func isRetryable(_ disposition: OperationDisposition) -> Bool {
        switch disposition {
        case .succeeded, .unchanged:
            return false
        case let .skipped(issue), let .failed(issue):
            return issue.retryable
        case let .cancelled(issue):
            return issue?.retryable != false
        }
    }

    /// Cleaning retries additionally require Domain-owned, non-persisted execution authority.
    /// A decoded/forged fact with a retryable-looking issue but no authorization/token is not an
    /// executable retry candidate.
    public static func isRetryable(_ fact: CleaningOperationFact) -> Bool {
        guard isRetryable(fact.disposition) else { return false }
        switch fact {
        case let .deletion(item):
            // Deletion is safe to repeat only when the prior executor proved that no mutation
            // occurred. `.changed` and `.possiblyChanged` may mean the old object disappeared;
            // retrying the same path could delete a newly-created replacement.
            return item.mutation == .none && item.retryAuthorization != nil
        case let .auxiliary(item):
            return item.retryToken != nil
        }
    }

    public static func retryableSubjectIDs(
        from items: [OperationItemOutcome]
    ) -> [String] {
        items.compactMap { item in
            switch item.disposition {
            case .succeeded, .unchanged:
                return nil
            case let .skipped(issue), let .failed(issue):
                return issue.retryable ? item.subjectID : nil
            case let .cancelled(issue):
                return issue?.retryable != false ? item.subjectID : nil
            }
        }
    }

    /// Selects exact cleaning payload facts in their stored D/R occurrence order. Aggregate
    /// counts and caller item IDs are deliberately ignored, so a remediation-only failure cannot
    /// cause an already successful deletion to run again.
    public static func retryableCleaningFacts(
        from report: CleaningReport
    ) -> [CleaningOperationFact] {
        report.facts.filter(isRetryable)
    }

    public static func retryRequest(
        parent: UUID,
        kind: OperationKind,
        subjects: [String],
        itemOutcomes: [OperationItemOutcome],
        cancellationAccepted: Bool,
        startedAt: Date,
        finishedAt: Date
    ) throws -> OperationOutcome {
        try OperationOutcomeReducer.reduce(
            id: UUID(),
            parentID: parent,
            kind: kind,
            requestedSubjectIDs: subjects,
            itemOutcomes: itemOutcomes,
            cancellationAccepted: cancellationAccepted,
            startedAt: startedAt,
            finishedAt: finishedAt)
    }
}
