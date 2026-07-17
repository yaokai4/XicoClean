import Foundation
import XCTest
@testable import Domain

final class OperationConsumerFactsTests: XCTestCase {
    private struct RegistryExpectation {
        let kind: OperationKind
        let profile: OutcomeWorkflowProfile
        let recordsHistory: Bool
        let allowsCleaningSuccessNotification: Bool
        let invalidationDomains: Set<OutcomeInvalidationDomain>
    }

    private let startedAt = Date(timeIntervalSince1970: 100)
    private let finishedAt = Date(timeIntervalSince1970: 101)

    func testThreatRemediationRetryTokenAcceptsCaseInsensitivePlistExtension() throws {
        let token = try XCTUnwrap(ThreatRemediationRetryToken(
            validatedLabel: "com.xico.case-insensitive",
            rootRelativeIdentity: "Agent.PLIST"))

        XCTAssertEqual(token.rootRelativeIdentity, "Agent.PLIST")
        XCTAssertNil(ThreatRemediationRetryToken(
            validatedLabel: "com.xico.not-a-plist",
            rootRelativeIdentity: "Agent.PLIST.backup"))
    }

    func testCanonicalOperationKindsHaveStableUniqueRawValues() {
        let expected: [(OperationKind, String)] = [
            (.cleaningExecute, "cleaning.execute"),
            (.cleaningUndo, "cleaning.undo"),
            (.threatRemediation, "threat.remediate"),
            (.spaceTrash, "space.trash"),
            (.snapshotDelete, "snapshot.delete"),
            (.shred, "shred.execute"),
            (.uninstall, "uninstall.execute"),
            (.maintenance, "maintenance.execute"),
            (.helperInstall, "helper.install"),
            (.iCloudEvict, "icloud.evict"),
            (.appTerminate, "optimization.terminate"),
            (.launchAgentToggle, "optimization.launchAgent"),
            (.memoryPurge, "optimization.memoryPurge"),
            (.appUpdateCheck, "update.thirdParty.check"),
            (.xicoUpdateCheck, "update.xico.check"),
            (.sftpDelete, "remote.sftp.delete"),
            (.hostDelete, "remote.host.delete"),
            (.tunnelDelete, "remote.tunnel.delete"),
            (.remoteDisconnect, "remote.disconnect"),
            (.snippetDelete, "server.snippet.delete"),
            (.downloadJob, "download.job"),
            (.componentInstall, "download.component.install"),
            (.historyClear, "history.clear"),
            (.benchmarkHistoryClear, "benchmark.history.clear"),
            (.ignoreRemove, "ignore.remove"),
            (.onboardingReset, "settings.onboarding.reset"),
            (.licenseDeactivate, "license.deactivate")
        ]

        XCTAssertEqual(expected.count, 27)
        XCTAssertEqual(Set(expected.map(\.0)).count, expected.count)
        XCTAssertEqual(Set(expected.map(\.1)).count, expected.count)
        for (kind, rawValue) in expected {
            XCTAssertEqual(kind.rawValue, rawValue)
        }
    }

    func testRetrySelectionKeepsOnlyRetryableNonSuccessSubjectsInInputOrder() throws {
        let items = try reducerAcceptedItems([
            item("retry-failed", .failed(issue("retry-failed", retryable: true))),
            item("succeeded", .succeeded, mutation: .changed),
            item("retry-skipped", .skipped(issue("retry-skipped", retryable: true))),
            item("unchanged", .unchanged),
            item("retry-cancelled", .cancelled(issue("retry-cancelled", retryable: true)))
        ])

        XCTAssertEqual(OperationConsumerFacts.retryableSubjectIDs(from: items), [
            "retry-failed", "retry-skipped", "retry-cancelled"
        ])
    }

    func testRetrySelectionDoesNotRetrySucceededUnchangedOrNonRetryableSubjects() throws {
        let items = try reducerAcceptedItems([
            item("succeeded", .succeeded, mutation: .changed),
            item("unchanged", .unchanged),
            item("failed", .failed(issue("failed", retryable: false))),
            item("skipped", .skipped(issue("skipped", retryable: false))),
            item("cancelled", .cancelled(issue("cancelled", retryable: false)))
        ])

        XCTAssertEqual(OperationConsumerFacts.retryableSubjectIDs(from: items), [])
    }

    func testRetrySelectionTreatsCancellationWithoutIssueAsUnattemptedAndRetryable() throws {
        let items = try reducerAcceptedItems([
            item("unattempted", .cancelled(nil)),
            item("retryable-cancelled", .cancelled(issue("retryable-cancelled", retryable: true))),
            item("nonretryable-cancelled", .cancelled(issue("nonretryable-cancelled",
                                                            retryable: false)))
        ], cancellationAccepted: true)

        XCTAssertEqual(OperationConsumerFacts.retryableSubjectIDs(from: items), [
            "unattempted", "retryable-cancelled"
        ])
    }

    func testRetrySelectionPreservesDuplicateSubjectsWithoutDeduplicating() throws {
        let items = try reducerAcceptedItems([
            item("duplicate", .failed(issue("duplicate", code: "first", retryable: true))),
            item("middle", .skipped(issue("middle", retryable: true))),
            item("duplicate", .failed(issue("duplicate", code: "second", retryable: true)))
        ])

        XCTAssertEqual(OperationConsumerFacts.retryableSubjectIDs(from: items), [
            "duplicate", "middle", "duplicate"
        ])
    }

    func testCleaningRetrySelectionUsesTypedFactsAndPreservesDeletionAuxiliaryOrder() throws {
        let firstDeletionID = UUID()
        let remediationID = UUID()
        let secondDeletionID = UUID()
        let thirdDeletionID = UUID()
        let url = URL(fileURLWithPath: "/tmp/retry-facts.plist")
        let retryIssue = OperationIssue(
            code: "test.retry", category: .io,
            subjectID: remediationID.uuidString,
            recovery: .retry, retryable: true)
        let noRetryIssue = OperationIssue(
            code: "test.manual", category: .safetyPolicy,
            subjectID: thirdDeletionID.uuidString,
            recovery: .manualAction, retryable: false)
        let secondItem = CleanableItem(
            id: UUID(), url: url, displayName: "second", size: 1)
        let token = try XCTUnwrap(ThreatRemediationRetryToken(
            validatedLabel: "com.xico.retry.facts",
            rootRelativeIdentity: "retry-facts.plist"))
        let facts: [CleaningOperationFact] = [
            .deletion(CleaningItemResult(
                requestID: firstDeletionID, itemID: UUID(), url: url,
                intent: .trash, disposition: .succeeded, mutation: .changed,
                reclaimedBytes: 1, restorable: nil)),
            .auxiliary(CleaningAuxiliaryItemResult(
                requestID: remediationID,
                relatedCleaningRequestID: firstDeletionID,
                kind: .threatRemediation,
                disposition: .failed(retryIssue),
                mutation: .possiblyChanged,
                retryToken: token)),
            .deletion(CleaningItemResult(
                requestID: secondDeletionID, itemID: secondItem.id, url: url,
                intent: .permanent,
                retryAuthorization: CleaningRetryAuthorization(
                    item: secondItem,
                    intent: .permanent,
                    prerequisite: .none),
                disposition: .cancelled(nil), mutation: .none,
                reclaimedBytes: 0, restorable: nil)),
            .deletion(CleaningItemResult(
                requestID: thirdDeletionID, itemID: UUID(), url: url,
                intent: .permanent, disposition: .failed(noRetryIssue), mutation: .none,
                reclaimedBytes: 0, restorable: nil))
        ]
        let outcome = try OperationOutcomeReducer.reduce(
            kind: .cleaningExecute,
            requestedSubjectIDs: facts.map { $0.requestID.uuidString },
            itemOutcomes: facts.map {
                OperationItemOutcome(
                    subjectID: $0.requestID.uuidString,
                    disposition: $0.disposition,
                    mutation: $0.mutation,
                    affectedBytes: $0.affectedBytes)
            },
            cancellationAccepted: true,
            startedAt: startedAt,
            finishedAt: finishedAt)
        let report = CleaningReport(operation: outcome, facts: facts)

        let selected = OperationConsumerFacts.retryableCleaningFacts(from: report)

        XCTAssertEqual(selected.map(\.requestID), [remediationID, secondDeletionID])
        guard case .auxiliary = selected.first else {
            return XCTFail("Expected the retryable remediation fact first")
        }
        guard case .deletion = selected.last else {
            return XCTFail("Expected the unattempted deletion fact second")
        }
    }

    func testCleaningRetrySelectionRejectsRetryableLookingFactsWithoutAuthority() throws {
        let deletionID = UUID()
        let remediationID = UUID()
        let issue = OperationIssue(
            code: "test.retry",
            category: .io,
            subjectID: deletionID.uuidString,
            recovery: .retry,
            retryable: true)
        let facts: [CleaningOperationFact] = [
            .deletion(CleaningItemResult(
                requestID: deletionID,
                itemID: UUID(),
                url: URL(fileURLWithPath: "/tmp/no-authority.plist"),
                intent: .permanent,
                disposition: .failed(issue),
                mutation: .none,
                reclaimedBytes: 0,
                restorable: nil)),
            .auxiliary(CleaningAuxiliaryItemResult(
                requestID: remediationID,
                relatedCleaningRequestID: deletionID,
                kind: .threatRemediation,
                disposition: .failed(OperationIssue(
                    code: "test.retry.aux",
                    category: .io,
                    subjectID: remediationID.uuidString,
                    recovery: .retry,
                    retryable: true)),
                mutation: .none))
        ]
        let outcome = try OperationOutcomeReducer.reduce(
            kind: .cleaningExecute,
            requestedSubjectIDs: facts.map { $0.requestID.uuidString },
            itemOutcomes: facts.map {
                OperationItemOutcome(
                    subjectID: $0.requestID.uuidString,
                    disposition: $0.disposition,
                    mutation: $0.mutation)
            },
            cancellationAccepted: false,
            startedAt: startedAt,
            finishedAt: finishedAt)

        XCTAssertTrue(OperationConsumerFacts.retryableCleaningFacts(
            from: CleaningReport(operation: outcome, facts: facts)).isEmpty)
    }

    func testCleaningRetrySelectionRejectsMutatedDeletionButKeepsTokenAuxiliary() throws {
        let changedID = UUID()
        let uncertainID = UUID()
        let contextID = UUID()
        let auxiliaryID = UUID()
        let issue: (UUID) -> OperationIssue = { requestID in
            OperationIssue(
                code: "test.retry.mutated",
                category: .io,
                subjectID: requestID.uuidString,
                recovery: .retry,
                retryable: true)
        }
        func deletion(
            requestID: UUID,
            mutation: OperationMutationFact
        ) -> CleaningItemResult {
            let item = CleanableItem(
                id: UUID(),
                url: URL(fileURLWithPath: "/tmp/mutated-\(requestID).plist"),
                displayName: "mutated",
                size: 1)
            return CleaningItemResult(
                requestID: requestID,
                itemID: item.id,
                url: item.url,
                intent: .permanent,
                retryAuthorization: CleaningRetryAuthorization(
                    item: item,
                    intent: .permanent,
                    prerequisite: .none),
                disposition: .failed(issue(requestID)),
                mutation: mutation,
                reclaimedBytes: 0,
                restorable: nil)
        }
        let token = try XCTUnwrap(ThreatRemediationRetryToken(
            validatedLabel: "com.xico.retry.auxiliary",
            rootRelativeIdentity: "retry-auxiliary.plist"))
        let facts: [CleaningOperationFact] = [
            .deletion(deletion(requestID: changedID, mutation: .changed)),
            .deletion(deletion(requestID: uncertainID, mutation: .possiblyChanged)),
            .deletion(CleaningItemResult(
                requestID: contextID,
                itemID: UUID(),
                url: URL(fileURLWithPath: "/tmp/retry-auxiliary.plist"),
                intent: .permanent,
                disposition: .succeeded,
                mutation: .changed,
                reclaimedBytes: 1,
                restorable: nil)),
            .auxiliary(CleaningAuxiliaryItemResult(
                requestID: auxiliaryID,
                relatedCleaningRequestID: contextID,
                kind: .threatRemediation,
                disposition: .failed(issue(auxiliaryID)),
                mutation: .possiblyChanged,
                retryToken: token))
        ]
        let outcome = try OperationOutcomeReducer.reduce(
            kind: .cleaningExecute,
            requestedSubjectIDs: facts.map { $0.requestID.uuidString },
            itemOutcomes: facts.map {
                OperationItemOutcome(
                    subjectID: $0.requestID.uuidString,
                    disposition: $0.disposition,
                    mutation: $0.mutation,
                    affectedBytes: $0.affectedBytes)
            },
            cancellationAccepted: false,
            startedAt: startedAt,
            finishedAt: finishedAt)
        let selected = OperationConsumerFacts.retryableCleaningFacts(
            from: CleaningReport(operation: outcome, facts: facts))

        XCTAssertEqual(selected.map(\.requestID), [auxiliaryID])
        guard let first = selected.first, case .auxiliary = first else {
            return XCTFail("Only the token-backed auxiliary may remain retryable")
        }
    }

    func testRetryCreatesNewIDAndPreservesParentID() throws {
        let parent = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000099"))
        let subjects = ["completed", "failed", "unattempted"]
        let items = [
            item("completed", .succeeded, mutation: .changed, bytes: 64),
            item("failed", .failed(issue("failed", retryable: true))),
            item("unattempted", .cancelled(nil))
        ]

        let first = try OperationConsumerFacts.retryRequest(
            parent: parent,
            kind: .maintenance,
            subjects: subjects,
            itemOutcomes: items,
            cancellationAccepted: true,
            startedAt: startedAt,
            finishedAt: finishedAt)
        let second = try OperationConsumerFacts.retryRequest(
            parent: parent,
            kind: .maintenance,
            subjects: subjects,
            itemOutcomes: items,
            cancellationAccepted: true,
            startedAt: startedAt,
            finishedAt: finishedAt)

        XCTAssertNotEqual(first.id, parent)
        XCTAssertNotEqual(second.id, parent)
        XCTAssertNotEqual(first.id, second.id)
        XCTAssertEqual(first.parentID, parent)
        XCTAssertEqual(first.kind, .maintenance)
        XCTAssertEqual(first.status, .cancelled)
        XCTAssertEqual(first.counts, OperationCounts(
            requested: 3,
            succeeded: 1,
            unchanged: 0,
            skipped: 0,
            failed: 1,
            cancelled: 1))
        XCTAssertEqual(first.mutation, .changed)
        XCTAssertEqual(first.startedAt, startedAt)
        XCTAssertEqual(first.finishedAt, finishedAt)
        XCTAssertEqual(first.issues.map(\.code), ["retryable"])
    }

    func testUnknownOperationKindHasFailClosedSemantics() {
        XCTAssertNil(OutcomeOperationRegistry.semantics(
            for: OperationKind("unreviewed.operation")))
    }

    func testNeutralIrreversibleKindSuppressesEveryCelebratoryCapability() throws {
        let irreversibleKinds: [OperationKind] = [
            .snapshotDelete, .shred, .sftpDelete, .hostDelete, .tunnelDelete
        ]

        for kind in irreversibleKinds {
            let semantics = try XCTUnwrap(OutcomeOperationRegistry.semantics(for: kind))
            XCTAssertEqual(semantics.profile, .neutral, kind.rawValue)
            XCTAssertFalse(semantics.allowsCleaningSuccessNotification, kind.rawValue)
        }
    }

    func testOnlyCleaningExecuteIsCleaningNotificationEligible() throws {
        let eligible = try allCanonicalKinds.filter { kind in
            try XCTUnwrap(OutcomeOperationRegistry.semantics(for: kind))
                .allowsCleaningSuccessNotification
        }

        XCTAssertEqual(eligible, [.cleaningExecute])
    }

    func testRegistryMatchesReviewedCapabilityMatrix() throws {
        let expectations: [RegistryExpectation] = [
            expectation(.cleaningExecute, .celebratory, true, true,
                        [.diskCapacity, .scanIndex, .cleaningHistory]),
            expectation(.cleaningUndo, .neutral, false, false,
                        [.diskCapacity, .scanIndex, .cleaningHistory]),
            expectation(.threatRemediation, .neutral, false, false,
                        [.diskCapacity, .scanIndex]),
            expectation(.spaceTrash, .celebratory, true, false,
                        [.diskCapacity, .scanIndex, .cleaningHistory]),
            expectation(.snapshotDelete, .neutral, false, false, [.diskCapacity]),
            expectation(.shred, .neutral, true, false,
                        [.diskCapacity, .cleaningHistory]),
            expectation(.uninstall, .celebratory, true, false,
                        [.diskCapacity, .installedApps, .cleaningHistory]),
            expectation(.maintenance, .neutral, false, false, [.diskCapacity]),
            expectation(.helperInstall, .neutral, false, false, []),
            expectation(.iCloudEvict, .neutral, false, false, [.diskCapacity]),
            expectation(.appTerminate, .neutral, false, false, [.runningApplications]),
            expectation(.launchAgentToggle, .neutral, false, false, [.launchAgents]),
            expectation(.memoryPurge, .neutral, false, false, [.runningApplications]),
            expectation(.appUpdateCheck, .neutral, false, false, []),
            expectation(.xicoUpdateCheck, .neutral, false, false, []),
            expectation(.sftpDelete, .neutral, false, false, [.remoteDirectory]),
            expectation(.hostDelete, .neutral, false, false, [.serverConfiguration]),
            expectation(.tunnelDelete, .neutral, false, false,
                        [.tunnels, .serverConfiguration]),
            expectation(.remoteDisconnect, .neutral, false, false, [.remoteConnections]),
            expectation(.snippetDelete, .neutral, false, false, [.serverConfiguration]),
            expectation(.downloadJob, .neutral, false, false, []),
            expectation(.componentInstall, .neutral, false, false, [.downloadComponents]),
            expectation(.historyClear, .neutral, false, false, [.cleaningHistory]),
            expectation(.benchmarkHistoryClear, .neutral, false, false, [.benchmarkHistory]),
            expectation(.ignoreRemove, .neutral, false, false, [.ignoreList]),
            expectation(.onboardingReset, .neutral, false, false, []),
            expectation(.licenseDeactivate, .neutral, false, false, [.license])
        ]

        XCTAssertEqual(expectations.count, 27)
        XCTAssertEqual(Set(expectations.map(\.kind)), Set(allCanonicalKinds))
        for expected in expectations {
            let actual = try XCTUnwrap(
                OutcomeOperationRegistry.semantics(for: expected.kind),
                "Missing reviewed semantics for \(expected.kind.rawValue)")
            XCTAssertEqual(actual.profile, expected.profile, expected.kind.rawValue)
            XCTAssertEqual(actual.recordsHistory, expected.recordsHistory,
                           expected.kind.rawValue)
            XCTAssertEqual(actual.allowsCleaningSuccessNotification,
                           expected.allowsCleaningSuccessNotification,
                           expected.kind.rawValue)
            XCTAssertEqual(actual.invalidationDomains, expected.invalidationDomains,
                           expected.kind.rawValue)
        }
    }

    private var allCanonicalKinds: [OperationKind] {
        [
            .cleaningExecute, .cleaningUndo, .threatRemediation, .spaceTrash,
            .snapshotDelete, .shred, .uninstall, .maintenance, .helperInstall,
            .iCloudEvict, .appTerminate, .launchAgentToggle, .memoryPurge,
            .appUpdateCheck, .xicoUpdateCheck, .sftpDelete, .hostDelete,
            .tunnelDelete, .remoteDisconnect, .snippetDelete, .downloadJob,
            .componentInstall, .historyClear, .benchmarkHistoryClear, .ignoreRemove,
            .onboardingReset, .licenseDeactivate
        ]
    }

    private func expectation(
        _ kind: OperationKind,
        _ profile: OutcomeWorkflowProfile,
        _ recordsHistory: Bool,
        _ allowsCleaningSuccessNotification: Bool,
        _ invalidationDomains: Set<OutcomeInvalidationDomain>
    ) -> RegistryExpectation {
        RegistryExpectation(
            kind: kind,
            profile: profile,
            recordsHistory: recordsHistory,
            allowsCleaningSuccessNotification: allowsCleaningSuccessNotification,
            invalidationDomains: invalidationDomains)
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
        _ subjectID: String,
        code: String = "retryable",
        retryable: Bool
    ) -> OperationIssue {
        OperationIssue(
            code: code,
            category: .io,
            subjectID: subjectID,
            recovery: retryable ? .retry : .manualAction,
            retryable: retryable)
    }

    private func reducerAcceptedItems(
        _ items: [OperationItemOutcome],
        cancellationAccepted: Bool = false
    ) throws -> [OperationItemOutcome] {
        var seen: Set<String> = []
        let requested = items.compactMap { item -> String? in
            seen.insert(item.subjectID).inserted ? item.subjectID : nil
        }
        _ = try OperationOutcomeReducer.reduce(
            kind: OperationKind("test.retry.fixture"),
            requestedSubjectIDs: requested,
            itemOutcomes: items,
            cancellationAccepted: cancellationAccepted,
            startedAt: startedAt,
            finishedAt: finishedAt)
        return items
    }

}
