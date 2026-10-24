import Foundation

extension DesktopAgentModel {
    func loadDwmActorDirectory(organizationID requestedOrganizationID: String) async throws -> DwmActorDirectoryPage {
        guard hasHanasandAuth else { throw DwmActorDirectoryError.signInRequired }
        guard settings.impersonationToken.isEmpty, settings.impersonatingUserID.isEmpty else {
            throw DwmActorDirectoryError.impersonationUnsupported
        }

        let userID = userIDForRequests.trimmingCharacters(in: .whitespacesAndNewlines)
        let organizationID = requestedOrganizationID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard DwmActorDirectoryPage.validWorkspaceID(userID),
              DwmActorDirectoryPage.validWorkspaceID(organizationID),
              settings.selectedOrganizationID == organizationID,
              settings.selectedOrganizationUserID == userID,
              selectedOrganizationID == organizationID else {
            throw DwmActorDirectoryError.invalidOrganization
        }

        let site = settings.websiteBaseURL.normalizedBaseURL
        guard site.scheme?.lowercased() == "https", site.host != nil, site.user == nil, site.password == nil else {
            throw DwmActorDirectoryError.invalidBaseURL
        }

        let requestedUserID = userID
        let requestedToken = authTokenForRequests
        var components = URLComponents(url: site.appendingAPIPath("api/findings/product"), resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "tenantId", value: organizationID),
            URLQueryItem(name: "organizationId", value: organizationID),
        ]
        let page: DwmActorDirectoryPage = try await requestJSON(
            components?.url ?? site.appendingAPIPath("api/findings/product"), authenticated: true)
        try page.validate(tenantID: organizationID)
        guard hasHanasandAuth,
              authTokenForRequests == requestedToken,
              userIDForRequests.trimmingCharacters(in: .whitespacesAndNewlines) == requestedUserID,
              settings.impersonationToken.isEmpty,
              settings.impersonatingUserID.isEmpty,
              settings.selectedOrganizationID == organizationID,
              settings.selectedOrganizationUserID == requestedUserID,
              selectedOrganizationID == organizationID else {
            throw DwmActorDirectoryError.scopeChanged
        }
        return page
    }
}
