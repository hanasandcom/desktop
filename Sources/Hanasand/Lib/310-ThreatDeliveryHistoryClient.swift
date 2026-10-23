import Foundation

struct ThreatDeliveryHistoryClient {
    private let settings: HanasandDesktopSettings
    private let organizationID: String
    private var send: (URLRequest) async throws -> (Data, URLResponse)

    init(settings: HanasandDesktopSettings,
         send: ((URLRequest) async throws -> (Data, URLResponse))? = nil) throws {
        guard !settings.userID.isEmpty, !settings.authToken.isEmpty else {
            throw ThreatDeliveryHistoryError.signInRequired
        }
        guard settings.userID.range(of: "^[A-Za-z0-9._-]{1,128}$", options: .regularExpression) != nil,
              settings.authToken.range(of: "^[A-Za-z0-9._~-]{1,4096}$", options: .regularExpression) != nil else {
            throw ThreatDeliveryHistoryError.invalidCredentials
        }
        let organizationID = settings.selectedOrganizationID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard ThreatDeliveryHistory.validID(organizationID), organizationID != "personal",
              organizationID != settings.userID,
              settings.selectedOrganizationUserID == settings.userID else {
            throw ThreatDeliveryHistoryError.organizationRequired
        }
        guard settings.impersonationToken.isEmpty && settings.impersonatingUserID.isEmpty else {
            throw ThreatDeliveryHistoryError.impersonationUnsupported
        }
        guard let base = URL(string: settings.apiBaseURL), base.scheme?.lowercased() == "https",
              base.host != nil, base.user == nil, base.password == nil,
              base.query == nil, base.fragment == nil else {
            throw ThreatDeliveryHistoryError.invalidBaseURL
        }
        self.settings = settings
        self.organizationID = organizationID
        self.send = send ?? { request in try await URLSession.shared.data(for: request) }
    }

    func load() async throws -> ThreatDeliveryHistory {
        guard var components = URLComponents(url: settings.apiBaseURL.normalizedBaseURL, resolvingAgainstBaseURL: false) else {
            throw ThreatDeliveryHistoryError.invalidBaseURL
        }
        let prefix = components.percentEncodedPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        components.percentEncodedPath = "/" + [prefix, "dwm/webhook-deliveries"].filter { !$0.isEmpty }.joined(separator: "/")
        components.queryItems = [URLQueryItem(name: "orgId", value: organizationID)]
        guard let url = components.url, url.scheme == "https", url.host == settings.apiBaseURL.normalizedBaseURL.host else {
            throw ThreatDeliveryHistoryError.invalidBaseURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 20
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.httpShouldHandleCookies = false
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        request.setValue("Bearer \(settings.authToken)", forHTTPHeaderField: "Authorization")
        request.setValue(settings.userID, forHTTPHeaderField: "id")

        let (data, response) = try await send(request)
        guard let response = response as? HTTPURLResponse else { throw ThreatDeliveryHistoryError.invalidResponse }
        guard (200..<300).contains(response.statusCode) else {
            throw ThreatDeliveryHistoryError.requestFailed(response.statusCode)
        }
        let envelope: Envelope
        do { envelope = try JSONDecoder().decode(Envelope.self, from: data) }
        catch { throw ThreatDeliveryHistoryError.invalidResponse }
        guard envelope.visibility.allowed,
              envelope.deliveries.count <= 100,
              Set(envelope.deliveries.map(\.id)).count == envelope.deliveries.count,
              envelope.deliveries.allSatisfy({
                  $0.orgId == organizationID && ThreatDeliveryHistory.validID($0.id)
                      && ThreatDeliveryHistory.validID($0.alertId)
                      && ThreatDeliveryHistory.validID($0.orgId)
              }) else { throw ThreatDeliveryHistoryError.organizationScopeChanged }
        return ThreatDeliveryHistory(deliveries: envelope.deliveries, organizationID: organizationID)
    }

    private struct Envelope: Decodable {
        struct Visibility: Decodable { let allowed: Bool }
        let deliveries: [ThreatDeliveryHistory.Attempt]
        let visibility: Visibility
    }
}

enum ThreatDeliveryHistoryError: LocalizedError {
    case signInRequired
    case invalidCredentials
    case organizationRequired
    case impersonationUnsupported
    case invalidBaseURL
    case invalidResponse
    case organizationScopeChanged
    case requestFailed(Int)

    var errorDescription: String? {
        switch self {
        case .signInRequired: "Sign in to review delivery history."
        case .invalidCredentials: "The signed-in session cannot be verified."
        case .organizationRequired: "Select an organization to review delivery history."
        case .impersonationUnsupported: "Return to your own account to review delivery history."
        case .invalidBaseURL: "Delivery history requires a secure API address."
        case .invalidResponse: "The delivery history response is invalid."
        case .organizationScopeChanged: "Delivery history did not match the selected organization. Refresh before continuing."
        case .requestFailed(let status) where status == 401: "Your session could not be verified. Sign in again."
        case .requestFailed(let status) where status == 403 || status == 404: "Delivery history is not available for this organization membership."
        case .requestFailed: "Delivery history is unavailable. Refresh to try again."
        }
    }
}
