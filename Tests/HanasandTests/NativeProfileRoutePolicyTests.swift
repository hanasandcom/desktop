import XCTest
@testable import Hanasand

final class NativeProfileRoutePolicyTests: XCTestCase {
    func testNoRequestedIDPreservesSignedInAccountDestination() {
        XCTAssertEqual(
            NativeProfileRoutePolicy.destination(requestedUserID: nil, authenticatedUserID: "alice"),
            .signedInAccount
        )
        XCTAssertEqual(
            NativeProfileRoutePolicy.destination(requestedUserID: "  ", authenticatedUserID: "alice"),
            .signedInAccount
        )
    }

    func testRequestedAuthenticatedIDOpensOwnAccountSections() {
        XCTAssertEqual(
            NativeProfileRoutePolicy.destination(requestedUserID: " alice ", authenticatedUserID: "alice"),
            .signedInAccount
        )
        XCTAssertEqual(
            NativeProfileRoutePolicy.destination(requestedUserID: "ALICE", authenticatedUserID: "alice"),
            .publicProfile(userID: "ALICE")
        )
    }

    func testForeignIDAlwaysOpensReadOnlyPublicProfileRegardlessOfSectionRoute() {
        for requestedID in ["bob", "bob/security", "bob/sessions", "bob/ssh-keys", "bob/support"] {
            let profileID = requestedID.split(separator: "/", maxSplits: 1).first.map(String.init)
            XCTAssertEqual(
                NativeProfileRoutePolicy.destination(requestedUserID: profileID, authenticatedUserID: "alice"),
                .publicProfile(userID: "bob"),
                "Foreign profile route \(requestedID) must not open the signed-in account panel."
            )
        }
    }

    func testMissingAuthenticatedIdentityNeverTreatsRequestedUserAsSelf() {
        XCTAssertEqual(
            NativeProfileRoutePolicy.destination(requestedUserID: "bob", authenticatedUserID: nil),
            .publicProfile(userID: "bob")
        )
    }
}
