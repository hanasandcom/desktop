import XCTest
@testable import Hanasand

final class IntegrationScopeStateTests: XCTestCase {
    func testUnchangedScopeDoesNotInvalidateCurrentState() {
        let identity = scope()
        var lifecycle = IntegrationScopeLifecycle()

        XCTAssertFalse(lifecycle.update(to: identity))
        XCTAssertFalse(lifecycle.update(to: identity))
        XCTAssertEqual(lifecycle.identity, identity)
        XCTAssertEqual(lifecycle.generation, 0)
    }

    func testWorkspaceUserAndTokenChangesEachInvalidateCurrentState() {
        let original = scope()
        var lifecycle = IntegrationScopeLifecycle()

        XCTAssertFalse(lifecycle.update(to: original))
        XCTAssertTrue(lifecycle.update(to: scope(workspaceID: "org-next")))
        XCTAssertEqual(lifecycle.generation, 1)
        XCTAssertTrue(lifecycle.update(to: scope(userID: "user-next")))
        XCTAssertEqual(lifecycle.generation, 2)
        XCTAssertTrue(lifecycle.update(to: scope(authToken: "token-next")))
        XCTAssertEqual(lifecycle.generation, 3)
    }

    private func scope(
        workspaceID: String = "org-current",
        userID: String = "user-current",
        authToken: String = "token-current"
    ) -> IntegrationScopeIdentity {
        IntegrationScopeIdentity(
            apiBaseURL: "https://api.hanasand.com/api",
            workspaceID: workspaceID,
            userID: userID,
            authToken: authToken,
            impersonationToken: "",
            impersonatingUserID: ""
        )
    }
}
