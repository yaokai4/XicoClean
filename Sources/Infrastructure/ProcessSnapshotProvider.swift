import Foundation
import Shared

enum ProcessHelperEnhancementPolicy {
    static let schedulingAllowance: TimeInterval = 1

    static func resultTimeToLive(refreshInterval: TimeInterval) -> TimeInterval {
        max(0, refreshInterval) + schedulingAllowance
    }

    static func currentResultTimeToLive() -> TimeInterval {
        resultTimeToLive(refreshInterval: MonitoringRefreshIntervalStore.read().rawValue)
    }
}

private final class HelperEnhancementState: @unchecked Sendable {
    struct Request: Sendable {
        let generation: UInt64
        let pids: [Int32]
    }

    struct Preparation {
        let cachedRecords: [ProcessResourceRecord]
        let request: Request?
    }

    private struct CachedResponse {
        let records: [ProcessResourceRecord]
        let completedAt: Date
        let generation: UInt64
    }

    private let lock = NSLock()
    private let retryDelay: TimeInterval
    private let resultFreshness: @Sendable () -> TimeInterval
    private var cachedResponse: CachedResponse?
    private var requestInFlight = false
    private var requestGeneration: UInt64 = 0
    private var retryAfter: Date?

    init(
        retryDelay: TimeInterval,
        resultFreshness: @escaping @Sendable () -> TimeInterval
    ) {
        self.retryDelay = max(0, retryDelay)
        self.resultFreshness = resultFreshness
    }

    func prepare(
        deniedPIDs: [Int32],
        helperAvailable: Bool,
        now: Date
    ) -> Preparation {
        // Read this for every frame so changing the user setting from 5s to 1s
        // immediately tightens the acceptance window for an outstanding result.
        let resultTimeToLive = max(0, resultFreshness())
        return lock.withLock {
            let requested = Set(deniedPIDs)
            let recovered: [ProcessResourceRecord]
            if let cachedResponse {
                let age = now.timeIntervalSince(cachedResponse.completedAt)
                if age >= 0, age <= resultTimeToLive,
                   cachedResponse.generation == requestGeneration {
                    recovered = cachedResponse.records.filter { requested.contains($0.pid) }
                } else {
                    recovered = []
                }
            } else {
                recovered = []
            }
            // A helper result belongs to at most one local frame. Leaving it cached would
            // allow a reopened panel to relabel old data with a new capture timestamp.
            cachedResponse = nil

            let canRetry = retryAfter.map { now >= $0 } ?? true
            let shouldStart = !deniedPIDs.isEmpty
                && helperAvailable
                && !requestInFlight
                && canRetry
            let request: Request?
            if shouldStart {
                requestInFlight = true
                requestGeneration &+= 1
                request = Request(generation: requestGeneration, pids: deniedPIDs)
            } else {
                request = nil
            }
            return Preparation(
                cachedRecords: recovered,
                request: request
            )
        }
    }

    func complete(
        _ response: ProcessHelperBatchResponse?,
        generation: UInt64,
        now: Date
    ) {
        lock.withLock {
            guard requestInFlight, generation == requestGeneration else { return }
            requestInFlight = false
            if let response, !response.records.isEmpty {
                cachedResponse = CachedResponse(
                    records: response.records,
                    completedAt: now,
                    generation: generation
                )
                retryAfter = nil
            } else {
                cachedResponse = nil
                retryAfter = now.addingTimeInterval(retryDelay)
            }
        }
    }

    func isRequestInFlight() -> Bool {
        lock.withLock { requestInFlight }
    }
}

public struct LocalProcessSnapshotProvider: ProcessSnapshotProviding {
    private let enumerator: PIDEnumerator

    public init(
        enumerator: PIDEnumerator = PIDEnumerator(),
        maximumWorkerCount: Int = 4
    ) {
        self.enumerator = enumerator
        _ = maximumWorkerCount
    }

    public func capture() async -> ProcessCapture {
        let pids = enumerator.allPIDs()
        let batch = DarwinProcessResourceReader.readBatch(pids: pids)

        return ProcessCapture(
            records: batch.records,
            failures: batch.failures,
            wallDate: Date(),
            monotonicNanoseconds: DispatchTime.now().uptimeNanoseconds,
            source: .local,
            enumeratedCount: pids.count
        )
    }
}

public struct HybridProcessSnapshotProvider: ProcessSnapshotProviding {
    private let local: any ProcessSnapshotProviding
    private let helper: any PrivilegedProcessSampling
    private let now: @Sendable () -> Date
    private let helperState: HelperEnhancementState

    public init(
        local: any ProcessSnapshotProviding = LocalProcessSnapshotProvider(),
        helper: any PrivilegedProcessSampling = HelperProxy(),
        now: @escaping @Sendable () -> Date = { Date() },
        helperRetryDelay: TimeInterval = 60,
        helperResultFreshness: @escaping @Sendable () -> TimeInterval = {
            max(0, MonitoringRefreshIntervalStore.read().rawValue) + 1
        }
    ) {
        self.local = local
        self.helper = helper
        self.now = now
        self.helperState = HelperEnhancementState(
            retryDelay: helperRetryDelay,
            resultFreshness: helperResultFreshness
        )
    }

    var helperRequestInFlightForTesting: Bool {
        helperState.isRequestInFlight()
    }

    public func capture() async -> ProcessCapture {
        let localCapture = await local.capture()
        let deniedPIDs = localCapture.failures.compactMap { pid, failure in
            failure == .permissionDenied ? pid : nil
        }.sorted()
        guard !deniedPIDs.isEmpty else { return localCapture }

        let preparation = helperState.prepare(
            deniedPIDs: deniedPIDs,
            helperAvailable: helper.processSamplingAvailable,
            now: now()
        )
        if let request = preparation.request {
            let helper = self.helper
            let helperState = self.helperState
            let now = self.now
            Task.detached(priority: .utility) {
                let response = await helper.sampleProcesses(pids: request.pids)
                helperState.complete(
                    response,
                    generation: request.generation,
                    now: now()
                )
            }
        }

        let requestedPIDs = Set(deniedPIDs)
        let recovered = preparation.cachedRecords.filter { requestedPIDs.contains($0.pid) }
        guard !recovered.isEmpty else { return localCapture }

        var recordsByIdentity = Dictionary(
            localCapture.records.map {
                (ProcessIdentity(pid: $0.pid, startTimeNanoseconds: $0.startTimeNanoseconds), $0)
            },
            uniquingKeysWith: { _, replacement in replacement }
        )
        for record in recovered {
            let identity = ProcessIdentity(
                pid: record.pid,
                startTimeNanoseconds: record.startTimeNanoseconds
            )
            recordsByIdentity[identity] = record
        }
        var failures = localCapture.failures
        for record in recovered {
            failures.removeValue(forKey: record.pid)
        }

        return ProcessCapture(
            records: recordsByIdentity.values.sorted {
                if $0.pid != $1.pid { return $0.pid < $1.pid }
                return $0.startTimeNanoseconds < $1.startTimeNanoseconds
            },
            failures: failures,
            wallDate: localCapture.wallDate,
            monotonicNanoseconds: localCapture.monotonicNanoseconds,
            source: .helperEnhanced,
            enumeratedCount: localCapture.enumeratedCount
        )
    }
}
