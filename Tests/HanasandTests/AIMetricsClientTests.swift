import XCTest
@testable import Hanasand

final class AIMetricsClientTests: XCTestCase {
    func testIntegerConversionRejectsDoubleRoundedIntUpperBound() {
        let roundedUpperBound = Double(Int.max)
        XCTAssertNil(AIMetricsValidation.integer(roundedUpperBound))
        XCTAssertEqual(AIMetricsValidation.integer(roundedUpperBound.nextDown), Int(roundedUpperBound.nextDown))
    }

    func testAuthenticatedEndpointTargetsMatchExpoContract() async throws {
        let settings = HanasandDesktopSettings()
        let client = await MainActor.run { AIMetricsClient(settings: settings) }
        let urls = try await MainActor.run {
            [try client.endpoint(settings.apiBaseURL, "ai/models"),
             try client.endpoint(settings.websiteBaseURL, "api/backend/ai/economics?days=30"),
             try client.endpoint(settings.apiBaseURL, "docker"),
             try client.endpoint(settings.apiBaseURL, "client/ws/gpt")]
        }
        XCTAssertEqual(urls.map(\.absoluteString), [
            "https://api.hanasand.com/api/ai/models",
            "https://hanasand.com/api/backend/ai/economics?days=30",
            "https://api.hanasand.com/api/docker",
            "https://api.hanasand.com/api/client/ws/gpt",
        ])
        var mutableSettings = settings
        mutableSettings.authToken = "test-token"; mutableSettings.userID = "user-1"; mutableSettings.selectedOrganizationID = "org-1"
        let authenticated = mutableSettings
        let request = try await MainActor.run { try client.request(urls[0], settings: authenticated) }
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-token")
        XCTAssertEqual(request.value(forHTTPHeaderField: "id"), "user-1")
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-organization-id"), "org-1")
        XCTAssertEqual(request.cachePolicy, .reloadIgnoringLocalAndRemoteCacheData)
        XCTAssertEqual(AIMetricsError.http(401).localizedDescription, "AI access could not be verified. Refresh manually before continuing.")
        do { _ = try await MainActor.run { try client.endpoint("http://example.com", "docker") }; XCTFail("insecure endpoint should fail") } catch { }
    }

    func testHTTPModelAndTelemetryParsingAndBounds() async throws {
        let settings = HanasandDesktopSettings(), client = await MainActor.run { AIMetricsClient(settings: settings) }
        let models = Data(#"{"connected":[{"id":"opaque","name":"worker-a","model":{"status":"ready","tps":18.5,"maxTokens":8192}}]}"#.utf8)
        let parsed = try await MainActor.run { try client.parseClients(models) }
        XCTAssertEqual(parsed.first?.name, "worker-a")
        XCTAssertEqual(parsed.first?.model.status, "ready")
        XCTAssertEqual(parsed.first?.model.tps, 18.5)
        XCTAssertNil(parsed.first?.ram)
        let economics = Data(#"{"windowDays":30,"reliability":{"queueDepth":[{"lane":"long-lane-identifier","model":"m","kind":"completion","status":"queued","count":2}],"promptTiming":{"p50FirstUsefulOutputMs":320,"p95FirstUsefulOutputMs":900,"sampleCount":8}}}"#.utf8)
        let values = try await MainActor.run { try client.parseEconomics(economics) }
        XCTAssertEqual(values.firstOutputP50, 320)
        XCTAssertEqual(values.queue.first?.count, 2)
        do { _ = try await MainActor.run { try client.parseEconomics(Data(#"{"reliability":{"queueDepth":"bad"}}"#.utf8)) }; XCTFail("malformed queue should fail") } catch { }
        XCTAssertThrowsError(try AIMetricsValidation.boundedJSON(Data(repeating: 0x20, count: AIMetricsValidation.maxBytes + 1)))
    }

    func testDockerHealthAcceptsEnvelopeAndFiltersToAIContainers() async throws {
        let settings = HanasandDesktopSettings(), client = await MainActor.run { AIMetricsClient(settings: settings) }
        let body = Data(#"{"generated_at":"2026-10-24T00:00:00Z","containers":[{"name":"gpt-parser","image":"parser:v1","status":"running","health":"healthy"},{"name":"web","image":"nginx","status":"running"}]}"#.utf8)
        let parsed = try await MainActor.run { try client.parseContainers(body) }
        XCTAssertEqual(parsed.items.map(\.name), ["gpt-parser"])
        XCTAssertEqual(parsed.items.first?.health, "healthy")
    }

    @MainActor
    func testScopeChangesOnAccountOrganizationAndEndpointOnly() {
        var original = HanasandDesktopSettings()
        let initial = AIMetricsClient.scopeKey(original)
        original.userID = "different-user"
        XCTAssertNotEqual(initial, AIMetricsClient.scopeKey(original))
        original.userID = ""
        original.selectedOrganizationID = "org-1"
        XCTAssertNotEqual(initial, AIMetricsClient.scopeKey(original))
        original.selectedOrganizationID = ""
        original.apiBaseURL = "https://api.example.invalid/api"
        XCTAssertNotEqual(initial, AIMetricsClient.scopeKey(original))
    }

    func testLiveEventCorrelationUsesConversationAndExplicitClient() throws {
        let correct: [String: Any] = ["type": "prompt_delta", "conversationId": "conversation-a", "clientName": "model-a"]
        XCTAssertTrue(AIMetricsValidation.eventMatches(correct, conversationID: "conversation-a", clientName: "model-a"))
        XCTAssertFalse(AIMetricsValidation.eventMatches(correct, conversationID: "conversation-b", clientName: "model-a"))
        XCTAssertFalse(AIMetricsValidation.eventMatches(correct, conversationID: "conversation-a", clientName: "model-b"))
        let data = try JSONSerialization.data(withJSONObject: correct)
        XCTAssertEqual(try AIMetricsValidation.event(data)["type"] as? String, "prompt_delta")
        XCTAssertThrowsError(try AIMetricsValidation.event(Data("[]".utf8)))
    }
}
