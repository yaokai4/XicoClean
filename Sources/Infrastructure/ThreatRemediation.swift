import Darwin
import Foundation
import Domain

enum LaunchAgentLabelReadResult: Equatable, Sendable {
    case label(String), missing, invalid, unreadable
}

protocol LaunchAgentLabelReading: Sendable {
    func readLabel(from data: Data) -> LaunchAgentLabelReadResult
}

enum LaunchAgentBootoutResult: Equatable, Sendable {
    case invoked
    case notInvoked
    case timedOut
    case cancelled(processStarted: Bool)
}

protocol LaunchAgentControlling: Sendable {
    func bootout(label: String, uid: uid_t) async -> LaunchAgentBootoutResult
}

enum LaunchAgentLoadState: Equatable, Sendable {
    case loaded, notLoaded, unknown
}

protocol LaunchAgentPostconditionChecking: Sendable {
    func loadState(label: String, uid: uid_t) async -> LaunchAgentLoadState
}

/// Reducer-backed bootout of suspicious user LaunchAgents. System access stays behind typed
/// dependencies; construction itself performs no filesystem or launchctl work.
struct ThreatRemediation: ThreatRemediationExecuting, Sendable {
    private static let maximumPlistBytes = 1_048_576
    private static let defaultRetryAuthorizationLifetimeNanoseconds: UInt64 =
        300_000_000_000
    private static let defaultRetryAuthorizationCapacity = 1_024

    private let root: URL
    private let uid: uid_t
    private let labelReader: any LaunchAgentLabelReading
    private let controller: any LaunchAgentControlling
    private let postcondition: any LaunchAgentPostconditionChecking
    private let retryAuthorizations: ThreatRemediationRetryAuthorizationStore

    init() {
        self.init(
            root: FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/LaunchAgents", isDirectory: true),
            uid: getuid(),
            labelReader: PropertyListLaunchAgentLabelReader(),
            controller: SystemLaunchAgentController(),
            postcondition: SystemLaunchAgentPostcondition())
    }

    init(
        root: URL,
        uid: uid_t,
        labelReader: any LaunchAgentLabelReading,
        controller: any LaunchAgentControlling,
        postcondition: any LaunchAgentPostconditionChecking,
        retryAuthorizationLifetimeNanoseconds: UInt64 =
            Self.defaultRetryAuthorizationLifetimeNanoseconds,
        retryAuthorizationCapacity: Int = Self.defaultRetryAuthorizationCapacity,
        monotonicNow: @escaping @Sendable () -> UInt64 = {
            DispatchTime.now().uptimeNanoseconds
        }
    ) {
        self.root = root.standardizedFileURL
        self.uid = uid
        self.labelReader = labelReader
        self.controller = controller
        self.postcondition = postcondition
        self.retryAuthorizations = ThreatRemediationRetryAuthorizationStore(
            lifetimeNanoseconds: retryAuthorizationLifetimeNanoseconds,
            capacity: retryAuthorizationCapacity,
            monotonicNow: monotonicNow)
    }

    func remediate(
        _ requests: [ThreatRemediationRequest],
        operationID: UUID,
        parentID: UUID
    ) async -> OperationResult<ThreatRemediationReport> {
        let startedAt = Date()
        if requests.count > CleaningOperationLimits.maximumFactCount {
            let outcome = OperationOutcomeReducer.admissionFailure(
                id: operationID,
                parentID: parentID,
                kind: .threatRemediation,
                requestedCount: requests.count,
                code: "threat.remediation.request.tooMany",
                recovery: .manualAction,
                startedAt: startedAt,
                finishedAt: Date())
            return OperationResult(
                outcome: outcome,
                payload: ThreatRemediationReport(items: []))
        }
        guard !requests.isEmpty,
              Set(requests.map(\.requestID)).count == requests.count,
              Set(requests.map(\.relatedCleaningRequestID)).count == requests.count,
              Set(requests.map { $0.url.standardizedFileURL.path }).count == requests.count else {
            let items = requests.map {
                Self.failed($0, code: "threat.remediation.request.invalid",
                            category: .internalInvariant)
            }
            return Self.result(
                requests: requests, items: items, id: operationID, parentID: parentID,
                cancellationAccepted: false, startedAt: startedAt,
                forcedInternalCode: "threat.remediation.request.invalid")
        }

        var items: [ThreatRemediationItemResult] = []
        items.reserveCapacity(requests.count)
        let authorizationBatchID = UUID()
        var cancelling = false
        for request in requests {
            if cancelling || Task.isCancelled {
                cancelling = true
                items.append(Self.item(request, .cancelled(nil), .none))
            } else {
                let completed = await remediateOne(
                    request,
                    authorizationBatchID: authorizationBatchID)
                items.append(completed)
                if case .cancelled = completed.disposition { cancelling = true }
            }
        }
        await retryAuthorizations.completeBatch(
            authorizationBatchID,
            rootPath: root.path,
            currentRootIdentity: SecureLaunchAgentReader.currentRootIdentity(at: root))
        return Self.result(
            requests: requests, items: items, id: operationID, parentID: parentID,
            cancellationAccepted: cancelling, startedAt: startedAt)
    }

    /// Shared with OptimizationService: exact ASCII `[A-Za-z0-9._-]`, 1...512 bytes.
    static func isValidLaunchdLabel(_ label: String) -> Bool {
        !label.isEmpty && label.utf8.count <= 512 && label.utf8.allSatisfy {
            (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0)
                || $0 == 46 || $0 == 95 || $0 == 45
        }
    }

    private func remediateOne(
        _ request: ThreatRemediationRequest,
        authorizationBatchID: UUID
    ) async -> ThreatRemediationItemResult {
        let binding: ValidatedLaunchAgentBinding
        if let retryToken = request.retryToken {
            guard let relativeIdentity = SecureLaunchAgentReader.relativeIdentity(
                      candidate: request.url,
                      root: root),
                  relativeIdentity == retryToken.rootRelativeIdentity else {
                return Self.failedNonretryable(
                    request,
                    code: "threat.remediation.retryToken.invalid",
                    category: .validation,
                    retryToken: retryToken)
            }
            let targetState = SecureLaunchAgentReader.validateRetryTargetAbsent(
                candidate: request.url,
                root: root)
            let rootIdentity: LaunchAgentsRootIdentity
            switch targetState {
            case let .absent(identity), let .present(identity):
                rootIdentity = identity
            case .invalid:
                return Self.failedNonretryable(
                    request,
                    code: "threat.remediation.retryToken.invalid",
                    category: .validation,
                    retryToken: retryToken)
            }
            let lease: ThreatRemediationRetryAuthorizationLease
            switch await retryAuthorizations.claim(
                token: retryToken,
                rootPath: root.path,
                rootIdentity: rootIdentity,
                batchID: authorizationBatchID)
            {
            case let .claimed(value):
                lease = value
            case .invalid:
                return Self.failedNonretryable(
                    request,
                    code: "threat.remediation.retryToken.invalid",
                    category: .validation,
                    retryToken: retryToken)
            case .inUse:
                return Self.failedNonretryable(
                    request,
                    code: "threat.remediation.retryToken.inUse",
                    category: .unavailable,
                    retryToken: retryToken)
            }
            // The actor hop above can give another process time to replace the path/root. Repeat
            // the descriptor-relative absence check immediately before using the bound label.
            let finalTargetState = SecureLaunchAgentReader.validateRetryTargetAbsent(
                candidate: request.url,
                root: root)
            switch finalTargetState {
            case let .absent(finalIdentity) where finalIdentity == rootIdentity:
                break
            case let .present(finalIdentity) where finalIdentity == rootIdentity:
                await retryAuthorizations.finish(lease, retryable: false)
                return Self.failedNonretryable(
                    request,
                    code: "threat.remediation.retryToken.staleTarget",
                    category: .validation,
                    retryToken: retryToken)
            case .absent, .present, .invalid:
                await retryAuthorizations.finish(lease, retryable: false)
                return Self.failedNonretryable(
                    request,
                    code: "threat.remediation.retryToken.invalid",
                    category: .validation,
                    retryToken: retryToken)
            }
            binding = ValidatedLaunchAgentBinding(
                label: retryToken.validatedLabel,
                token: retryToken,
                authorizationLease: lease)
        } else {
            let secured: SecureLaunchAgentTarget
            switch SecureLaunchAgentReader.read(
                candidate: request.url,
                root: root,
                maximumBytes: Self.maximumPlistBytes) {
            case let .target(target):
                secured = target
            case .ineligible:
                return Self.skipped(
                    request,
                    code: "threat.remediation.target.ineligible",
                    category: .safetyPolicy)
            case .tooLarge:
                return Self.failedNonretryable(
                    request,
                    code: "threat.remediation.target.tooLarge",
                    category: .validation)
            case .unreadable:
                return Self.failedNonretryable(
                    request,
                    code: "threat.remediation.label.unreadable",
                    category: .io)
            }

            let label: String
            switch labelReader.readLabel(from: secured.data) {
            case let .label(value):
                label = value
            case .missing:
                return Self.skipped(
                    request,
                    code: "threat.remediation.label.missing",
                    category: .validation)
            case .invalid:
                return Self.skipped(
                    request,
                    code: "threat.remediation.label.invalid",
                    category: .validation)
            case .unreadable:
                return Self.failedNonretryable(
                    request,
                    code: "threat.remediation.label.unreadable",
                    category: .io)
            }
            guard Self.isValidLaunchdLabel(label),
                  secured.rootIdentity.matchesCurrentPath(root),
                  let token = ThreatRemediationRetryToken(
                      validatedLabel: label,
                      rootRelativeIdentity: secured.relativeIdentity) else {
                return Self.skipped(
                    request,
                    code: Self.isValidLaunchdLabel(label)
                        ? "threat.remediation.target.ineligible"
                        : "threat.remediation.label.invalid",
                    category: Self.isValidLaunchdLabel(label)
                        ? .safetyPolicy
                        : .validation)
            }
            let lease: ThreatRemediationRetryAuthorizationLease
            switch await retryAuthorizations.reserve(
                token: token,
                rootPath: root.path,
                rootIdentity: secured.rootIdentity,
                batchID: authorizationBatchID)
            {
            case let .reserved(value):
                lease = value
            case .capacity:
                return Self.failedNonretryable(
                    request,
                    code: "threat.remediation.retryToken.capacity",
                    category: .unavailable)
            case .collision:
                return Self.failedNonretryable(
                    request,
                    code: "threat.remediation.retryToken.collision",
                    category: .validation)
            }
            guard secured.rootIdentity.matchesCurrentPath(root) else {
                await retryAuthorizations.finish(lease, retryable: false)
                return Self.skipped(
                    request,
                    code: "threat.remediation.target.ineligible",
                    category: .safetyPolicy)
            }
            binding = ValidatedLaunchAgentBinding(
                label: label,
                token: token,
                authorizationLease: lease)
        }

        let completed = await remediateValidated(
            request,
            label: binding.label,
            retryToken: binding.token)
        let retryable = Self.isRetryable(completed.disposition)
        await retryAuthorizations.finish(
            binding.authorizationLease,
            retryable: retryable)
        let outputToken = request.retryToken != nil || retryable ? binding.token : nil
        return Self.item(
            request,
            completed.disposition,
            completed.mutation,
            retryToken: outputToken)
    }

    private func remediateValidated(
        _ request: ThreatRemediationRequest,
        label: String,
        retryToken: ThreatRemediationRetryToken
    ) async -> ThreatRemediationItemResult {
        guard !Task.isCancelled else {
            return Self.cancelled(
                request,
                code: "threat.remediation.cancelled",
                mutation: .none,
                retryToken: retryToken)
        }

        let initialState = await postcondition.loadState(label: label, uid: uid)
        if initialState == .notLoaded {
            return Self.item(request, .unchanged, .none, retryToken: retryToken)
        }
        guard !Task.isCancelled else {
            return Self.cancelled(
                request,
                code: "threat.remediation.cancelled",
                mutation: .none,
                retryToken: retryToken)
        }

        switch await controller.bootout(label: label, uid: uid) {
        case .notInvoked:
            return Self.failed(
                request,
                code: "threat.remediation.bootout.notInvoked",
                category: .unavailable,
                retryToken: retryToken)
        case .timedOut:
            return Self.failed(
                request,
                code: "threat.remediation.bootout.timeout",
                category: .unavailable,
                mutation: .possiblyChanged,
                retryToken: retryToken)
        case let .cancelled(processStarted):
            return Self.cancelled(
                request,
                code: "threat.remediation.bootout.cancelled",
                mutation: processStarted ? .possiblyChanged : .none,
                retryToken: retryToken)
        case .invoked:
            break
        }

        // Once launchctl was invoked, always probe the postcondition. If cancellation wins while
        // that probe is running, the mutation remains conservative because launchd may have acted.
        let finalState = await postcondition.loadState(label: label, uid: uid)
        if finalState == .notLoaded {
            return Self.item(request, .succeeded, .changed, retryToken: retryToken)
        }
        if Task.isCancelled {
            return Self.cancelled(
                request,
                code: "threat.remediation.bootout.cancelled",
                mutation: .possiblyChanged,
                retryToken: retryToken)
        }
        return Self.failed(
            request,
            code: "threat.remediation.bootout.notConfirmed",
            category: .io,
            mutation: .possiblyChanged,
            retryToken: retryToken)
    }

    private static func item(
        _ request: ThreatRemediationRequest,
        _ disposition: OperationDisposition,
        _ mutation: OperationMutationFact,
        retryToken: ThreatRemediationRetryToken? = nil
    ) -> ThreatRemediationItemResult {
        ThreatRemediationItemResult(
            requestID: request.requestID,
            relatedCleaningRequestID: request.relatedCleaningRequestID,
            url: request.url,
            disposition: disposition,
            mutation: mutation,
            retryToken: retryToken ?? request.retryToken)
    }

    private static func skipped(
        _ request: ThreatRemediationRequest,
        code: String,
        category: OperationIssueCategory
    ) -> ThreatRemediationItemResult {
        item(request, .skipped(issue(request, code, category, .none, false)), .none)
    }

    private static func failed(
        _ request: ThreatRemediationRequest,
        code: String,
        category: OperationIssueCategory,
        mutation: OperationMutationFact = .none,
        retryToken: ThreatRemediationRetryToken? = nil
    ) -> ThreatRemediationItemResult {
        item(
            request,
            .failed(issue(request, code, category, .retry, true)),
            mutation,
            retryToken: retryToken)
    }

    private static func failedNonretryable(
        _ request: ThreatRemediationRequest,
        code: String,
        category: OperationIssueCategory,
        retryToken: ThreatRemediationRetryToken? = nil
    ) -> ThreatRemediationItemResult {
        item(
            request,
            .failed(issue(request, code, category, .manualAction, false)),
            .none,
            retryToken: retryToken)
    }

    private static func cancelled(
        _ request: ThreatRemediationRequest,
        code: String,
        mutation: OperationMutationFact,
        retryToken: ThreatRemediationRetryToken
    ) -> ThreatRemediationItemResult {
        item(
            request,
            .cancelled(issue(request, code, .unavailable, .retry, true)),
            mutation,
            retryToken: retryToken)
    }

    private static func isRetryable(_ disposition: OperationDisposition) -> Bool {
        switch disposition {
        case .succeeded, .unchanged:
            return false
        case let .skipped(issue), let .failed(issue):
            return issue.retryable
        case let .cancelled(issue):
            return issue?.retryable != false
        }
    }

    private static func issue(
        _ request: ThreatRemediationRequest,
        _ code: String,
        _ category: OperationIssueCategory,
        _ recovery: OperationRecoveryHint,
        _ retryable: Bool
    ) -> OperationIssue {
        OperationIssue(
            code: code, category: category, subjectID: request.requestID.uuidString,
            recovery: recovery, retryable: retryable)
    }

    private static func result(
        requests: [ThreatRemediationRequest],
        items: [ThreatRemediationItemResult],
        id: UUID,
        parentID: UUID,
        cancellationAccepted: Bool,
        startedAt: Date,
        forcedInternalCode: String? = nil
    ) -> OperationResult<ThreatRemediationReport> {
        let requestIDs = requests.map { $0.requestID.uuidString }
        let facts = items.map {
            OperationItemOutcome(
                subjectID: $0.requestID.uuidString,
                disposition: $0.disposition,
                mutation: $0.mutation)
        }
        let finishedAt = max(startedAt, Date())
        let outcome: OperationOutcome
        if let forcedInternalCode {
            outcome = OperationOutcomeReducer.internalFailure(
                id: id, parentID: parentID, kind: .threatRemediation,
                requestedSubjectIDs: requestIDs, itemOutcomes: facts,
                cancellationAccepted: cancellationAccepted, code: forcedInternalCode,
                startedAt: startedAt, finishedAt: finishedAt)
        } else {
            do {
                outcome = try OperationOutcomeReducer.reduce(
                    id: id, parentID: parentID, kind: .threatRemediation,
                    requestedSubjectIDs: requestIDs, itemOutcomes: facts,
                    cancellationAccepted: cancellationAccepted,
                    startedAt: startedAt, finishedAt: finishedAt)
            } catch {
                outcome = OperationOutcomeReducer.internalFailure(
                    id: id, parentID: parentID, kind: .threatRemediation,
                    requestedSubjectIDs: requestIDs, itemOutcomes: facts,
                    cancellationAccepted: cancellationAccepted,
                    code: "threat.remediation.reducer.invariant",
                    startedAt: startedAt, finishedAt: finishedAt)
            }
        }
        return OperationResult(
            outcome: outcome, payload: ThreatRemediationReport(items: items))
    }
}

private struct ValidatedLaunchAgentBinding: Sendable {
    let label: String
    let token: ThreatRemediationRetryToken
    let authorizationLease: ThreatRemediationRetryAuthorizationLease
}

private struct SecureLaunchAgentTarget: Sendable {
    let data: Data
    let relativeIdentity: String
    let rootIdentity: LaunchAgentsRootIdentity
}

private enum SecureLaunchAgentReadResult: Sendable {
    case target(SecureLaunchAgentTarget)
    case ineligible
    case tooLarge
    case unreadable
}

private enum SecureLaunchAgentRetryTargetState: Sendable {
    case absent(LaunchAgentsRootIdentity)
    case present(LaunchAgentsRootIdentity)
    case invalid
}

private struct LaunchAgentsRootIdentity: Equatable, Sendable {
    let device: dev_t
    let inode: ino_t

    init(_ information: stat) {
        device = information.st_dev
        inode = information.st_ino
    }

    func matchesCurrentPath(_ root: URL) -> Bool {
        SecureLaunchAgentReader.currentRootIdentity(at: root) == self
    }
}

private enum SecureLaunchAgentReader {
    static func relativeIdentity(candidate: URL, root: URL) -> String? {
        guard candidate.isFileURL,
              root.isFileURL,
              !candidate.pathComponents.contains("."),
              !candidate.pathComponents.contains("..") else { return nil }
        let identity = candidate.lastPathComponent
        guard ThreatRemediationRetryToken(
                  validatedLabel: "x",
                  rootRelativeIdentity: identity) != nil else { return nil }
        let expected = root.appendingPathComponent(identity, isDirectory: false)
        guard candidate.path == expected.path,
              candidate.standardizedFileURL.path == expected.standardizedFileURL.path else {
            return nil
        }
        return identity
    }

    static func currentRootIdentity(at root: URL) -> LaunchAgentsRootIdentity? {
        var information = stat()
        let status = root.path.withCString { lstat($0, &information) }
        guard status == 0,
              mode(information.st_mode, is: S_IFDIR) else { return nil }
        return LaunchAgentsRootIdentity(information)
    }

    static func read(
        candidate: URL,
        root: URL,
        maximumBytes: Int
    ) -> SecureLaunchAgentReadResult {
        guard maximumBytes >= 0,
              let relativeIdentity = relativeIdentity(candidate: candidate, root: root) else {
            return .ineligible
        }

        let rootFlags = O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        let rootDescriptor = root.path.withCString { Darwin.open($0, rootFlags) }
        guard rootDescriptor >= 0 else { return .ineligible }
        defer { Darwin.close(rootDescriptor) }

        var rootInformation = stat()
        guard fstat(rootDescriptor, &rootInformation) == 0,
              mode(rootInformation.st_mode, is: S_IFDIR) else {
            return .ineligible
        }
        let rootIdentity = LaunchAgentsRootIdentity(rootInformation)

        let fileFlags = O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW
        let fileDescriptor = relativeIdentity.withCString {
            Darwin.openat(rootDescriptor, $0, fileFlags)
        }
        guard fileDescriptor >= 0 else { return .ineligible }
        defer { Darwin.close(fileDescriptor) }

        var fileInformation = stat()
        guard fstat(fileDescriptor, &fileInformation) == 0 else { return .unreadable }
        guard mode(fileInformation.st_mode, is: S_IFREG) else { return .ineligible }
        guard fileInformation.st_size >= 0 else { return .unreadable }
        guard fileInformation.st_size <= maximumBytes else { return .tooLarge }

        var data = Data()
        data.reserveCapacity(min(Int(fileInformation.st_size), maximumBytes))
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let remaining = maximumBytes + 1 - data.count
            guard remaining > 0 else { return .tooLarge }
            let requested = min(buffer.count, remaining)
            let readCount = buffer.withUnsafeMutableBytes { bytes in
                Darwin.read(fileDescriptor, bytes.baseAddress, requested)
            }
            if readCount == 0 { break }
            if readCount < 0 {
                if errno == EINTR { continue }
                return .unreadable
            }
            data.append(contentsOf: buffer.prefix(Int(readCount)))
            if data.count > maximumBytes { return .tooLarge }
        }
        return .target(SecureLaunchAgentTarget(
            data: data,
            relativeIdentity: relativeIdentity,
            rootIdentity: rootIdentity))
    }

    /// Validates retry eligibility against one securely opened root directory. A retry token is
    /// only valid after the original plist has disappeared; any current directory entry (regular,
    /// symlink, directory, FIFO, or other node) is a stale target and must never inherit the old
    /// label authorization.
    static func validateRetryTargetAbsent(
        candidate: URL,
        root: URL
    ) -> SecureLaunchAgentRetryTargetState {
        guard let relativeIdentity = relativeIdentity(candidate: candidate, root: root) else {
            return .invalid
        }
        let rootFlags = O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        let rootDescriptor = root.path.withCString { Darwin.open($0, rootFlags) }
        guard rootDescriptor >= 0 else { return .invalid }
        defer { Darwin.close(rootDescriptor) }

        var rootInformation = stat()
        guard fstat(rootDescriptor, &rootInformation) == 0,
              mode(rootInformation.st_mode, is: S_IFDIR) else {
            return .invalid
        }
        let rootIdentity = LaunchAgentsRootIdentity(rootInformation)

        var targetInformation = stat()
        errno = 0
        let targetStatus = relativeIdentity.withCString {
            Darwin.fstatat(
                rootDescriptor,
                $0,
                &targetInformation,
                AT_SYMLINK_NOFOLLOW)
        }
        let targetErrno = errno
        guard rootIdentity.matchesCurrentPath(root) else { return .invalid }
        if targetStatus == 0 {
            return .present(rootIdentity)
        }
        guard targetErrno == ENOENT else { return .invalid }
        return .absent(rootIdentity)
    }

    private static func mode(_ value: mode_t, is expected: mode_t) -> Bool {
        value & S_IFMT == expected
    }
}

private struct ThreatRemediationRetryAuthorizationLease: Equatable, Sendable {
    let id: UUID
}

private enum ThreatRemediationRetryReservationResult: Sendable {
    case reserved(ThreatRemediationRetryAuthorizationLease)
    case capacity
    case collision
}

private enum ThreatRemediationRetryClaimResult: Sendable {
    case claimed(ThreatRemediationRetryAuthorizationLease)
    case invalid
    case inUse
}

private actor ThreatRemediationRetryAuthorizationStore {
    private enum EntryState: Equatable, Sendable {
        case available
        case inUse(leaseID: UUID, batchID: UUID)
        case pendingBatch(batchID: UUID)
    }

    private struct Entry: Equatable, Sendable {
        let token: ThreatRemediationRetryToken
        let rootPath: String
        let rootIdentity: LaunchAgentsRootIdentity
        var issuedAt: UInt64
        var state: EntryState
    }

    private let capacity: Int
    private let lifetimeNanoseconds: UInt64
    private let monotonicNow: @Sendable () -> UInt64
    private var entries: [Entry] = []

    init(
        lifetimeNanoseconds: UInt64,
        capacity: Int,
        monotonicNow: @escaping @Sendable () -> UInt64
    ) {
        self.lifetimeNanoseconds = lifetimeNanoseconds
        self.capacity = max(0, capacity)
        self.monotonicNow = monotonicNow
    }

    func reserve(
        token: ThreatRemediationRetryToken,
        rootPath: String,
        rootIdentity: LaunchAgentsRootIdentity,
        batchID: UUID
    ) -> ThreatRemediationRetryReservationResult {
        let now = monotonicNow()
        purgeExpired(at: now)
        if let index = entries.firstIndex(where: {
            $0.token == token
                && $0.rootPath == rootPath
                && $0.rootIdentity == rootIdentity
        }) {
            switch entries[index].state {
            case .available:
                // A D+R retry deliberately omits the old token and securely rereads the still-
                // present plist. Reuse its existing slot atomically instead of misclassifying the
                // fresh proof as a collision or evicting a live authorization.
                let lease = ThreatRemediationRetryAuthorizationLease(id: UUID())
                entries[index].issuedAt = now
                entries[index].state = .inUse(
                    leaseID: lease.id,
                    batchID: batchID)
                return .reserved(lease)
            case .inUse, .pendingBatch:
                return .collision
            }
        }
        guard entries.count < capacity else { return .capacity }
        let lease = ThreatRemediationRetryAuthorizationLease(id: UUID())
        entries.append(Entry(
            token: token,
            rootPath: rootPath,
            rootIdentity: rootIdentity,
            issuedAt: now,
            state: .inUse(leaseID: lease.id, batchID: batchID)))
        return .reserved(lease)
    }

    func claim(
        token: ThreatRemediationRetryToken,
        rootPath: String,
        rootIdentity: LaunchAgentsRootIdentity,
        batchID: UUID
    ) -> ThreatRemediationRetryClaimResult {
        let now = monotonicNow()
        purgeExpired(at: now)
        guard let index = entries.firstIndex(where: {
            $0.token == token
                && $0.rootPath == rootPath
                && $0.rootIdentity == rootIdentity
        }) else { return .invalid }
        switch entries[index].state {
        case .available:
            let lease = ThreatRemediationRetryAuthorizationLease(id: UUID())
            entries[index].state = .inUse(
                leaseID: lease.id,
                batchID: batchID)
            return .claimed(lease)
        case .inUse, .pendingBatch:
            return .inUse
        }
    }

    func finish(
        _ lease: ThreatRemediationRetryAuthorizationLease,
        retryable: Bool
    ) {
        guard let index = entries.firstIndex(where: {
            if case let .inUse(leaseID, _) = $0.state {
                return leaseID == lease.id
            }
            return false
        }) else { return }
        if retryable {
            guard case let .inUse(_, batchID) = entries[index].state else { return }
            entries[index].state = .pendingBatch(batchID: batchID)
        } else {
            entries.remove(at: index)
        }
    }

    /// Starts the user-action TTL only when the whole batch is ready to return. This prevents an
    /// early item from expiring while later sequential launchctl operations are still running.
    func completeBatch(
        _ batchID: UUID,
        rootPath: String,
        currentRootIdentity: LaunchAgentsRootIdentity?
    ) {
        let now = monotonicNow()
        for index in entries.indices.reversed() {
            guard case let .pendingBatch(entryBatchID) = entries[index].state,
                  entryBatchID == batchID else { continue }
            guard let currentRootIdentity,
                  entries[index].rootPath == rootPath,
                  entries[index].rootIdentity == currentRootIdentity else {
                entries.remove(at: index)
                continue
            }
            entries[index].issuedAt = now
            entries[index].state = .available
        }
    }

    private func purgeExpired(at now: UInt64) {
        entries.removeAll { entry in
            guard case .available = entry.state else { return false }
            guard lifetimeNanoseconds > 0,
                  now >= entry.issuedAt else { return true }
            return now - entry.issuedAt >= lifetimeNanoseconds
        }
    }
}

struct PropertyListLaunchAgentLabelReader: LaunchAgentLabelReading {
    func readLabel(from data: Data) -> LaunchAgentLabelReadResult {
        do {
            let value = try PropertyListSerialization.propertyList(
                from: data,
                options: [], format: nil)
            guard let dictionary = value as? [String: Any] else { return .unreadable }
            guard let rawLabel = dictionary["Label"] else { return .missing }
            guard let label = rawLabel as? String else { return .invalid }
            return .label(label)
        } catch {
            return .unreadable
        }
    }
}

private struct SystemLaunchAgentController: LaunchAgentControlling {
    private let executor: any LaunchctlProcessExecuting

    init(executor: any LaunchctlProcessExecuting = LaunchctlProcessRunner()) {
        self.executor = executor
    }

    func bootout(label: String, uid: uid_t) async -> LaunchAgentBootoutResult {
        switch await executor.run(["bootout", "gui/\(uid)/\(label)"]) {
        case .notStarted:
            return .notInvoked
        case .exited:
            return .invoked
        case .timedOut:
            return .timedOut
        case let .cancelled(processStarted):
            return .cancelled(processStarted: processStarted)
        }
    }
}

private struct SystemLaunchAgentPostcondition: LaunchAgentPostconditionChecking {
    private let executor: any LaunchctlProcessExecuting

    init(executor: any LaunchctlProcessExecuting = LaunchctlProcessRunner()) {
        self.executor = executor
    }

    func loadState(label: String, uid: uid_t) async -> LaunchAgentLoadState {
        switch await executor.run(["print", "gui/\(uid)/\(label)"]) {
        case .exited(0): return .loaded
        case .exited(113): return .notLoaded
        case .notStarted, .timedOut, .cancelled, .exited: return .unknown
        }
    }
}

enum LaunchctlExecution: Equatable, Sendable {
    case notStarted
    case exited(Int32)
    case timedOut
    case cancelled(processStarted: Bool)
}

protocol LaunchctlProcessExecuting: Sendable {
    func run(_ arguments: [String]) async -> LaunchctlExecution
}

enum LaunchctlProcessPollResult: Equatable, Sendable {
    case running
    case exited(Int32)
}

/// A process driver transfers ownership of a child PID exactly once: either `poll` reaps it or,
/// after the runner's hard deadline, `transferToBestEffortReaper` assumes sole ownership.
protocol LaunchctlProcessDriving: Sendable {
    func spawn(executableURL: URL, arguments: [String]) -> pid_t?
    func poll(_ pid: pid_t) -> LaunchctlProcessPollResult
    func send(signal: Int32, to pid: pid_t)
    func transferToBestEffortReaper(_ pid: pid_t)
}

protocol LaunchctlProcessTiming: Sendable {
    func now() -> UInt64
    func sleep(nanoseconds: UInt64) async
}

struct LaunchctlProcessRunner: LaunchctlProcessExecuting, Sendable {
    let executableURL: URL
    let timeoutNanoseconds: UInt64
    let pollNanoseconds: UInt64
    let terminationGraceNanoseconds: UInt64
    let killReapDeadlineNanoseconds: UInt64
    private let driver: any LaunchctlProcessDriving
    private let timing: any LaunchctlProcessTiming

    init(
        executableURL: URL = URL(fileURLWithPath: "/bin/launchctl"),
        timeoutNanoseconds: UInt64 = 5_000_000_000,
        pollNanoseconds: UInt64 = 10_000_000,
        terminationGraceNanoseconds: UInt64 = 200_000_000,
        killReapDeadlineNanoseconds: UInt64 = 200_000_000,
        driver: any LaunchctlProcessDriving = POSIXLaunchctlProcessDriver(),
        timing: any LaunchctlProcessTiming = SystemLaunchctlProcessTiming()
    ) {
        self.executableURL = executableURL
        self.timeoutNanoseconds = timeoutNanoseconds
        self.pollNanoseconds = max(1_000_000, pollNanoseconds)
        self.terminationGraceNanoseconds = terminationGraceNanoseconds
        self.killReapDeadlineNanoseconds = killReapDeadlineNanoseconds
        self.driver = driver
        self.timing = timing
    }

    func run(_ arguments: [String]) async -> LaunchctlExecution {
        guard !Task.isCancelled else {
            return .cancelled(processStarted: false)
        }
        guard let pid = driver.spawn(
            executableURL: executableURL,
            arguments: arguments) else {
            return Task.isCancelled
                ? .cancelled(processStarted: false)
                : .notStarted
        }

        let deadline = Self.deadline(
            from: timing.now(),
            after: timeoutNanoseconds)
        while true {
            if Task.isCancelled {
                await terminateAndBoundReaping(pid: pid)
                return .cancelled(processStarted: true)
            }
            switch driver.poll(pid) {
            case let .exited(status):
                return .exited(status)
            case .running:
                break
            }
            let now = timing.now()
            if now >= deadline {
                await terminateAndBoundReaping(pid: pid)
                return .timedOut
            }
            await timing.sleep(nanoseconds: min(pollNanoseconds, deadline - now))
        }
    }

    private func terminateAndBoundReaping(pid: pid_t) async {
        // The calling task is the sole owner until the explicit transfer below. There is no
        // cancellation-handler race and each signal is emitted at most once.
        driver.send(signal: SIGTERM, to: pid)
        if await waitForExit(
            pid: pid,
            durationNanoseconds: terminationGraceNanoseconds) {
            return
        }
        driver.send(signal: SIGKILL, to: pid)
        if await waitForExit(
            pid: pid,
            durationNanoseconds: killReapDeadlineNanoseconds) {
            return
        }
        driver.transferToBestEffortReaper(pid)
    }

    private func waitForExit(
        pid: pid_t,
        durationNanoseconds: UInt64
    ) async -> Bool {
        if case .exited = driver.poll(pid) { return true }
        let deadline = Self.deadline(
            from: timing.now(),
            after: durationNanoseconds)
        while true {
            let now = timing.now()
            guard now < deadline else { return false }
            let remaining = deadline - now
            await timing.sleep(nanoseconds: min(pollNanoseconds, remaining))
            if case .exited = driver.poll(pid) { return true }
        }
    }

    private static func deadline(from now: UInt64, after duration: UInt64) -> UInt64 {
        let value = now.addingReportingOverflow(duration)
        return value.overflow ? UInt64.max : value.partialValue
    }
}

private struct SystemLaunchctlProcessTiming: LaunchctlProcessTiming {
    func now() -> UInt64 {
        DispatchTime.now().uptimeNanoseconds
    }

    func sleep(nanoseconds: UInt64) async {
        guard nanoseconds > 0 else {
            await Task.yield()
            return
        }
        // Cap each suspension so cancellation is observed promptly even if a caller supplies an
        // unusually large polling interval; repeated sleeps still honor the monotonic deadline.
        let bounded = Int(min(nanoseconds, 50_000_000))
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).asyncAfter(
                deadline: .now() + .nanoseconds(bounded)) {
                continuation.resume()
            }
        }
    }
}

private struct POSIXLaunchctlProcessDriver: LaunchctlProcessDriving {
    func spawn(executableURL: URL, arguments: [String]) -> pid_t? {
        let nullDescriptor = Darwin.open("/dev/null", O_RDWR | O_CLOEXEC)
        guard nullDescriptor >= 0 else { return nil }
        defer { Darwin.close(nullDescriptor) }

        var fileActions: posix_spawn_file_actions_t?
        guard posix_spawn_file_actions_init(&fileActions) == 0 else { return nil }
        defer { posix_spawn_file_actions_destroy(&fileActions) }
        for descriptor in [STDIN_FILENO, STDOUT_FILENO, STDERR_FILENO] {
            guard posix_spawn_file_actions_adddup2(
                    &fileActions,
                    nullDescriptor,
                    descriptor) == 0 else {
                return nil
            }
        }
        if nullDescriptor > STDERR_FILENO {
            guard posix_spawn_file_actions_addclose(
                    &fileActions,
                    nullDescriptor) == 0 else {
                return nil
            }
        }

        var cArguments: [UnsafeMutablePointer<CChar>?] =
            ([executableURL.path] + arguments).map { strdup($0) }
        guard cArguments.allSatisfy({ $0 != nil }) else {
            cArguments.forEach { if let pointer = $0 { free(pointer) } }
            return nil
        }
        defer { cArguments.forEach { if let pointer = $0 { free(pointer) } } }
        cArguments.append(nil)

        var cEnvironment: [UnsafeMutablePointer<CChar>?] =
            ProcessInfo.processInfo.environment
                .sorted { $0.key < $1.key }
                .map { strdup("\($0.key)=\($0.value)") }
        guard cEnvironment.allSatisfy({ $0 != nil }) else {
            cEnvironment.forEach { if let pointer = $0 { free(pointer) } }
            return nil
        }
        defer { cEnvironment.forEach { if let pointer = $0 { free(pointer) } } }
        cEnvironment.append(nil)

        var pid: pid_t = 0
        let status = executableURL.path.withCString { executable in
            cArguments.withUnsafeMutableBufferPointer { argv in
                cEnvironment.withUnsafeMutableBufferPointer { environment in
                    posix_spawn(
                        &pid,
                        executable,
                        &fileActions,
                        nil,
                        argv.baseAddress,
                        environment.baseAddress)
                }
            }
        }
        return status == 0 && pid > 0 ? pid : nil
    }

    func poll(_ pid: pid_t) -> LaunchctlProcessPollResult {
        while true {
            var status: Int32 = 0
            let result = Darwin.waitpid(pid, &status, WNOHANG)
            if result == pid {
                return .exited(Self.exitCode(from: status))
            }
            if result == 0 { return .running }
            if result < 0, errno == EINTR { continue }
            // ECHILD cannot occur under the ownership contract. Fail closed as a terminal
            // nonzero exit rather than spinning or signalling a possibly reused PID.
            return .exited(1)
        }
    }

    func send(signal: Int32, to pid: pid_t) {
        _ = Darwin.kill(pid, signal)
    }

    func transferToBestEffortReaper(_ pid: pid_t) {
        Task.detached(priority: .utility) {
            var status: Int32 = 0
            while Darwin.waitpid(pid, &status, 0) < 0, errno == EINTR {}
        }
    }

    private static func exitCode(from waitStatus: Int32) -> Int32 {
        let terminatingSignal = waitStatus & 0x7f
        if terminatingSignal == 0 {
            return (waitStatus >> 8) & 0xff
        }
        return 128 + terminatingSignal
    }
}
