import Foundation
import XCTest
import Domain
@testable import Features

final class TaskOutcomeAccessibilityTests: XCTestCase {
    private static let locales = [
        "en", "zh-Hans", "zh-Hant", "ja", "ko",
        "de", "fr", "es", "it", "pt-BR", "ru",
    ]

    private static let baseLocale = "zh-Hans"

    private static let stateKeys = [
        "操作已完成",
        "目标已经满足",
        "部分完成",
        "操作失败",
        "操作已取消",
        "不可逆操作已完成",
        "结果需要确认",
    ]

    private static let countKeys = [
        "请求 %d 项",
        "完成 %d 项",
        "无需更改 %d 项",
        "跳过 %d 项",
        "失败 %d 项",
        "取消 %d 项",
    ]

    private static let actionKeys = [
        "重试 %d 个失败项目",
        "继续处理 %d 个剩余项目",
        "查看详情",
        "撤销已更改项目",
        "按建议恢复",
        "完成",
    ]

    private static let announcementKeys = [
        "%@。%@。下一步：%@",
    ]

    private static let compatibilityShimKeys = [
        "结果展示正在升级",
        "请返回并重新执行此操作以查看完整结果。",
    ]

    private static var localizationInventory: [String] {
        stateKeys + countKeys + actionKeys + announcementKeys + compatibilityShimKeys
    }

    func testEveryTerminalVariantExposesNonemptyLabelStatusAndExactCounts() throws {
        let cases = try presentationCases()

        XCTAssertEqual(cases.count, 6)
        for candidate in cases {
            let presentation = candidate.presentation
            let operation = candidate.operation

            XCTAssertFalse(
                presentation.accessibilityLabel
                    .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                candidate.name)
            XCTAssertFalse(
                presentation.titleKey
                    .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                "\(candidate.name) must expose a spoken status phrase")
            XCTAssertFalse(
                presentation.detailKey
                    .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                "\(candidate.name) must expose domain detail")
            XCTAssertFalse(
                presentation.systemImage
                    .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                "\(candidate.name) needs a non-color state cue")
            assertCounts(
                presentation.countSummary,
                equal: operation.counts,
                name: candidate.name)
            XCTAssertTrue(
                presentation.accessibilityLabel.containsDecimalCount,
                "\(candidate.name) accessibility label must include a count summary")
        }
    }

    func testTerminalVariantsAreDistinguishableWithoutColorOrSuccessCheckmark() throws {
        let cases = try presentationCases()
        let byName = Dictionary(uniqueKeysWithValues: cases.map { ($0.name, $0.presentation) })
        let changed = try XCTUnwrap(byName["changed-success"])
        let unchanged = try XCTUnwrap(byName["unchanged-success"])
        let partial = try XCTUnwrap(byName["partial"])
        let failure = try XCTUnwrap(byName["failure"])
        let cancelled = try XCTUnwrap(byName["cancelled"])
        let irreversible = try XCTUnwrap(byName["irreversible"])

        XCTAssertEqual(changed.semanticRole, .success)
        XCTAssertEqual(unchanged.semanticRole, .neutral)
        XCTAssertEqual(partial.semanticRole, .warning)
        XCTAssertEqual(failure.semanticRole, .error)
        XCTAssertEqual(cancelled.semanticRole, .cancelled)
        XCTAssertEqual(irreversible.semanticRole, .irreversible)

        XCTAssertNotEqual(partial.systemImage, failure.systemImage)
        XCTAssertNotEqual(partial.systemImage, cancelled.systemImage)
        XCTAssertNotEqual(failure.systemImage, cancelled.systemImage)
        XCTAssertNotEqual(partial.titleKey, failure.titleKey)
        XCTAssertNotEqual(partial.titleKey, cancelled.titleKey)
        XCTAssertNotEqual(failure.titleKey, cancelled.titleKey)
        for presentation in [partial, failure, cancelled] {
            XCTAssertFalse(
                presentation.systemImage.localizedCaseInsensitiveContains("checkmark"),
                "Partial, failure and cancelled states must never use a success checkmark")
        }
        XCTAssertTrue(
            irreversible.systemImage.localizedCaseInsensitiveContains("shield"),
            "Irreversible completion must be a static shield confirmation")
    }

    func testEveryTerminalVariantHasDeterministicActionOrder() throws {
        let cases = try presentationCases()
        let expected: [String: [TaskOutcomeActionKind]] = [
            "changed-success": [.undoChanged, .done],
            "unchanged-success": [.done],
            "partial": [.retryFailed, .details, .undoChanged, .done],
            "failure": [.recovery, .details, .done],
            "cancelled": [.retryRemaining, .details, .undoChanged, .done],
            "irreversible": [.done],
        ]

        for candidate in cases {
            XCTAssertEqual(
                candidate.presentation.actionOrder,
                try XCTUnwrap(expected[candidate.name]),
                candidate.name)
            XCTAssertEqual(
                Set(candidate.presentation.actionOrder).count,
                candidate.presentation.actionOrder.count,
                "\(candidate.name) must not render duplicate actions")
            XCTAssertEqual(candidate.presentation.actionOrder.last, .done, candidate.name)
        }
    }

    func testEveryApprovedIrreversibleKindUsesStaticShieldAndDoneOnly() throws {
        let irreversibleKinds: [OperationKind] = [
            .snapshotDelete,
            .shred,
            .sftpDelete,
            .hostDelete,
            .tunnelDelete,
        ]
        XCTAssertEqual(irreversibleKinds.count, 5)

        for kind in irreversibleKinds {
            let operation = try reduce(
                kind: kind,
                facts: [fact("irreversible-\(kind.rawValue)", .succeeded, .changed, bytes: 1)])
            let context = outcomeContext(
                operation,
                affectedBytes: 1,
                canUndoChangedItems: false,
                retryableSubjectCount: 0)
            let presentation = TaskOutcomePresentation.make(context: context)

            XCTAssertEqual(presentation.semanticRole, .irreversible, kind.rawValue)
            XCTAssertTrue(
                presentation.systemImage.localizedCaseInsensitiveContains("shield"),
                kind.rawValue)
            XCTAssertEqual(presentation.actionOrder, [.done], kind.rawValue)
            XCTAssertFalse(presentation.allowsCelebration, kind.rawValue)
            XCTAssertFalse(presentation.allowsSuccessSoundHaptic, kind.rawValue)
        }
    }

    func testAnnouncementIncludesStatusCountsAndDeterministicNextAction() throws {
        for candidate in try presentationCases() {
            let presentation = candidate.presentation
            let announcement = presentation.announcement
            let nextAction = try XCTUnwrap(presentation.actionOrder.first)

            XCTAssertFalse(
                announcement.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                candidate.name)
            XCTAssertTrue(
                announcement.containsDecimalCount,
                "\(candidate.name) announcement must speak result counts")
            XCTAssertTrue(
                try containsLocalizedVariant(of: presentation.titleKey, in: announcement),
                "\(candidate.name) announcement must speak its status")
            XCTAssertTrue(
                try containsLocalizedActionVariant(
                    nextAction,
                    presentation: presentation,
                    in: announcement),
                "\(candidate.name) announcement must speak the deterministic next action")
        }
    }

    func testAnnouncementUsesCanonicalGateOnceAndRejectsHistoricalOrStaleOperations() async {
        let gate = OutcomeFeedbackGate()
        let historicalID = UUID()
        let liveID = UUID()
        let nextLiveID = UUID()

        let historical = await gate.consume(.accessibilityAnnouncement, for: historicalID)
        XCTAssertFalse(historical)

        await gate.registerTerminal(liveID)
        for channel in existingEffectChannels {
            let first = await gate.consume(channel, for: liveID)
            XCTAssertTrue(first, "\(channel)")
        }
        let firstAnnouncement = await gate.consume(.accessibilityAnnouncement, for: liveID)
        let secondAnnouncement = await gate.consume(.accessibilityAnnouncement, for: liveID)
        XCTAssertTrue(firstAnnouncement)
        XCTAssertFalse(secondAnnouncement)
        for channel in existingEffectChannels {
            let second = await gate.consume(channel, for: liveID)
            XCTAssertFalse(
                second,
                "Announcement consumption must not reset \(channel)")
        }

        await gate.registerTerminal(nextLiveID)
        let stale = await gate.consume(.accessibilityAnnouncement, for: liveID)
        let nextFirst = await gate.consume(.accessibilityAnnouncement, for: nextLiveID)
        let nextSecond = await gate.consume(.accessibilityAnnouncement, for: nextLiveID)
        XCTAssertFalse(stale)
        XCTAssertTrue(nextFirst)
        XCTAssertFalse(nextSecond)
    }

    func testReduceMotionConstructsNoEffectsOrTasksAndPreservesFocusAndActionOrder() throws {
        let operation = try changedSuccess()
        let context = outcomeContext(
            operation,
            affectedBytes: 4_096,
            canUndoChangedItems: true,
            retryableSubjectCount: 0)
        let presentation = TaskOutcomePresentation.make(context: context)
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
        let historical = OutcomeMotionPlan.make(
            context: context,
            presentation: presentation,
            visualEffectGranted: false,
            reduceMotion: false)

        XCTAssertTrue(animated.constructsBurst)
        XCTAssertTrue(animated.createsDelayedRevealTask)
        XCTAssertTrue(animated.createsCountUpTask)
        XCTAssertEqual(animated.initialNumericValue, 0)
        XCTAssertEqual(animated.finalNumericValue, 4_096)

        XCTAssertFalse(reduced.constructsBurst)
        XCTAssertFalse(reduced.createsDelayedRevealTask)
        XCTAssertFalse(reduced.createsCountUpTask)
        XCTAssertEqual(reduced.initialNumericValue, 4_096)
        XCTAssertEqual(reduced.finalNumericValue, 4_096)
        XCTAssertEqual(reduced.actionOrder, animated.actionOrder)
        XCTAssertEqual(reduced.initialFocus, animated.initialFocus)
        let focus = try XCTUnwrap(reduced.initialFocus)
        XCTAssertTrue(reduced.actionOrder.contains(focus))
        XCTAssertEqual(reduced.actionOrder, presentation.actionOrder)
        XCTAssertFalse(historical.constructsBurst)
        XCTAssertFalse(historical.createsDelayedRevealTask)
        XCTAssertFalse(historical.createsCountUpTask)
        XCTAssertEqual(historical.initialNumericValue, 4_096)
    }

    func testTaskOutcomeLocalizationInventoryIsExactAndExistsInAllElevenLocales() throws {
        XCTAssertEqual(Self.locales.count, 11)
        XCTAssertEqual(Set(Self.locales).count, 11)
        XCTAssertEqual(Self.stateKeys.count, 7)
        XCTAssertEqual(Self.countKeys.count, 6)
        XCTAssertEqual(Self.actionKeys.count, 6)
        XCTAssertEqual(Self.announcementKeys.count, 1)
        XCTAssertEqual(Self.compatibilityShimKeys.count, 2)
        XCTAssertEqual(Self.localizationInventory.count, 22)
        XCTAssertEqual(Set(Self.localizationInventory).count, 22)

        let expected = Set(Self.localizationInventory)
        for locale in Self.locales {
            let missing = expected.subtracting(try stringsTable(locale).keys).sorted()
            XCTAssertTrue(
                missing.isEmpty,
                "\(locale) lacks Task Outcome keys:\n\(missing.joined(separator: "\n"))")
        }
    }

    func testTaskOutcomeLocalizationPlaceholdersHaveExactParity() throws {
        for locale in Self.locales {
            let table = try stringsTable(locale)
            for key in Self.localizationInventory {
                let value = try XCTUnwrap(table[key], "\(locale) lacks \(key)")
                XCTAssertEqual(
                    try placeholderKinds(in: value),
                    try placeholderKinds(in: key),
                    "\(locale) changes Task Outcome placeholders for \(key)")
            }
        }
    }

    func testNonChineseTaskOutcomeTranslationsAreNonemptyAndNeverCopySourceText() throws {
        let legitimateSameSpelling: [String: Set<String>] = [
            "zh-Hant": ["完成"],
        ]
        for locale in Self.locales where locale != Self.baseLocale {
            let table = try stringsTable(locale)
            for key in Self.localizationInventory {
                let value = try XCTUnwrap(table[key], "\(locale) lacks \(key)")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                XCTAssertFalse(value.isEmpty, "\(locale) has an empty translation for \(key)")
                if legitimateSameSpelling[locale]?.contains(key) != true {
                    XCTAssertNotEqual(value, key, "\(locale) copies the Chinese source text: \(key)")
                }
            }
        }
    }

    private struct PresentationCase {
        let name: String
        let operation: OperationOutcome
        let presentation: TaskOutcomePresentation
    }

    private func presentationCases() throws -> [PresentationCase] {
        let changed = try changedSuccess()
        let unchanged = try unchangedSuccess()
        let partial = try partialOutcome()
        let failure = try failedOutcome()
        let cancelled = try cancelledOutcome()
        let irreversible = try irreversibleSuccess()

        return [
            makeCase(
                "changed-success", operation: changed, affectedBytes: 42,
                canUndoChangedItems: true, retryableSubjectCount: 0),
            makeCase(
                "unchanged-success", operation: unchanged, affectedBytes: 0,
                canUndoChangedItems: false, retryableSubjectCount: 0),
            makeCase(
                "partial", operation: partial, affectedBytes: 11,
                canUndoChangedItems: true, retryableSubjectCount: 1),
            makeCase(
                "failure", operation: failure, affectedBytes: nil,
                canUndoChangedItems: false, retryableSubjectCount: 0),
            makeCase(
                "cancelled", operation: cancelled, affectedBytes: 7,
                canUndoChangedItems: true, retryableSubjectCount: 1),
            makeCase(
                "irreversible", operation: irreversible, affectedBytes: 9,
                canUndoChangedItems: false, retryableSubjectCount: 0),
        ]
    }

    private func makeCase(
        _ name: String,
        operation: OperationOutcome,
        affectedBytes: Int64?,
        canUndoChangedItems: Bool,
        retryableSubjectCount: Int
    ) -> PresentationCase {
        let context = outcomeContext(
            operation,
            affectedBytes: affectedBytes,
            canUndoChangedItems: canUndoChangedItems,
            retryableSubjectCount: retryableSubjectCount)
        return PresentationCase(
            name: name,
            operation: operation,
            presentation: TaskOutcomePresentation.make(context: context))
    }

    private func outcomeContext(
        _ operation: OperationOutcome,
        affectedBytes: Int64?,
        canUndoChangedItems: Bool,
        retryableSubjectCount: Int
    ) -> TaskOutcomeContext {
        TaskOutcomeContext(
            operation: operation,
            affectedBytes: affectedBytes,
            primaryDetailKey: "任务结果详情",
            note: nil,
            canUndoChangedItems: canUndoChangedItems,
            retryableSubjectCount: retryableSubjectCount)
    }

    private func changedSuccess() throws -> OperationOutcome {
        try reduce(
            kind: .cleaningExecute,
            facts: [
                fact("changed-1", .succeeded, .changed, bytes: 40),
                fact("changed-2", .succeeded, .changed, bytes: 2),
            ])
    }

    private func unchangedSuccess() throws -> OperationOutcome {
        try reduce(
            kind: .cleaningExecute,
            facts: [
                fact("unchanged-1", .unchanged, .none),
                fact("unchanged-2", .unchanged, .none),
            ])
    }

    private func partialOutcome() throws -> OperationOutcome {
        let failedID = "partial-failed"
        let issue = OperationIssue(
            code: "task.outcome.partial.retry",
            category: .io,
            subjectID: failedID,
            recovery: .retry,
            retryable: true)
        return try reduce(
            kind: .cleaningExecute,
            facts: [
                fact("partial-success", .succeeded, .changed, bytes: 11),
                fact(failedID, .failed(issue), .none),
            ])
    }

    private func failedOutcome() throws -> OperationOutcome {
        let firstID = "failure-1"
        let secondID = "failure-2"
        return try reduce(
            kind: .cleaningExecute,
            facts: [
                fact(firstID, .failed(OperationIssue(
                    code: "task.outcome.failure.permission",
                    category: .permission,
                    subjectID: firstID,
                    recovery: .openSettings,
                    retryable: false)), .none),
                fact(secondID, .failed(OperationIssue(
                    code: "task.outcome.failure.permission",
                    category: .permission,
                    subjectID: secondID,
                    recovery: .openSettings,
                    retryable: false)), .none),
            ])
    }

    private func cancelledOutcome() throws -> OperationOutcome {
        try reduce(
            kind: .cleaningExecute,
            facts: [
                fact("cancelled-success", .succeeded, .changed, bytes: 7),
                fact("cancelled-pending", .cancelled(nil), .none),
            ],
            cancellationAccepted: true)
    }

    private func irreversibleSuccess() throws -> OperationOutcome {
        try reduce(
            kind: .shred,
            facts: [fact("shredded", .succeeded, .changed, bytes: 9)])
    }

    private struct Fact {
        let subjectID: String
        let disposition: OperationDisposition
        let mutation: OperationMutationFact
        let bytes: Int64
    }

    private func fact(
        _ subjectID: String,
        _ disposition: OperationDisposition,
        _ mutation: OperationMutationFact,
        bytes: Int64 = 0
    ) -> Fact {
        Fact(
            subjectID: subjectID,
            disposition: disposition,
            mutation: mutation,
            bytes: bytes)
    }

    private func reduce(
        kind: OperationKind,
        facts: [Fact],
        cancellationAccepted: Bool = false
    ) throws -> OperationOutcome {
        try OperationOutcomeReducer.reduce(
            kind: kind,
            requestedSubjectIDs: facts.map(\.subjectID),
            itemOutcomes: facts.map {
                OperationItemOutcome(
                    subjectID: $0.subjectID,
                    disposition: $0.disposition,
                    mutation: $0.mutation,
                    affectedBytes: $0.bytes)
            },
            cancellationAccepted: cancellationAccepted,
            startedAt: Date(timeIntervalSinceReferenceDate: 100),
            finishedAt: Date(timeIntervalSinceReferenceDate: 101))
    }

    private func assertCounts(
        _ summary: TaskOutcomeCountSummary,
        equal counts: OperationCounts,
        name: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(summary.requested, counts.requested, name, file: file, line: line)
        XCTAssertEqual(summary.succeeded, counts.succeeded, name, file: file, line: line)
        XCTAssertEqual(summary.unchanged, counts.unchanged, name, file: file, line: line)
        XCTAssertEqual(summary.skipped, counts.skipped, name, file: file, line: line)
        XCTAssertEqual(summary.failed, counts.failed, name, file: file, line: line)
        XCTAssertEqual(summary.cancelled, counts.cancelled, name, file: file, line: line)
    }

    private func actionKey(for action: TaskOutcomeActionKind) -> String {
        switch action {
        case .retryFailed: "重试 %d 个失败项目"
        case .retryRemaining: "继续处理 %d 个剩余项目"
        case .details: "查看详情"
        case .undoChanged: "撤销已更改项目"
        case .recovery: "按建议恢复"
        case .done: "完成"
        }
    }

    private var existingEffectChannels: [OutcomeEffectChannel] {
        [
            .history,
            .successNotification,
            .celebration,
            .successSoundHaptic,
            .internalInvalidation,
        ]
    }

    private func containsLocalizedActionVariant(
        _ action: TaskOutcomeActionKind,
        presentation: TaskOutcomePresentation,
        in text: String
    ) throws -> Bool {
        let key = actionKey(for: action)
        let count: Int
        switch action {
        case .retryFailed:
            count = presentation.countSummary.failed
        case .retryRemaining:
            count = presentation.countSummary.cancelled
        case .details, .undoChanged, .recovery, .done:
            return try containsLocalizedVariant(of: key, in: text)
        }

        var variants: Set<String> = [String(format: key, count)]
        for locale in Self.locales {
            if let value = try stringsTable(locale)[key] {
                variants.insert(String(format: value, count))
            }
        }
        return variants.contains { candidate in
            !candidate.isEmpty && text.localizedCaseInsensitiveContains(candidate)
        }
    }

    private func containsLocalizedVariant(of key: String, in text: String) throws -> Bool {
        var variants: Set<String> = [key]
        for locale in Self.locales {
            if let value = try stringsTable(locale)[key] {
                variants.insert(value)
            }
        }
        return variants.contains { candidate in
            !candidate.isEmpty && text.localizedCaseInsensitiveContains(candidate)
        }
    }

    private func packageRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func stringsURL(_ locale: String) -> URL {
        packageRoot()
            .appendingPathComponent("Sources", isDirectory: true)
            .appendingPathComponent("DesignSystem", isDirectory: true)
            .appendingPathComponent("Resources", isDirectory: true)
            .appendingPathComponent("\(locale).lproj", isDirectory: true)
            .appendingPathComponent("Localizable.strings")
    }

    private func stringsTable(_ locale: String) throws -> [String: String] {
        let data = try Data(contentsOf: stringsURL(locale))
        let object = try PropertyListSerialization.propertyList(
            from: data,
            options: [],
            format: nil)
        return try XCTUnwrap(
            object as? [String: String],
            "\(locale) Localizable.strings must be a string dictionary")
    }

    private func placeholderKinds(in text: String) throws -> [String] {
        let regex = try NSRegularExpression(
            pattern: #"%(?:[1-9][0-9]*\$)?(@|d)"#)
        let source = text as NSString
        let range = NSRange(location: 0, length: source.length)
        return regex.matches(in: text, range: range).map {
            source.substring(with: $0.range(at: 1))
        }
    }
}

private extension String {
    var containsDecimalCount: Bool {
        rangeOfCharacter(from: .decimalDigits) != nil
    }
}
