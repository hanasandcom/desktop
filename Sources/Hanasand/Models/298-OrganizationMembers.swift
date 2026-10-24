import Foundation

struct DashboardOrganizationMember: Decodable, Identifiable, Equatable {
    let organizationId: String
    let userId: String
    let name: String
    let email: String?
    let role: String
    let status: String
    let joinedAt: String?

    var id: String { userId }

    enum CodingKeys: String, CodingKey {
        case organizationId, userId, name, email, role, status, joinedAt
    }
}

struct DashboardOrganizationInvite: Decodable, Identifiable, Equatable {
    let id: String
    let email: String
    let role: String
    let status: String
    let expiresAt: String?
    let createdAt: String?
    let acceptanceUrl: String?
    let acceptancePath: String?
    let token: String?

    enum CodingKeys: String, CodingKey {
        case id, email, role, status, expiresAt, createdAt, acceptanceUrl, acceptancePath, token
    }
}

struct DashboardOrganizationMembersEnvelope: Decodable, Equatable {
    struct Organization: Decodable, Equatable {
        let id: String
        let name: String
        let lifecycleStatus: String
        let role: String?
    }

    let organization: Organization
    let members: [DashboardOrganizationMember]
}

struct DashboardOrganizationMembersList: Decodable {
    let members: [DashboardOrganizationMember]
}

struct DashboardOrganizationInvitesEnvelope: Decodable {
    let invites: [DashboardOrganizationInvite]
}

enum DashboardOrganizationMemberPolicy {
    static func canManage(actorID: String, signedInUserID: String, selectedOrganizationID: String,
                          organizationID: String, lifecycleStatus: String, actorRole: String?,
                          actorMembershipStatus: String?, isAuthenticated: Bool, isImpersonating: Bool) -> Bool {
        isAuthenticated && !isImpersonating && actorID == signedInUserID
            && !selectedOrganizationID.isEmpty && selectedOrganizationID == organizationID
            && lifecycleStatus == "active" && actorMembershipStatus == "active"
            && ["owner", "admin"].contains(actorRole?.lowercased() ?? "")
    }

    static func canManageTarget(actorRole: String, targetRole: String, requestedRole: String? = nil,
                                action: String) -> Bool {
        let actor = actorRole.lowercased()
        let target = targetRole.lowercased()
        let requested = requestedRole?.lowercased()
        guard ["owner", "admin"].contains(actor) else { return false }
        if action == "invite" { return requested.map { ["admin", "editor", "reader"].contains($0) } ?? false }
        if action == "role" {
            guard let requested, ["admin", "editor", "reader"].contains(requested) else { return false }
            if actor == "owner" { return true }
            return ["editor", "reader"].contains(target) && ["editor", "reader"].contains(requested)
        }
        if action == "remove" {
            return actor == "owner" || ["editor", "reader", "member", "viewer"].contains(target)
        }
        if action == "inviteAction" { return true }
        return false
    }
}
