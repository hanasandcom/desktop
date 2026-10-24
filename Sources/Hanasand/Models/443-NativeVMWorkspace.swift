import Foundation

struct NativeVMWorkspaceDetails: Equatable {
    let name: String
    let fields: [(String, String)]
    let profiles: [String]

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.name == rhs.name && lhs.fields.elementsEqual(rhs.fields, by: ==) && lhs.profiles == rhs.profiles
    }
}

struct NativeVMMetric: Equatable, Identifiable {
    let id: String
    let recordedAt: String?
    let powerState: String?
    let values: [(String, String)]

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id && lhs.recordedAt == rhs.recordedAt && lhs.powerState == rhs.powerState
            && lhs.values.elementsEqual(rhs.values, by: ==)
    }
}

struct NativeVMManagementAccess: Equatable {
    let canManage: Bool
    let services: [(String, String)]

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.canManage == rhs.canManage && lhs.services.elementsEqual(rhs.services, by: ==)
    }
}

enum NativeVMWorkspaceClientError: LocalizedError, Equatable {
    case invalidEndpoint
    case invalidVMName
    case invalidResponse
    case responseTooLarge
    case permissionDenied
    case httpStatus(Int)

    var errorDescription: String? {
        switch self {
        case .invalidEndpoint: "VM details require a valid secure API address."
        case .invalidVMName: "The selected VM name is invalid."
        case .invalidResponse: "The VM service returned an invalid response."
        case .responseTooLarge: "The VM response is larger than expected."
        case .permissionDenied: "Current permission to manage this VM could not be verified."
        case let .httpStatus(status): "The VM service returned HTTP \(status)."
        }
    }
}
