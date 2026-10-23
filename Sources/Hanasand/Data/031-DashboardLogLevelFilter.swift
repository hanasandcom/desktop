import Foundation

enum DashboardLogLevelFilter {
    static let options = ["all", "critical", "high", "fatal", "error", "warn", "info", "debug"]

    static func matches(level: String, filter: String) -> Bool {
        let normalizedLevel = level.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let normalizedFilter = filter.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        switch normalizedFilter {
        case "", "all":
            return true
        case "high":
            return normalizedLevel == "high" || normalizedLevel == "critical"
        case "warn":
            return normalizedLevel == "warn" || normalizedLevel == "warning"
        default:
            return normalizedLevel == normalizedFilter
        }
    }
}
