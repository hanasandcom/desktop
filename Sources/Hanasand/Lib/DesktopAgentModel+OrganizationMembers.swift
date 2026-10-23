import AppKit
import ApplicationServices
import Combine
import CryptoKit
import Darwin
import Foundation
import Network
import PDFKit
import SwiftUI
import UniformTypeIdentifiers
import WebKit

private struct OrganizationMemberRoleWrite: Encodable {
    let role: String
    let reason: String
    let requestId: String
}

private struct OrganizationMemberRemoveWrite: Encodable {
    let reason: String
    let requestId: String
}

private struct OrganizationInviteCreateWrite: Encodable {
    let emails: [String]
    let role: String
    let requestId: String
}

private struct OrganizationInviteActionWrite: Encodable {
    let action: String
    let reason: String
    let requestId: String
}

private struct OrganizationMemberMutationReceipt: Decodable {
    struct Member: Decodable { let userId: String }
    let member: Member
}

private struct OrganizationInviteMutationReceipt: Decodable {
    struct Invite: Decodable { let id: String }
    struct Workflow: Decodable { let invitedCount: Int; let skippedCount: Int }
    let invite: Invite?
    let invites: [Invite]?
    let workflow: Workflow?
}

private enum OrganizationMemberError: LocalizedError {
    case scopeChanged
    case permissionChanged
    case targetChanged
    case unconfirmed
    case invalidEmail

    var errorDescription: String? {
        switch self {
        case .scopeChanged: return "Your account or selected organization changed. Refresh before continuing."
        case .permissionChanged: return "Active owner or admin access could not be verified. Refresh before continuing."
        case .targetChanged: return "This member or invitation changed. Refresh before continuing."
        case .unconfirmed: return "The server did not confirm the requested change. Refresh to review the current state."
        case .invalidEmail: return "Enter up to 25 valid email addresses, separated by commas or new lines."
        }
    }
}

extension DesktopAgentModel {
    var organizationMembersCanManage: Bool {
        guard let page = organizationMembersPage else { return false }
        let actor = page.members.first { $0.userId == userIDForRequests && $0.status == "active" }
        return DashboardOrganizationMemberPolicy.canManage(
            actorID: userIDForRequests, signedInUserID: userIDForRequests,
            selectedOrganizationID: selectedOrganizationID, organizationID: page.organization.id,
            lifecycleStatus: page.organization.lifecycleStatus,
            actorRole: page.organization.role ?? actor?.role,
            actorMembershipStatus: actor?.status, isAuthenticated: hasHanasandAuth,
            isImpersonating: isImpersonatingForOrganizationSwitch
        )
    }

    func loadOrganizationMembers() async {
        let organizationID = selectedOrganizationID
        guard hasHanasandAuth, !organizationID.isEmpty, !isImpersonatingForOrganizationSwitch else {
            organizationMembersPage = nil
            organizationInvites = []
            organizationMembersStatus = hasHanasandAuth ? "Return to your own account and select an active organization." : "Sign in to view organization members."
            return
        }

        let userID = userIDForRequests
        let token = authTokenForRequests
        isLoadingOrganizationMembers = true
        organizationMembersStatus = "Loading organization members…"
        defer { isLoadingOrganizationMembers = false }
        do {
            let page: DashboardOrganizationMembersEnvelope = try await requestJSON(
                organizationMembersURL(organizationID: organizationID, suffix: "members"), authenticated: true
            )
            guard organizationID == selectedOrganizationID, userID == userIDForRequests,
                  token == authTokenForRequests, !isImpersonatingForOrganizationSwitch,
                  page.organization.id == organizationID else { throw OrganizationMemberError.scopeChanged }
            organizationMembersPage = page
            guard organizationMembersCanManage else {
                organizationInvites = []
                organizationMembersStatus = "Members loaded. An organization owner or admin can view invitations and manage access."
                return
            }

            do {
                let envelope: DashboardOrganizationInvitesEnvelope = try await requestJSON(
                    organizationMembersURL(organizationID: organizationID, suffix: "invites"), authenticated: true
                )
                guard organizationID == selectedOrganizationID, userID == userIDForRequests,
                      token == authTokenForRequests, !isImpersonatingForOrganizationSwitch else { throw OrganizationMemberError.scopeChanged }
                organizationInvites = envelope.invites
                organizationMembersStatus = "Loaded \(page.members.count) members and \(envelope.invites.count) pending invitations."
            } catch {
                organizationInvites = []
                organizationMembersStatus = "Members loaded, but invitations could not be loaded: \(error.localizedDescription)"
            }
        } catch {
            organizationMembersPage = nil
            organizationInvites = []
            organizationMembersStatus = "Could not load organization members: \(error.localizedDescription)"
        }
    }

    func inviteOrganizationMembers() async {
        let emails = normalizedOrganizationInviteEmails(organizationInviteEmailDraft)
        guard !emails.isEmpty, emails.count <= 25, emails.allSatisfy(isValidOrganizationInviteEmail) else {
            organizationMembersStatus = OrganizationMemberError.invalidEmail.localizedDescription
            return
        }
        guard !isMutatingOrganizationMembers else { return }
        isMutatingOrganizationMembers = true
        defer { isMutatingOrganizationMembers = false }
        do {
            let organizationID = try await freshManageableOrganization(action: "invite", role: organizationInviteRoleDraft)
            let body = try JSONEncoder().encode(OrganizationInviteCreateWrite(
                emails: emails, role: organizationInviteRoleDraft,
                requestId: "desktop-org-invite-\(UUID().uuidString.lowercased())"
            ))
            let receipt: OrganizationInviteMutationReceipt = try await requestJSON(
                organizationMembersURL(organizationID: organizationID, suffix: "invites"),
                method: "POST", body: body, authenticated: true
            )
            guard receipt.invites != nil else { throw OrganizationMemberError.unconfirmed }
            organizationInviteEmailDraft = ""
            await loadOrganizationMembers()
            if organizationMembersPage != nil {
                let invited = receipt.workflow?.invitedCount ?? receipt.invites?.count ?? 0
                let skipped = receipt.workflow?.skippedCount ?? 0
                organizationMembersStatus = skipped == 0 ? "Invited \(invited) people." : "Invited \(invited); skipped \(skipped) recipients already ineligible or members."
            }
        } catch {
            organizationMembersStatus = "Could not send invitations: \(error.localizedDescription)"
        }
    }

    func updateOrganizationMemberRole(_ member: DashboardOrganizationMember, role: String) async {
        guard !isMutatingOrganizationMembers else { return }
        isMutatingOrganizationMembers = true
        defer { isMutatingOrganizationMembers = false }
        do {
            let organizationID = try await freshManageableOrganization(action: "role", targetUserID: member.userId, targetRole: member.role, role: role)
            let body = try JSONEncoder().encode(OrganizationMemberRoleWrite(
                role: role, reason: "Organization member role updated from Hanasand Desktop.",
                requestId: "desktop-org-role-\(UUID().uuidString.lowercased())"
            ))
            let receipt: OrganizationMemberMutationReceipt = try await requestJSON(
                organizationMembersURL(organizationID: organizationID, suffix: "members/\(encodedOrganizationPath(member.userId))/role"),
                method: "PATCH", body: body, authenticated: true
            )
            guard receipt.member.userId == member.userId else { throw OrganizationMemberError.unconfirmed }
            await loadOrganizationMembers()
            if organizationMembersPage != nil { organizationMembersStatus = "Member role updated." }
        } catch {
            organizationMembersStatus = "Could not update member role: \(error.localizedDescription)"
        }
    }

    func removeOrganizationMember(_ member: DashboardOrganizationMember) async {
        guard !isMutatingOrganizationMembers else { return }
        isMutatingOrganizationMembers = true
        defer { isMutatingOrganizationMembers = false }
        do {
            let organizationID = try await freshManageableOrganization(action: "remove", targetUserID: member.userId, targetRole: member.role)
            let body = try JSONEncoder().encode(OrganizationMemberRemoveWrite(
                reason: "Organization member removed from Hanasand Desktop.",
                requestId: "desktop-org-remove-\(UUID().uuidString.lowercased())"
            ))
            let receipt: OrganizationMemberMutationReceipt = try await requestJSON(
                organizationMembersURL(organizationID: organizationID, suffix: "members/\(encodedOrganizationPath(member.userId))"),
                method: "DELETE", body: body, authenticated: true
            )
            guard receipt.member.userId == member.userId else { throw OrganizationMemberError.unconfirmed }
            await loadOrganizationMembers()
            if organizationMembersPage != nil { organizationMembersStatus = "Member removed." }
        } catch {
            organizationMembersStatus = "Could not remove member: \(error.localizedDescription)"
        }
    }

    func actOnOrganizationInvite(_ invite: DashboardOrganizationInvite, action: String) async {
        guard ["resend", "revoke"].contains(action), invite.status == "pending",
              !isMutatingOrganizationMembers else { return }
        isMutatingOrganizationMembers = true
        defer { isMutatingOrganizationMembers = false }
        do {
            let userID = userIDForRequests
            let token = authTokenForRequests
            let organizationID = try await freshManageableOrganization(action: "inviteAction")
            let freshInvites: DashboardOrganizationInvitesEnvelope = try await requestJSON(
                organizationMembersURL(organizationID: organizationID, suffix: "invites"), authenticated: true
            )
            guard organizationID == selectedOrganizationID, userID == userIDForRequests,
                  token == authTokenForRequests, !isImpersonatingForOrganizationSwitch else { throw OrganizationMemberError.scopeChanged }
            guard let current = freshInvites.invites.first(where: { $0.id == invite.id && $0.status == "pending" }),
                  current.email.caseInsensitiveCompare(invite.email) == .orderedSame else { throw OrganizationMemberError.targetChanged }
            _ = try await freshManageableOrganization(action: "inviteAction")
            guard organizationID == selectedOrganizationID, userID == userIDForRequests,
                  token == authTokenForRequests, !isImpersonatingForOrganizationSwitch else { throw OrganizationMemberError.scopeChanged }
            let body = try JSONEncoder().encode(OrganizationInviteActionWrite(
                action: action,
                reason: action == "resend" ? "Invitation resent from Hanasand Desktop." : "Access no longer required.",
                requestId: "desktop-org-invite-\(action)-\(UUID().uuidString.lowercased())"
            ))
            let receipt: OrganizationInviteMutationReceipt = try await requestJSON(
                organizationMembersURL(organizationID: organizationID, suffix: "invites/\(encodedOrganizationPath(invite.id))/actions"),
                method: "POST", body: body, authenticated: true
            )
            guard receipt.invite?.id == invite.id else { throw OrganizationMemberError.unconfirmed }
            await loadOrganizationMembers()
            if organizationMembersPage != nil { organizationMembersStatus = action == "resend" ? "Invitation resent." : "Invitation revoked." }
        } catch {
            organizationMembersStatus = "Could not \(action) invitation: \(error.localizedDescription)"
        }
    }

    private func freshManageableOrganization(action: String, targetUserID: String? = nil,
                                             targetRole: String? = nil, role: String? = nil) async throws -> String {
        let organizationID = selectedOrganizationID
        let userID = userIDForRequests
        let token = authTokenForRequests
        guard hasHanasandAuth, !organizationID.isEmpty, !isImpersonatingForOrganizationSwitch else { throw OrganizationMemberError.scopeChanged }
        let fresh: DashboardOrganizationMembersEnvelope = try await requestJSON(
            organizationMembersURL(organizationID: organizationID, suffix: "members"), authenticated: true
        )
        guard organizationID == selectedOrganizationID, userID == userIDForRequests,
              token == authTokenForRequests, !isImpersonatingForOrganizationSwitch,
              fresh.organization.id == organizationID else { throw OrganizationMemberError.scopeChanged }
        let actor = fresh.members.first { $0.userId == userID && $0.status == "active" }
        let actorRole = fresh.organization.role ?? actor?.role
        guard DashboardOrganizationMemberPolicy.canManage(
            actorID: userID, signedInUserID: userID,
            selectedOrganizationID: organizationID, organizationID: fresh.organization.id,
            lifecycleStatus: fresh.organization.lifecycleStatus, actorRole: actorRole,
            actorMembershipStatus: actor?.status, isAuthenticated: hasHanasandAuth,
            isImpersonating: isImpersonatingForOrganizationSwitch
        ) else { throw OrganizationMemberError.permissionChanged }

        if let targetUserID, let targetRole {
            guard let target = fresh.members.first(where: { $0.userId == targetUserID && $0.status == "active" }),
                  target.role.caseInsensitiveCompare(targetRole) == .orderedSame,
                  DashboardOrganizationMemberPolicy.canManageTarget(actorRole: actorRole ?? "", targetRole: target.role, requestedRole: role, action: action) else {
                throw OrganizationMemberError.targetChanged
            }
        } else if !DashboardOrganizationMemberPolicy.canManageTarget(actorRole: actorRole ?? "", targetRole: "", requestedRole: role, action: action) {
            throw OrganizationMemberError.permissionChanged
        }

        guard userID == userIDForRequests, token == authTokenForRequests,
              organizationID == selectedOrganizationID, !isImpersonatingForOrganizationSwitch else { throw OrganizationMemberError.scopeChanged }
        return organizationID
    }

    private func organizationMembersURL(organizationID: String, suffix: String) -> URL {
        settings.websiteBaseURL.normalizedBaseURL.appendingAPIPath(
            "api/organizations/\(encodedOrganizationPath(organizationID))/\(suffix)"
        )
    }
}

func normalizedOrganizationInviteEmails(_ value: String) -> [String] {
    var seen = Set<String>()
    return value.split(whereSeparator: { $0 == "," || $0.isNewline })
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        .filter { !$0.isEmpty && seen.insert($0).inserted }
}

func isValidOrganizationInviteEmail(_ email: String) -> Bool {
    let pattern = #"^[^\s@]+@[^\s@]+\.[^\s@]+$"#
    return email.range(of: pattern, options: .regularExpression) != nil
}

private func encodedOrganizationPath(_ value: String) -> String {
    let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._:@")
    return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
}
