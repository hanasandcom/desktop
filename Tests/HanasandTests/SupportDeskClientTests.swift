import Foundation
import XCTest
@testable import Hanasand

final class SupportDeskClientTests: XCTestCase {
    private let service = URL(string: "https://support.synthetic.invalid/api")!
    private let site = URL(string: "https://synthetic.invalid")!
    private let ticketID = "11111111-1111-4111-8111-111111111111"
    private let requestID = "22222222-2222-4222-8222-222222222222"
    private let messageID = "33333333-3333-4333-8333-333333333333"
    private let row = #"{"id":"11111111-1111-4111-8111-111111111111","subject":"Help","status":"open","updated_at":"2026-10-23T12:00:00Z","created_at":"2026-10-23T11:00:00Z","user_id":"customer","user_name":"Customer","channel":"human","last_message":"Question","feedback_rating":5,"feedback_comment":"Thanks","resolution_version":2,"reply_count":3}"#

    private func client(send: ((URLRequest) async throws -> (Data, URLResponse))? = nil) throws -> SupportDeskClient {
        try SupportDeskClient(baseURL: service, siteBaseURL: site, userID: "agent", token: "token", organizationID: "org", send: send)
    }

    private func response(_ body: String, request: URLRequest, status: Int = 200) -> (Data, URLResponse) {
        (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!)
    }

    private func snapshot(_ ticket: SupportDeskTicket) -> SupportDeskSnapshot {
        SupportDeskSnapshot(scope: (try? client())?.scope ?? "", isSupport: true, realtime: true, tickets: [ticket])
    }

    func testQueueUsesCanonicalFiltersAndAuthenticatedNoStoreRequest() async throws {
        var captured: URLRequest?
        let client = try client { request in
            captured = request
            return self.response(#"{"isSupport":true,"realtime":true,"tickets":[{"id":"11111111-1111-4111-8111-111111111111","subject":"Help","status":"open","updated_at":"2026-10-23T12:00:00Z","secret":"discard"}]}"#, request: request)
        }
        var filters = SupportDeskFilters()
        filters.search = " Help "; filters.from = "2026-10-01"; filters.stars = .rated; filters.feedback = .comment; filters.status = .resolved
        let result = try await client.load(filters: filters)
        XCTAssertEqual(captured?.url?.absoluteString, "https://support.synthetic.invalid/api/support/tickets?search=Help&from=2026-10-01&stars=rated&feedback=comment")
        XCTAssertEqual(captured?.value(forHTTPHeaderField: "Authorization"), "Bearer token")
        XCTAssertEqual(captured?.value(forHTTPHeaderField: "id"), "agent")
        XCTAssertEqual(captured?.value(forHTTPHeaderField: "Cache-Control"), "no-store")
        XCTAssertFalse(captured?.httpShouldHandleCookies ?? true)
        XCTAssertEqual(result.tickets.first?.subject, "Help")
        XCTAssertNil(result.tickets.first?.lastMessage)
        XCTAssertEqual(try SupportDeskClient.filterQuery(filters), "?search=Help&from=2026-10-01&stars=rated&feedback=comment")
    }

    func testQueueAndDateFiltersFailClosedOnInvalidResponses() async throws {
        XCTAssertThrowsError(try SupportDeskClient.filterQuery({ var value = SupportDeskFilters(); value.from = "2026-02-30"; return value }()))
        XCTAssertThrowsError(try SupportDeskClient.filterQuery({ var value = SupportDeskFilters(); value.from = "2026-10-02"; value.to = "2026-10-01"; return value }()))
        for body in [#"{}"#, #"{"isSupport":true,"realtime":true,"tickets":[{}]}"#] {
            let malformed = try client { request in self.response(body, request: request) }
            do { _ = try await malformed.load(filters: SupportDeskFilters()); XCTFail("Expected invalid queue to fail") }
            catch SupportDeskClientError.invalidResponse {}
        }
        let valid = try client { request in self.response(#"{"isSupport":false,"realtime":true,"tickets":[]}"#, request: request) }
        let validQueue = try await valid.load(filters: SupportDeskFilters())
        XCTAssertEqual(validQueue.tickets, [])
    }

    func testReplyRequiresFreshStaffScopeAndSendsIdempotencyUUID() async throws {
        let ticket = try JSONDecoder().decode(SupportDeskTicket.self, from: Data(row.utf8))
        var captured: URLRequest?
        let instance = try client { request in
            captured = request
            return self.response(#"{"ok":true,"messageId":"33333333-3333-4333-8333-333333333333"}"#, request: request)
        }
        let receipt = try await instance.reply(snapshot: snapshot(ticket), ticket: ticket, body: "  Reply  ", requestID: requestID)
        XCTAssertEqual(receipt, messageID)
        XCTAssertEqual(captured?.url?.path, "/api/support/tickets/\(ticketID)/messages")
        let payload = try XCTUnwrap(captured?.httpBody).flatMap { try JSONSerialization.jsonObject(with: $0) as? [String: String] }
        XCTAssertEqual(payload, ["message": "Reply", "requestId": requestID])
        let stale = SupportDeskSnapshot(scope: "stale", isSupport: true, realtime: true, tickets: [ticket])
        do { _ = try await instance.reply(snapshot: stale, ticket: ticket, body: "Reply", requestID: requestID); XCTFail("Expected stale permission rejection") }
        catch SupportDeskClientError.readOnly {}
        let impersonated = try SupportDeskClient(baseURL: service, siteBaseURL: site, userID: "agent", token: "token", impersonationToken: "imp") { request in
            self.response(#"{"ok":true,"messageId":"33333333-3333-4333-8333-333333333333"}"#, request: request)
        }
        do { _ = try await impersonated.reply(snapshot: SupportDeskSnapshot(scope: impersonated.scope, isSupport: true, realtime: true, tickets: [ticket]), ticket: ticket, body: "Reply", requestID: requestID); XCTFail("Expected impersonation guard") }
        catch SupportDeskClientError.readOnly {}
    }

    func testStatusAndAccountChangesRequireMatchingDurableReceipts() async throws {
        let ticket = try JSONDecoder().decode(SupportDeskTicket.self, from: Data(row.utf8))
        var captured: URLRequest?
        let instance = try client { request in
            captured = request
            return self.response(#"{"ok":true,"ticket":{"id":"11111111-1111-4111-8111-111111111111","status":"closed"}}"#, request: request)
        }
        try await instance.setStatus(snapshot: snapshot(ticket), ticket: ticket, status: "closed")
        XCTAssertEqual(captured?.httpMethod, "POST")
        for body in [#"{"ok":true}"#, #"{"ok":true,"ticket":{"id":"33333333-3333-4333-8333-333333333333","status":"closed"}}"#] {
            let mismatch = try client { request in self.response(body, request: request) }
            do { try await mismatch.setStatus(snapshot: snapshot(ticket), ticket: ticket, status: "closed"); XCTFail("Expected uncertain receipt") }
            catch SupportDeskClientError.uncertainResult {}
        }
        captured = nil
        let accountClient = try client { request in captured = request; return self.response(#"{"ok":true}"#, request: request) }
        try await accountClient.changeAccount(snapshot: snapshot(ticket), ticket: ticket, field: .email, value: "person@example.test")
        XCTAssertEqual(captured?.httpMethod, "PUT")
        XCTAssertEqual(captured?.url?.path, "/api/support/tickets/\(ticketID)/account/email")
        XCTAssertThrowsError(try SupportDeskClient.validateAccountChange(field: .password, value: "short"))
        XCTAssertThrowsError(try SupportDeskClient.validateAccountChange(field: .email, value: "invalid"))
        XCTAssertThrowsError(try SupportDeskClient.validateAccountChange(field: .password, value: String(repeating: "x", count: 1025)))
    }

    func testMessagesAreValidatedAndWritesNeverEchoSecretsInErrors() async throws {
        let instance = try client { request in
            if request.url?.path.hasSuffix("/messages") == true {
                return self.response(#"{"messages":[{"id":"33333333-3333-4333-8333-333333333333","sender_name":"Agent","body":"Hello","created_at":"2026-10-23T12:00:00Z"}]}"#, request: request)
            }
            return self.response(#"{"error":"private-input-secret"}"#, request: request, status: 500)
        }
        let rows = try await instance.messages(ticketID: ticketID)
        XCTAssertEqual(rows.first?.body, "Hello")
        let ticket = try JSONDecoder().decode(SupportDeskTicket.self, from: Data(row.utf8))
        do { try await instance.setStatus(snapshot: snapshot(ticket), ticket: ticket, status: "closed"); XCTFail("Expected uncertain write") }
        catch SupportDeskClientError.uncertainResult {}
        let rejected = try client { request in self.response(#"{"error":"private-input-secret"}"#, request: request, status: 400) }
        do { try await rejected.setStatus(snapshot: snapshot(ticket), ticket: ticket, status: "closed"); XCTFail("Expected request rejection") }
        catch let SupportDeskClientError.requestFailed(_, message) { XCTAssertFalse(message?.contains("private-input-secret") == true) }
        do { _ = try await instance.messages(ticketID: "../../wrong"); XCTFail("Expected path guard") }
        catch SupportDeskClientError.invalidTicket {}
    }

    func testOwnTicketListUsesOwnerEndpointAndRejectsSupportOrForeignRows() async throws {
        var captured: URLRequest?
        let own = try SupportDeskClient(baseURL: service, siteBaseURL: site, userID: "customer", token: "token") { request in
            captured = request
            return self.response(#"{"isSupport":false,"realtime":true,"tickets":[{"id":"11111111-1111-4111-8111-111111111111","subject":"Help","status":"open","updated_at":"2026-10-23T12:00:00Z","user_id":"customer"}]}"#, request: request)
        }
        let result = try await own.loadOwnTickets()
        XCTAssertEqual(captured?.url?.path, "/api/support/my-tickets")
        XCTAssertEqual(captured?.httpMethod, "GET")
        XCTAssertEqual(captured?.value(forHTTPHeaderField: "Authorization"), "Bearer token")
        XCTAssertFalse(captured?.httpShouldHandleCookies ?? true)
        XCTAssertFalse(result.isSupport)
        XCTAssertEqual(result.tickets.first?.userID, "customer")

        for body in [
            #"{"isSupport":true,"realtime":true,"tickets":[]}"#,
            #"{"isSupport":false,"realtime":true,"tickets":[{"id":"11111111-1111-4111-8111-111111111111","subject":"Help","status":"open","updated_at":"2026-10-23T12:00:00Z","user_id":"other"}]}"#
        ] {
            let invalid = try SupportDeskClient(baseURL: service, siteBaseURL: site, userID: "customer", token: "token") { request in
                self.response(body, request: request)
            }
            do { _ = try await invalid.loadOwnTickets(); XCTFail("Expected owner-scoped response validation") }
            catch SupportDeskClientError.invalidResponse {}
        }
    }

    func testCurrentUserLoadFallsBackToOwnerEndpointOnlyOnForbidden() async throws {
        var paths: [String] = []
        let fallback = try SupportDeskClient(baseURL: service, siteBaseURL: site, userID: "customer", token: "token") { request in
            paths.append(request.url!.path)
            if paths.count == 1 { return self.response(#"{"error":"Support queue unavailable"}"#, request: request, status: 403) }
            return self.response(#"{"isSupport":false,"realtime":true,"tickets":[{"id":"11111111-1111-4111-8111-111111111111","subject":"Help","status":"open","updated_at":"2026-10-23T12:00:00Z","user_id":"customer"}]}"#, request: request)
        }
        let result = try await fallback.loadForCurrentUser(filters: SupportDeskFilters())
        XCTAssertEqual(paths, ["/api/support/tickets", "/api/support/my-tickets"])
        XCTAssertFalse(result.isSupport)
        XCTAssertEqual(result.tickets.first?.userID, "customer")

        paths = []
        let unauthorized = try SupportDeskClient(baseURL: service, siteBaseURL: site, userID: "customer", token: "token") { request in
            paths.append(request.url!.path)
            return self.response(#"{"error":"Sign in"}"#, request: request, status: 401)
        }
        do { _ = try await unauthorized.loadForCurrentUser(filters: SupportDeskFilters()); XCTFail("401 must be preserved") }
        catch SupportDeskClientError.requestFailed(401, _) {}
        XCTAssertEqual(paths, ["/api/support/tickets"])
    }

    func testCustomerCanCreateReplyAndRateOnlyOwnedConversation() async throws {
        let ticket = try JSONDecoder().decode(SupportDeskTicket.self, from: Data(row.replacingOccurrences(of: #""user_id":"customer""#, with: #""user_id":"agent""#).utf8))
        let feedbackTicket = try JSONDecoder().decode(SupportDeskTicket.self, from: Data(#"{"id":"11111111-1111-4111-8111-111111111111","subject":"Help","status":"closed","updated_at":"2026-10-23T12:00:00Z","user_id":"agent","resolution_version":2,"feedback_rating":null,"feedback_comment":null}"#.utf8))
        let customer = try SupportDeskClient(baseURL: service, siteBaseURL: site, userID: "agent", token: "token")
        let ownSnapshot = SupportDeskSnapshot(scope: customer.scope, isSupport: false, realtime: true, tickets: [ticket])
        let feedbackSnapshot = SupportDeskSnapshot(scope: customer.scope, isSupport: false, realtime: true, tickets: [feedbackTicket])
        var captured: URLRequest?
        let writes = try SupportDeskClient(baseURL: service, siteBaseURL: site, userID: "agent", token: "token") { request in
            captured = request
            let body = request.url?.path.hasSuffix("/feedback") == true ? #"{"ok":true}"#
                : request.url?.path.hasSuffix("/messages") == true ? #"{"ok":true,"messageId":"33333333-3333-4333-8333-333333333333"}"#
                : #"{"id":"11111111-1111-4111-8111-111111111111"}"#
            return self.response(body, request: request, status: request.url?.path == "/api/support/tickets" ? 201 : 200)
        }

        let created = try await writes.createTicket(subject: "  Help  ", message: "  Please help.  ")
        XCTAssertEqual(created, ticketID)
        XCTAssertEqual(captured?.url?.path, "/api/support/tickets")
        XCTAssertEqual(captured?.httpMethod, "POST")
        let createBody = try XCTUnwrap(captured?.httpBody).flatMap { try JSONSerialization.jsonObject(with: $0) as? [String: String] }
        XCTAssertEqual(createBody, ["subject": "Help", "message": "Please help."])

        _ = try await writes.reply(snapshot: ownSnapshot, ticket: ticket, body: "A reply", requestID: requestID)
        XCTAssertEqual(captured?.url?.path, "/api/support/tickets/\(ticketID)/messages")
        try await writes.submitFeedback(snapshot: feedbackSnapshot, ticket: feedbackTicket, rating: 4, comment: "Ignored for high rating")
        XCTAssertEqual(captured?.url?.path, "/api/support/tickets/\(ticketID)/feedback")
        let feedbackBody = try XCTUnwrap(captured?.httpBody).flatMap { try JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        XCTAssertEqual(feedbackBody?["rating"] as? Int, 4)
        XCTAssertEqual(feedbackBody?["comment"] as? String, "")
        XCTAssertEqual(feedbackBody?["resolutionVersion"] as? Int, 2)

        let foreign = try JSONDecoder().decode(SupportDeskTicket.self, from: Data(#"{"id":"11111111-1111-4111-8111-111111111111","subject":"Help","status":"closed","updated_at":"2026-10-23T12:00:00Z","user_id":"other","resolution_version":2,"feedback_rating":null,"feedback_comment":null}"#.utf8))
        let foreignSnapshot = SupportDeskSnapshot(scope: customer.scope, isSupport: false, realtime: true, tickets: [foreign])
        do { _ = try await writes.reply(snapshot: foreignSnapshot, ticket: foreign, body: "Reply", requestID: requestID); XCTFail("Customer cannot reply to a foreign ticket") }
        catch SupportDeskClientError.readOnly {}
        do { try await writes.submitFeedback(snapshot: foreignSnapshot, ticket: foreign, rating: 5, comment: ""); XCTFail("Foreign ticket feedback must be rejected") }
        catch SupportDeskClientError.readOnly {}

        let impersonated = try SupportDeskClient(baseURL: service, siteBaseURL: site, userID: "agent", token: "token", impersonationToken: "imp") { request in
            XCTFail("No request should be sent while impersonating")
            return self.response(#"{"id":"11111111-1111-4111-8111-111111111111"}"#, request: request)
        }
        do { _ = try await impersonated.createTicket(subject: "Help", message: "Question"); XCTFail("Impersonation must remain read-only") }
        catch SupportDeskClientError.readOnly {}
    }
}
