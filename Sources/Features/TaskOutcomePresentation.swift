import Foundation
import Domain
import DesignSystem

struct TaskOutcomeContext: Sendable {
    let operation: OperationOutcome
    let affectedBytes: Int64?
    let primaryDetailKey: String
    let note: String?
    let canUndoChangedItems: Bool
    let retryableSubjectCount: Int
}

@MainActor
struct TaskOutcomeActions {
    var retry: (() -> Void)?
    var details: (() -> Void)?
    var undo: (() -> Void)?
    var recovery: (() -> Void)?
    var done: () -> Void

    init(
        retry: (() -> Void)? = nil,
        details: (() -> Void)? = nil,
        undo: (() -> Void)? = nil,
        recovery: (() -> Void)? = nil,
        done: @escaping () -> Void
    ) {
        self.retry = retry
        self.details = details
        self.undo = undo
        self.recovery = recovery
        self.done = done
    }

    var availableKinds: Set<TaskOutcomeActionKind> {
        var result: Set<TaskOutcomeActionKind> = [.done]
        if retry != nil {
            result.formUnion([.retryFailed, .retryRemaining])
        }
        if details != nil { result.insert(.details) }
        if undo != nil { result.insert(.undoChanged) }
        if recovery != nil { result.insert(.recovery) }
        return result
    }
}

struct TaskOutcomeCountSummary: Equatable, Sendable {
    let requested: Int
    let succeeded: Int
    let unchanged: Int
    let skipped: Int
    let failed: Int
    let cancelled: Int

    init(_ counts: OperationCounts) {
        requested = counts.requested
        succeeded = counts.succeeded
        unchanged = counts.unchanged
        skipped = counts.skipped
        failed = counts.failed
        cancelled = counts.cancelled
    }
}

enum TaskOutcomeSemanticRole: Equatable, Sendable {
    case success
    case neutral
    case warning
    case error
    case cancelled
    case irreversible
}

enum TaskOutcomeActionKind: Hashable, Sendable {
    case retryFailed
    case retryRemaining
    case details
    case undoChanged
    case recovery
    case done
}

struct TaskOutcomePresentation: Equatable, Sendable {
    let systemImage: String
    let semanticRole: TaskOutcomeSemanticRole
    let titleKey: String
    let detailKey: String
    let countSummary: TaskOutcomeCountSummary
    let actionOrder: [TaskOutcomeActionKind]
    let accessibilityLabel: String
    let announcement: String
    let allowsCelebration: Bool
    let allowsSuccessSoundHaptic: Bool
    let note: String?
    let affectedBytes: Int64?

    private let retryableSubjectCount: Int

    var countSummaryText: String {
        Self.countSummaryText(for: countSummary)
    }

    func actionTitle(for action: TaskOutcomeActionKind) -> String {
        switch action {
        case .retryFailed:
            return xLocF("重试 %d 个失败项目", retryableSubjectCount)
        case .retryRemaining:
            return xLocF("继续处理 %d 个剩余项目", retryableSubjectCount)
        case .details:
            return xLoc("查看详情")
        case .undoChanged:
            // The reducer has aggregate success counts, not a trusted count of
            // restorable receipts. Never turn that aggregate into an undo claim.
            return xLoc("撤销已更改项目")
        case .recovery:
            return xLoc("按建议恢复")
        case .done:
            return xLoc("完成")
        }
    }

    /// Removes domain-recommended actions that the concrete consumer did not
    /// supply. This keeps the visible buttons, announced next action and
    /// keyboard focus on the same executable route.
    func resolvingAvailableActions(
        _ availableKinds: Set<TaskOutcomeActionKind>
    ) -> TaskOutcomePresentation {
        let resolvedOrder = actionOrder.filter(availableKinds.contains)
        // `TaskOutcomeActions.done` is non-optional, so the normal path always
        // retains `.done`. Keep a fail-closed dismissal fallback for direct
        // internal construction with an invalid empty availability set.
        let safeOrder = resolvedOrder.isEmpty ? [.done] : resolvedOrder
        let nextAction = safeOrder.first ?? .done

        return TaskOutcomePresentation(
            systemImage: systemImage,
            semanticRole: semanticRole,
            titleKey: titleKey,
            detailKey: detailKey,
            countSummary: countSummary,
            actionOrder: safeOrder,
            accessibilityLabel: accessibilityLabel,
            announcement: Self.announcement(
                titleKey: titleKey,
                counts: countSummary,
                nextAction: nextAction,
                retryableSubjectCount: retryableSubjectCount),
            allowsCelebration: allowsCelebration,
            allowsSuccessSoundHaptic: allowsSuccessSoundHaptic,
            note: note,
            affectedBytes: affectedBytes,
            retryableSubjectCount: retryableSubjectCount)
    }

    static func make(context: TaskOutcomeContext) -> TaskOutcomePresentation {
        let operation = context.operation
        let counts = TaskOutcomeCountSummary(operation.counts)
        let registeredSemantics = OutcomeOperationRegistry.semantics(for: operation.kind)
        let hasInvariant = operation.issues.contains { $0.category == .internalInvariant }
        let failClosed = registeredSemantics == nil
            || hasInvariant
            || operation.mutation == .possiblyChanged
        let irreversible = !failClosed
            && operation.status == .success
            && operation.mutation == .changed
            && Self.irreversibleKinds.contains(operation.kind)

        let effectDecision = OutcomeSideEffectPolicy.evaluate(operation)
        let allowsCelebration = !failClosed
            && !irreversible
            && effectDecision.celebration == .allowed

        let visual = Self.visualState(
            operation: operation,
            failClosed: failClosed,
            irreversible: irreversible,
            allowsCelebration: allowsCelebration)
        let retryableSubjectCount = Self.retryableCount(
            context.retryableSubjectCount,
            for: operation.status,
            counts: counts)
        let actions = Self.actionOrder(
            context: context,
            retryableSubjectCount: retryableSubjectCount,
            failClosed: failClosed,
            irreversible: irreversible)
        let nextAction = actions.first ?? .done
        let localizedTitle = xLoc(visual.titleKey)
        let summaryText = Self.countSummaryText(for: counts)
        let announcement = Self.announcement(
            titleKey: visual.titleKey,
            counts: counts,
            nextAction: nextAction,
            retryableSubjectCount: retryableSubjectCount)
        let detail = xLoc(context.primaryDetailKey)
        let accessibilityParts = [
            localizedTitle,
            summaryText,
            detail,
            context.note,
        ].compactMap { value -> String? in
            guard let value else { return nil }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }

        return TaskOutcomePresentation(
            systemImage: visual.systemImage,
            semanticRole: visual.role,
            titleKey: visual.titleKey,
            detailKey: context.primaryDetailKey,
            countSummary: counts,
            actionOrder: actions,
            accessibilityLabel: accessibilityParts.joined(separator: "，"),
            announcement: announcement,
            allowsCelebration: allowsCelebration,
            allowsSuccessSoundHaptic: allowsCelebration,
            note: context.note,
            affectedBytes: context.affectedBytes.map { max(0, $0) },
            retryableSubjectCount: retryableSubjectCount)
    }

    private struct VisualState {
        let systemImage: String
        let role: TaskOutcomeSemanticRole
        let titleKey: String
    }

    private static let irreversibleKinds: Set<OperationKind> = [
        .snapshotDelete,
        .shred,
        .sftpDelete,
        .hostDelete,
        .tunnelDelete,
    ]

    private static func visualState(
        operation: OperationOutcome,
        failClosed: Bool,
        irreversible: Bool,
        allowsCelebration: Bool
    ) -> VisualState {
        if failClosed {
            return VisualState(
                systemImage: "questionmark.diamond.fill",
                role: .warning,
                titleKey: "结果需要确认")
        }

        switch operation.status {
        case .success:
            if operation.mutation == .none {
                return VisualState(
                    systemImage: "checkmark.circle",
                    role: .neutral,
                    titleKey: "目标已经满足")
            }
            if irreversible {
                return VisualState(
                    systemImage: "checkmark.shield.fill",
                    role: .irreversible,
                    titleKey: "不可逆操作已完成")
            }
            if allowsCelebration {
                return VisualState(
                    systemImage: "checkmark.circle.fill",
                    role: .success,
                    titleKey: "操作已完成")
            }
            return VisualState(
                systemImage: "info.circle.fill",
                role: .neutral,
                titleKey: "操作已完成")
        case .partial:
            return VisualState(
                systemImage: "exclamationmark.circle.fill",
                role: .warning,
                titleKey: "部分完成")
        case .failure:
            return VisualState(
                systemImage: "xmark.octagon.fill",
                role: .error,
                titleKey: "操作失败")
        case .cancelled:
            return VisualState(
                systemImage: "stop.circle.fill",
                role: .cancelled,
                titleKey: "操作已取消")
        }
    }

    private static func actionOrder(
        context: TaskOutcomeContext,
        retryableSubjectCount: Int,
        failClosed: Bool,
        irreversible: Bool
    ) -> [TaskOutcomeActionKind] {
        let operation = context.operation
        let hasRetry = retryableSubjectCount > 0
        // The payload capability is backed by concrete restorable receipts.
        // An unrelated item's ambiguous mutation must not hide those confirmed
        // receipts merely because the aggregate becomes `.possiblyChanged`.
        // Retry generations may carry a Domain-verified receipt owned by an earlier changed
        // operation even when the current retry is unchanged or rejected before mutation.
        // The consumer capability is therefore authoritative; current-generation mutation alone
        // cannot erase a still-valid undo action.
        let canUndo = context.canUndoChangedItems
        let hasRecovery = operation.issues.contains { issue in
            issue.recovery != .none && issue.recovery != .retry
        }

        switch operation.status {
        case .success:
            if irreversible || operation.mutation == .none {
                return [.done]
            }
            if failClosed {
                return canUndo ? [.details, .undoChanged, .done] : [.details, .done]
            }
            return canUndo ? [.undoChanged, .done] : [.done]
        case .partial:
            var actions: [TaskOutcomeActionKind] = []
            if hasRetry { actions.append(.retryFailed) }
            actions.append(.details)
            if canUndo { actions.append(.undoChanged) }
            actions.append(.done)
            return actions
        case .failure:
            var actions: [TaskOutcomeActionKind] = []
            if hasRetry { actions.append(.retryFailed) }
            if hasRecovery { actions.append(.recovery) }
            actions.append(.details)
            actions.append(.done)
            return actions
        case .cancelled:
            var actions: [TaskOutcomeActionKind] = []
            if hasRetry { actions.append(.retryRemaining) }
            actions.append(.details)
            if canUndo { actions.append(.undoChanged) }
            actions.append(.done)
            return actions
        }
    }

    private static func retryableCount(
        _ supplied: Int,
        for status: OperationTerminalStatus,
        counts: TaskOutcomeCountSummary
    ) -> Int {
        let boundedSupply = max(0, supplied)
        switch status {
        case .partial, .failure:
            return min(boundedSupply, Self.saturatingAdd(counts.failed, counts.skipped))
        case .cancelled:
            let incompleteBeforeCancellation = Self.saturatingAdd(
                counts.failed,
                counts.skipped)
            return min(
                boundedSupply,
                Self.saturatingAdd(incompleteBeforeCancellation, counts.cancelled))
        case .success:
            return 0
        }
    }

    private static func countSummaryText(for counts: TaskOutcomeCountSummary) -> String {
        [
            xLocF("请求 %d 项", counts.requested),
            xLocF("完成 %d 项", counts.succeeded),
            xLocF("无需更改 %d 项", counts.unchanged),
            xLocF("跳过 %d 项", counts.skipped),
            xLocF("失败 %d 项", counts.failed),
            xLocF("取消 %d 项", counts.cancelled),
        ].joined(separator: " · ")
    }

    private static func actionTitle(
        for action: TaskOutcomeActionKind,
        retryableSubjectCount: Int
    ) -> String {
        switch action {
        case .retryFailed:
            return xLocF("重试 %d 个失败项目", retryableSubjectCount)
        case .retryRemaining:
            return xLocF("继续处理 %d 个剩余项目", retryableSubjectCount)
        case .details:
            return xLoc("查看详情")
        case .undoChanged:
            return xLoc("撤销已更改项目")
        case .recovery:
            return xLoc("按建议恢复")
        case .done:
            return xLoc("完成")
        }
    }

    private static func announcement(
        titleKey: String,
        counts: TaskOutcomeCountSummary,
        nextAction: TaskOutcomeActionKind,
        retryableSubjectCount: Int
    ) -> String {
        xLocF(
            "%@。%@。下一步：%@",
            xLoc(titleKey),
            countSummaryText(for: counts),
            actionTitle(
                for: nextAction,
                retryableSubjectCount: retryableSubjectCount))
    }

    private static func saturatingAdd(_ lhs: Int, _ rhs: Int) -> Int {
        let (value, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? Int.max : value
    }
}

/// Per-operation motion preference state is monotonic: enabling Reduce Motion
/// suppresses presentation motion immediately and permanently for an already
/// shown result, while disabling it never causes a late replay.
struct OutcomeMotionSessionState: Equatable, Sendable {
    private(set) var hasSuppressedMotion: Bool

    init(initialReduceMotion: Bool) {
        hasSuppressedMotion = initialReduceMotion
    }

    func shouldSuppress(currentReduceMotion: Bool) -> Bool {
        hasSuppressedMotion || currentReduceMotion
    }

    mutating func observe(reduceMotion: Bool) {
        hasSuppressedMotion = hasSuppressedMotion || reduceMotion
    }
}

struct OutcomeMotionPlan: Equatable, Sendable {
    let constructsBurst: Bool
    let createsDelayedRevealTask: Bool
    let createsCountUpTask: Bool
    let initialNumericValue: Int64
    let finalNumericValue: Int64
    let actionOrder: [TaskOutcomeActionKind]
    let initialFocus: TaskOutcomeActionKind?

    /// Converts animation progress without ever feeding an out-of-range
    /// floating-point value to `Int64.init`. `Double(Int64.max)` rounds to
    /// 2^63, so the seemingly simple conversion can otherwise trap at the
    /// final frame for a legitimate saturated byte count.
    func interpolatedNumericValue(at progress: Double) -> Int64 {
        if progress.isNaN { return 0 }
        if progress <= 0 { return 0 }
        if progress >= 1 || progress == .infinity { return finalNumericValue }

        let raw = Double(finalNumericValue) * progress
        guard raw.isFinite, raw < Double(Int64.max) else {
            return finalNumericValue
        }
        return Int64(max(0, raw))
    }

    static func make(
        context: TaskOutcomeContext,
        presentation: TaskOutcomePresentation,
        visualEffectGranted: Bool,
        reduceMotion: Bool
    ) -> OutcomeMotionPlan {
        let finalValue = context.affectedBytes.map { max(0, $0) }
            ?? Int64(clamping: context.operation.counts.succeeded)
        let constructsEffect = visualEffectGranted
            && presentation.allowsCelebration
            && !reduceMotion
        let countsUp = constructsEffect && finalValue > 0
        // VoiceOver announces the first action as the next step, so keyboard
        // focus must land on that same highest-priority action.
        let focus = presentation.actionOrder.first

        return OutcomeMotionPlan(
            constructsBurst: constructsEffect,
            createsDelayedRevealTask: constructsEffect,
            createsCountUpTask: countsUp,
            initialNumericValue: countsUp ? 0 : finalValue,
            finalNumericValue: finalValue,
            actionOrder: presentation.actionOrder,
            initialFocus: focus)
    }
}
