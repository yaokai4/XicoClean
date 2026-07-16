import Foundation
import Domain

enum OutcomeEffectPermission: Equatable, Sendable {
    case allowed
    case suppressed
}

enum OutcomeHistoryDecision: Equatable, Sendable {
    case none
    case record(status: OperationTerminalStatus)
}

struct OutcomeSideEffectDecision: Equatable, Sendable {
    let history: OutcomeHistoryDecision
    let successNotification: OutcomeEffectPermission
    let celebration: OutcomeEffectPermission
    let broadcastsInternalInvalidation: Bool

    fileprivate init(
        history: OutcomeHistoryDecision,
        successNotification: OutcomeEffectPermission,
        celebration: OutcomeEffectPermission,
        broadcastsInternalInvalidation: Bool
    ) {
        self.history = history
        self.successNotification = successNotification
        self.celebration = celebration
        self.broadcastsInternalInvalidation = broadcastsInternalInvalidation
    }
}

enum OutcomeSideEffectPolicy: Sendable {
    static func evaluate(_ outcome: OperationOutcome) -> OutcomeSideEffectDecision {
        guard let semantics = OutcomeOperationRegistry.semantics(for: outcome.kind) else {
            return OutcomeSideEffectDecision(
                history: .none,
                successNotification: .suppressed,
                celebration: .suppressed,
                broadcastsInternalInvalidation: false)
        }
        return evaluateRegistered(outcome, semantics: semantics)
    }

    private static func evaluateRegistered(
        _ outcome: OperationOutcome,
        semantics: OutcomeOperationSemantics
    ) -> OutcomeSideEffectDecision {
        let mutated = outcome.mutation != .none
        let invariant = outcome.issues.contains { $0.category == .internalInvariant }
        let feedbackSafe = outcome.status == .success
            && outcome.mutation == .changed
            && !invariant
        return OutcomeSideEffectDecision(
            history: mutated && semantics.recordsHistory
                ? .record(status: invariant ? .partial : outcome.status)
                : .none,
            successNotification: feedbackSafe
                && semantics.allowsCleaningSuccessNotification
                ? .allowed
                : .suppressed,
            celebration: feedbackSafe && semantics.profile == .celebratory
                ? .allowed
                : .suppressed,
            broadcastsInternalInvalidation: mutated
                && !semantics.invalidationDomains.isEmpty)
    }
}

enum OutcomeEffectChannel: Hashable, Sendable {
    case history
    case successNotification
    case celebration
    case successSoundHaptic
    case internalInvalidation
}

actor OutcomeFeedbackGate {
    private var currentOperationID: UUID?
    private var consumedChannels: Set<OutcomeEffectChannel> = []

    func registerTerminal(_ operationID: UUID) {
        guard currentOperationID != operationID else { return }
        currentOperationID = operationID
        consumedChannels.removeAll(keepingCapacity: true)
    }

    func consume(_ channel: OutcomeEffectChannel, for operationID: UUID) -> Bool {
        guard currentOperationID == operationID else { return false }
        return consumedChannels.insert(channel).inserted
    }
}
