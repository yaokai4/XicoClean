import Foundation
import SwiftUI
import Domain
import DesignSystem
import Infrastructure

/// The immutable, channel-by-channel result of asking the canonical live gate
/// for permission to emit presentation feedback for one terminal operation.
///
/// The authorization is permanently bound to the operation from which its
/// policy was derived. It also owns a one-shot `take(expectedOperationID:)`
/// latch so a state transition or SwiftUI rebuild cannot replay feedback for a
/// different result.
final class OutcomePresentationEffectAuthorization: @unchecked Sendable {
    let operationID: UUID
    private let grantedCelebration: Bool
    private let grantedSuccessSoundHaptic: Bool
    private let grantedAccessibilityAnnouncement: Bool

    private let lock = NSLock()
    private var wasTaken = false

    private init(
        operationID: UUID,
        celebration: Bool,
        successSoundHaptic: Bool,
        accessibilityAnnouncement: Bool
    ) {
        self.operationID = operationID
        self.grantedCelebration = celebration
        self.grantedSuccessSoundHaptic = successSoundHaptic
        self.grantedAccessibilityAnnouncement = accessibilityAnnouncement
    }

    /// Consumes the eligible presentation channels in one canonical gate
    /// transaction. A terminal registration therefore cannot interleave and
    /// create a partial authorization for an operation that just became stale.
    static func consume(
        context: TaskOutcomeContext,
        gate: OutcomeFeedbackGate?
    ) async -> OutcomePresentationEffectAuthorization {
        let operationID = context.operation.id
        let presentation = TaskOutcomePresentation.make(context: context)
        guard let gate else {
            return OutcomePresentationEffectAuthorization(
                operationID: operationID,
                celebration: false,
                successSoundHaptic: false,
                accessibilityAnnouncement: false)
        }

        var requestedChannels: Set<OutcomeEffectChannel> = [
            .accessibilityAnnouncement,
        ]
        if presentation.allowsCelebration {
            requestedChannels.insert(.celebration)
        }
        if presentation.allowsSuccessSoundHaptic {
            requestedChannels.insert(.successSoundHaptic)
        }
        let grantedChannels = await gate.consume(
            requestedChannels,
            for: operationID)

        return OutcomePresentationEffectAuthorization(
            operationID: operationID,
            celebration: grantedChannels.contains(.celebration),
            successSoundHaptic: grantedChannels.contains(.successSoundHaptic),
            accessibilityAnnouncement: grantedChannels.contains(
                .accessibilityAnnouncement))
    }

    /// Hands the authorization to the sole effects owner exactly once. Empty
    /// historical/stale or operation-mismatched authorizations do not
    /// manufacture a live grant. A mismatch burns the latch fail-closed.
    func take(expectedOperationID: UUID) -> OutcomePresentationEffectGrant? {
        lock.lock()
        defer { lock.unlock() }
        guard !wasTaken else { return nil }
        wasTaken = true
        guard operationID == expectedOperationID,
              grantedCelebration
                || grantedSuccessSoundHaptic
                || grantedAccessibilityAnnouncement else {
            return nil
        }
        return OutcomePresentationEffectGrant(
            operationID: operationID,
            celebration: grantedCelebration,
            successSoundHaptic: grantedSuccessSoundHaptic,
            accessibilityAnnouncement: grantedAccessibilityAnnouncement)
    }
}

struct OutcomePresentationEffectGrant: Equatable, Sendable {
    let operationID: UUID
    let celebration: Bool
    let successSoundHaptic: Bool
    let accessibilityAnnouncement: Bool

    fileprivate init(
        operationID: UUID,
        celebration: Bool,
        successSoundHaptic: Bool,
        accessibilityAnnouncement: Bool
    ) {
        self.operationID = operationID
        self.celebration = celebration
        self.successSoundHaptic = successSoundHaptic
        self.accessibilityAnnouncement = accessibilityAnnouncement
    }
}

/// Freezes one atomic grant for the lifetime of a rendered operation. Parent
/// body recomputation (for example after focus changes) reads this immutable
/// session instead of re-querying an authorization whose one-shot latch has
/// already advanced.
@MainActor
final class OutcomePresentationEffectSession: ObservableObject {
    let grant: OutcomePresentationEffectGrant?

    init(
        authorization: OutcomePresentationEffectAuthorization?,
        expectedOperationID: UUID
    ) {
        grant = authorization?.take(expectedOperationID: expectedOperationID)
    }
}

/// The only production owner of terminal celebration visuals, success
/// sound/haptic feedback and proactive accessibility announcements.
///
/// `OutcomeMotionPlan` is resolved before this view is built. Consequently a
/// Reduce Motion/static plan still consumes the visual authorization but never
/// constructs the burst (and therefore creates no burst delay task). Sound and
/// haptic delivery uses its independent grant and remains available without a
/// visual layer.
@MainActor
struct OutcomePresentationEffects: View {
    @StateObject private var emission: OutcomePresentationEffectEmission
    let constructsBurst: Bool

    init(
        context: TaskOutcomeContext,
        presentation: TaskOutcomePresentation,
        motionPlan: OutcomeMotionPlan,
        grant: OutcomePresentationEffectGrant
    ) {
        constructsBurst = motionPlan.constructsBurst
        _emission = StateObject(wrappedValue: OutcomePresentationEffectEmission(
            grant: grant,
            operationKind: context.operation.kind,
            announcement: presentation.announcement))
    }

    var body: some View {
        Group {
            if constructsBurst {
                switch emission.burstStyle {
                case .some(.annihilation):
                    XAnnihilationBurst()
                case .some(.celebration):
                    XCelebrationBurst()
                case .none:
                    Color.clear
                }
            } else {
                Color.clear
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onAppear {
            // Sound/haptic is an independent channel, not a callback owned by
            // a visual effect that Reduce Motion may remove at any time.
            emission.deliverSoundHapticOnce()
            emission.deliverAnnouncementOnce()
        }
    }
}

@MainActor
private final class OutcomePresentationEffectEmission: ObservableObject {
    enum BurstStyle: Equatable {
        case annihilation
        case celebration
    }

    let burstStyle: BurstStyle?

    private let grant: OutcomePresentationEffectGrant
    private let announcement: String
    private var deliveredSoundHaptic = false
    private var deliveredAnnouncement = false

    init(
        grant: OutcomePresentationEffectGrant,
        operationKind: OperationKind,
        announcement: String
    ) {
        self.grant = grant
        if grant.celebration {
            burstStyle = operationKind == .cleaningExecute
                ? .annihilation
                : .celebration
        } else {
            burstStyle = nil
        }
        self.announcement = grant.accessibilityAnnouncement
            ? announcement
            : ""
    }

    func deliverSoundHapticOnce() {
        guard grant.successSoundHaptic,
              !deliveredSoundHaptic else { return }
        deliveredSoundHaptic = true
        XSound.play(.cleanDone)
        XHaptic.perform(.levelChange)
    }

    func deliverAnnouncementOnce() {
        guard grant.accessibilityAnnouncement,
              !deliveredAnnouncement,
              !announcement.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }
        deliveredAnnouncement = true
        AccessibilityNotification.Announcement(announcement).post()
    }
}
