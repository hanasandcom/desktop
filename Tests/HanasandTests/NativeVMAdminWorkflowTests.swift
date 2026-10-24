import XCTest
@testable import Hanasand

final class NativeVMAdminWorkflowTests: XCTestCase {
    func testOwnerCanAssignPersonalVMButDoesNotReceivePlatformActions() {
        let actions = nativeVMAdminScreenActions(
            authorization: authorization(owner: "owner", organizationID: nil, canAssign: true, deletedAt: nil, access: .init(allowed: false, canEdit: false)),
            userID: "owner", organizationID: "personal", isAuthenticated: true, isImpersonating: false
        )

        XCTAssertEqual(actions, [.assignOrganization])
    }

    func testPlatformEditorCanDeleteStopAllAndRestoreOnlyDeletedVM() {
        let editor = NativeVMAdminAccess(allowed: true, canEdit: true)
        let active = nativeVMAdminScreenActions(
            authorization: authorization(owner: "other", organizationID: nil, canAssign: false, deletedAt: nil, access: editor),
            userID: "editor", organizationID: "personal", isAuthenticated: true, isImpersonating: false
        )
        XCTAssertEqual(active, [.scheduleDeletion, .stopAll])

        let deleted = nativeVMAdminScreenActions(
            authorization: authorization(owner: "other", organizationID: nil, canAssign: true, deletedAt: "2026-10-24T00:00:00Z", access: editor),
            userID: "editor", organizationID: "personal", isAuthenticated: true, isImpersonating: false
        )
        XCTAssertEqual(deleted, [.restore, .stopAll])
    }

    func testPolicyHidesActionsForImpersonationAndWrongOrganization() {
        let auth = authorization(owner: "owner", organizationID: "org-a", canAssign: false, deletedAt: nil,
                                 access: .init(allowed: true, canEdit: true))
        XCTAssertTrue(nativeVMAdminScreenActions(authorization: auth, userID: "owner", organizationID: "org-a",
                                                 isAuthenticated: true, isImpersonating: true).isEmpty)
        XCTAssertTrue(nativeVMAdminScreenActions(authorization: auth, userID: "owner", organizationID: "org-b",
                                                 isAuthenticated: true, isImpersonating: false).isEmpty)
        XCTAssertTrue(nativeVMAdminScreenActions(authorization: auth, userID: "owner", organizationID: "org-a",
                                                 isAuthenticated: false, isImpersonating: false).isEmpty)
    }

    private func authorization(owner: String, organizationID: String?, canAssign: Bool, deletedAt: String?, access: NativeVMAdminAccess) -> NativeVMAdminAuthorization {
        NativeVMAdminAuthorization(
            scope: "fixture", capturedAt: Date(timeIntervalSince1970: 1_800_000_000),
            vm: NativeVMAdminRecord(name: "fixture-vm", owner: owner, organizationID: organizationID,
                                    canAssignOrganization: canAssign, deletedAt: deletedAt),
            access: access
        )
    }
}
