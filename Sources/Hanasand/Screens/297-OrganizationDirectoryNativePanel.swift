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

struct OrganizationDirectoryNativePanel: View {
    @EnvironmentObject var model: DesktopAgentModel
    @Environment(\.desktopTheme) var theme
    @State private var searchText = ""

    private var filteredOrganizations: [DashboardDirectoryOrganization] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return model.organizationDirectory }
        return model.organizationDirectory.filter {
            $0.name.localizedCaseInsensitiveContains(query)
                || $0.slug.localizedCaseInsensitiveContains(query)
                || $0.status.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "building.2")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(theme.accent)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Organization directory")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(theme.text)
                    Text("Directory visibility does not grant organization membership.")
                        .font(.system(size: 12))
                        .foregroundStyle(theme.textSecondary)
                }
                Spacer()
                if model.isLoadingOrganizationDirectory {
                    ProgressView().controlSize(.small)
                } else {
                    Button("Refresh") { Task { await model.loadOrganizationDirectory() } }
                        .buttonStyle(.bordered)
                }
            }

            if model.isImpersonatingForOrganizationSwitch {
                NativeNotice(message: "Return to your own account before switching organizations.", tone: .info)
            }
            if let error = model.organizationDirectoryError {
                NativeNotice(message: error, title: "Organizations unavailable")
            }
            if model.isImpersonatingForOrganizationSwitch {
                Label("Workspace selection is paused during impersonation", systemImage: "person.crop.circle.badge.exclam")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(theme.textSecondary)
            } else if !model.selectedOrganizationID.isEmpty {
                HStack(spacing: 10) {
                    Label("Current workspace: \(model.selectedOrganizationName ?? model.selectedOrganizationID)", systemImage: "building.2.crop.circle")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(theme.text)
                    Spacer()
                    Button("Use personal workspace") { model.usePersonalWorkspace() }
                        .buttonStyle(.plain)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(theme.accent)
                }
                .padding(12)
                .background(theme.card)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            } else {
                Label("Current workspace: Personal", systemImage: "person.crop.circle")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(theme.textSecondary)
            }

            if model.organizationDirectorySnapshotUserID != model.userIDForRequests {
                NativeNotice(message: "Refresh to verify current memberships before switching.", tone: .info)
            }

            SearchFieldRow(placeholder: "Search organizations by name, slug, or status", text: $searchText)

            if model.isLoadingOrganizationDirectory && model.organizationDirectory.isEmpty {
                NativeEmptyState(title: "Loading organizations", message: "Checking directory visibility and your active memberships.")
            } else if model.organizationDirectory.isEmpty {
                NativeEmptyState(title: "No organizations loaded", message: "Refresh the directory or check that your account has organization administrator access.")
            } else if filteredOrganizations.isEmpty {
                NativeEmptyState(title: "No matches", message: "No organizations match this search.")
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: 12, alignment: .top)], alignment: .leading, spacing: 12) {
                    ForEach(filteredOrganizations) { organization in
                        organizationCard(organization)
                    }
                }
            }

            if !model.selectedOrganizationID.isEmpty {
                OrganizationMembersNativePanel()
            }
        }
        .task(id: model.selectedDashboardPath) {
            await model.loadOrganizationDirectory()
        }
    }

    @ViewBuilder
    private func organizationCard(_ organization: DashboardDirectoryOrganization) -> some View {
        let member = model.organizationMemberships.first { $0.id == organization.id && $0.status == "active" }
        let current = model.selectedOrganizationID == organization.id
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(organization.name)
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(theme.text)
                        .lineLimit(2)
                    Text(organization.slug.isEmpty ? organization.id : organization.slug)
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(theme.textTertiary)
                        .textSelection(.enabled)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                Text(organization.status.capitalized)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(organization.status == "active" ? theme.green : theme.textTertiary)
            }

            Text("\(organization.memberCount.map(String.init) ?? "Unavailable") active members")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(theme.textSecondary)

            if current {
                Label("Current workspace", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(theme.green)
            } else if member != nil && model.canSwitchToOrganization(organization) {
                Button("Switch to \(organization.name)") {
                    Task { await model.selectOrganization(organization) }
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.isLoadingOrganizationDirectory)
            } else if organization.status != "active" {
                Text("This organization is not active.")
                    .font(.system(size: 11))
                    .foregroundStyle(theme.textTertiary)
            } else {
                Text("No verified active membership for switching.")
                    .font(.system(size: 11))
                    .foregroundStyle(theme.textTertiary)
            }
        }
        .padding(13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.card)
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(theme.divider, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}
