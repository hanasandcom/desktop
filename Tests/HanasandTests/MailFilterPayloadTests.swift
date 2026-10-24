import Foundation
import XCTest
@testable import Hanasand

final class MailFilterPayloadTests: XCTestCase {
    func testEncodesEveryWebsiteSupportedCriteriaField() throws {
        XCTAssertEqual(
            MailFilterPayload.CriteriaField.allCases.map(\.rawValue),
            ["from", "subject", "body", "senderDomain"]
        )

        for field in MailFilterPayload.CriteriaField.allCases {
            let payload = Self.payload(field: field, markRead: false)
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(payload)) as? [String: Any])
            let criteria = try XCTUnwrap(object["criteria"] as? [String: Any])
            XCTAssertEqual(criteria["field"] as? String, field.rawValue)
            XCTAssertEqual(criteria["contains"] as? String, "hanasand")
        }
    }

    func testEncodesMarkReadChoiceForMoveAction() throws {
        for markRead in [false, true] {
            let payload = Self.payload(field: .subject, markRead: markRead)
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(payload)) as? [String: Any])
            let action = try XCTUnwrap(object["action"] as? [String: Any])
            XCTAssertEqual(action["type"] as? String, "move")
            XCTAssertEqual(action["mailboxName"] as? String, "Archive")
            XCTAssertEqual(action["markRead"] as? Bool, markRead)
        }
    }

    private static func payload(
        field: MailFilterPayload.CriteriaField,
        markRead: Bool
    ) -> MailFilterPayload {
        MailFilterPayload(
            mailboxUser: "mail@example.test",
            name: "Rule",
            enabled: true,
            criteria: .init(field: field, contains: "hanasand"),
            action: .init(type: "move", mailboxName: "Archive", markRead: markRead)
        )
    }
}
