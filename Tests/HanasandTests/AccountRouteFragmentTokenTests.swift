import XCTest
@testable import Hanasand

final class AccountRouteFragmentTokenTests: XCTestCase {
    func testWebsitePasswordResetFragmentTokenIsPassedAsNativeRouteSecretAndCanBeScrubbed() {
        let url = "https://hanasand.com/reset-password?id=member-24#token=reset%2Bsecret"
        guard let route = BrowserWorkspaceModel.nativeRoute(for: url) else {
            XCTFail("Expected native reset route")
            return
        }

        XCTAssertEqual(route.path, "/reset-password")
        XCTAssertEqual(route.query["id"], "member-24")
        XCTAssertEqual(route.query["token"], "reset+secret")
        XCTAssertFalse(URLComponents(string: url)?.queryItems?.contains(where: { $0.name == "token" }) ?? false)

        let capture = NativeAccountRouteSecretCapture.capture(from: route.query, removing: ["token"])
        XCTAssertEqual(capture.values["token"], "reset+secret")
        XCTAssertEqual(capture.sanitizedQuery["id"], "member-24")
        XCTAssertNil(capture.sanitizedQuery["token"])
    }

    func testWebsitePendingDeletionFragmentRestoreTokenIsPassedAndCanBeScrubbed() {
        let url = "https://hanasand.com/account-pending-deletion?id=member-24&deletionScheduledAt=2030-01-01T00%3A00%3A00Z#restoreToken=restore-secret"
        guard let route = BrowserWorkspaceModel.nativeRoute(for: url) else {
            XCTFail("Expected native pending-deletion route")
            return
        }

        XCTAssertEqual(route.path, "/account-pending-deletion")
        XCTAssertEqual(route.query["id"], "member-24")
        XCTAssertEqual(route.query["restoreToken"], "restore-secret")
        XCTAssertFalse(URLComponents(string: url)?.queryItems?.contains(where: { $0.name == "restoreToken" }) ?? false)

        let capture = NativeAccountRouteSecretCapture.capture(from: route.query, removing: ["restoreToken"])
        XCTAssertEqual(capture.values["restoreToken"], "restore-secret")
        XCTAssertEqual(capture.sanitizedQuery["id"], "member-24")
        XCTAssertNil(capture.sanitizedQuery["restoreToken"])
    }

    func testUnrelatedWebsiteFragmentsDoNotBecomeNativeRouteQueryParameters() {
        let route = BrowserWorkspaceModel.nativeRoute(for: "https://hanasand.com/dashboard#token=must-not-be-imported&restoreToken=must-not-be-imported")
        XCTAssertNil(route?.query["token"])
        XCTAssertNil(route?.query["restoreToken"])
    }

    func testAccountRouteDoesNotForwardQueryStringSecretsInsteadOfFragmentSecrets() {
        let route = BrowserWorkspaceModel.nativeRoute(for: "https://hanasand.com/reset-password?id=member-24&token=query-secret#token=fragment-secret")
        XCTAssertEqual(route?.query["token"], "fragment-secret")
    }
}
