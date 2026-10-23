import Foundation

struct SandboxHistoryRun: Identifiable, Equatable {
    let id: String
    let resultID: String
    let target: String
    let network: String
    let status: String
    let startedAt: String

    var displayTarget: String { target.isEmpty ? "Untitled target" : target }
}

struct SandboxHistoryPage: Equatable {
    let runs: [SandboxHistoryRun]
    let nextOffset: Int?
}

enum SandboxHistoryLimits {
    static let pageSize = 50
    static let responseBytes = 1 * 1024 * 1024
    static let maximumPages = 200
    static let identifierLength = 128
    static let targetLength = 2_000
    static let fieldLength = 100
}

enum SandboxHistoryError: LocalizedError, Equatable {
    case signInRequired
    case ownAccountRequired
    case invalidBaseURL
    case invalidCredentials
    case invalidOffset
    case invalidResponse
    case responseTooLarge
    case requestFailed(Int)

    var errorDescription: String? {
        switch self {
        case .signInRequired: "Sign in to view saved Sandbox runs."
        case .ownAccountRequired: "Return to your own account to view saved Sandbox runs."
        case .invalidBaseURL: "Saved Sandbox runs require a valid HTTPS API address."
        case .invalidCredentials: "The current account credentials are invalid. Sign in again."
        case .invalidOffset: "The Sandbox history page could not be loaded. Refresh and try again."
        case .invalidResponse: "The Sandbox history service returned an invalid response."
        case .responseTooLarge: "The Sandbox history response exceeded its size limit."
        case .requestFailed(401): "Sign in again to view saved Sandbox runs."
        case .requestFailed(403): "Current account does not have access to these Sandbox runs."
        case .requestFailed: "Saved Sandbox runs are unavailable. Refresh to try again."
        }
    }
}
