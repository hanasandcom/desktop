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
}
