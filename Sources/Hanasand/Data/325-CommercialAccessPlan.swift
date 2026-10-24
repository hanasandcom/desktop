import Foundation

struct CommercialAccessPlan: Identifiable, Equatable {
    let id: String
    let name: String
    let priceNok: Int
    let quota: String
    let summary: String
    let features: [String]

    var monthlyPriceLabel: String { "\(priceNok.formatted()) kr / month" }
}

enum CommercialAccessPlans {
    // Keep these read-only offer details aligned with frontend/src/utils/commercialAccess.ts.
    static let all: [CommercialAccessPlan] = [
        CommercialAccessPlan(
            id: "threat-intelligence",
            name: "Threat Intelligence",
            priceNok: 199,
            quota: "100 searches per day",
            summary: "Search actors, domains, companies, and current public intelligence.",
            features: ["Threat actor profiles", "Current intelligence results", "API access", "Saved searches"]
        ),
        CommercialAccessPlan(
            id: "monitoring",
            name: "Dark Web Monitoring",
            priceNok: 499,
            quota: "25 watch terms",
            summary: "Monitor relevant public intelligence and turn matches into alerts and cases.",
            features: ["Customer watchlists", "Evidence-backed alerts", "Case workflow", "Source health and freshness"]
        ),
        CommercialAccessPlan(
            id: "scanner",
            name: "Security Scanner",
            priceNok: 299,
            quota: "10 monitored targets",
            summary: "Run scheduled security checks against approved websites and review the findings.",
            features: ["Scheduled scans", "Severity-based findings", "Scan history", "Run-now controls"]
        ),
    ]
}
