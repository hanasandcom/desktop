import XCTest
@testable import Hanasand

final class NativeProfileRoutePolicyTests: XCTestCase {
    func testInactivePublicProfileUsesUsernameAsDisplayName() {
        XCTAssertEqual(
            NativeProfilePresentation.displayName(name: "Retired Display Name", username: "inactive-user", id: "user-9", active: false),
            "inactive-user"
        )
    }

    func testPublicProfileDisplayNameFallsBackSafely() {
        XCTAssertEqual(NativeProfilePresentation.displayName(name: "", username: "", id: "user-10", active: false), "user-10")
        XCTAssertEqual(NativeProfilePresentation.displayName(name: nil, username: "active-user", id: "user-11", active: true), "active-user")
        XCTAssertEqual(NativeProfilePresentation.displayName(name: "Active Name", username: "active-user", id: "user-12", active: true), "Active Name")
        XCTAssertEqual(NativeProfilePresentation.displayName(name: "Unknown Status Name", username: "active-user", id: "user-13", active: nil), "Unknown Status Name")
    }

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
