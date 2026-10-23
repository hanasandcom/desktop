import XCTest
@testable import Hanasand

final class MailSearchTests: XCTestCase {
    func testBuildsMailboxScopedSearchURLAndPreservesQueryParameters() throws {
        let url = try MailSearchRequest.makeURL(
            baseURL: "https://api.example.test/api/",
            mailboxUser: "person@example.test",
            mailboxID: "mailbox/one",
            query: "  invoice & travel  ",
            after: "message/last"
        )

        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        XCTAssertEqual(components.path, "/api/mail/search")
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value) }), [
            "mailboxUser": "person@example.test",
            "mailboxId": "mailbox/one",
            "query": "invoice & travel",
            "after": "message/last",
        ])
    }

    func testRejectsEmptyOversizedAndMailboxlessQueries() {
        let baseURL = "https://api.example.test"
        XCTAssertThrowsError(try MailSearchRequest.makeURL(baseURL: baseURL, mailboxUser: "u", mailboxID: "inbox", query: "  "))
        XCTAssertThrowsError(try MailSearchRequest.makeURL(baseURL: baseURL, mailboxUser: "u", mailboxID: "inbox", query: String(repeating: "x", count: 201)))
        XCTAssertThrowsError(try MailSearchRequest.makeURL(baseURL: baseURL, mailboxUser: "u", mailboxID: " ", query: "invoice"))
        XCTAssertThrowsError(try MailSearchRequest.makeURL(baseURL: baseURL, mailboxUser: "u", mailboxID: "inbox", query: "invoice", after: ""))
    }

    func testDecodesSearchSummariesAndNextPageCursor() throws {
        let data = #"{"messages":[{"id":"message-1","threadId":"thread-1","mailboxIds":["inbox"],"subject":"Invoice","preview":"October invoice","receivedAt":"2026-10-20T10:00:00Z","sentAt":"","from":[{"email":"billing@example.test"}],"to":[],"cc":[],"hasAttachment":false,"isRead":false,"isFlagged":false,"isAnswered":false,"isDraft":false,"isJunk":false,"isDeleted":false}],"nextCursor":"message-1"}"#.data(using: .utf8)!
        let page = try JSONDecoder().decode(MailSearchPage.self, from: data)

        XCTAssertEqual(page.messages.map(\.id), ["message-1"])
        XCTAssertEqual(page.messages.first?.fromLabel, "billing@example.test")
        XCTAssertEqual(page.nextCursor, "message-1")
    }
}
