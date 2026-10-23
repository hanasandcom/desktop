import Foundation

extension DesktopAgentModel {
    func loadThreatFindings(cursor: String? = nil) async throws -> ThreatFindingPage {
        guard hasHanasandAuth else { throw ThreatFindingsError.signIn }
        guard settings.impersonationToken.isEmpty, settings.impersonatingUserID.isEmpty else { throw ThreatFindingsError.impersonating }

        let userID = userIDForRequests.trimmingCharacters(in: .whitespacesAndNewlines)
        let rawSelection = settings.selectedOrganizationID
        let selected = selectedOrganizationID
        if !rawSelection.isEmpty, rawSelection != "personal", rawSelection != userID, selected != rawSelection {
            throw ThreatFindingsError.invalidWorkspace
        }
        let organizationID = rawSelection.isEmpty || rawSelection == "personal" || rawSelection == userID ? nil : selected
        let tenantID = organizationID ?? userID
        guard tenantID.isValidFindingWorkspaceID,
              organizationID == nil || organizationID!.isValidFindingWorkspaceID,
              cursor == nil || (!cursor!.isEmpty && cursor!.count <= 4096 && !cursor!.containsControlCharacters) else {
            throw ThreatFindingsError.invalidWorkspace
        }

        let site = settings.websiteBaseURL.normalizedBaseURL
        guard site.scheme?.lowercased() == "https", site.host != nil, site.user == nil, site.password == nil else {
            throw ThreatFindingsError.invalidWorkspace
        }
        var components = URLComponents(url: site.appendingAPIPath("api/findings/alerts"), resolvingAgainstBaseURL: false)
        var query = [URLQueryItem(name: "tenantId", value: tenantID), URLQueryItem(name: "limit", value: "50")]
        if let organizationID { query.append(URLQueryItem(name: "organizationId", value: organizationID)) }
        if let cursor { query.append(URLQueryItem(name: "cursor", value: cursor)) }
        components?.queryItems = query
        let page: ThreatFindingPage = try await requestJSON(components?.url ?? site.appendingAPIPath("api/findings/alerts"), authenticated: true)
        try page.validate(tenantID: tenantID, organizationID: organizationID, requestedCursor: cursor)
        return page
    }
}

private extension String {
    var containsControlCharacters: Bool { unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) } }
    var isValidFindingWorkspaceID: Bool {
        range(of: "^[A-Za-z0-9_.:@-]{1,200}$", options: .regularExpression) != nil && self != "." && self != ".." && !containsControlCharacters
    }
}
