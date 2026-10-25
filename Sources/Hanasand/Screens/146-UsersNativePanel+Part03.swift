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

extension UsersNativePanel {
    var selectedUserProfilePanel: some View {
        NativeGroupPanel(
            title: model.selectedUserProfile?.displayName ?? "User profile",
            subtitle: model.selectedUserProfileID
        ) {
            HStack {
                Spacer()
                Button("Back to users") { model.closeSelectedUserProfile() }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(theme.accent)
            }

            if model.isLoadingSelectedUserProfile {
                ProgressView("Loading user profile…")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(theme.textSecondary)
            } else if let user = model.selectedUserProfile {
                if !organizationNavigationStatus.isEmpty {
                    NativeNotice(message: organizationNavigationStatus, title: "Organization unavailable")
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 12)], alignment: .leading, spacing: 12) {
                    profileValue("User ID", user.id, symbol: "number")
                    profileValue("Username", user.username ?? "Not set", symbol: "at")
                    if !model.isProfileIdentityImpersonating {
                        profileValue("Email", user.email ?? "Not available", symbol: "envelope")
                    }
                    profileValue("Account status", user.active == false ? "Inactive" : "Active", symbol: "person.crop.circle")
                    profileValue("Created", user.createdAt ?? "Not available", symbol: "calendar")
                    profileValue("Last login", user.lastLoginAt ?? "Not available", symbol: "clock")
                    if let deletion = user.deletionScheduledAt {
                        profileValue("Deletion scheduled", deletion, symbol: "calendar.badge.exclamationmark")
                    }
                }

                if !user.organizations.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Organizations")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(theme.textSecondary)
                        ForEach(user.organizations) { organization in
                            HStack(spacing: 8) {
                                Image(systemName: "building.2")
                                    .foregroundStyle(theme.accent)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(organization.name)
                                        .font(.system(size: 12, weight: .bold))
                                        .foregroundStyle(theme.text)
                                    Text("\(organization.slug) · \(organization.status)")
                                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                                        .foregroundStyle(theme.textTertiary)
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(9)
                            .background(theme.cardRaised)
                            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                            if UsersNativePanelPresentation.canOpenOrganization(
                                organization,
                                as: model.users.first { $0.id == model.userIDForRequests },
                                isImpersonating: model.isImpersonatingForOrganizationSwitch
                            ) {
                                Button {
                                    openUserOrganization(organization)
                                } label: {
                                    Label("Open organization", systemImage: "arrow.up.right")
                                        .font(.system(size: 11, weight: .semibold))
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .foregroundStyle(theme.accent)
                                .accessibilityLabel("Open organization \(organization.name)")
                            }
                        }
                    }
                }
            } else {
                NativeEmptyState(
                    title: "Profile unavailable",
                    message: model.nativeDashboardStatus.isEmpty ? "The user profile could not be loaded. Refresh and try again." : model.nativeDashboardStatus
                )
            }
        }
    }

    private func openUserOrganization(_ organization: DashboardUserOrganization) {
        guard UsersNativePanelPresentation.canOpenOrganization(
            organization,
            as: model.users.first { $0.id == model.userIDForRequests },
            isImpersonating: model.isImpersonatingForOrganizationSwitch
        ) else { return }

        let profileID = model.selectedUserProfileID
        let accountID = model.userIDForRequests
        let sessionToken = model.authTokenForRequests
        organizationNavigationStatus = ""
        Task {
            let selected = await model.selectOrganizationFromDeepLink(organization.id)
            guard model.selectedUserProfileID == profileID,
                  model.userIDForRequests == accountID,
                  model.authTokenForRequests == sessionToken else { return }
            guard selected else {
                organizationNavigationStatus = model.organizationDirectoryError ?? "Refresh organizations and verify your active membership before opening this workspace."
                return
            }
            model.openNativeDashboard(path: "/organizations", label: organization.name)
        }
    }

    func profileValue(_ title: String, _ value: String, symbol: String) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(theme.accent)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 3) {
                Text(title.uppercased())
                    .font(.system(size: 9, weight: .black))
                    .foregroundStyle(theme.textTertiary)
                Text(value)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(theme.text)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.cardRaised)
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
    }
}
