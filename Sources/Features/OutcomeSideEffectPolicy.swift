import Foundation
import Domain

enum OutcomeWorkflowProfile: Equatable, Sendable {
    case celebratory
    case neutral
}

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
    static func evaluate(
        _ outcome: OperationOutcome,
        profile: OutcomeWorkflowProfile,
        recordsHistory: Bool,
        allowsSuccessNotification: Bool
    ) -> OutcomeSideEffectDecision {
        let mutated = outcome.mutation != .none
        let invariant = outcome.issues.contains { $0.category == .internalInvariant }
        let feedbackSafe = outcome.status == .success
            && outcome.mutation == .changed
            && !invariant
        return OutcomeSideEffectDecision(
            history: mutated && recordsHistory
                ? .record(status: invariant ? .partial : outcome.status)
                : .none,
            successNotification: feedbackSafe && allowsSuccessNotification
                ? .allowed
                : .suppressed,
            celebration: feedbackSafe && profile == .celebratory
                ? .allowed
                : .suppressed,
            broadcastsInternalInvalidation: mutated)
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
