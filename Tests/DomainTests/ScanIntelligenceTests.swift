import XCTest
@testable import Domain

final class ScanIntelligenceTests: XCTestCase {
    private let url = URL(fileURLWithPath: "/tmp/xico-intelligence/cache")

    func testExplicitAssessmentRequiresHighConfidenceIndependentEvidenceForAutoSelection() {
        let weak = FindingAssessment(
            confidence: 0.99,
            evidence: [ScanEvidence(code: "one", kind: .signedRule, title: "规则命中")],
            reclaimableBytes: 100
        )
        let weakItem = CleanableItem(url: url, displayName: "cache", size: 100,
                                     safety: .safe, assessment: weak)
        XCTAssertFalse(weakItem.isSelected, "显式智能判断只有单一证据时不得自动勾选")

        let strong = FindingAssessment(
            confidence: 0.99,
            evidence: [
                ScanEvidence(code: "rule", kind: .signedRule, title: "签名规则命中"),
                ScanEvidence(code: "owner", kind: .pathOwnership, title: "路径归属确认")
            ],
            reclaimableBytes: 100,
            recovery: .regenerate
        )
        let strongItem = CleanableItem(url: url, displayName: "cache", size: 100,
                                       safety: .safe, assessment: strong)
        XCTAssertTrue(strongItem.isSelected, "高置信双证据安全项才可自动勾选")
    }

    func testReclaimableTotalsUseIndependentBytesInsteadOfApparentSize() {
        let assessment = FindingAssessment(
            confidence: 1,
            evidence: [
                ScanEvidence(code: "hash", kind: .exactContent, title: "内容一致"),
                ScanEvidence(code: "clone", kind: .size, title: "独占块口径")
            ],
            reclaimableBytes: 4
        )
        let item = CleanableItem(url: url, displayName: "clone", size: 1_000,
                                 safety: .caution, isSelected: true, assessment: assessment)
        let group = ScanResultGroup(id: "g", title: "g", items: [item])
        XCTAssertEqual(group.totalSize, 1_000)
        XCTAssertEqual(group.reclaimableSize, 4)
        XCTAssertEqual(group.selectedSize, 4)
        XCTAssertEqual(CleaningPlan(items: [item]).totalSize, 4)
    }

    func testCoverageNeverCallsDeniedOrCancelledScanComplete() {
        let complete = ScanCoverage(roots: ["/tmp"], filesVisited: 10,
                                    directoriesVisited: 2, hiddenFilesIncluded: true)
        XCTAssertTrue(complete.isComplete)

        let denied = ScanCoverage(roots: ["/tmp"], deniedDirectories: 1,
                                  limitations: ["有 1 个目录因权限不足未读取"])
        XCTAssertFalse(denied.isComplete)
        let merged = ScanCoverage.merged([complete, denied])
        XCTAssertEqual(merged?.filesVisited, 10)
        XCTAssertEqual(merged?.deniedDirectories, 1)
        XCTAssertFalse(merged?.isComplete ?? true)
    }

    func testCoverageMergeDoesNotTripleCountSharedSnapshot() {
        let shared = ScanCoverage(roots: ["/Users/test"], filesVisited: 12_000,
                                  directoriesVisited: 900, bytesInspected: 42_000,
                                  deniedDirectories: 2,
                                  limitations: ["有 2 个目录因权限不足未读取"])
        let merged = ScanCoverage.merged([shared, shared, shared])

        XCTAssertEqual(merged?.filesVisited, 12_000)
        XCTAssertEqual(merged?.directoriesVisited, 900)
        XCTAssertEqual(merged?.deniedDirectories, 2)
    }
}
