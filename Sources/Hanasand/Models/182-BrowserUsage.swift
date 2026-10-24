import Foundation

struct BrowserUsage: Equatable {
    let plan: String
    let runsToday: Int
    let activeRuns: Int
    let dailyLimit: Int?
    let concurrentLimit: Int?
    let paid: Bool
    let advancedAnalysis: Bool

    var runCountLabel: String {
        dailyLimit.map { "\(runsToday) / \($0) runs today" } ?? "\(runsToday) runs today"
    }

    var concurrencyLabel: String {
        concurrentLimit.map { "\(activeRuns) / \($0) active" } ?? "\(activeRuns) active"
    }
}

struct BrowserGlobalStats: Equatable {
    let runs24h: Int
    let darkwebRuns24h: Int
}

enum BrowserUsageLoadState: Equatable {
    case loading
    case ready(BrowserUsage)
    case signedOut
    case unavailable(String)
}

enum BrowserGlobalStatsLoadState: Equatable {
    case loading
    case ready(BrowserGlobalStats)
    case unavailable(String)
}

enum BrowserUsageError: LocalizedError, Equatable {
    case signInRequired
    case invalidEndpoint
    case invalidCredentials
    case invalidResponse
    case responseTooLarge
    case requestFailed(Int)

    var errorDescription: String? {
        switch self {
        case .signInRequired: "Sign in to view Browser usage."
        case .invalidEndpoint: "Browser usage requires a valid HTTPS API address."
        case .invalidCredentials: "The current account credentials are invalid. Sign in again."
        case .invalidResponse: "The Browser usage service returned invalid usage data."
        case .responseTooLarge: "The Browser usage response exceeded its size limit."
        case .requestFailed(401): "Sign in again to view Browser usage."
        case .requestFailed(403): "Your account cannot view Browser usage."
        case .requestFailed(let status): "Browser usage could not be loaded (HTTP \(status))."
        }
    }
}

enum BrowserGlobalStatsError: LocalizedError, Equatable {
    case invalidEndpoint
    case invalidResponse
    case responseTooLarge
    case requestFailed(Int)

    var errorDescription: String? {
        switch self {
        case .invalidEndpoint: "Aggregate Browser statistics require a valid HTTPS API address."
        case .invalidResponse: "The aggregate Browser statistics response was invalid."
        case .responseTooLarge: "The aggregate Browser statistics response exceeded its size limit."
        case .requestFailed(let status): "Aggregate Browser statistics could not be loaded (HTTP \(status))."
        }
    }
}
