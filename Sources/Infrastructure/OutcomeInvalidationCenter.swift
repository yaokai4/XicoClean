import Foundation
import Domain

public extension Notification.Name {
    static let xicoOutcomeInvalidated = Notification.Name("xicoOutcomeInvalidated")
}

public enum OutcomeInvalidationPublishResult: Equatable, Sendable {
    case published
    case rejected(code: String)
}

public struct ValidatedOutcomeInvalidation: Sendable {
    public let outcome: OperationOutcome
    public let domains: Set<OutcomeInvalidationDomain>

    public init?(
        outcome: OperationOutcome,
        domains: Set<OutcomeInvalidationDomain>
    ) {
        guard outcome.mutation == .changed || outcome.mutation == .possiblyChanged,
              !domains.isEmpty,
              let registered = OutcomeOperationRegistry.semantics(for: outcome.kind)?
                .invalidationDomains,
              domains.isSubset(of: registered) else {
            return nil
        }
        self.outcome = outcome
        self.domains = domains
    }
}

public protocol OutcomeInvalidationPublishing: Sendable {
    func publish(
        _ request: ValidatedOutcomeInvalidation
    ) -> OutcomeInvalidationPublishResult
}

public struct OutcomeInvalidationEvent: Equatable, Sendable {
    public let operationID: UUID
    public let kind: OperationKind
    public let status: OperationTerminalStatus
    public let mutation: OperationMutationFact
    public let domains: Set<OutcomeInvalidationDomain>

    init(_ request: ValidatedOutcomeInvalidation) {
        operationID = request.outcome.id
        kind = request.outcome.kind
        status = request.outcome.status
        mutation = request.outcome.mutation
        domains = request.domains
    }
}

public final class OutcomeInvalidationCenter:
    OutcomeInvalidationPublishing,
    @unchecked Sendable {
    static let maximumRememberedOperationIDs = 512

    private let lock = NSLock()
    private let center: NotificationCenter
    private var publishedOperationIDs: Set<UUID> = []
    private var publishedOperationOrder: [UUID] = []

    public init(center: NotificationCenter = .default) {
        self.center = center
    }

    public func publish(
        _ request: ValidatedOutcomeInvalidation
    ) -> OutcomeInvalidationPublishResult {
        lock.lock()
        let isFirstPublication = publishedOperationIDs
            .insert(request.outcome.id).inserted
        if isFirstPublication {
            publishedOperationOrder.append(request.outcome.id)
            if publishedOperationOrder.count > Self.maximumRememberedOperationIDs {
                let evicted = publishedOperationOrder.removeFirst()
                publishedOperationIDs.remove(evicted)
            }
        }
        lock.unlock()
        guard isFirstPublication else { return .published }

        center.post(
            name: .xicoOutcomeInvalidated,
            object: OutcomeInvalidationEvent(request))
        return .published
    }
}
