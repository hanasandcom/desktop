import XCTest
@testable import Hanasand

final class OrganizationMemberTests: XCTestCase {
    func testDecodesMemberEmailAndPendingInviteCopyLinkFields() throws {
        let members = #"{"organization":{"id":"org-one","name":"Example","lifecycleStatus":"active","role":"owner"},"members":[{"organizationId":"org-one","userId":"owner-1","name":"Owner","email":"owner@example.com","role":"owner","status":"active","joinedAt":"2026-10-22T12:00:00Z"}]}"#.data(using: .utf8)!
        let invites = #"{"invites":[{"id":"invite-1","email":"person@example.com","role":"reader","status":"pending","expiresAt":"2026-11-05T12:00:00Z","acceptanceUrl":"https://hanasand.test/invite/opaque"}]}"#.data(using: .utf8)!

        let memberPage = try JSONDecoder().decode(DashboardOrganizationMembersEnvelope.self, from: members)
        let invite = try JSONDecoder().decode(DashboardOrganizationInvitesEnvelope.self, from: invites).invites[0]

        XCTAssertEqual(memberPage.members[0].userId, "owner-1")
        XCTAssertEqual(memberPage.members[0].email, "owner@example.com")
        XCTAssertEqual(memberPage.organization.role, "owner")
        XCTAssertEqual(invite.id, "invite-1")
        XCTAssertEqual(invite.status, "pending")
        XCTAssertEqual(invite.acceptanceUrl, "https://hanasand.test/invite/opaque")

        let legacyMember = #"{"organizationId":"org-one","userId":"member-1","name":"Member","role":"reader","status":"active"}"#.data(using: .utf8)!
        XCTAssertNil(try JSONDecoder().decode(DashboardOrganizationMember.self, from: legacyMember).email)
    }

    func testManagementRequiresOwnActiveSelectedMembershipAndNoImpersonation() {
        let allowed = DashboardOrganizationMemberPolicy.canManage(
            actorID: "user-1", signedInUserID: "user-1", selectedOrganizationID: "org-1",
            organizationID: "org-1", lifecycleStatus: "active", actorRole: "admin",
            actorMembershipStatus: "active", isAuthenticated: true, isImpersonating: false
        )
        XCTAssertTrue(allowed)
        XCTAssertFalse(DashboardOrganizationMemberPolicy.canManage(
            actorID: "user-1", signedInUserID: "user-2", selectedOrganizationID: "org-1",
            organizationID: "org-1", lifecycleStatus: "active", actorRole: "owner",
            actorMembershipStatus: "active", isAuthenticated: true, isImpersonating: false
        ))
        XCTAssertFalse(DashboardOrganizationMemberPolicy.canManage(
            actorID: "user-1", signedInUserID: "user-1", selectedOrganizationID: "org-1",
            organizationID: "org-1", lifecycleStatus: "active", actorRole: "owner",
            actorMembershipStatus: "active", isAuthenticated: true, isImpersonating: true
        ))
        XCTAssertFalse(DashboardOrganizationMemberPolicy.canManage(
            actorID: "user-1", signedInUserID: "user-1", selectedOrganizationID: "org-1",
            organizationID: "org-1", lifecycleStatus: "active", actorRole: "owner",
            actorMembershipStatus: "removed", isAuthenticated: true, isImpersonating: false
        ))
    }

    func testAdminCanOnlyInviteAndChangeEditorOrReaderRoles() {
        XCTAssertTrue(DashboardOrganizationMemberPolicy.canManageTarget(actorRole: "admin", targetRole: "", requestedRole: "admin", action: "invite"))
        XCTAssertTrue(DashboardOrganizationMemberPolicy.canManageTarget(actorRole: "admin", targetRole: "reader", requestedRole: "editor", action: "role"))
        XCTAssertFalse(DashboardOrganizationMemberPolicy.canManageTarget(actorRole: "admin", targetRole: "admin", requestedRole: "reader", action: "role"))
        XCTAssertFalse(DashboardOrganizationMemberPolicy.canManageTarget(actorRole: "admin", targetRole: "editor", requestedRole: "admin", action: "role"))
        XCTAssertFalse(DashboardOrganizationMemberPolicy.canManageTarget(actorRole: "admin", targetRole: "admin", action: "remove"))
        XCTAssertTrue(DashboardOrganizationMemberPolicy.canManageTarget(actorRole: "owner", targetRole: "owner", requestedRole: "admin", action: "role"))
    }

    func testInviteEmailNormalizationAndValidation() {
        let emails = normalizedOrganizationInviteEmails(" Person@example.com,person@example.com\nother@example.org ")
        XCTAssertEqual(emails, ["person@example.com", "other@example.org"])
        XCTAssertTrue(emails.allSatisfy(isValidOrganizationInviteEmail))
        XCTAssertFalse(isValidOrganizationInviteEmail("not an email"))
    }
}
