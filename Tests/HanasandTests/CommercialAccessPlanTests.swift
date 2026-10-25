import XCTest
@testable import Hanasand

final class CommercialAccessPlanTests: XCTestCase {
    func testCatalogMatchesWebsiteOffersAndPrices() {
        XCTAssertEqual(CommercialAccessPlans.all.map(\.id), ["threat-intelligence", "monitoring", "scanner"])
        XCTAssertEqual(CommercialAccessPlans.all.map(\.priceNok), [199, 499, 299])
        XCTAssertEqual(CommercialAccessPlans.all.map(\.name), ["Threat Intelligence", "Dark Web Monitoring", "Security Scanner"])
        XCTAssertEqual(CommercialAccessPlans.all.map(\.quota), ["100 searches per day", "25 watch terms", "10 monitored targets"])
        XCTAssertTrue(CommercialAccessPlans.all.allSatisfy { !$0.summary.isEmpty && !$0.features.isEmpty })
    }

    func testPlanPricesAreClearlyMonthly() {
        XCTAssertEqual(CommercialAccessPlans.all.map(\.monthlyPriceLabel), ["199 kr / month", "499 kr / month", "299 kr / month"])
    }
}
