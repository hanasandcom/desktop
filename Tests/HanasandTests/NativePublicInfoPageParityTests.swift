import XCTest
@testable import Hanasand

final class NativePublicInfoPageParityTests: XCTestCase {
    func testHomeActionsAndSolutionsMatchWebsiteDestinations() throws {
        let home = try XCTUnwrap(NativePublicInfoPage.resolve("/"))
        XCTAssertEqual(home.links.map(\.route), [
            "/organizations", "/findings", "/ti", "/automation?setup=dwm",
        ])
        XCTAssertEqual(NativePublicInfoPage.homeSolutions.map(\.route), ["/ti", "/contact"])
        XCTAssertEqual(NativePublicInfoPage.faqItems.prefix(10).count, 10)
    }

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
        XCTAssertEqual(pricing.sections.first?.paragraphs, [
            "VM creation is free. Automatic failover is an optional upgrade: a standby copy on the other host with a verified container transfer.",
        ])
    }
}
