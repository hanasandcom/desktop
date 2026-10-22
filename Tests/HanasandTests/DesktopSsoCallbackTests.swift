import XCTest
@testable import Hanasand

final class DesktopSsoCallbackTests: XCTestCase {
    func testAcceptsOnlyAWellFormedDesktopAuthorizationCallback() throws {
        let code = String(repeating: "A", count: 43)
        let callback = try XCTUnwrap(URL(string: "hanasand-desktop://sso?code=\(code)"))

        XCTAssertEqual(DesktopSsoCallback.authorizationCode(from: callback), code)
    }

    func testRejectsMalformedOrAmbiguousDesktopAuthorizationCallbacks() throws {
        let code = String(repeating: "A", count: 43)
        let invalidCallbacks = [
            "https://hanasand.com/api/auth/sso/callback?code=\(code)",
            "hanasand-desktop://other?code=\(code)",
            "hanasand-desktop://sso/callback?code=\(code)",
            "hanasand-desktop://sso?code=\(code)&code=\(code)",
            "hanasand-desktop://sso?code=\(code)&error=access_denied",
            "hanasand-desktop://sso?error=access_denied",
            "hanasand-desktop://sso?code=short",
            "hanasand-desktop://sso?code=\(code)#fragment",
        ]

        for value in invalidCallbacks {
            let callback = try XCTUnwrap(URL(string: value), "Expected test URL to parse: \(value)")
            XCTAssertNil(DesktopSsoCallback.authorizationCode(from: callback), "Unexpectedly accepted callback: \(value)")
        }
    }
}
