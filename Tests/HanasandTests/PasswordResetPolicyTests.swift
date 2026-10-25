import XCTest
@testable import Hanasand

final class PasswordResetPolicyTests: XCTestCase {
    func testResetPasswordUsesWebsiteStrengthRequirements() {
        XCTAssertFalse(AccountSignupClient.passwordMeetsRequirements("Short1!"))
        XCTAssertFalse(AccountSignupClient.passwordMeetsRequirements("alllowercasepassword1!"))
        XCTAssertFalse(AccountSignupClient.passwordMeetsRequirements("ALLUPPERCASEPASSWORD1!"))
        XCTAssertFalse(AccountSignupClient.passwordMeetsRequirements("NoNumberPassword!"))
        XCTAssertFalse(AccountSignupClient.passwordMeetsRequirements("NoSpecialCharacter123"))
        XCTAssertTrue(AccountSignupClient.passwordMeetsRequirements("CorrectHorseBattery9!"))
    }
}
