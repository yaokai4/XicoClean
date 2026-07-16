import Foundation
import Domain

public struct ShredderItemResult: Sendable {
    public let requestID: UUID
    public let url: URL
    public let disposition: OperationDisposition
    public let mutation: OperationMutationFact
    public let freedBytes: Int64

    init(
        requestID: UUID,
        url: URL,
        disposition: OperationDisposition,
        mutation: OperationMutationFact,
        freedBytes: Int64
    ) {
        self.requestID = requestID
        self.url = url
        self.disposition = disposition
        self.mutation = mutation
        self.freedBytes = max(0, freedBytes)
    }
}

public struct ShredderPayload: Sendable {
    public let items: [ShredderItemResult]
    public let freedBytes: Int64

    init(items: [ShredderItemResult]) {
        self.items = items
        self.freedBytes = items.reduce(Int64(0)) { total, item in
            let (sum, overflow) = total.addingReportingOverflow(item.freedBytes)
            return overflow ? .max : sum
        }
    }
}
