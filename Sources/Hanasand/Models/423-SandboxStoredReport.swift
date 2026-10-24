import Foundation

struct SandboxStoredReport: Identifiable {
    let id: String
    let target: String
    let finalURL: String
    let status: String
    let exportedAt: String
    let verdict: String
    let summary: String
    let indicators: [String]
    let recommendedActions: [String]
    let threatAssociations: [SandboxStoredReportLine]
    let timeline: [SandboxStoredReportLine]
    let providers: [SandboxStoredReportLine]
    let evidence: [SandboxStoredReportLine]
    let captures: [SandboxStoredReportCapture]
    let networkEvidence: [SandboxStoredReportLine]
    let scriptArtifacts: [SandboxStoredReportLine]
    let consoleEvents: [String]
    let availableRuns: [SandboxStoredReportRun]
}

struct SandboxStoredReportCapture: Identifiable {
    let id: String
    let title: String
    let url: String
    let capturedAt: String
    let reason: String
    let imageDataURL: String
    let textExcerpt: String
    let sourceCode: String
}

struct SandboxStoredReportLine: Identifiable {
    let id: String
    let title: String
    let detail: String
}

struct SandboxStoredReportRun: Identifiable, Equatable {
    let id: String
    let status: String
    let startedAt: String
}

enum SandboxStoredReportLimits {
    static let responseBytes = 16_000_000
    static let maximumItems = 500
    static let fieldBytes = 16_000
    static let idBytes = 128
}

enum SandboxStoredReportError: LocalizedError, Equatable {
    case signInRequired
    case ownAccountRequired
    case invalidBaseURL
    case invalidRoute
    case invalidCredentials
    case invalidResponse
    case responseTooLarge
    case requestFailed(Int)

    var errorDescription: String? {
        switch self {
        case .signInRequired: "Sign in to view this saved Sandbox report. Shareable reports can be opened with their report link."
        case .ownAccountRequired: "Return to your own account to view this Sandbox report."
        case .invalidBaseURL: "Sandbox reports require a valid secure browser API address."
        case .invalidRoute: "This Sandbox report link is missing a valid run or result identifier."
        case .invalidCredentials: "The current account credentials are invalid. Sign in again."
        case .invalidResponse: "The Sandbox report service returned an invalid response."
        case .responseTooLarge: "The Sandbox report exceeded the safe response size limit."
        case .requestFailed(401): "Sign in again to view this Sandbox report."
        case .requestFailed(403): "The current account cannot view this Sandbox report."
        case .requestFailed(404): "This Sandbox report was not found or is no longer available."
        case .requestFailed: "The Sandbox report is unavailable. Refresh to try again."
        }
    }
}
