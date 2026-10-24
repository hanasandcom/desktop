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

private struct PendingOrganizationMemberChange: Identifiable {
    let member: DashboardOrganizationMember
    let action: String
    let role: String?
    var id: String { "\(action):\(member.userId)" }
}

private struct PendingOrganizationInviteRevoke: Identifiable {
    let invite: DashboardOrganizationInvite
    var id: String { invite.id }
}

struct OrganizationMembersNativePanel: View {
    @EnvironmentObject private var model: DesktopAgentModel
    @Environment(\.desktopTheme) private var theme
    @State private var memberFilters = OrganizationMemberFiltering()
    @State private var pendingMemberChange: PendingOrganizationMemberChange?
    @State private var pendingInviteRevoke: PendingOrganizationInviteRevoke?

    private var filteredMembers: [DashboardOrganizationMember] {
        memberFilters.matching(model.organizationMembersPage?.members ?? [])
    }

    private var loadedMembers: [DashboardOrganizationMember] {
        model.organizationMembersPage?.members ?? []
    }

    private var memberRoles: [String] {
        OrganizationMemberFiltering.countsByRole(in: loadedMembers).keys.sorted()
    }

    private var memberStatuses: [String] {
        OrganizationMemberFiltering.countsByStatus(in: loadedMembers).keys.sorted()
    }

    private var filteredInvites: [DashboardOrganizationInvite] {
        let query = memberFilters.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return model.organizationInvites }
        return model.organizationInvites.filter {
            $0.email.localizedCaseInsensitiveContains(query)
                || $0.role.localizedCaseInsensitiveContains(query)
                || $0.status.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        NativeGroupPanel(title: "Team and invitations", subtitle: model.organizationMembersPage?.organization.name ?? "Selected organization") {
            HStack(spacing: 8) {
                ActionButton(title: "Refresh", icon: "arrow.clockwise") { Task { await model.loadOrganizationMembers() } }
                    .disabled(model.isLoadingOrganizationMembers || model.isMutatingOrganizationMembers || model.selectedOrganizationID.isEmpty)
                if model.isLoadingOrganizationMembers { ProgressView().controlSize(.small) }
            }

            if !model.organizationMembersStatus.isEmpty {
                Text(model.organizationMembersStatus)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(theme.textSecondary)
                    .textSelection(.enabled)
            }

            if model.selectedOrganizationID.isEmpty {
                NativeEmptyState(title: "Select an organization", message: "Select an active membership in the organization directory to view its team.")
            } else if model.isLoadingOrganizationMembers && model.organizationMembersPage == nil {
                NativeEmptyState(title: "Loading team", message: "Verifying current organization membership.")
            } else if let page = model.organizationMembersPage {
                SearchFieldRow(placeholder: "Search members and invitations", text: $memberFilters.searchText)
                memberFilterControls
                HStack(spacing: 6) {
                    Text("Showing \(filteredMembers.count) of \(loadedMembers.count) members")
                    if memberFilters.hasActiveFilters {
                        Button("Clear filters") { memberFilters = OrganizationMemberFiltering() }
                            .buttonStyle(.link)
                    }
                }
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(theme.textSecondary)
                if filteredMembers.isEmpty {
                    NativeEmptyState(
                        title: loadedMembers.isEmpty ? "No active members" : "No matching members",
                        message: loadedMembers.isEmpty ? "This organization has no active members to display." : "No members match the current search and filters. Clear filters or try another search."
                    )
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: 12, alignment: .top)], alignment: .leading, spacing: 12) {
                        ForEach(filteredMembers) { member in memberCard(member, actorRole: page.organization.role ?? "") }
                    }
                }

                if model.organizationMembersCanManage {
                    inviteComposer
                    NativeGroupPanel(title: "Pending invitations", subtitle: "Pending invites expire automatically after 14 days") {
                        if filteredInvites.isEmpty {
                            NativeEmptyState(
                                title: model.organizationInvites.isEmpty ? "No pending invitations" : "No matching invitations",
                                message: model.organizationInvites.isEmpty ? "Invitations that have been accepted, revoked, or expired are not listed here." : "Try another search."
                            )
                        } else {
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: 12, alignment: .top)], alignment: .leading, spacing: 12) {
                                ForEach(filteredInvites) { invite in inviteCard(invite) }
                            }
                        }
                    }
                } else {
                    NativeNotice(message: "Only an active organization owner or admin can manage invitations and member access.", tone: .info)
                }
            } else {
                NativeEmptyState(title: "Team unavailable", message: model.organizationMembersStatus.isEmpty ? "Refresh to verify active organization membership." : model.organizationMembersStatus)
            }
        }
        .task(id: model.selectedOrganizationID) { await model.loadOrganizationMembers() }
        .onChange(of: model.selectedOrganizationID) { _, _ in
            memberFilters.role = "all"
            memberFilters.status = "all"
        }
        .confirmationDialog(memberChangeTitle, isPresented: Binding(get: { pendingMemberChange != nil }, set: { if !$0 { pendingMemberChange = nil } }), titleVisibility: .visible) {
            if let change = pendingMemberChange {
                Button(change.action == "remove" ? "Remove member" : "Change role", role: .destructive) {
                    pendingMemberChange = nil
                    if change.action == "remove" { Task { await model.removeOrganizationMember(change.member) } }
                    else if let role = change.role { Task { await model.updateOrganizationMemberRole(change.member, role: role) } }
                }
                Button("Cancel", role: .cancel) { pendingMemberChange = nil }
            }
        } message: { Text(memberChangeMessage) }
        .confirmationDialog("Revoke invitation?", isPresented: Binding(get: { pendingInviteRevoke != nil }, set: { if !$0 { pendingInviteRevoke = nil } }), titleVisibility: .visible) {
            if let pendingInviteRevoke {
                Button("Revoke invitation", role: .destructive) {
                    let invite = pendingInviteRevoke.invite
                    self.pendingInviteRevoke = nil
                    Task { await model.actOnOrganizationInvite(invite, action: "revoke") }
                }
                Button("Cancel", role: .cancel) { self.pendingInviteRevoke = nil }
            }
        } message: { Text(pendingInviteRevoke?.invite.email ?? "") }
    }

    private var memberFilterControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            filterRow(title: "Role", values: memberRoles, counts: OrganizationMemberFiltering.countsByRole(in: loadedMembers), selection: $memberFilters.role)
            filterRow(title: "Status", values: memberStatuses, counts: OrganizationMemberFiltering.countsByStatus(in: loadedMembers), selection: $memberFilters.status)
        }
    }

    private func filterRow(title: String, values: [String], counts: [String: Int], selection: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.system(size: 10, weight: .semibold)).foregroundStyle(theme.textSecondary)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), alignment: .leading)], alignment: .leading, spacing: 6) {
                FilterChip(title: "All (\(loadedMembers.count))", active: selection.wrappedValue == "all") { selection.wrappedValue = "all" }
                ForEach(values, id: \.self) { value in
                    FilterChip(title: "\(value.capitalized) (\(counts[value] ?? 0))", active: selection.wrappedValue == value) {
                        selection.wrappedValue = value
                    }
                }
            }
        }
    }

    private var memberChangeTitle: String {
        pendingMemberChange?.action == "remove" ? "Remove organization member?" : "Change member role?"
    }

    private var memberChangeMessage: String {
        guard let pendingMemberChange else { return "" }
        let label = pendingMemberChange.member.name.isEmpty ? pendingMemberChange.member.userId : pendingMemberChange.member.name
        if pendingMemberChange.action == "remove" { return "Remove \(label) from this organization? Their active membership and organization access will end." }
        return "Change \(label)'s role to \(pendingMemberChange.role ?? "")? This changes their organization permissions."
    }

    private var inviteComposer: some View {
        NativeGroupPanel(title: "Invite members", subtitle: "Enter up to 25 email addresses; invitations are valid for 14 days") {
            TextField("name@example.com, another@example.com", text: $model.organizationInviteEmailDraft, axis: .vertical)
                .lineLimit(2...4)
                .textFieldStyle(.roundedBorder)
            Picker("Role", selection: $model.organizationInviteRoleDraft) {
                ForEach(inviteRoles, id: \.self) { role in Text(role.capitalized).tag(role) }
            }
            .pickerStyle(.segmented)
            HStack(spacing: 8) {
                ActionButton(title: model.isMutatingOrganizationMembers ? "Sending…" : "Send invitations", icon: "paperplane") {
                    Task { await model.inviteOrganizationMembers() }
                }
                .disabled(model.isMutatingOrganizationMembers || normalizedOrganizationInviteEmails(model.organizationInviteEmailDraft).isEmpty
                          || !DashboardOrganizationMemberPolicy.canManageTarget(actorRole: currentActorRole, targetRole: "", requestedRole: model.organizationInviteRoleDraft, action: "invite"))
            }
        }
    }

    private var currentActorRole: String {
        model.organizationMembersPage?.organization.role
            ?? model.organizationMembersPage?.members.first(where: { $0.userId == model.userIDForRequests })?.role
            ?? ""
    }

    private var inviteRoles: [String] {
        ["admin", "editor", "reader"]
    }

    @ViewBuilder
    private func memberCard(_ member: DashboardOrganizationMember, actorRole: String) -> some View {
        NativeGroupPanel(title: member.name.isEmpty ? member.userId : member.name,
                         subtitle: "\(member.role.capitalized) · \(member.status.capitalized)") {
            Text(member.userId)
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(theme.textTertiary)
                .textSelection(.enabled)
            if let email = member.email, !email.isEmpty {
                Text(email).font(.system(size: 10, weight: .medium)).foregroundStyle(theme.textSecondary).textSelection(.enabled)
            }
            if let joinedAt = member.joinedAt, !joinedAt.isEmpty {
                Text("Joined \(joinedAt)").font(.system(size: 10)).foregroundStyle(theme.textSecondary)
            }
            if model.organizationMembersCanManage {
                HStack(spacing: 7) {
                    Menu("Change role") {
                        ForEach(rolesAssignable(by: actorRole, to: member.role), id: \.self) { role in
                            Button(role.capitalized) { pendingMemberChange = PendingOrganizationMemberChange(member: member, action: "role", role: role) }
                                .disabled(role == member.role.lowercased() || model.isMutatingOrganizationMembers)
                        }
                    }
                    .menuStyle(.borderlessButton)
                    .disabled(rolesAssignable(by: actorRole, to: member.role).isEmpty || model.isMutatingOrganizationMembers)
                    ActionButton(title: "Remove", icon: "person.crop.circle.badge.minus") {
                        pendingMemberChange = PendingOrganizationMemberChange(member: member, action: "remove", role: nil)
                    }
                    .disabled(!DashboardOrganizationMemberPolicy.canManageTarget(actorRole: actorRole, targetRole: member.role, action: "remove") || model.isMutatingOrganizationMembers)
                }
            }
        }
    }

    private func inviteCard(_ invite: DashboardOrganizationInvite) -> some View {
        NativeGroupPanel(title: invite.email, subtitle: "\(invite.role.capitalized) · Pending") {
            if let expiresAt = invite.expiresAt, !expiresAt.isEmpty {
                Text("Expires \(expiresAt)").font(.system(size: 10)).foregroundStyle(theme.textSecondary)
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 7) { inviteActions(invite) }
                VStack(alignment: .leading, spacing: 7) { inviteActions(invite) }
            }
        }
    }

    @ViewBuilder private func inviteActions(_ invite: DashboardOrganizationInvite) -> some View {
                if [invite.acceptanceUrl, invite.acceptancePath, invite.token].contains(where: { !($0 ?? "").isEmpty }) {
                    ActionButton(title: "Copy link", icon: "doc.on.doc") { copyInviteLink(invite) }
                        .disabled(model.isMutatingOrganizationMembers || invite.status != "pending")
                }
                ActionButton(title: "Resend", icon: "paperplane") { Task { await model.actOnOrganizationInvite(invite, action: "resend") } }
                    .disabled(model.isMutatingOrganizationMembers)
                ActionButton(title: "Revoke", icon: "xmark.circle", tone: .danger) { pendingInviteRevoke = PendingOrganizationInviteRevoke(invite: invite) }
                    .disabled(model.isMutatingOrganizationMembers)
    }

    private func copyInviteLink(_ invite: DashboardOrganizationInvite) {
        guard invite.status == "pending", let link = validatedInviteLink(invite) else {
            model.organizationMembersStatus = "This invitation link is unavailable. Refresh invitations before copying."
            return
        }
        NSPasteboard.general.clearContents()
        guard NSPasteboard.general.setString(link, forType: .string) else {
            model.organizationMembersStatus = "Could not copy the invitation link."
            return
        }
        model.organizationMembersStatus = "Invitation link copied for \(invite.email)."
    }

    private func validatedInviteLink(_ invite: DashboardOrganizationInvite) -> String? {
        let base = model.settings.websiteBaseURL.normalizedBaseURL
        if let raw = invite.acceptanceUrl, let url = URL(string: raw), url.scheme?.lowercased() == "https",
           url.host?.lowercased() == base.host?.lowercased(), url.user == nil, url.password == nil,
           url.fragment == nil { return url.absoluteString }
        if let path = invite.acceptancePath, path.hasPrefix("/"), !path.hasPrefix("//"), !path.contains("\\"),
           !path.split(separator: "/").contains(".."), let url = URL(string: path, relativeTo: base) {
            return url.absoluteURL.absoluteString
        }
        if let token = invite.token, !token.isEmpty, token.range(of: "^[A-Za-z0-9._~-]{1,4096}$", options: .regularExpression) != nil {
            return token
        }
        return nil
    }

    private func rolesAssignable(by actorRole: String, to targetRole: String) -> [String] {
        guard targetRole.lowercased() != "owner" else { return [] }
        if actorRole.lowercased() == "owner" { return ["admin", "editor", "reader"] }
        return ["editor", "reader"].contains(targetRole.lowercased()) ? ["editor", "reader"] : []
    }
}
