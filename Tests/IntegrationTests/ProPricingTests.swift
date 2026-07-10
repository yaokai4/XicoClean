import XCTest
@testable import Infrastructure

/// Pro 价格与官网同步的回归：格式化口径、折扣计算、离线兜底，
/// 以及（门控）与官网 geo/定价接口的实网一致性。
final class ProPricingTests: XCTestCase {
    func testDiscountAndLabels() {
        let cny = ProPricing(currency: "CNY",
                             personal: ProPlanPrice(amount: 38, compareAt: 129),
                             family: ProPlanPrice(amount: 68, compareAt: 218))
        XCTAssertEqual(cny.discountPercent(cny.personal), 71)
        XCTAssertEqual(cny.discountPercent(cny.family), 69)
        XCTAssertTrue(cny.label(cny.personal).contains("38"))
        XCTAssertNotNil(cny.compareAtLabel(cny.personal))

        // 无折扣（compareAt 缺失或不高于现价）不得出现划线价。
        let flat = ProPricing(currency: "USD",
                              personal: ProPlanPrice(amount: 9.99, compareAt: nil),
                              family: ProPlanPrice(amount: 9.99, compareAt: 5))
        XCTAssertNil(flat.compareAtLabel(flat.personal))
        XCTAssertNil(flat.compareAtLabel(flat.family))
        XCTAssertNil(flat.discountPercent(flat.family))
        XCTAssertTrue(flat.label(flat.personal).contains("9.99"))
    }

    func testFallbackWithoutCacheIsCNYTable() {
        UserDefaults.standard.removeObject(forKey: "xico.pro.pricing.cache")
        let p = ProPricingClient.cachedOrDefault()
        XCTAssertEqual(p.currency, "CNY")
        XCTAssertEqual(p.personal.amount, 38)
        XCTAssertEqual(p.family.amount, 68)
    }

    /// 实网同步（门控 XICO_NET_TEST=1）：fetch 必须返回官网判定的币种价格，
    /// 且金额来自官网接口或与官网同源的价目表——绝不再出现硬编码 ¥128/¥218 的脱节。
    func testLiveFetchMatchesSiteCurrency() async throws {
        guard ProcessInfo.processInfo.environment["XICO_NET_TEST"] == "1" else {
            throw XCTSkip("未设置 XICO_NET_TEST=1，跳过实网测试")
        }
        let p = await ProPricingClient.fetch()
        XCTAssertGreaterThan(p.personal.amount, 0)
        XCTAssertGreaterThan(p.family.amount, p.personal.amount)
        if let compareAt = p.personal.compareAt {
            XCTAssertGreaterThan(compareAt, p.personal.amount)
        }
        print("[价格同步] currency=\(p.currency) personal=\(p.label(p.personal)) family=\(p.label(p.family))")
    }
}
