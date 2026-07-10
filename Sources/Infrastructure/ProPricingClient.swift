import Foundation

/// 单个方案的价格（主单位，如 38 表示 ¥38 / $38）。compareAt = 划线原价（有折扣时）。
public struct ProPlanPrice: Sendable, Equatable, Codable {
    public let amount: Double
    public let compareAt: Double?

    public init(amount: Double, compareAt: Double?) {
        self.amount = amount
        self.compareAt = compareAt
    }
}

/// Pro 价格（币种 + 个人版/家庭版）——与官网购买页同一口径。
public struct ProPricing: Sendable, Equatable, Codable {
    public let currency: String
    public let personal: ProPlanPrice
    public let family: ProPlanPrice

    public init(currency: String, personal: ProPlanPrice, family: ProPlanPrice) {
        self.currency = currency
        self.personal = personal
        self.family = family
    }

    /// 本地化价格标签（如 "¥38" / "JP¥880" / "$5.99"）。整数价不带小数。
    public func label(_ plan: ProPlanPrice) -> String {
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.currencyCode = currency
        f.minimumFractionDigits = 0
        f.maximumFractionDigits = plan.amount.rounded() == plan.amount ? 0 : 2
        return f.string(from: plan.amount as NSNumber) ?? "\(currency) \(plan.amount)"
    }

    /// 划线原价标签；无折扣（compareAt 缺失或不高于现价）返回 nil。
    public func compareAtLabel(_ plan: ProPlanPrice) -> String? {
        guard let compareAt = plan.compareAt, compareAt > plan.amount else { return nil }
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.currencyCode = currency
        f.minimumFractionDigits = 0
        f.maximumFractionDigits = compareAt.rounded() == compareAt ? 0 : 2
        return f.string(from: compareAt as NSNumber)
    }

    /// 折扣百分比（如 71 = -71%）；无折扣返回 nil。
    public func discountPercent(_ plan: ProPlanPrice) -> Int? {
        guard let compareAt = plan.compareAt, compareAt > plan.amount else { return nil }
        return Int(((1 - plan.amount / compareAt) * 100).rounded())
    }
}

/// 官网价格同步客户端。三级回退，永不失败：
/// 1. 官网定价 API `/api/mac/pricing`（服务端按 IP 定币种，管理后台改价即时生效）；
/// 2. 官网 geo API `/api/geo` 拿币种 + 内置价目表（与官网价目表同源同值）；
/// 3. 上次成功结果的本地缓存 → 内置 CNY 兜底。
/// 成功结果落缓存；App 展示价与官网购买页对同一位用户显示的价格一致（同一 IP 币种判定）。
public enum ProPricingClient {
    private static let cacheKey = "xico.pro.pricing.cache"

    /// 与官网 `SUGGESTED_CURRENCY_PRESETS` 同源的价目表（2026-07 实拉官网购买页核对一致）。
    /// 仅作离线/接口不可用时的回退——在线时以官网返回为准。
    private static let priceTable: [String: (personal: ProPlanPrice, family: ProPlanPrice)] = [
        "CNY": (ProPlanPrice(amount: 38, compareAt: 129), ProPlanPrice(amount: 68, compareAt: 218)),
        "USD": (ProPlanPrice(amount: 5.99, compareAt: 19.99), ProPlanPrice(amount: 9.99, compareAt: 34.99)),
        "JPY": (ProPlanPrice(amount: 880, compareAt: 2980), ProPlanPrice(amount: 1480, compareAt: 4980)),
        "EUR": (ProPlanPrice(amount: 5.99, compareAt: 18.99), ProPlanPrice(amount: 9.99, compareAt: 32.99)),
        "KRW": (ProPlanPrice(amount: 7900, compareAt: 26000), ProPlanPrice(amount: 13900, compareAt: 45000)),
        "TWD": (ProPlanPrice(amount: 180, compareAt: 620), ProPlanPrice(amount: 320, compareAt: 1080)),
        "HKD": (ProPlanPrice(amount: 45, compareAt: 158), ProPlanPrice(amount: 78, compareAt: 268)),
        "GBP": (ProPlanPrice(amount: 4.99, compareAt: 16.99), ProPlanPrice(amount: 8.99, compareAt: 28.99)),
        "BRL": (ProPlanPrice(amount: 29, compareAt: 99), ProPlanPrice(amount: 49, compareAt: 169)),
    ]

    private static func tablePricing(currency: String) -> ProPricing {
        let c = currency.uppercased()
        let row = priceTable[c] ?? priceTable["CNY"]!
        return ProPricing(currency: priceTable[c] != nil ? c : "CNY",
                          personal: row.personal, family: row.family)
    }

    /// 同步可用的初始值：上次成功缓存，否则 CNY 兜底（视图先渲染它，随后被 fetch 结果替换）。
    public static func cachedOrDefault() -> ProPricing {
        if let data = UserDefaults.standard.data(forKey: cacheKey),
           let cached = try? JSONDecoder().decode(ProPricing.self, from: data) {
            return cached
        }
        return tablePricing(currency: "CNY")
    }

    /// 拉取与官网一致的价格。永不抛错——逐级回退，最终必有值。
    public static func fetch() async -> ProPricing {
        if let live = await fetchPricingEndpoint() {
            cache(live)
            return live
        }
        if let currency = await fetchGeoCurrency() {
            let p = tablePricing(currency: currency)
            cache(p)
            return p
        }
        return cachedOrDefault()
    }

    private static func cache(_ p: ProPricing) {
        if let data = try? JSONEncoder().encode(p) {
            UserDefaults.standard.set(data, forKey: cacheKey)
        }
    }

    private static func session() -> URLSession {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 5
        cfg.timeoutIntervalForResource = 8
        return URLSession(configuration: cfg)
    }

    /// 官网定价 API（部署后即时生效；未部署时 404 → 回退 geo+价目表）。
    private static func fetchPricingEndpoint() async -> ProPricing? {
        struct Payload: Decodable {
            struct Plan: Decodable { let amount: Double; let compareAt: Double? }
            struct Plans: Decodable { let personal: Plan; let family: Plan }
            let active: Bool
            let currency: String
            let plans: Plans
        }
        let url = LicenseService.activationBaseURL().appendingPathComponent("api/mac/pricing")
        guard let (data, resp) = try? await session().data(from: url),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let p = try? JSONDecoder().decode(Payload.self, from: data),
              p.plans.personal.amount > 0 else { return nil }
        return ProPricing(currency: p.currency.uppercased(),
                          personal: ProPlanPrice(amount: p.plans.personal.amount,
                                                 compareAt: p.plans.personal.compareAt),
                          family: ProPlanPrice(amount: p.plans.family.amount,
                                               compareAt: p.plans.family.compareAt))
    }

    /// 官网 geo API：按访问 IP 判定币种（已在线），与购买页同一套判定。
    private static func fetchGeoCurrency() async -> String? {
        struct Geo: Decodable { let currency: String? }
        let url = LicenseService.activationBaseURL().appendingPathComponent("api/geo")
        guard let (data, resp) = try? await session().data(from: url),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let g = try? JSONDecoder().decode(Geo.self, from: data) else { return nil }
        return g.currency
    }
}
