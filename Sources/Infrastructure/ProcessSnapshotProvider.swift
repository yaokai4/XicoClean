import Foundation
import Shared

public struct LocalProcessSnapshotProvider: ProcessSnapshotProviding {
    private let enumerator: PIDEnumerator

    public init(enumerator: PIDEnumerator = PIDEnumerator()) {
        self.enumerator = enumerator
    }

    public func capture() async -> ProcessCapture {
        let pids = enumerator.allPIDs()
        var records: [ProcessResourceRecord] = []
        var failures: [Int32: ProcessResourceReadFailure] = [:]
        records.reserveCapacity(pids.count)
        failures.reserveCapacity(pids.count)

        for pid in pids {
            switch DarwinProcessResourceReader.read(pid: pid) {
            case .success(let record):
                records.append(record)
            case .failure(let failure):
                failures[pid] = failure
            }
        }

        return ProcessCapture(
            records: records,
            failures: failures,
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

    public init(
        local: any ProcessSnapshotProviding = LocalProcessSnapshotProvider(),
        helper: any PrivilegedProcessSampling = HelperProxy()
    ) {
        self.local = local
        self.helper = helper
    }

    public func capture() async -> ProcessCapture {
        let localCapture = await local.capture()
        let deniedPIDs = localCapture.failures.compactMap { pid, failure in
            failure == .permissionDenied ? pid : nil
        }.sorted()
        guard !deniedPIDs.isEmpty, helper.processSamplingAvailable,
              let response = await helper.sampleProcesses(pids: deniedPIDs),
              !response.records.isEmpty else {
            return localCapture
        }

        let requestedPIDs = Set(deniedPIDs)
        let recovered = response.records.filter { requestedPIDs.contains($0.pid) }
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
