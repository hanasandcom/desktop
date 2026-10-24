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
