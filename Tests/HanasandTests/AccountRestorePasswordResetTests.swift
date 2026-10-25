import XCTest
@testable import Hanasand

final class AccountRestorePasswordResetTests: XCTestCase {
    func testRestoreResponseRequiresAndDecodesPasswordResetToken() throws {
        let payload = Data(#"{"id":"test-user","token":"restore-session","resetToken":"required-reset"}"#.utf8)
        let response = try JSONDecoder().decode(HanasandLoginResponse.self, from: payload)

        XCTAssertEqual(response.requiredPasswordResetTokenForRestoration, "required-reset")
        XCTAssertEqual(response.token, "restore-session")
    }

    func testRestoreResponseWithoutResetTokenCannotStartPasswordReset() throws {
        let payload = Data(#"{"id":"test-user","token":"restore-session"}"#.utf8)
        let response = try JSONDecoder().decode(HanasandLoginResponse.self, from: payload)

        XCTAssertNil(response.requiredPasswordResetTokenForRestoration)
    }

    func testBlankRestoreResetTokenIsRejected() throws {
        let payload = Data(#"{"id":"test-user","resetToken":"  "}"#.utf8)
        let response = try JSONDecoder().decode(HanasandLoginResponse.self, from: payload)

        XCTAssertNil(response.requiredPasswordResetTokenForRestoration)
    }
}
