import Foundation

struct PasswordCheckFile: Equatable, Identifiable {
    let file: String
    let count: Int
    let lineRanges: [ClosedRange<Int>]

    var id: String { file }
}

struct PasswordCheckResult: Equatable {
    let count: Int
    let files: [PasswordCheckFile]
}

enum PasswordCheckError: LocalizedError, Equatable {
    case invalidHash
    case insecureEndpoint
    case invalidResponse
    case httpStatus(Int)
    case unavailable

    var errorDescription: String? {
        switch self {
        case .invalidHash: return "Enter a complete 40-character SHA-1 hash."
        case .insecureEndpoint: return "Password checks require a secure API URL."
        case .invalidResponse: return "The password index returned an invalid response."
        case let .httpStatus(status): return "Password check failed with HTTP \(status). Try again."
        case .unavailable: return "Unable to check leaked-password records right now. Try again."
        }
    }
}
