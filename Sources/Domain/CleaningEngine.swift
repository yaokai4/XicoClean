import Foundation
import os

/// 清理引擎：执行清理计划。
/// 默认所有删除走废纸篓（可恢复）；每一项删除前都经过 SafetyEngine 校验。
public actor CleaningEngine {
    private static let log = Logger(subsystem: "com.xico.app", category: "clean")

    private struct CleaningRequest: Sendable {
        let requestID: UUID
        let item: CleanableItem
    }

    private let safety: SafetyEngine
    private let fs: FileSystemService
    private let privileged: PrivilegedCleaningService?
    private var activeNormalizedPaths: Set<String> = []

    public init(safety: SafetyEngine,
                fs: FileSystemService,
                privileged: PrivilegedCleaningService? = nil) {
        self.safety = safety
        self.fs = fs
        self.privileged = privileged
    }

    public func execute(
        _ plan: CleaningPlan,
        purpose: CleaningOperationPurpose = .standard,
        progress: @escaping ProgressHandler = { _ in }
    ) async -> CleaningReport {
        let startedAt = Date()
        let operationKind = purpose.operationKind
        guard !plan.items.isEmpty else {
            let operation = OperationOutcomeReducer.internalFailure(
                kind: operationKind,
                requestedSubjectIDs: [],
                code: "cleaning.request.empty",
                startedAt: startedAt,
                finishedAt: Date())
            return CleaningReport(operation: operation, items: [])
        }

        let requests = Self.makeRequests(for: plan.items)
        let duplicateRequestIDs = Self.duplicateRequestIDs(in: requests)
        var inFlightRequestIDs: Set<UUID> = []
        var reservedPaths: Set<String> = []
        for request in requests {
            if duplicateRequestIDs.contains(request.requestID) { continue }
            let path = request.item.url.standardizedFileURL.path
            if activeNormalizedPaths.contains(path) {
                inFlightRequestIDs.insert(request.requestID)
            } else {
                reservedPaths.insert(path)
            }
        }
        activeNormalizedPaths.formUnion(reservedPaths)
        defer { activeNormalizedPaths.subtract(reservedPaths) }

        var results: [CleaningItemResult] = []
        results.reserveCapacity(requests.count)
        var cancellationAccepted = false
        var reclaimedForProgress: Int64 = 0

        for (index, request) in requests.enumerated() {
            if cancellationAccepted || Task.isCancelled {
                cancellationAccepted = true
                results.append(Self.result(for: request,
                                           intent: plan.intent,
                                           disposition: .cancelled(nil),
                                           mutation: .none))
                continue
            }

            let result: CleaningItemResult
            let suppressProgress: Bool
            if duplicateRequestIDs.contains(request.requestID) {
                let issue = Self.issue(
                    code: "cleaning.request.duplicateTarget",
                    category: .internalInvariant,
                    requestID: request.requestID,
                    recovery: .chooseAnotherTarget,
                    retryable: false)
                result = Self.result(for: request,
                                     intent: plan.intent,
                                     disposition: .failed(issue),
                                     mutation: .none)
                suppressProgress = true
            } else if inFlightRequestIDs.contains(request.requestID) {
                let issue = Self.issue(
                    code: "cleaning.request.inFlight",
                    category: .internalInvariant,
                    requestID: request.requestID,
                    recovery: .retry,
                    retryable: true)
                result = Self.result(for: request,
                                     intent: plan.intent,
                                     disposition: .failed(issue),
                                     mutation: .none)
                suppressProgress = true
            } else {
                result = await executeItem(request, intent: plan.intent)
                suppressProgress = false
            }
            results.append(result)
            if Task.isCancelled { cancellationAccepted = true }

            if result.disposition == .succeeded {
                reclaimedForProgress = saturatedNonnegativeSum(
                    reclaimedForProgress,
                    result.reclaimedBytes)
            }
            if !suppressProgress {
                progress(ScanProgress(
                    fraction: Double(index + 1) / Double(requests.count),
                    message: request.item.displayName,
                    bytesFound: reclaimedForProgress))
                if Task.isCancelled { cancellationAccepted = true }
            }
        }

        let operationItems = results.map {
            OperationItemOutcome(subjectID: $0.requestID.uuidString,
                                 disposition: $0.disposition,
                                 mutation: $0.mutation,
                                 affectedBytes: $0.reclaimedBytes)
        }
        let requestIDs = requests.map { $0.requestID.uuidString }
        let finishedAt = Date()
        if Task.isCancelled { cancellationAccepted = true }
        let operation: OperationOutcome
        do {
            operation = try OperationOutcomeReducer.reduce(
                kind: operationKind,
                requestedSubjectIDs: requestIDs,
                itemOutcomes: operationItems,
                cancellationAccepted: cancellationAccepted,
                startedAt: startedAt,
                finishedAt: finishedAt)
        } catch {
            operation = OperationOutcomeReducer.internalFailure(
                kind: operationKind,
                requestedSubjectIDs: requestIDs,
                itemOutcomes: operationItems,
                cancellationAccepted: cancellationAccepted,
                code: "cleaning.reducer.invariant",
                startedAt: startedAt,
                finishedAt: finishedAt)
        }
        return CleaningReport(operation: operation, items: results)
    }

    private func executeItem(
        _ request: CleaningRequest,
        intent: DeleteIntent
    ) async -> CleaningItemResult {
        let item = request.item

        // 仅提示项只提供官方处置指引，任何清理计划都不能把它变成删除请求。
        if item.isInformational {
            let issue = Self.issue(
                code: "cleaning.item.informational",
                category: .safetyPolicy,
                requestID: request.requestID,
                recovery: .manualAction,
                retryable: false)
            return Self.result(for: request,
                               intent: intent,
                               disposition: .skipped(issue),
                               mutation: .none)
        }

        // 废纸篓内叶子软链的永久删除只删除链接本身，不解析或跟随目标。
        if intent == .permanent, Self.isInsideTrash(item.url), Self.isSymlink(item.url) {
            do {
                try fs.remove(item.url)
                return Self.result(for: request,
                                   intent: intent,
                                   disposition: .succeeded,
                                   mutation: .changed,
                                   reclaimedBytes: item.estimatedReclaimableBytes)
            } catch {
                Self.log.error("cleaning.filesystem.operationFailed count=1")
                let issue = Self.issue(
                    code: "cleaning.filesystem.operationFailed",
                    category: .io,
                    requestID: request.requestID,
                    recovery: .retry,
                    retryable: true)
                return Self.result(for: request,
                                   intent: intent,
                                   disposition: .failed(issue),
                                   mutation: .possiblyChanged)
            }
        }

        guard safety.verify(item.url, intent: intent).isAllowed else {
            let issue = Self.issue(
                code: "cleaning.safety.denied",
                category: .safetyPolicy,
                requestID: request.requestID,
                recovery: .chooseAnotherTarget,
                retryable: false)
            return Self.result(for: request,
                               intent: intent,
                               disposition: .skipped(issue),
                               mutation: .none)
        }

        guard fs.exists(item.url) else {
            return Self.result(for: request,
                               intent: intent,
                               disposition: .unchanged,
                               mutation: .none)
        }

        if item.requiresHelper {
            return await executePrivilegedItem(request, intent: intent)
        }

        let resolved = item.url.resolvingSymlinksInPath()
        guard safety.verify(item.url, intent: intent).isAllowed,
              safety.verify(resolved, intent: intent).isAllowed else {
            Self.log.error("cleaning.safety.identityChanged count=1")
            let issue = Self.issue(
                code: "cleaning.safety.identityChanged",
                category: .identityChanged,
                requestID: request.requestID,
                recovery: .retry,
                retryable: true)
            return Self.result(for: request,
                               intent: intent,
                               disposition: .failed(issue),
                               mutation: .none)
        }

        if intent == .permanent, Self.isSymlink(item.url) {
            Self.log.error("cleaning.safety.identityChanged count=1")
            let issue = Self.issue(
                code: "cleaning.safety.identityChanged",
                category: .identityChanged,
                requestID: request.requestID,
                recovery: .retry,
                retryable: true)
            return Self.result(for: request,
                               intent: intent,
                               disposition: .failed(issue),
                               mutation: .none)
        }

        do {
            switch intent {
            case .trash:
                let trashedURL = try fs.trash(item.url)
                let receipt = RestorableItem(originalURL: item.url, trashedURL: trashedURL)
                return Self.result(for: request,
                                   intent: intent,
                                   disposition: .succeeded,
                                   mutation: .changed,
                                   reclaimedBytes: item.estimatedReclaimableBytes,
                                   restorable: receipt)
            case .permanent:
                try fs.remove(item.url)
                return Self.result(for: request,
                                   intent: intent,
                                   disposition: .succeeded,
                                   mutation: .changed,
                                   reclaimedBytes: item.estimatedReclaimableBytes)
            }
        } catch {
            Self.log.error("cleaning.filesystem.operationFailed count=1")
            let issue = Self.issue(
                code: "cleaning.filesystem.operationFailed",
                category: .io,
                requestID: request.requestID,
                recovery: .retry,
                retryable: true)
            return Self.result(for: request,
                               intent: intent,
                               disposition: .failed(issue),
                               mutation: .possiblyChanged)
        }
    }

    private func executePrivilegedItem(
        _ request: CleaningRequest,
        intent: DeleteIntent
    ) async -> CleaningItemResult {
        guard let privileged else {
            let issue = Self.issue(
                code: "cleaning.helper.unavailable",
                category: .unavailable,
                requestID: request.requestID,
                recovery: .installHelper,
                retryable: true)
            return Self.result(for: request,
                               intent: intent,
                               disposition: .failed(issue),
                               mutation: .none)
        }
        guard intent == .permanent else {
            let issue = Self.issue(
                code: "cleaning.helper.intentMismatch",
                category: .validation,
                requestID: request.requestID,
                recovery: .chooseAnotherTarget,
                retryable: false)
            return Self.result(for: request,
                               intent: intent,
                               disposition: .failed(issue),
                               mutation: .none)
        }

        let report = await privileged.removeProtected([request.item.url])
        let requestedPath = request.item.url.standardizedFileURL.path
        let failedPaths = report.failures.map { $0.standardizedFileURL.path }

        if failedPaths.contains(where: { $0 != requestedPath }) {
            Self.log.error("cleaning.helper.unexpectedFailurePath count=1")
            let issue = Self.issue(
                code: "cleaning.helper.unexpectedFailurePath",
                category: .internalInvariant,
                requestID: request.requestID,
                recovery: .retry,
                retryable: true)
            return Self.result(for: request,
                               intent: intent,
                               disposition: .failed(issue),
                               mutation: .possiblyChanged)
        }
        if failedPaths.contains(requestedPath) {
            Self.log.error("cleaning.helper.removalFailed count=1")
            let issue = Self.issue(
                code: "cleaning.helper.removalFailed",
                category: .io,
                requestID: request.requestID,
                recovery: .retry,
                retryable: true)
            return Self.result(for: request,
                               intent: intent,
                               disposition: .failed(issue),
                               mutation: .possiblyChanged)
        }
        if fs.exists(request.item.url) {
            Self.log.error("cleaning.helper.targetStillExists count=1")
            let issue = Self.issue(
                code: "cleaning.helper.targetStillExists",
                category: .io,
                requestID: request.requestID,
                recovery: .retry,
                retryable: true)
            return Self.result(for: request,
                               intent: intent,
                               disposition: .failed(issue),
                               mutation: .possiblyChanged)
        }

        return Self.result(for: request,
                           intent: intent,
                           disposition: .succeeded,
                           mutation: .changed,
                           reclaimedBytes: report.freedBytes)
    }

    /// 撤销上一次清理：把 sandbox/废纸篓收据中的项移回原位，并保留所有失败收据。
    public func undo(_ report: CleaningReport) async -> UndoResult {
        var restored = 0
        var failed: [RestorableItem] = []
        for item in report.restorable {
            do {
                try fs.restore(item)
                restored += 1
            } catch {
                Self.log.error("cleaning.undo.restoreFailed count=1")
                failed.append(item)
            }
        }
        return UndoResult(restored: restored, failed: failed)
    }

    private static func makeRequests(for items: [CleanableItem]) -> [CleaningRequest] {
        var generated = Set<UUID>()
        return items.map { item in
            var requestID = UUID()
            while !generated.insert(requestID).inserted {
                requestID = UUID()
            }
            return CleaningRequest(requestID: requestID, item: item)
        }
    }

    private static func duplicateRequestIDs(
        in requests: [CleaningRequest]
    ) -> Set<UUID> {
        let ids = Dictionary(grouping: requests, by: { $0.item.id })
        let paths = Dictionary(grouping: requests, by: { $0.item.url.standardizedFileURL.path })
        let duplicateItemIDs = Set(ids.compactMap { $0.value.count > 1 ? $0.key : nil })
        let duplicatePaths = Set(paths.compactMap { $0.value.count > 1 ? $0.key : nil })
        return Set(requests.compactMap { request in
            duplicateItemIDs.contains(request.item.id)
                || duplicatePaths.contains(request.item.url.standardizedFileURL.path)
                ? request.requestID
                : nil
        })
    }

    private static func result(
        for request: CleaningRequest,
        intent: DeleteIntent,
        disposition: OperationDisposition,
        mutation: OperationMutationFact,
        reclaimedBytes: Int64 = 0,
        restorable: RestorableItem? = nil
    ) -> CleaningItemResult {
        let validatedReceipt = intent == .trash && disposition == .succeeded
            ? restorable
            : nil
        return CleaningItemResult(requestID: request.requestID,
                                  itemID: request.item.id,
                                  url: request.item.url,
                                  intent: intent,
                                  disposition: disposition,
                                  mutation: mutation,
                                  reclaimedBytes: reclaimedBytes,
                                  restorable: validatedReceipt)
    }

    private static func issue(
        code: String,
        category: OperationIssueCategory,
        requestID: UUID,
        recovery: OperationRecoveryHint,
        retryable: Bool
    ) -> OperationIssue {
        OperationIssue(code: code,
                       category: category,
                       subjectID: requestID.uuidString,
                       recovery: recovery,
                       retryable: retryable)
    }

    /// 叶子自身是否为符号链接（lstat 语义，不跟随）。
    private static func isSymlink(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink ?? false
    }

    /// 路径字面量是否锚定于真实废纸篓根内；刻意不解析符号链接。
    private static func isInsideTrash(_ url: URL) -> Bool {
        let comps = url.standardizedFileURL.pathComponents.map { $0.lowercased() }
        let home = FileManager.default.homeDirectoryForCurrentUser
            .standardizedFileURL.pathComponents.map { $0.lowercased() }
        if comps.count > home.count,
           Array(comps.prefix(home.count)) == home,
           comps[home.count] == ".trash" {
            return true
        }
        if let trashIndex = comps.firstIndex(of: ".trashes") {
            let validAnchor = trashIndex == 1
                || (trashIndex == 3 && comps.count > 1 && comps[1] == "volumes")
            if validAnchor && comps.count > trashIndex + 1 { return true }
        }
        return false
    }
}
