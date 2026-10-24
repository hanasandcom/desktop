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
    private func organizationDirectoryClient() throws -> OrganizationDirectoryClient {
        try OrganizationDirectoryClient(settings: settings)
    }

    private func applyOrganizationDirectory(_ snapshot: DashboardOrganizationDirectorySnapshot, accountID: String) {
        organizationDirectory = snapshot.organizations
        organizationMemberships = snapshot.memberships
        organizationDirectorySnapshotUserID = isImpersonatingForOrganizationSwitch ? "" : accountID
    }

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

    @discardableResult
    func selectOrganizationFromDeepLink(_ organizationID: String) async -> Bool {
        guard hasHanasandAuth, !isImpersonatingForOrganizationSwitch,
              !organizationID.isEmpty, organizationID != "personal" else { return false }
        let accountID = userIDForRequests
        let sessionToken = authTokenForRequests
        do {
            let snapshot = try await organizationDirectoryClient().loadSnapshot()
            guard accountID == userIDForRequests, sessionToken == authTokenForRequests,
                  !isImpersonatingForOrganizationSwitch else { return false }
            applyOrganizationDirectory(snapshot, accountID: accountID)
            guard snapshot.organizations.contains(where: { $0.id == organizationID && $0.status == "active" }),
                  snapshot.memberships.contains(where: { $0.id == organizationID && $0.status == "active" }) else {
                organizationDirectoryError = "This link targets an organization without an active membership."
                return false
            }
            settings.selectedOrganizationID = organizationID
            settings.selectedOrganizationUserID = accountID
            organizationDirectoryError = nil
            return true
        } catch {
            organizationDirectoryError = error.localizedDescription
            organizationDirectorySnapshotUserID = ""
            return false
        }
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
            let snapshot = try await organizationDirectoryClient().loadSnapshot()
            guard organizationDirectoryLoadID == loadID,
                  selectedDashboardPath == "/organizations",
                  accountID == userIDForRequests,
                  sessionToken == authTokenForRequests else { return }
            applyOrganizationDirectory(snapshot, accountID: accountID)
            if !isImpersonatingForOrganizationSwitch,
               settings.selectedOrganizationUserID == accountID,
               !settings.selectedOrganizationID.isEmpty,
               !snapshot.memberships.contains(where: { $0.id == settings.selectedOrganizationID && $0.status == "active" }) {
                usePersonalWorkspace()
            }
        } catch {
            guard organizationDirectoryLoadID == loadID,
                  selectedDashboardPath == "/organizations",
                  accountID == userIDForRequests else { return }
            if case OrganizationDirectoryClientError.requestFailed(401, _) = error {
                organizationDirectoryError = "Your session could not be verified. Sign in again."
            } else if case OrganizationDirectoryClientError.requestFailed(403, _) = error {
                organizationDirectoryError = "Your account cannot access its organization memberships."
            } else if case OrganizationDirectoryClientError.requestFailed(429, _) = error {
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
            // Re-read the organization list and the caller's active memberships before switching.
            let snapshot = try await organizationDirectoryClient().loadSnapshot()
            guard organizationDirectoryLoadID == loadID,
                  selectedDashboardPath == "/organizations",
                  accountID == userIDForRequests,
                  sessionToken == authTokenForRequests,
                  !isImpersonatingForOrganizationSwitch else { return }

            let target = snapshot.organizations.first { $0.id == organization.id }
            let membership = snapshot.memberships.first { $0.id == organization.id }
            guard let target, target.status == "active", membership?.status == "active" else {
                applyOrganizationDirectory(snapshot, accountID: accountID)
                organizationDirectoryError = "This organization is no longer available through an active membership. Refresh to review access."
                return
            }

            settings.selectedOrganizationID = target.id
            settings.selectedOrganizationUserID = accountID
            applyOrganizationDirectory(snapshot, accountID: accountID)
        } catch {
            organizationDirectoryError = error.localizedDescription
            organizationDirectorySnapshotUserID = ""
        }
    }

    func createOrganization(named name: String) async {
        guard hasHanasandAuth else {
            organizationDirectoryError = "Sign in to create an organization."
            return
        }
        guard !isImpersonatingForOrganizationSwitch else {
            organizationDirectoryError = "Return to your own account before creating an organization."
            return
        }
        guard !isLoadingOrganizationDirectory else { return }

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
            let client = try organizationDirectoryClient()
            let createdID = try await client.createOrganization(name: name)
            guard organizationDirectoryLoadID == loadID,
                  selectedDashboardPath == "/organizations",
                  accountID == userIDForRequests,
                  sessionToken == authTokenForRequests,
                  !isImpersonatingForOrganizationSwitch else { return }

            let snapshot = try await client.loadSnapshot()
            guard organizationDirectoryLoadID == loadID,
                  selectedDashboardPath == "/organizations",
                  accountID == userIDForRequests,
                  sessionToken == authTokenForRequests,
                  !isImpersonatingForOrganizationSwitch else { return }
            applyOrganizationDirectory(snapshot, accountID: accountID)

            guard let created = snapshot.organizations.first(where: { $0.id == createdID }),
                  created.status == "active",
                  snapshot.memberships.contains(where: { $0.id == createdID && $0.status == "active" }) else {
                organizationDirectoryError = "The organization was created, but its active membership could not be verified. Refresh before selecting it."
                return
            }

            settings.selectedOrganizationID = created.id
            settings.selectedOrganizationUserID = accountID
        } catch {
            guard organizationDirectoryLoadID == loadID,
                  selectedDashboardPath == "/organizations",
                  accountID == userIDForRequests else { return }
            organizationDirectoryError = error.localizedDescription
        }
    }

    func usePersonalWorkspace() {
        settings.selectedOrganizationID = ""
        settings.selectedOrganizationUserID = ""
        organizationDirectoryError = nil
    }

}
