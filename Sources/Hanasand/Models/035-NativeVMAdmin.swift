import Foundation

struct NativeVMAdminRecord: Equatable {
    let name: String
    let owner: String
    let organizationID: String?
    let canAssignOrganization: Bool
    let deletedAt: String?
}

struct NativeVMAdminAccess: Equatable {
    let allowed: Bool
    let canEdit: Bool
}

/// A short-lived authorization read. The client verifies its scope and age again before every write.
struct NativeVMAdminAuthorization: Equatable {
    let scope: String
    let capturedAt: Date
    let vm: NativeVMAdminRecord
    let access: NativeVMAdminAccess
}

/// A short-lived platform permission read for actions that are global to the VM service.
struct NativeVMPlatformAdminAuthorization: Equatable {
    let scope: String
    let capturedAt: Date
    let access: NativeVMAdminAccess
}

struct NativeVMAdminOrganizationReceipt: Equatable {
    let id: String
    let name: String
}

struct NativeVMAdminDeletionReceipt: Equatable {
    let message: String
    let vm: NativeVMAdminRecord
}

struct NativeVMAdminStopReceipt: Equatable {
    let message: String
    let vmNames: [String]
}

enum NativeVMAdminError: LocalizedError, Equatable {
    case signInRequired
    case impersonationUnsupported
    case invalidEndpoint
    case invalidInput
    case invalidResponse
    case responseTooLarge
    case accessDenied
    case staleAuthorization
    case wrongScope
    case invalidConfirmation
    case requestFailed(Int)
    case uncertainOutcome

    var errorDescription: String? {
        switch self {
        case .signInRequired: "Sign in to manage virtual machines."
        case .impersonationUnsupported: "Return to your own account before managing virtual machines."
        case .invalidEndpoint: "Use a secure API address for virtual machine management."
        case .invalidInput: "The selected virtual machine or organization is invalid."
        case .invalidResponse: "The virtual machine service returned an invalid response."
        case .responseTooLarge: "The virtual machine response exceeded its size limit."
        case .accessDenied: "Current Hanasand owner or editor access is required."
        case .staleAuthorization: "Refresh the virtual machine and permission state before continuing."
        case .wrongScope: "The current account or organization does not match this virtual machine."
        case .invalidConfirmation: "Type the exact virtual machine name to schedule its deletion."
        case let .requestFailed(status): "Virtual machine management failed (HTTP \(status))."
        case .uncertainOutcome: "The operation outcome could not be verified. Refresh current state before retrying."
        }
    }
}
