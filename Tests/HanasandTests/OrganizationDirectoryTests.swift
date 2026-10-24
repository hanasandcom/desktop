import XCTest
@testable import Hanasand

final class OrganizationDirectoryTests: XCTestCase {
    func testDecodesIdentityDirectoryAndMembershipContracts() throws {
        let directoryData = #"{"organizations":[{"id":"org-one","name":"Example Org","slug":"example-org","status":"active","member_count":7,"created_at":"2026-10-22T12:00:00Z","last_active_at":null}]}"#.data(using: .utf8)!
        let membershipData = #"{"organizations":[{"id":"org-one","name":"Example Org","lifecycleStatus":"active","role":"reader"}]}"#.data(using: .utf8)!

        let organization = try JSONDecoder().decode(DashboardDirectoryOrganizationsEnvelope.self, from: directoryData).organizations[0]
        let membership = try JSONDecoder().decode(DashboardOrganizationMembershipsEnvelope.self, from: membershipData).organizations[0]

        XCTAssertEqual(organization.id, "org-one")
        XCTAssertEqual(organization.memberCount, 7)
        XCTAssertEqual(organization.lastActiveAt, nil)
        XCTAssertEqual(membership.status, "active")
        XCTAssertEqual(membership.role, "reader")

        let stringCountData = #"{"organizations":[{"id":"org-two","name":"Second Org","slug":"second-org","status":"active","member_count":"12"}]}"#.data(using: .utf8)!
        XCTAssertEqual(try JSONDecoder().decode(DashboardDirectoryOrganizationsEnvelope.self, from: stringCountData).organizations[0].memberCount, 12)
    }

    func testSwitchRequiresOwnAuthenticatedNonImpersonatedActiveMembership() {
        func allowed(
            organizationID: String = "org-one",
            organizationStatus: String = "active",
            membershipStatus: String? = "active",
            isAuthenticated: Bool = true,
            isOwnAccount: Bool = true,
            isImpersonating: Bool = false
        ) -> Bool {
            return DashboardOrganizationSwitchPolicy.canSwitch(
                organizationID: organizationID,
                organizationStatus: organizationStatus,
                membershipStatus: membershipStatus,
                isAuthenticated: isAuthenticated,
                isOwnAccount: isOwnAccount,
                isImpersonating: isImpersonating
            )
        }

        XCTAssertTrue(allowed())
        XCTAssertFalse(allowed(membershipStatus: nil))
        XCTAssertFalse(allowed(membershipStatus: "inactive"))
        XCTAssertFalse(allowed(organizationStatus: "archived"))
        XCTAssertFalse(allowed(isAuthenticated: false))
        XCTAssertFalse(allowed(isOwnAccount: false))
        XCTAssertFalse(allowed(isImpersonating: true))
    }

    func testOldSettingsDecodeWithoutOrganizationContext() throws {
        let data = #"{"websiteBaseURL":"https://hanasand.com","apiBaseURL":"https://api.hanasand.com/api"}"#.data(using: .utf8)!
        let settings = try JSONDecoder().decode(HanasandDesktopSettings.self, from: data)

        XCTAssertEqual(settings.selectedOrganizationID, "")
        XCTAssertEqual(settings.selectedOrganizationUserID, "")
    }

    func testCreationNormalizesNameAndRejectsListedNameOrSlugDuplicates() {
        let organizations = [
            DashboardDirectoryOrganization(id: "org-one", name: "Example Security", slug: "example-security", status: "active", memberCount: 1),
            DashboardDirectoryOrganization(id: "other-slug", name: "Another Group", slug: "another-group", status: "archived", memberCount: 0),
        ]

        XCTAssertEqual(DashboardOrganizationCreationPolicy.normalizedName("  Example\n  Security  "), "Example Security")
        XCTAssertEqual(DashboardOrganizationCreationPolicy.slug(for: " Example Security "), "example-security")
        XCTAssertTrue(DashboardOrganizationCreationPolicy.nameIsInUse(" example   security ", organizations: organizations))
        XCTAssertTrue(DashboardOrganizationCreationPolicy.nameIsInUse("another-group", organizations: organizations))
        XCTAssertFalse(DashboardOrganizationCreationPolicy.nameIsInUse("New Team", organizations: organizations))
        XCTAssertFalse(DashboardOrganizationCreationPolicy.nameIsInUse(" \n ", organizations: organizations))
    }

    func testCreationNormalizesUniqueInvitesAndReportsMalformedOrOversizedEmails() {
        XCTAssertEqual(
            DashboardOrganizationCreationPolicy.inviteEmails("First@Example.com, second@example.com\nfirst@example.com"),
            ["first@example.com", "second@example.com"]
        )
        XCTAssertEqual(
            DashboardOrganizationCreationPolicy.invalidInviteEmails("good@example.com, bad-address, ALSO@ok.test"),
            ["bad-address"]
        )
        XCTAssertEqual(
            DashboardOrganizationCreationPolicy.invalidInviteEmails("\(String(repeating: "a", count: 250))@example.com"),
            ["\(String(repeating: "a", count: 250))@example.com"]
        )
        XCTAssertTrue(DashboardOrganizationCreationPolicy.invalidInviteEmails(" , \n ").isEmpty)
    }
}
