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

    func testFAQUsesTheWebsiteContactCTAWithoutAnExtraRelatedSection() throws {
        let faq = try XCTUnwrap(NativePublicInfoPage.resolve("/faq"))
        XCTAssertEqual(faq.eyebrow, "FAQ")
        XCTAssertEqual(faq.links.map(\.title), ["Ask a different question"])
        XCTAssertEqual(faq.links.map(\.route), ["/contact"])
        XCTAssertTrue(faq.sections.isEmpty)
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
        XCTAssertEqual(NativePublicInfoPage.plans.map(\.checkoutPlanID), CommercialAccessPlans.all.map(\.id))
        XCTAssertEqual(pricing.sections.map(\.title), ["Container host options"])
        XCTAssertEqual(pricing.sections.first?.paragraphs, [
            "VM creation is free. Automatic failover is an optional upgrade: a standby copy on the other host with a verified container transfer.",
        ])
    }

    func testFAQFeedbackPersistsPerQuestionAndReplacesThePreviousVote() throws {
        let suiteName = "hanasand.faq-feedback-tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertTrue(NativeFAQFeedbackStore.load(from: defaults).isEmpty)
        NativeFAQFeedbackStore.save(.yes, for: "Question one", to: defaults)
        NativeFAQFeedbackStore.save(.no, for: "Question two", to: defaults)
        XCTAssertEqual(NativeFAQFeedbackStore.load(from: defaults), ["Question one": .yes, "Question two": .no])

        NativeFAQFeedbackStore.save(.no, for: "Question one", to: defaults)
        XCTAssertEqual(NativeFAQFeedbackStore.load(from: defaults), ["Question one": .no, "Question two": .no])
    }
}
