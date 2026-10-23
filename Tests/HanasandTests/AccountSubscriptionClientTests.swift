import Foundation
import XCTest
@testable import Hanasand

final class AccountSubscriptionClientTests: XCTestCase {
    private func http(_ json: String, request: URLRequest, status: Int = 200) -> (Data, URLResponse) {
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        return (Data(json.utf8), response)
    }

    func testLoadUsesAuthenticatedReadOnlyNoStoreEndpointAndSelectsSafeFields() async throws {
        var captured: URLRequest?
        let client = try AccountSubscriptionClient(baseURL: URL(string: "https://api.hanasand.test/api")!, userID: "owner", token: "token_abc-123") { request in
            captured = request
            return self.http(#"{"subscription":{"planId":"plus","status":"active","currentPeriodStart":"2026-10-01T00:00:00.000Z","currentPeriodEnd":"2026-11-01T00:00:00.000Z","cancelAtPeriodEnd":false,"stripeCustomerId":"must-not-decode"},"entitlements":[{"planId":"plus","features":["traffic-map"]}],"quotas":[{"key":"searchesPerDay","limit":50,"used":4,"remaining":46,"resetsAt":"2026-10-24T00:00:00.000Z","secret":"ignored"}],"paymentMethod":"ignored"}"#, request: request)
        }

        let result = try await client.load()
        XCTAssertEqual(result.subscription?.planId, "plus")
        XCTAssertEqual(result.entitlements.map(\.features), [["traffic-map"]])
        XCTAssertEqual(result.quotas.first?.remaining, 46)
        XCTAssertEqual(captured?.url?.absoluteString, "https://api.hanasand.test/api/billing/subscription")
        XCTAssertEqual(captured?.httpMethod, "GET")
        XCTAssertEqual(captured?.value(forHTTPHeaderField: "Authorization"), "Bearer token_abc-123")
        XCTAssertEqual(captured?.value(forHTTPHeaderField: "id"), "owner")
        XCTAssertEqual(captured?.value(forHTTPHeaderField: "Cache-Control"), "no-store")
        XCTAssertNil(captured?.httpBody)
        XCTAssertFalse(captured?.httpShouldHandleCookies ?? true)
    }

    func testLoadPreservesNoSubscriptionAndUnknownQuota() async throws {
        let client = try AccountSubscriptionClient(baseURL: URL(string: "https://api.hanasand.test/api")!, userID: "owner", token: "token") { request in
            self.http(#"{"subscription":null,"entitlements":[],"quotas":[{"key":"searchesPerDay","limit":null,"used":0,"remaining":null,"resetsAt":null}]}"#, request: request)
        }

        let result = try await client.load()
        XCTAssertNil(result.subscription)
        XCTAssertNil(result.quotas.first?.limit)
        XCTAssertNil(result.quotas.first?.remaining)
    }

    func testLoadForwardsImpersonationContextWhenPresent() async throws {
        var captured: URLRequest?
        let client = try AccountSubscriptionClient(baseURL: URL(string: "https://api.hanasand.test/api")!, userID: "admin", token: "token", impersonationToken: "scope-token") { request in
            captured = request
            return self.http(#"{"subscription":null,"entitlements":[],"quotas":[]}"#, request: request)
        }

        _ = try await client.load()
        XCTAssertEqual(captured?.value(forHTTPHeaderField: "x-impersonation-token"), "scope-token")
    }

    func testBillingPortalUsesOwnAccountPostAndValidatesStripeDestination() async throws {
        var captured: URLRequest?
        let client = try AccountSubscriptionClient(baseURL: URL(string: "https://api.hanasand.test/api")!, userID: "owner", token: "token") { request in
            captured = request
            return self.http(#"{"url":"https://billing.stripe.com/p/session/example"}"#, request: request)
        }

        let url = try await client.createBillingPortalURL()

        XCTAssertEqual(url.absoluteString, "https://billing.stripe.com/p/session/example")
        XCTAssertEqual(captured?.url?.absoluteString, "https://api.hanasand.test/api/billing/portal")
        XCTAssertEqual(captured?.httpMethod, "POST")
        XCTAssertNil(captured?.httpBody)
        XCTAssertEqual(captured?.value(forHTTPHeaderField: "Authorization"), "Bearer token")
        XCTAssertEqual(captured?.value(forHTTPHeaderField: "id"), "owner")
        XCTAssertEqual(captured?.value(forHTTPHeaderField: "Cache-Control"), "no-store")
        XCTAssertFalse(captured?.httpShouldHandleCookies ?? true)
    }

    func testBillingPortalRejectsImpersonationAndUnsafeDestinations() async throws {
        var wasSent = false
        let impersonating = try AccountSubscriptionClient(baseURL: URL(string: "https://api.hanasand.test/api")!, userID: "admin", token: "token", impersonationToken: "view-token") { request in
            wasSent = true
            return self.http(#"{"url":"https://billing.stripe.com/p/session/example"}"#, request: request)
        }
        do { _ = try await impersonating.createBillingPortalURL(); XCTFail("Expected own-account restriction") }
        catch AccountSubscriptionClientError.impersonationUnsupported {}
        XCTAssertFalse(wasSent)

        for value in ["http://billing.stripe.com/p/session/example", "https://billing.stripe.com.attacker.test/p/session/example", "https://user@billing.stripe.com/p/session/example", "https://billing.stripe.com:8443/p/session/example"] {
            let unsafe = try AccountSubscriptionClient(baseURL: URL(string: "https://api.hanasand.test/api")!, userID: "owner", token: "token") { request in
                self.http(#"{"url":""# + value + #""}"#, request: request)
            }
            do { _ = try await unsafe.createBillingPortalURL(); XCTFail("Expected unsafe billing URL to be rejected") }
            catch AccountSubscriptionClientError.invalidPortalURL {}
        }
    }

    func testClientRejectsInsecureURLAndMissingCredentials() throws {
        XCTAssertThrowsError(try AccountSubscriptionClient(baseURL: URL(string: "http://api.hanasand.test/api")!, userID: "owner", token: "token"))
        XCTAssertThrowsError(try AccountSubscriptionClient(baseURL: URL(string: "https://api.hanasand.test/api")!, userID: "", token: "token"))
        XCTAssertThrowsError(try AccountSubscriptionClient(baseURL: URL(string: "https://api.hanasand.test/api")!, userID: "owner", token: ""))
    }

    func testLoadRejectsServerErrorsAndMalformedPayload() async throws {
        let denied = try AccountSubscriptionClient(baseURL: URL(string: "https://api.hanasand.test/api")!, userID: "owner", token: "token") { request in
            self.http(#"{"error":"forbidden"}"#, request: request, status: 403)
        }
        do { _ = try await denied.load(); XCTFail("Expected authorization failure") }
        catch AccountSubscriptionClientError.requestFailed(403) {}

        let malformed = try AccountSubscriptionClient(baseURL: URL(string: "https://api.hanasand.test/api")!, userID: "owner", token: "token") { request in
            self.http(#"{"subscription":"not-an-object"}"#, request: request)
        }
        do { _ = try await malformed.load(); XCTFail("Expected malformed response failure") }
        catch AccountSubscriptionClientError.invalidResponse {}
    }
}
