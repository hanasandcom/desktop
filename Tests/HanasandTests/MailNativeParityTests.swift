import XCTest
@testable import Hanasand

final class MailNativeParityTests: XCTestCase {
    @MainActor
    func testSendKeyIsStableForUncertainRetryAndChangesAfterEditOrNewDraft() {
        let store = MailSendIdempotencyStore()
        let mailbox = "owner@example.test"
        let original = Data("recipient|subject|body".utf8)
        let edited = Data("recipient|edited subject|body".utf8)

        let firstKey = store.idempotencyKey(mailbox: mailbox, payload: original)
        XCTAssertEqual(store.idempotencyKey(mailbox: mailbox, payload: original), firstKey)
        XCTAssertNotEqual(store.idempotencyKey(mailbox: mailbox, payload: edited), firstKey)

        store.beginNewDraft(mailbox: mailbox)
        XCTAssertNotEqual(store.idempotencyKey(mailbox: mailbox, payload: original), firstKey)
    }

    @MainActor
    func testOnlyOneSendPerMailboxCanBeInFlight() {
        let store = MailSendIdempotencyStore()

        XCTAssertTrue(store.beginSend(mailbox: "mailbox-a"))
        XCTAssertTrue(store.isSending(mailbox: "mailbox-a"))
        XCTAssertFalse(store.beginSend(mailbox: "mailbox-a"))
        XCTAssertTrue(store.beginSend(mailbox: "mailbox-b"))

        store.finishSend(mailbox: "mailbox-a")
        XCTAssertFalse(store.isSending(mailbox: "mailbox-a"))
        XCTAssertTrue(store.beginSend(mailbox: "mailbox-a"))
    }

    @MainActor
    func testSuccessfulSendResetsTheNextDraftAfterTheSendFinishes() {
        let store = MailSendIdempotencyStore()
        let mailbox = "owner@example.test"
        let payload = Data("same message".utf8)
        let firstKey = store.idempotencyKey(mailbox: mailbox, payload: payload)
        XCTAssertTrue(store.beginSend(mailbox: mailbox))

        store.beginNewDraft(mailbox: mailbox)
        XCTAssertEqual(store.idempotencyKey(mailbox: mailbox, payload: payload), firstKey)
        store.finishSend(mailbox: mailbox)
        store.beginNewDraft(mailbox: mailbox)
        XCTAssertNotEqual(store.idempotencyKey(mailbox: mailbox, payload: payload), firstKey)
    }

    @MainActor
    func testNavigationLockCoversAnyMailboxSend() {
        let store = MailSendIdempotencyStore()
        XCTAssertFalse(store.isSendingAnyMailbox)
        XCTAssertTrue(store.beginSend(mailbox: "mailbox-a"))
        XCTAssertTrue(store.isSendingAnyMailbox)
        store.finishSend(mailbox: "mailbox-a")
        XCTAssertFalse(store.isSendingAnyMailbox)
    }

    func testSendBudgetMatchesSerializedPayloadAndRejectsOversizedEstimate() throws {
        let attachment = MailDraftAttachment.Payload(name: "a.txt", type: "text/plain", contentBase64: "YQ==", size: 1)
        let payload = Self.sendPayload(attachments: [attachment])
        let encoded = try MailSendPayloadBudget.encodedBody(payload)
        XCTAssertEqual(try MailSendPayloadBudget.estimatedBodyBytes(payload), encoded.count)
        XCTAssertNoThrow(try MailSendPayloadBudget.validateEncodedBody(encoded))

        let oversized = Self.sendPayload(attachments: [
            MailDraftAttachment.Payload(name: "large.bin", type: "application/octet-stream", contentBase64: "", size: 20_000_000),
        ])
        XCTAssertThrowsError(try MailSendPayloadBudget.estimatedBodyBytes(oversized))
    }

    func testOverviewPageURLIsScopedAndRejectsInvalidCursor() throws {
        let url = try MailOverviewPageRequest.makeURL(
            baseURL: "https://api.example.test/api/",
            mailboxUser: "person+shared@example.test",
            mailboxID: "mailbox/one",
            cursor: "message/last?"
        )
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        XCTAssertEqual(components.path, "/api/mail/overview")
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value) }), [
            "mailboxUser": "person+shared@example.test",
            "mailboxId": "mailbox/one",
            "after": "message/last?",
        ])
        XCTAssertThrowsError(try MailOverviewPageRequest.makeURL(baseURL: "https://api.example.test/api", mailboxUser: "u", mailboxID: "inbox", cursor: ""))
        XCTAssertThrowsError(try MailOverviewPageRequest.makeURL(baseURL: "http://api.example.test/api", mailboxUser: "u", mailboxID: "inbox", cursor: "next"))
    }

    func testOverviewCursorAndCanSendPermissionDecode() throws {
        let denied = #"{"mailboxUser":"owner","mailboxes":[],"messages":[],"nextCursor":"older","actor":{"id":"owner","canSend":false}}"#.data(using: .utf8)!
        let overview = try JSONDecoder().decode(MailOverviewEnvelope.self, from: denied)
        XCTAssertEqual(overview.nextCursor, "older")
        XCTAssertFalse(overview.canSend)

        let legacy = #"{"mailboxUser":"owner","mailboxes":[],"messages":[]}"#.data(using: .utf8)!
        XCTAssertTrue(try JSONDecoder().decode(MailOverviewEnvelope.self, from: legacy).canSend)
    }

    func testOverviewPagingAppendsOnlyUnseenMessagesInOrder() throws {
        func message(_ id: String) throws -> MailOverviewEnvelope.Message {
            try JSONDecoder().decode(MailOverviewEnvelope.Message.self, from: #"{"id":"\#(id)","subject":"\#(id)","from":[],"to":[]}"#.data(using: .utf8)!)
        }

        let merged = MailOverviewPageMerge.appending(
            [try message("two"), try message("three"), try message("three")],
            to: [try message("one"), try message("two")]
        )
        XCTAssertEqual(merged.map(\.id), ["one", "two", "three"])
    }

    @MainActor
    func testInboxPaginationAllowsOneRequestPerAccountAndFolderScope() {
        let state = MailInboxPaginationState()
        XCTAssertTrue(state.begin(scope: "owner|inbox"))
        XCTAssertTrue(state.isLoading(scope: "owner|inbox"))
        XCTAssertFalse(state.begin(scope: "owner|inbox"))
        XCTAssertTrue(state.begin(scope: "shared|inbox"))
        state.finish(scope: "owner|inbox")
        XCTAssertFalse(state.isLoading(scope: "owner|inbox"))
        XCTAssertTrue(state.isLoading(scope: "shared|inbox"))
    }

    private static func sendPayload(attachments: [MailDraftAttachment.Payload]) -> MailSendPayload {
        MailSendPayload(
            mailboxUser: "owner@example.test",
            to: "recipient@example.test",
            cc: "",
            bcc: "",
            replyTo: "",
            subject: "Subject",
            textBody: "Body",
            attachments: attachments
        )
    }
}
