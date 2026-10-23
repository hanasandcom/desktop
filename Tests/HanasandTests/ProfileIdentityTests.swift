import XCTest
@testable import Hanasand

final class ProfileIdentityTests: XCTestCase {
    func testUpdatePayloadTrimsNameAndNormalizesUsernameWithoutExtraFields() throws {
        let payload = try DashboardProfileIdentityUpdatePayload(name: "  Ada Lovelace  ", username: "  Ada.Lovelace  ")
        let data = try JSONEncoder().encode(payload)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: String])

        XCTAssertEqual(object, ["name": "Ada Lovelace", "username": "ada.lovelace"])
    }

    func testUpdatePayloadRejectsBlankOrOverlongNameAndShortUsername() {
        XCTAssertThrowsError(try DashboardProfileIdentityUpdatePayload(name: "  ", username: "ada"))
        XCTAssertThrowsError(try DashboardProfileIdentityUpdatePayload(name: String(repeating: "a", count: 101), username: "ada"))
        XCTAssertThrowsError(try DashboardProfileIdentityUpdatePayload(name: "Ada", username: "ab"))
        XCTAssertThrowsError(try DashboardProfileIdentityUpdatePayload(name: "Ada", username: "-ada"))
        XCTAssertThrowsError(try DashboardProfileIdentityUpdatePayload(name: "Ada", username: String(repeating: "a", count: 41)))
    }

    func testUpdateResponseIgnoresReturnedSessionToken() throws {
        let json = """
        {"id":"ada","name":"Ada Lovelace","username":"ada","avatar":null,"token":"must-not-be-exposed","expires_at":"2030-01-01T00:00:00Z"}
        """.data(using: .utf8)!
        let response = try JSONDecoder().decode(DashboardProfileIdentityUpdateResponse.self, from: json)

        XCTAssertEqual(response.id, "ada")
        XCTAssertEqual(response.name, "Ada Lovelace")
        XCTAssertEqual(response.username, "ada")
        XCTAssertFalse(Mirror(reflecting: response).children.contains { $0.label == "token" })
    }
}
