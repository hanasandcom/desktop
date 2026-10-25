import XCTest
@testable import Hanasand

final class AccountDeletionImpersonationTests: XCTestCase {
    @MainActor
    func testDeletionIsBlockedOnlyWhileImpersonating() {
        XCTAssertEqual(
            DesktopAgentModel.accountDeletionImpersonationDenial(isImpersonating: true),
            "Return to your own account before scheduling deletion."
        )
        XCTAssertNil(DesktopAgentModel.accountDeletionImpersonationDenial(isImpersonating: false))
    }
}
