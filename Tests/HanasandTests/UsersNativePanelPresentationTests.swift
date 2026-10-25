import XCTest
@testable import Hanasand

final class UsersNativePanelPresentationTests: XCTestCase {
    func testOrganizationOpenRequiresCurrentActiveMembershipAndNoImpersonation() throws {
        let actor = try JSONDecoder().decode(
            DashboardUser.self,
            from: Data(#"{"id":"admin","active":true,"organization_memberships":[{"id":"org-one","name":"Research","slug":"research","status":"active"}]}"#.utf8)
        )
        let active = DashboardUserOrganization(id: "org-one", name: "Research", slug: "research", status: "active")
        let pending = DashboardUserOrganization(id: "org-one", name: "Research", slug: "research", status: "pending")
        let other = DashboardUserOrganization(id: "org-two", name: "Other", slug: "other", status: "active")

        XCTAssertTrue(UsersNativePanelPresentation.canOpenOrganization(active, as: actor, isImpersonating: false))
        XCTAssertFalse(UsersNativePanelPresentation.canOpenOrganization(active, as: actor, isImpersonating: true))
        XCTAssertFalse(UsersNativePanelPresentation.canOpenOrganization(pending, as: actor, isImpersonating: false))
        XCTAssertFalse(UsersNativePanelPresentation.canOpenOrganization(other, as: actor, isImpersonating: false))
        XCTAssertFalse(UsersNativePanelPresentation.canOpenOrganization(active, as: nil, isImpersonating: false))

        let inactiveActor = try JSONDecoder().decode(
            DashboardUser.self,
            from: Data(#"{"id":"admin","active":false,"organization_memberships":[{"id":"org-one","name":"Research","slug":"research","status":"active"}]}"#.utf8)
        )
        XCTAssertFalse(UsersNativePanelPresentation.canOpenOrganization(active, as: inactiveActor, isImpersonating: false))
    }

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
