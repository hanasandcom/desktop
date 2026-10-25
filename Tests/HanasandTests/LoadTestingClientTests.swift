import Foundation
import XCTest
@testable import Hanasand

final class LoadTestingClientTests: XCTestCase {
    func testResultReportParsesTrendSeriesAndPreviousRunComparison() throws {
        let payload = #"{"id":"run-17","url":"https://example.com","status":"done","latest_run_summary":{"requests":120,"checks":100,"failures":3,"failureRate":0.03,"duration":{"p50":42,"p95":187},"rps":[{"time":"0s","value":4},{"time":"10s","value":12}],"latency":[{"time":"0s","p50":40,"p95":120},{"time":"10s","p50":45,"p95":187}],"errors":[{"time":"10s","count":3}]},"previous_run_summary":{"requests":100,"failureRate":0.02,"duration":{"p50":50,"p95":210},"rps":[{"time":"0s","value":10}]},"p95_delta_ms":23}"#
        let test = try JSONDecoder().decode(DashboardRecentTest.self, from: Data(payload.utf8))

        let latest = try XCTUnwrap(test.reportSummary)
        XCTAssertEqual(latest.requests, 120)
        XCTAssertEqual(latest.checks, 100)
        XCTAssertEqual(latest.failures, 3)
        XCTAssertEqual(latest.failureRate, 0.03)
        XCTAssertEqual(latest.duration("p50"), 42)
        XCTAssertEqual(latest.duration("p95"), 187)
        XCTAssertEqual(latest.series.map(\.name), ["rps", "latency", "errors"])
        XCTAssertEqual(latest.series[0].title, "Requests per second")
        XCTAssertEqual(latest.series[0].points[1].time, "10s")
        XCTAssertEqual(latest.series[0].points[1].values["value"], 12)
        XCTAssertEqual(latest.series[1].points[1].values["p50"], 45)
        XCTAssertEqual(latest.series[1].points[1].values["p95"], 187)
        XCTAssertEqual(latest.series[2].points[0].values["count"], 3)
        XCTAssertTrue(latest.hasTimeSeries)

        let previous = try XCTUnwrap(test.previousReportSummary)
        XCTAssertEqual(previous.requests, 100)
        XCTAssertEqual(previous.duration("p95"), 210)
        XCTAssertEqual(test.p95DeltaLabel, "faster 23ms")
    }

    func testResultReportHandlesEmptyAndBoundedChartData() throws {
        let emptyPayload = #"{"id":"run-empty","url":"https://example.com","status":"done","summary":{"requests":4,"duration":{"p95":90},"rps":[],"latency":[{"time":"bad","p50":-1},{"time":"also bad"}],"errors":[]}}"#
        let empty = try JSONDecoder().decode(DashboardRecentTest.self, from: Data(emptyPayload.utf8))
        let summary = try XCTUnwrap(empty.reportSummary)
        XCTAssertFalse(summary.hasTimeSeries)
        XCTAssertTrue(summary.series.isEmpty)
        XCTAssertEqual(summary.requests, 4)
        XCTAssertEqual(summary.duration("p95"), 90)

        let points = (0..<302).map { "{\"time\":\"\($0)s\",\"value\":\($0)}" }.joined(separator: ",")
        let boundedPayload = "{\"id\":\"run-many\",\"url\":\"https://example.com\",\"status\":\"done\",\"summary\":{\"rps\":[\(points)]}}"
        let bounded = try JSONDecoder().decode(DashboardRecentTest.self, from: Data(boundedPayload.utf8))
        let rps = try XCTUnwrap(bounded.reportSummary?.series.first)
        XCTAssertEqual(rps.name, "rps")
        XCTAssertEqual(rps.points.count, 300)
        XCTAssertEqual(rps.points.last?.time, "299s")
    }

    func testAnonymousQuotaHistoryAndCreateUseOnlyPersistentClientIdentity() async throws {
        let clientID = "4e57a3bf-41da-46d8-9d85-0a29d7e87d43"
        var requests: [URLRequest] = []
        let client = try makeAnonymousClient(id: clientID) { request in
            requests.append(request)
            let body: String
            switch request.url?.path {
            case "/api/tests/quota": body = #"{"plan":"free","limit":5,"used":1,"remaining":4,"resetsAt":null}"#
            case "/api/tests/mine": body = "[]"
            default: body = #"{"id":"run-guest-1","url":"https://example.com/health","status":"queued"}"#
            }
            return (Data(body.utf8), Self.response(status: 200))
        }

        XCTAssertTrue(client.canRead)
        XCTAssertTrue(client.canWrite)
        XCTAssertFalse(client.isAuthenticated)
        XCTAssertFalse(client.canRerun)
        let quota = try await client.quota()
        let history = try await client.history(.mine)
        XCTAssertEqual(quota.remaining, 4)
        XCTAssertTrue(history.isEmpty)
        _ = try await client.create(url: "https://example.com/health", scenario: LoadTestingScenario.all[0])

        XCTAssertEqual(requests.map { $0.url?.path }, ["/api/tests/quota", "/api/tests/mine", "/api/test"])
        for request in requests {
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            XCTAssertNil(request.value(forHTTPHeaderField: "id"))
            XCTAssertNil(request.value(forHTTPHeaderField: "x-impersonation-token"))
            XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
            XCTAssertFalse(request.httpShouldHandleCookies)
        }
        XCTAssertEqual(requests[0].value(forHTTPHeaderField: "x-load-test-client-id"), clientID)
        XCTAssertEqual(requests[1].value(forHTTPHeaderField: "x-load-test-client-id"), clientID)
        XCTAssertEqual(requests[2].value(forHTTPHeaderField: "x-load-test-client-id"), clientID)
    }

    func testAnonymousSharedResultIsPublicAndDoesNotSendClientOrAccountHeaders() async throws {
        var captured: URLRequest?
        let client = try makeAnonymousClient(id: "4e57a3bf-41da-46d8-9d85-0a29d7e87d43", send: { request in
            captured = request
            return (Data(#"{"id":"run-guest-2","url":"https://example.com","status":"completed"}"#.utf8), Self.response(status: 200))
        })

        let result = try await client.result(id: "run-guest-2")
        XCTAssertEqual(result.id, "run-guest-2")
        XCTAssertEqual(captured?.url?.path, "/api/test/run-guest-2")
        XCTAssertNil(captured?.value(forHTTPHeaderField: "x-load-test-client-id"))
        XCTAssertNil(captured?.value(forHTTPHeaderField: "Authorization"))
        XCTAssertNil(captured?.value(forHTTPHeaderField: "id"))
        XCTAssertNil(captured?.value(forHTTPHeaderField: "Cookie"))
    }

    func testAnonymousClientsCannotRerunAndRequireAStableUUID() async throws {
        var requests = 0
        let client = try makeAnonymousClient(id: "4e57a3bf-41da-46d8-9d85-0a29d7e87d43", send: { _ in
            requests += 1
            return (Data("{}".utf8), Self.response(status: 200))
        })
        do {
            try await client.rerun(id: "run-guest-3")
            XCTFail("Anonymous clients must not rerun saved tests")
        } catch let error as LoadTestingClientError {
            guard case .accountRequiredForRerun = error else { return XCTFail("Unexpected error: \(error)") }
        }
        XCTAssertEqual(requests, 0)

        let suite = "LoadTestingAnonymousIdentityTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = LoadTestingAnonymousIdentity.current(defaults: defaults)
        XCTAssertTrue(LoadTestingAnonymousIdentity.isValid(first))
        XCTAssertEqual(LoadTestingAnonymousIdentity.current(defaults: defaults), first)
        defaults.set("invalid", forKey: LoadTestingAnonymousIdentity.storageKey)
        let replaced = LoadTestingAnonymousIdentity.current(defaults: defaults)
        XCTAssertTrue(LoadTestingAnonymousIdentity.isValid(replaced))
        XCTAssertNotEqual(replaced, "invalid")
    }

    func testPublicLoadTestRoutesAcceptRootAndValidSharedIDsOnly() {
        let rootRoute = LoadTestingPublicRoute(path: "/test")
        XCTAssertNotNil(rootRoute)
        XCTAssertNil(rootRoute?.testID)
        XCTAssertNil(LoadTestingPublicRoute(path: "/test/stats")?.testID)
        XCTAssertEqual(LoadTestingPublicRoute(path: "/test/scan-42")?.testID, "scan-42")
        XCTAssertEqual(LoadTestingPublicRoute(path: "/test/case%3A42")?.testID, "case:42")
        XCTAssertTrue(NativeAccountRoutePanel.supports(path: "/test"))
        XCTAssertTrue(NativeAccountRoutePanel.supports(path: "/test/scan-42"))
        for path in ["/test/", "/test/../other", "/test/id/extra", "/dashboard", "/test/unsafe%2Fpath"] {
            XCTAssertNil(LoadTestingPublicRoute(path: path), path)
        }
    }

    func testGuestModeMustBeExplicitAndRequiresValidClientUUID() async throws {
        var requests = 0
        let noIdentity = try LoadTestingClient(
            apiBaseURL: URL(string: "https://api.synthetic.invalid/api")!,
            userID: "",
            token: "",
            send: { _ in requests += 1; return (Data("{}".utf8), Self.response(status: 200)) }
        )
        XCTAssertFalse(noIdentity.canRead)
        XCTAssertFalse(noIdentity.canWrite)
        do {
            _ = try await noIdentity.quota()
            XCTFail("An anonymous request without an explicit client UUID must be rejected")
        } catch let error as LoadTestingClientError {
            guard case .signIn = error else { return XCTFail("Unexpected error: \(error)") }
        }

        let invalidIdentity = try LoadTestingClient(
            apiBaseURL: URL(string: "https://api.synthetic.invalid/api")!,
            userID: "",
            token: "",
            anonymousClientID: "not-a-uuid",
            send: { _ in requests += 1; return (Data("{}".utf8), Self.response(status: 200)) }
        )
        XCTAssertFalse(invalidIdentity.canRead)
        XCTAssertFalse(invalidIdentity.canWrite)
        XCTAssertEqual(requests, 0)
    }

    func testAuthenticatedHistoryCallsExpectedLaneAndLimit() async throws {
        var captured: URLRequest?
        let client = try makeClient(send: { request in
            captured = request
            return (Data("[]".utf8), Self.response(status: 200))
        })

        let history = try await client.history(.mine)
        XCTAssertTrue(history.isEmpty)
        XCTAssertEqual(captured?.url?.absoluteString, "https://api.synthetic.invalid/api/tests/mine?limit=50")
        XCTAssertEqual(captured?.value(forHTTPHeaderField: "Authorization"), "Bearer synthetic-token")
        XCTAssertEqual(captured?.value(forHTTPHeaderField: "id"), "user-17")
        XCTAssertNil(captured?.value(forHTTPHeaderField: "x-load-test-client-id"))
        XCTAssertTrue(client.isAuthenticated)
        XCTAssertTrue(client.canRerun)
    }

    func testRecentHistoryBoundsCallerLimitAndRejectsDuplicateIDs() async throws {
        let client = try makeClient(send: { request in
            XCTAssertTrue(request.url?.absoluteString.hasSuffix("/api/tests/recent?limit=50") == true)
            return (Data("[{\"id\":\"same\",\"url\":\"https://a.example\",\"status\":\"done\"},{\"id\":\"same\",\"url\":\"https://b.example\",\"status\":\"done\"}]".utf8), Self.response(status: 200))
        })
        do {
            _ = try await client.history(.recent, limit: 500)
            XCTFail("Expected duplicate history IDs to be rejected")
        } catch let error as LoadTestingClientError {
            guard case .malformed = error else { return XCTFail("Unexpected error: \(error)") }
        }
    }

    func testImpersonationAllowsReadButBlocksCreateAndRerun() async throws {
        var requests = 0
        let client = try makeClient(impersonationToken: "delegated", impersonatingUserID: "user-88", send: { request in
            requests += 1
            XCTAssertEqual(request.value(forHTTPHeaderField: "x-impersonation-token"), "delegated")
            return (Data("[]".utf8), Self.response(status: 200))
        })

        _ = try await client.history(.mine)
        XCTAssertFalse(client.canWrite)
        do {
            _ = try await client.create(url: "https://example.com/health", scenario: LoadTestingScenario.all[0])
            XCTFail("Impersonated sessions must not start tests")
        } catch let error as LoadTestingClientError {
            guard case .impersonation = error else { return XCTFail("Unexpected error: \(error)") }
        }
        do {
            try await client.rerun(id: "test-1")
            XCTFail("Impersonated sessions must not rerun tests")
        } catch let error as LoadTestingClientError {
            guard case .impersonation = error else { return XCTFail("Unexpected error: \(error)") }
        }
        XCTAssertEqual(requests, 1)
    }

    func testCreateQueuesOnlyOnceAndEncodesSelectedScenario() async throws {
        var captured: URLRequest?
        let client = try makeClient(send: { request in
            captured = request
            return (Data("{\"id\":\"run-4\",\"url\":\"https://example.com/health\",\"status\":\"queued\"}".utf8), Self.response(status: 200))
        })

        let result = try await client.create(url: "example.com/health#section", scenario: LoadTestingScenario.all[1])

        XCTAssertEqual(result.id, "run-4")
        XCTAssertEqual(captured?.httpMethod, "POST")
        XCTAssertEqual(captured?.url?.absoluteString, "https://api.synthetic.invalid/api/test")
        let payload = try XCTUnwrap(captured?.httpBody)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: payload) as? [String: Any])
        XCTAssertEqual(object["url"] as? String, "https://example.com/health")
        XCTAssertEqual(object["timeout"] as? Int, 45)
        XCTAssertEqual((object["stages"] as? [[String: Any]])?.count, 3)
    }

    func testRerunRequiresAValidReceiptAndUsesEncodedID() async throws {
        var captured: URLRequest?
        let client = try makeClient(send: { request in
            captured = request
            return (Data("{\"ok\":true,\"status\":\"queued\"}".utf8), Self.response(status: 200))
        })

        try await client.rerun(id: "case:42")

        XCTAssertEqual(captured?.httpMethod, "POST")
        XCTAssertEqual(captured?.url?.absoluteString, "https://api.synthetic.invalid/api/test/case:42/rerun")
    }

    func testUnknownSubmissionOutcomeIsMarkedUncertain() async throws {
        let client = try makeClient(send: { _ in throw URLError(.timedOut) })
        do {
            _ = try await client.create(url: "https://example.com/health", scenario: LoadTestingScenario.all[0])
            XCTFail("Expected timeout")
        } catch let error as LoadTestingClientError {
            XCTAssertTrue(error.isUncertain)
            XCTAssertTrue(error.localizedDescription.contains("may have reached"))
        }
    }

    func testMalformedCreateReceiptIsUncertain() async throws {
        let client = try makeClient(send: { _ in
            (Data("{\"url\":\"https://example.com/health\",\"status\":\"queued\"}".utf8), Self.response(status: 200))
        })
        do {
            _ = try await client.create(url: "https://example.com/health", scenario: LoadTestingScenario.all[0])
            XCTFail("Expected a missing test ID to be rejected")
        } catch let error as LoadTestingClientError {
            XCTAssertTrue(error.isUncertain)
            XCTAssertTrue(error.localizedDescription.contains("invalid load-test response"))
        }
    }

    func testQuotaReceiptAndHTTPQuotaError() async throws {
        let quotaJSON = "{\"plan\":\"team\",\"limit\":25,\"used\":9,\"remaining\":16,\"resetsAt\":null}"
        let client = try makeClient(send: { _ in (Data(quotaJSON.utf8), Self.response(status: 200)) })
        let quota = try await client.quota()
        XCTAssertEqual(quota.plan, "team")
        XCTAssertEqual(quota.remaining, 16)

        let limited = try makeClient(send: { _ in
            (Data("{\"error\":\"Allowance used\",\"quota\":\(quotaJSON)}".utf8), Self.response(status: 402))
        })
        do {
            _ = try await limited.create(url: "https://example.com/health", scenario: LoadTestingScenario.all[0])
            XCTFail("Expected an allowance error")
        } catch let error as LoadTestingClientError {
            XCTAssertEqual(error.quota?.remaining, 16)
            XCTAssertFalse(error.isUncertain)
        }
    }

    func testInvalidTargetAndTestIDAreRejectedBeforeRequest() async throws {
        var requests = 0
        let client = try makeClient(send: { _ in requests += 1; return (Data("{}".utf8), Self.response(status: 200)) })
        for url in ["javascript:alert(1)", "https://user:pass@example.com", "ftp://example.com"] {
            do {
                _ = try await client.create(url: url, scenario: LoadTestingScenario.all[0])
                XCTFail("Expected invalid endpoint to be rejected")
            } catch let error as LoadTestingClientError {
                guard case .invalidDraft = error else { return XCTFail("Unexpected error: \(error)") }
            }
        }
        do {
            _ = try await client.result(id: "../other")
            XCTFail("Expected invalid ID to be rejected")
        } catch let error as LoadTestingClientError {
            guard case .invalidTestID = error else { return XCTFail("Unexpected error: \(error)") }
        }
        XCTAssertEqual(requests, 0)
    }

    func testCustomStageLimitsAndLocalhostPortValidation() async throws {
        var requests = 0
        let client = try makeClient(send: { _ in requests += 1; return (Data("{}".utf8), Self.response(status: 200)) })
        XCTAssertEqual(try LoadTestingClient.validate(url: "localhost:8080/health"), "https://localhost:8080/health")
        let unsafeScenario = LoadTestingScenario(id: "custom", title: "Custom", description: "Custom", timeout: 30, stages: [.init(duration: "601s", target: 1)])
        do {
            _ = try await client.create(url: "https://example.com/health", scenario: unsafeScenario)
            XCTFail("Expected an overlong scenario to be rejected")
        } catch let error as LoadTestingClientError {
            guard case .invalidDraft = error else { return XCTFail("Unexpected error: \(error)") }
        }
        XCTAssertEqual(requests, 0)
    }

    private func makeClient(impersonationToken: String = "", impersonatingUserID: String = "", send: @escaping LoadTestingClient.Sender) throws -> LoadTestingClient {
        try LoadTestingClient(
            apiBaseURL: URL(string: "https://api.synthetic.invalid/api")!,
            userID: "user-17",
            token: "synthetic-token",
            impersonationToken: impersonationToken,
            impersonatingUserID: impersonatingUserID,
            send: send
        )
    }

    private func makeAnonymousClient(id: String, send: @escaping LoadTestingClient.Sender) throws -> LoadTestingClient {
        try LoadTestingClient(
            apiBaseURL: URL(string: "https://api.synthetic.invalid/api")!,
            userID: "",
            token: "",
            anonymousClientID: id,
            send: send
        )
    }

    private static func response(status: Int) -> HTTPURLResponse {
        HTTPURLResponse(url: URL(string: "https://api.synthetic.invalid")!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
    }
}
