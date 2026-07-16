import Foundation
import XCTest
import Domain
@testable import Features

final class OutcomeSideEffectPolicyTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 100)
    private let finish = Date(timeIntervalSince1970: 101)

    func testSuccessChangedCleaningUsesEveryRegisteredSuccessChannel() throws {
        let decision = OutcomeSideEffectPolicy.evaluate(try outcome(
            kind: .cleaningExecute,
            status: .success,
            mutation: .changed))

        XCTAssertEqual(decision.history, .record(status: .success))
        XCTAssertEqual(decision.successNotification, .allowed)
        XCTAssertEqual(decision.celebration, .allowed)
        XCTAssertTrue(decision.broadcastsInternalInvalidation)
    }

    func testOnlyCleaningExecuteIsCleaningNotificationEligible() throws {
        let kinds: [OperationKind] = [
            .cleaningExecute, .spaceTrash, .uninstall, .shred, .maintenance,
            .sftpDelete, .appUpdateCheck
        ]

        for kind in kinds {
            let decision = OutcomeSideEffectPolicy.evaluate(try outcome(
                kind: kind,
                status: .success,
                mutation: .changed))
            XCTAssertEqual(
                decision.successNotification,
                kind == .cleaningExecute ? .allowed : .suppressed,
                kind.rawValue)
        }
    }

    func testNeutralIrreversibleKindSuppressesEveryCelebratoryChannel() throws {
        let kinds: [OperationKind] = [
            .snapshotDelete, .shred, .sftpDelete, .hostDelete, .tunnelDelete,
            .remoteDisconnect, .snippetDelete
        ]

        for kind in kinds {
            XCTAssertEqual(OutcomeOperationRegistry.semantics(for: kind)?.profile, .neutral)
            let decision = OutcomeSideEffectPolicy.evaluate(try outcome(
                kind: kind,
                status: .success,
                mutation: .changed))
            XCTAssertEqual(decision.successNotification, .suppressed, kind.rawValue)
            XCTAssertEqual(decision.celebration, .suppressed, kind.rawValue)
        }
    }

    func testCallerCannotUpgradeNeutralOrUnknownKindToCelebratory() throws {
        let neutral = OutcomeSideEffectPolicy.evaluate(try outcome(
            kind: .shred,
            status: .success,
            mutation: .changed))
        let unknown = OutcomeSideEffectPolicy.evaluate(try outcome(
            kind: OperationKind("unregistered.claimed-celebratory"),
            status: .success,
            mutation: .changed))

        XCTAssertEqual(neutral.celebration, .suppressed)
        XCTAssertEqual(unknown.celebration, .suppressed)
        XCTAssertEqual(unknown.successNotification, .suppressed)
    }

    func testPartialChangedAllowsHistoryAndInvalidationButNoSuccessFeedback() throws {
        let decision = OutcomeSideEffectPolicy.evaluate(try outcome(
            kind: .cleaningExecute,
            status: .partial,
            mutation: .changed))

        XCTAssertEqual(decision.history, .record(status: .partial))
        XCTAssertEqual(decision.successNotification, .suppressed)
        XCTAssertEqual(decision.celebration, .suppressed)
        XCTAssertTrue(decision.broadcastsInternalInvalidation)
    }

    func testCancelledChangedPreservesHistoryAndInvalidationButNoSuccessFeedback() throws {
        let decision = OutcomeSideEffectPolicy.evaluate(try outcome(
            kind: .cleaningExecute,
            status: .cancelled,
            mutation: .changed))

        XCTAssertEqual(decision.history, .record(status: .cancelled))
        XCTAssertEqual(decision.successNotification, .suppressed)
        XCTAssertEqual(decision.celebration, .suppressed)
        XCTAssertTrue(decision.broadcastsInternalInvalidation)
    }

    func testSuccessUnchangedSuppressesAllChangedChannels() throws {
        let decision = OutcomeSideEffectPolicy.evaluate(try outcome(
            kind: .cleaningExecute,
            status: .success,
            mutation: .none))

        assertNoSideEffects(decision)
    }

    func testShredAndRemoteDeleteNeverAllowNotificationOrCelebrationEvenWhenSuccessful() throws {
        for kind in [OperationKind.shred, .sftpDelete, .hostDelete, .tunnelDelete] {
            let decision = OutcomeSideEffectPolicy.evaluate(try outcome(
                kind: kind,
                status: .success,
                mutation: .changed))
            XCTAssertEqual(decision.successNotification, .suppressed, kind.rawValue)
            XCTAssertEqual(decision.celebration, .suppressed, kind.rawValue)
            XCTAssertTrue(decision.broadcastsInternalInvalidation, kind.rawValue)
        }
    }

    func testPossiblyChangedNeverNotifiesOrCelebrates() throws {
        for status in [OperationTerminalStatus.success, .failure, .cancelled] {
            let decision = OutcomeSideEffectPolicy.evaluate(try outcome(
                kind: .cleaningExecute,
                status: status,
                mutation: .possiblyChanged))
            XCTAssertEqual(decision.successNotification, .suppressed, status.rawValue)
            XCTAssertEqual(decision.celebration, .suppressed, status.rawValue)
            XCTAssertNotEqual(decision.history, .none, status.rawValue)
            XCTAssertTrue(decision.broadcastsInternalInvalidation, status.rawValue)
        }
    }

    func testUnknownKindSuppressesHistoryNotificationCelebrationAndInvalidation() throws {
        let decision = OutcomeSideEffectPolicy.evaluate(try outcome(
            kind: OperationKind("unknown.operation"),
            status: .success,
            mutation: .changed))

        assertNoSideEffects(decision)
        XCTAssertNil(OutcomeOperationRegistry.semantics(for: OperationKind("unknown.operation")))
    }

    func testRegisteredKindWithNoDomainsDoesNotBroadcastInvalidation() throws {
        let decision = OutcomeSideEffectPolicy.evaluate(try outcome(
            kind: .helperInstall,
            status: .success,
            mutation: .changed))

        assertNoSideEffects(decision)
    }

    func testInternalInvariantDowngradesHistoryAndSuppressesSuccessFeedback() throws {
        let decision = OutcomeSideEffectPolicy.evaluate(try outcome(
            kind: .cleaningExecute,
            status: .success,
            mutation: .changed,
            hasInvariant: true))

        XCTAssertEqual(decision.history, .record(status: .partial))
        XCTAssertEqual(decision.successNotification, .suppressed)
        XCTAssertEqual(decision.celebration, .suppressed)
        XCTAssertTrue(decision.broadcastsInternalInvalidation)
    }

    func testFailureWithoutMutationProducesNoSideEffects() throws {
        assertNoSideEffects(OutcomeSideEffectPolicy.evaluate(try outcome(
            kind: .cleaningExecute,
            status: .failure,
            mutation: .none)))
    }

    func testHistoryConsumptionDoesNotConsumeNotificationOrCelebrationChannel() async {
        let gate = OutcomeFeedbackGate()
        let operationID = UUID()
        await gate.registerTerminal(operationID)

        let historyFirst = await gate.consume(.history, for: operationID)
        let notificationFirst = await gate.consume(.successNotification, for: operationID)
        let celebrationFirst = await gate.consume(.celebration, for: operationID)
        let soundHapticFirst = await gate.consume(.successSoundHaptic, for: operationID)
        let invalidationFirst = await gate.consume(.internalInvalidation, for: operationID)
        let historySecond = await gate.consume(.history, for: operationID)
        let notificationSecond = await gate.consume(.successNotification, for: operationID)
        let celebrationSecond = await gate.consume(.celebration, for: operationID)
        let soundHapticSecond = await gate.consume(.successSoundHaptic, for: operationID)
        let invalidationSecond = await gate.consume(.internalInvalidation, for: operationID)

        XCTAssertTrue(historyFirst)
        XCTAssertTrue(notificationFirst)
        XCTAssertTrue(celebrationFirst)
        XCTAssertTrue(soundHapticFirst)
        XCTAssertTrue(invalidationFirst)
        XCTAssertFalse(historySecond)
        XCTAssertFalse(notificationSecond)
        XCTAssertFalse(celebrationSecond)
        XCTAssertFalse(soundHapticSecond)
        XCTAssertFalse(invalidationSecond)
    }

    func testConcurrentConsumptionOfSameChannelSucceedsExactlyOnce() async {
        let gate = OutcomeFeedbackGate()
        let operationID = UUID()
        await gate.registerTerminal(operationID)

        let consumed = await withTaskGroup(of: Bool.self, returning: [Bool].self) { group in
            for _ in 0..<64 {
                group.addTask { await gate.consume(.history, for: operationID) }
            }
            var values: [Bool] = []
            for await value in group { values.append(value) }
            return values
        }

        XCTAssertEqual(consumed.filter { $0 }.count, 1)
        XCTAssertEqual(consumed.filter { !$0 }.count, 63)
    }

    func testReregisteringSameOperationIDDoesNotResetConsumedChannels() async {
        let gate = OutcomeFeedbackGate()
        let operationID = UUID()
        await gate.registerTerminal(operationID)
        let first = await gate.consume(.history, for: operationID)

        await gate.registerTerminal(operationID)

        let historyAfterRegistration = await gate.consume(.history, for: operationID)
        let celebrationAfterRegistration = await gate.consume(.celebration, for: operationID)
        XCTAssertTrue(first)
        XCTAssertFalse(historyAfterRegistration)
        XCTAssertTrue(celebrationAfterRegistration)
    }

    func testRegisteringNewOperationRejectsOldOperationID() async {
        let gate = OutcomeFeedbackGate()
        let oldID = UUID()
        let newID = UUID()
        await gate.registerTerminal(oldID)
        let oldBeforeReplacement = await gate.consume(.history, for: oldID)

        await gate.registerTerminal(newID)

        let oldAfterReplacement = await gate.consume(.celebration, for: oldID)
        let newAfterReplacement = await gate.consume(.history, for: newID)
        XCTAssertTrue(oldBeforeReplacement)
        XCTAssertFalse(oldAfterReplacement)
        XCTAssertTrue(newAfterReplacement)
    }

    func testGateStorageRemainsConstantAcrossManyTerminalOperations() async {
        let gate = OutcomeFeedbackGate()
        let firstID = UUID()
        var currentID = firstID

        for index in 0..<4_097 {
            currentID = index == 0 ? firstID : UUID()
            await gate.registerTerminal(currentID)
            let consumed = await gate.consume(.history, for: currentID)
            XCTAssertTrue(consumed)
        }

        let stale = await gate.consume(.celebration, for: firstID)
        let currentHistory = await gate.consume(.history, for: currentID)
        let currentCelebration = await gate.consume(.celebration, for: currentID)
        XCTAssertFalse(stale)
        XCTAssertFalse(currentHistory)
        XCTAssertTrue(currentCelebration)

        let storage = Mirror(reflecting: gate)
        let fields = Dictionary(uniqueKeysWithValues: storage.children.compactMap { child in
            child.label.map { ($0, child.value) }
        })
        XCTAssertEqual(
            Set(fields.keys),
            ["$defaultActor", "currentOperationID", "consumedChannels"])
        XCTAssertTrue(fields["consumedChannels"] is Set<OutcomeEffectChannel>)
    }

    func testAppearanceCannotRegisterAnOperationOrReplayEffects() async {
        let gate = OutcomeFeedbackGate()
        let operationID = UUID()

        let first = await gate.consume(.celebration, for: operationID)
        let second = await gate.consume(.celebration, for: operationID)
        XCTAssertFalse(first)
        XCTAssertFalse(second)
    }

    func testHistoricalOutcomeCannotRegisterOrConsumeLiveEffects() async {
        let gate = OutcomeFeedbackGate()
        let liveID = UUID()
        let historicalID = UUID()
        await gate.registerTerminal(liveID)

        let historical = await gate.consume(.history, for: historicalID)
        let live = await gate.consume(.history, for: liveID)
        let historicalAgain = await gate.consume(.history, for: historicalID)
        XCTAssertFalse(historical)
        XCTAssertTrue(live)
        XCTAssertFalse(historicalAgain)
    }

    private func outcome(
        kind: OperationKind,
        status: OperationTerminalStatus,
        mutation: OperationMutationFact,
        hasInvariant: Bool = false
    ) throws -> OperationOutcome {
        let failure = OperationIssue(
            code: "test.failure",
            category: .io,
            subjectID: "failed",
            recovery: .retry,
            retryable: true)
        let requested: [String]
        var itemOutcomes: [OperationItemOutcome]
        let cancellationAccepted: Bool

        switch status {
        case .success:
            requested = ["primary"]
            itemOutcomes = [item("primary", .succeeded, mutation: mutation)]
            cancellationAccepted = false
        case .partial:
            requested = ["primary", "failed"]
            itemOutcomes = [
                item("primary", .succeeded, mutation: mutation),
                item("failed", .failed(failure), mutation: .none)
            ]
            cancellationAccepted = false
        case .failure:
            requested = ["failed"]
            itemOutcomes = [item("failed", .failed(failure), mutation: mutation)]
            cancellationAccepted = false
        case .cancelled:
            requested = ["primary", "pending"]
            itemOutcomes = mutation == .none
                ? []
                : [item("primary", .succeeded, mutation: mutation)]
            cancellationAccepted = true
        }

        if hasInvariant {
            itemOutcomes.append(item("unexpected", .unchanged, mutation: .none))
        }

        return try OperationOutcomeReducer.reduce(
            kind: kind,
            requestedSubjectIDs: requested,
            itemOutcomes: itemOutcomes,
            cancellationAccepted: cancellationAccepted,
            startedAt: start,
            finishedAt: finish)
    }

    private func item(
        _ subjectID: String,
        _ disposition: OperationDisposition,
        mutation: OperationMutationFact
    ) -> OperationItemOutcome {
        OperationItemOutcome(
            subjectID: subjectID,
            disposition: disposition,
            mutation: mutation)
    }

    private func assertNoSideEffects(
        _ decision: OutcomeSideEffectDecision,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(decision.history, .none, file: file, line: line)
        XCTAssertEqual(decision.successNotification, .suppressed, file: file, line: line)
        XCTAssertEqual(decision.celebration, .suppressed, file: file, line: line)
        XCTAssertFalse(decision.broadcastsInternalInvalidation, file: file, line: line)
    }
}
