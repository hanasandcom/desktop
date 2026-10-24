import XCTest
@testable import Hanasand

final class CasesWorkspaceFiltersTests: XCTestCase {
    func testDefaultsMatchCasesWorkspaceAndResetRestoresAllDefaults() {
        var filters = CasesWorkspaceFilters()
        XCTAssertFalse(filters.hasActiveFilters)

        filters.search = " outage "
        filters.status = "all"
        filters.severity = "critical"
        filters.source = "monitoring"
        filters.owner = "unassigned"
        filters.resolution = "ai"
        filters.review = "pending"
        XCTAssertTrue(filters.hasActiveFilters)

        filters.reset()

        XCTAssertEqual(filters, CasesWorkspaceFilters())
        XCTAssertFalse(filters.hasActiveFilters)
    }
}
