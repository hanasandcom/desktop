import Foundation
import XCTest
@testable import Hanasand

final class SupportDeskClientTests: XCTestCase {
    private let service = URL(string: "https://support.synthetic.invalid/api")!
    private let site = URL(string: "https://synthetic.invalid")!
    private let ticketID = "11111111-1111-4111-8111-111111111111"
    private let requestID = "22222222-2222-4222-8222-222222222222"
    private let messageID = "33333333-3333-4333-8333-333333333333"
    private let guestToken = String(repeating: "a", count: 64)
    private let row = #"{"id":"11111111-1111-4111-8111-111111111111","subject":"Help","status":"open","updated_at":"2026-10-23T12:00:00Z","created_at":"2026-10-23T11:00:00Z","user_id":"customer","user_name":"Customer","channel":"human","last_message":"Question","feedback_rating":5,"feedback_comment":"Thanks","resolution_version":2,"reply_count":3}"#

    private func client(send: ((URLRequest) async throws -> (Data, URLResponse))? = nil) throws -> SupportDeskClient {
        try SupportDeskClient(baseURL: service, siteBaseURL: site, userID: "agent", token: "token", organizationID: "org", send: send)
    }

    private func discordClient(siteBaseURL: URL = URL(string: "https://hanasand.com")!,
                               impersonationToken: String = "",
                               send: @escaping (URLRequest) async throws -> (Data, URLResponse)) throws -> SupportDeskClient {
        try SupportDeskClient(baseURL: service, siteBaseURL: siteBaseURL, userID: "agent", token: "token",
                              organizationID: "org", impersonationToken: impersonationToken, send: send)
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

    func testDiscordLinkCodeUsesValidatedNativeOriginAndAuthenticatedNoCookieRequest() async throws {
        var captured: URLRequest?
        let expiry = ISO8601DateFormatter()
        expiry.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let expiration = expiry.string(from: Date().addingTimeInterval(300))
        let instance = try discordClient { request in
            captured = request
            return self.response(#"{"code":"AB12CD34EF56AB78","expiresAt":"\#(expiration)"}"#, request: request)
        }

        let result = try await instance.createDiscordLinkCode()
        XCTAssertEqual(result.code, "AB12CD34EF56AB78")
        XCTAssertEqual(captured?.url?.absoluteString, "https://support.synthetic.invalid/api/support/discord/link-code")
        XCTAssertEqual(captured?.httpMethod, "POST")
        XCTAssertEqual(captured?.httpBody, Data("{}".utf8))
        XCTAssertEqual(captured?.value(forHTTPHeaderField: "Origin"), "https://hanasand.com")
        XCTAssertEqual(captured?.value(forHTTPHeaderField: "Authorization"), "Bearer token")
        XCTAssertEqual(captured?.value(forHTTPHeaderField: "id"), "agent")
        XCTAssertEqual(captured?.value(forHTTPHeaderField: "Cache-Control"), "no-store")
        XCTAssertNil(captured?.value(forHTTPHeaderField: "Cookie"))
        XCTAssertNil(captured?.value(forHTTPHeaderField: "x-api-key"))
        XCTAssertFalse(captured?.httpShouldHandleCookies ?? true)
    }

    func testDiscordLinkCodeRejectsUntrustedOriginAndImpersonationBeforeSending() async throws {
        var sent = false
        let invalidOrigin = try discordClient(siteBaseURL: URL(string: "https://example.invalid")!) { request in
            sent = true
            return self.response("{}", request: request)
        }
        do { _ = try await invalidOrigin.createDiscordLinkCode(); XCTFail("Untrusted website origins must not be sent") }
        catch SupportDeskClientError.invalidServiceURL {}
        XCTAssertFalse(sent)

        let impersonated = try discordClient(impersonationToken: "imp") { request in
            sent = true
            return self.response("{}", request: request)
        }
        do { _ = try await impersonated.createDiscordLinkCode(); XCTFail("A link code must not be issued for an impersonated account") }
        catch SupportDeskClientError.readOnly {}
        XCTAssertFalse(sent)
    }

    func testDiscordLinkCodeRequiresUppercaseHexAndExpiryWithinTenMinutes() async throws {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let now = Date()
        let cases: [(String, String)] = [
            ("ab12cd34ef56ab78", formatter.string(from: now.addingTimeInterval(300))),
            ("AB12CD34EF56AB78", formatter.string(from: now.addingTimeInterval(-1))),
            ("AB12CD34EF56AB78", formatter.string(from: now.addingTimeInterval(601))),
            ("AB12CD34EF56AB7", formatter.string(from: now.addingTimeInterval(300))),
            ("AB12CD34EF56AB7G", formatter.string(from: now.addingTimeInterval(300))),
            ("AB12CD34EF56AB78", "not-a-date"),
        ]
        for (code, expiresAt) in cases {
            let invalid = try discordClient { request in
                self.response(#"{"code":"\#(code)","expiresAt":"\#(expiresAt)"}"#, request: request)
            }
            do { _ = try await invalid.createDiscordLinkCode(now: now); XCTFail("Invalid link code response must be rejected") }
            catch SupportDeskClientError.invalidResponse {}
        }
    }

    func testDiscordLinkCodeFailureStatusesRemainRetryable() async throws {
        for status in [401, 403, 429] {
            let rejected = try discordClient { request in self.response(#"{"error":"temporarily unavailable"}"#, request: request, status: status) }
            do { _ = try await rejected.createDiscordLinkCode(); XCTFail("Expected HTTP \(status) rejection") }
            catch let SupportDeskClientError.requestFailed(actual, _) { XCTAssertEqual(actual, status) }
        }

        let failed = try discordClient { request in self.response(#"{"error":"not echoed"}"#, request: request, status: 500) }
        do { _ = try await failed.createDiscordLinkCode(); XCTFail("Expected an unconfirmed server outcome") }
        catch let SupportDeskClientError.requestFailed(status, message) {
            XCTAssertEqual(status, 0)
            XCTAssertTrue(message?.contains("Request another code") == true)
            XCTAssertFalse(message?.contains("not echoed") == true)
        }
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

    func testGuestSessionRenewsForThirtyDaysAndRotatesAfterExpiry() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let token = String(repeating: "b", count: 64)
        let fresh = try SupportGuestSession.loadOrRefresh(storedValue: nil, now: now) { token }
        XCTAssertEqual(fresh.session.token, token)
        XCTAssertEqual(fresh.session.expiresAt, now.addingTimeInterval(30 * 24 * 60 * 60))
        XCTAssertEqual(DesktopCredential.supportGuestSession.rawValue, "supportGuestSession")

        let renewed = try SupportGuestSession.loadOrRefresh(storedValue: fresh.encodedValue, now: now.addingTimeInterval(10)) {
            XCTFail("A valid guest session must be reused")
            return ""
        }
        XCTAssertEqual(renewed.session.token, token)
        XCTAssertEqual(renewed.session.expiresAt, now.addingTimeInterval(10 + 30 * 24 * 60 * 60))

        let expired = try SupportGuestSession.loadOrRefresh(storedValue: fresh.encodedValue, now: fresh.session.expiresAt) { token }
        XCTAssertEqual(expired.session.token, token)
        XCTAssertNotEqual(expired.encodedValue, fresh.encodedValue)
        XCTAssertThrowsError(try SupportGuestSession.loadOrRefresh(storedValue: nil, now: now) { "not-a-capability" })
    }

    func testGuestChatUsesOnlyCapabilityHeaderAndExistingGuestActions() async throws {
        let ticket = #"{"id":"11111111-1111-4111-8111-111111111111","subject":"Guest question","status":"open","updated_at":"2026-10-23T12:00:00Z","channel":"ai","reply_count":0}"#
        let guest = #"{"id":"11111111-1111-4111-8111-111111111111","channel":"ai","status":"open","pending":false,"has_response":false,"resolution_version":0,"messages":[],"tickets":["# + ticket + #"]}"#
        var captured: [URLRequest] = []
        let client = try SupportGuestChatClient(baseURL: service, token: guestToken) { request in
            captured.append(request)
            let isAction = ((try? JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any])?["action"] as? String) != nil
            let body = request.httpMethod == "GET" || request.url?.path == "/api/support/chat" && !isAction
                ? guest : #"{"ok":true,"ticket":{"id":"11111111-1111-4111-8111-111111111111","status":"closed"}}"#
            return self.response(body, request: request)
        }

        let transcript = try await client.load(conversationID: ticketID)
        XCTAssertEqual(transcript.id, ticketID)
        XCTAssertEqual(captured[0].url?.absoluteString, "https://support.synthetic.invalid/api/support/chat?conversationId=11111111-1111-4111-8111-111111111111")
        let posted = try await client.sendMessage("Question", requestID: requestID, conversationID: ticketID)
        XCTAssertEqual(posted.id, ticketID)
        let sentBody = try XCTUnwrap(captured[1].httpBody).flatMap { try JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        XCTAssertEqual(sentBody?["requestId"] as? String, requestID)
        XCTAssertEqual(sentBody?["message"] as? String, "Question")
        _ = try await client.sendMessage("", requestID: requestID, conversationID: ticketID, handoff: true)
        let handoffBody = try XCTUnwrap(captured[2].httpBody).flatMap { try JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        XCTAssertEqual(handoffBody?["handoff"] as? Bool, true)
        try await client.resolve(conversationID: ticketID)
        try await client.submitFeedback(conversationID: ticketID, resolutionVersion: 2, rating: 3, comment: "Helpful")
        try await client.submitCloseFeedback(conversationID: ticketID, resolutionVersion: 2, foundWhatLookingFor: false, reason: "Still need help")

        for request in captured {
            let headers = Set((request.allHTTPHeaderFields ?? [:]).keys.map { $0.lowercased() })
            let expectedHeaders: Set<String> = request.httpBody == nil
                ? ["accept", "cache-control", "x-support-session"]
                : ["accept", "cache-control", "content-type", "x-support-session"]
            XCTAssertEqual(headers, expectedHeaders)
            XCTAssertEqual(request.value(forHTTPHeaderField: "x-support-session"), guestToken)
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            XCTAssertNil(request.value(forHTTPHeaderField: "id"))
            XCTAssertNil(request.value(forHTTPHeaderField: "x-impersonation-token"))
            XCTAssertNil(request.value(forHTTPHeaderField: "x-organization-id"))
            XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
            XCTAssertFalse(request.httpShouldHandleCookies)
            XCTAssertEqual(request.value(forHTTPHeaderField: "Cache-Control"), "no-store")
        }
    }

    func testVMUnavailablePrefillSanitizesContextAndRequiresAuthenticatedCustomerRoute() throws {
        let now = Date(timeIntervalSince1970: 0)
        let route: [String: String] = ["newTicket": "vm-sudo-password", "vm": "vm 17/../../east\n"]
        let prefill = try XCTUnwrap(SupportVMUnavailableTicketPrefill.fromNativeRoute(
            query: route, isAuthenticated: true, isSupportQueue: false, now: now
        ))
        XCTAssertEqual(prefill.vmName, "vm17....east")
        XCTAssertEqual(prefill.subject, "Sudo password unavailable for vm17....east")
        XCTAssertTrue(prefill.message.contains("I could not display the sudo password for VM vm17....east."))
        XCTAssertTrue(prefill.message.contains("Time: 1970-01-01T00:00:00.000Z\nPage: /vms"))
        XCTAssertFalse(prefill.message.localizedCaseInsensitiveContains("temporary-sudo-secret"))
        XCTAssertLessThanOrEqual(prefill.subject.count, 160)
        XCTAssertLessThanOrEqual(prefill.message.count, 10_000)

        XCTAssertNil(SupportVMUnavailableTicketPrefill.fromNativeRoute(
            query: route, isAuthenticated: false, isSupportQueue: false, now: now
        ), "Guest support must not receive authenticated ticket prefill data.")
        XCTAssertNil(SupportVMUnavailableTicketPrefill.fromNativeRoute(
            query: route, isAuthenticated: true, isSupportQueue: true, now: now
        ), "The global Support queue must not start a customer ticket composer.")
        XCTAssertNil(SupportVMUnavailableTicketPrefill.fromNativeRoute(
            query: ["newTicket": "other", "vm": "vm-17"], isAuthenticated: true, isSupportQueue: false, now: now
        ))
        XCTAssertNil(SupportVMUnavailableTicketPrefill.fromNativeRoute(
            query: ["newTicket": "vm-sudo-password", "vm": " /!?\n"], isAuthenticated: true, isSupportQueue: false, now: now
        ))
    }

    func testGuestHumanAgentStatusHandlesAssignedMissingAndMalformedName() throws {
        func decode(agentName: Any? = nil, messages: [[String: Any]] = [], channel: String = "human") throws -> SupportGuestConversation {
            var object: [String: Any] = ["channel": channel, "status": "open", "pending": false, "messages": messages, "tickets": []]
            if let agentName { object["agent_name"] = agentName }
            return try JSONDecoder().decode(SupportGuestConversation.self, from: JSONSerialization.data(withJSONObject: object))
        }
        let assigned = try decode(agentName: "  Sam Agent  ")
        XCTAssertEqual(assigned.agentName, "Sam Agent")
        XCTAssertEqual(assigned.humanAgentStatus, "Speaking with Sam Agent")
        let supportMessage: [[String: Any]] = [[
            "id": "33333333-3333-4333-8333-333333333333", "sender_kind": "support", "sender_name": "Support Agent",
            "body": "I can help", "created_at": "2026-10-25T00:00:00Z"
        ]]
        XCTAssertEqual(try decode(agentName: "", messages: supportMessage).humanAgentStatus, "Speaking with Support Agent")
        XCTAssertEqual(try decode().humanAgentStatus, "Waiting for support")
        XCTAssertEqual(try decode(agentName: String(repeating: "x", count: 121), messages: supportMessage).humanAgentStatus, "Speaking with Support Agent")

        let malformed = try decode(agentName: 7)
        XCTAssertNil(malformed.agentName)
        XCTAssertEqual(malformed.humanAgentStatus, "Waiting for support")
        let ai = try decode(agentName: "Sam Agent", channel: "ai")
        XCTAssertNil(ai.humanAgentStatus)
    }

    func testGuestConnectIssuesFreshOneUseTicketWithSessionCapability() async throws {
        let firstTicket = String(repeating: "b", count: 64)
        let secondTicket = String(repeating: "c", count: 64)
        var captured: [URLRequest] = []
        let tickets = [firstTicket, secondTicket]
        let client = try SupportGuestChatClient(baseURL: service, token: guestToken) { request in
            captured.append(request)
            let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: String])
            XCTAssertEqual(payload, ["action": "connect"])
            let body = try JSONSerialization.data(withJSONObject: ["ticket": tickets[captured.count - 1]])
            return (body, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!)
        }

        let issuedFirst = try await client.connectTicket()
        let issuedSecond = try await client.connectTicket()
        XCTAssertEqual(issuedFirst, firstTicket)
        XCTAssertEqual(issuedSecond, secondTicket)
        XCTAssertEqual(captured.count, 2)
        for request in captured {
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.url?.absoluteString, "https://support.synthetic.invalid/api/support/chat")
            XCTAssertEqual(request.value(forHTTPHeaderField: "x-support-session"), guestToken)
            XCTAssertEqual(request.value(forHTTPHeaderField: "Cache-Control"), "no-store")
            XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            XCTAssertFalse(request.httpShouldHandleCookies)
        }

        let invalidBodies = [#"{}"#, #"{"ticket":"short"}"#,
                             String(data: try JSONSerialization.data(withJSONObject: ["ticket": String(repeating: "G", count: 64)]), encoding: .utf8)!]
        for invalidBody in invalidBodies {
            let invalid = try SupportGuestChatClient(baseURL: service, token: guestToken) { request in
                self.response(invalidBody, request: request)
            }
            do { _ = try await invalid.connectTicket(); XCTFail("Malformed or missing one-use ticket must be rejected") }
            catch SupportDeskClientError.invalidResponse {}
        }
    }

    func testGuestTransportRejectsInvalidCapabilityAndMessageInput() async throws {
        XCTAssertThrowsError(try SupportGuestChatClient(baseURL: service, token: "short"))
        let client = try SupportGuestChatClient(baseURL: service, token: guestToken) { request in
            self.response("{}", request: request)
        }
        XCTAssertThrowsError(try SupportGuestChatClient(baseURL: URL(string: "http://support.synthetic.invalid/api")!, token: guestToken))
        do { _ = try await client.sendMessage("", requestID: requestID, conversationID: ticketID); XCTFail("An empty guest message must be rejected") }
        catch SupportDeskClientError.invalidDraft(_) {}
        do { _ = try await client.sendMessage(String(repeating: "x", count: 4001), requestID: requestID, conversationID: ticketID); XCTFail("An oversized guest message must be rejected") }
        catch SupportDeskClientError.invalidDraft(_) {}
        do { _ = try await client.sendMessage(String(repeating: "😀", count: 2001), requestID: requestID, conversationID: ticketID); XCTFail("UTF-16 message size must match the server limit") }
        catch SupportDeskClientError.invalidDraft(_) {}
        do { try await client.submitCloseFeedback(conversationID: ticketID, resolutionVersion: 1, foundWhatLookingFor: false, reason: String(repeating: "😀", count: 1001)); XCTFail("UTF-16 feedback size must match the server limit") }
        catch SupportDeskClientError.invalidDraft(_) {}
        do { try await client.resolve(conversationID: "../../ticket"); XCTFail("A malformed conversation ID must be rejected") }
        catch SupportDeskClientError.invalidTicket {}

        let different = #"{"id":"44444444-4444-4444-8444-444444444444","channel":"ai","status":"open","pending":false,"has_response":false,"messages":[],"tickets":[{"id":"44444444-4444-4444-8444-444444444444","subject":"Other chat","status":"open","updated_at":"2026-10-23T12:00:00Z"}]}"#
        let mismatchedReceipt = try SupportGuestChatClient(baseURL: service, token: guestToken) { request in
            self.response(different, request: request)
        }
        do { _ = try await mismatchedReceipt.sendMessage("Question", requestID: requestID, conversationID: ticketID); XCTFail("A mismatched conversation receipt must remain uncertain") }
        catch SupportDeskClientError.uncertainResult {}
    }

    func testGuestEmptySessionUsesBackendNoConversationEnvelope() async throws {
        let client = try SupportGuestChatClient(baseURL: service, token: guestToken) { request in
            self.response(#"{"id":null,"channel":"ai","status":"open","pending":false,"messages":[],"tickets":[]}"#, request: request)
        }
        let conversation = try await client.load()
        XCTAssertNil(conversation.id)
        XCTAssertEqual(conversation.channel, "ai")
        XCTAssertEqual(conversation.status, "open")
        XCTAssertFalse(conversation.hasResponse)
        XCTAssertTrue(conversation.tickets.isEmpty)
    }
}
