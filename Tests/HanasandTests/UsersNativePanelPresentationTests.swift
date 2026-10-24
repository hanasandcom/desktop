import XCTest
@testable import Hanasand

final class UsersNativePanelPresentationTests: XCTestCase {
    func testOrganizationSummaryHandlesNoMemberships() {
        XCTAssertEqual(
            UsersNativePanelPresentation.organizationSummary([]),
            "No organization memberships"
        )
    }

    func testOrganizationSummaryIncludesCountNamesAndMembershipStatuses() {
        let organizations = [
            DashboardUserOrganization(id: "org-one", name: "Research", slug: "research", status: "active"),
            DashboardUserOrganization(id: "org-two", name: "Incident response", slug: "incident-response", status: "pending"),
        ]

        XCTAssertEqual(
            UsersNativePanelPresentation.organizationSummary(organizations),
            "2 organizations · Research · active, Incident response · pending"
        )
    }

    func testOrganizationSummaryKeepsLongMembershipNamesIntactForTooltip() {
        let longName = "Regional security and incident response organization"
        let organizations = [
            DashboardUserOrganization(id: "org-one", name: longName, slug: "regional-security", status: "active"),
        ]

        XCTAssertEqual(
            UsersNativePanelPresentation.organizationSummary(organizations),
            "1 organization · \(longName) · active"
        )
    }
}
