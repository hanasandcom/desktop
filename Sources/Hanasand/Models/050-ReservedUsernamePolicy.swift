import Foundation

enum ReservedUsernamePolicy {
    static let usernames: Set<String> = [
        "abuse", "admin", "administrator", "billing", "bookkeeper", "cdc", "ceo", "cfo", "chairman",
        "compliance", "contact", "controller", "coo", "cto", "director", "eirikhanasand", "executive",
        "facebook", "finance", "google", "hanasand", "help", "hr", "legal", "management", "manager",
        "meta", "microsoft", "noreply", "owner", "paypal", "postmaster", "president", "root", "security",
        "soc", "spam", "staff", "support", "sysadmin", "treasurer", "trust", "twitter", "x",
    ]

    static func normalizedSignupUsername(_ username: String) -> String {
        username.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    static func isReservedPlaceholder(id: String, username: String?, active: Bool?) -> Bool {
        guard active == false else { return false }
        return usernames.contains(id.lowercased())
            || usernames.contains((username ?? "").lowercased())
    }
}
