import Foundation

struct NativeVMConnection: Equatable {
    let vmName: String
    let ipAddress: String
    let username: String
    let sshCommand: String?
    let certificateCount: Int
}

struct NativeVMHostOptions: Equatable {
    let vmName: String
    let primaryHost: String?
    let standbyHost: String?
    let failoverPremium: Bool
    let failoverEnabled: Bool
}

struct NativeVMFailoverReceipt: Equatable {
    let hostOptions: NativeVMHostOptions
    let message: String
}

enum NativeVMAccessError: LocalizedError, Equatable {
    case signInRequired
    case impersonationUnsupported
    case invalidEndpoint
    case invalidVMName
    case invalidPassword
    case invalidResponse
    case responseTooLarge
    case accessDenied
    case requestFailed(Int)
    case uncertainOutcome

    var errorDescription: String? {
        switch self {
        case .signInRequired: "Sign in to view VM access details."
        case .impersonationUnsupported: "Return to your own account before managing VM access or host options."
        case .invalidEndpoint: "Use a secure API address for VM access."
        case .invalidVMName: "The selected VM name is invalid."
        case .invalidPassword: "Enter your current Hanasand account password."
        case .invalidResponse: "The VM service returned an invalid response."
        case .responseTooLarge: "The VM service response exceeded its size limit."
        case .accessDenied: "Current owner or editor access is required for this VM."
        case let .requestFailed(status): "The VM request failed (HTTP \(status))."
        case .uncertainOutcome: "The operation outcome could not be verified. Refresh the VM state before trying again."
        }
    }
}

enum NativeVMAccessPolicy {
    static func mayManage(canManage: Bool, isImpersonating: Bool, hasCredentials: Bool) -> Bool {
        canManage && !isImpersonating && hasCredentials
    }

    static func mayRevealSudoPassword(isImpersonating: Bool, hasCredentials: Bool) -> Bool {
        !isImpersonating && hasCredentials
    }
}
