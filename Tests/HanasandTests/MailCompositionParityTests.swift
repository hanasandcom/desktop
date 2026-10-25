import XCTest

@testable import Hanasand

final class MailCompositionParityTests: XCTestCase {
    func testReplyAllUsesReplyToAndExcludesOwnMailboxAndDuplicateAddresses() {
        let replyTo = [
            address("reply@example.test", name: "Reply address"),
            address("owner@example.test", name: "My mailbox"),
        ]
        let to = [
            address("reply@example.test"),
            address("teammate@example.test", name: "Teammate"),
        ]
        let cc = [
            address("OWNER@example.test"),
            address("observer@example.test", name: "Observer"),
        ]

        let recipients = MailReplyRecipientPolicy.replyAll(
            from: replyTo,
            to: to,
            cc: cc,
            mailboxAddress: " owner@example.test "
        )

        XCTAssertEqual(recipients.map(\.email), [
            "reply@example.test",
            "teammate@example.test",
            "observer@example.test",
        ])
        XCTAssertEqual(recipients.first?.displayName, "Reply address <reply@example.test>")
    }

    func testReplyAllKeepsOriginalSenderWhenMailboxAddressIsUnknown() {
        let sender = address("sender@example.test")
        let copy = address("copy@example.test")

        let recipients = MailReplyRecipientPolicy.replyAll(
            from: [sender],
            to: [sender, copy],
            cc: [],
            mailboxAddress: nil
        )

        XCTAssertEqual(recipients.map(\.email), ["sender@example.test", "copy@example.test"])
    }

    private func address(_ email: String, name: String? = nil) -> MailOverviewEnvelope.MailAddress {
        MailOverviewEnvelope.MailAddress(email: email, name: name)
    }
}
