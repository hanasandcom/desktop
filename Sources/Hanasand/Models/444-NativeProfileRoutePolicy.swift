import Foundation

enum NativeProfileRouteDestination: Equatable {
    case signedInAccount
    case publicProfile(userID: String)
}

enum NativeProfileRoutePolicy {
    static func destination(requestedUserID: String?, authenticatedUserID: String?) -> NativeProfileRouteDestination {
        guard let requested = normalized(requestedUserID) else { return .signedInAccount }
        guard let authenticated = normalized(authenticatedUserID),
              requested == authenticated else {
            return .publicProfile(userID: requested)
        }
        return .signedInAccount
    }

    private static func normalized(_ value: String?) -> String? {
        guard let value else { return nil }
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? nil : normalized
    }
}

enum NativeProfilePresentation {
    static func displayName(name: String?, username: String?, id: String, active: Bool?) -> String {
        let usernameOrID = nonempty(username) ?? id
        if active == false { return usernameOrID }
        return nonempty(name) ?? usernameOrID
    }

    private static func nonempty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }
}
