import XCTest
@testable import Hanasand

final class ProfileSshKeyTests: XCTestCase {
    func testAddPayloadTrimsFieldsAndUsesMobileAPIContract() throws {
        let payload = try ProfileSshKeyPayload(name: "  Work laptop  ", publicKey: "\nssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAA... eirik\n")
        let data = try JSONEncoder().encode(payload)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: String])

        XCTAssertEqual(object, ["name": "Work laptop", "publicKey": "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAA... eirik"])
    }

    func testAddPayloadRejectsBlankAndOverlongName() {
        XCTAssertThrowsError(try ProfileSshKeyPayload(name: "  ", publicKey: "ssh-ed25519 AAAA"))
        XCTAssertThrowsError(try ProfileSshKeyPayload(name: String(repeating: "a", count: 101), publicKey: "ssh-ed25519 AAAA"))
        XCTAssertThrowsError(try ProfileSshKeyPayload(name: "Laptop", publicKey: "  "))
    }

    func testKeyListDecodesUsageMetadataWithoutPublicKeyMaterial() throws {
        let data = """
        {"keys":[{"id":41,"name":"Work laptop","fingerprint":"SHA256:abc","keyType":"ssh-ed25519","addedAt":"2026-10-20T12:00:00Z","lastUsedAt":null,"lastUsedServer":null,"lastUsedIp":null,"lastUsedUserAgent":null}]}
        """.data(using: .utf8)!
        let list = try JSONDecoder().decode(ProfileSshKeyList.self, from: data)

        XCTAssertEqual(list.keys.count, 1)
        XCTAssertEqual(list.keys[0].id, 41)
        XCTAssertEqual(list.keys[0].fingerprint, "SHA256:abc")
        XCTAssertNil(list.keys[0].lastUsedAt)
        XCTAssertFalse(Mirror(reflecting: list.keys[0]).children.contains { $0.label == "publicKey" })
    }
}
