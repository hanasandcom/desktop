import XCTest
@testable import Hanasand

final class UserRoleAdministrationTests: XCTestCase {
    func testReservedPlaceholderMatchesInactiveReservedIDOrUsername() throws {
        XCTAssertTrue(try user(id: "ADMIN", username: nil, active: false).isReservedPlaceholder)
        XCTAssertTrue(try user(id: "placeholder-1", username: "Support", active: false).isReservedPlaceholder)
    }

    func testReservedPlaceholderDoesNotHideActiveOrOrdinaryUsers() throws {
        XCTAssertFalse(try user(id: "admin", username: nil, active: true).isReservedPlaceholder)
        XCTAssertFalse(try user(id: "ordinary-user", username: "regular", active: false).isReservedPlaceholder)
    }

    func testSignupReservationUsesTrimmedCaseInsensitiveNormalization() {
        let cleanUsername = ReservedUsernamePolicy.normalizedSignupUsername("  AdMiN  ")
        XCTAssertEqual(cleanUsername, "admin")
        XCTAssertTrue(ReservedUsernamePolicy.usernames.contains(cleanUsername))
        XCTAssertFalse(ReservedUsernamePolicy.usernames.contains(ReservedUsernamePolicy.normalizedSignupUsername("  regular  ")))
    }

    private func user(id: String, username: String?, active: Bool) throws -> DashboardUser {
        let fields: [String: Any] = [
            "id": id,
            "active": active,
            "username": username as Any? ?? NSNull(),
        ]
        return try JSONDecoder().decode(DashboardUser.self, from: JSONSerialization.data(withJSONObject: fields))
    }
}
