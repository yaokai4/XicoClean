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
