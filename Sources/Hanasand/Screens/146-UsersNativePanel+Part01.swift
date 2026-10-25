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

enum UsersNativePanelPresentation {
    static func canOpenOrganization(
        _ organization: DashboardUserOrganization,
        as actor: DashboardUser?,
        isImpersonating: Bool
    ) -> Bool {
        guard !isImpersonating, organization.status == "active", let actor, actor.active == true else { return false }
        return actor.organizations.contains { $0.id == organization.id && $0.status == "active" }
    }

    static func organizationSummary(_ organizations: [DashboardUserOrganization]) -> String {
        guard !organizations.isEmpty else { return "No organization memberships" }
        let details = organizations.map { organization in
            organization.status.isEmpty ? organization.name : "\(organization.name) · \(organization.status)"
        }
        return "\(organizations.count) \(organizations.count == 1 ? "organization" : "organizations") · "
            + details.joined(separator: ", ")
    }
}

extension UsersNativePanel {

    var columns: [GridItem] {
        [GridItem(.adaptive(minimum: 220), spacing: 12, alignment: .top)]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 14) {
                    Label("\(model.users.count) users", systemImage: "person.2")
                    Label("\(model.users.filter { $0.active != false }.count) active", systemImage: "checkmark.circle")
                    Label("\(model.users.filter { $0.active == false }.count) inactive", systemImage: "person.crop.circle.badge.xmark")
                    Label("\(model.users.filter(\.isReservedPlaceholder).count) reserved", systemImage: "person.crop.circle.badge.questionmark")
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 118), alignment: .leading)], alignment: .leading, spacing: 8) {
                    Label("\(model.users.count) users", systemImage: "person.2")
                    Label("\(model.users.filter { $0.active != false }.count) active", systemImage: "checkmark.circle")
                    Label("\(model.users.filter { $0.active == false }.count) inactive", systemImage: "person.crop.circle.badge.xmark")
                    Label("\(model.users.filter(\.isReservedPlaceholder).count) reserved", systemImage: "person.crop.circle.badge.questionmark")
                }
            }
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(theme.textSecondary)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) {
                    SearchFieldRow(placeholder: "Filter users by name, username, email, id, or role", text: $searchText)
                    reservedUsersToggle
                }
                VStack(alignment: .leading, spacing: 8) {
                    SearchFieldRow(placeholder: "Filter users by name, username, email, id, or role", text: $searchText)
                    reservedUsersToggle
                }
            }

            if model.users.isEmpty {
                NativeEmptyState(title: "No users loaded", message: "Use Refresh from this dashboard or configure auth in Settings to load user administration data.")
            } else {
                LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
                    ForEach(filteredUsers) { user in
                        VStack(alignment: .leading, spacing: 10) {
                            HStack(spacing: 10) {
                                Image(systemName: user.active == false ? "person.crop.circle.badge.xmark" : "person.crop.circle")
                                    .font(.system(size: 17, weight: .bold))
                                    .foregroundStyle(user.active == false ? theme.danger : theme.accent)
                                    .frame(width: 38, height: 38)
                                    .background(theme.cardRaised)
                                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(user.displayName)
                                        .font(.system(size: 14, weight: .black))
                                        .foregroundStyle(theme.text)
                                        .lineLimit(2)
                                        .fixedSize(horizontal: false, vertical: true)
                                    Text("@\(user.displayUsername) · \(user.id)")
                                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                        .foregroundStyle(theme.textTertiary)
                                        .lineLimit(2)
                                        .textSelection(.enabled)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                Text(user.active == false ? "Inactive" : "Active")
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundStyle(user.active == false ? theme.danger : theme.green)
                                    .fixedSize()
                            }
                            Text("\(user.roleLabel) · Priority \(user.highestRolePriority.map(String.init) ?? "unknown")")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(theme.textSecondary)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                            userDirectoryMetadata(user)
                            Menu {
                                Button("Open profile", systemImage: "person.crop.circle") {
                                    model.openUserProfile(user)
                                }
                                Button("Roles", systemImage: "person.badge.key") {
                                    model.selectDashboardUser(user)
                                }
                                if user.id != model.userIDForRequests {
                                    Button("Impersonate", systemImage: "person.crop.circle.badge.arrowtrianglehead.counterclockwise") {
                                        impersonationReason = ""
                                        impersonationReasonError = ""
                                        pendingImpersonationUser = user
                                    }
                                }
                                Divider()
                                Button(user.active == false ? "Activate" : "Deactivate",
                                       systemImage: user.active == false ? "checkmark.circle" : "person.crop.circle.badge.xmark") {
                                    pendingStatusUser = user
                                }
                                Button("Schedule deletion", systemImage: "trash", role: .destructive) {
                                    pendingDeleteUser = user
                                }
                            } label: {
                                Label("User actions", systemImage: "ellipsis.circle")
                                    .font(.system(size: 12, weight: .semibold))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .contentShape(Rectangle())
                            }
                            .menuStyle(.borderlessButton)
                            .help("Open profile, manage roles, or review account actions")
                        }
                        .padding(13)
                        .background(theme.card)
                        .overlay(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .stroke(theme.divider, lineWidth: 1)
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                }
            }

            if let selectedUser {
                userRolesPanel(selectedUser)
            }
            if !model.selectedUserProfileID.isEmpty {
                selectedUserProfilePanel
            }
        }
        .task(id: model.selectedUserID) {
            await model.loadSelectedUserRoles()
        }
        .task(id: model.selectedUserProfileID) {
            organizationNavigationStatus = ""
            await model.loadSelectedUserProfile()
        }
        .alert(statusAlertTitle, isPresented: Binding(
            get: { pendingStatusUser != nil },
            set: { if !$0 { pendingStatusUser = nil } }
        )) {
            Button("Cancel", role: .cancel) {
                pendingStatusUser = nil
            }
            Button(statusActionTitle, role: pendingStatusUser?.active == false ? nil : .destructive) {
                if let pendingStatusUser {
                    Task { await model.setDashboardUser(pendingStatusUser, active: pendingStatusUser.active == false) }
                }
                pendingStatusUser = nil
            }
        } message: {
            Text(pendingStatusUser?.active == false ? "This will reactivate the selected account." : "This will deactivate the account and revoke its active sessions.")
        }
        .alert("Schedule user deletion?", isPresented: Binding(
            get: { pendingDeleteUser != nil },
            set: { if !$0 { pendingDeleteUser = nil } }
        )) {
            Button("Cancel", role: .cancel) {
                pendingDeleteUser = nil
            }
            Button("Schedule deletion", role: .destructive) {
                if let pendingDeleteUser {
                    Task { await model.deleteDashboardUser(pendingDeleteUser) }
                }
                pendingDeleteUser = nil
            }
        } message: {
            Text("This revokes access for \(pendingDeleteUser?.displayName ?? "the selected user") now and schedules account deletion in 30 days. The deletion must be confirmed by the server before it is reported as scheduled.")
        }
        .sheet(item: $pendingImpersonationUser, onDismiss: {
            impersonationReason = ""
            impersonationReasonError = ""
        }) { user in
            impersonationPrompt(user)
        }
    }

    func userDirectoryMetadata(_ user: DashboardUser) -> some View {
        let created = "Created \(formatDateText(user.createdAt, fallback: "Not recorded"))"
        let lastLogin = "Last login \(formatDateText(user.lastLoginAt, fallback: "Not recorded"))"
        return VStack(alignment: .leading, spacing: 5) {
            Text(user.email?.isEmpty == false ? user.email! : "Email not available")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(theme.textSecondary)
                .lineLimit(2)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Text(UsersNativePanelPresentation.organizationSummary(user.organizations))
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(theme.textSecondary)
                .lineLimit(2)
                .help(UsersNativePanelPresentation.organizationSummary(user.organizations))
                .fixedSize(horizontal: false, vertical: true)
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 10) {
                    Label(created, systemImage: "calendar")
                    Label(lastLogin, systemImage: "clock")
                }
                VStack(alignment: .leading, spacing: 4) {
                    Label(created, systemImage: "calendar")
                    Label(lastLogin, systemImage: "clock")
                }
            }
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(theme.textTertiary)
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private var reservedUsersToggle: some View {
        if model.users.contains(where: \.isReservedPlaceholder) {
            Toggle("Reserved", isOn: $showReserved)
                .toggleStyle(.button)
                .help(showReserved ? "Hide reserved placeholder accounts" : "Show reserved placeholder accounts")
        }
    }

    var selectedUser: DashboardUser? {
        model.users.first { $0.id == model.selectedUserID }
    }

    var statusAlertTitle: String {
        pendingStatusUser?.active == false ? "Activate user?" : "Deactivate user?"
    }

    var statusActionTitle: String {
        pendingStatusUser?.active == false ? "Activate" : "Deactivate"
    }

    func normalizedImpersonationReason(_ value: String) -> String {
        value.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    func impersonationPrompt(_ user: DashboardUser) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Start impersonation")
                    .font(.system(size: 18, weight: .black))
                    .foregroundStyle(theme.text)
                Text("Provide an audit reason before viewing \(user.displayName).")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(theme.textSecondary)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Reason")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(theme.textSecondary)
                TextEditor(text: $impersonationReason)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(theme.text)
                    .frame(minHeight: 96)
                    .scrollContentBackground(.hidden)
                    .background(theme.cardRaised)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(theme.divider, lineWidth: 1)
                    )
                HStack(alignment: .top) {
                    Text("Required for audit. Minimum 10 characters. Starts a 30 minute profile and organization session.")
                    Spacer()
                    Text("\(normalizedImpersonationReason(impersonationReason).count)/10")
                }
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(theme.textTertiary)
            }

            if !impersonationReasonError.isEmpty {
                Text(impersonationReasonError)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(theme.danger)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(theme.danger.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }

            HStack {
                Spacer()
                Button("Cancel") {
                    pendingImpersonationUser = nil
                }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(theme.textSecondary)

                Button("Start session") {
                    let reason = normalizedImpersonationReason(impersonationReason)
                    guard reason.count >= 10 else {
                        impersonationReasonError = "Enter at least 10 characters so the audit trail explains why this session is needed."
                        return
                    }
                    model.impersonateDashboardUser(user, reason: reason)
                    pendingImpersonationUser = nil
                }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .black))
                .foregroundStyle(theme.accent)
            }
        }
        .padding(18)
        .frame(width: 420)
        .background(theme.background)
    }
}
