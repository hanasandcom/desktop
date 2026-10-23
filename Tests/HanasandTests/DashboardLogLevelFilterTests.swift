import XCTest
@testable import Hanasand

final class DashboardLogLevelFilterTests: XCTestCase {
    func testHighPresetIncludesHighAndCriticalSeverity() {
        XCTAssertTrue(DashboardLogLevelFilter.matches(level: "high", filter: "high"))
        XCTAssertTrue(DashboardLogLevelFilter.matches(level: "critical", filter: "high"))
        XCTAssertFalse(DashboardLogLevelFilter.matches(level: "error", filter: "high"))
    }

    func testLevelFiltersIgnoreCaseAndWhitespace() {
        XCTAssertTrue(DashboardLogLevelFilter.matches(level: " Critical ", filter: "critical"))
        XCTAssertTrue(DashboardLogLevelFilter.matches(level: "WARNING", filter: "warn"))
        XCTAssertFalse(DashboardLogLevelFilter.matches(level: "info", filter: "warn"))
    }

    func testAllFilterIncludesEveryLevel() {
        XCTAssertTrue(DashboardLogLevelFilter.matches(level: "custom", filter: "all"))
        XCTAssertTrue(DashboardLogLevelFilter.matches(level: "custom", filter: ""))
    }
}
