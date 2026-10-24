import Foundation
import XCTest

@testable import Hanasand

final class BrowserUsageClientTests: XCTestCase {
    private let api = URL(string: "https://api.example.test/api")!

    func testLoadsAuthenticatedAccountUsageFromBrowserRunsContract() async throws {
        var captured: URLRequest?
        let client = try makeClient { request in
            captured = request
            let body = #"{"runs":[],"quota":{"plan":"free","limit":20,"used":7,"remaining":13,"active":2,"paid":false,"advancedAnalysis":false,"sessionSeconds":90,"concurrentLimit":3,"identityKind":"user"}}"#
            return (Data(body.utf8), Self.response(for: request, status: 200))
        }

        let usage = try await client.load()

        XCTAssertEqual(captured?.url?.absoluteString, "https://api.example.test/api/browser/runs")
        XCTAssertEqual(captured?.httpMethod, "GET")
        XCTAssertEqual(captured?.value(forHTTPHeaderField: "Authorization"), "Bearer session-token")
        XCTAssertEqual(captured?.value(forHTTPHeaderField: "id"), "owner.test")
        XCTAssertEqual(captured?.value(forHTTPHeaderField: "Cache-Control"), "no-store")
        XCTAssertNil(captured?.value(forHTTPHeaderField: "Cookie"))
        XCTAssertNil(captured?.httpBody)
        XCTAssertFalse(captured?.httpShouldHandleCookies ?? true)
        XCTAssertEqual(usage, BrowserUsage(plan: "free", runsToday: 7, activeRuns: 2,
                                           dailyLimit: 20, concurrentLimit: 3, paid: false,
                                           advancedAnalysis: false))
        XCTAssertEqual(usage.runCountLabel, "7 / 20 runs today")
        XCTAssertEqual(usage.concurrencyLabel, "2 / 3 active")
    }

    func testUnmeteredPlanUsesExplicitUnlimitedUsageLabels() async throws {
        let client = try makeClient { request in
            let body = #"{"runs":[],"quota":{"plan":"business","limit":null,"used":21,"remaining":null,"active":1,"paid":true,"advancedAnalysis":true,"sessionSeconds":1800,"concurrentLimit":null,"identityKind":"user"}}"#
            return (Data(body.utf8), Self.response(for: request, status: 200))
        }

        let usage = try await client.load()

        XCTAssertEqual(usage.runCountLabel, "21 runs today")
        XCTAssertEqual(usage.concurrencyLabel, "1 active")
        XCTAssertTrue(usage.paid)
        XCTAssertTrue(usage.advancedAnalysis)
    }

    func testRejectsMalformedUsageAndUnauthorizedResponses() async throws {
        let malformed = try makeClient { request in
            let body = #"{"runs":[],"quota":{"plan":"free","limit":20,"used":true,"active":0,"paid":false,"advancedAnalysis":false,"sessionSeconds":90,"concurrentLimit":3}}"#
            return (Data(body.utf8), Self.response(for: request, status: 200))
        }
        do {
            _ = try await malformed.load()
            XCTFail("Malformed usage values must be rejected")
        } catch { XCTAssertEqual(error as? BrowserUsageError, .invalidResponse) }

        let unauthorized = try makeClient { request in
            (Data(#"{"error":"Unauthorized."}"#.utf8), Self.response(for: request, status: 401))
        }
        do {
            _ = try await unauthorized.load()
            XCTFail("Unauthorized usage requests must be surfaced")
        } catch { XCTAssertEqual(error as? BrowserUsageError, .requestFailed(401)) }
    }

    func testRequiresValidAuthenticatedOwnerAndHTTPSEndpoint() throws {
        XCTAssertThrowsError(try BrowserUsageClient(apiBaseURL: api, userID: "", token: "token")) {
            XCTAssertEqual($0 as? BrowserUsageError, .signInRequired)
        }
        XCTAssertThrowsError(try BrowserUsageClient(apiBaseURL: api, userID: "owner.test", token: "bad token")) {
            XCTAssertEqual($0 as? BrowserUsageError, .invalidCredentials)
        }
        XCTAssertThrowsError(try BrowserUsageClient(apiBaseURL: URL(string: "http://api.example.test/api")!, userID: "owner.test", token: "token")) {
            XCTAssertEqual($0 as? BrowserUsageError, .invalidEndpoint)
        }
    }

    func testLoadsExactPublicAggregateStatsWithoutIdentityOrCookies() async throws {
        var captured: URLRequest?
        let stats = try await BrowserUsageClient.loadGlobalStats(apiBaseURL: api) { request in
            captured = request
            return (Data(#"{"runs24h":4321,"darkweb_runs24h":37}"#.utf8), Self.response(for: request, status: 200))
        }

        XCTAssertEqual(captured?.url?.absoluteString, "https://api.example.test/api/browser/stats")
        XCTAssertEqual(captured?.httpMethod, "GET")
        XCTAssertEqual(captured?.value(forHTTPHeaderField: "Accept"), "application/json")
        XCTAssertEqual(captured?.value(forHTTPHeaderField: "Cache-Control"), "no-store")
        XCTAssertNil(captured?.value(forHTTPHeaderField: "Authorization"))
        XCTAssertNil(captured?.value(forHTTPHeaderField: "id"))
        XCTAssertNil(captured?.value(forHTTPHeaderField: "Cookie"))
        XCTAssertNil(captured?.url?.query)
        XCTAssertFalse(captured?.httpShouldHandleCookies ?? true)
        XCTAssertEqual(stats, BrowserGlobalStats(runs24h: 4_321, darkwebRuns24h: 37))
    }

    func testPublicAggregateStatsRejectInvalidCountsAndUnexpectedScopeFields() async throws {
        for body in [
            #"{"runs24h":true,"darkweb_runs24h":0}"#,
            #"{"runs24h":-1,"darkweb_runs24h":0}"#,
            #"{"runs24h":1.25,"darkweb_runs24h":0}"#,
            #"{"runs24h":1,"darkweb_runs24h":1.5}"#,
            #"{"runs24h":9223372036854775808,"darkweb_runs24h":0}"#,
            #"{"runs24h":1,"darkweb_runs24h":0,"userId":"owner.test"}"#,
            #"{"runs24h":1}"#,
        ] {
            do {
                _ = try await BrowserUsageClient.loadGlobalStats(apiBaseURL: api) { request in
                    (Data(body.utf8), Self.response(for: request, status: 200))
                }
                XCTFail("Unexpected aggregate response must be rejected")
            } catch { XCTAssertEqual(error as? BrowserGlobalStatsError, .invalidResponse) }
        }
    }

    func testPublicAggregateStatsBoundedTransportAndHTTPFailures() async throws {
        do {
            _ = try await BrowserUsageClient.loadGlobalStats(apiBaseURL: api) { request in
                (Data(repeating: 0x20, count: BrowserUsageClient.responseByteLimit + 1), Self.response(for: request, status: 200))
            }
            XCTFail("Oversized aggregate payload must be rejected")
        } catch { XCTAssertEqual(error as? BrowserGlobalStatsError, .responseTooLarge) }

        do {
            _ = try await BrowserUsageClient.loadGlobalStats(apiBaseURL: api) { request in
                (Data(#"{"error":"unavailable"}"#.utf8), Self.response(for: request, status: 503))
            }
            XCTFail("Aggregate endpoint failure must be surfaced")
        } catch { XCTAssertEqual(error as? BrowserGlobalStatsError, .requestFailed(503)) }
    }

    func testPublicAggregateStatsRejectInvalidOriginAndCrossOriginResponse() async throws {
        for endpoint in [URL(string: "http://api.example.test/api")!, URL(string: "https://user:pass@api.example.test/api")!] {
            do {
                _ = try await BrowserUsageClient.loadGlobalStats(apiBaseURL: endpoint) { request in
                    (Data(#"{"runs24h":0,"darkweb_runs24h":0}"#.utf8), Self.response(for: request, status: 200))
                }
                XCTFail("Invalid aggregate API origin must be rejected")
            } catch { XCTAssertEqual(error as? BrowserGlobalStatsError, .invalidEndpoint) }
        }

        do {
            _ = try await BrowserUsageClient.loadGlobalStats(apiBaseURL: api) { request in
                let response = HTTPURLResponse(url: URL(string: "https://other.example.test/api/browser/stats")!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (Data(#"{"runs24h":0,"darkweb_runs24h":0}"#.utf8), response)
            }
            XCTFail("Cross-origin aggregate responses must be rejected")
        } catch { XCTAssertEqual(error as? BrowserGlobalStatsError, .invalidResponse) }
    }

    private func makeClient(send: @escaping BrowserUsageClient.Sender) throws -> BrowserUsageClient {
        try BrowserUsageClient(apiBaseURL: api, userID: "owner.test", token: "session-token", send: send)
    }

    private static func response(for request: URLRequest, status: Int) -> HTTPURLResponse {
        HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
    }
}
