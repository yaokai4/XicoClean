import Foundation
import XCTest
import Domain
@testable import Features

final class TaskOutcomePresentationTests: XCTestCase {
    private let startedAt = Date(timeIntervalSince1970: 100)
    private let finishedAt = Date(timeIntervalSince1970: 101)

    func testChangedSuccessUsesSuccessStateOnlyForCelebratorySafeKind() throws {
        let context = context(
            operation: try outcome(
                kind: .cleaningExecute,
                requested: ["cache"],
                items: [item("cache", .succeeded, mutation: .changed, bytes: 4_096)]),
            affectedBytes: 4_096,
            detailKey: "已释放空间",
            canUndo: true)

        let presentation = makePresentation(context)

        XCTAssertEqual(presentation.systemImage, "checkmark.circle.fill")
        XCTAssertEqual(presentation.semanticRole, .success)
        XCTAssertEqual(presentation.titleKey, "操作已完成")
        XCTAssertEqual(presentation.detailKey, "已释放空间")
        assertCounts(presentation.countSummary, requested: 1, succeeded: 1)
        XCTAssertEqual(presentation.actionOrder, [.undoChanged, .done])
        XCTAssertTrue(presentation.allowsCelebration)
        XCTAssertTrue(presentation.allowsSuccessSoundHaptic)
        assertAccessible(presentation)
    }

    func testUnchangedSuccessIsStaticNeutralAndSaysTargetAlreadySatisfied() throws {
        let context = context(
            operation: try outcome(
                kind: .appUpdateCheck,
                requested: ["app"],
                items: [item("app", .unchanged)]),
            detailKey: "当前目标已经满足")

        let presentation = makePresentation(context)

        XCTAssertEqual(presentation.systemImage, "checkmark.circle")
        XCTAssertEqual(presentation.semanticRole, .neutral)
        XCTAssertEqual(presentation.titleKey, "目标已经满足")
        assertCounts(presentation.countSummary, requested: 1, unchanged: 1)
        XCTAssertEqual(presentation.actionOrder, [.done])
        XCTAssertFalse(presentation.allowsCelebration)
        XCTAssertFalse(presentation.allowsSuccessSoundHaptic)
        assertAccessible(presentation)
    }

    func testUnchangedRetryTerminalStillOffersUndoForRetainedPriorReceipt() throws {
        let context = context(
            operation: try outcome(
                kind: .cleaningExecute,
                requested: ["retry-context"],
                items: [item("retry-context", .unchanged)]),
            detailKey: "当前目标已经满足",
            canUndo: true)

        let presentation = makePresentation(context)

        XCTAssertEqual(context.operation.mutation, .none)
        XCTAssertEqual(presentation.semanticRole, .neutral)
        XCTAssertEqual(presentation.actionOrder, [.undoChanged, .done])
        XCTAssertFalse(presentation.allowsCelebration)
        XCTAssertFalse(presentation.allowsSuccessSoundHaptic)
    }

    func testPartialUsesWarningIconTextRetryDetailsAndUndo() throws {
        let retryable = issue(
            code: "test.io",
            subjectID: "failed",
            recovery: .retry,
            retryable: true)
        let skipped = issue(
            code: "test.permission",
            category: .permission,
            subjectID: "skipped",
            recovery: .grantPermission,
            retryable: false)
        let context = context(
            operation: try outcome(
                kind: .cleaningExecute,
                requested: ["changed", "failed", "skipped"],
                items: [
                    item("changed", .succeeded, mutation: .changed, bytes: 2_048),
                    item("failed", .failed(retryable)),
                    item("skipped", .skipped(skipped)),
                ]),
            affectedBytes: 2_048,
            detailKey: "部分项目尚未完成",
            canUndo: true,
            retryableSubjectCount: 1)

        let presentation = makePresentation(context)

        XCTAssertEqual(presentation.systemImage, "exclamationmark.circle.fill")
        XCTAssertFalse(presentation.systemImage.contains("checkmark"))
        XCTAssertEqual(presentation.semanticRole, .warning)
        XCTAssertEqual(presentation.titleKey, "部分完成")
        assertCounts(
            presentation.countSummary,
            requested: 3,
            succeeded: 1,
            skipped: 1,
            failed: 1)
        XCTAssertEqual(
            presentation.actionOrder,
            [.retryFailed, .details, .undoChanged, .done])
        XCTAssertFalse(presentation.allowsCelebration)
        XCTAssertFalse(presentation.allowsSuccessSoundHaptic)
        assertAccessible(presentation)
    }

    func testPartialPossiblyChangedStillOffersUndoForConfirmedReceipts() throws {
        let uncertainIssue = issue(
            code: "test.uncertain",
            subjectID: "uncertain",
            recovery: .manualAction,
            retryable: false)
        let context = context(
            operation: try outcome(
                kind: .cleaningExecute,
                requested: ["confirmed", "uncertain"],
                items: [
                    item("confirmed", .succeeded, mutation: .changed),
                    item(
                        "uncertain",
                        .failed(uncertainIssue),
                        mutation: .possiblyChanged),
                ]),
            detailKey: "部分完成",
            canUndo: true)

        let presentation = makePresentation(context)

        XCTAssertEqual(context.operation.mutation, .possiblyChanged)
        XCTAssertEqual(presentation.semanticRole, .warning)
        XCTAssertTrue(presentation.actionOrder.contains(.undoChanged))
        XCTAssertFalse(presentation.allowsCelebration)
    }

    func testFailureUsesErrorIconTextRecoveryAndNoCheckmark() throws {
        let permission = issue(
            code: "test.permission",
            category: .permission,
            subjectID: "protected",
            recovery: .grantPermission,
            retryable: false)
        let context = context(
            operation: try outcome(
                kind: .cleaningExecute,
                requested: ["protected"],
                items: [item("protected", .failed(permission))]),
            detailKey: "没有项目被更改")

        let presentation = makePresentation(context)

        XCTAssertEqual(presentation.systemImage, "xmark.octagon.fill")
        XCTAssertFalse(presentation.systemImage.contains("checkmark"))
        XCTAssertEqual(presentation.semanticRole, .error)
        XCTAssertEqual(presentation.titleKey, "操作失败")
        assertCounts(presentation.countSummary, requested: 1, failed: 1)
        XCTAssertEqual(presentation.actionOrder, [.recovery, .details, .done])
        XCTAssertFalse(presentation.allowsCelebration)
        XCTAssertFalse(presentation.allowsSuccessSoundHaptic)
        assertAccessible(presentation)
    }

    func testAdmissionRejectedRetryStillOffersUndoForRetainedPriorReceipt() {
        let operation = OperationOutcomeReducer.admissionFailure(
            kind: .cleaningExecute,
            requestedCount: CleaningOperationLimits.maximumFactCount + 1,
            code: "cleaning.request.inventoryLimitExceeded",
            startedAt: startedAt,
            finishedAt: finishedAt)
        let context = context(
            operation: operation,
            detailKey: "请求项目过多，尚未执行",
            canUndo: true)

        let presentation = makePresentation(context)

        XCTAssertEqual(presentation.semanticRole, .error)
        XCTAssertEqual(
            presentation.actionOrder,
            [.recovery, .details, .undoChanged, .done])
        XCTAssertFalse(presentation.allowsCelebration)
        XCTAssertFalse(presentation.allowsSuccessSoundHaptic)
    }

    func testCancelledReportsCompletedBeforeCancelAndKeepsUndo() throws {
        let context = context(
            operation: try outcome(
                kind: .cleaningExecute,
                requested: ["completed", "pending"],
                items: [item("completed", .succeeded, mutation: .changed, bytes: 1_024)],
                cancellationAccepted: true),
            affectedBytes: 1_024,
            detailKey: "取消前已完成的更改仍然保留",
            canUndo: true,
            retryableSubjectCount: 1)

        let presentation = makePresentation(context)

        XCTAssertEqual(presentation.systemImage, "stop.circle.fill")
        XCTAssertFalse(presentation.systemImage.contains("checkmark"))
        XCTAssertEqual(presentation.semanticRole, .cancelled)
        XCTAssertEqual(presentation.titleKey, "操作已取消")
        assertCounts(
            presentation.countSummary,
            requested: 2,
            succeeded: 1,
            cancelled: 1)
        XCTAssertEqual(
            presentation.actionOrder,
            [.retryRemaining, .details, .undoChanged, .done])
        XCTAssertFalse(presentation.allowsCelebration)
        XCTAssertFalse(presentation.allowsSuccessSoundHaptic)
        assertAccessible(presentation)
    }

    func testIrreversibleSuccessUsesStaticShieldAndNoCelebration() throws {
        let context = context(
            operation: try outcome(
                kind: .shred,
                requested: ["document"],
                items: [item("document", .succeeded, mutation: .changed, bytes: 8_192)]),
            affectedBytes: 8_192,
            detailKey: "项目已不可逆地处理")

        let presentation = makePresentation(context)

        XCTAssertEqual(presentation.systemImage, "checkmark.shield.fill")
        XCTAssertEqual(presentation.semanticRole, .irreversible)
        XCTAssertEqual(presentation.titleKey, "不可逆操作已完成")
        assertCounts(presentation.countSummary, requested: 1, succeeded: 1)
        XCTAssertEqual(presentation.actionOrder, [.done])
        XCTAssertFalse(presentation.allowsCelebration)
        XCTAssertFalse(presentation.allowsSuccessSoundHaptic)
        assertAccessible(presentation)
    }

    func testOnlyTheFiveRegisteredIrreversibleKindsUseTheShieldSemantic() throws {
        let irreversibleKinds: [OperationKind] = [
            .snapshotDelete, .shred, .sftpDelete, .hostDelete, .tunnelDelete,
        ]
        for kind in irreversibleKinds {
            let context = context(
                operation: try outcome(
                    kind: kind,
                    requested: ["subject"],
                    items: [item("subject", .succeeded, mutation: .changed)]),
                detailKey: "不可逆操作已完成")
            let presentation = makePresentation(context)

            XCTAssertEqual(presentation.systemImage, "checkmark.shield.fill", kind.rawValue)
            XCTAssertEqual(presentation.semanticRole, .irreversible, kind.rawValue)
            XCTAssertFalse(presentation.allowsCelebration, kind.rawValue)
        }

        for kind in [OperationKind.remoteDisconnect, .snippetDelete, .maintenance] {
            let context = context(
                operation: try outcome(
                    kind: kind,
                    requested: ["subject"],
                    items: [item("subject", .succeeded, mutation: .changed)]),
                detailKey: "中性操作已完成")
            let presentation = makePresentation(context)

            XCTAssertEqual(presentation.semanticRole, .neutral, kind.rawValue)
            XCTAssertNotEqual(presentation.systemImage, "checkmark.shield.fill", kind.rawValue)
            XCTAssertFalse(presentation.allowsCelebration, kind.rawValue)
        }
    }

    func testPartialFailureAndCancelledAreDistinctWithoutColor() throws {
        let failureIssue = issue(
            code: "test.failure",
            subjectID: "failed",
            recovery: .retry,
            retryable: true)
        let partial = makePresentation(context(
            operation: try outcome(
                kind: .cleaningExecute,
                requested: ["done", "failed"],
                items: [
                    item("done", .succeeded, mutation: .changed),
                    item("failed", .failed(failureIssue)),
                ]),
            detailKey: "部分完成",
            retryableSubjectCount: 1))
        let failure = makePresentation(context(
            operation: try outcome(
                kind: .cleaningExecute,
                requested: ["failed"],
                items: [item("failed", .failed(failureIssue))]),
            detailKey: "失败",
            retryableSubjectCount: 1))
        let cancelled = makePresentation(context(
            operation: try outcome(
                kind: .cleaningExecute,
                requested: ["pending"],
                items: [],
                cancellationAccepted: true),
            detailKey: "已取消",
            retryableSubjectCount: 1))

        XCTAssertEqual(Set([partial.systemImage, failure.systemImage, cancelled.systemImage]).count, 3)
        XCTAssertEqual(Set([partial.titleKey, failure.titleKey, cancelled.titleKey]).count, 3)
        XCTAssertFalse([partial, failure, cancelled].contains { $0.systemImage.contains("checkmark") })
    }

    func testUnknownInvariantAndPossiblyChangedSuccessFailClosed() throws {
        let unknown = makePresentation(context(
            operation: try outcome(
                kind: OperationKind("test.unregistered.presentation"),
                requested: ["subject"],
                items: [item("subject", .succeeded, mutation: .changed)]),
            detailKey: "结果需要确认"))
        let ambiguous = makePresentation(context(
            operation: try outcome(
                kind: .cleaningExecute,
                requested: ["subject"],
                items: [item("subject", .succeeded, mutation: .possiblyChanged)]),
            detailKey: "结果需要确认"))
        let invariant = makePresentation(context(
            operation: try outcome(
                kind: .cleaningExecute,
                requested: ["expected"],
                items: [
                    item("expected", .succeeded, mutation: .changed),
                    item("unexpected", .unchanged),
                ]),
            detailKey: "结果需要确认"))

        XCTAssertEqual(unknown.titleKey, "结果需要确认")
        XCTAssertEqual(ambiguous.titleKey, "结果需要确认")
        for presentation in [unknown, ambiguous, invariant] {
            XCTAssertNotEqual(presentation.semanticRole, .success)
            XCTAssertNotEqual(presentation.semanticRole, .irreversible)
            XCTAssertFalse(presentation.systemImage.contains("checkmark"))
            XCTAssertFalse(presentation.allowsCelebration)
            XCTAssertFalse(presentation.allowsSuccessSoundHaptic)
        }
    }

    func testRetryActionsUseTheReducerBoundedCountBeforeTheyAreOffered() throws {
        let cancelledWithoutRemaining = context(
            operation: try outcome(
                kind: .cleaningExecute,
                requested: ["completed"],
                items: [item("completed", .succeeded, mutation: .changed)],
                cancellationAccepted: true),
            detailKey: "操作已取消",
            retryableSubjectCount: Int.max)
        let cancelledPresentation = makePresentation(cancelledWithoutRemaining)

        XCTAssertEqual(cancelledPresentation.countSummary.cancelled, 0)
        XCTAssertFalse(cancelledPresentation.actionOrder.contains(.retryRemaining))
        XCTAssertFalse(cancelledPresentation.announcement.contains(
            cancelledPresentation.actionTitle(for: .retryRemaining)))

        let failureIssue = issue(
            code: "test.retry",
            subjectID: "failed",
            recovery: .retry,
            retryable: true)
        let failed = context(
            operation: try outcome(
                kind: .cleaningExecute,
                requested: ["failed"],
                items: [item("failed", .failed(failureIssue))]),
            detailKey: "操作失败",
            retryableSubjectCount: Int.max)
        let failedPresentation = makePresentation(failed)

        XCTAssertEqual(failedPresentation.actionOrder.first, .retryFailed)
        XCTAssertTrue(failedPresentation.actionTitle(for: .retryFailed).contains("1"))

        let negativeCapability = context(
            operation: failed.operation,
            detailKey: "操作失败",
            retryableSubjectCount: -1)
        XCTAssertFalse(makePresentation(negativeCapability).actionOrder.contains(.retryFailed))

        let cancelledIssue = issue(
            code: "test.cancel.retry",
            subjectID: "failed",
            recovery: .retry,
            retryable: true)
        let mixedCancelled = context(
            operation: try outcome(
                kind: .cleaningExecute,
                requested: ["failed", "pending"],
                items: [item("failed", .failed(cancelledIssue))],
                cancellationAccepted: true),
            detailKey: "操作已取消",
            retryableSubjectCount: 2)
        let mixedPresentation = makePresentation(mixedCancelled)

        XCTAssertEqual(mixedPresentation.countSummary.failed, 1)
        XCTAssertEqual(mixedPresentation.countSummary.cancelled, 1)
        XCTAssertEqual(mixedPresentation.actionOrder.first, .retryRemaining)
        XCTAssertTrue(mixedPresentation.actionTitle(for: .retryRemaining).contains("2"))
    }

    func testMotionSessionSuppressionIsMonotonicAcrossPreferenceChanges() {
        var session = OutcomeMotionSessionState(initialReduceMotion: false)

        XCTAssertFalse(session.shouldSuppress(currentReduceMotion: false))
        session.observe(reduceMotion: true)
        XCTAssertTrue(session.shouldSuppress(currentReduceMotion: true))
        session.observe(reduceMotion: false)
        XCTAssertTrue(
            session.shouldSuppress(currentReduceMotion: false),
            "Disabling Reduce Motion must not late-replay an already shown outcome")

        let initiallyReduced = OutcomeMotionSessionState(initialReduceMotion: true)
        XCTAssertTrue(initiallyReduced.shouldSuppress(currentReduceMotion: false))
    }

    func testReduceMotionUsesFinalValueAndConstructsNoEffectsOrTasks() throws {
        let context = context(
            operation: try outcome(
                kind: .cleaningExecute,
                requested: ["cache"],
                items: [item("cache", .succeeded, mutation: .changed, bytes: 4_096)]),
            affectedBytes: 4_096,
            detailKey: "已释放空间",
            canUndo: true)
        let presentation = makePresentation(context)

        let fullMotion = OutcomeMotionPlan.make(
            context: context,
            presentation: presentation,
            visualEffectGranted: true,
            reduceMotion: false)
        let reducedMotion = OutcomeMotionPlan.make(
            context: context,
            presentation: presentation,
            visualEffectGranted: true,
            reduceMotion: true)

        XCTAssertTrue(fullMotion.constructsBurst)
        XCTAssertTrue(fullMotion.createsDelayedRevealTask)
        XCTAssertTrue(fullMotion.createsCountUpTask)
        XCTAssertEqual(fullMotion.initialNumericValue, 0)
        XCTAssertEqual(fullMotion.finalNumericValue, 4_096)

        XCTAssertFalse(reducedMotion.constructsBurst)
        XCTAssertFalse(reducedMotion.createsDelayedRevealTask)
        XCTAssertFalse(reducedMotion.createsCountUpTask)
        XCTAssertEqual(reducedMotion.initialNumericValue, 4_096)
        XCTAssertEqual(reducedMotion.finalNumericValue, 4_096)
        XCTAssertEqual(reducedMotion.actionOrder, fullMotion.actionOrder)
        XCTAssertEqual(reducedMotion.initialFocus, fullMotion.initialFocus)
        XCTAssertEqual(
            fullMotion.initialFocus,
            presentation.actionOrder.first,
            "Initial keyboard focus must match the announced next action")
        if let focus = reducedMotion.initialFocus {
            XCTAssertTrue(reducedMotion.actionOrder.contains(focus))
        }
    }

    func testNeutralPresentationNeverConstructsMotionTasks() throws {
        let context = context(
            operation: try outcome(
                kind: .shred,
                requested: ["document"],
                items: [item("document", .succeeded, mutation: .changed, bytes: 8_192)]),
            affectedBytes: 8_192,
            detailKey: "项目已不可逆地处理")
        let presentation = makePresentation(context)

        let plan = OutcomeMotionPlan.make(
            context: context,
            presentation: presentation,
            visualEffectGranted: true,
            reduceMotion: false)

        XCTAssertFalse(plan.constructsBurst)
        XCTAssertFalse(plan.createsDelayedRevealTask)
        XCTAssertFalse(plan.createsCountUpTask)
        XCTAssertEqual(plan.initialNumericValue, 8_192)
        XCTAssertEqual(plan.finalNumericValue, 8_192)
    }

    func testCountUpInterpolationClampsExtremeValuesWithoutIntegerOverflow() throws {
        let context = context(
            operation: try outcome(
                kind: .cleaningExecute,
                requested: ["cache"],
                items: [item("cache", .succeeded, mutation: .changed)]),
            affectedBytes: Int64.max,
            detailKey: "已完成")
        let presentation = makePresentation(context)
        let plan = OutcomeMotionPlan.make(
            context: context,
            presentation: presentation,
            visualEffectGranted: true,
            reduceMotion: false)

        XCTAssertEqual(plan.interpolatedNumericValue(at: -1), 0)
        XCTAssertGreaterThan(plan.interpolatedNumericValue(at: 0.5), 0)
        XCTAssertLessThan(plan.interpolatedNumericValue(at: 0.5), Int64.max)
        XCTAssertEqual(plan.interpolatedNumericValue(at: 1), Int64.max)
        XCTAssertEqual(plan.interpolatedNumericValue(at: 2), Int64.max)
    }

    @MainActor
    func testAnnouncementAndActionOrderUseOnlyAvailableCallbacks() throws {
        let retryable = issue(
            code: "test.retry",
            subjectID: "failed",
            recovery: .retry,
            retryable: true)
        let context = context(
            operation: try outcome(
                kind: .cleaningExecute,
                requested: ["changed", "failed"],
                items: [
                    item("changed", .succeeded, mutation: .changed),
                    item("failed", .failed(retryable)),
                ]),
            detailKey: "部分完成",
            canUndo: true,
            retryableSubjectCount: 1)
        let actions = TaskOutcomeActions(undo: {}, done: {})

        let unfiltered = makePresentation(context)
        let presentation = unfiltered.resolvingAvailableActions(actions.availableKinds)

        XCTAssertEqual(presentation.actionOrder, [.undoChanged, .done])
        XCTAssertTrue(presentation.announcement.contains(
            presentation.actionTitle(for: .undoChanged)))
        XCTAssertFalse(presentation.announcement.contains(
            unfiltered.actionTitle(for: .retryFailed)))
        XCTAssertFalse(presentation.announcement.contains(
            unfiltered.actionTitle(for: .details)))

        let animated = OutcomeMotionPlan.make(
            context: context,
            presentation: presentation,
            visualEffectGranted: true,
            reduceMotion: false)
        let reduced = OutcomeMotionPlan.make(
            context: context,
            presentation: presentation,
            visualEffectGranted: true,
            reduceMotion: true)
        XCTAssertEqual(animated.initialFocus, .undoChanged)
        XCTAssertEqual(reduced.initialFocus, .undoChanged)
    }

    func testCelebrationAndSoundHapticChannelsAreConsumedIndependentlyExactlyOnce() async throws {
        let context = context(
            operation: try outcome(
                kind: .cleaningExecute,
                requested: ["cache"],
                items: [item("cache", .succeeded, mutation: .changed)]),
            detailKey: "已完成")
        let gate = OutcomeFeedbackGate()
        await gate.registerTerminal(context.operation.id)

        let first = await OutcomePresentationEffectAuthorization.consume(
            context: context,
            gate: gate)
        let replay = await OutcomePresentationEffectAuthorization.consume(
            context: context,
            gate: gate)
        let firstGrant = try XCTUnwrap(first.take(
            expectedOperationID: context.operation.id))

        XCTAssertTrue(firstGrant.celebration)
        XCTAssertTrue(firstGrant.successSoundHaptic)
        XCTAssertNil(replay.take(expectedOperationID: context.operation.id))

        let splitGate = OutcomeFeedbackGate()
        await splitGate.registerTerminal(context.operation.id)
        let consumedCelebration = await splitGate.consume(.celebration, for: context.operation.id)
        let split = await OutcomePresentationEffectAuthorization.consume(
            context: context,
            gate: splitGate)
        let splitGrant = try XCTUnwrap(split.take(
            expectedOperationID: context.operation.id))

        XCTAssertTrue(consumedCelebration)
        XCTAssertFalse(splitGrant.celebration)
        XCTAssertTrue(splitGrant.successSoundHaptic)
    }

    func testReducedMotionConsumesLiveAuthorizationWithoutConstructingMotion() async throws {
        let context = context(
            operation: try outcome(
                kind: .cleaningExecute,
                requested: ["cache"],
                items: [item("cache", .succeeded, mutation: .changed)]),
            detailKey: "已完成")
        let presentation = makePresentation(context)
        let gate = OutcomeFeedbackGate()
        await gate.registerTerminal(context.operation.id)

        let authorization = await OutcomePresentationEffectAuthorization.consume(
            context: context,
            gate: gate)
        let grant = try XCTUnwrap(authorization.take(
            expectedOperationID: context.operation.id))
        XCTAssertTrue(grant.celebration)
        XCTAssertTrue(grant.successSoundHaptic)

        let reducedPlan = OutcomeMotionPlan.make(
            context: context,
            presentation: presentation,
            visualEffectGranted: grant.celebration,
            reduceMotion: true)
        XCTAssertFalse(reducedPlan.constructsBurst)
        XCTAssertFalse(reducedPlan.createsDelayedRevealTask)
        XCTAssertFalse(reducedPlan.createsCountUpTask)

        let replay = await OutcomePresentationEffectAuthorization.consume(
            context: context,
            gate: gate)
        XCTAssertNil(replay.take(expectedOperationID: context.operation.id))
    }

    func testEffectAuthorizationCanBeTakenOnlyOnceEvenWhenTheSameObjectIsReused() async throws {
        let context = context(
            operation: try outcome(
                kind: .cleaningExecute,
                requested: ["cache"],
                items: [item("cache", .succeeded, mutation: .changed)]),
            detailKey: "已完成")
        let gate = OutcomeFeedbackGate()
        await gate.registerTerminal(context.operation.id)

        let authorization = await OutcomePresentationEffectAuthorization.consume(
            context: context,
            gate: gate)
        let first = try XCTUnwrap(authorization.take(
            expectedOperationID: context.operation.id))

        XCTAssertTrue(first.celebration)
        XCTAssertTrue(first.successSoundHaptic)
        XCTAssertTrue(first.accessibilityAnnouncement)
        XCTAssertNil(
            authorization.take(expectedOperationID: context.operation.id),
            "A rebuilt effects view must not replay one-shot feedback")
    }

    func testEffectAuthorizationFailsClosedForAMismatchedOperationID() async throws {
        let context = context(
            operation: try outcome(
                kind: .cleaningExecute,
                requested: ["cache"],
                items: [item("cache", .succeeded, mutation: .changed)]),
            detailKey: "已完成")
        let wrongOperationID = UUID()
        let gate = OutcomeFeedbackGate()
        await gate.registerTerminal(context.operation.id)

        let authorization = await OutcomePresentationEffectAuthorization.consume(
            context: context,
            gate: gate)

        XCTAssertNil(authorization.take(expectedOperationID: wrongOperationID))
        XCTAssertNil(
            authorization.take(expectedOperationID: context.operation.id),
            "A mismatched presentation attempt must burn the one-shot grant")
    }

    func testHistoricalAndStaleResultsCannotConsumeLiveEffects() async throws {
        let context = context(
            operation: try outcome(
                kind: .cleaningExecute,
                requested: ["cache"],
                items: [item("cache", .succeeded, mutation: .changed)]),
            detailKey: "已完成")
        let historical = await OutcomePresentationEffectAuthorization.consume(
            context: context,
            gate: nil)
        XCTAssertNil(historical.take(expectedOperationID: context.operation.id))

        let staleGate = OutcomeFeedbackGate()
        await staleGate.registerTerminal(UUID())
        let stale = await OutcomePresentationEffectAuthorization.consume(
            context: context,
            gate: staleGate)
        XCTAssertNil(stale.take(expectedOperationID: context.operation.id))
    }

    func testConcurrentTakeCreatesExactlyOnePresentationGrant() async throws {
        let context = context(
            operation: try outcome(
                kind: .cleaningExecute,
                requested: ["cache"],
                items: [item("cache", .succeeded, mutation: .changed)]),
            detailKey: "已完成")
        let gate = OutcomeFeedbackGate()
        await gate.registerTerminal(context.operation.id)
        let authorization = await OutcomePresentationEffectAuthorization.consume(
            context: context,
            gate: gate)

        let granted = await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<64 {
                group.addTask {
                    authorization.take(
                        expectedOperationID: context.operation.id) != nil
                }
            }
            var values: [Bool] = []
            for await value in group { values.append(value) }
            return values
        }

        XCTAssertEqual(granted.filter { $0 }.count, 1)
    }

    func testCanonicalGateConsumesPresentationChannelsAsOneTransaction() async {
        let gate = OutcomeFeedbackGate()
        let operationID = UUID()
        await gate.registerTerminal(operationID)
        let channels: Set<OutcomeEffectChannel> = [
            .celebration,
            .successSoundHaptic,
            .accessibilityAnnouncement,
        ]

        let first = await gate.consume(channels, for: operationID)
        let replay = await gate.consume(channels, for: operationID)

        XCTAssertEqual(first, channels)
        XCTAssertTrue(replay.isEmpty)
    }

    func testAccessibilityAnnouncementUsesTheCanonicalGateAsAnIndependentChannel() async {
        let gate = OutcomeFeedbackGate()
        let operationID = UUID()
        await gate.registerTerminal(operationID)

        let firstAnnouncement = await gate.consume(.accessibilityAnnouncement, for: operationID)
        let replayedAnnouncement = await gate.consume(.accessibilityAnnouncement, for: operationID)
        let independentCelebration = await gate.consume(.celebration, for: operationID)

        XCTAssertTrue(firstAnnouncement)
        XCTAssertFalse(replayedAnnouncement)
        XCTAssertTrue(independentCelebration)

        let nextOperationID = UUID()
        await gate.registerTerminal(nextOperationID)
        let staleAnnouncement = await gate.consume(.accessibilityAnnouncement, for: operationID)
        let nextAnnouncement = await gate.consume(.accessibilityAnnouncement, for: nextOperationID)
        XCTAssertFalse(staleAnnouncement)
        XCTAssertTrue(nextAnnouncement)
    }

    func testCompatibilityShimIsStaticNeutralDismissalOnly() throws {
        let source = try source("Sources/Features/SharedViews.swift")
        let segment = try taskCompletionSegment(in: source)
        let code = strippingCommentsAndStrings(from: segment)

        XCTAssertTrue(code.contains("LegacyTaskOutcomeCompatibilityView"))
        XCTAssertTrue(
            compact(code).contains("LegacyTaskOutcomeCompatibilityView(onDone:onDone)"),
            "Compatibility shim may forward only the existing dismissal action")
        for forbidden in [
            "OperationOutcomeReducer", "OutcomeFeedbackGate", "registerTerminal(",
            "XAnnihilationBurst", "XCelebrationBurst", "XSound", "XHaptic",
            "Task {", "countUp(", ".onAppear", "onUndo()", "metricText(",
        ] {
            XCTAssertFalse(code.contains(forbidden), "Compatibility shim contains \(forbidden)")
        }
    }

    func testPresentationAndEffectViewsNeverRegisterTerminalOrResetTheGate() throws {
        for relativePath in [
            "Sources/Features/TaskOutcomePresentation.swift",
            "Sources/Features/OutcomePresentationEffects.swift",
            "Sources/Features/SharedViews.swift",
        ] {
            let code = strippingCommentsAndStrings(from: try source(relativePath))
            XCTAssertFalse(code.contains("registerTerminal("), relativePath)
        }
    }

    func testTaskOutcomeViewBindsInitialFocusToTheRenderedActionButtons() throws {
        let code = strippingCommentsAndStrings(
            from: try source("Sources/Features/SharedViews.swift"))
        let compactCode = compact(code)

        XCTAssertTrue(code.contains("@FocusState"))
        XCTAssertTrue(compactCode.contains("focusedAction=motionPlan.initialFocus"))
        XCTAssertTrue(compactCode.contains(".focused(focusedAction,equals:item.0)"))
    }

    func testTaskOutcomeViewFreezesOneAtomicEffectGrantForItsLifetime() throws {
        let code = strippingCommentsAndStrings(
            from: try source("Sources/Features/SharedViews.swift"))
        let compactCode = compact(code)
        let effects = compact(strippingCommentsAndStrings(
            from: try source("Sources/Features/OutcomePresentationEffects.swift")))

        XCTAssertTrue(code.contains("@StateObject"))
        XCTAssertTrue(compactCode.contains("effectSession.grant?.celebration"))
        XCTAssertTrue(compactCode.contains("motionSession.shouldSuppress"))
        XCTAssertTrue(compactCode.contains("motionSession.observe(reduceMotion:enabled)"))
        XCTAssertFalse(compactCode.contains("authorization?.permits"))
        XCTAssertTrue(effects.contains("ifconstructsBurst"))
        XCTAssertTrue(effects.contains("emission.deliverSoundHapticOnce()"))
    }

    func testTerminalFeedbackReferencesAreCentralizedInTheEffectOwner() throws {
        let effects = strippingCommentsAndStrings(
            from: try source("Sources/Features/OutcomePresentationEffects.swift"))
        for required in [
            "XAnnihilationBurst", "XCelebrationBurst",
            "XSound.play(.cleanDone)", "XHaptic.perform(.levelChange)",
        ] {
            XCTAssertTrue(effects.contains(required), "Effect owner lacks \(required)")
        }

        for relativePath in [
            "Sources/Features/TaskOutcomePresentation.swift",
            "Sources/Features/SharedViews.swift",
        ] {
            let source = strippingCommentsAndStrings(from: try source(relativePath))
            for forbidden in [
                "XAnnihilationBurst", "XCelebrationBurst",
                "XSound.play(.cleanDone)", "XHaptic.perform(.levelChange)",
            ] {
                XCTAssertFalse(source.contains(forbidden), "\(relativePath) owns \(forbidden)")
            }
        }
    }

    // MARK: - Fixtures

    private func makePresentation(_ context: TaskOutcomeContext) -> TaskOutcomePresentation {
        TaskOutcomePresentation.make(context: context)
    }

    private func context(
        operation: OperationOutcome,
        affectedBytes: Int64? = nil,
        detailKey: String,
        note: String? = nil,
        canUndo: Bool = false,
        retryableSubjectCount: Int = 0
    ) -> TaskOutcomeContext {
        TaskOutcomeContext(
            operation: operation,
            affectedBytes: affectedBytes,
            primaryDetailKey: detailKey,
            note: note,
            canUndoChangedItems: canUndo,
            retryableSubjectCount: retryableSubjectCount)
    }

    private func outcome(
        id: UUID = UUID(),
        kind: OperationKind,
        requested: [String],
        items: [OperationItemOutcome],
        cancellationAccepted: Bool = false
    ) throws -> OperationOutcome {
        try OperationOutcomeReducer.reduce(
            id: id,
            kind: kind,
            requestedSubjectIDs: requested,
            itemOutcomes: items,
            cancellationAccepted: cancellationAccepted,
            startedAt: startedAt,
            finishedAt: finishedAt)
    }

    private func item(
        _ subjectID: String,
        _ disposition: OperationDisposition,
        mutation: OperationMutationFact = .none,
        bytes: Int64 = 0
    ) -> OperationItemOutcome {
        OperationItemOutcome(
            subjectID: subjectID,
            disposition: disposition,
            mutation: mutation,
            affectedBytes: bytes)
    }

    private func issue(
        code: String,
        category: OperationIssueCategory = .io,
        subjectID: String,
        recovery: OperationRecoveryHint,
        retryable: Bool
    ) -> OperationIssue {
        OperationIssue(
            code: code,
            category: category,
            subjectID: subjectID,
            recovery: recovery,
            retryable: retryable)
    }

    private func assertCounts(
        _ summary: TaskOutcomeCountSummary,
        requested: Int,
        succeeded: Int = 0,
        unchanged: Int = 0,
        skipped: Int = 0,
        failed: Int = 0,
        cancelled: Int = 0,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(summary.requested, requested, file: file, line: line)
        XCTAssertEqual(summary.succeeded, succeeded, file: file, line: line)
        XCTAssertEqual(summary.unchanged, unchanged, file: file, line: line)
        XCTAssertEqual(summary.skipped, skipped, file: file, line: line)
        XCTAssertEqual(summary.failed, failed, file: file, line: line)
        XCTAssertEqual(summary.cancelled, cancelled, file: file, line: line)
    }

    private func assertAccessible(
        _ presentation: TaskOutcomePresentation,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertFalse(
            presentation.accessibilityLabel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            file: file,
            line: line)
        XCTAssertFalse(
            presentation.announcement.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            file: file,
            line: line)
        XCTAssertTrue(
            presentation.announcement.contains(String(presentation.countSummary.requested)),
            "Announcement must include reducer-owned counts",
            file: file,
            line: line)
    }

    private func packageRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func source(_ relativePath: String) throws -> String {
        try String(
            contentsOf: packageRoot().appendingPathComponent(relativePath),
            encoding: .utf8)
    }

    private func taskCompletionSegment(in source: String) throws -> String {
        let start = try XCTUnwrap(source.range(of: "struct TaskCompletionView"))
        let tail = source[start.lowerBound...]
        let end = try XCTUnwrap(tail.range(of: "struct CompletionView"))
        return String(tail[..<end.lowerBound])
    }

    private func strippingCommentsAndStrings(from source: String) -> String {
        let patterns = [
            #"\"(?:\\.|[^\"\\])*\""#,
            #"(?s)/\*.*?\*/"#,
            #"//[^\n]*"#,
        ]
        return patterns.reduce(source) { value, pattern in
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return value }
            let range = NSRange(value.startIndex..., in: value)
            return regex.stringByReplacingMatches(
                in: value,
                range: range,
                withTemplate: "")
        }
    }

    private func compact(_ source: String) -> String {
        source.filter { !$0.isWhitespace }
    }
}
