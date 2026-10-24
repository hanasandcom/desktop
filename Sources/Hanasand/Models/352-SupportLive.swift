import Foundation

enum SupportLiveStatus: Equatable {
    case idle
    case connecting
    case live
    case reconnecting
    case refreshAccess
    case unavailable

    var title: String {
        switch self {
        case .idle: "Live updates are not active."
        case .connecting: "Connecting to live updates…"
        case .live: "Live updates connected."
        case .reconnecting: "Reconnecting to live updates…"
        case .refreshAccess: "Refresh access to reconnect live updates."
        case .unavailable: "Live updates are unavailable. Refresh to check for changes."
        }
    }
}

enum SupportLiveProtocol {
    static func socketURL(apiBaseURL: String) throws -> URL {
        guard var parts = URLComponents(string: apiBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)),
              parts.scheme?.lowercased() == "https", parts.host != nil,
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil else {
            throw SupportLiveError.invalidEndpoint
        }
        let basePath = parts.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        parts.scheme = "wss"
        parts.path = "/" + [basePath, "ws", "support"].filter { !$0.isEmpty }.joined(separator: "/")
        guard let url = parts.url, url.scheme == "wss", url.host == URLComponents(string: apiBaseURL)?.host,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else {
            throw SupportLiveError.invalidEndpoint
        }
        return url
    }

    static func originHeader(websiteBaseURL: String) throws -> String {
        guard let parts = URLComponents(string: websiteBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)),
              parts.scheme?.lowercased() == "https", let host = parts.host?.lowercased(),
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
              parts.port == nil || parts.port == 443,
              host == "hanasand.com" || host == "www.hanasand.com" else {
            throw SupportLiveError.invalidEndpoint
        }
        return "https://\(host)"
    }

    static func authFrame(userID: String, token: String, impersonationToken: String = "") throws -> String {
        guard !userID.isEmpty, userID.utf8.count <= 200, !token.isEmpty, token.utf8.count <= 512,
              impersonationToken.utf8.count <= 4096 else { throw SupportLiveError.invalidCredentials }
        var value: [String: String] = ["type": "auth", "id": userID, "token": token]
        if !impersonationToken.isEmpty { value["impersonationToken"] = impersonationToken }
        let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        guard let text = String(data: data, encoding: .utf8), text.utf8.count <= 4096 else {
            throw SupportLiveError.invalidCredentials
        }
        return text
    }

    static func frameType(_ text: String) throws -> String {
        guard text.utf8.count <= 1_048_576, let data = text.data(using: .utf8),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = object["type"] as? String else { throw SupportLiveError.invalidResponse }
        return type
    }
}

enum SupportLiveError: LocalizedError, Equatable {
    case invalidEndpoint, invalidCredentials, invalidResponse, socketUnavailable
    var errorDescription: String? {
        switch self {
        case .invalidEndpoint: "Support live updates require a secure service address."
        case .invalidCredentials: "Sign in again to receive Support live updates."
        case .invalidResponse: "The Support live connection returned an invalid response."
        case .socketUnavailable: "The Support live connection is unavailable."
        }
    }
}
