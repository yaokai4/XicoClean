import XCTest
@testable import Infrastructure
import Shared

final class ProcessSnapshotProviderTests: XCTestCase {
    private final class FakeListing: PIDListing, @unchecked Sendable {
        let estimate: Int
        let values: [Int32]
        init(estimate: Int, values: [Int32]) {
            self.estimate = estimate
            self.values = values
        }
        func estimatedCount() -> Int { estimate }
        func fill(_ buffer: inout [Int32]) -> Int {
            let count = min(buffer.count, values.count)
            for index in 0..<count { buffer[index] = values[index] }
            return values.count > buffer.count ? buffer.count : values.count
        }
    }

    func testPIDReturnValueIsCountNotBytes() {
        let listing = FakeListing(estimate: 8, values: [11, 12, 13, 14, 15, 16, 17, 18])
        XCTAssertEqual(PIDEnumerator(listing: listing, reserve: 0).allPIDs(),
                       [11, 12, 13, 14, 15, 16, 17, 18])
    }

    func testPIDEnumeratorGrowsWhenBufferFills() {
        let expected = (1...100).map(Int32.init)
        let listing = FakeListing(estimate: 1, values: expected)
        XCTAssertEqual(PIDEnumerator(listing: listing, reserve: 0).allPIDs(), expected)
    }

    func testIdentityIncludesStartTime() {
        XCTAssertNotEqual(ProcessIdentity(pid: 42, startTimeNanoseconds: 1),
                          ProcessIdentity(pid: 42, startTimeNanoseconds: 2))
    }
}
