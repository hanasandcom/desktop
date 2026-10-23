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

extension DesktopAgentModel {
    var isImpersonatingForOrganizationSwitch: Bool {
        !settings.impersonationToken.isEmpty || !settings.impersonatingUserID.isEmpty
    }

    var selectedOrganizationName: String? {
        organizationDirectory.first(where: { $0.id == selectedOrganizationID })?.name
    }

    func canSwitchToOrganization(_ organization: DashboardDirectoryOrganization) -> Bool {
        DashboardOrganizationSwitchPolicy.canSwitch(
            organizationID: organization.id,
            organizationStatus: organization.status,
            membershipStatus: organizationMemberships.first { $0.id == organization.id }?.status,
            isAuthenticated: hasHanasandAuth,
            isOwnAccount: organizationDirectorySnapshotUserID == userIDForRequests,
            isImpersonating: isImpersonatingForOrganizationSwitch
        )
    }

    func loadOrganizationDirectory() async {
        guard !isLoadingOrganizationDirectory else { return }
        guard hasHanasandAuth else {
            organizationDirectory = []
            organizationMemberships = []
            organizationDirectorySnapshotUserID = ""
            organizationDirectoryError = "Sign in to view organizations."
            return
        }

        let loadID = UUID()
        let accountID = userIDForRequests
        let sessionToken = authTokenForRequests
        organizationDirectoryLoadID = loadID
        isLoadingOrganizationDirectory = true
        organizationDirectoryError = nil
        defer {
            if organizationDirectoryLoadID == loadID { isLoadingOrganizationDirectory = false }
        }

        do {
            let apiBase = settings.apiBaseURL.normalizedBaseURL
            let directory: DashboardDirectoryOrganizationsEnvelope = try await requestJSON(
                apiBase.appendingAPIPath("management/organizations"),
                authenticated: true
            )
            let memberships: DashboardOrganizationMembershipsEnvelope = try await requestJSON(
                organizationMembershipsURL(),
                authenticated: true
            )
            guard organizationDirectoryLoadID == loadID,
                  selectedDashboardPath == "/organizations",
                  accountID == userIDForRequests,
                  sessionToken == authTokenForRequests else { return }
            organizationDirectory = directory.organizations
            organizationMemberships = memberships.organizations
            organizationDirectorySnapshotUserID = isImpersonatingForOrganizationSwitch ? "" : accountID
            if !isImpersonatingForOrganizationSwitch,
               settings.selectedOrganizationUserID == accountID,
               !settings.selectedOrganizationID.isEmpty,
               !memberships.organizations.contains(where: { $0.id == settings.selectedOrganizationID && $0.status == "active" }) {
                usePersonalWorkspace()
            }
        } catch {
            guard organizationDirectoryLoadID == loadID,
                  selectedDashboardPath == "/organizations",
                  accountID == userIDForRequests else { return }
            if case DashboardRequestError.httpStatus(401) = error {
                organizationDirectoryError = "Your session could not be verified. Sign in again."
            } else if case DashboardRequestError.httpStatus(403) = error {
                organizationDirectoryError = "The organization directory requires Hanasand organization administrator access."
            } else if case DashboardRequestError.httpStatus(429) = error {
                organizationDirectoryError = "Too many organization requests. Wait, then refresh."
            } else {
                organizationDirectoryError = error.localizedDescription
            }
            organizationDirectorySnapshotUserID = ""
        }
    }

    func selectOrganization(_ organization: DashboardDirectoryOrganization) async {
        guard canSwitchToOrganization(organization) else {
            organizationDirectoryError = isImpersonatingForOrganizationSwitch
                ? "Return to your own account before switching organizations."
                : "Refresh the directory and verify an active membership before switching."
            return
        }

        let accountID = userIDForRequests
        let sessionToken = authTokenForRequests
        let loadID = UUID()
        organizationDirectoryLoadID = loadID
        isLoadingOrganizationDirectory = true
        organizationDirectoryError = nil
        defer {
            if organizationDirectoryLoadID == loadID { isLoadingOrganizationDirectory = false }
        }

        do {
            // Re-read both sources so directory visibility alone can never authorize a switch.
            let directory: DashboardDirectoryOrganizationsEnvelope = try await requestJSON(
                settings.apiBaseURL.normalizedBaseURL.appendingAPIPath("management/organizations"),
                authenticated: true
            )
            let memberships: DashboardOrganizationMembershipsEnvelope = try await requestJSON(
                organizationMembershipsURL(),
                authenticated: true
            )
            guard organizationDirectoryLoadID == loadID,
                  selectedDashboardPath == "/organizations",
                  accountID == userIDForRequests,
                  sessionToken == authTokenForRequests,
                  !isImpersonatingForOrganizationSwitch else { return }

            let target = directory.organizations.first { $0.id == organization.id }
            let membership = memberships.organizations.first { $0.id == organization.id }
            guard let target, target.status == "active", membership?.status == "active" else {
                organizationDirectory = directory.organizations
                organizationMemberships = memberships.organizations
                organizationDirectorySnapshotUserID = accountID
                organizationDirectoryError = "This organization is no longer available through an active membership. Refresh to review access."
                return
            }

            settings.selectedOrganizationID = target.id
            settings.selectedOrganizationUserID = accountID
            organizationDirectory = directory.organizations
            organizationMemberships = memberships.organizations
            organizationDirectorySnapshotUserID = accountID
        } catch {
            organizationDirectoryError = error.localizedDescription
            organizationDirectorySnapshotUserID = ""
        }
    }

    func usePersonalWorkspace() {
        settings.selectedOrganizationID = ""
        settings.selectedOrganizationUserID = ""
        organizationDirectoryError = nil
    }

    private func organizationMembershipsURL() -> URL {
        let configured = settings.apiBaseURL.normalizedBaseURL
        if configured.host?.lowercased() == "api.hanasand.com",
           let identityURL = URL(string: "https://identity.hanasand.com/api/organizations") {
            return identityURL
        }
        return configured.appendingAPIPath("organizations")
    }
}
