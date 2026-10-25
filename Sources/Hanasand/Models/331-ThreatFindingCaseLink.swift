import Foundation

enum ThreatFindingCaseLink {
    static func url(siteBaseURL: String, caseID: String, alertID: String, organizationID: String?) -> URL? {
        guard isSafeIdentifier(caseID), isSafeIdentifier(alertID),
              let base = URLComponents(string: siteBaseURL),
              base.scheme?.lowercased() == "https", base.host != nil,
              base.user == nil, base.password == nil, base.query == nil, base.fragment == nil,
              let encodedCaseID = caseID.addingPercentEncoding(withAllowedCharacters: pathIdentifierCharacters) else {
            return nil
        }
        if let organizationID, !isSafeIdentifier(organizationID) { return nil }

        var destination = URLComponents()
        destination.scheme = base.scheme
        destination.host = base.host
        destination.port = base.port
        destination.percentEncodedPath = "/cases/\(encodedCaseID)"
        destination.queryItems = [
            organizationID.map { URLQueryItem(name: "organizationId", value: $0) },
            URLQueryItem(name: "alertId", value: alertID),
            URLQueryItem(name: "route", value: "alert_queue"),
        ].compactMap { $0 }
        return destination.url
    }

    private static let pathIdentifierCharacters = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    private static func isSafeIdentifier(_ value: String) -> Bool {
        value.range(of: "^[A-Za-z0-9_.:@-]{1,200}$", options: .regularExpression) != nil
            && value != "." && value != ".."
            && !value.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }
}
