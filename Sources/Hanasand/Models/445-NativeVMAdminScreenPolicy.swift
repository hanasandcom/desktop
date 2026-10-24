import Foundation

enum NativeVMAdminScreenAction: String, CaseIterable, Hashable {
    case assignOrganization
    case scheduleDeletion
    case restore
    case stopAll
}

enum NativeVMAdminConfirmation: Identifiable, Equatable {
    case delete
    case restore
    case stopAll

    var id: String {
        switch self {
        case .delete: "delete"
        case .restore: "restore"
        case .stopAll: "stop-all"
        }
    }

    var title: String {
        switch self {
        case .delete: "Schedule this VM for deletion?"
        case .restore: "Restore this VM?"
        case .stopAll: "Review stop all VMs?"
        }
    }

    var buttonTitle: String {
        switch self {
        case .delete: "Schedule deletion"
        case .restore: "Restore VM"
        case .stopAll: "Stop all VMs"
        }
    }
}

func nativeVMAdminScreenActions(
    authorization: NativeVMAdminAuthorization?,
    userID: String,
    organizationID: String,
    isAuthenticated: Bool,
    isImpersonating: Bool
) -> Set<NativeVMAdminScreenAction> {
    guard isAuthenticated, !isImpersonating, !userID.isEmpty,
          let authorization else { return [] }

    let vm = authorization.vm
    let scope = organizationID.isEmpty || organizationID == "personal" ? nil : organizationID
    guard vm.organizationID == scope else { return [] }

    var actions = Set<NativeVMAdminScreenAction>()
    let canPlatformEdit = authorization.access.allowed && authorization.access.canEdit
    if canPlatformEdit {
        actions.insert(.stopAll)
        actions.insert(vm.deletedAt == nil ? .scheduleDeletion : .restore)
    }
    if vm.deletedAt == nil, vm.organizationID == nil, vm.canAssignOrganization,
       vm.owner == userID || canPlatformEdit {
        actions.insert(.assignOrganization)
    }
    return actions
}
