import Foundation

struct DashboardMonitoringOverview: Decodable, Equatable {
    struct WatchTerm: Decodable, Equatable {
        let value: String
        let kind: String
    }

    struct Evidence: Decodable, Equatable {
        let sourceName: String
        let observedAt: String?
        let firstSeenAt: String?
        let provenance: Provenance?

        struct Provenance: Decodable, Equatable {
            let collectedAt: String?
        }

        var latestTimestamp: String? { provenance?.collectedAt ?? observedAt ?? firstSeenAt }
    }

    struct Alert: Decodable, Equatable {
        let reviewState: String
        let firstSeenAt: String
        let evidence: [Evidence]
    }

    struct SourceCoverage: Decodable, Equatable {
        let family: String
        let label: String
        let sourceCount: Int
        let activeCount: Int
        let health: String
        let detail: String
    }

    struct Readiness: Decodable, Equatable {
        let decision: String
        let blockers: [String]
    }

    let schemaVersion: String
    let generatedAt: String
    let tenantId: String
    let watchlist: [WatchTerm]
    let alerts: [Alert]
    let sourceCoverage: [SourceCoverage]
    let readiness: Readiness

    var openAlertCount: Int {
        alerts.filter { !["closed", "resolved", "false_positive", "suppressed"].contains($0.reviewState.lowercased()) }.count
    }

    var recentMatchCount: Int {
        let cutoff = Date().addingTimeInterval(-7 * 24 * 60 * 60)
        return alerts.filter { Self.date(from: $0.firstSeenAt).map { $0 >= cutoff } ?? false }.count
    }

    var latestEvidence: Evidence? {
        alerts.flatMap(\.evidence).max { left, right in
            let leftDate = left.latestTimestamp.flatMap(Self.date(from:))
            let rightDate = right.latestTimestamp.flatMap(Self.date(from:))
            if let leftDate, let rightDate { return leftDate < rightDate }
            return (left.latestTimestamp ?? "") < (right.latestTimestamp ?? "")
        }
    }

    var healthySourceCount: Int { sourceCoverage.filter { $0.health == "healthy" }.count }
    var isReady: Bool { readiness.decision == "production_ready_with_live_sources" }

    static func date(from value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value) ?? {
            formatter.formatOptions = [.withInternetDateTime]
            return formatter.date(from: value)
        }()
    }
}

struct DashboardMonitoringOverviewState: Equatable {
    let snapshot: DashboardMonitoringOverview?
    let openCaseCount: Int?
    let isLoading: Bool
    let errorMessage: String?
    let casesErrorMessage: String?

    static let loading = Self(snapshot: nil, openCaseCount: nil, isLoading: true, errorMessage: nil, casesErrorMessage: nil)
}

enum DashboardMonitoringOverviewError: LocalizedError, Equatable {
    case signInRequired
    case invalidCredentials
    case impersonationUnsupported
    case invalidEndpoint
    case invalidResponse
    case requestFailed(Int)
    case scopeChanged

    var errorDescription: String? {
        switch self {
        case .signInRequired: "Sign in to view monitoring overview."
        case .invalidCredentials: "Sign in again to view monitoring overview."
        case .impersonationUnsupported: "Return to your own account to view monitoring overview."
        case .invalidEndpoint: "Monitoring overview requires a secure Hanasand service address."
        case .invalidResponse: "The monitoring service returned data that could not be verified."
        case .requestFailed(401): "Sign in again to access monitoring overview."
        case .requestFailed(403): "Current organization access could not be verified."
        case .requestFailed(let status): "Monitoring overview failed (HTTP \(status))."
        case .scopeChanged: "The workspace changed while monitoring overview was loading. Refresh to try again."
        }
    }
}
