import XCTest
@testable import Hanasand

final class NativePublicInfoPageParityTests: XCTestCase {
    func testSolutionCallsToActionMatchWebsiteDestinations() throws {
        let scanner = try XCTUnwrap(NativePublicInfoPage.resolve("/solutions/scanner"))
        XCTAssertEqual(scanner.links.map(\.route), ["/scanner"])

        let monitoring = try XCTUnwrap(NativePublicInfoPage.resolve("/solutions/security-monitoring"))
        XCTAssertEqual(monitoring.links.map(\.route), ["/cases", "/developers"])
        XCTAssertEqual(monitoring.sections.prefix(3).map(\.title), [
            "One endpoint", "Useful first detections", "Evidence-first review",
        ])
    }

    func testPricingIncludesPlansAndContainerSection() throws {
        let pricing = try XCTUnwrap(NativePublicInfoPage.resolve("/pricing"))
        XCTAssertEqual(NativePublicInfoPage.plans.count, 3)
        XCTAssertEqual(pricing.sections.map(\.title), ["Container host options"])
    }
}
