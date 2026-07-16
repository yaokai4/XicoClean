import Foundation
import XCTest
import Domain
@testable import Features

final class OutcomeSideEffectPolicyTests: XCTestCase {
    private let kind = OperationKind("test.side-effects")
    private let start = Date(timeIntervalSince1970: 100)
    private let finish = Date(timeIntervalSince1970: 101)

    func testSuccessChangedCelebratoryRecordsNotifiesCelebratesAndInvalidates() throws {
        let decision = try evaluate(
            status: .success,
            mutation: .changed,
            profile: .celebratory,
            recordsHistory: true,
            allowsSuccessNotification: true,
            hasInvariant: false)

        XCTAssertEqual(decision.history, .record(status: .success))
        XCTAssertEqual(decision.successNotification, .allowed)
        XCTAssertEqual(decision.celebration, .allowed)
        XCTAssertTrue(decision.broadcastsInternalInvalidation)

        let notificationIneligible = try evaluate(
            status: .success,
            mutation: .changed,
            profile: .celebratory,
            recordsHistory: true,
            allowsSuccessNotification: false,
            hasInvariant: false)
        XCTAssertEqual(notificationIneligible.history, .record(status: .success))
        XCTAssertEqual(notificationIneligible.successNotification, .suppressed)
        XCTAssertEqual(notificationIneligible.celebration, .allowed)
        XCTAssertTrue(notificationIneligible.broadcastsInternalInvalidation)
    }

    func testSuccessChangedNotificationEligibleNeutralRecordsAndNotifiesWithoutCelebration() throws {
        let decision = try evaluate(
            status: .success,
            mutation: .changed,
            profile: .neutral,
            recordsHistory: true,
            allowsSuccessNotification: true,
            hasInvariant: false)

        XCTAssertEqual(decision.history, .record(status: .success))
        XCTAssertEqual(decision.successNotification, .allowed)
        XCTAssertEqual(decision.celebration, .suppressed)
        XCTAssertTrue(decision.broadcastsInternalInvalidation)

        let fullyIneligible = try evaluate(
            status: .success,
            mutation: .changed,
            profile: .neutral,
            recordsHistory: false,
            allowsSuccessNotification: false,
            hasInvariant: false)
        XCTAssertEqual(fullyIneligible.history, .none)
        XCTAssertEqual(fullyIneligible.successNotification, .suppressed)
        XCTAssertEqual(fullyIneligible.celebration, .suppressed)
        XCTAssertTrue(fullyIneligible.broadcastsInternalInvalidation)
    }

    func testSuccessChangedNotificationIneligibleNeutralNeverNotifiesOrCelebrates() throws {
        let decision = try evaluate(
            status: .success,
            mutation: .changed,
            profile: .neutral,
            recordsHistory: true,
            allowsSuccessNotification: false,
            hasInvariant: false)

        XCTAssertEqual(decision.history, .record(status: .success))
        XCTAssertEqual(decision.successNotification, .suppressed)
        XCTAssertEqual(decision.celebration, .suppressed)
        XCTAssertTrue(decision.broadcastsInternalInvalidation)
    }

    func testChangedHistoryIneligibleWorkflowDoesNotRecord() throws {
        let decision = try evaluate(
            status: .success,
            mutation: .changed,
            profile: .neutral,
            recordsHistory: false,
            allowsSuccessNotification: true,
            hasInvariant: false)

        XCTAssertEqual(decision.history, .none)
        XCTAssertEqual(decision.successNotification, .allowed)
        XCTAssertEqual(decision.celebration, .suppressed)
        XCTAssertTrue(decision.broadcastsInternalInvalidation)
    }

    func testSuccessUnchangedProducesNoSideEffects() throws {
        let decision = try evaluate(
            status: .success,
            mutation: .none,
            profile: .celebratory,
            recordsHistory: true,
            allowsSuccessNotification: true,
            hasInvariant: false)

        assertNoSideEffects(decision)
    }

    func testPartialChangedRecordsPartialWithoutFeedbackAndInvalidates() throws {
        let decision = try evaluate(
            status: .partial,
            mutation: .changed,
            profile: .celebratory,
            recordsHistory: true,
            allowsSuccessNotification: true,
            hasInvariant: false)

        XCTAssertEqual(decision.history, .record(status: .partial))
        XCTAssertEqual(decision.successNotification, .suppressed)
        XCTAssertEqual(decision.celebration, .suppressed)
        XCTAssertTrue(decision.broadcastsInternalInvalidation)
    }

    func testPartialWithoutChangeProducesNoSideEffects() throws {
        let decision = try evaluate(
            status: .partial,
            mutation: .none,
            profile: .celebratory,
            recordsHistory: true,
            allowsSuccessNotification: true,
            hasInvariant: false)

        assertNoSideEffects(decision)
    }

    func testFailureWithoutChangeProducesNoSideEffects() throws {
        let decision = try evaluate(
            status: .failure,
            mutation: .none,
            profile: .celebratory,
            recordsHistory: true,
            allowsSuccessNotification: true,
            hasInvariant: false)

        assertNoSideEffects(decision)
    }

    func testCancelledChangedRecordsCancelledWithoutFeedbackAndInvalidates() throws {
        let decision = try evaluate(
            status: .cancelled,
            mutation: .changed,
            profile: .celebratory,
            recordsHistory: true,
            allowsSuccessNotification: true,
            hasInvariant: false)

        XCTAssertEqual(decision.history, .record(status: .cancelled))
        XCTAssertEqual(decision.successNotification, .suppressed)
        XCTAssertEqual(decision.celebration, .suppressed)
        XCTAssertTrue(decision.broadcastsInternalInvalidation)
    }

    func testCancelledWithoutChangeProducesNoSideEffects() throws {
        let decision = try evaluate(
            status: .cancelled,
            mutation: .none,
            profile: .celebratory,
            recordsHistory: true,
            allowsSuccessNotification: true,
            hasInvariant: false)

        assertNoSideEffects(decision)
    }

    func testInvariantChangedRecordsPartialWithoutFeedbackAndInvalidates() throws {
        let decision = try evaluate(
            status: .failure,
            mutation: .changed,
            profile: .celebratory,
            recordsHistory: true,
            allowsSuccessNotification: true,
            hasInvariant: true)

        XCTAssertEqual(decision.history, .record(status: .partial))
        XCTAssertEqual(decision.successNotification, .suppressed)
        XCTAssertEqual(decision.celebration, .suppressed)
        XCTAssertTrue(decision.broadcastsInternalInvalidation)
    }

    func testInvariantWithoutChangeProducesNoSideEffects() throws {
        let decision = try evaluate(
            status: .failure,
            mutation: .none,
            profile: .celebratory,
            recordsHistory: true,
            allowsSuccessNotification: true,
            hasInvariant: true)

        assertNoSideEffects(decision)
    }

    func testPossiblyChangedNeverCelebratesOrSendsSuccessNotification() throws {
        let decision = try evaluate(
            status: .success,
            mutation: .possiblyChanged,
            profile: .celebratory,
            recordsHistory: true,
            allowsSuccessNotification: true,
            hasInvariant: false)

        XCTAssertEqual(decision.history, .record(status: .success))
        XCTAssertEqual(decision.successNotification, .suppressed)
        XCTAssertEqual(decision.celebration, .suppressed)
        XCTAssertTrue(decision.broadcastsInternalInvalidation)

        let failed = try evaluate(
            status: .failure,
            mutation: .possiblyChanged,
            profile: .celebratory,
            recordsHistory: true,
            allowsSuccessNotification: true,
            hasInvariant: false)
        XCTAssertEqual(failed.history, .record(status: .failure))
        XCTAssertEqual(failed.successNotification, .suppressed)
        XCTAssertEqual(failed.celebration, .suppressed)
        XCTAssertTrue(failed.broadcastsInternalInvalidation)
    }

    func testConcurrentConsumptionOfSameChannelSucceedsExactlyOnce() async {
        let gate = OutcomeFeedbackGate()
        let operationID = UUID()
        await gate.registerTerminal(operationID)

        let consumed = await withTaskGroup(of: Bool.self, returning: [Bool].self) { group in
            for _ in 0..<64 {
                group.addTask {
                    await gate.consume(.history, for: operationID)
                }
            }
            var values: [Bool] = []
            for await value in group { values.append(value) }
            return values
        }

        XCTAssertEqual(consumed.filter { $0 }.count, 1)
        XCTAssertEqual(consumed.filter { !$0 }.count, 63)
    }

    func testNotificationAndCelebrationChannelsEachConsumeOnce() async {
        let gate = OutcomeFeedbackGate()
        let operationID = UUID()
        await gate.registerTerminal(operationID)

        let notificationFirst = await gate.consume(.successNotification, for: operationID)
        let notificationSecond = await gate.consume(.successNotification, for: operationID)
        let celebrationFirst = await gate.consume(.celebration, for: operationID)
        let celebrationSecond = await gate.consume(.celebration, for: operationID)

        XCTAssertTrue(notificationFirst)
        XCTAssertFalse(notificationSecond)
        XCTAssertTrue(celebrationFirst)
        XCTAssertFalse(celebrationSecond)
    }

    func testHistoryCelebrationSoundAndInvalidationChannelsRemainIndependent() async {
        let gate = OutcomeFeedbackGate()
        let operationID = UUID()
        await gate.registerTerminal(operationID)

        let history = await gate.consume(.history, for: operationID)
        let celebration = await gate.consume(.celebration, for: operationID)
        let sound = await gate.consume(.successSoundHaptic, for: operationID)
        let invalidation = await gate.consume(.internalInvalidation, for: operationID)
        let historyAgain = await gate.consume(.history, for: operationID)

        XCTAssertTrue(history)
        XCTAssertTrue(celebration)
        XCTAssertTrue(sound)
        XCTAssertTrue(invalidation)
        XCTAssertFalse(historyAgain)
    }

    func testReregisteringSameOperationIDDoesNotResetConsumedChannels() async {
        let gate = OutcomeFeedbackGate()
        let operationID = UUID()
        await gate.registerTerminal(operationID)
        let first = await gate.consume(.history, for: operationID)
        await gate.registerTerminal(operationID)
        let second = await gate.consume(.history, for: operationID)

        XCTAssertTrue(first)
        XCTAssertFalse(second)
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
    }

    func testAppearanceCannotRegisterAnOperationOrReplayEffects() async {
        let gate = OutcomeFeedbackGate()
        let operationID = UUID()

        let firstAppearance = await gate.consume(.celebration, for: operationID)
        let repeatedAppearance = await gate.consume(.celebration, for: operationID)

        XCTAssertFalse(firstAppearance)
        XCTAssertFalse(repeatedAppearance)
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

    private func evaluate(
        status: OperationTerminalStatus,
        mutation: OperationMutationFact,
        profile: OutcomeWorkflowProfile,
        recordsHistory: Bool,
        allowsSuccessNotification: Bool,
        hasInvariant: Bool
    ) throws -> OutcomeSideEffectDecision {
        let issue = OperationIssue(code: "test.failure",
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
                item("failed", .failed(issue), mutation: .none)
            ]
            cancellationAccepted = false
        case .failure:
            requested = ["failed"]
            itemOutcomes = [item("failed", .failed(issue), mutation: mutation)]
            cancellationAccepted = false
        case .cancelled:
            requested = ["primary", "pending"]
            itemOutcomes = [item("primary", .succeeded, mutation: mutation)]
            cancellationAccepted = true
        }

        if hasInvariant {
            itemOutcomes.append(item("unexpected", .unchanged, mutation: .none))
        }

        let outcome = try OperationOutcomeReducer.reduce(
            kind: kind,
            requestedSubjectIDs: requested,
            itemOutcomes: itemOutcomes,
            cancellationAccepted: cancellationAccepted,
            startedAt: start,
            finishedAt: finish)
        return OutcomeSideEffectPolicy.evaluate(
            outcome,
            profile: profile,
            recordsHistory: recordsHistory,
            allowsSuccessNotification: allowsSuccessNotification)
    }

    private func item(
        _ subjectID: String,
        _ disposition: OperationDisposition,
        mutation: OperationMutationFact
    ) -> OperationItemOutcome {
        OperationItemOutcome(subjectID: subjectID,
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
