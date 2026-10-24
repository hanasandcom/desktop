import Foundation
import XCTest
@testable import Hanasand

final class NativeFindingsActionsTests: XCTestCase {
    func testWatchlistPostsNativelyWithScopedAuthenticatedNoCookieRequest() async throws {
        var settings = makeSettings()
        settings.selectedOrganizationID = "org-1"
        settings.selectedOrganizationUserID = settings.userID
        var captured: URLRequest?
        let client = try NativeFindingsActionsClient(settings: settings) { request in
            captured = request
            return (Data(#"{"watchlist":{"id":"watchlist-1"}}"#.utf8), self.response(for: request))
        }
        let receipt = try await client.perform(.saveWatchlist, input: NativeFindingsActionInput(terms: "acme,ACME\nexample.com"))
        let request = try XCTUnwrap(captured)
        XCTAssertEqual(request.url?.host, "hanasand.com")
        XCTAssertEqual(request.url?.path, "/api/findings/watchlists")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-token")
        XCTAssertEqual(request.value(forHTTPHeaderField: "id"), "user-1")
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-organization-id"), "org-1")
        XCTAssertFalse(request.httpShouldHandleCookies)
        XCTAssertEqual(receipt.message, "Watchlist terms saved.")
        let body = try XCTUnwrap(request.httpBody.flatMap { try JSONSerialization.jsonObject(with: $0) as? [String: Any] })
        XCTAssertEqual(body["tenantId"] as? String, "org-1")
        XCTAssertEqual(body["organizationId"] as? String, "org-1")
        XCTAssertEqual(body["terms"] as? [String], ["acme", "example.com"])
    }

    func testSourceRequestRequiresDurableReceiptAndUsesPublicOnlyInactivePayload() async throws {
        let settings = makeSettings()
        var captured: URLRequest?
        let client = try NativeFindingsActionsClient(settings: settings) { request in
            captured = request
            return (Data(#"{"request":{"id":"request-1"},"source":{"id":"source-1"}}"#.utf8), self.response(for: request))
        }
        _ = try await client.perform(.submitTelegramSource,
            input: NativeFindingsActionInput(terms: "acme", telegramTarget: "https://t.me/public_channel"))
        let body = try XCTUnwrap(captured?.httpBody.flatMap { try JSONSerialization.jsonObject(with: $0) as? [String: Any] })
        XCTAssertEqual(body["type"] as? String, "telegram_channel")
        XCTAssertEqual(body["activate"] as? Bool, false)
        XCTAssertEqual(body["target"] as? String, "https://t.me/public_channel")
    }

    func testRejectsInvalidWebhookAndImpersonationBeforeSending() async throws {
        var settings = makeSettings()
        var sends = 0
        let client = try NativeFindingsActionsClient(settings: settings) { request in
            sends += 1
            return (Data("{}".utf8), self.response(for: request))
        }
        do {
            _ = try await client.perform(.testWebhook, input: NativeFindingsActionInput(webhookURL: "http://insecure.example/hook"))
            XCTFail("Expected insecure URL rejection")
        } catch { XCTAssertEqual(error as? NativeFindingsActionsError, .invalidInput("Enter a valid HTTPS webhook URL.")) }
        XCTAssertEqual(sends, 0)

        settings.impersonationToken = "active"
        XCTAssertThrowsError(try NativeFindingsActionsClient(settings: settings))
    }

    func testAmbiguousServerFailureRequiresRefreshAndAdvisoryCaseUsesDurableWorkflow() async throws {
        let client = try NativeFindingsActionsClient(settings: makeSettings()) { request in
            (Data("{}".utf8), self.response(for: request, status: 503))
        }
        do {
            _ = try await client.perform(.runCollection, input: NativeFindingsActionInput())
            XCTFail("Expected uncertain outcome")
        } catch { XCTAssertEqual(error as? NativeFindingsActionsError, .uncertainOutcome) }

        var requests: [URLRequest] = []
        let replies = [
            "/api/findings/exposure-claims/ingest": #"{"accepted":1}"#,
            "/api/findings/watchlists": #"{"watchlist":{"id":"watchlist-1"}}"#,
            "/api/findings/alerts/rebuild": #"{"savedAlertCount":1,"alerts":[{"id":"finding-1","company":"Acme"}]}"#,
            "/api/findings/alerts/finding-1/case-handoff": #"{"case":{"id":"case-1"}}"#
        ]
        let workflow = try NativeFindingsActionsClient(settings: makeSettings()) { request in
            requests.append(request)
            let payload = replies[request.url!.path] ?? "{}"
            return (Data(payload.utf8), self.response(for: request))
        }
        let receipt = try await workflow.perform(.openCase, input: NativeFindingsActionInput(
            terms: "Acme", actor: "Actor", company: "Acme", claimedData: "Public incident details", sourceURL: "https://example.com/advisory"))
        XCTAssertEqual(requests.map { $0.url!.path }, [
            "/api/findings/exposure-claims/ingest", "/api/findings/watchlists", "/api/findings/alerts/rebuild",
            "/api/findings/alerts/finding-1/case-handoff"
        ])
        XCTAssertEqual(receipt.action, .openCase)
        XCTAssertEqual(receipt.message, "Case case-1 opened from public advisory evidence.")
        let handoff = try XCTUnwrap(requests.last?.httpBody.flatMap { try JSONSerialization.jsonObject(with: $0) as? [String: Any] })
        XCTAssertEqual(handoff["idempotencyKey"] as? String, "dashboard-public-advisory-case:finding-1")
    }

    func testAdvisoryRequiresHTTPSAndExplicitFieldsBeforeSending() async throws {
        var sends = 0
        let client = try NativeFindingsActionsClient(settings: makeSettings()) { request in
            sends += 1
            return (Data("{}".utf8), self.response(for: request))
        }
        do {
            _ = try await client.perform(.ingestAdvisory, input: NativeFindingsActionInput(actor: "Actor", company: "Acme", claimedData: "Data", sourceURL: "http://example.com/report"))
            XCTFail("Expected HTTPS validation")
        } catch { XCTAssertEqual(error as? NativeFindingsActionsError, .invalidInput("Enter the actor, affected company, exposure details, and an HTTPS source URL.")) }
        XCTAssertEqual(sends, 0)
    }

    private func makeSettings() -> HanasandDesktopSettings {
        var settings = HanasandDesktopSettings()
        settings.userID = "user-1"
        settings.authToken = "test-token"
        return settings
    }

    private func response(for request: URLRequest, status: Int = 200) -> HTTPURLResponse {
        HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
    }
}
